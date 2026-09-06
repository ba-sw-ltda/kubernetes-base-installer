<#
.SYNOPSIS
    Collect OpenBao settings upfront, including multi-PKI definitions.
.PARAMETER Platform
    Target platform
.PARAMETER Domain
    Cluster domain (from Install-Base.ps1)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Domain = "kubernetes.local"
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

# ── Seed PKI list from state file ────────────────────────────────
# If the state file already exists (re-run or upgrade), load whatever
# PKIs were previously defined. If the file has the old single-PKI format
# (no PKIs key), pre-populate with the legacy "ingress" entry so the user
# doesn't have to re-enter it.
$pkis = [System.Collections.Generic.List[hashtable]]::new()

$stateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
if (Test-Path $stateFile) {
    $existingState = Get-Content $stateFile | ConvertFrom-Json -AsHashtable
    if ($existingState.ContainsKey('PKIs') -and $existingState['PKIs']) {
        foreach ($p in @($existingState['PKIs'])) {
            $pkis.Add([hashtable]$p) | Out-Null
        }
    } elseif ($existingState.ContainsKey('UnsealKey')) {
        # Old format: migrate the single implicit root CA
        $pkis.Add(@{
            Name      = "ingress"
            MountPath = "pki"
            Type      = "Root"
            Roles     = @("HTTP")
            IsDefault = $true
            Status    = "Active"
        }) | Out-Null
    }
}

# ── Helper: build ContextCurrent summary of current PKIs ─────────
function Get-PkiSummary {
    param([System.Collections.Generic.List[hashtable]]$PKIs)
    $ctx = [ordered]@{}
    if ($PKIs.Count -eq 0) {
        $ctx["PKIs"] = "(none defined yet)"
    } else {
        foreach ($p in $PKIs) {
            $label  = $p.Name + $(if ($p.IsDefault) { " [DEFAULT]" })
            $roles  = (@($p.Roles) -join ", ")
            $status = if ($p.Status) { " · $($p.Status)" } else { "" }
            $ctx[$label] = "$($p.Type) · $roles$status"
        }
    }
    return $ctx
}

# ── PKI management loop ───────────────────────────────────────────
# Outer do-while: re-runs the full management loop when the user chooses
# "go back" from the empty-PKI warning instead of confirming no-PKI.
do {
$restartPkiLoop = $false
$continueLoop = $true
while ($continueLoop) {
    $menuOptions = [System.Collections.Generic.List[hashtable]]::new()
    $menuOptions.Add(@{ Label = "Done — apply PKIs"; Value = "done" }) | Out-Null
    $menuOptions.Add(@{ Label = "Add PKI";           Value = "add"  }) | Out-Null
    foreach ($p in $pkis) {
        $menuOptions.Add(@{ Label = "Edit:   $($p.Name)"; Value = "edit:$($p.Name)"   }) | Out-Null
        $menuOptions.Add(@{ Label = "Delete: $($p.Name)"; Value = "delete:$($p.Name)" }) | Out-Null
    }

    $choice = Read-SelectValue `
        -Title   "PKI Management" `
        -Message "Define certificate authorities — each PKI is mounted as its own secrets engine in OpenBao" `
        -Options $menuOptions `
        -Default 0 `
        -ContextTitle "Security/OpenBao — PKIs" `
        -ContextHint  "Root CA: self-signed. Intermediate CA: signed by a parent CA (internal or external)." `
        -ContextCurrent (Get-PkiSummary -PKIs $pkis)

    if ($null -eq $choice -or $choice -eq "done") {
        $continueLoop = $false; break
    }

    # ── Add ──────────────────────────────────────────────────────
    if ($choice -eq "add") {
        # Name
        $nameRaw = Read-Plain `
            -Prompt       "PKI name (e.g. ingress, vehicles, corporate)" `
            -ContextTitle "Security/OpenBao — Add PKI" `
            -ContextHint  "MountPath will automatically be 'pki-<name>'; CommonName will be '<name>.$Domain'" `
            -ContextCurrent (Get-PkiSummary -PKIs $pkis)
        if ([string]::IsNullOrWhiteSpace($nameRaw)) { continue }
        $name = $nameRaw.Trim().ToLower() -replace '[^a-z0-9-]', '-'

        if ($pkis | Where-Object { $_.Name -eq $name }) {
            Write-Host "  PKI '$name' already exists." -ForegroundColor Yellow; continue
        }

        # Type
        $type = Read-SelectValue `
            -Title   "PKI type" `
            -Options @(
                @{ Label = "Root CA — self-signed (e.g. own infrastructure, vehicles)"; Value = "Root"         }
                @{ Label = "Intermediate CA — signed by a parent CA";                   Value = "Intermediate" }
            ) `
            -Default 0 `
            -ContextTitle   "Security/OpenBao — Add PKI" `
            -ContextCurrent ([ordered]@{ Name = $name; MountPath = "pki-$name" })
        if ($null -eq $type) { continue }

        $parentType       = $null
        $parentMountPath  = $null

        if ($type -eq "Intermediate") {
            $parentOptions = [System.Collections.Generic.List[hashtable]]::new()
            $parentOptions.Add(@{ Label = "External — Corporate CA outside of OpenBao (CSR is exported)"; Value = "External" }) | Out-Null
            foreach ($p in $pkis) {
                $parentOptions.Add(@{ Label = "OpenBao PKI: $($p.Name) ($($p.Type))"; Value = "openbao:$($p.Name)" }) | Out-Null
            }

            $parentChoice = Read-SelectValue `
                -Title   "Parent CA" `
                -Message "Which CA should sign this intermediate?" `
                -Options $parentOptions `
                -Default 0 `
                -ContextTitle   "Security/OpenBao — Add PKI" `
                -ContextCurrent ([ordered]@{ Name = $name; Type = $type })
            if ($null -eq $parentChoice) { continue }

            if ($parentChoice -eq "External") {
                $parentType = "External"
            } else {
                $parentType  = "OpenBao"
                $parentName  = $parentChoice -replace '^openbao:', ''
                $parentPkiObj = $pkis | Where-Object { $_.Name -eq $parentName } | Select-Object -First 1
                if ($parentPkiObj) { $parentMountPath = $parentPkiObj.MountPath }
            }
        }

        # Roles
        $roleOptions = @(
            @{ Label = "HTTP — server certificates for Ingress (ServerAuth, cert-manager ClusterIssuer)"; Value = "HTTP"        }
            @{ Label = "mTLS — client certificates for devices (ClientAuth, CSR-based)";                  Value = "mTLS"        }
            @{ Label = "CodeSigning — code signing (placeholder, no logic yet)";                          Value = "CodeSigning" }
        )
        $preSelected = @("HTTP")  # default pre-check
        $selectedRoles = Read-MultiSelectValues `
            -Title         "Roles for PKI '$name'" `
            -Message       "Which certificate types should this PKI issue?" `
            -Options       $roleOptions `
            -DefaultValues $preSelected `
            -ContextTitle  "Security/OpenBao — Add PKI" `
            -ContextCurrent ([ordered]@{ Name = $name; Type = $type })
        if ($null -eq $selectedRoles -or $selectedRoles.Count -eq 0) { $selectedRoles = @("HTTP") }

        # mTLS TTL
        $mTlsTtlHours = 336
        if ("mTLS" -in $selectedRoles) {
            $ttlInput = Read-Plain `
                -Prompt       "Client cert TTL in hours" `
                -Default      "336" `
                -ContextTitle "Security/OpenBao — Add PKI" `
                -ContextHint  "336h = 14 days; renewal starts at 50% (day 7)" `
                -ContextCurrent ([ordered]@{ Name = $name; Roles = ($selectedRoles -join ", ") })
            $ttlVal = [int]($ttlInput -replace '\D', '0')
            if ($ttlVal -gt 0) { $mTlsTtlHours = $ttlVal }
        }

        # IsDefault (auto-set if no default exists; ask otherwise only for HTTP PKIs)
        $isDefault = $false
        $hasDefault = [bool]($pkis | Where-Object { $_.IsDefault })
        if (-not $hasDefault) {
            $isDefault = $true
        } elseif ("HTTP" -in $selectedRoles) {
            $isDefault = Read-YesNo `
                -Title       "Set as default PKI for Ingress certificates?" `
                -DefaultYes  $false `
                -ContextTitle "Security/OpenBao — Add PKI" `
                -ContextCurrent ([ordered]@{ Name = $name; Type = $type })
            if ($isDefault) {
                foreach ($p in $pkis) { $p['IsDefault'] = $false }
            }
        }

        $newPki = @{
            Name      = $name
            MountPath = "pki-$name"
            Type      = $type
            Roles     = @($selectedRoles)
            IsDefault = $isDefault
            Status    = ""   # filled by Install.ps1
        }
        if ($type -eq "Intermediate") {
            $newPki['ParentType'] = $parentType
            if ($parentMountPath) { $newPki['ParentMountPath'] = $parentMountPath }
        }
        if ("mTLS" -in $selectedRoles) {
            $newPki['mTlsTtlHours'] = $mTlsTtlHours
        }

        $pkis.Add($newPki) | Out-Null
        Write-Host "  ✓ PKI '$name' added to the list" -ForegroundColor Green
    }

    # ── Edit ─────────────────────────────────────────────────────
    elseif ($choice -like "edit:*") {
        $editName = $choice -replace '^edit:', ''
        $pki = $pkis | Where-Object { $_.Name -eq $editName } | Select-Object -First 1
        if (-not $pki) { continue }

        $editChoice = Read-SelectValue `
            -Title   "Edit: $editName" `
            -Options @(
                @{ Label = "Adjust roles";                Value = "roles"   }
                @{ Label = "Set as default PKI";          Value = "default" }
                @{ Label = "Rename";                      Value = "rename"  }
                @{ Label = "Back";                        Value = "back"    }
            ) `
            -Default 0 `
            -ContextTitle   "Security/OpenBao — Edit PKI" `
            -ContextCurrent ([ordered]@{
                Name      = $pki.Name
                Type      = $pki.Type
                Roles     = (@($pki.Roles) -join ", ")
                MountPath = $pki.MountPath
                Default   = if ($pki.IsDefault) { "Yes" } else { "No" }
                Status    = if ($pki.Status) { $pki.Status } else { "new" }
            })

        switch ($editChoice) {
            "roles" {
                $roleOptions = @(
                    @{ Label = "HTTP — server certificates for Ingress (ServerAuth)"; Value = "HTTP"        }
                    @{ Label = "mTLS — client certificates for devices (ClientAuth)";  Value = "mTLS"        }
                    @{ Label = "CodeSigning — code signing (placeholder)";              Value = "CodeSigning" }
                )
                $newRoles = Read-MultiSelectValues `
                    -Title         "Roles for '$editName'" `
                    -Options       $roleOptions `
                    -DefaultValues @($pki.Roles) `
                    -ContextTitle  "Security/OpenBao — Edit PKI" `
                    -ContextCurrent ([ordered]@{ Name = $pki.Name })
                if ($newRoles -and $newRoles.Count -gt 0) {
                    $pki['Roles'] = @($newRoles)
                    if ("mTLS" -in $newRoles -and -not $pki.ContainsKey('mTlsTtlHours')) {
                        $ttlInput = Read-Plain `
                            -Prompt       "Client cert TTL in hours" `
                            -Default      "336" `
                            -ContextTitle "Security/OpenBao — Edit PKI" `
                            -ContextHint  "336h = 14 days"
                        $ttlVal = [int]($ttlInput -replace '\D', '0')
                        $pki['mTlsTtlHours'] = if ($ttlVal -gt 0) { $ttlVal } else { 336 }
                    }
                    Write-Host "  ✓ Roles updated: $((@($pki['Roles'])) -join ', ')" -ForegroundColor Green
                }
            }
            "default" {
                foreach ($p in $pkis) { $p['IsDefault'] = $false }
                $pki['IsDefault'] = $true
                Write-Host "  ✓ '$editName' is now the default PKI" -ForegroundColor Green
            }
            "rename" {
                $newNameRaw = Read-Plain `
                    -Prompt       "New name for '$editName'" `
                    -ContextTitle "Security/OpenBao — Rename PKI" `
                    -ContextCurrent ([ordered]@{ Current_Name = $editName })
                if ([string]::IsNullOrWhiteSpace($newNameRaw)) { break }
                $newName = $newNameRaw.Trim().ToLower() -replace '[^a-z0-9-]', '-'
                if ($pkis | Where-Object { $_.Name -eq $newName -and $_.Name -ne $editName }) {
                    Write-Host "  Name '$newName' already exists." -ForegroundColor Yellow; break
                }
                # Only auto-update MountPath if it was auto-derived
                if ($pki['MountPath'] -eq "pki-$editName") { $pki['MountPath'] = "pki-$newName" }
                $pki['Name'] = $newName
                Write-Host "  ✓ Renamed: '$editName' → '$newName'" -ForegroundColor Green
            }
        }
    }

    # ── Delete ───────────────────────────────────────────────────
    elseif ($choice -like "delete:*") {
        $delName = $choice -replace '^delete:', ''
        $confirm = Read-YesNo `
            -Title      "Remove PKI '$delName' from the list?" `
            -DefaultYes $false `
            -ContextTitle   "Security/OpenBao — Delete PKI" `
            -ContextHint    "Removes the PKI from the installer. Existing OpenBao mounts are NOT automatically deleted." `
            -ContextCurrent ([ordered]@{ Name = $delName })
        if ($confirm) {
            $toRemove = $pkis | Where-Object { $_.Name -eq $delName } | Select-Object -First 1
            $pkis.Remove($toRemove) | Out-Null
            Write-Host "  ✓ '$delName' removed" -ForegroundColor Green
        }
    }
}

# ── Guard: empty PKI list ─────────────────────────────────────────
# Without any PKI there is no ClusterIssuer → no TLS. Authelia's session
# cookie is Secure-only, so logins will silently fail on every browser.
# This is intentionally allowed (dev/CI without a browser is a valid use
# case), but must be an explicit choice — not an accidental omission.
if ($pkis.Count -eq 0) {
    Write-Host ""
    Write-Host "  ⚠  No PKI defined!" -ForegroundColor Yellow
    Write-Host "     Without a PKI: no TLS, no ClusterIssuer." -ForegroundColor Yellow
    Write-Host "     Authelia login will not work (Secure cookie requires HTTPS)." -ForegroundColor Yellow
    Write-Host "     Only suitable for development/CI without a browser." -ForegroundColor DarkGray
    Write-Host ""
    $proceed = Read-YesNo `
        -Title      "Continue without a PKI?" `
        -DefaultYes $false `
        -YesLabel   "Yes — no TLS, Authelia login disabled (Dev/CI only)" `
        -NoLabel    "No — back to PKI management" `
        -ContextTitle "Security/OpenBao — PKI warning" `
        -ContextCurrent ([ordered]@{ TLS = "disabled"; Authelia = "Login not functional" })
    if (-not $proceed) { $restartPkiLoop = $true }
}
} while ($restartPkiLoop)  # outer do-while: re-runs the management loop if user goes back

# ── High Availability ─────────────────────────────────────────────
$haEnabled = Read-YesNo `
    -Title "Enable High Availability (Raft, 3 replicas)?" `
    -DefaultYes $false `
    -ContextTitle "Security/OpenBao — $Platform" `
    -ContextHint "Switches storage from single-node file to Raft integrated storage across 3 pods. Switching modes on an existing install wipes and reinitializes OpenBao (fresh unseal keys/root token; PKIs/secrets are lost) — no in-place migration."

# ── OpenBao hostname ──────────────────────────────────────────────
$defaultHostname = "vault.$Domain"
$hostname = Read-Plain `
    -Prompt       "OpenBao hostname" `
    -Default      $defaultHostname `
    -ContextTitle "Security/OpenBao — $Platform" `
    -ContextHint  "DNS name under which the OpenBao UI is reachable" `
    -ContextCurrent ([ordered]@{
        PKIs   = if ($pkis.Count -gt 0) { ($pkis | ForEach-Object { $_.Name }) -join ", " } else { "(none)" }
        Domain = $Domain
    })

return @{
    Hostname  = $hostname.Trim()
    Domain    = $Domain
    PKIs      = @($pkis | ForEach-Object { [hashtable]$_ })
    HAEnabled = $haEnabled
}
