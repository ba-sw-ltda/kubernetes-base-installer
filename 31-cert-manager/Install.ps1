<#
.SYNOPSIS
    Install cert-manager
.DESCRIPTION
    Installs cert-manager via Helm only — no ClusterIssuer here. For RKE2/Kind,
    33-openbao/Install.ps1 creates one ClusterIssuer per PKI (named
    "openbao-pki-<name>") once OpenBao's PKI engines are ready (cert-manager
    always installs first in the fixed order, so its CRDs/ServiceAccount already
    exist by then). Other platforms have no issuer yet — see Get-ClusterIssuerName.
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER Platform
    Target platform (Azure AKS, AWS EKS, Google GKE, RKE2, Kind)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Platform
)

$ScriptRoot = $PSScriptRoot
$BaseDir = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 31 - cert-manager" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName       = $FullConfig.ChartName
$ChartVersion    = $FullConfig.Version
$Repository      = $FullConfig.Repository
$Namespace       = $FullConfig.Namespace
$CreateNamespace = $FullConfig.CreateNamespace
$UserConfig      = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName $ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host ""

Start-Group -Title "Preparation"

# Helm repository
$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "jetstack", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }

# Namespace
if ($CreateNamespace) {
    & kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
    Write-GroupLine "✓ Namespace ready" -ForegroundColor Green
}

Complete-Group
Start-Group -Title "Deploy"

# Deploy
$HelmArgs = @(
    "upgrade", "--install", "cert-manager", "jetstack/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "installCRDs=$($UserConfig.InstallCRDs.ToString().ToLower())",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    # Chart-native ServiceMonitor (cert-manager:9402/metrics) — same
    # release=prometheus label convention as every other ServiceMonitor in
    # this repo (see 21-longhorn/Install.ps1). CRD-only, no NetworkPolicy
    # effect by itself — the metrics port is bundled into the provider-ingress
    # rule below.
    "--set", "prometheus.enabled=true",
    "--set", "prometheus.servicemonitor.enabled=true",
    "--set", "prometheus.servicemonitor.labels.release=prometheus"
)

Reset-StuckHelmRelease -ReleaseName "cert-manager" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying cert-manager..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy cert-manager (exit code $exitCode)"; exit 1 }

# Wait for all three components
foreach ($dep in @("cert-manager", "cert-manager-cainjector", "cert-manager-webhook")) {
    $exitCode = Invoke-WithSpinner -Message "Waiting for $dep..." -Executable "kubectl" `
        -Arguments @("rollout", "status", "deployment/$dep", "-n", $Namespace, "--timeout=5m") `
        -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Rollout of $dep did not complete"; exit 1 }
}

if ($verbose) {
    Write-GroupLine ""
    & kubectl get pods -n $Namespace
}

Complete-Group
Complete-Group

# Three separate groups instead of one catch-all "Housekeeping" — see
# 11-ingress-traefik/Install.ps1 for why (duplicate Grafana confirmation
# line + user-flagged "shouldn't NetworkPolicy get its own group?",
# 2026-09-05). "Monitoring" is the deliberate name, not "Grafana" —
# Prometheus alerting rules for this component will join the same group
# once that work starts.
if ($FullConfig.RancherProject) {
    Start-Group -Title "Rancher"
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
    Write-GroupLine "✓ Assigned to Rancher project '$($FullConfig.RancherProject)'" -ForegroundColor Green
    Complete-Group
}

# Grafana dashboard: ConfigMap labeled grafana_dashboard=1, picked up live by
# Grafana's dashboard sidecar. Order-independent, no NetworkPolicy involved —
# same pattern as 21-longhorn/Install.ps1. Register-GrafanaDashboard prints
# its own "✓ ... registered" confirmation line — nothing more to print here.
Start-Group -Title "Monitoring"
Register-GrafanaDashboard -Namespace $Namespace -Name "cert-manager" `
    -JsonPath "$ScriptRoot\dashboards\cert-manager.json" -Folder "Security"

# Prometheus alerting rules — vendored from the community cert-manager mixin
# (see prometheusrules/cert-manager.yaml for source/provenance and the
# jsonnet-to-PromQL resolution notes). Same order-independence as the
# dashboard above — Register-PrometheusRule prints its own confirmation
# line, nothing more to print here.
Register-PrometheusRule -Namespace $Namespace -Name "cert-manager" `
    -YamlPath "$ScriptRoot\prometheusrules\cert-manager.yaml"
Complete-Group

Start-Group -Title "Network Policy"

Install-NetworkPolicyBaseline -Namespace $Namespace
# Metrics scrape port (cert-manager:9402), label-gated via the same
# provider-ingress pattern as 21-longhorn/Install.ps1.
Set-NetworkPolicyProviderIngress -Namespace $Namespace -Port 9402
# Self-register as a Prometheus scrape target instead of Prometheus
# enumerating every ServiceMonitor'd namespace centrally (compliance finding
# #1 fix). If `prometheus` doesn't exist yet, this parks a pending marker
# that 61-prometheus/Install.ps1 resolves once it does.
Set-NetworkPolicyConsumerEgress -Namespace "prometheus" -TargetNamespace $Namespace -Port 9402
# Resolved dynamically against OpenBao's real container port rather than
# hardcoded — see Resolve-ServiceRealPorts for why (NetworkPolicy `ports`
# matches the pod's real destination port after Service DNAT, not the
# Service's advertised port). cert-manager (31) always installs before
# OpenBao (33) in the fixed component order, so OpenBao's Service doesn't
# exist yet on a fresh install — Resolve-ServiceRealPorts then returns an
# empty array by design (see its own doc comment) rather than throwing.
# Falling back to 8200 (OpenBao's fixed HTTP port, hardcoded the same way
# throughout 33-openbao/Install.ps1, e.g. its own ClusterIssuer `server:`
# field and Ingress backend) still gets the egress rule right on a fresh
# install instead of silently omitting it forever — 33-openbao only ever
# creates the *provider*-side (ingress) half via Set-NetworkPolicyProviderIngress,
# never a consumer egress rule for cert-manager, so this call is cert-manager's
# only chance to open its own egress.
$openbaoPort = Resolve-ServiceRealPorts -Namespace "openbao" -ServiceName "openbao" -ServicePortName "http"
if ($openbaoPort.Count -eq 0) {
    Write-Warning "Could not resolve OpenBao's real container port (Service not deployed yet — expected on a fresh install, since cert-manager installs before OpenBao) — falling back to 8200."
    $openbaoPort = @(8200)
}
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "openbao" -Port $openbaoPort

# The default-deny above also blocks the kube-apiserver's admission-webhook
# calls into this namespace (every Certificate/ClusterIssuer create or update,
# cluster-wide, goes through cert-manager-webhook). That traffic arrives from
# the control-plane nodes' host network, not from a pod, so the label-contract
# pattern used everywhere else can't cover it — carve out an explicit ipBlock
# exception scoped to just the webhook pod and port.
$controlPlaneIps = (& kubectl get nodes -l "node-role.kubernetes.io/control-plane" -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>$null) -split '\s+' | Where-Object { $_ }
if (-not $controlPlaneIps) {
    $controlPlaneIps = (& kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>$null) -split '\s+' | Where-Object { $_ }
}

# Magalu's managed control plane binds a second NIC (an internal management
# network) that Kubernetes never reports via Node.status.addresses — only the
# "user project network" IP above gets published. The apiserver's outbound
# webhook call sometimes egresses from that unpublished NIC instead, a purely
# platform-specific routing quirk: confirmed live 2026-08-20 with only the
# InternalIP allow-listed, cert-manager's webhook calls intermittently timed
# out ("failed calling webhook ... Client.Timeout exceeded while awaiting
# headers"), leaving Certificates permanently stuck un-Ready — including the
# portal's, which is why the portal was unreachable. calico-node runs
# hostNetwork on every node and can see every real interface on its host, so
# where it's present (Magalu; this repo never installs Calico itself, so the
# calico-system namespace is simply absent everywhere else — RKE2/Kind/AKS/
# EKS/GKE use their own CNI and don't hit this at all) pull every extra
# global-scope IPv4 address it reports per control-plane node and fold it
# into the same allow-list, rather than guessing which interface is "the"
# one.
$calicoNodesByHost = @{}
(& kubectl get pods -n calico-system -l k8s-app=calico-node -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.metadata.name}{"\n"}{end}' 2>$null) -split "`n" | Where-Object { $_ } | ForEach-Object {
    $parts = $_ -split '\s+'
    if ($parts.Count -eq 2) { $calicoNodesByHost[$parts[0]] = $parts[1] }
}
if ($calicoNodesByHost.Count -gt 0) {
    $cpNodeNames = (& kubectl get nodes -l "node-role.kubernetes.io/control-plane" -o jsonpath='{.items[*].metadata.name}' 2>$null) -split '\s+' | Where-Object { $_ }
    if (-not $cpNodeNames) {
        $cpNodeNames = (& kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>$null) -split '\s+' | Where-Object { $_ }
    }
    foreach ($nodeName in $cpNodeNames) {
        $calicoPod = $calicoNodesByHost[$nodeName]
        if (-not $calicoPod) { continue }
        $addrLines = (& kubectl exec -n calico-system $calicoPod -c calico-node -- ip -4 -o addr show scope global 2>$null) -split "`n"
        foreach ($line in $addrLines) {
            if ($line -match '\s(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)/') {
                $ifName = $Matches[1]
                $ip     = $Matches[2]
                if ($ifName -in @('vxlan.calico', 'tunl0', 'nodelocaldns')) { continue }
                if ($ip -notin $controlPlaneIps) { $controlPlaneIps += $ip }
            }
        }
    }
}

if ($controlPlaneIps) {
    $ipBlockYaml = ($controlPlaneIps | ForEach-Object { "    - ipBlock:`n        cidr: $_/32" }) -join "`n"
    $webhookYaml = @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-apiserver-to-webhook
  namespace: $Namespace
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: webhook
  policyTypes: ["Ingress"]
  ingress:
  - from:
$ipBlockYaml
    ports:
    - protocol: TCP
      port: 10250
"@
    $webhookYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-GroupLine "✓ NetworkPolicy exception applied (apiserver -> cert-manager-webhook:10250)" -ForegroundColor Green
    } else {
        Write-Warning "  ⚠ Failed to apply apiserver->webhook NetworkPolicy exception"
    }
} else {
    Write-Warning "  ⚠ Could not determine control-plane node IPs — cert-manager webhook may be unreachable from the API server under the new default-deny policy"
}

Complete-Group

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  No issuer yet — created later by 33-openbao/Install.ps1" -ForegroundColor Gray
Write-Host "  (RKE2/Kind: one ClusterIssuer per PKI, named 'openbao-pki-<name>')." -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
