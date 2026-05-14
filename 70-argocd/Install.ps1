<#
.SYNOPSIS
    Install ArgoCD
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER Platform
    Target platform (Azure AKS, AWS EKS, Google GKE, RKE2, Kind)
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Platform,
    [string]$Hostname
)

$ScriptRoot = $PSScriptRoot
$BaseDir = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 70 - ArgoCD" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName       = $FullConfig.ChartName
$ChartVersion    = $FullConfig.Version
$Repository      = $FullConfig.Repository
$Namespace       = $FullConfig.Namespace
$CreateNamespace = $FullConfig.CreateNamespace
$UserConfig      = $FullConfig.UserConfig

# Effective values: UserConfig + platform overrides
$serviceType = $UserConfig.ServerServiceType

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Service:    $serviceType  |  CPU: $($UserConfig.Resources.Limits.Cpu)  |  Memory: $($UserConfig.Resources.Limits.Memory)" -ForegroundColor Gray
if ($Hostname) { Write-Host "  Hostname:   $Hostname" -ForegroundColor Gray }
Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "argo", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

if ($CreateNamespace) {
    & kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
    Write-Host "  ✓ Namespace ready" -ForegroundColor Green
}

# Pull proxy Secret from proxy-config namespace via Reflector (only when proxy-config source exists)
& kubectl get secret proxy-config -n proxy-config 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    $reflectedSecret = @"
apiVersion: v1
kind: Secret
metadata:
  name: proxy-config
  namespace: $Namespace
  annotations:
    reflector.v1.k8s.emberstack.com/reflects: "proxy-config/proxy-config"
type: Opaque
"@
    $reflectedSecret | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Proxy Secret reflected into $Namespace" -ForegroundColor Green
    }
}

$HelmArgs = @(
    "upgrade", "--install", "--force", "argocd", "argo/$ChartName",
    "--namespace", $Namespace, "--version", $ChartVersion,
    "--set", "global.nameOverride=argocd",
    "--set", "server.service.type=$serviceType",
    "--set", "server.resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "server.resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "server.resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "server.resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    "--set", "repoServer.resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "repoServer.resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "repoServer.resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "repoServer.resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    "--set", "controller.resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "controller.resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "controller.resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "controller.resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    "--set", "server.insecure=$($UserConfig.ServerInsecure.ToString().ToLower())"
)


$exitCode = Invoke-WithSpinner -Message "Deploying ArgoCD..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy ArgoCD (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$deployments = @("argocd-server", "argocd-repo-server", "argocd-applicationset-controller", "argocd-notifications-controller")
foreach ($dep in $deployments) {
    $exitCode = Invoke-WithSpinner -Message "Waiting for $dep..." -Executable "kubectl" `
        -Arguments @("rollout", "status", "deployment/$dep", "-n", $Namespace, "--timeout=10m") `
        -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Rollout of $dep did not complete — check cluster state"; exit 1 }
    Write-Host "  ✓ $dep ready" -ForegroundColor Green
}

if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    $ingressYaml = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: $Namespace
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: $(Get-IngressClass)
  rules:
  - host: $Hostname
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
"@
    $applyOut = $ingressYaml | & kubectl apply -f - 2>&1
    if ($LASTEXITCODE -ne 0) {
        foreach ($line in $applyOut) { Write-Host $line -ForegroundColor Red }
        Write-Error "Failed to create ArgoCD Ingress"; exit 1
    }
    Write-Host "  ✓ Ingress configured ($Hostname)" -ForegroundColor Green
}

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace
}

$password = & kubectl -n $Namespace get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>&1
if ($LASTEXITCODE -eq 0) {
    $decodedPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($password))
    Write-Host "`n  Initial admin password: $decodedPassword" -ForegroundColor Yellow
    Write-Host "  (Only valid for first login)" -ForegroundColor Gray
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    Write-Host "  Access:  http://$Hostname" -ForegroundColor Yellow
} elseif ($serviceType -eq "LoadBalancer") {
    $ip = & kubectl get svc argocd-server -n $Namespace -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>&1
    Write-Host "  Access:  https://${ip}:443" -ForegroundColor Yellow
} else {
    Write-Host "  Service type: $serviceType — configure access per platform." -ForegroundColor Gray
}
Write-Host ""
Write-Host "  ArgoCD Application:" -ForegroundColor Gray
Write-Host "    apiVersion: argoproj.io/v1alpha1" -ForegroundColor Yellow
Write-Host "    kind: Application" -ForegroundColor Yellow
Write-Host "    spec.source.repoURL: <git-url>" -ForegroundColor Yellow
Write-Host "    spec.destination.namespace: <target-ns>" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
