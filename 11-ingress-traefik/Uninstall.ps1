<#
.SYNOPSIS
    Uninstall Traefik Ingress Controller if present.
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param([string]$Platform)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'
$release = "traefik"

# Same reasoning as 11-ingress-nginx/Uninstall.ps1 — resolve the release's
# real namespace instead of assuming "ingress", so this stays correct even
# against a legacy/pre-rename layout.
$existingJson = & helm list -A --filter "^$release$" -o json 2>&1
$existing = $null
if ($LASTEXITCODE -eq 0 -and $existingJson) {
    $existing = ($existingJson | ConvertFrom-Json) | Select-Object -First 1
}
if (-not $existing) { exit 0 }
$namespace = $existing.namespace

# See 11-ingress-nginx/Uninstall.ps1 for why this owns its own group instead
# of printing flat Write-Host lines — same fix, mirrored.
Start-Group -Title "Switching ingress controller (removing Traefik)"

$exitCode = Invoke-WithSpinner -Message "Uninstalling Traefik..." -Executable "helm" `
    -Arguments @("uninstall", $release, "-n", $namespace) -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to uninstall Traefik"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Waiting for cleanup..." -Executable "kubectl" `
    -Arguments @("wait", "--for=delete", "service/traefik", "-n", $namespace, "--timeout=2m") `
    -ShowOutput:$verbose
# exit code non-zero = service already gone, that's fine

Complete-Group
