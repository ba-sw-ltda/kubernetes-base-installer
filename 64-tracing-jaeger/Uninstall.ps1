<#
.SYNOPSIS
    Uninstall Jaeger (called when switching to Tempo)
#>
[CmdletBinding()]
param([string]$Platform)

$existing = & helm list -n monitoring --filter "^jaeger$" --short 2>&1
if (-not $existing) { exit 0 }

Write-Host "  Removing Jaeger (switching tracing backend)..." -ForegroundColor Cyan
& helm uninstall jaeger -n monitoring 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "Could not uninstall Jaeger — continuing" }
else { Write-Host "  ✓ Jaeger removed" -ForegroundColor Green }

$pvcs = & kubectl get pvc -n monitoring -l "app.kubernetes.io/instance=jaeger" -o name 2>$null
foreach ($pvc in $pvcs) {
    & kubectl patch $pvc -n monitoring -p '{"metadata":{"finalizers":[]}}' --type=merge 2>$null | Out-Null
    & kubectl delete $pvc -n monitoring --ignore-not-found 2>$null | Out-Null
    Write-Host "  ✓ PVC removed: $($pvc -replace 'persistentvolumeclaims/','')" -ForegroundColor Green
}

exit 0
