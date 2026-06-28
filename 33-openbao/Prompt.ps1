<#
.SYNOPSIS
    Collect OpenBao settings upfront.
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

$defaultHostname = "vault.$Domain"

$hostname = Read-Plain `
    -Prompt "OpenBao UI hostname" `
    -Default $defaultHostname `
    -ContextTitle "Security/OpenBao — $Platform" `
    -ContextHint "DNS name under which the OpenBao UI will be reachable" `
    -ContextCurrent ([ordered]@{ Domain = $Domain })

return @{ Hostname = $hostname.Trim(); Domain = $Domain }
