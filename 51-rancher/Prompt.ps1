<#
.SYNOPSIS
    Collect Rancher settings upfront.
.PARAMETER Platform
    Target platform
.PARAMETER Domain
    Cluster domain (from Install-Base.ps1)
.PARAMETER BootstrapPassword
    Pre-fill bootstrap password (skip prompt — for dev/test only)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'BootstrapPassword',
    Justification = 'Dev/test pre-fill only — remove before production use')]
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Domain = "kubernetes.local",
    [string]$BootstrapPassword = ""
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$mode = Read-SelectValue `
    -Title "Management Mode" `
    -Message "Install full Rancher Server or import this cluster into an existing Rancher?" `
    -Options @(
        @{ Label = "Rancher Server  (install full Rancher on this cluster)"; Value = "Full" }
        @{ Label = "Rancher Agent   (import this cluster into existing Rancher)"; Value = "Agent" }
    ) `
    -Default 0 `
    -ContextTitle "Management" `
    -ContextHint "Full = Rancher UI runs here. Agent = cluster is registered in an external Rancher." `
    -ContextCurrent ([ordered]@{ Platform = $Platform })

if (-not $mode) { return $null }

if ($mode -eq "Agent") {
    $registrationUrl = Read-Plain `
        -Prompt "Rancher registration URL" `
        -ContextTitle "Rancher Agent" `
        -ContextHint "In Rancher UI: Import Existing → Generic → Create → copy the URL ending in .yaml" `
        -ContextCurrent ([ordered]@{ Platform = $Platform })
    return @{ ManagementMode = "Agent"; RegistrationUrl = $registrationUrl.Trim() }
}

# Full Rancher Server
$defaultHostname = "rancher.$Domain"
$hostname = Read-Plain `
    -Prompt "Rancher hostname" `
    -Default $defaultHostname `
    -ContextTitle "Rancher Server" `
    -ContextHint "DNS name under which Rancher will be reachable — must resolve to your ingress IP" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; Domain = $Domain })

if ([string]::IsNullOrWhiteSpace($BootstrapPassword)) {
    $BootstrapPassword = Read-SecretPlainConfirm `
        -Prompt1 "Bootstrap admin password (min. 12 chars)" `
        -Prompt2 "Confirm bootstrap password" `
        -ContextTitle "Rancher Server" `
        -ContextHint "Initial password for the 'admin' user — change it after first login" `
        -ContextCurrent ([ordered]@{ Platform = $Platform; Hostname = $hostname })
}

return @{
    ManagementMode    = "Full"
    Hostname          = $hostname.Trim()
    BootstrapPassword = $BootstrapPassword.Trim()
}
