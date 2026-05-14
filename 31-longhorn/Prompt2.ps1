<#
.SYNOPSIS
    Phase 2 — configuration: Longhorn UI hostname (only if ExposeUi = true).
.PARAMETER Platform
    Target platform
.PARAMETER Domain
    Cluster domain (from Install-Base.ps1)
.PARAMETER ExposeUi
    Result from Phase 1 Prompt.ps1
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Domain   = "kubernetes.local",
    [bool]$ExposeUi   = $true
)

if (-not $ExposeUi) { return @{} }

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$defaultHostname = "longhorn.$Domain"

$hostname = Read-Plain `
    -Prompt "Longhorn UI hostname" `
    -Default $defaultHostname `
    -ContextTitle "Longhorn Storage" `
    -ContextHint "DNS name under which the Longhorn dashboard will be reachable" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; Domain = $Domain })

return @{ Hostname = $hostname.Trim() }
