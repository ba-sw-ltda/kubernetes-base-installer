<#
.SYNOPSIS
    Collect Grafana settings upfront.
.PARAMETER Platform
    Target platform
.PARAMETER Domain
    Cluster domain (from Install-Base.ps1)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'AdminPassword',
    Justification = 'Helm --set requires plain text; password is not logged or stored')]
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Domain = "kubernetes.local"
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$defaultHostname = "grafana.$Domain"

$hostname = Read-Plain `
    -Prompt "Grafana hostname" `
    -Default $defaultHostname `
    -ContextTitle "Grafana" `
    -ContextHint "DNS name under which Grafana will be reachable" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; Domain = $Domain })

do {
    $adminPassword = Read-SecretPlainConfirm `
        -Prompt1 "Grafana admin password (min. 8 chars)" `
        -Prompt2 "Confirm admin password" `
        -ContextTitle "Grafana" `
        -ContextHint "Password for the 'admin' user" `
        -ContextCurrent ([ordered]@{ Platform = $Platform; Hostname = $hostname })
    if ($adminPassword.Length -lt 8) {
        Write-Host "  Password must be at least 8 characters." -ForegroundColor Red
    }
} while ($adminPassword.Length -lt 8)

return @{
    Hostname      = $hostname.Trim()
    AdminPassword = $adminPassword.Trim()
}
