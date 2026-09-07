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

if ($Platform -in @("Azure AKS", "AWS EKS", "Google GKE", "Magalu Cloud")) {
    # The node-exporter subchart ships a default toleration (effect:
    # NoSchedule, operator: Exists) specifically so it also runs on tainted
    # control-plane nodes — that only matters for our on-prem/local topology
    # (RKE2 (On-Premise) and Kind (Local)), where the recommended 3-node
    # layout makes every node both worker AND control-plane, so node-exporter
    # would otherwise silently skip the control-plane taint and miss 1/3 of
    # the cluster. On every managed cloud platform (AKS/EKS/GKE/Magalu) the
    # control plane is either fully hidden (AKS/EKS/GKE — this toleration is
    # then just a no-op) or an explicitly protected system node whose
    # admission controller denies it outright (Magalu — see below), so strip
    # it there instead of relying on it doing nothing everywhere but Magalu.
    # Replace it with an empty list so node-exporter only targets ordinary
    # schedulable worker nodes. --set-json (not --set=null, which unsets
    # rather than overrides) actually replaces the chart default instead of
    # falling back to it.
    #
    # Magalu specifically: its managed control plane runs a
    # ValidatingAdmissionPolicy ("protectsystemnodesfromworkloaddeploymentsbinding")
    # that denies any DaemonSet/workload carrying a toleration for
    # control-plane or generic NoSchedule taints on its protected system
    # nodes — confirmed live 2026-08-20: "daemonsets.apps
    # 'prometheus-prometheus-node-exporter' is forbidden ... ValidatingAdmissionPolicy
    # 'protectsystemnodesfromworkloaddeployments' ... This action is not allowed."
    $HelmArgs += @("--set-json", "prometheus-node-exporter.tolerations=[]")
}

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
    $protect = Protect-ComponentIngress -Hostname $Hostname -Platform $Platform -BaseDir $BaseDir
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
    $portalIcon = Get-PortalIconDataUri -ScriptRoot $ScriptRoot -IconFile $FullConfig.PortalIcon
    Register-PortalEntry -Name $FullConfig.PortalTitle -Url "${scheme}://$Hostname" `
        -Category "Observability" -Namespace $Namespace -Subtitle $FullConfig.PortalSubtitle -Order 61 `
        -InternalUrl "http://prometheus-kube-prometheus-prometheus.prometheus.svc.cluster.local:9090" `
        -LogoUrl $portalIcon
}

# Service alias so apps can use prometheus.$Namespace instead of the full release name
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

Install-NetworkPolicyBaseline -Namespace $Namespace
# Real namespace of whichever ingress controller is actually installed —
# "ingress" on fresh installs, but pre-rename clusters (e.g. live RKE2) can
# still have ingress-nginx in the legacy "ingress-nginx" namespace (compliance
# finding #2, NetworkPolicy audit 2026-09-05; see project_rke2_ingress_namespace_mismatch memory).
$ingressNamespace = Resolve-IngressNamespace
$prometheusPort = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "prometheus-kube-prometheus-prometheus" -ServicePortName "http-web"
Set-NetworkPolicyProviderIngress -Namespace $Namespace -Port $prometheusPort
Set-NetworkPolicyConsumerEgress -Namespace $ingressNamespace -TargetNamespace $Namespace -Port $prometheusPort

# Prometheus as a CONSUMER of every namespace it actually scrapes via a
# ServiceMonitor (Compliance finding #1, NetworkPolicy audit 2026-09-05):
# until now nothing ever labeled `prometheus` as a consumer, so every
# provider-ingress rule written for a ServiceMonitor target (12-metallb,
# 21-longhorn, 31-cert-manager, 33-openbao, 35-authelia, 62-loki,
# 63-promtail, 64-tracing-jaeger/tempo, 65-opentelemetry-collector,
# 66-grafana, 91-argocd, 92-minio, 93-velero, 11-ingress-nginx/traefik) was
# inert — Prometheus's own default-deny (Install-NetworkPolicyBaseline)
# silently blocked every scrape. One Set-NetworkPolicyConsumerEgress call
# per ServiceMonitor'd namespace below, each resolving the same
# Service+port-name pair that namespace's own provider-ingress rule uses so
# both ends match.
#
# Components that install BEFORE 61-prometheus (ingress=11, metallb=12,
# longhorn=21, cert-manager=31, openbao=33, authelia=35) already exist at
# this point, so those resolve live with no fallback needed. Components
# installing AFTER (loki=62, promtail=63, tracing=64, otel=65, grafana=66,
# argocd=91, minio=92, velero=93) don't exist yet on a fresh install, so
# those fall back to each chart's documented default port — same
# resolve-then-fallback idiom already used for cert-manager's own openbao
# consumer-egress call above. Re-running this script once those components
# are live re-resolves the real value and re-applies the rule, same as
# every other NetworkPolicy call in this repo.

# Ingress controller metrics (whichever variant is active — both install
# before Prometheus, so this always resolves live).
& kubectl get svc ingress-nginx-controller-metrics -n $ingressNamespace 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    $ingressMetricsPort = Resolve-ServiceRealPorts -Namespace $ingressNamespace -ServiceName "ingress-nginx-controller-metrics" -ServicePortName "metrics"
    if (-not $ingressMetricsPort) { $ingressMetricsPort = @(10254) }
} else {
    $ingressMetricsPort = @(9100)   # traefik — hardcoded upstream too, see 11-ingress-traefik/Install.ps1
}
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace $ingressNamespace -Port $ingressMetricsPort

# metallb-system (already installed, order 12) — hardcoded port upstream too.
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "metallb-system" -Port 7472

# longhorn-system (already installed, order 21)
$longhornFrontendPort = Resolve-ServiceRealPorts -Namespace "longhorn-system" -ServiceName "longhorn-frontend"
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "longhorn-system" -Port ($longhornFrontendPort + 9500)

# cert-manager (already installed, order 31) — hardcoded port upstream too.
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "cert-manager" -Port 9402

# openbao (already installed, order 33)
$openbaoConsumerPort = Resolve-ServiceRealPorts -Namespace "openbao" -ServiceName "openbao" -ServicePortName "http"
if (-not $openbaoConsumerPort) { $openbaoConsumerPort = @(8200) }
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "openbao" -Port $openbaoConsumerPort

# authelia (already installed, order 35) — chart-native ServiceMonitor
# (configMap.telemetry.metrics.serviceMonitor.enabled=true, see
# 35-authelia/Install.ps1), unfiltered resolve same as that script's own
# provider-ingress rule. Metrics port defaults to 9959 (chart >=4.36.0).
$autheliaConsumerPort = Resolve-ServiceRealPorts -Namespace "authelia" -ServiceName "authelia"
if (-not $autheliaConsumerPort) { $autheliaConsumerPort = @(9959) }
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "authelia" -Port $autheliaConsumerPort

# loki (installs after, order 62) — chart default "http-metrics" port is 3100.
$lokiConsumerPort = Resolve-ServiceRealPorts -Namespace "loki" -ServiceName "loki" -ServicePortName "http-metrics"
if (-not $lokiConsumerPort) { $lokiConsumerPort = @(3100) }
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "loki" -Port $lokiConsumerPort

# promtail (installs after, order 63) — metrics Service is named
# "promtail-metrics", not "promtail" (see 63-promtail/Install.ps1). Chart
# default "http-metrics" port is 3101.
$promtailConsumerPort = Resolve-ServiceRealPorts -Namespace "promtail" -ServiceName "promtail-metrics" -ServicePortName "http-metrics"
if (-not $promtailConsumerPort) { $promtailConsumerPort = @(3101) }
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "promtail" -Port $promtailConsumerPort

# Tracing backend (installs after, order 64) — mutually exclusive, same
# auto-detection 66-grafana/Install.ps1 uses (tempo-distributed uses
# tempo-query-frontend; legacy tempo uses the plain "tempo" Service).
$tracingNamespace = ""
& kubectl get svc tempo-query-frontend -n tempo 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { & kubectl get svc tempo -n tempo 2>&1 | Out-Null }
if ($LASTEXITCODE -eq 0) { $tracingNamespace = "tempo" }
& kubectl get svc jaeger -n jaeger 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { $tracingNamespace = "jaeger" }

if ($tracingNamespace -eq "jaeger") {
    $jaegerConsumerQueryPort     = Resolve-ServiceRealPorts -Namespace "jaeger" -ServiceName "jaeger-query"
    if (-not $jaegerConsumerQueryPort) { $jaegerConsumerQueryPort = @(16686) }
    $jaegerConsumerCollectorPort = Resolve-ServiceRealPorts -Namespace "jaeger" -ServiceName "jaeger-collector" -ServicePortName "grpc-otlp"
    if (-not $jaegerConsumerCollectorPort) { $jaegerConsumerCollectorPort = @(4317) }
    $jaegerConsumerAdminPort = @(Resolve-ServiceRealPorts -Namespace "jaeger" -ServiceName "jaeger-query" -ServicePortName "admin") +
        @(Resolve-ServiceRealPorts -Namespace "jaeger" -ServiceName "jaeger-collector" -ServicePortName "admin") +
        @(Resolve-ServiceRealPorts -Namespace "jaeger" -ServiceName "jaeger" -ServicePortName "admin")
    if (-not $jaegerConsumerAdminPort) { $jaegerConsumerAdminPort = @(14269, 16687) }
    Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "jaeger" -Port ($jaegerConsumerQueryPort + $jaegerConsumerCollectorPort + $jaegerConsumerAdminPort)
} elseif ($tracingNamespace -eq "tempo") {
    $tempoConsumerQueryFrontendPort = Resolve-ServiceRealPorts -Namespace "tempo" -ServiceName "tempo-query-frontend" -ServicePortName "http-metrics"
    if (-not $tempoConsumerQueryFrontendPort) { $tempoConsumerQueryFrontendPort = @(3200) }
    $tempoConsumerDistributorPorts = Resolve-ServiceRealPorts -Namespace "tempo" -ServiceName "tempo-distributor"
    if (-not $tempoConsumerDistributorPorts) { $tempoConsumerDistributorPorts = @(3200, 9095) }
    $tempoConsumerCompactorPort = Resolve-ServiceRealPorts -Namespace "tempo" -ServiceName "tempo-compactor" -ServicePortName "http-metrics"
    if (-not $tempoConsumerCompactorPort) { $tempoConsumerCompactorPort = @(3200) }
    $tempoConsumerIngesterPort = Resolve-ServiceRealPorts -Namespace "tempo" -ServiceName "tempo-ingester" -ServicePortName "http-metrics"
    if (-not $tempoConsumerIngesterPort) { $tempoConsumerIngesterPort = @(3200) }
    $tempoConsumerQuerierPort = Resolve-ServiceRealPorts -Namespace "tempo" -ServiceName "tempo-querier" -ServicePortName "http-metrics"
    if (-not $tempoConsumerQuerierPort) { $tempoConsumerQuerierPort = @(3200) }
    $tempoConsumerPorts = @($tempoConsumerQueryFrontendPort + $tempoConsumerDistributorPorts + $tempoConsumerCompactorPort + $tempoConsumerIngesterPort + $tempoConsumerQuerierPort | Select-Object -Unique)
    Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "tempo" -Port $tempoConsumerPorts
}

# opentelemetry-collector (installs after, order 65) — namespace is
# "opentelemetry", not "opentelemetry-collector". Chart defaults: otlp=4317,
# otlp-http=4318, metrics=8888 (see 65-opentelemetry-collector/Install.ps1).
$otelConsumerPorts = @(
    (Resolve-ServiceRealPorts -Namespace "opentelemetry" -ServiceName "opentelemetry-collector" -ServicePortName "otlp") +
    (Resolve-ServiceRealPorts -Namespace "opentelemetry" -ServiceName "opentelemetry-collector" -ServicePortName "otlp-http") +
    (Resolve-ServiceRealPorts -Namespace "opentelemetry" -ServiceName "opentelemetry-collector" -ServicePortName "metrics") |
    Select-Object -Unique
)
if (-not $otelConsumerPorts) { $otelConsumerPorts = @(4317, 4318, 8888) }
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "opentelemetry" -Port $otelConsumerPorts

# grafana (installs after, order 66) — chart default Service port is 80.
$grafanaConsumerPort = Resolve-ServiceRealPorts -Namespace "grafana" -ServiceName "grafana"
if (-not $grafanaConsumerPort) { $grafanaConsumerPort = @(80) }
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "grafana" -Port $grafanaConsumerPort

# argocd (installs after, order 91) — chart default argocd-server "http"
# port is 80; argocd-metrics default is 8082.
$argocdConsumerPort = Resolve-ServiceRealPorts -Namespace "argocd" -ServiceName "argocd-server" -ServicePortName "http"
if (-not $argocdConsumerPort) { $argocdConsumerPort = @(80) }
$argocdConsumerMetricsPort = Resolve-ServiceRealPorts -Namespace "argocd" -ServiceName "argocd-metrics" -ServicePortName "metrics"
if (-not $argocdConsumerMetricsPort) { $argocdConsumerMetricsPort = @(8082) }
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "argocd" -Port ($argocdConsumerPort + $argocdConsumerMetricsPort)

# minio (installs after, order 92) — chart default Service ports are 9000
# (S3 API, also serves /minio/v2/metrics/cluster) and 9001 (console).
$minioConsumerPort = Resolve-ServiceRealPorts -Namespace "minio" -ServiceName "minio"
if (-not $minioConsumerPort) { $minioConsumerPort = @(9000, 9001) }
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "minio" -Port $minioConsumerPort

# velero (installs after, order 93) — chart default "http-monitoring" port is 8085.
$veleroConsumerPort = Resolve-ServiceRealPorts -Namespace "velero" -ServiceName "velero" -ServicePortName "http-monitoring"
if (-not $veleroConsumerPort) { $veleroConsumerPort = @(8085) }
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "velero" -Port $veleroConsumerPort

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    Write-Host "  Access:  ${scheme}://$Hostname" -ForegroundColor Yellow
}
Write-Host "  Service (cluster-internal):" -ForegroundColor Gray
Write-Host "    http://prometheus.${Namespace}:9090" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
