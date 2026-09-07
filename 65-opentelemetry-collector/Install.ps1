<#
.SYNOPSIS
    Install OpenTelemetry Collector (receives OTLP, forwards to tracing backend)
.PARAMETER Platform
    Target platform
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER Enabled
    Whether to install the collector at all (from Prompt.ps1) — defaults to
    true for standalone runs.
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$ConfigPath,
    [bool]$Enabled = $true
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

if (-not $Enabled) { Write-Host "  Skipped — OpenTelemetry Collector declined." -ForegroundColor Gray; exit 0 }

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 65 - OpenTelemetry Collector" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName    = $FullConfig.ChartName
$ChartVersion = $FullConfig.Version
$Repository   = $FullConfig.Repository
$Namespace    = $FullConfig.Namespace
$UserConfig   = $FullConfig.UserConfig

# Auto-detect tracing backend: jaeger > tempo-distributed > tempo (legacy)
$tracingExporter  = "otlp/tempo"
$tracingEndpoint  = "tempo.tempo:4317"
$tracingNamespace = "tempo"
& kubectl get svc jaeger-collector -n jaeger 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    $tracingExporter  = "otlp/jaeger"
    $tracingEndpoint  = "jaeger-collector.jaeger:4317"
    $tracingNamespace = "jaeger"
} else {
    & kubectl get svc tempo-distributor -n tempo 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $tracingEndpoint = "tempo-distributor.tempo:4317"
    }
}

$prometheusUrl = $UserConfig.PrometheusRemoteWriteUrl
$lokiUrl       = $UserConfig.LokiOtlpUrl

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Traces  →   $tracingEndpoint" -ForegroundColor Gray
Write-Host "  Metrics →   prometheus.prometheus:9090" -ForegroundColor Gray
Write-Host "  Logs    →   loki.loki:3100" -ForegroundColor Gray
Write-Host ""

Start-Group -Title "Preparation"

& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-GroupLine "✓ Namespace ready" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "open-telemetry", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }

Complete-Group
Start-Group -Title "Deploy"

# Build collector config as YAML values
$otelConfig = @"
config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
  exporters:
    ${tracingExporter}:
      endpoint: $tracingEndpoint
      tls:
        insecure: true
    prometheusremotewrite:
      endpoint: $prometheusUrl
      tls:
        insecure: true
    otlphttp/loki:
      endpoint: $lokiUrl
      tls:
        insecure: true
  service:
    pipelines:
      traces:
        receivers: [otlp]
        exporters: [$tracingExporter]
      metrics:
        receivers: [otlp]
        exporters: [prometheusremotewrite]
      logs:
        receivers: [otlp]
        exporters: ["otlphttp/loki"]
"@

$tempValues = Join-Path $env:TEMP "otelcol-values.yaml"
Set-Content -Path $tempValues -Value $otelConfig -Encoding UTF8

$HelmArgs = @(
    "upgrade", "--install", "--force", "opentelemetry-collector", "open-telemetry/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "image.repository=$($UserConfig.ImageRepository)",
    "--set", "mode=$($UserConfig.Mode)",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    "--values", $tempValues,
    # Chart-native ServiceMonitor (own port "metrics", collector self-metrics,
    # default 8888) — same release=prometheus label convention as every other
    # ServiceMonitor in this repo (see 21-longhorn/Install.ps1); this chart
    # uses serviceMonitor.extraLabels rather than additionalLabels. CRD-only,
    # no NetworkPolicy effect by itself — the metrics port is bundled into
    # the existing provider-ingress rule below.
    #
    # ports.metrics.enabled — the chart's own values.yaml ships this port
    # *disabled* by default (containerPort/servicePort both 8888) and says
    # explicitly: "you need to enable the port in order to use the
    # ServiceMonitor". Without this, serviceMonitor.enabled=true alone
    # creates a ServiceMonitor that references a Service port named
    # "metrics" which never exists — confirmed live 2026-09-07: the Service
    # only exposed otlp/otlp-http/jaeger-*/zipkin, no "metrics" port at all,
    # so self-metrics scraping silently never worked (and
    # Resolve-ServiceRealPorts in every consumer, e.g. 61-prometheus, warned
    # "no port named 'metrics'" and quietly dropped it from the egress rule
    # instead of falling back — a separate, still-open gap in
    # Resolve-ServiceRealPorts' partial-failure handling).
    "--set", "ports.metrics.enabled=true",
    "--set", "serviceMonitor.enabled=true",
    "--set", "serviceMonitor.extraLabels.release=prometheus"
)

Reset-StuckHelmRelease -ReleaseName "opentelemetry-collector" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying OpenTelemetry Collector..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
Remove-Item $tempValues -Force -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { Write-Error "Failed to deploy OpenTelemetry Collector (exit code $exitCode)"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Waiting for opentelemetry-collector..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/opentelemetry-collector", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of OpenTelemetry Collector did not complete"; exit 1 }

# Publish OTLP endpoints as a reflected ConfigMap so all namespaces can reference them
$otlpConfigMap = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: otlp-endpoints
  namespace: $Namespace
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-enabled: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: ""
data:
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://opentelemetry-collector.${Namespace}:4317"
  OTEL_EXPORTER_OTLP_ENDPOINT_HTTP: "http://opentelemetry-collector.${Namespace}:4318"
"@
$otlpConfigMap | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-GroupLine "✓ OTLP endpoints ConfigMap published (reflected to all namespaces)" -ForegroundColor Green
}

Complete-Group

if ($FullConfig.RancherProject) {
    Start-Group -Title "Rancher"
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
    Write-GroupLine "✓ Assigned to Rancher project '$($FullConfig.RancherProject)'" -ForegroundColor Green
    Complete-Group
}

Start-Group -Title "Monitoring"
Register-GrafanaDashboard -Namespace $Namespace -Name "opentelemetry-collector" -JsonPath "$ScriptRoot\dashboards\opentelemetry-collector.json" -Folder "Observability"
Complete-Group

Start-Group -Title "Network Policy"

Install-NetworkPolicyBaseline -Namespace $Namespace
# OTLP gRPC/HTTP receiver ports (4317/4318) plus the ServiceMonitor's own
# self-metrics port ("metrics", default 8888) — the collector's Service also
# exposes legacy jaeger-*/zipkin receiver ports this platform doesn't use.
$otelCollectorPorts = @(
    (Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "opentelemetry-collector" -ServicePortName "otlp") +
    (Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "opentelemetry-collector" -ServicePortName "otlp-http") +
    (Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "opentelemetry-collector" -ServicePortName "metrics") |
    Select-Object -Unique
)
if (-not $otelCollectorPorts) { $otelCollectorPorts = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "opentelemetry-collector" }
Set-NetworkPolicyProviderIngress -Namespace $Namespace -Port $otelCollectorPorts
# Self-register as a Prometheus scrape target instead of Prometheus
# enumerating every ServiceMonitor'd namespace centrally (compliance finding
# #1 fix). Only the "metrics" port matters to Prometheus, but the full
# provider-ingress port set is harmless to also open here (same egress rule
# object either way, named allow-egress-to-$Namespace).
Set-NetworkPolicyConsumerEgress -Namespace "prometheus" -TargetNamespace $Namespace -Port $otelCollectorPorts
# Trace-export egress target depends on the tracing backend: tempo's real
# receiving Service is tempo-distributor, jaeger's is jaeger-collector. NOTE:
# as of 2026-08-20 on Magalu, tempo-distributor doesn't expose 4317 (OTLP)
# at all — its chart's OTLP receiver isn't enabled — a separate config gap,
# not a NetworkPolicy port issue; Resolve-ServiceRealPorts won't invent a
# phantom port the way the old hardcoded 4317 did.
if ($tracingNamespace -eq "jaeger") {
    $tracingIngestPort = Resolve-ServiceRealPorts -Namespace $tracingNamespace -ServiceName "jaeger-collector" -ServicePortName "grpc-otlp"
    if (-not $tracingIngestPort) { $tracingIngestPort = @(4317) }
} else {
    $tracingIngestPort = Resolve-ServiceRealPorts -Namespace $tracingNamespace -ServiceName "tempo-distributor"
}
if ($tracingIngestPort) {
    Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace $tracingNamespace -Port $tracingIngestPort
}
$prometheusPort = Resolve-ServiceRealPorts -Namespace "prometheus" -ServiceName "prometheus-kube-prometheus-prometheus" -ServicePortName "http-web"
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "prometheus" -Port $prometheusPort
$lokiPort = Resolve-ServiceRealPorts -Namespace "loki" -ServiceName "loki" -ServicePortName "http-metrics"
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "loki" -Port $lokiPort

Complete-Group

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  OTLP gRPC (traces, metrics, logs):" -ForegroundColor Gray
Write-Host "    opentelemetry-collector.${Namespace}:4317" -ForegroundColor Yellow
Write-Host "  OTLP HTTP (traces, metrics, logs):" -ForegroundColor Gray
Write-Host "    http://opentelemetry-collector.${Namespace}:4318" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Forwarding:" -ForegroundColor Gray
Write-Host "    Traces  → $tracingEndpoint" -ForegroundColor Yellow
Write-Host "    Metrics → prometheus.prometheus:9090 (remote write)" -ForegroundColor Yellow
Write-Host "    Logs    → loki.loki:3100" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
