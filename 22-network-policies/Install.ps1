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
# Service actually fronts DNS in this namespace — every platform we
# support publishes it under one of the two conventional names
# ("kube-dns" or "coredns"), so its .spec.selector is always the ground
# truth for whatever labels that platform's CoreDNS pods actually carry.
$dnsSvcJson = & kubectl get svc -n $Namespace -o json 2>$null
$dnsPodSelector = $null
if ($LASTEXITCODE -eq 0 -and $dnsSvcJson) {
    $dnsSvc = ($dnsSvcJson | ConvertFrom-Json).items |
        Where-Object { $_.metadata.name -in @('kube-dns', 'coredns') } |
        Select-Object -First 1
    if ($dnsSvc -and $dnsSvc.spec.selector) {
        $dnsPodSelector = $dnsSvc.spec.selector
    }
}

if ($dnsPodSelector) {
    $matchLabelsYaml = ($dnsPodSelector.PSObject.Properties | ForEach-Object {
        "      $($_.Name): $($_.Value)"
    }) -join "`n"
    $podSelectorYaml = "  podSelector:`n    matchLabels:`n$matchLabelsYaml"
} else {
    Write-Warning "Could not discover the DNS Service's selector in '$Namespace' (no 'kube-dns' or 'coredns' Service found) — falling back to known label conventions."
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
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
"@
$dnsIngressYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ CoreDNS ingress-from-anywhere rule applied" -ForegroundColor Green
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
"@
$httpsEgressYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ Cloud-provider API egress rule applied" -ForegroundColor Green
} else {
    Write-Error "Failed to apply cloud-provider API egress rule in '$Namespace'"
    exit 1
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
