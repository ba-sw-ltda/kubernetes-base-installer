<#
.SYNOPSIS
    Collect private container registry settings upfront, including feed
    management (New / Edit / Delete) — same list-management UX as
    33-openbao/Prompt.ps1's PKI list.
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param(
    [string]$Platform
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$cfg       = Import-PowerShellDataFile "$PSScriptRoot\Config.psd1"
$Namespace = $cfg.Namespace

$useRegistry = Read-YesNo `
    -Title      "Registry" `
    -Message    "Use a private container registry?" `
    -DefaultYes $false `
    -ContextTitle "Configuration/ProGet — $Platform"
if (-not $useRegistry) { return @{} }

$registryUrl = Read-Plain `
    -Prompt       "Registry host" `
    -ContextTitle "Configuration/ProGet — $Platform" `
    -ContextHint  "e.g. registry.$Platform.local or proget.example.com"
if ([string]::IsNullOrWhiteSpace($registryUrl)) { return @{} }
$registryUrl = $registryUrl.Trim()

# K8s resource names / vault paths: lowercase alphanumeric + hyphens only.
# Kept identical to 43-proget-registry/Install.ps1's own ConvertTo-FeedSlug
# so vault paths line up (registry/$slug) — duplicated on purpose, this is
# a tiny private helper, not worth sharing across two independently
# invoked scripts.
function ConvertTo-FeedSlug {
    param([string]$Name)
    $slug = $Name.ToLower() -replace '[^a-z0-9-]', '-'
    $slug = $slug -replace '-+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = "feed" }
    return $slug
}

function Get-ProGetFeedStateFile {
    param([string]$BaseDir, [string]$Platform)
    $slug = switch ($Platform) {
        "RKE2 (On-Premise)" { "rke2"   }
        "Kind (Local)"      { "kind"   }
        "Magalu Cloud"      { "magalu" }
        "Azure AKS"         { "aks"    }
        "AWS EKS"           { "eks"    }
        "Google GKE"        { "gke"    }
        default             { "unknown" }
    }
    return Join-Path $BaseDir ".proget-registry-state-$slug.json"
}

# ── Seed feed list from state file ───────────────────────────────
# Only Name/User are persisted on disk — passwords never touch this file.
# For every seeded feed with a User, the password is pulled back from the
# cluster secret store (OpenBao/KMS) below, so a re-run doesn't force
# re-typing credentials that are already stored — that's the whole point
# of this conversion ("mühsam jedes mal die api keys raussuchen").
$feeds     = [System.Collections.Generic.List[hashtable]]::new()
$stateFile = Get-ProGetFeedStateFile -BaseDir $BaseDir -Platform $Platform
if (Test-Path $stateFile) {
    $existingState = Get-Content $stateFile | ConvertFrom-Json -AsHashtable
    if ($existingState -and $existingState.ContainsKey('Feeds')) {
        foreach ($f in @($existingState['Feeds'])) {
            $name     = [string]$f.Name
            $user     = [string]$f.User
            $password = ""
            if (-not [string]::IsNullOrWhiteSpace($user)) {
                $slug   = ConvertTo-FeedSlug -Name $name
                $secret = Get-ClusterSecret -Path "registry/$slug" -Keys @("user", "password") -BaseDir $BaseDir -Platform $Platform
                if ($secret.password) { $password = [string]$secret.password }
            }
            $feeds.Add(@{ Name = $name; User = $user; Password = $password }) | Out-Null
        }
    }
}

# ── Helper: build ContextCurrent summary of current feeds ────────
function Get-FeedSummary {
    param([System.Collections.Generic.List[hashtable]]$Feeds)
    $ctx = [ordered]@{}
    if ($Feeds.Count -eq 0) {
        $ctx["Feeds"] = "(none defined yet)"
    } else {
        foreach ($f in $Feeds) {
            $ctx[$f.Name] = if ([string]::IsNullOrWhiteSpace($f.User)) { "anonymous" } else { "user: $($f.User)" }
        }
    }
    return $ctx
}

# ── Feed management loop ──────────────────────────────────────────
$continueLoop = $true
while ($continueLoop) {
    $menuOptions = [System.Collections.Generic.List[hashtable]]::new()
    $menuOptions.Add(@{ Label = "Done — apply feeds"; Value = "done" }) | Out-Null
    $menuOptions.Add(@{ Label = "Add feed";           Value = "add"  }) | Out-Null
    foreach ($f in $feeds) {
        $menuOptions.Add(@{ Label = "Edit:   $($f.Name)"; Value = "edit:$($f.Name)"   }) | Out-Null
        $menuOptions.Add(@{ Label = "Delete: $($f.Name)"; Value = "delete:$($f.Name)" }) | Out-Null
    }

    $choice = Read-SelectValue `
        -Title   "Feed Management" `
        -Message "Define registry feeds — each becomes an imagePullSecret + ConfigMap in the '$Namespace' namespace" `
        -Options $menuOptions `
        -Default 0 `
        -ContextTitle "Configuration/ProGet — Feeds" `
        -ContextHint  "Anonymous/public feeds need no user/password." `
        -ContextCurrent (Get-FeedSummary -Feeds $feeds)

    if ($null -eq $choice -or $choice -eq "done") { $continueLoop = $false; break }

    # ── Add ──────────────────────────────────────────────────────
    if ($choice -eq "add") {
        $nameRaw = Read-Plain `
            -Prompt       "Feed name" `
            -ContextTitle "Configuration/ProGet — Add Feed" `
            -ContextCurrent (Get-FeedSummary -Feeds $feeds)
        if ([string]::IsNullOrWhiteSpace($nameRaw)) { continue }
        $name = $nameRaw.Trim()

        if ($feeds | Where-Object { $_.Name -eq $name }) {
            Write-Host "  Feed '$name' already exists." -ForegroundColor Yellow; continue
        }

        $user = Read-Plain `
            -Prompt       "  User for '$name' (Enter for an anonymous/public feed)" `
            -Default      "api" `
            -ContextTitle "Configuration/ProGet — Add Feed" `
            -ContextCurrent ([ordered]@{ Name = $name })

        $password = ""
        if (-not [string]::IsNullOrWhiteSpace($user)) {
            $password = Read-SecretPlain `
                -Prompt       "  Password/API token for '$user'" `
                -ContextTitle "Configuration/ProGet — Add Feed" `
                -ContextCurrent ([ordered]@{ Name = $name; User = $user })
        }

        $feeds.Add(@{ Name = $name; User = $user.Trim(); Password = $password.Trim() }) | Out-Null
        Write-Host "  ✓ Feed '$name' added to the list" -ForegroundColor Green
    }

    # ── Edit ─────────────────────────────────────────────────────
    elseif ($choice -like "edit:*") {
        $editName = $choice -replace '^edit:', ''
        $feed = $feeds | Where-Object { $_.Name -eq $editName } | Select-Object -First 1
        if (-not $feed) { continue }

        $editChoice = Read-SelectValue `
            -Title   "Edit: $editName" `
            -Options @(
                @{ Label = "Change credentials"; Value = "creds"  }
                @{ Label = "Rename";              Value = "rename" }
                @{ Label = "Back";                Value = "back"   }
            ) `
            -Default 0 `
            -ContextTitle   "Configuration/ProGet — Edit Feed" `
            -ContextCurrent ([ordered]@{
                Name = $feed.Name
                Auth = if ([string]::IsNullOrWhiteSpace($feed.User)) { "anonymous" } else { "user: $($feed.User)" }
            })

        switch ($editChoice) {
            "creds" {
                $newUser = Read-Plain `
                    -Prompt       "  User for '$editName' (Enter for an anonymous/public feed)" `
                    -Default      $feed.User `
                    -ContextTitle "Configuration/ProGet — Edit Feed" `
                    -ContextCurrent ([ordered]@{ Name = $editName })

                if ([string]::IsNullOrWhiteSpace($newUser)) {
                    $feed['User']     = ""
                    $feed['Password'] = ""
                } else {
                    $newPassword = Read-SecretPlain `
                        -Prompt       "  Password/API token for '$newUser' (Enter to keep current)" `
                        -ContextTitle "Configuration/ProGet — Edit Feed" `
                        -ContextCurrent ([ordered]@{ Name = $editName; User = $newUser })
                    $feed['User'] = $newUser.Trim()
                    if (-not [string]::IsNullOrWhiteSpace($newPassword)) {
                        $feed['Password'] = $newPassword.Trim()
                    }
                    # else: keep whatever password is already on the feed
                    # (seeded from the vault above, or entered earlier this run)
                }
                Write-Host "  ✓ Credentials updated for '$editName'" -ForegroundColor Green
            }
            "rename" {
                $newNameRaw = Read-Plain `
                    -Prompt       "New name for '$editName'" `
                    -ContextTitle "Configuration/ProGet — Rename Feed" `
                    -ContextCurrent ([ordered]@{ Current_Name = $editName })
                if ([string]::IsNullOrWhiteSpace($newNameRaw)) { break }
                $newName = $newNameRaw.Trim()
                if ($feeds | Where-Object { $_.Name -eq $newName -and $_.Name -ne $editName }) {
                    Write-Host "  Name '$newName' already exists." -ForegroundColor Yellow; break
                }
                $feed['Name'] = $newName
                Write-Host "  ✓ Renamed: '$editName' → '$newName'" -ForegroundColor Green
            }
        }
    }

    # ── Delete ───────────────────────────────────────────────────
    elseif ($choice -like "delete:*") {
        $delName = $choice -replace '^delete:', ''
        $confirm = Read-YesNo `
            -Title      "Remove feed '$delName' from the list?" `
            -DefaultYes $false `
            -ContextTitle "Configuration/ProGet — Delete Feed" `
            -ContextHint  "Removes the feed from the installer. An existing imagePullSecret/ConfigMap in the cluster is NOT automatically deleted." `
            -ContextCurrent ([ordered]@{ Name = $delName })
        if ($confirm) {
            $toRemove = $feeds | Where-Object { $_.Name -eq $delName } | Select-Object -First 1
            $feeds.Remove($toRemove) | Out-Null
            Write-Host "  ✓ '$delName' removed" -ForegroundColor Green
        }
    }
}

if ($feeds.Count -eq 0) { return @{} }

# Persist non-secret feed metadata (Name/User only) so the next run can seed
# the Edit/Delete menu — passwords stay in the cluster secret store and are
# re-fetched from there above, never written to this file.
@{ Feeds = @($feeds | ForEach-Object { @{ Name = $_.Name; User = $_.User } }) } |
    ConvertTo-Json -Depth 5 | Set-Content $stateFile

return @{ RegistryUrl = $registryUrl; Feeds = $feeds.ToArray() }
