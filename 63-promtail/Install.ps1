<#
.SYNOPSIS
    Install Promtail (log shipper → Loki)
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

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 63 - Promtail" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName    = $FullConfig.ChartName
$ChartVersion = $FullConfig.Version
$Repository   = $FullConfig.Repository
$Namespace    = $FullConfig.Namespace
$UserConfig   = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Loki URL:   $($UserConfig.LokiUrl)" -ForegroundColor Gray
Write-Host ""

& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-Host "  ✓ Namespace ready" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "grafana", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

$HelmArgs = @(
    "upgrade", "--install", "--force", "promtail", "grafana/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "config.clients[0].url=$($UserConfig.LokiUrl)",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)"
)

Reset-StuckHelmRelease -ReleaseName "promtail" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying Promtail..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Promtail (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for promtail..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "daemonset/promtail", "-n", $Namespace, "--timeout=10m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of Promtail did not complete"; exit 1 }
Write-Host "  ✓ Promtail ready" -ForegroundColor Green

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace -l app.kubernetes.io/name=promtail
}

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Promtail ships all pod logs to Loki." -ForegroundColor Gray
Write-Host "  Logs are queryable in Grafana via the Loki datasource." -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
