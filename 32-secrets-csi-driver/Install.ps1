<#
.SYNOPSIS
    Install Secrets Store CSI Driver — mounts vault secrets directly into pods as files.
    No Kubernetes Secrets created, nothing stored in etcd.
    Platform-specific vault provider is installed by the vault backend component (33-*).
.PARAMETER Platform
    Target platform
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$ConfigPath
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose    = $VerbosePreference -eq 'Continue'
$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath
$ChartName  = $FullConfig.ChartName
$ChartVersion = $FullConfig.Version
$Repository = $FullConfig.Repository
$Namespace  = $FullConfig.Namespace
$UserConfig = $FullConfig.UserConfig

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 32 - Secrets Store CSI Driver" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "  Chart:    $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Strategy: File-mount only (no K8s Secrets, no etcd)" -ForegroundColor Gray
Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "secrets-store-csi-driver", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

$HelmArgs = @(
    "upgrade", "--install", "secrets-store-csi-driver",
    "secrets-store-csi-driver/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "syncSecret.enabled=$($UserConfig.SyncSecret.ToString().ToLower())",
    "--set", "enableSecretRotation=true",
    "--set", "rotationPollInterval=$($UserConfig.RotationPollInterval)"
)

Reset-StuckHelmRelease -ReleaseName "secrets-store-csi-driver" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying Secrets Store CSI Driver..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Secrets Store CSI Driver (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for CSI Driver DaemonSet..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "daemonset/secrets-store-csi-driver",
                 "-n", $Namespace, "--timeout=5m") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "CSI Driver DaemonSet did not become ready"; exit 1 }
Write-Host "  ✓ Secrets Store CSI Driver ready" -ForegroundColor Green

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Secrets are mounted as files — not stored in etcd." -ForegroundColor Gray
Write-Host "  Each component creates its own SecretProviderClass." -ForegroundColor Gray
Write-Host "  Vault provider is installed by the 33-* component." -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
