<#
.SYNOPSIS
    Defense-in-depth sweep: applies the NetworkPolicy baseline to any
    namespace that isn't already marked as policy-managed by its own
    component's Install.ps1 (Finding #4 — network segmentation).
.DESCRIPTION
    Every component that owns a namespace calls Install-NetworkPolicyBaseline
    for it, which stamps that namespace with the
    "network.k8s/policy-managed=true" annotation. This sweep runs last,
    enumerates all namespaces, and catches anything missing that marker —
    a forgotten or stray namespace — rather than relying on a maintained
    list of "already handled" namespace names.

    A few namespace categories are excluded on purpose, since "missing the
    marker" alone can't distinguish "forgotten" from "deliberately out of
    bounds":
      - Rancher-dynamic namespaces (cattle-*, fleet-*, p-*, u-*, user-*,
        local) — matched by name pattern so new project/cluster namespaces
        Rancher creates later stay excluded with no upkeep.
      - kube-public / kube-node-lease / default — fixed Kubernetes-intrinsic
        namespaces, not project-specific.
      - navios-vwkotc2 / external-secrets — deferred to other findings
        (see exclusion list below).
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
Write-Host "  Installing: 95 - Network Policy Safety Net" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Rancher creates these dynamically per project/cluster/user — genuinely
# outside our control, not "forgotten".
$namePatternExclusions = @("cattle-*", "fleet-*", "p-*", "u-*", "user-*", "local")

# Kubernetes-intrinsic, not project-specific.
$exactNameExclusions = @("kube-public", "kube-node-lease", "default")

# Deferred to other findings — remove each line once that finding resolves.
$exactNameExclusions += "navios-vwkotc2"     # Finding #3 (deferred)
$exactNameExclusions += "external-secrets"   # Finding #12 (not yet reached)

$allNamespaces = & kubectl get namespace -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to list namespaces"
    exit 1
}

$stray = @()
foreach ($ns in $allNamespaces.items) {
    $name = $ns.metadata.name

    if ($name -in $exactNameExclusions) { continue }
    if (($namePatternExclusions | Where-Object { $name -like $_ }) ) { continue }

    $managed = $ns.metadata.annotations.'network.k8s/policy-managed'
    if ($managed -eq "true") { continue }

    $stray += $name
}

if ($stray.Count -eq 0) {
    Write-Host "  ✓ No unmanaged namespaces found" -ForegroundColor Green
} else {
    foreach ($name in $stray) {
        Install-NetworkPolicyBaseline -Namespace $name
    }
    Write-Host "`n  Swept the following previously-unmanaged namespaces:" -ForegroundColor Yellow
    foreach ($name in $stray) {
        Write-Host "  - $name" -ForegroundColor Yellow
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
