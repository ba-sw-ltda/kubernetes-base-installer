<#
.SYNOPSIS
    Collect Prometheus settings upfront.
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

$defaultHostname = "prometheus.$Domain"

# --- Pre-fill from the live Helm release (if one already exists) -----------
# Re-running this prompt shouldn't force re-typing every receiver from
# scratch, nor risk landing on an empty list and silently disabling
# Alertmanager on the next Install.ps1 run (see its $alertmanagerEnabled
# gate). The already-applied Helm values are the single source of truth for
# what's actually running — no separate state file to drift out of sync —
# parsed back out of the exact structure Install.ps1 itself generates
# (receiver named 'notifications', email_configs[].to, msteams_configs[].
# webhook_url, global.smtp_*). Falls back to empty on a fresh install, or if
# helm/the cluster isn't reachable yet — same as before this existed.
$existingReceivers = [System.Collections.Generic.List[hashtable]]::new()
$existingSmtp = $null
try {
    $namespace = "prometheus"
    try {
        $cfg = Import-PowerShellDataFile "$PSScriptRoot\Config.psd1"
        if ($cfg.Namespace) { $namespace = $cfg.Namespace }
    } catch {}

    $existingValuesJson = & helm get values prometheus -n $namespace -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingValuesJson)) {
        $amConfig = ($existingValuesJson | ConvertFrom-Json).alertmanager.config
        $notif = $amConfig.receivers | Where-Object { $_.name -eq 'notifications' }
        if ($notif) {
            foreach ($e in @($notif.email_configs)) {
                if ($e.to) { $existingReceivers.Add(@{ Type = "Email"; Target = $e.to }) | Out-Null }
            }
            foreach ($t in @($notif.msteams_configs)) {
                if ($t.webhook_url) { $existingReceivers.Add(@{ Type = "Teams"; Target = $t.webhook_url }) | Out-Null }
            }
        }
        if ($amConfig.global -and $amConfig.global.smtp_smarthost) {
            $existingSmtp = @{
                Host       = $amConfig.global.smtp_smarthost
                From       = $amConfig.global.smtp_from
                User       = $amConfig.global.smtp_auth_username
                Password   = $amConfig.global.smtp_auth_password
                RequireTls = if ($null -ne $amConfig.global.smtp_require_tls) { [bool]$amConfig.global.smtp_require_tls } else { $true }
            }
        }
    }
} catch {
    # First install, helm not reachable yet, or an unrecognized values
    # shape — fall back to empty, same as before this existed.
}

if ($existingReceivers.Count -gt 0) {
    Write-Host "  · Found $($existingReceivers.Count) existing receiver(s) in the current Alertmanager config — edit/delete below as needed" -ForegroundColor DarkGray
}

$hostname = Read-Plain `
    -Prompt "Prometheus hostname" `
    -Default $defaultHostname `
    -ContextTitle "Observability/Prometheus — $Platform" `
    -ContextHint "DNS name under which Prometheus will be reachable" `
    -ContextCurrent ([ordered]@{ Domain = $Domain })

# --- Alertmanager receivers -------------------------------------------------
# Add/Edit/Delete management loop — same UX as 33-openbao's PKI list, so a
# typo (or a change of mind on the type) doesn't force restarting the whole
# installer. Alertmanager itself stays disabled until at least one receiver
# remains here (see 61-prometheus/Install.ps1) — same "empty = the legitimate
# no-op answer" contract as 43-proget-registry's $Feeds.
$receivers = $existingReceivers

function Get-ReceiverSummary {
    param([System.Collections.Generic.List[hashtable]]$Receivers)
    $ctx = [ordered]@{}
    if ($Receivers.Count -eq 0) {
        $ctx["Receivers"] = "(none defined — Alertmanager stays disabled)"
    } else {
        foreach ($r in $Receivers) { $ctx["$($r.Type): $($r.Target)"] = "" }
    }
    return $ctx
}

$typeOptions = @(
    @{ Label = "Email"; Value = "Email" }
    @{ Label = "Microsoft Teams"; Value = "Teams" }
)

$continueLoop = $true
while ($continueLoop) {
    $menuOptions = [System.Collections.Generic.List[hashtable]]::new()
    $menuOptions.Add(@{ Label = "Done — apply receivers"; Value = "done" }) | Out-Null
    $menuOptions.Add(@{ Label = "Add receiver";           Value = "add"  }) | Out-Null
    for ($i = 0; $i -lt $receivers.Count; $i++) {
        $r = $receivers[$i]
        $menuOptions.Add(@{ Label = "Edit:   $($r.Type) — $($r.Target)"; Value = "edit:$i"   }) | Out-Null
        $menuOptions.Add(@{ Label = "Delete: $($r.Type) — $($r.Target)"; Value = "delete:$i" }) | Out-Null
    }

    $choice = Read-SelectValue `
        -Title   "Alerting" `
        -Message "Configure Alertmanager alert receivers (email / Microsoft Teams)" `
        -Options $menuOptions `
        -Default 0 `
        -ContextTitle "Observability/Prometheus — $Platform" `
        -ContextHint "Leave the list empty to keep Alertmanager disabled — no receivers means nothing to send alerts to" `
        -ContextCurrent (Get-ReceiverSummary -Receivers $receivers)

    if ($null -eq $choice -or $choice -eq "done") { $continueLoop = $false; break }

    # ── Add ──────────────────────────────────────────────────────
    if ($choice -eq "add") {
        $type = Read-SelectValue `
            -Title   "Alerting" `
            -Message "Receiver type" `
            -Options $typeOptions `
            -Default 0 `
            -ContextTitle "Observability/Prometheus — Add Receiver" `
            -ContextCurrent (Get-ReceiverSummary -Receivers $receivers)
        if ($null -eq $type) { continue }

        if ($type -eq "Email") {
            $target = Read-Plain `
                -Prompt "  Email address to notify" `
                -ContextTitle "Observability/Prometheus — Add Receiver" `
                -ContextHint "Delivered via the SMTP relay configured next" `
                -ContextCurrent ([ordered]@{ Receiver = "New (Email)" })
        } else {
            $target = Read-Plain `
                -Prompt "  Microsoft Teams webhook URL" `
                -ContextTitle "Observability/Prometheus — Add Receiver" `
                -ContextHint "Teams channel -> Workflows app -> 'Post to a channel when a webhook request is received' -> copy the generated URL (the legacy O365 Connectors webhook was retired)" `
                -ContextCurrent ([ordered]@{ Receiver = "New (Teams)" })
        }

        if ([string]::IsNullOrWhiteSpace($target)) {
            Write-Host "  (empty — not added)" -ForegroundColor Gray
            continue
        }

        $receivers.Add(@{ Type = $type; Target = $target.Trim() }) | Out-Null
        Write-Host "  ✓ $type receiver added" -ForegroundColor Green
    }

    # ── Edit ─────────────────────────────────────────────────────
    elseif ($choice -like "edit:*") {
        $idx = [int]($choice -replace '^edit:', '')
        if ($idx -lt 0 -or $idx -ge $receivers.Count) { continue }
        $r = $receivers[$idx]

        $editChoice = Read-SelectValue `
            -Title   "Edit: $($r.Type) — $($r.Target)" `
            -Options @(
                @{ Label = "Change target"; Value = "target" }
                @{ Label = "Change type";   Value = "type"   }
                @{ Label = "Back";          Value = "back"   }
            ) `
            -Default 0 `
            -ContextTitle "Observability/Prometheus — Edit Receiver" `
            -ContextCurrent ([ordered]@{ Type = $r.Type; Target = $r.Target })

        switch ($editChoice) {
            "target" {
                $prompt = if ($r.Type -eq "Email") { "  Email address to notify" } else { "  Microsoft Teams webhook URL" }
                $newTarget = Read-Plain `
                    -Prompt $prompt `
                    -Default $r.Target `
                    -ContextTitle "Observability/Prometheus — Edit Receiver" `
                    -ContextCurrent ([ordered]@{ Type = $r.Type })
                if (-not [string]::IsNullOrWhiteSpace($newTarget)) {
                    $r['Target'] = $newTarget.Trim()
                    Write-Host "  ✓ Target updated" -ForegroundColor Green
                }
            }
            "type" {
                $newType = Read-SelectValue `
                    -Title   "Receiver type" `
                    -Options $typeOptions `
                    -Default 0 `
                    -ContextTitle "Observability/Prometheus — Edit Receiver" `
                    -ContextCurrent ([ordered]@{ Target = $r.Target })
                if ($newType) {
                    $r['Type'] = $newType
                    Write-Host "  ✓ Type changed to $newType" -ForegroundColor Green
                }
            }
        }
    }

    # ── Delete ───────────────────────────────────────────────────
    elseif ($choice -like "delete:*") {
        $idx = [int]($choice -replace '^delete:', '')
        if ($idx -lt 0 -or $idx -ge $receivers.Count) { continue }
        $r = $receivers[$idx]
        $confirm = Read-YesNo `
            -Title      "Remove receiver '$($r.Type): $($r.Target)'?" `
            -DefaultYes $false `
            -ContextTitle "Observability/Prometheus — Delete Receiver"
        if ($confirm) {
            $receivers.RemoveAt($idx)
            Write-Host "  ✓ Removed" -ForegroundColor Green
        }
    }
}

# --- SMTP relay (only needed if at least one Email receiver was added) -----
$smtp = @{}
if (@($receivers | Where-Object { $_.Type -eq "Email" }).Count -gt 0) {
    $smtpHostDefault = if ($existingSmtp -and $existingSmtp.Host) { $existingSmtp.Host } else { "smtp.$Domain:587" }
    $smtpHost = Read-Plain `
        -Prompt "SMTP relay host:port" `
        -Default $smtpHostDefault `
        -ContextTitle "Observability/Prometheus — $Platform" `
        -ContextHint "Outbound mail relay Alertmanager will use to send the email alerts above"

    $smtpFromDefault = if ($existingSmtp -and $existingSmtp.From) { $existingSmtp.From } else { "alertmanager@$Domain" }
    $smtpFrom = Read-Plain `
        -Prompt "  From address" `
        -Default $smtpFromDefault `
        -ContextTitle "Observability/Prometheus — $Platform"

    $smtpUserDefault = if ($existingSmtp -and $existingSmtp.User) { $existingSmtp.User } else { "" }
    $smtpUser = Read-Plain `
        -Prompt "  SMTP username (Enter if the relay needs no auth)" `
        -Default $smtpUserDefault `
        -ContextTitle "Observability/Prometheus — $Platform"

    $smtpPassword = ""
    if (-not [string]::IsNullOrWhiteSpace($smtpUser)) {
        # Same user as before -> a blank answer keeps the existing password
        # instead of forcing a re-type of a credential that already works.
        # A different (or newly-added) user always needs its own password.
        $keepsExistingUser = $existingSmtp -and $existingSmtp.Password -and ($smtpUser -eq $existingSmtp.User)
        $passwordPrompt = if ($keepsExistingUser) { "  SMTP password (Enter to keep the existing password)" } else { "  SMTP password" }
        $smtpPassword = Read-SecretPlain `
            -Prompt $passwordPrompt `
            -ContextTitle "Observability/Prometheus — $Platform" `
            -ContextCurrent ([ordered]@{ "SMTP user" = $smtpUser })
        if ([string]::IsNullOrWhiteSpace($smtpPassword) -and $keepsExistingUser) {
            $smtpPassword = $existingSmtp.Password
        }
    }

    $requireTlsDefault = if ($existingSmtp) { $existingSmtp.RequireTls } else { $true }
    $requireTls = Read-YesNo `
        -Title "Alerting" `
        -Message "Require STARTTLS for the SMTP connection?" `
        -DefaultYes $requireTlsDefault `
        -ContextTitle "Observability/Prometheus — $Platform"

    $smtp = @{
        Host       = $smtpHost.Trim()
        From       = $smtpFrom.Trim()
        User       = $smtpUser.Trim()
        Password   = $smtpPassword.Trim()
        RequireTls = $requireTls
    }
}

return @{
    Hostname  = $hostname.Trim()
    Receivers = $receivers.ToArray()
    Smtp      = $smtp
}
