<#
.SYNOPSIS
    Install OpenTelemetry Collector (receives OTLP, forwards to tracing backend)
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
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

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
$tracingExporter = "otlp/tempo"
$tracingEndpoint = "tempo.${Namespace}:4317"
& kubectl get svc jaeger-collector -n $Namespace 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    $tracingExporter = "otlp/jaeger"
    $tracingEndpoint = "jaeger-collector.${Namespace}:4317"
} else {
    & kubectl get svc tempo-distributor -n $Namespace 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $tracingEndpoint = "tempo-distributor.${Namespace}:4317"
    }
}

$prometheusUrl = $UserConfig.PrometheusRemoteWriteUrl
$lokiUrl       = $UserConfig.LokiOtlpUrl

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Traces  →   $tracingEndpoint" -ForegroundColor Gray
Write-Host "  Metrics →   prometheus.${Namespace}:9090" -ForegroundColor Gray
Write-Host "  Logs    →   loki.${Namespace}:3100" -ForegroundColor Gray
Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "open-telemetry", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

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
    "--values", $tempValues
)

$exitCode = Invoke-WithSpinner -Message "Deploying OpenTelemetry Collector..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
Remove-Item $tempValues -Force -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { Write-Error "Failed to deploy OpenTelemetry Collector (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for opentelemetry-collector..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/opentelemetry-collector", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of OpenTelemetry Collector did not complete"; exit 1 }
Write-Host "  ✓ OpenTelemetry Collector ready" -ForegroundColor Green

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
    Write-Host "  ✓ OTLP endpoints ConfigMap published (reflected to all namespaces)" -ForegroundColor Green
}

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
Write-Host "    Metrics → prometheus.${Namespace}:9090 (remote write)" -ForegroundColor Yellow
Write-Host "    Logs    → loki.${Namespace}:3100" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
