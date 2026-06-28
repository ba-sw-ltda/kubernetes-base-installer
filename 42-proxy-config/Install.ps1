<#
.SYNOPSIS
    Create central proxy Secret and annotate for Config-Syncer distribution.
.PARAMETER Platform
    Target platform
.PARAMETER HttpProxy
    HTTP proxy URL (from Prompt.ps1)
.PARAMETER HttpsProxy
    HTTPS proxy URL (from Prompt.ps1)
.PARAMETER NoProxyExtra
    Additional NO_PROXY entries (from Prompt.ps1)
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$HttpProxy,
    [string]$HttpsProxy,
    [string]$NoProxyExtra,
    [string]$ConfigPath
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

# No proxy configured — clean up any existing proxy setup
if ([string]::IsNullOrWhiteSpace($HttpProxy)) {
    & "$ScriptRoot\Uninstall.ps1"
    exit 0
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 42 - Proxy Configuration" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$Namespace  = $FullConfig.Namespace
$UserConfig = $FullConfig.UserConfig

$noProxy = $UserConfig.NoProxyBase
if (-not [string]::IsNullOrWhiteSpace($NoProxyExtra)) {
    $noProxy = "$noProxy,$($NoProxyExtra.Trim(','))"
}

Write-Host "  Namespace:    $Namespace" -ForegroundColor Gray
Write-Host "  HTTP_PROXY:   $HttpProxy" -ForegroundColor Gray
Write-Host "  HTTPS_PROXY:  $HttpsProxy" -ForegroundColor Gray
Write-Host "  NO_PROXY:     $noProxy" -ForegroundColor Gray
Write-Host ""

# Create namespace
& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-Host "  ✓ Namespace ready" -ForegroundColor Green

# Create or update the proxy Secret, annotated for Reflector auto-sync to all namespaces
$secretYaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: $($UserConfig.SecretName)
  namespace: $Namespace
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: ""
type: Opaque
stringData:
  HTTP_PROXY: "$HttpProxy"
  HTTPS_PROXY: "$HttpsProxy"
  NO_PROXY: "$noProxy"
  http_proxy: "$HttpProxy"
  https_proxy: "$HttpsProxy"
  no_proxy: "$noProxy"
"@

$applyOutput = $secretYaml | & kubectl apply -f - 2>&1
if ($LASTEXITCODE -ne 0) {
    foreach ($line in $applyOutput) { Write-Host $line -ForegroundColor Red }
    Write-Error "Failed to apply proxy Secret"; exit 1
}
Write-Host "  ✓ Secret '$($UserConfig.SecretName)' created in '$Namespace'" -ForegroundColor Green

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Pull proxy Secret into a namespace:" -ForegroundColor Gray
Write-Host "    apiVersion: v1" -ForegroundColor Yellow
Write-Host "    kind: Secret" -ForegroundColor Yellow
Write-Host "    metadata:" -ForegroundColor Yellow
Write-Host "      annotations:" -ForegroundColor Yellow
Write-Host "        reflector.v1.k8s.emberstack.com/reflects: `"$Namespace/$($UserConfig.SecretName)`"" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
