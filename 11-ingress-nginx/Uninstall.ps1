<#
.SYNOPSIS
    Uninstall NGINX Ingress Controller if present.
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param([string]$Platform)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose   = $VerbosePreference -eq 'Continue'
$namespace = "ingress-nginx"
$release   = "ingress-nginx"

$existing = & helm list -n $namespace --filter "^$release$" --short 2>&1
if (-not $existing) { exit 0 }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Removing: NGINX Ingress Controller" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$exitCode = Invoke-WithSpinner -Message "Uninstalling NGINX Ingress Controller..." -Executable "helm" `
    -Arguments @("uninstall", $release, "-n", $namespace) -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to uninstall NGINX Ingress Controller"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Waiting for cleanup..." -Executable "kubectl" `
    -Arguments @("wait", "--for=delete", "service/ingress-nginx-controller", "-n", $namespace, "--timeout=2m") `
    -ShowOutput:$verbose
# exit code non-zero = service already gone, that's fine
Write-Host "  ✓ NGINX Ingress Controller removed" -ForegroundColor Green
