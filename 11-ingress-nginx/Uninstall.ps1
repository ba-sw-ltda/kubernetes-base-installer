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

$verbose = $VerbosePreference -eq 'Continue'
$release = "ingress-nginx"

# Don't assume the release's namespace — pre-rename installs on some clusters
# (e.g. live RKE2, confirmed 2026-09-05) still have it in the legacy
# "ingress-nginx" namespace, not today's product-neutral "ingress"
# (see project_rke2_ingress_namespace_mismatch memory). Hardcoding "ingress"
# here silently no-ops the whole uninstall when the release lives elsewhere.
$existingJson = & helm list -A --filter "^$release$" -o json 2>&1
$existing = $null
if ($LASTEXITCODE -eq 0 -and $existingJson) {
    $existing = ($existingJson | ConvertFrom-Json) | Select-Object -First 1
}
if (-not $existing) { exit 0 }
$namespace = $existing.namespace

# Own Start-Group/Complete-Group, not the caller's — this script runs as the
# very first action inside the installing controller's own "Preparation"
# group, and previously printed flat, ungrouped Write-Host lines there. That
# squeezed a plain-text removal step underneath the parent's "▸ Preparation"
# header with no group marker of its own, reading as mis-nested (confirmed
# live 2026-09-05, user-flagged). Opening/closing a group here instead — and
# calling this script before the caller opens "Preparation" (see
# 11-ingress-traefik/Install.ps1) — makes the switch its own clean step.
Start-Group -Title "Switching ingress controller (removing NGINX)"

$exitCode = Invoke-WithSpinner -Message "Uninstalling NGINX Ingress Controller..." -Executable "helm" `
    -Arguments @("uninstall", $release, "-n", $namespace) -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to uninstall NGINX Ingress Controller"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Waiting for cleanup..." -Executable "kubectl" `
    -Arguments @("wait", "--for=delete", "service/ingress-nginx-controller", "-n", $namespace, "--timeout=2m") `
    -ShowOutput:$verbose
# exit code non-zero = service already gone, that's fine

Complete-Group
