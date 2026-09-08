<#
.SYNOPSIS
    Applies the NetworkPolicy baseline to kube-system — the one namespace no
    installer component owns (RKE2 core + our own 32-secrets-csi-driver and
    41-config-syncer co-tenant it).
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

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 22 - Network Segmentation - Network Policies (kube-system)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath
$Namespace  = $FullConfig.Namespace

Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host ""

Start-Group -Title "Network Policy"

Install-NetworkPolicyBaseline -Namespace $Namespace

# CoreDNS must be reachable from literally every namespace in the cluster, so
# this ingress rule is intentionally NOT label-gated (namespaceSelector: {}) —
# it's the one place the opt-in label-contract pattern doesn't apply. This is
# a one-off unique to kube-system/CoreDNS, so it's not part of the generic
# Install-NetworkPolicyBaseline helper.
#
# The podSelector below has to match CoreDNS's own pods, and the label used
# for that isn't uniform across platforms: RKE2's rke2-coredns chart (and
# AKS/EKS/GKE's built-in addons) label pods "k8s-app: kube-dns" for legacy
# kube-dns compatibility, but Magalu Cloud's managed-Kubernetes CoreDNS
# chart uses "k8s-app: coredns" instead. Hardcoding either one silently
# matches zero pods on whatever platform doesn't use it — the policy still
# applies (so it looks fine), it just protects nothing, leaving CoreDNS
# reachable only from within kube-system itself (default-deny-all +
# allow-intra-namespace) and unreachable from every other namespace.
# Instead of guessing, read the real selector straight off whichever
# Service actually fronts DNS in this namespace. Originally this matched by
# Service *name* ("kube-dns"/"coredns"), on the assumption every platform
# publishes it under one of those two literal names — wrong on RKE2, whose
# rke2-coredns Helm chart names the Service "rke2-coredns-rke2-coredns"
# (release name prefixed onto the chart name), so the name-based lookup
# always missed it there, silently falling through to the fallback below
# on every single RKE2 run (confirmed live 2026-09-06 — the fallback's
# hardcoded k8s-app values happened to still be correct, so the policy was
# never actually wrong, just the discovery step and its Write-Warning were
# noise on a completely healthy run). Matching on the Service *port*
# instead of its name sidesteps the whole naming question: whatever a
# platform calls its DNS Service, kubelet's --cluster-dns points at its
# ClusterIP expecting port 53, so that's the one platform-independent
# signal every conventional DNS Service actually has to expose.
$dnsSvcJson = & kubectl get svc -n $Namespace -o json 2>$null
$dnsPodSelector = $null
if ($LASTEXITCODE -eq 0 -and $dnsSvcJson) {
    $dnsSvc = ($dnsSvcJson | ConvertFrom-Json).items |
        Where-Object {
            $_.spec.selector -and ($_.spec.ports | Where-Object { $_.port -eq 53 })
        } |
        Select-Object -First 1
    if ($dnsSvc) {
        $dnsPodSelector = $dnsSvc.spec.selector
    }
}

if ($dnsPodSelector) {
    $matchLabelsYaml = ($dnsPodSelector.PSObject.Properties | ForEach-Object {
        "      $($_.Name): $($_.Value)"
    }) -join "`n"
    $podSelectorYaml = "  podSelector:`n    matchLabels:`n$matchLabelsYaml"
} else {
    # Genuinely unusual at this point — no port-53 Service found at all in
    # this namespace — so still worth flagging rather than silently
    # guessing; the platforms this repo supports have never hit this path.
    Write-Warning "Could not discover a DNS Service (port 53) in '$Namespace' — falling back to known label conventions."
    $podSelectorYaml = @"
  podSelector:
    matchExpressions:
    - key: k8s-app
      operator: In
      values: ["kube-dns", "coredns"]
"@
}

$dnsIngressYaml = @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-ingress-from-anywhere
  namespace: $Namespace
spec:
$podSelectorYaml
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - namespaceSelector: {}
    # node-local-dns runs with hostNetwork: true, forwarding queries to
    # CoreDNS from the node's own network namespace rather than a pod IP.
    # NetworkPolicy peer matching (namespaceSelector/podSelector above)
    # never covers hostNetwork traffic — standard Kubernetes/CNI behavior,
    # not platform-specific — so without this, default-deny-all silently
    # blocks node-local-dns's own upstream queries to CoreDNS, causing DNS
    # timeouts cluster-wide. Confirmed and reproduced by Magalu support
    # (ticket re: [[project_magalu_dns_resolver_issue]], 2026-08-19); their
    # own fix used the same unscoped 0.0.0.0/0 ipBlock, so matching that
    # here rather than trying to guess/scope to the node CIDR.
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
"@
$dnsIngressYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-GroupLine "✓ CoreDNS ingress-from-anywhere rule applied" -ForegroundColor Green
} else {
    Write-Error "Failed to apply CoreDNS ingress rule in '$Namespace'"
    exit 1
}

# On managed-cloud platforms, kube-system also hosts the cloud provider's own
# infra pods (CSI controllers, cloud-controller-manager, ...) that phone home
# to that provider's HTTPS management API — e.g. Magalu's block-storage CSI
# (block.csi.magalu.cloud) calls https://api.magalu.cloud to list/create
# volumes. The generic Install-NetworkPolicyBaseline default-deny-all above
# has no rule for that, so every such call times out and PVC provisioning
# never completes. Same reasoning as the DNS external-egress rule: kube-system
# is trusted, platform-managed infrastructure, not a general app namespace, so
# an unscoped outbound-443 allowance here doesn't undermine the opt-in
# label-contract pattern used everywhere else.
#
# Same CSI drivers also need the instance metadata service on startup — e.g.
# Magalu's mgc-csi-node/mgc-csi-controller call
# http://169.254.169.254/openstack/latest/meta_data.json (port 80, not 443)
# to resolve their own region before they can serve any volume request. That
# port-80 call gets silently dropped by the same default-deny-all, which
# crash-loops both pods (liveness probe never comes up) and, transitively,
# hangs every PVC-mounting pod's pending-mount forever — including CSI mounts
# that have nothing to do with block storage themselves, since kubelet still
# has to wait for *all* volumes on the pod spec to mount. Confirmed live
# 2026-08-19: metadata endpoint answered instantly from an unprotected
# namespace, timed out identically from kube-system. Unlike the 443 rule
# above, this is scoped to the metadata service's own well-known link-local
# IP rather than 0.0.0.0/0 — no legitimate reason for kube-system pods to
# reach arbitrary hosts on port 80, and that address is a classic SSRF
# target, so there's no reason to open it wider than the one IP that needs it.
$httpsEgressYaml = @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-cloud-api-egress
  namespace: $Namespace
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
    - protocol: TCP
      port: 443
  - to:
    - ipBlock:
        cidr: 169.254.169.254/32
    ports:
    - protocol: TCP
      port: 80
"@
$httpsEgressYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-GroupLine "✓ Cloud-provider API egress rule applied" -ForegroundColor Green
} else {
    Write-Error "Failed to apply cloud-provider API egress rule in '$Namespace'"
    exit 1
}

# metrics-server (rke2-metrics-server, kube-system-native) scrapes every node's
# kubelet directly over HTTPS on 10250 — not a Service, so NetworkPolicy egress
# has to allow the node IPs themselves, not a pod/namespace selector. The
# generic default-deny-all above has no rule for that, so every scrape times
# out ("context deadline exceeded") on all nodes. Confirmed live 2026-09-08:
# metrics-server's Deployment rollout got stuck in ProgressDeadlineExceeded —
# the new pod failed its readiness probe (500, "no metrics to serve") 2800+
# times over 6+ hours, while the old pod (whose scrape connections predate
# default-deny-all, added 2026-09-07) kept working on grandfathered conntrack
# state — masking the gap until the next rollout or pod restart hit it fresh.
# That flapping between one healthy and one broken metrics-server endpoint is
# also what surfaces as intermittent "stale GroupVersion discovery" /
# "couldn't get current server API group list" noise from every client
# (kubectl, longhorn-manager, ...) that queries the metrics.k8s.io aggregated
# API. Node IPs are dynamic (added/replaced nodes, different CIDRs per
# platform), so — same reasoning as the DNS-selector discovery above — this
# reads the real InternalIP off every current Node object rather than
# hardcoding a CIDR.
$nodeIpsJson = & kubectl get nodes -o json 2>$null
$nodeIps = @()
if ($LASTEXITCODE -eq 0 -and $nodeIpsJson) {
    $nodeIps = ($nodeIpsJson | ConvertFrom-Json).items | ForEach-Object {
        ($_.status.addresses | Where-Object { $_.type -eq 'InternalIP' } | Select-Object -First 1).address
    } | Where-Object { $_ }
}

if ($nodeIps.Count -gt 0) {
    $nodeIpBlocksYaml = ($nodeIps | ForEach-Object {
        "    - ipBlock:`n        cidr: $_/32"
    }) -join "`n"
    $kubeletEgressYaml = @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-kubelet-metrics-egress
  namespace: $Namespace
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
  - to:
$nodeIpBlocksYaml
    ports:
    - protocol: TCP
      port: 10250
"@
    $kubeletEgressYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-GroupLine "✓ Kubelet-metrics egress rule applied ($($nodeIps.Count) node(s))" -ForegroundColor Green
    } else {
        Write-Error "Failed to apply kubelet-metrics egress rule in '$Namespace'"
        exit 1
    }
} else {
    Write-Warning "Could not list node InternalIPs — skipping kubelet-metrics egress rule (metrics-server scrapes will fail under default-deny-all)"
}

Complete-Group

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
