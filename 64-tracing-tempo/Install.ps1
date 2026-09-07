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

$extraArgs = if ($verbose) { @{ Verbose = $true } } else { @{} }

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

Start-Group -Title "Preparation"

& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-GroupLine "✓ Namespace ready" -ForegroundColor Green

$otherUninstall = Join-Path $BaseDir "64-tracing-jaeger\Uninstall.ps1"
if (Test-Path $otherUninstall) { & $otherUninstall -Platform $Platform @extraArgs }

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "grafana", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }

Complete-Group
Start-Group -Title "Deploy"

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
    "--set", "ingester.resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",

    # Prometheus scraping — this chart's toggle lives under metaMonitoring,
    # NOT monitoring.serviceMonitor like Loki's chart. release=prometheus is
    # the repo-wide label convention the Prometheus Operator release-scoped
    # selector requires (see 62-loki/Install.ps1).
    "--set", "metaMonitoring.serviceMonitor.enabled=true",
    "--set", "metaMonitoring.serviceMonitor.labels.release=prometheus"
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

Complete-Group

if ($FullConfig.RancherProject) {
    Start-Group -Title "Rancher"
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
    Write-GroupLine "✓ Assigned to Rancher project '$($FullConfig.RancherProject)'" -ForegroundColor Green
    Complete-Group
}

# Official Tempo mixin "operational" dashboard (grafana/tempo repo,
# operations/tempo-mixin-compiled) — single all-in-one view of
# distributor/ingester/compactor/querier/query-frontend health, matching
# this repo's one-dashboard-per-component convention. Its cluster/namespace
# template variables come from Grafana Labs' internal multi-tenant mixin
# convention (label_values(tempo_build_info, cluster)); on this single-
# cluster deployment tempo_build_info won't carry a "cluster" label, so
# expect those dropdowns to resolve empty rather than populate like a
# multi-tenant install — panels should still render since Prometheus
# treats a missing label as an empty-string match. Not yet verified against
# live data (ServiceMonitor isn't deployed yet).
Start-Group -Title "Monitoring"
Register-GrafanaDashboard -Namespace $Namespace -Name "tempo" -JsonPath "$ScriptRoot\dashboards\tempo.json" -Folder "Observability"
Complete-Group

Start-Group -Title "Network Policy"

Install-NetworkPolicyBaseline -Namespace $Namespace
# This provider-ingress rule covers the whole tempo namespace (podSelector:
# {}), which fronts several distinct Services with different real listen
# ports depending on who's talking to what: Grafana's Tempo datasource hits
# tempo-query-frontend:3200 (see 66-grafana/Config.psd1's TempoUrl), while
# opentelemetry-collector's trace-export egress targets tempo-distributor.
# NOTE: as of 2026-08-20 on Magalu, tempo-distributor's live pod does NOT
# expose 4317 (OTLP gRPC) at all — only http-metrics/3200 and grpc/9095 —
# meaning this chart's OTLP receiver isn't enabled, a separate Helm-values
# gap unrelated to NetworkPolicy ports; Resolve-ServiceRealPorts intentionally
# won't invent a phantom 4317 entry the way the old hardcoded list did.
# The Tempo ServiceMonitor (metaMonitoring.serviceMonitor, enabled above)
# creates one ServiceMonitor per component, each scraping its own Service's
# "http-metrics" port — compactor/ingester/querier weren't previously in
# this allow-list (only query-frontend and distributor were, for Grafana's
# datasource and the OTLP-export path respectively), so Prometheus would be
# silently blocked from scraping 3 of the 5 ServiceMonitor targets.
$tempoQueryFrontendPort = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "tempo-query-frontend" -ServicePortName "http-metrics"
$tempoDistributorPorts  = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "tempo-distributor"
$tempoCompactorPort     = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "tempo-compactor" -ServicePortName "http-metrics"
$tempoIngesterPort      = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "tempo-ingester" -ServicePortName "http-metrics"
$tempoQuerierPort       = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "tempo-querier" -ServicePortName "http-metrics"
$tempoPorts = @($tempoQueryFrontendPort + $tempoDistributorPorts + $tempoCompactorPort + $tempoIngesterPort + $tempoQuerierPort | Select-Object -Unique)
Set-NetworkPolicyProviderIngress -Namespace $Namespace -Port $tempoPorts
# Self-register as a Prometheus scrape target instead of Prometheus
# enumerating every ServiceMonitor'd namespace centrally (compliance finding
# #1 fix).
Set-NetworkPolicyConsumerEgress -Namespace "prometheus" -TargetNamespace $Namespace -Port $tempoPorts

Complete-Group

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
