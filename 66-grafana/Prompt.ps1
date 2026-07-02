<#
.SYNOPSIS
    Collect Grafana settings upfront.
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

$defaultHostname = "grafana.$Domain"

$hostname = Read-Plain `
    -Prompt "Grafana hostname" `
    -Default $defaultHostname `
    -ContextTitle "66 - Observability - Grafana" `
    -ContextHint "DNS name under which Grafana will be reachable" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; Domain = $Domain })

return @{
    Hostname = $hostname.Trim()
}
