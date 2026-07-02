<#
.SYNOPSIS
    Completely removes Longhorn including CRDs, PVCs and namespace.
.DESCRIPTION
    Longhorn hinterlässt bei fehlgeschlagenen Installationen CRDs und PVCs mit Finalizers
    die manuelles Eingreifen erfordern. Dieses Script räumt alles sauber auf.
    WARNING: All Longhorn volumes and their data will be permanently deleted.
.PARAMETER Platform
    Target platform
.PARAMETER Force
    Überspringt die Sicherheitsabfrage
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [switch]$Force
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$Namespace = "longhorn-system"

Write-Host "`n========================================" -ForegroundColor Red
Write-Host "  Uninstall: Longhorn Storage" -ForegroundColor Red
Write-Host "========================================`n" -ForegroundColor Red

if (-not $Force) {
    $confirm = Read-YesNo `
        -Title "Completely remove Longhorn?" `
        -Message "WARNING: All Longhorn volumes and data will be deleted. Continue?" `
        -DefaultYes $false `
        -YesLabel "Yes — permanently remove Longhorn and all data" `
        -NoLabel  "No — abort"
    if (-not $confirm) {
        Write-Host "  Aborted." -ForegroundColor Yellow
        exit 0
    }
}

Unregister-PortalEntry -Name "Longhorn"

# ── 1. Remove Helm release ──────────────────────────────────────
Write-Host "`n--- 1. Helm Release ---" -ForegroundColor Magenta
$existing = & helm list -n $Namespace --filter "^longhorn$" --short 2>&1
if ($existing) {
    Write-Host "  Uninstalling Helm release (--no-hooks to skip broken pre-delete job)..." -ForegroundColor Cyan
    & helm uninstall longhorn -n $Namespace --no-hooks 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Helm release removed" -ForegroundColor Green }
    else { Write-Warning "  helm uninstall failed — continuing with manual cleanup" }
} else {
    Write-Host "  ✓ No Helm release found — skipping" -ForegroundColor Green
}

# ── 2. Delete hook jobs ─────────────────────────────────────────
Write-Host "`n--- 2. Hook Jobs ---" -ForegroundColor Magenta
foreach ($job in @("longhorn-pre-upgrade", "longhorn-uninstall", "longhorn-post-upgrade")) {
    & kubectl delete job $job -n $Namespace --ignore-not-found 2>&1 | Out-Null
}
Write-Host "  ✓ Hook jobs removed" -ForegroundColor Green

# ── 3. PVCs mit Longhorn StorageClass finalizer-bereinigen ───────
Write-Host "`n--- 3. Stuck Longhorn PVCs (cluster-wide) ---" -ForegroundColor Magenta
$allPvcs = & kubectl get pvc -A -o json 2>&1 | ConvertFrom-Json
$longhornPvcs = $allPvcs.items | Where-Object {
    $_.spec.storageClassName -eq "longhorn" -and $_.metadata.deletionTimestamp
}
foreach ($pvc in $longhornPvcs) {
    $ns   = $pvc.metadata.namespace
    $name = $pvc.metadata.name
    & kubectl patch pvc $name -n $ns -p '{"metadata":{"finalizers":[]}}' --type=merge 2>&1 | Out-Null
    Write-Host "  ✓ Finalizer removed from PVC: $ns/$name" -ForegroundColor Yellow
}
if (-not $longhornPvcs) {
    Write-Host "  ✓ No stuck Longhorn PVCs found" -ForegroundColor Green
}

# ── 4. Remove Longhorn CRD instance finalizers ──────────────────
# CRD deletion will hang if instances still have finalizers.
# Without the Longhorn controller, finalizers are never auto-removed.
Write-Host "`n--- 4. Longhorn Resource Finalizers ---" -ForegroundColor Magenta
$allCrdsRaw = & kubectl get crd -o json --request-timeout=30s 2>&1
$longhornCrds = @()
try {
    $allCrds = $allCrdsRaw | ConvertFrom-Json -ErrorAction Stop
    $longhornCrds = @($allCrds.items | Where-Object { $_.metadata.name -like "*.longhorn.io" })
} catch {
    Write-Warning "  Could not list CRDs — trying by known names"
    $knownCrds = @("engines","volumes","replicas","nodes","instancemanagers","engineimages",
                   "backuptargets","backupvolumes","backups","snapshots","recurringjobs",
                   "supportbundles","systembackups","systemrestores","volumeattachments") |
                 ForEach-Object { "$_.longhorn.io" }
    $longhornCrds = $knownCrds | ForEach-Object {
        $r = & kubectl get crd $_ --ignore-not-found 2>$null
        if ($r) { [PSCustomObject]@{ metadata = @{ name = $_ } } }
    } | Where-Object { $_ }
}

foreach ($crd in $longhornCrds) {
    $crdName = $crd.metadata.name
    $frames  = @('|','/','-','\'); $fi = 0
    [Console]::Write("`r  $($frames[$fi++ % 4]) Clearing $crdName...")

    $instances = & kubectl get $crdName -A --no-headers 2>$null
    if ($instances) {
        foreach ($line in ($instances -split "`n" | Where-Object { $_ })) {
            $parts = $line -split '\s+'
            $ns    = $parts[0]
            $name  = $parts[1]
            & kubectl patch $crdName $name -n $ns `
                -p '{"metadata":{"finalizers":[]}}' --type=merge 2>$null | Out-Null
        }
    }
    # Remove finalizer from the CRD itself too
    & kubectl patch crd $crdName -p '{"metadata":{"finalizers":[]}}' --type=merge 2>$null | Out-Null
}
[Console]::Write("`r" + (" " * 60) + "`r")

if ($longhornCrds) {
    Write-Host "  ✓ Finalizers removed from $($longhornCrds.Count) CRD(s) and their instances" -ForegroundColor Green
} else {
    Write-Host "  ✓ No Longhorn CRDs found" -ForegroundColor Green
}

# ── 5. Delete Longhorn CRDs ─────────────────────────────────────
Write-Host "`n--- 5. Delete Longhorn CRDs ---" -ForegroundColor Magenta
foreach ($crd in $longhornCrds) {
    & kubectl delete crd $crd.metadata.name --ignore-not-found --request-timeout=15s 2>&1 | Out-Null
    Write-Host "  ✓ Deleted CRD: $($crd.metadata.name)" -ForegroundColor Yellow
}
if (-not $longhornCrds) {
    Write-Host "  ✓ No Longhorn CRDs to delete" -ForegroundColor Green
}

# ── 6. Delete namespace and wait ────────────────────────────────
Write-Host "`n--- 6. Namespace ---" -ForegroundColor Magenta
$nsExists = & kubectl get namespace $Namespace --ignore-not-found 2>&1
if ($nsExists) {
    Write-Host "  Deleting namespace $Namespace..." -ForegroundColor Cyan
    & kubectl delete namespace $Namespace --ignore-not-found 2>&1 | Out-Null

    $maxWait = 120
    $elapsed = 0
    while ($elapsed -lt $maxWait) {
        $still = & kubectl get namespace $Namespace --ignore-not-found 2>&1
        if (-not $still) { break }
        Start-Sleep -Seconds 5
        $elapsed += 5
        Write-Host "  Waiting for namespace deletion... ($elapsed`s)" -ForegroundColor DarkGray
    }

    if ($elapsed -ge $maxWait) {
        Write-Warning "  Namespace still present after ${maxWait}s — may need manual cleanup"
    } else {
        Write-Host "  ✓ Namespace $Namespace deleted" -ForegroundColor Green
    }
} else {
    Write-Host "  ✓ Namespace not found — skipping" -ForegroundColor Green
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Longhorn completely removed" -ForegroundColor Green
Write-Host "  Bereit für Neuinstallation" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

exit 0


