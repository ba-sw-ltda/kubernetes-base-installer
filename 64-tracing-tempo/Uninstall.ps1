<#
.SYNOPSIS
    Uninstall Grafana Tempo (called when switching to Jaeger)
#>
[CmdletBinding()]
param([string]$Platform)

$existing = & helm list -n monitoring --filter "^tempo$" --short 2>&1
if (-not $existing) { exit 0 }

Write-Host "  Removing Tempo (switching tracing backend)..." -ForegroundColor Cyan
& helm uninstall tempo -n monitoring 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "Could not uninstall Tempo — continuing" }
else { Write-Host "  ✓ Tempo removed" -ForegroundColor Green }

$pvcs = & kubectl get pvc -n monitoring -l "app.kubernetes.io/instance=tempo" -o name 2>$null
foreach ($pvc in $pvcs) {
    & kubectl patch $pvc -n monitoring -p '{"metadata":{"finalizers":[]}}' --type=merge 2>$null | Out-Null
    & kubectl delete $pvc -n monitoring --ignore-not-found 2>$null | Out-Null
    Write-Host "  ✓ PVC removed: $($pvc -replace 'persistentvolumeclaims/','')" -ForegroundColor Green
}

exit 0
