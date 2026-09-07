<#
.SYNOPSIS
    Install kube-prometheus-stack (Prometheus + Alertmanager + Node Exporter + kube-state-metrics)
.PARAMETER Platform
    Target platform
.PARAMETER Receivers
    Array of @{ Type = "Email"|"Teams"; Target = <email address|Teams webhook URL> }
    (from Prompt.ps1). Empty means "no alerting configured" — Alertmanager
    stays disabled.
.PARAMETER Smtp
    @{ Host; From; User; Password; RequireTls } (from Prompt.ps1) — only
    populated when at least one Email receiver was configured.
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Hostname,
    [hashtable[]]$Receivers = @(),
    [hashtable]$Smtp        = @{},
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
Write-Host "  Alerting:   $(if ($Receivers.Count -gt 0) { "$($Receivers.Count) receiver(s)" } else { "disabled — no receivers configured" })" -ForegroundColor Gray
Write-Host ""

Start-Group "Preparation"

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "prometheus-community", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }

& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-GroupLine "✓ Namespace ready" -ForegroundColor Green

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
        Write-GroupLine "✓ Proxy Secret reflected into $Namespace" -ForegroundColor Green
    }
}

Complete-Group
Start-Group "Alerting"

# Receivers with a blank target (user backed out mid-prompt) don't count.
$Receivers = @($Receivers | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_.Target) })
$alertmanagerEnabled = $Receivers.Count -gt 0

$tempAlertmanagerValues = $null
if ($alertmanagerEnabled) {
    $emailReceivers = @($Receivers | Where-Object { $_.Type -eq "Email" })
    $teamsReceivers = @($Receivers | Where-Object { $_.Type -eq "Teams" })

    # One shared receiver ("notifications") fans every alert out to every
    # configured channel — this repo's ask was a flat list of destinations,
    # not per-severity routing, so there's no routing tree to build.
    # 'Watchdog' (kube-prometheus-stack's built-in always-firing heartbeat)
    # keeps going to the chart's default 'null' receiver so it doesn't spam
    # every channel below every group_interval.
    # Nested two levels deeper than "- name: 'notifications'" itself (8sp to
    # align under "name:", 10sp for each list item) — these are keys *of*
    # that receiver, not siblings of the receivers: list.
    $emailConfigsBlock = ""
    if ($emailReceivers.Count -gt 0) {
        $lines = foreach ($r in $emailReceivers) { "          - to: `"$($r.Target)`"" }
        $emailConfigsBlock = "        email_configs:`n" + ($lines -join "`n") + "`n"
    }

    $teamsConfigsBlock = ""
    if ($teamsReceivers.Count -gt 0) {
        $lines = foreach ($r in $teamsReceivers) { "          - webhook_url: `"$($r.Target)`"`n            send_resolved: true" }
        $teamsConfigsBlock = "        msteams_configs:`n" + ($lines -join "`n") + "`n"
    }

    $smtpLines = ""
    if ($emailReceivers.Count -gt 0 -and $Smtp -and -not [string]::IsNullOrWhiteSpace($Smtp.Host)) {
        $smtpLines = "      smtp_smarthost: `"$($Smtp.Host)`"`n"
        $smtpLines += "      smtp_from: `"$($Smtp.From)`"`n"
        $smtpLines += "      smtp_require_tls: $($Smtp.RequireTls.ToString().ToLower())"
        if (-not [string]::IsNullOrWhiteSpace($Smtp.User)) {
            $smtpLines += "`n      smtp_auth_username: `"$($Smtp.User)`""
            $smtpLines += "`n      smtp_auth_password: `"$($Smtp.Password)`""
        }
        $smtpLines += "`n"

        # Vault is the audit trail for the credential; Alertmanager still
        # needs the plaintext inline above to actually authenticate — same
        # dual-write as 43-proget-registry's feed credentials. Skipped
        # entirely when the relay needs no auth (no $Smtp.User) — there is
        # no credential to audit in that case, and writing an empty
        # user/password pair to vault would just look like a broken secret.
        if (-not [string]::IsNullOrWhiteSpace($Smtp.User)) {
            $writeOk = Write-ClusterSecret -Path "prometheus/smtp" -BaseDir $BaseDir -Platform $Platform -Data @{
                user     = $Smtp.User
                password = $Smtp.Password
            }
            if ($writeOk) { Write-GroupLine "✓ SMTP credentials stored in vault" -ForegroundColor Green }
        }
    }

    # kube-prometheus-stack's own defaults for global/inhibit_rules/route are
    # reproduced here (not merged — a --values file replaces this whole key),
    # just re-pointed at 'notifications' instead of the chart's default 'null'.
    $alertmanagerConfigYaml = @"
alertmanager:
  config:
    global:
      resolve_timeout: 5m
$smtpLines    inhibit_rules:
      - source_matchers: ['severity = critical']
        target_matchers: ['severity =~ warning|info']
        equal: ['namespace', 'alertname']
      - source_matchers: ['severity = warning']
        target_matchers: ['severity = info']
        equal: ['namespace', 'alertname']
      - source_matchers: ['alertname = InfoInhibitor']
        target_matchers: ['severity = info']
        equal: ['namespace']
      - target_matchers: ['alertname = InfoInhibitor']
    route:
      group_by: ['namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'notifications'
      routes:
      - receiver: 'null'
        matchers:
          - alertname = "Watchdog"
    receivers:
      - name: 'null'
      - name: 'notifications'
$emailConfigsBlock$teamsConfigsBlock
"@

    $tempAlertmanagerValues = Join-Path $env:TEMP "prometheus-alertmanager-values.yaml"
    Set-Content -Path $tempAlertmanagerValues -Value $alertmanagerConfigYaml -Encoding UTF8
} else {
    Write-GroupLine "· No receivers configured — Alertmanager stays disabled" -ForegroundColor DarkGray
}

Complete-Group

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
    "--set", "alertmanager.enabled=$($alertmanagerEnabled.ToString().ToLower())",
    "--set", "grafana.enabled=$($UserConfig.GrafanaEnabled.ToString().ToLower())",
    "--set", "prometheus.prometheusSpec.enableRemoteWriteReceiver=$($UserConfig.RemoteWriteReceiverEnabled.ToString().ToLower())",
    "--set", "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]=ReadWriteOnce",
    "--set", "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=$($UserConfig.StorageSize)"
)

if ($tempAlertmanagerValues) { $HelmArgs += @("--values", $tempAlertmanagerValues) }

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

Start-Group "Deploy"

Reset-StuckHelmRelease -ReleaseName "prometheus" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying kube-prometheus-stack..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy kube-prometheus-stack (exit code $exitCode)"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Waiting for prometheus-operator..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/prometheus-kube-prometheus-operator", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of prometheus-operator did not complete"; exit 1 }

# The Prometheus Operator creates the StatefulSet asynchronously after its own rollout.
# Wait for it to appear before running rollout status.
$frames = @('|','/','-','\'); $fi = 0; $elapsed = 0
$indent = Get-GroupIndent
while ($elapsed -lt 60) {
    $ss = & kubectl get statefulset prometheus-prometheus-kube-prometheus-prometheus `
        -n $Namespace --ignore-not-found 2>$null
    if ($ss) { break }
    Write-Host ("`r$indent$($frames[$fi++ % 4]) Waiting for prometheus StatefulSet to be created...") -NoNewline -ForegroundColor Cyan
    Start-Sleep -Seconds 5; $elapsed += 5
}
Write-Host ("`r" + (" " * 60) + "`r") -NoNewline
if (-not $ss) { Write-Error "Prometheus StatefulSet was not created within 60s"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Waiting for prometheus..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "statefulset/prometheus-prometheus-kube-prometheus-prometheus", "-n", $Namespace, "--timeout=10m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of prometheus did not complete"; exit 1 }

Complete-Group
Start-Group "Ingress & Portal"

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
    if ($LASTEXITCODE -eq 0) { Write-GroupLine "✓ Ingress configured ($Hostname)" -ForegroundColor Green }
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
if ($LASTEXITCODE -eq 0) { Write-GroupLine "✓ Service alias 'prometheus' created" -ForegroundColor Green }

if ($alertmanagerEnabled) {
    # Same alias pattern as 'prometheus' above — gives 66-grafana a stable
    # short DNS name for the Alertmanager datasource instead of hardcoding
    # the full "prometheus-kube-prometheus-alertmanager" release name.
    $amAliasYaml = @"
apiVersion: v1
kind: Service
metadata:
  name: alertmanager
  namespace: $Namespace
spec:
  type: ExternalName
  externalName: prometheus-kube-prometheus-alertmanager.$Namespace.svc.cluster.local
"@
    $amAliasYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-GroupLine "✓ Service alias 'alertmanager' created" -ForegroundColor Green }
}

Complete-Group

if ($FullConfig.RancherProject) {
    Start-Group -Title "Rancher"
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
    Write-GroupLine "✓ Assigned to Rancher project '$($FullConfig.RancherProject)'" -ForegroundColor Green
    Complete-Group
}

# General cluster-status dashboards — not tied to any single component, so
# registered here rather than by whichever component happens to install
# last. Both are vendored community dashboards (grafana.com) built against
# kube-state-metrics + node-exporter, which this chart provisions directly:
#   - cluster-overview: "Kubernetes / Views / Global" (dotdc, ID 15757) —
#     CPU/memory/filesystem/pod-count at cluster level; wired as Grafana's
#     default home dashboard in 66-grafana/Install.ps1 (grafana.ini
#     [dashboards] default_home_dashboard_path).
#   - node-exporter: "Node Exporter Full" (ID 1860) — per-node hardware/OS
#     detail (disk, network, memory breakdown) the Global dashboard doesn't
#     drill into.
# Both use live "datasource"-type template variables (${datasource} /
# ${ds_prometheus}) that Grafana resolves at render time against whichever
# Prometheus datasource is provisioned — no per-install JSON patching needed,
# same as every other vendored dashboard in this repo.
Start-Group -Title "Monitoring"
Register-GrafanaDashboard -Namespace $Namespace -Name "cluster-overview" `
    -JsonPath "$ScriptRoot\dashboards\cluster-overview.json" -Folder "Cluster"
Register-GrafanaDashboard -Namespace $Namespace -Name "node-exporter" `
    -JsonPath "$ScriptRoot\dashboards\node-exporter.json" -Folder "Cluster"
Complete-Group

Start-Group -Title "Network Policy"

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
# ServiceMonitor (Compliance finding #1, NetworkPolicy audit 2026-09-05) is
# no longer enumerated centrally here — Prometheus shouldn't need to know
# about every component that happens to expose metrics. Each provider now
# self-registers via its own Set-NetworkPolicyConsumerEgress -Namespace
# "prometheus" call, right next to its own Set-NetworkPolicyProviderIngress
# (11-ingress-nginx/traefik, 12-metallb, 21-longhorn, 31-cert-manager,
# 33-openbao, 35-authelia, 62-loki, 63-promtail, 64-tracing-jaeger/tempo,
# 65-opentelemetry-collector, 66-grafana, 91-argocd, 92-minio, 93-velero).
#
# Providers installing BEFORE Prometheus (order < 61) hit this call before
# the `prometheus` namespace exists, so Set-NetworkPolicyConsumerEgress
# parks a pending marker in the provider's own namespace instead of
# silently doing nothing. Resolving those markers now that `prometheus`
# exists is Prometheus's own concern (it's the consumer becoming ready),
# not a central sweep of what every other component needs — same
# marker/resolver pattern already used for portal entries and Rancher
# project assignments.
Resolve-PendingNetworkPolicyConsumerEgress -Namespace $Namespace

if ($alertmanagerEnabled) {
    # Alertmanager's own targets (the SMTP relay, the Teams webhook host)
    # are arbitrary internet endpoints, not another namespace in this
    # cluster — same shape as the DNS/NTP external-egress rules in
    # Install-NetworkPolicyBaseline, so it gets the same 0.0.0.0/0-by-port
    # treatment, scoped to just the alertmanager pod (not the whole
    # namespace) to keep the hole as narrow as the baseline's default-deny
    # posture intends.
    $smtpPort = 587
    if ($Smtp -and -not [string]::IsNullOrWhiteSpace($Smtp.Host) -and $Smtp.Host -match ':(\d+)$') {
        $smtpPort = [int]$Matches[1]
    }
    $alertEgressYaml = @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-alertmanager-external-egress
  namespace: $Namespace
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: alertmanager
  policyTypes: ["Egress"]
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
    - protocol: TCP
      port: $smtpPort
    - protocol: TCP
      port: 443
"@
    $alertEgressYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-GroupLine "✓ Alertmanager external egress (SMTP $smtpPort / HTTPS 443) allowed" -ForegroundColor Green }
}

Complete-Group

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    Write-Host "  Access:  ${scheme}://$Hostname" -ForegroundColor Yellow
}
Write-Host "  Service (cluster-internal):" -ForegroundColor Gray
Write-Host "    http://prometheus.${Namespace}:9090" -ForegroundColor Yellow
if ($alertmanagerEnabled) {
    Write-Host "  Alertmanager:" -ForegroundColor Gray
    foreach ($r in $Receivers) { Write-Host "    $($r.Type): $($r.Target)" -ForegroundColor Yellow }
}
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
