<#
.SYNOPSIS
    Install cert-manager
.DESCRIPTION
    Installs cert-manager via Helm only — no ClusterIssuer here. For RKE2/Kind,
    33-openbao/Install.ps1 creates one ClusterIssuer per PKI (named
    "openbao-pki-<name>") once OpenBao's PKI engines are ready (cert-manager
    always installs first in the fixed order, so its CRDs/ServiceAccount already
    exist by then). Other platforms have no issuer yet — see Get-ClusterIssuerName.
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER Platform
    Target platform (Azure AKS, AWS EKS, Google GKE, RKE2, Kind)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Platform
)

$ScriptRoot = $PSScriptRoot
$BaseDir = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 31 - cert-manager" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName       = $FullConfig.ChartName
$ChartVersion    = $FullConfig.Version
$Repository      = $FullConfig.Repository
$Namespace       = $FullConfig.Namespace
$CreateNamespace = $FullConfig.CreateNamespace
$UserConfig      = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName $ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host ""

# Helm repository
$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "jetstack", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

# Namespace
if ($CreateNamespace) {
    & kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
    Write-Host "  ✓ Namespace ready" -ForegroundColor Green
}

# Deploy
$HelmArgs = @(
    "upgrade", "--install", "cert-manager", "jetstack/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "installCRDs=$($UserConfig.InstallCRDs.ToString().ToLower())",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)"
)

Reset-StuckHelmRelease -ReleaseName "cert-manager" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying cert-manager..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy cert-manager (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

# Wait for all three components
foreach ($dep in @("cert-manager", "cert-manager-cainjector", "cert-manager-webhook")) {
    $exitCode = Invoke-WithSpinner -Message "Waiting for $dep..." -Executable "kubectl" `
        -Arguments @("rollout", "status", "deployment/$dep", "-n", $Namespace, "--timeout=5m") `
        -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Rollout of $dep did not complete"; exit 1 }
    Write-Host "  ✓ $dep ready" -ForegroundColor Green
}

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace
}

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  No issuer yet — created later by 33-openbao/Install.ps1" -ForegroundColor Gray
Write-Host "  (RKE2/Kind: one ClusterIssuer per PKI, named 'openbao-pki-<name>')." -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
