<#
.SYNOPSIS
    Reports namespaces that aren't marked as policy-managed. Never applies
    anything itself (Finding #4 — network segmentation).
.DESCRIPTION
    Every component that owns a namespace calls Install-NetworkPolicyBaseline
    for it, which stamps that namespace with the
    "network.k8s/policy-managed=true" annotation. This step runs last and
    enumerates all namespaces to find anything missing that marker.

    It only reports — it does NOT apply a NetworkPolicy baseline to
    whatever it finds, and there is deliberately no maintained exclusion
    list to auto-apply "safely" either. Both were tried and both failed in
    practice: on a live Magalu cluster this step once auto-applied a
    default-deny baseline to calico-system/calico-apiserver/tigera-operator
    (platform-managed Calico namespaces we don't own and whose traffic
    needs we don't know) and broke calico-kube-controllers, because its
    egress to the API server's external LB IP wasn't covered by the
    generic allow-list. A namespace whose traffic pattern we don't
    understand cannot be locked down safely by a generic baseline, no
    matter how well the exclusion list is maintained — so this step never
    writes anything. Any namespace it flags needs a human to look at it
    and decide (add the missing Install-NetworkPolicyBaseline call to its
    owning component, or explicitly leave it alone) — never an automatic
    write, not even from a curated allow/deny list.
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

# Kubernetes-intrinsic, never project-specific — kept out of the report
# purely to avoid permanent noise; nothing is ever written to these either.
$exactNameExclusions = @("kube-public", "kube-node-lease", "default")

$allNamespaces = & kubectl get namespace -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to list namespaces"
    exit 1
}

$stray = @()
foreach ($ns in $allNamespaces.items) {
    $name = $ns.metadata.name

    if ($name -in $exactNameExclusions) { continue }

    $managed = $ns.metadata.annotations.'network.k8s/policy-managed'
    if ($managed -eq "true") { continue }

    $stray += $name
}

if ($stray.Count -eq 0) {
    Write-Host "  ✓ No unmanaged namespaces found" -ForegroundColor Green
} else {
    Write-Host "  ! The following namespaces have no NetworkPolicy baseline" -ForegroundColor Yellow
    Write-Host "    and were NOT touched automatically — review each one:" -ForegroundColor Yellow
    foreach ($name in $stray) {
        Write-Host "    - $name" -ForegroundColor Yellow
    }
    Write-Host "`n    If it's ours: add an Install-NetworkPolicyBaseline call to its" -ForegroundColor Yellow
    Write-Host "    owning component's Install.ps1. If it isn't (platform/vendor-" -ForegroundColor Yellow
    Write-Host "    managed, e.g. Calico/Rancher/cloud-provider namespaces): leave it" -ForegroundColor Yellow
    Write-Host "    alone — we don't know its traffic needs." -ForegroundColor Yellow
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
