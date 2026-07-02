<#
.SYNOPSIS
    Install kube-prometheus-stack (Prometheus + Alertmanager + Node Exporter + kube-state-metrics)
.PARAMETER Platform
    Target platform
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Hostname,
    [string]$ConfigPath
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1"       -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 61 - Prometheus" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName  = $FullConfig.ChartName
$ChartVersion = $FullConfig.Version
$Repository = $FullConfig.Repository
$Namespace  = $FullConfig.Namespace
$UserConfig = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Retention:  $($UserConfig.RetentionTime) / $($UserConfig.RetentionSize)" -ForegroundColor Gray
Write-Host "  Storage:    $($UserConfig.StorageSize)" -ForegroundColor Gray
Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "prometheus-community", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-Host "  ✓ Namespace ready" -ForegroundColor Green

# Pull proxy Secret via Reflector if proxy-config exists
& kubectl get secret proxy-config -n proxy-config 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    $reflectedSecret = @"
apiVersion: v1
kind: Secret
metadata:
  name: proxy-config
  namespace: $Namespace
  annotations:
    reflector.v1.k8s.emberstack.com/reflects: "proxy-config/proxy-config"
type: Opaque
"@
    $reflectedSecret | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Proxy Secret reflected into $Namespace" -ForegroundColor Green
    }
}

$alertmanagerEnabled = $UserConfig.AlertmanagerEnabled.ToString().ToLower()

$HelmArgs = @(
    "upgrade", "--install", "--force", "prometheus", "prometheus-community/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "prometheus.prometheusSpec.retention=$($UserConfig.RetentionTime)",
    "--set", "prometheus.prometheusSpec.retentionSize=$($UserConfig.RetentionSize)",
    "--set", "prometheus.prometheusSpec.resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "prometheus.prometheusSpec.resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "prometheus.prometheusSpec.resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "prometheus.prometheusSpec.resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    "--set", "alertmanager.enabled=$alertmanagerEnabled",
    "--set", "grafana.enabled=$($UserConfig.GrafanaEnabled.ToString().ToLower())",
    "--set", "prometheus.prometheusSpec.enableRemoteWriteReceiver=$($UserConfig.RemoteWriteReceiverEnabled.ToString().ToLower())",
    "--set", "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]=ReadWriteOnce",
    "--set", "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=$($UserConfig.StorageSize)"
)

Reset-StuckHelmRelease -ReleaseName "prometheus" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying kube-prometheus-stack..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy kube-prometheus-stack (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for prometheus-operator..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/prometheus-kube-prometheus-operator", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of prometheus-operator did not complete"; exit 1 }
Write-Host "  ✓ prometheus-operator ready" -ForegroundColor Green

# The Prometheus Operator creates the StatefulSet asynchronously after its own rollout.
# Wait for it to appear before running rollout status.
$frames = @('|','/','-','\'); $fi = 0; $elapsed = 0
while ($elapsed -lt 60) {
    $ss = & kubectl get statefulset prometheus-prometheus-kube-prometheus-prometheus `
        -n $Namespace --ignore-not-found 2>$null
    if ($ss) { break }
    Write-Host ("`r  $($frames[$fi++ % 4]) Waiting for prometheus StatefulSet to be created...") -NoNewline -ForegroundColor Cyan
    Start-Sleep -Seconds 5; $elapsed += 5
}
Write-Host ("`r" + (" " * 60) + "`r") -NoNewline
if (-not $ss) { Write-Error "Prometheus StatefulSet was not created within 60s"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Waiting for prometheus..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "statefulset/prometheus-prometheus-kube-prometheus-prometheus", "-n", $Namespace, "--timeout=10m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of prometheus did not complete"; exit 1 }
Write-Host "  ✓ prometheus ready" -ForegroundColor Green

if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    $protect = Protect-ComponentIngress -Hostname $Hostname -Platform $Platform
    $authAnnotations = ($protect.Annotations.GetEnumerator() | ForEach-Object { "    $($_.Key): `"$($_.Value)`"" }) -join "`n"

    $ingressYaml = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus
  namespace: $Namespace
  annotations:
$authAnnotations
spec:
  ingressClassName: $(Get-IngressClass)
$($protect.TlsBlock)
  rules:
  - host: $Hostname
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: prometheus-kube-prometheus-prometheus
            port:
              number: 9090
"@
    $ingressYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Ingress configured ($Hostname)" -ForegroundColor Green }
    $scheme = if (-not [string]::IsNullOrWhiteSpace($protect.TlsBlock)) { "https" } else { "http" }
    Register-PortalEntry -Name "Prometheus" -Url "${scheme}://$Hostname" `
        -Category "Observability" -Subtitle "Metrics & Alerting" -Order 61 `
        -LogoUrl "https://prometheus.io/assets/prometheus_logo-cb55bb5c346.png"
}

# Service alias so apps can use prometheus.monitoring instead of the full name
$aliasYaml = @"
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: $Namespace
spec:
  type: ExternalName
  externalName: prometheus-kube-prometheus-prometheus.$Namespace.svc.cluster.local
"@
$aliasYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Service alias 'prometheus' created" -ForegroundColor Green }

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
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    Write-Host "  Access:  http://$Hostname" -ForegroundColor Yellow
}
Write-Host "  Service (cluster-internal):" -ForegroundColor Gray
Write-Host "    http://prometheus.${Namespace}:9090" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
