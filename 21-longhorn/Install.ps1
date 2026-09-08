<#
.SYNOPSIS
    Install Longhorn distributed block storage and set it as the default StorageClass.
.DESCRIPTION
    Installs Longhorn via Helm, sets it as the default StorageClass, and removes the
    default annotation from the local-path StorageClass if present (RKE2 ships one).
.PARAMETER Platform
    Target platform
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER Hostname
    DNS hostname for the Longhorn UI ingress (e.g. storage.kubernetes.example.com)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$ConfigPath,
    [string]$Hostname = ""
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1"       -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 21 - Longhorn Storage" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName       = $FullConfig.ChartName
$ChartVersion    = $FullConfig.Version
$Repository      = $FullConfig.Repository
$Namespace       = $FullConfig.Namespace
$CreateNamespace = $FullConfig.CreateNamespace
$UserConfig      = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Replicas:   $($UserConfig.ReplicaCount)  |  Default StorageClass: yes" -ForegroundColor Gray
if ($Hostname) { Write-Host "  UI:         $Hostname" -ForegroundColor Gray }
Write-Host ""

Start-Group -Title "Preparation"

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "longhorn", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }

if ($CreateNamespace) {
    & kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
    Write-GroupLine "✓ Namespace ready" -ForegroundColor Green
}

$resetOk = Reset-StuckHelmRelease -ReleaseName "longhorn" -Namespace $Namespace
if ($resetOk -eq $false) { Write-Error "Could not reset Longhorn release — aborting"; exit 1 }

# Remove leftover Longhorn hook jobs — Helm never cleans up failed hook jobs automatically
& kubectl delete job longhorn-pre-upgrade  -n $Namespace --ignore-not-found 2>&1 | Out-Null
& kubectl delete job longhorn-uninstall    -n $Namespace --ignore-not-found 2>&1 | Out-Null

# Remove finalizers from any Longhorn CRDs stuck in Terminating state.
# This happens when a previous install failed: the Longhorn controller never ran to clean up
# instances, so the CRD finalizer was never removed. Without this step the CRDs stay in
# Terminating indefinitely and the new manager cannot start.
$allCrds = & kubectl get crd -o json 2>$null | ConvertFrom-Json -AsHashtable
$stuckCrds = $allCrds['items'] | Where-Object {
    $_['metadata']['name'] -like "*.longhorn.io" -and $_['metadata']['deletionTimestamp']
}
foreach ($crd in $stuckCrds) {
    & kubectl patch crd $crd['metadata']['name'] `
        -p '{"metadata":{"finalizers":[]}}' --type=merge 2>$null | Out-Null
    Write-GroupLine "✓ Removed finalizer from stuck CRD: $($crd['metadata']['name'])" -ForegroundColor Yellow
}
if ($stuckCrds) {
    Write-GroupLine "Waiting for stuck CRDs to clear..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
}

# Longhorn manages CRDs via a hook job (not in crds/ dir) so helm show crds returns nothing.
# Apply them explicitly via helm template --include-crds so the correct API versions are always
# registered before the manager starts — Helm never updates CRDs on its own.
$crdYaml = ""
$exitCode = Invoke-WithSpinner -Message "Applying Longhorn CRDs..." -Executable "helm" `
    -Arguments @("template", "longhorn", "longhorn/$ChartName", "--version", $ChartVersion,
                 "--include-crds", "--namespace", $Namespace) `
    -ShowOutput:$false -OutputVariable ([ref]$crdYaml)
if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($crdYaml)) {
    $crdOnly = ($crdYaml -split "(?m)^---") | Where-Object { $_ -match "kind:\s*CustomResourceDefinition" }
    if ($crdOnly) {
        ($crdOnly -join "`n---`n") | & kubectl apply --server-side --force-conflicts -f - 2>&1 | Out-Null
        Write-GroupLine "✓ CRDs applied" -ForegroundColor Green
    }
}

Complete-Group
Start-Group -Title "Deploy"

# Pre-emptive patch, applied BEFORE the helm upgrade below — breaks a chicken-and-egg
# deadlock discovered live 2026-09-08: if a previous install already created this
# longhorn-manager-backed Service (default internalTrafficPolicy=Cluster), the CSI
# plugin's REST calls to longhorn-backend (used on every volume attach/detach) fired by
# THIS upgrade's own manifest apply / concurrent attach traffic can route cross-node over
# the flannel.1 VXLAN and time out — wedging `helm upgrade --install longhorn` itself
# indefinitely, before it ever reaches the post-deploy patch further down (which is then
# unreachable). Best-effort and silent: on a genuinely fresh install this Service doesn't
# exist yet, so this simply no-ops and the post-deploy patch below is what applies
# instead. longhorn-admission-webhook deliberately excluded — see the post-deploy patch's
# comment for why. Same deny-list reasoning as cert-manager's fix — see the post-deploy
# patch's comment for the full root-cause writeup and $cloudHostsPlatforms definition.
if ($Platform -notin @("Azure AKS", "AWS EKS", "Google GKE", "Magalu Cloud")) {
    & kubectl patch service longhorn-backend -n $Namespace -p '{"spec":{"internalTrafficPolicy":"Local"}}' 2>$null | Out-Null
}

$HelmArgs = @(
    "upgrade", "--install", "longhorn", "longhorn/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "persistence.defaultClass=true",
    "--set", "persistence.defaultClassReplicaCount=$($UserConfig.ReplicaCount)",
    "--set", "defaultSettings.defaultReplicaCount=$($UserConfig.ReplicaCount)",
    # Chart-native ServiceMonitor (longhorn-backend:9500/metrics, port name
    # "manager") — the Prometheus Operator here only picks up ServiceMonitors
    # labeled release=prometheus, from any namespace (serviceMonitorSelector
    # matchLabels, serviceMonitorNamespaceSelector: {}). This is CRD-only —
    # no NetworkPolicy effect by itself. Confirmed missing 2026-09-01: Longhorn
    # exports rich metrics but nothing wired it into Prometheus's scrape config.
    # NOTE: scraping still needs a NetworkPolicy egress-allow from `prometheus`
    # to `longhorn-system` on this port — deliberately NOT added here, since
    # `prometheus` currently has zero NetworkPolicies (fully open) and applying
    # Set-NetworkPolicyConsumerEgress to it today would flip it to
    # deny-all-egress-except-longhorn, breaking every other scrape target
    # (kubelet, CoreDNS, apiserver, ...). Needs a real egress baseline for
    # `prometheus` first — deferred to the weekend NetworkPolicy fix alongside
    # the ingress-nginx namespace mismatch (see project_rke2_ingress_namespace_mismatch).
    "--set", "metrics.serviceMonitor.enabled=true",
    "--set", "metrics.serviceMonitor.additionalLabels.release=prometheus"
)

$exitCode = Invoke-WithSpinner -Message "Deploying Longhorn..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Longhorn (exit code $exitCode)"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Waiting for longhorn-manager (up to 20m)..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "daemonset/longhorn-manager", "-n", $Namespace, "--timeout=20m") `
    -ShowOutput:$verbose -ShowElapsed
if ($exitCode -ne 0) {
    Write-GroupLine ""
    Write-GroupLine "── Pod status ──────────────────────────────" -ForegroundColor DarkGray
    & kubectl get pods -n $Namespace -l "app=longhorn-manager" 2>&1 | ForEach-Object { Write-GroupLine "$_" }
    Write-GroupLine ""
    Write-GroupLine "── Recent events ───────────────────────────" -ForegroundColor DarkGray
    & kubectl get events -n $Namespace --sort-by='.lastTimestamp' --field-selector type=Warning 2>&1 | Select-Object -Last 10 | ForEach-Object { Write-GroupLine "$_" }
    Write-GroupLine ""
    Write-GroupLine "Tip: Longhorn requires open-iscsi on all nodes:" -ForegroundColor Yellow
    Write-GroupLine "  apt-get install -y open-iscsi && systemctl enable --now iscsid" -ForegroundColor Yellow
    Write-Error "Rollout of longhorn-manager did not complete"
    exit 1
}

# Authoritative patch — covers a fresh install, where the pre-emptive patch further up
# (right before the helm upgrade call) necessarily no-op'd because this Service didn't
# exist yet. Longhorn manager already runs as a DaemonSet (one pod per node), so unlike
# 31-cert-manager/Install.ps1's webhook fix this needs no affinity/replica
# pinning — every node already has a local backend the moment the rollout above succeeds.
# Same underlying flannel.1 cross-node VXLAN defect as cert-manager's fix (see that
# script's comment for the full root-cause writeup), but ONLY longhorn-backend gets
# patched here:
#   - longhorn-backend: the CSI plugin's REST calls (used on every volume attach/
#     detach, e.g. POST /v1/volumes/<name>?action=attach) can land on a different node's
#     pod via the Service's default internalTrafficPolicy=Cluster, and the reply on that
#     cross-node path times out ("context deadline exceeded (Client.Timeout exceeded
#     while awaiting headers)"). Confirmed live 2026-09-08: this is what stuck OpenBao's
#     PVC attach in a retry loop and cascaded into Authelia (Vault secret mount) /
#     Rancher OIDC login / Portal ForwardAuth all failing.
# longhorn-admission-webhook is deliberately EXCLUDED and, if a prior run of this script
# already set it to Local, actively reverted back to Cluster below. Originally patched to
# Local alongside longhorn-backend, but that creates a guaranteed, self-inflicted
# deadlock: the same longhorn-manager process that serves this webhook also calls it
# (synchronously, during its own startup, to validate the longhorn-default-setting
# ConfigMap) — and with internalTrafficPolicy=Local that self-call can ONLY be routed to
# the pod's own node-local endpoint, i.e. itself, which isn't Ready yet. It needs itself
# to be ready in order to become ready — every single longhorn-manager restart on every
# node fails this self-check and crash-loops forever, not just under cross-node load.
# Confirmed live 2026-09-08 via `kubectl get endpointslices ... longhorn-admission-webhook`
# showing the restarting pod's own address as its node's only (not-Ready) endpoint.
# longhorn-backend has no equivalent self-call (it's only ever called externally, by the
# CSI plugin pods), so it doesn't share this failure mode and keeps Local. Cluster policy
# reintroduces a narrower version of the original cross-node webhook-timeout risk for this
# one Service — accepted as the lesser, non-deterministic risk versus a deterministic
# restart deadlock. Deliberately NOT applied on managed-control-plane platforms — same
# reasoning and same deny-list as cert-manager's fix ($cloudHostsPlatforms, see that script).
$cloudHostsPlatforms = @("Azure AKS", "AWS EKS", "Google GKE", "Magalu Cloud")
if ($Platform -notin $cloudHostsPlatforms) {
    & kubectl patch service longhorn-backend -n $Namespace -p '{"spec":{"internalTrafficPolicy":"Local"}}' 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-GroupLine "✓ longhorn-backend Service set to internalTrafficPolicy=Local" -ForegroundColor Green
    } else {
        Write-Warning "  ⚠ Failed to set internalTrafficPolicy=Local on longhorn-backend Service"
    }
    & kubectl patch service longhorn-admission-webhook -n $Namespace -p '{"spec":{"internalTrafficPolicy":"Cluster"}}' 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-GroupLine "✓ longhorn-admission-webhook Service confirmed on internalTrafficPolicy=Cluster" -ForegroundColor Green
    } else {
        Write-Warning "  ⚠ Failed to confirm internalTrafficPolicy=Cluster on longhorn-admission-webhook Service"
    }
}

$exitCode = Invoke-WithSpinner -Message "Waiting for longhorn-driver-deployer..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/longhorn-driver-deployer", "-n", $Namespace, "--timeout=15m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of longhorn-driver-deployer did not complete"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Waiting for longhorn-ui..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/longhorn-ui", "-n", $Namespace, "--timeout=15m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of longhorn-ui did not complete"; exit 1 }

Complete-Group
Start-Group -Title "Configuration"

# Self-heal: detect and recreate engine processes wedged in "starting" state.
# Discovered live 2026-09-08: an OpenBao HA reinit (see 33-openbao/Install.ps1)
# reshuffled Longhorn replicas onto different nodes at the exact moment the
# flannel.1 cross-node VXLAN bug (patched above) was still silently active and
# undiagnosed — two engine processes got stuck mid-startup and, because a
# wedged engine never retries itself, sat there indefinitely (44h+ / 7d+ by
# the time this was found and manually root-caused) even after the network
# path was fixed. Without this check, that class of failure requires manual
# diagnosis every time — this makes the install self-heal it instead. An
# Engine CR holds no data (replicas do); deleting one is safe and just makes
# longhorn-manager's controller recreate the process fresh against the
# current, correct replica addresses. Checked twice, 30s apart, so a
# legitimately-in-progress attach (which normally resolves in seconds) isn't
# mistaken for a wedge. Not platform-gated like the Service patches above —
# an engine can get wedged for reasons other than the flannel bug, so this is
# a general safety net, not a flannel-specific fix.
function Get-WedgedLonghornEngines {
    $json = & kubectl get engines.longhorn.io -n $Namespace -o json 2>$null
    if (-not $json) { return @() }
    $engines = ($json | ConvertFrom-Json -AsHashtable)['items']
    return @($engines | Where-Object {
        $_['status']['currentState'] -eq 'starting' -and $_['status']['started'] -eq $false
    } | ForEach-Object { $_['metadata']['name'] })
}

$wedgedFirstPass = Get-WedgedLonghornEngines
if ($wedgedFirstPass.Count -gt 0) {
    Write-GroupLine "Checking $($wedgedFirstPass.Count) engine(s) stuck in 'starting'..." -ForegroundColor Yellow
    Start-Sleep -Seconds 30
    $wedgedConfirmed = @(Get-WedgedLonghornEngines | Where-Object { $_ -in $wedgedFirstPass })
    if ($wedgedConfirmed.Count -gt 0) {
        foreach ($engineName in $wedgedConfirmed) {
            & kubectl delete engines.longhorn.io $engineName -n $Namespace --ignore-not-found 2>&1 | Out-Null
            Write-GroupLine "✓ Recreated wedged engine: $engineName" -ForegroundColor Yellow
        }
    } else {
        Write-GroupLine "✓ Engine(s) resolved on their own" -ForegroundColor Green
    }
}

# Remove default annotation from local-path StorageClass (RKE2 ships with it as default)
$lpExists = & kubectl get storageclass local-path --ignore-not-found 2>&1
if ($lpExists) {
    $patch = '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    & kubectl patch storageclass local-path -p $patch 2>&1 | Out-Null
    Write-GroupLine "✓ local-path StorageClass de-defaulted" -ForegroundColor Green
}

# Ingress for Longhorn UI
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    $protect = Protect-ComponentIngress -Hostname $Hostname -Platform $Platform -BaseDir $BaseDir
    $authAnnotations = ($protect.Annotations.GetEnumerator() | ForEach-Object { "    $($_.Key): `"$($_.Value)`"" }) -join "`n"

    $ingressYaml = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ui
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
            name: longhorn-frontend
            port:
              number: 80
"@
    $applyOut = $ingressYaml | & kubectl apply -f - 2>&1
    if ($LASTEXITCODE -ne 0) {
        foreach ($line in $applyOut) { Write-GroupLine "$line" -ForegroundColor Red }
        Write-Error "Failed to create Longhorn UI Ingress"; exit 1
    }
    Write-GroupLine "✓ Ingress configured ($Hostname)" -ForegroundColor Green
    $scheme = if (-not [string]::IsNullOrWhiteSpace($protect.TlsBlock)) { "https" } else { "http" }
    $portalIcon = Get-PortalIconDataUri -ScriptRoot $ScriptRoot -IconFile $FullConfig.PortalIcon
    Register-PortalEntry -Name $FullConfig.PortalTitle -Url "${scheme}://$Hostname" `
        -Category "Storage" -Namespace $Namespace -Subtitle $FullConfig.PortalSubtitle -Order 21 `
        -InternalUrl "http://longhorn-frontend.longhorn-system.svc.cluster.local" `
        -LogoUrl $portalIcon
}

if ($verbose) {
    Write-GroupLine ""
    & kubectl get storageclass
    Write-GroupLine ""
    & kubectl get pods -n $Namespace
}

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
# Grafana's dashboard sidecar (see 66-grafana/Install.ps1 sidecar.dashboards.*
# Helm flags) via its own K8s API watch. Order-independent, no NetworkPolicy
# involved. Register-GrafanaDashboard prints its own "✓ ... registered"
# confirmation line — nothing more to print here.
Start-Group -Title "Monitoring"
Register-GrafanaDashboard -Namespace $Namespace -Name "longhorn" `
    -JsonPath "$ScriptRoot\dashboards\longhorn.json" -Folder "Storage"

# Prometheus alerting rules: vendored from the official SUSE Storage
# (Longhorn) docs (see prometheusrules/longhorn.yaml for source/provenance
# and the one description-text correction applied). Same order-independence
# as the dashboard above — Register-PrometheusRule prints its own
# confirmation line, nothing more to print here.
Register-PrometheusRule -Namespace $Namespace -Name "longhorn" `
    -YamlPath "$ScriptRoot\prometheusrules\longhorn.yaml"
Complete-Group

Start-Group -Title "Network Policy"

Install-NetworkPolicyBaseline -Namespace $Namespace
# NetworkPolicy `ports` matches the pod's real destination port after the
# Service's DNAT rewrite, not the Service's externally-advertised port — the
# longhorn-frontend Service exposes 80 but its container listens on 8000
# (confirmed 2026-08-20 against the RKE2 cluster; same bug class already
# found and fixed on 11-ingress-traefik/35-authelia/66-grafana). Resolved
# dynamically so a future chart bump can't silently reintroduce the mismatch.
$longhornPort = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "longhorn-frontend"
# Metrics port (longhorn-backend:9500) — Service port matches the container
# port directly here, no DNAT mismatch like the UI Service above (confirmed
# 2026-09-01). Bundled into the same provider-ingress rule so the
# ServiceMonitor added above (see $HelmArgs metrics.serviceMonitor.* flags)
# can actually be scraped, not just defined.
Set-NetworkPolicyProviderIngress -Namespace $Namespace -Port ($longhornPort + 9500)
# Self-register as a Prometheus scrape target instead of Prometheus
# enumerating every ServiceMonitor'd namespace centrally (compliance finding
# #1 fix). If `prometheus` doesn't exist yet, this parks a pending marker
# that 61-prometheus/Install.ps1 resolves once it does.
Set-NetworkPolicyConsumerEgress -Namespace "prometheus" -TargetNamespace $Namespace -Port ($longhornPort + 9500)
# Real namespace of whichever ingress controller is actually installed —
# "ingress" on fresh installs, but pre-rename clusters (e.g. live RKE2) can
# still have ingress-nginx in the legacy "ingress-nginx" namespace (compliance
# finding #2, NetworkPolicy audit 2026-09-05; see project_rke2_ingress_namespace_mismatch memory).
$ingressNamespace = Resolve-IngressNamespace
Set-NetworkPolicyConsumerEgress -Namespace $ingressNamespace -TargetNamespace $Namespace -Port $longhornPort

Complete-Group

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Default StorageClass: longhorn" -ForegroundColor Gray
Write-Host ""
Write-Host "  Use Longhorn explicitly:" -ForegroundColor Gray
Write-Host "    storageClassName: longhorn" -ForegroundColor Yellow
Write-Host ""
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    Write-Host "  Longhorn UI:  ${scheme}://$Hostname" -ForegroundColor Yellow
} else {
    Write-Host "  Longhorn UI (port-forward):" -ForegroundColor Gray
    Write-Host "    kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80" -ForegroundColor Yellow
    Write-Host "    → http://localhost:8080" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Node prerequisite (open-iscsi must be installed on all nodes):" -ForegroundColor Gray
Write-Host "    apt-get install -y open-iscsi && systemctl enable --now iscsid   # Debian/Ubuntu" -ForegroundColor Yellow
Write-Host "    yum install -y iscsi-initiator-utils && systemctl enable --now iscsid  # RHEL/Rocky" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0

