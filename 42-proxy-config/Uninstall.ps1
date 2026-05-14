<#
.SYNOPSIS
    Remove proxy Secret and all reflected copies across namespaces.
#>
[CmdletBinding()]
param()

# Nothing to do if source Secret doesn't exist
& kubectl get secret proxy-config -n proxy-config 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { exit 0 }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Removing: 42 - Proxy Configuration" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Find and delete all reflected copies
$allSecrets = & kubectl get secrets -A -o json 2>&1 | ConvertFrom-Json -AsHashTable
if ($LASTEXITCODE -eq 0 -and $allSecrets['items']) {
    $reflected = $allSecrets['items'] | Where-Object {
        $ann = $_['metadata']['annotations']
        $ann -and $ann['reflector.v1.k8s.emberstack.com/reflects'] -eq "proxy-config/proxy-config"
    }
    foreach ($s in $reflected) {
        $sName = $s['metadata']['name']
        $sNs   = $s['metadata']['namespace']
        & kubectl delete secret $sName -n $sNs 2>&1 | Out-Null
        Write-Host "  ✓ Removed reflected Secret from '$sNs'" -ForegroundColor Gray
    }
}

# Delete source Secret and namespace
& kubectl delete secret proxy-config -n proxy-config 2>&1 | Out-Null
& kubectl delete namespace proxy-config 2>&1 | Out-Null
Write-Host "  ✓ Proxy configuration removed" -ForegroundColor Green

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Removal Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
