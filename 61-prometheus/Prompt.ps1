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

$hostname = Read-Plain `
    -Prompt "Prometheus hostname" `
    -Default $defaultHostname `
    -ContextTitle "Prometheus" `
    -ContextHint "DNS name under which Prometheus will be reachable" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; Domain = $Domain })

return @{ Hostname = $hostname.Trim() }
