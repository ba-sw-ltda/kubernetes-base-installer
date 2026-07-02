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
        $ctx["PKIs"] = "(noch keine definiert)"
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
    $menuOptions.Add(@{ Label = "Fertig — PKIs übernehmen"; Value = "done" }) | Out-Null
    $menuOptions.Add(@{ Label = "PKI hinzufügen";           Value = "add"  }) | Out-Null
    foreach ($p in $pkis) {
        $menuOptions.Add(@{ Label = "Bearbeiten: $($p.Name)"; Value = "edit:$($p.Name)"   }) | Out-Null
        $menuOptions.Add(@{ Label = "Löschen:    $($p.Name)"; Value = "delete:$($p.Name)" }) | Out-Null
    }

    $choice = Read-SelectValue `
        -Title   "PKI Verwaltung" `
        -Message "Zertifizierungsstellen definieren — jede PKI wird als eigene secrets engine in OpenBao gemountet" `
        -Options $menuOptions `
        -Default 0 `
        -ContextTitle "33 - Security - OpenBao — PKIs" `
        -ContextHint  "Root CA: selbst signiert. Intermediate CA: von einer Parent CA signiert (intern oder extern)." `
        -ContextCurrent (Get-PkiSummary -PKIs $pkis)

    if ($null -eq $choice -or $choice -eq "done") {
        $continueLoop = $false; break
    }

    # ── Add ──────────────────────────────────────────────────────
    if ($choice -eq "add") {
        # Name
        $nameRaw = Read-Plain `
            -Prompt       "PKI Name (z.B. ingress, vehicles, corporate)" `
            -ContextTitle "33 - Security - OpenBao — PKI hinzufügen" `
            -ContextHint  "MountPath wird automatisch 'pki-<name>'; CommonName wird '<name>.$Domain'" `
            -ContextCurrent (Get-PkiSummary -PKIs $pkis)
        if ([string]::IsNullOrWhiteSpace($nameRaw)) { continue }
        $name = $nameRaw.Trim().ToLower() -replace '[^a-z0-9-]', '-'

        if ($pkis | Where-Object { $_.Name -eq $name }) {
            Write-Host "  PKI '$name' existiert bereits." -ForegroundColor Yellow; continue
        }

        # Type
        $type = Read-SelectValue `
            -Title   "PKI Typ" `
            -Options @(
                @{ Label = "Root CA — selbst signiert (z.B. eigene Infrastruktur, Fahrzeuge)"; Value = "Root"         }
                @{ Label = "Intermediate CA — von einer Parent CA signiert";                    Value = "Intermediate" }
            ) `
            -Default 0 `
            -ContextTitle   "33 - Security - OpenBao — PKI hinzufügen" `
            -ContextCurrent ([ordered]@{ Name = $name; MountPath = "pki-$name" })
        if ($null -eq $type) { continue }

        $parentType       = $null
        $parentMountPath  = $null

        if ($type -eq "Intermediate") {
            $parentOptions = [System.Collections.Generic.List[hashtable]]::new()
            $parentOptions.Add(@{ Label = "Extern — Corporate CA außerhalb von OpenBao (CSR wird exportiert)"; Value = "External" }) | Out-Null
            foreach ($p in $pkis) {
                $parentOptions.Add(@{ Label = "OpenBao PKI: $($p.Name) ($($p.Type))"; Value = "openbao:$($p.Name)" }) | Out-Null
            }

            $parentChoice = Read-SelectValue `
                -Title   "Parent CA" `
                -Message "Welche CA soll dieses Intermediate signieren?" `
                -Options $parentOptions `
                -Default 0 `
                -ContextTitle   "33 - Security - OpenBao — PKI hinzufügen" `
                -ContextCurrent ([ordered]@{ Name = $name; Typ = $type })
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
            @{ Label = "HTTP — Server-Zertifikate für Ingress (ServerAuth, cert-manager ClusterIssuer)"; Value = "HTTP"        }
            @{ Label = "mTLS — Client-Zertifikate für Geräte (ClientAuth, CSR-basiert)";                Value = "mTLS"        }
            @{ Label = "CodeSigning — Code-Signing (Platzhalter, noch keine Logik)";                    Value = "CodeSigning" }
        )
        $preSelected = @("HTTP")  # default pre-check
        $selectedRoles = Read-MultiSelectValues `
            -Title         "Rollen für PKI '$name'" `
            -Message       "Welche Zertifikatstypen soll diese PKI ausstellen?" `
            -Options       $roleOptions `
            -DefaultValues $preSelected `
            -ContextTitle  "33 - Security - OpenBao — PKI hinzufügen" `
            -ContextCurrent ([ordered]@{ Name = $name; Typ = $type })
        if ($null -eq $selectedRoles -or $selectedRoles.Count -eq 0) { $selectedRoles = @("HTTP") }

        # mTLS TTL
        $mTlsTtlHours = 336
        if ("mTLS" -in $selectedRoles) {
            $ttlInput = Read-Plain `
                -Prompt       "Client-Cert TTL in Stunden" `
                -Default      "336" `
                -ContextTitle "33 - Security - OpenBao — PKI hinzufügen" `
                -ContextHint  "336h = 14 Tage; Erneuerung startet bei 50% (Tag 7)" `
                -ContextCurrent ([ordered]@{ Name = $name; Rollen = ($selectedRoles -join ", ") })
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
                -Title       "Als Standard-PKI für Ingress-Zertifikate setzen?" `
                -DefaultYes  $false `
                -ContextTitle "33 - Security - OpenBao — PKI hinzufügen" `
                -ContextCurrent ([ordered]@{ Name = $name; Typ = $type })
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
        Write-Host "  ✓ PKI '$name' zur Liste hinzugefügt" -ForegroundColor Green
    }

    # ── Edit ─────────────────────────────────────────────────────
    elseif ($choice -like "edit:*") {
        $editName = $choice -replace '^edit:', ''
        $pki = $pkis | Where-Object { $_.Name -eq $editName } | Select-Object -First 1
        if (-not $pki) { continue }

        $editChoice = Read-SelectValue `
            -Title   "Bearbeiten: $editName" `
            -Options @(
                @{ Label = "Rollen anpassen";                Value = "roles"   }
                @{ Label = "Als Standard-PKI setzen";        Value = "default" }
                @{ Label = "Umbenennen";                     Value = "rename"  }
                @{ Label = "Zurück";                         Value = "back"    }
            ) `
            -Default 0 `
            -ContextTitle   "33 - Security - OpenBao — PKI bearbeiten" `
            -ContextCurrent ([ordered]@{
                Name      = $pki.Name
                Typ       = $pki.Type
                Rollen    = (@($pki.Roles) -join ", ")
                MountPath = $pki.MountPath
                Standard  = if ($pki.IsDefault) { "Ja" } else { "Nein" }
                Status    = if ($pki.Status) { $pki.Status } else { "neu" }
            })

        switch ($editChoice) {
            "roles" {
                $roleOptions = @(
                    @{ Label = "HTTP — Server-Zertifikate für Ingress (ServerAuth)"; Value = "HTTP"        }
                    @{ Label = "mTLS — Client-Zertifikate für Geräte (ClientAuth)";  Value = "mTLS"        }
                    @{ Label = "CodeSigning — Code-Signing (Platzhalter)";            Value = "CodeSigning" }
                )
                $newRoles = Read-MultiSelectValues `
                    -Title         "Rollen für '$editName'" `
                    -Options       $roleOptions `
                    -DefaultValues @($pki.Roles) `
                    -ContextTitle  "33 - Security - OpenBao — PKI bearbeiten" `
                    -ContextCurrent ([ordered]@{ Name = $pki.Name })
                if ($newRoles -and $newRoles.Count -gt 0) {
                    $pki['Roles'] = @($newRoles)
                    if ("mTLS" -in $newRoles -and -not $pki.ContainsKey('mTlsTtlHours')) {
                        $ttlInput = Read-Plain `
                            -Prompt       "Client-Cert TTL in Stunden" `
                            -Default      "336" `
                            -ContextTitle "33 - Security - OpenBao — PKI bearbeiten" `
                            -ContextHint  "336h = 14 Tage"
                        $ttlVal = [int]($ttlInput -replace '\D', '0')
                        $pki['mTlsTtlHours'] = if ($ttlVal -gt 0) { $ttlVal } else { 336 }
                    }
                    Write-Host "  ✓ Rollen aktualisiert: $((@($pki['Roles'])) -join ', ')" -ForegroundColor Green
                }
            }
            "default" {
                foreach ($p in $pkis) { $p['IsDefault'] = $false }
                $pki['IsDefault'] = $true
                Write-Host "  ✓ '$editName' ist jetzt die Standard-PKI" -ForegroundColor Green
            }
            "rename" {
                $newNameRaw = Read-Plain `
                    -Prompt       "Neuer Name für '$editName'" `
                    -ContextTitle "33 - Security - OpenBao — PKI umbenennen" `
                    -ContextCurrent ([ordered]@{ Aktueller_Name = $editName })
                if ([string]::IsNullOrWhiteSpace($newNameRaw)) { break }
                $newName = $newNameRaw.Trim().ToLower() -replace '[^a-z0-9-]', '-'
                if ($pkis | Where-Object { $_.Name -eq $newName -and $_.Name -ne $editName }) {
                    Write-Host "  Name '$newName' existiert bereits." -ForegroundColor Yellow; break
                }
                # Only auto-update MountPath if it was auto-derived
                if ($pki['MountPath'] -eq "pki-$editName") { $pki['MountPath'] = "pki-$newName" }
                $pki['Name'] = $newName
                Write-Host "  ✓ Umbenannt: '$editName' → '$newName'" -ForegroundColor Green
            }
        }
    }

    # ── Delete ───────────────────────────────────────────────────
    elseif ($choice -like "delete:*") {
        $delName = $choice -replace '^delete:', ''
        $confirm = Read-YesNo `
            -Title      "PKI '$delName' aus der Liste entfernen?" `
            -DefaultYes $false `
            -ContextTitle   "33 - Security - OpenBao — PKI löschen" `
            -ContextHint    "Löscht die PKI aus dem Installer. Bestehende OpenBao-Mounts werden NICHT automatisch gelöscht." `
            -ContextCurrent ([ordered]@{ Name = $delName })
        if ($confirm) {
            $toRemove = $pkis | Where-Object { $_.Name -eq $delName } | Select-Object -First 1
            $pkis.Remove($toRemove) | Out-Null
            Write-Host "  ✓ '$delName' entfernt" -ForegroundColor Green
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
    Write-Host "  ⚠  Keine PKI definiert!" -ForegroundColor Yellow
    Write-Host "     Ohne PKI: kein TLS, kein ClusterIssuer." -ForegroundColor Yellow
    Write-Host "     Authelia-Login funktioniert nicht (Secure-Cookie erfordert HTTPS)." -ForegroundColor Yellow
    Write-Host "     Nur für Entwicklung/CI ohne Browser geeignet." -ForegroundColor DarkGray
    Write-Host ""
    $proceed = Read-YesNo `
        -Title      "Ohne PKI fortfahren?" `
        -DefaultYes $false `
        -YesLabel   "Ja — kein TLS, Authelia-Login deaktiviert (nur Dev/CI)" `
        -NoLabel    "Nein — zurück zur PKI-Verwaltung" `
        -ContextTitle "33 - Security - OpenBao — PKI Warnung" `
        -ContextCurrent ([ordered]@{ TLS = "deaktiviert"; Authelia = "Login nicht funktionsfähig" })
    if (-not $proceed) { $restartPkiLoop = $true }
}
} while ($restartPkiLoop)  # outer do-while: re-runs the management loop if user goes back

# ── OpenBao UI hostname ───────────────────────────────────────────
$defaultHostname = "vault.$Domain"
$hostname = Read-Plain `
    -Prompt       "OpenBao UI hostname" `
    -Default      $defaultHostname `
    -ContextTitle "33 - Security - OpenBao — $Platform" `
    -ContextHint  "DNS-Name unter dem die OpenBao UI erreichbar ist" `
    -ContextCurrent ([ordered]@{
        Domain = $Domain
        PKIs   = if ($pkis.Count -gt 0) { ($pkis | ForEach-Object { $_.Name }) -join ", " } else { "(keine)" }
    })

return @{
    Hostname = $hostname.Trim()
    Domain   = $Domain
    PKIs     = @($pkis | ForEach-Object { [hashtable]$_ })
}
