<#
.SYNOPSIS
    Install Grafana Tempo Distributed (trace backend)
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
Write-Host "  Installing: 64 - Tempo Distributed" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName    = $FullConfig.ChartName
$ChartVersion = $FullConfig.Version
$Repository   = $FullConfig.Repository
$Namespace    = $FullConfig.Namespace
$UserConfig   = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Retention:  $($UserConfig.Retention)" -ForegroundColor Gray
Write-Host "  Storage:    $($UserConfig.StorageSize)" -ForegroundColor Gray
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
    "upgrade", "--install", "--force", "tempo", "grafana/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,

    # Single-replica for all components (minimal / dev setup)
    "--set", "distributor.replicas=1",
    "--set", "ingester.replicas=1",
    "--set", "querier.replicas=1",
    "--set", "queryFrontend.replicas=1",
    "--set", "compactor.replicas=1",

    # Disable components not needed for single-node use
    "--set", "gateway.enabled=false",
    "--set", "memcached.enabled=false",
    "--set", "metricsGenerator.enabled=false",

    # Local trace storage
    "--set", "tempo.storage.trace.backend=local",
    "--set", "tempo.storage.trace.local.path=/var/tempo/traces",

    # Retention via compactor
    "--set", "tempo.compactor.compaction.block_retention=$($UserConfig.Retention)",

    # Ingester persistence (the only StatefulSet in the chart)
    "--set", "ingester.persistence.enabled=true",
    "--set", "ingester.persistence.size=$($UserConfig.StorageSize)",

    # Resource limits on ingester (stateful, most memory-sensitive)
    "--set", "ingester.resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "ingester.resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "ingester.resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "ingester.resources.requests.memory=$($UserConfig.Resources.Requests.Memory)"
)

Reset-StuckHelmRelease -ReleaseName "tempo" -Namespace $Namespace

# If the old single-binary tempo StatefulSet exists, remove it first — the
# distributed chart uses a different StatefulSet name (tempo-ingester).
& kubectl get statefulset tempo -n $Namespace 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    $exitCode = Invoke-WithSpinner -Message "Removing old single-binary StatefulSet..." -Executable "kubectl" `
        -Arguments @("delete", "statefulset", "tempo", "-n", $Namespace, "--ignore-not-found") -ShowOutput:$verbose
}

$exitCode = Invoke-WithSpinner -Message "Deploying Tempo Distributed..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Tempo Distributed (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for ingester..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "statefulset/tempo-ingester", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of tempo-ingester did not complete"; exit 1 }

foreach ($dep in @("tempo-distributor", "tempo-querier", "tempo-query-frontend", "tempo-compactor")) {
    $exitCode = Invoke-WithSpinner -Message "Waiting for $dep..." -Executable "kubectl" `
        -Arguments @("rollout", "status", "deployment/$dep", "-n", $Namespace, "--timeout=5m") `
        -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Rollout of $dep did not complete"; exit 1 }
}
Write-Host "  ✓ Tempo Distributed ready" -ForegroundColor Green

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  OTLP gRPC (cluster-internal):" -ForegroundColor Gray
Write-Host "    tempo-distributor.${Namespace}:4317" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Grafana datasource URL:" -ForegroundColor Gray
Write-Host "    http://tempo-query-frontend.${Namespace}:3200" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
