<#
.SYNOPSIS
    Collect Rancher registration URL for cluster import.
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param([string]$Platform)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$registrationUrl = Read-Plain `
    -Prompt "Rancher registration URL" `
    -ContextTitle "Rancher/Agent — $Platform" `
    -ContextHint "In Rancher UI: Import Existing → Generic → Create → copy the URL ending in .yaml"

if ([string]::IsNullOrWhiteSpace($registrationUrl)) {
    Write-Host "  No URL entered — Rancher Agent will be skipped." -ForegroundColor Yellow
    return @{ RegistrationUrl = "" }
}

return @{ RegistrationUrl = $registrationUrl.Trim() }
