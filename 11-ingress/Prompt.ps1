<#
.SYNOPSIS
    Collect ingress controller selection upfront.
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param([string]$Platform)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$choice = Read-SelectValue `
    -Title "Select Ingress Controller" `
    -Message "Choose the ingress controller for your cluster" `
    -Options @(
        @{ Label = "NGINX    (most widely used, community-maintained)"; Value = "nginx" }
        @{ Label = "Traefik  (built-in dashboard, dynamic configuration)"; Value = "traefik" }
    ) `
    -Default 0 `
    -ContextTitle "Ingress — $Platform"

if (-not $choice) {
    Write-Error "Ingress controller selection is required."
    exit 1
}

return @{ IngressController = $choice }
