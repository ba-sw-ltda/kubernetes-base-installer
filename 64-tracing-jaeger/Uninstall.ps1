<#
.SYNOPSIS
    Uninstall Jaeger (called when switching to Tempo)
#>
[CmdletBinding()]
param([string]$Platform)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$existing = & helm list -n jaeger --filter "^jaeger$" --short 2>&1
if (-not $existing) { exit 0 }

$result = Invoke-ScriptBlockWithSpinner -Message "Uninstalling Jaeger..." -ScriptBlock {
    param($path, $kubeconfig)
    $env:PATH = $path
    if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }

    & helm uninstall jaeger -n jaeger 2>&1 | Out-Null
    $helmExit = $LASTEXITCODE

    $pvcs = & kubectl get pvc -n jaeger -l "app.kubernetes.io/instance=jaeger" -o name 2>$null
    foreach ($pvc in $pvcs) {
        & kubectl patch $pvc -n jaeger -p '{"metadata":{"finalizers":[]}}' --type=merge 2>$null | Out-Null
        & kubectl delete $pvc -n jaeger --ignore-not-found 2>$null | Out-Null
    }

    [PSCustomObject]@{ ExitCode = $helmExit }
} -ArgumentList @($env:PATH, $env:KUBECONFIG) | Select-Object -Last 1

Unregister-PortalEntry -Name "Jaeger" -Order 64 *>$null

if ($result.ExitCode -ne 0) {
    Write-Warning "Could not uninstall Jaeger — continuing"
} else {
    Write-Host "  ✓ Jaeger removed" -ForegroundColor Green
}

exit 0
