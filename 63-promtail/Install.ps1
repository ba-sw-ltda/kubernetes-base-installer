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

# Extra static scrape job for the RKE2 API audit log (Finding #9) —
# mounted read-only from the host path RKE2 writes it to. Only present on
# server nodes; worker-node Promtail pods just see an empty DirectoryOrCreate
# mount and the job stays idle there.
$promtailAuditValues = @'
extraVolumes:
  - name: rke2-audit-log
    hostPath:
      path: /var/log/rancher/rke2/audit
      type: DirectoryOrCreate

extraVolumeMounts:
  - name: rke2-audit-log
    mountPath: /var/log/rancher/rke2/audit
    readOnly: true

config:
  snippets:
    extraScrapeConfigs: |
      - job_name: rke2-audit
        static_configs:
          - targets:
              - localhost
            labels:
              job: rke2-audit
              __path__: /var/log/rancher/rke2/audit/audit.log
'@
$tempValues = Join-Path $env:TEMP "promtail-audit-values.yaml"
Set-Content -Path $tempValues -Value $promtailAuditValues -Encoding UTF8

$HelmArgs = @(
    "upgrade", "--install", "--force", "promtail", "grafana/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "config.clients[0].url=$($UserConfig.LokiUrl)",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    "--values", $tempValues,
    # Chart-native ServiceMonitor (promtail:http-metrics/metrics) — same
    # release=prometheus label convention as every other ServiceMonitor in
    # this repo (see 21-longhorn/Install.ps1). CRD-only, no NetworkPolicy
    # effect by itself — the metrics port is bundled into the new
    # provider-ingress rule below (Promtail previously had no
    # provider-ingress rule at all, only its own consumer-egress rule
    # toward Loki).
    "--set", "serviceMonitor.enabled=true",
    "--set", "serviceMonitor.labels.release=prometheus"
)

if ($Platform -in @("Azure AKS", "AWS EKS", "Google GKE", "Magalu Cloud")) {
    # The chart ships a default toleration for node-role.kubernetes.io/master
    # and node-role.kubernetes.io/control-plane (NoSchedule) so Promtail also
    # runs on control-plane nodes — that only matters for our on-prem/local
    # topology (RKE2 (On-Premise) and Kind (Local)), where the recommended
    # 3-node layout makes every node both worker AND control-plane, so
    # Promtail would otherwise silently skip the control-plane taint and miss
    # 1/3 of the cluster's logs. On every managed cloud platform (AKS/EKS/GKE/
    # Magalu) the control plane is either fully hidden (AKS/EKS/GKE — this
    # toleration is then just a no-op) or an explicitly protected system node
    # whose admission controller denies it outright, exactly as it did for
    # prometheus-node-exporter on Magalu (see 61-prometheus/Install.ps1), so
    # strip it there instead of relying on it doing nothing everywhere but
    # Magalu. Replace it with an empty list so Promtail only targets ordinary
    # schedulable worker nodes. --set-json (not --set=null, which unsets
    # rather than overrides) actually replaces the chart default instead of
    # falling back to it.
    $HelmArgs += @("--set-json", "tolerations=[]")
}

Reset-StuckHelmRelease -ReleaseName "promtail" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying Promtail..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
Remove-Item $tempValues -Force -ErrorAction SilentlyContinue
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

Register-GrafanaDashboard -Namespace $Namespace -Name "promtail" -JsonPath "$ScriptRoot\dashboards\promtail.json" -Folder "Observability"

Install-NetworkPolicyBaseline -Namespace $Namespace
$lokiPort = Resolve-ServiceRealPorts -Namespace "loki" -ServiceName "loki" -ServicePortName "http-metrics"
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "loki" -Port $lokiPort

# Metrics scrape port (promtail:http-metrics), bundled separately since
# Promtail previously had no provider-ingress rule of its own — only the
# consumer-egress rule above (toward Loki, for shipping logs). Label-gated
# on the network.k8s/allow-$Namespace consumer contract, inert until
# `prometheus` is labeled as a consumer, same deliberate gap as
# 21-longhorn/Install.ps1.
$promtailMetricsPort = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "promtail" -ServicePortName "http-metrics"
Set-NetworkPolicyProviderIngress -Namespace $Namespace -Port $promtailMetricsPort
# Self-register as a Prometheus scrape target instead of Prometheus
# enumerating every ServiceMonitor'd namespace centrally (compliance finding
# #1 fix).
Set-NetworkPolicyConsumerEgress -Namespace "prometheus" -TargetNamespace $Namespace -Port $promtailMetricsPort

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
