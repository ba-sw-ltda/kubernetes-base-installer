<#
.SYNOPSIS
    Uninstall Grafana Tempo (called when switching to Jaeger)
#>
[CmdletBinding()]
param([string]$Platform)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$existing = & helm list -n tempo --filter "^tempo$" --short 2>&1
if (-not $existing) { exit 0 }

$result = Invoke-ScriptBlockWithSpinner -Message "Uninstalling Tempo..." -ScriptBlock {
    param($path, $kubeconfig)
    $env:PATH = $path
    if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }

    & helm uninstall tempo -n tempo 2>&1 | Out-Null
    $helmExit = $LASTEXITCODE

    $pvcs = & kubectl get pvc -n tempo -l "app.kubernetes.io/instance=tempo" -o name 2>$null
    foreach ($pvc in $pvcs) {
        & kubectl patch $pvc -n tempo -p '{"metadata":{"finalizers":[]}}' --type=merge 2>$null | Out-Null
        & kubectl delete $pvc -n tempo --ignore-not-found 2>$null | Out-Null
    }

    [PSCustomObject]@{ ExitCode = $helmExit }
} -ArgumentList @($env:PATH, $env:KUBECONFIG) | Select-Object -Last 1

if ($result.ExitCode -ne 0) {
    Write-Warning "Could not uninstall Tempo — continuing"
} else {
    Write-Host "  ✓ Tempo removed" -ForegroundColor Green
}

exit 0
