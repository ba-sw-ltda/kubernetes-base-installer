<#
.SYNOPSIS
    Install Traefik Ingress Controller
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
Import-Module "$BaseDir\_lib\Installer.Ui.psm1"         -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1"   -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: Traefik Ingress Controller" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$extraArgs = if ($verbose) { @{ Verbose = $true } } else { @{} }
$otherUninstall = Join-Path $BaseDir "11-ingress-nginx\Uninstall.ps1"
if (Test-Path $otherUninstall) {
    & $otherUninstall -Platform $Platform @extraArgs
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to remove NGINX ingress controller"; exit 1 }
}

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName       = $FullConfig.ChartName
$ChartVersion    = $FullConfig.Version
$Repository      = $FullConfig.Repository
$Namespace       = $FullConfig.Namespace
$CreateNamespace = $FullConfig.CreateNamespace
$UserConfig      = $FullConfig.UserConfig

$serviceType = $UserConfig.ServiceType

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Service:    $serviceType  |  CPU: $($UserConfig.Resources.Limits.Cpu)  |  Memory: $($UserConfig.Resources.Limits.Memory)" -ForegroundColor Gray
Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "traefik", $Repository, "--force-update") -ShowOutput:$verbose
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

$HelmArgs = @(
    "upgrade", "--install", "--force", "traefik", "traefik/$ChartName",
    "--namespace", $Namespace, "--version", $ChartVersion,
    "--set", "service.type=$serviceType",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)"
)
if ($UserConfig.HostPortWeb -gt 0) {
    $HelmArgs += @("--set", "ports.web.hostPort=$($UserConfig.HostPortWeb)")
}
if ($UserConfig.HostPortSecure -gt 0) {
    $HelmArgs += @("--set", "ports.websecure.hostPort=$($UserConfig.HostPortSecure)")
}
if ($UserConfig.MetalLbPool) {
    $HelmArgs += @("--set", "service.annotations.metallb\.universe\.tf/address-pool=$($UserConfig.MetalLbPool)")
}

Reset-StuckHelmRelease -ReleaseName "traefik" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying Traefik..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Traefik (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for rollout..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/traefik", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout did not complete — check cluster state"; exit 1 }
Write-Host "  ✓ Rollout complete" -ForegroundColor Green

# Cloud platforms: wait for LoadBalancer external IP and write to .ingress-ip for Install-Base.ps1
$ipStateFile = Join-Path $BaseDir ".ingress-ip"
Remove-Item $ipStateFile -Force -ErrorAction SilentlyContinue
if ($Platform -eq "Azure AKS" -or $Platform -eq "Google GKE") {
    Write-Host "`n  Waiting for LoadBalancer external IP..." -ForegroundColor Cyan
    $externalIp = Get-AksIngressIp -Namespace $Namespace
    if ($externalIp) {
        Set-Content -Path $ipStateFile -Value $externalIp -Encoding UTF8
        Write-Host "  ✓ External IP: $externalIp" -ForegroundColor Green
    } else {
        Write-Warning "  ⚠ Could not resolve external IP — update hosts file manually"
    }
} elseif ($Platform -eq "AWS EKS") {
    Write-Host "`n  Waiting for LoadBalancer external IP..." -ForegroundColor Cyan
    $externalIp = Get-EksIngressIp -Namespace $Namespace
    if ($externalIp) {
        Set-Content -Path $ipStateFile -Value $externalIp -Encoding UTF8
        Write-Host "  ✓ External IP: $externalIp" -ForegroundColor Green
    } else {
        Write-Warning "  ⚠ Could not resolve external IP — update hosts file manually"
    }
}

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace -l app.kubernetes.io/name=traefik
}

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Ingress (Standard):" -ForegroundColor Gray
Write-Host "    ingressClassName: traefik" -ForegroundColor Yellow
Write-Host "    cert-manager.io/cluster-issuer: <issuer>" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Traefik-spezifische Annotations:" -ForegroundColor Gray
Write-Host "    traefik.ingress.kubernetes.io/router.entrypoints: websecure" -ForegroundColor Yellow
Write-Host "    traefik.ingress.kubernetes.io/router.tls: 'true'" -ForegroundColor Yellow
Write-Host ""
Write-Host "  IngressRoute (Traefik-nativ):" -ForegroundColor Gray
Write-Host "    apiVersion: traefik.io/v1alpha1" -ForegroundColor Yellow
Write-Host "    kind: IngressRoute" -ForegroundColor Yellow
Write-Host "    spec.entryPoints: [websecure]" -ForegroundColor Yellow
Write-Host "    spec.tls.certResolver: <resolver>" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
