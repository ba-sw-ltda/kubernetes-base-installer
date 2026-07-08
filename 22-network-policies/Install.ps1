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
$dnsIngressYaml = @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-ingress-from-anywhere
  namespace: $Namespace
spec:
  podSelector:
    matchLabels:
      k8s-app: kube-dns
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

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
