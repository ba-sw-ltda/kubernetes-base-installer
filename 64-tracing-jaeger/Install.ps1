<#
.SYNOPSIS
    Install Jaeger (trace backend + UI)
.PARAMETER Platform
    Target platform
.PARAMETER Hostname
    Hostname for Jaeger UI ingress (from Prompt.ps1, Kind only)
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Hostname,
    [string]$ConfigPath
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 64 - Jaeger" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName    = $FullConfig.ChartName
$ChartVersion = $FullConfig.Version
$Repository   = $FullConfig.Repository
$Namespace    = $FullConfig.Namespace
$UserConfig   = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Mode:       $($UserConfig.DeploymentMode)" -ForegroundColor Gray
if ($Hostname) { Write-Host "  Hostname:   $Hostname" -ForegroundColor Gray }
Write-Host ""

& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-Host "  ✓ Namespace ready" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "jaegertracing", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

$HelmArgs = @(
    "upgrade", "--install", "--force", "jaeger", "jaegertracing/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "allInOne.enabled=$($($UserConfig.DeploymentMode -eq 'allInOne').ToString().ToLower())",
    "--set", "collector.enabled=$($($UserConfig.DeploymentMode -ne 'allInOne').ToString().ToLower())",
    "--set", "query.enabled=$($($UserConfig.DeploymentMode -ne 'allInOne').ToString().ToLower())",
    "--set", "agent.enabled=false",
    "--set", "storage.type=$($UserConfig.StorageType)",
    "--set", "allInOne.resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "allInOne.resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "allInOne.resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "allInOne.resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    "--set", "allInOne.persistence.enabled=true",
    "--set", "allInOne.persistence.size=$($UserConfig.StorageSize)",
    "--set", "storage.badger.ephemeral=false",
    "--set", "storage.badger.spanStoreTTL=$($UserConfig.Retention)"
)

Reset-StuckHelmRelease -ReleaseName "jaeger" -Namespace $Namespace

# If a StatefulSet exists without a volumeClaimTemplate, recreate it so persistence can be added.
$existingSs = & kubectl get statefulset -n $Namespace -l "app.kubernetes.io/instance=jaeger" `
    --no-headers -o custom-columns="N:.metadata.name" 2>$null | Select-Object -First 1
if ($existingSs) {
    $existingVct = & kubectl get statefulset $existingSs -n $Namespace `
        -o jsonpath='{.spec.volumeClaimTemplates}' 2>$null
    if ($existingVct -eq "[]" -or [string]::IsNullOrWhiteSpace($existingVct)) {
        $exitCode = Invoke-WithSpinner -Message "Recreating StatefulSet to add persistence..." -Executable "kubectl" `
            -Arguments @("delete", "statefulset", $existingSs, "-n", $Namespace) -ShowOutput:$verbose
    }
}

$exitCode = Invoke-WithSpinner -Message "Deploying Jaeger..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Jaeger (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

# Detect what the chart actually created — allInOne can be Deployment or StatefulSet
# depending on chart version and persistence settings.
$ssName  = & kubectl get statefulset -n $Namespace -l "app.kubernetes.io/instance=jaeger" `
    --no-headers -o custom-columns="N:.metadata.name" 2>$null | Select-Object -First 1
$depName = & kubectl get deployment  -n $Namespace -l "app.kubernetes.io/instance=jaeger" `
    --no-headers -o custom-columns="N:.metadata.name" 2>$null | Select-Object -First 1

if ($ssName) {
    $exitCode = Invoke-WithSpinner -Message "Waiting for jaeger ($ssName)..." -Executable "kubectl" `
        -Arguments @("rollout", "status", "statefulset/$ssName", "-n", $Namespace, "--timeout=5m") `
        -ShowOutput:$verbose
} elseif ($depName) {
    $exitCode = Invoke-WithSpinner -Message "Waiting for jaeger ($depName)..." -Executable "kubectl" `
        -Arguments @("rollout", "status", "deployment/$depName", "-n", $Namespace, "--timeout=5m") `
        -ShowOutput:$verbose
} else {
    Write-Error "No Jaeger StatefulSet or Deployment found in namespace $Namespace after deploy"
    exit 1
}
if ($exitCode -ne 0) { Write-Error "Rollout of Jaeger did not complete"; exit 1 }
Write-Host "  ✓ Jaeger ready" -ForegroundColor Green

if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    $protect = Protect-ComponentIngress -Hostname $Hostname -Platform $Platform
    $authAnnotations = ($protect.Annotations.GetEnumerator() | ForEach-Object { "    $($_.Key): `"$($_.Value)`"" }) -join "`n"

    $ingressYaml = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jaeger
  namespace: $Namespace
  annotations:
$authAnnotations
spec:
  ingressClassName: $(Get-IngressClass)
$($protect.TlsBlock)
  rules:
  - host: $Hostname
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: jaeger
            port:
              number: 16686
"@
    $ingressYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Ingress configured ($Hostname)" -ForegroundColor Green }
    $scheme = if (-not [string]::IsNullOrWhiteSpace($protect.TlsBlock)) { "https" } else { "http" }
    Register-PortalEntry -Name "Jaeger" -Url "${scheme}://$Hostname" `
        -Category "Observability" -Subtitle "Distributed Tracing" -Order 64 `
        -InternalUrl "http://jaeger-query.jaeger.svc.cluster.local:16686"
}

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
if ($Hostname) {
    Write-Host "  Jaeger UI:  http://$Hostname" -ForegroundColor Yellow
}
Write-Host "  OTLP gRPC (cluster-internal):" -ForegroundColor Gray
Write-Host "    jaeger-collector.${Namespace}:4317" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Grafana datasource URL:" -ForegroundColor Gray
Write-Host "    http://jaeger.${Namespace}:16686" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
