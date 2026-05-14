<#
.SYNOPSIS
    Collect MetalLB inputs upfront (called by Install-Base.ps1 before installation starts).
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param(
    [string]$Platform
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

# Only RKE2 needs manual input — Kind auto-detects
if ($Platform -ne "RKE2 (On-Premise)") { return @{} }

# Gespeicherte IP aus State-File als Default vorschlagen
$savedIp = $null
$stateFile = Join-Path $BaseDir ".rke2-state.json"
if (Test-Path $stateFile) {
    $state = Get-Content $stateFile | ConvertFrom-Json
    $savedIp = $state.LoadBalancerIP
}

$nginxIp = Read-Plain `
    -Prompt "nginx LoadBalancer IP" `
    -Default $savedIp `
    -ContextTitle "MetalLB - RKE2 (On-Premise)" `
    -ContextHint "The IP your wildcard DNS (*.kubernetes.example.com) points to" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; Saved = if ($savedIp) { $savedIp } else { "—" } })

if ([string]::IsNullOrWhiteSpace($nginxIp)) {
    Write-Error "nginx LoadBalancer IP is required for RKE2."
    exit 1
}

return @{ NginxIp = $nginxIp.Trim() }
