<#
.SYNOPSIS
    Install Traefik Ingress Controller
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
Import-Module "$BaseDir\_lib\Installer.Ui.psm1"         -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1"   -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: Traefik Ingress Controller" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$extraArgs = if ($verbose) { @{ Verbose = $true } } else { @{} }
$otherUninstall = Join-Path $BaseDir "11-ingress-nginx\Uninstall.ps1"

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName       = $FullConfig.ChartName
$ChartVersion    = $FullConfig.Version
$Repository      = $FullConfig.Repository
$Namespace       = $FullConfig.Namespace
$CreateNamespace = $FullConfig.CreateNamespace
$UserConfig      = $FullConfig.UserConfig

$serviceType = $UserConfig.ServiceType

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Service:    $serviceType  |  CPU: $($UserConfig.Resources.Limits.Cpu)  |  Memory: $($UserConfig.Resources.Limits.Memory)" -ForegroundColor Gray
Write-Host ""

# Runs — and, if anything is actually found, opens/closes its own group —
# before "Preparation" starts, rather than as the first (ungrouped-looking)
# action inside it. See 11-ingress-nginx/Uninstall.ps1 for why: it used to
# print flat Write-Host lines squeezed under "▸ Preparation" with no group
# marker of its own (user-flagged 2026-09-05).
if (Test-Path $otherUninstall) {
    & $otherUninstall -Platform $Platform @extraArgs
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to remove NGINX ingress controller"; exit 1 }
}

Start-Group -Title "Preparation"

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "traefik", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }

if ($CreateNamespace) {
    & kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
    Write-GroupLine "✓ Namespace ready" -ForegroundColor Green
}

$HelmArgs = @(
    "upgrade", "--install", "--force", "traefik", "traefik/$ChartName",
    "--namespace", $Namespace, "--version", $ChartVersion,
    "--set", "service.type=$serviceType",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    # Chart-native ServiceMonitor (traefik:9100/metrics) — same
    # release=prometheus label convention as every other ServiceMonitor in
    # this repo (see 21-longhorn/Install.ps1), since the Prometheus Operator
    # here only picks up ServiceMonitors carrying that label. CRD-only, no
    # NetworkPolicy effect by itself — the metrics port is bundled into the
    # provider-ingress rule below.
    "--set", "metrics.prometheus.serviceMonitor.enabled=true",
    "--set", "metrics.prometheus.serviceMonitor.additionalLabels.release=prometheus"
)
if ($UserConfig.HostPortWeb -gt 0) {
    $HelmArgs += @("--set", "ports.web.hostPort=$($UserConfig.HostPortWeb)")
}
if ($UserConfig.HostPortSecure -gt 0) {
    $HelmArgs += @("--set", "ports.websecure.hostPort=$($UserConfig.HostPortSecure)")
}
if ($UserConfig.MetalLbPool) {
    $HelmArgs += @("--set", "service.annotations.metallb\.universe\.tf/address-pool=$($UserConfig.MetalLbPool)")
}

Complete-Group

Start-Group -Title "Deploy"

Reset-StuckHelmRelease -ReleaseName "traefik" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying Traefik..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Traefik (exit code $exitCode)"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Waiting for rollout..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/traefik", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout did not complete — check cluster state"; exit 1 }

# Cloud platforms: wait for LoadBalancer external IP and write to .ingress-ip for Install-Base.ps1
$ipStateFile = Join-Path $BaseDir ".ingress-ip"
Remove-Item $ipStateFile -Force -ErrorAction SilentlyContinue
if ($Platform -eq "Azure AKS" -or $Platform -eq "Google GKE") {
    # Get-AksIngressIp already prints its own "Waiting for ingress LoadBalancer
    # IP..." spinner (with live elapsed time) and its own "✓ External IP: ..."
    # line on success — don't duplicate either message here.
    $externalIp = Get-AksIngressIp -Namespace $Namespace
    if ($externalIp) {
        Set-Content -Path $ipStateFile -Value $externalIp -Encoding UTF8
    } else {
        Write-Warning "  ⚠ Could not resolve external IP — update hosts file manually"
    }
} elseif ($Platform -eq "AWS EKS") {
    # Get-EksIngressIp likewise prints its own waiting/success messages.
    $externalIp = Get-EksIngressIp -Namespace $Namespace
    if ($externalIp) {
        Set-Content -Path $ipStateFile -Value $externalIp -Encoding UTF8
    } else {
        Write-Warning "  ⚠ Could not resolve external IP — update hosts file manually"
    }
} elseif ($Platform -eq "Magalu Cloud") {
    # Magalu's managed LoadBalancer exposes a raw IP on the Service status
    # (like AKS/GKE, not a hostname like EKS's ELB) — same polling shape as
    # Get-AksIngressIp despite the name. Same duplicate-message caveat as above.
    $externalIp = Get-AksIngressIp -Namespace $Namespace
    if ($externalIp) {
        Set-Content -Path $ipStateFile -Value $externalIp -Encoding UTF8
    } else {
        Write-Warning "  ⚠ Could not resolve external IP — update hosts file manually"
    }
}

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace -l app.kubernetes.io/name=traefik
}

Complete-Group

Start-Group -Title "Housekeeping"

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
    Write-GroupLine "✓ Assigned to Rancher project '$($FullConfig.RancherProject)'" -ForegroundColor Green
}

# Grafana dashboard: ConfigMap labeled grafana_dashboard=1, picked up live by
# Grafana's dashboard sidecar (see 66-grafana/Install.ps1 sidecar.dashboards.*
# Helm flags). Order-independent, no NetworkPolicy involved — same pattern as
# 21-longhorn/Install.ps1.
Register-GrafanaDashboard -Namespace $Namespace -Name "traefik" `
    -JsonPath "$ScriptRoot\dashboards\traefik.json" -Folder "Networking"
Write-GroupLine "✓ Grafana dashboard registered" -ForegroundColor Green

# Every component that wants ingress traffic registers itself — see its own
# Install.ps1 (Set-NetworkPolicyConsumerEgress -Namespace "ingress" -TargetNamespace <self>).
# This namespace only sets up its own baseline; it doesn't know or care who's behind it.
Install-NetworkPolicyBaseline -Namespace $Namespace
Write-GroupLine "✓ NetworkPolicy baseline installed" -ForegroundColor Green

# Install-NetworkPolicyBaseline's default-deny-all has no concept of "this
# namespace is a public entrypoint" — it treats every namespace the same.
# Traefik is the one namespace in the whole platform that genuinely needs to
# accept ingress from literally anywhere (the cloud LoadBalancer / the
# on-prem VIP forward traffic in from outside the cluster entirely, not from
# another labeled namespace), so — same special-case reasoning as CoreDNS's
# unscoped ipBlock 0.0.0.0/0 rule in 22-network-policies/Install.ps1 — this
# doesn't fit the opt-in label-contract pattern used for app-to-app traffic
# and needs its own unscoped rule here. Without it, default-deny-all silently
# blocks every external connection to Traefik on 80/443, which is
# indistinguishable from the outside from a dead ingress controller (TCP
# connects, then resets/closes — confirmed live 2026-08-19 on Magalu:
# ERR_CONNECTION_CLOSED in-browser, curl showed "Recv failure: Connection
# was reset" on port 80 and a failed TLS handshake on 443).
#
# Selector is read straight off Traefik's own Service (same defensive
# pattern as the DNS block in 22-network-policies/Install.ps1) rather than
# hardcoded, so a future chart bump that changes the pod labels can't
# silently make this rule match zero pods.
$traefikSvcJson = & kubectl get svc traefik -n $Namespace -o json 2>$null
$traefikPodSelector = $null
if ($LASTEXITCODE -eq 0 -and $traefikSvcJson) {
    $traefikSvc = $traefikSvcJson | ConvertFrom-Json
    if ($traefikSvc.spec.selector) {
        $traefikPodSelector = $traefikSvc.spec.selector
    }
}

if ($traefikPodSelector) {
    $matchLabelsYaml = ($traefikPodSelector.PSObject.Properties | ForEach-Object {
        "      $($_.Name): $($_.Value)"
    }) -join "`n"
    $podSelectorYaml = "  podSelector:`n    matchLabels:`n$matchLabelsYaml"
} else {
    Write-Warning "Could not discover the Traefik Service's selector in '$Namespace' — falling back to known chart label convention."
    $podSelectorYaml = @"
  podSelector:
    matchLabels:
      app.kubernetes.io/name: traefik
"@
}

# A NetworkPolicy's `ports` list matches the pod's real destination port
# after the Service's DNAT rewrites it — i.e. Traefik's actual container
# ports (8000/8443 in this chart), not the Service's externally-advertised
# port (80/443). Hardcoding 80/443 here silently matched zero real traffic:
# default-deny-all then ate every external/NodePort/LoadBalancer request to
# Traefik, while requests from another pod inside this same namespace kept
# working (allow-intra-namespace has no port restriction), which is exactly
# why this went undetected through multiple rounds of "the cluster is
# broken" diagnosis — confirmed live 2026-08-20 on Magalu: this bug alone
# fully explained a 100%-timeout ClusterIP/external-LB path that looked
# identical to a platform-level connectivity defect. Resolve-ServiceRealPorts
# resolves the Service's targetPort(s) — numeric or named — against the live
# pod's actual containerPort list instead of assuming any specific numbers,
# so a future chart bump can't silently reintroduce the same mismatch.
$resolvedPorts = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "traefik"
if ($resolvedPorts.Count -gt 0) {
    $portsYaml = ($resolvedPorts | ForEach-Object { "    - protocol: TCP`n      port: $_" }) -join "`n"
} else {
    Write-Warning "Could not resolve Traefik's real container ports from its Service — falling back to 80/443, which will NOT match actual traffic if the chart's targetPorts differ (as they do by default: 8000/8443)."
    $portsYaml = "    - protocol: TCP`n      port: 80`n    - protocol: TCP`n      port: 443"
}

$publicIngressYaml = @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-public-web-ingress
  namespace: $Namespace
spec:
$podSelectorYaml
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
$portsYaml
"@
$publicIngressYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-GroupLine "✓ Public web ingress rule applied (container ports: $($resolvedPorts -join ', '))" -ForegroundColor Green
} else {
    Write-Error "Failed to apply public web ingress rule in '$Namespace'"
    exit 1
}

# Metrics scrape port (traefik:9100), bundled separately from the unscoped
# public-web-ingress rule above — that rule is deliberately world-open
# (0.0.0.0/0) for ports 80/443 only; /metrics must NOT be reachable from the
# internet. Set-NetworkPolicyProviderIngress instead gates ingress on the
# label-contract pattern (only namespaces labeled network.k8s/allow-$Namespace
# may reach this port) — inert until `prometheus` is labeled as a consumer,
# same deliberate gap as 21-longhorn/Install.ps1 (see its NOTE on why
# `prometheus`'s own egress side is deferred to the weekend NetworkPolicy fix).
Set-NetworkPolicyProviderIngress -Namespace $Namespace -Port 9100
Write-GroupLine "✓ Metrics scrape port allowed" -ForegroundColor Green

Complete-Group

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Ingress (Standard):" -ForegroundColor Gray
Write-Host "    ingressClassName: traefik" -ForegroundColor Yellow
Write-Host "    cert-manager.io/cluster-issuer: <issuer>" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Traefik-spezifische Annotations:" -ForegroundColor Gray
Write-Host "    traefik.ingress.kubernetes.io/router.entrypoints: websecure" -ForegroundColor Yellow
Write-Host "    traefik.ingress.kubernetes.io/router.tls: 'true'" -ForegroundColor Yellow
Write-Host ""
Write-Host "  IngressRoute (Traefik-nativ):" -ForegroundColor Gray
Write-Host "    apiVersion: traefik.io/v1alpha1" -ForegroundColor Yellow
Write-Host "    kind: IngressRoute" -ForegroundColor Yellow
Write-Host "    spec.entryPoints: [websecure]" -ForegroundColor Yellow
Write-Host "    spec.tls.certResolver: <resolver>" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
