<#
.SYNOPSIS
    Install NGINX Ingress Controller
.PARAMETER Platform
    Target platform
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$ConfigPath,
    [string]$DnsLabel = ""
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1"         -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1"   -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: NGINX Ingress Controller" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName       = $FullConfig.ChartName
$ChartVersion    = $FullConfig.Version
$Repository      = $FullConfig.Repository
$Namespace       = $FullConfig.Namespace
$CreateNamespace = $FullConfig.CreateNamespace
$UserConfig      = $FullConfig.UserConfig

$serviceType  = $UserConfig.ServiceType
$nodeCount    = (& kubectl get nodes --no-headers 2>$null | Measure-Object -Line).Lines
$replicaCount = if ($nodeCount -gt 1) { [Math]::Min($nodeCount, 2) } else { 1 }

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Replicas:   $replicaCount  |  Service: $serviceType  |  CPU: $($UserConfig.Resources.Limits.Cpu)  |  Memory: $($UserConfig.Resources.Limits.Memory)" -ForegroundColor Gray
Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "ingress-nginx", $Repository, "--force-update") -ShowOutput:$verbose
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
    "upgrade", "--install", "ingress-nginx", "ingress-nginx/$ChartName",
    "--namespace", $Namespace, "--version", $ChartVersion,
    "--set", "controller.replicaCount=$replicaCount",
    "--set", "controller.service.type=$serviceType",
    # Needed by 35-authelia's configuration-snippet annotation, which rewrites
    # a known Rancher OIDC bug (rancher/dashboard#12477, #16351 — the
    # dashboard never sends a 'scope' parameter) at the ingress before it
    # reaches Authelia. Off by default since chart 4.x for security (arbitrary
    # nginx config injection via Ingress annotations) — acceptable here since
    # every Ingress in this cluster is created by this installer, not by
    # untrusted self-service users. annotations-risk-level=Critical is also
    # required as of controller 1.12 — its validating webhook blocks `set`/
    # rewriting $args at the default "High" threshold even with snippets
    # otherwise allowed (confirmed live: rejected with "contains risky
    # annotation" until this was raised).
    "--set", "controller.allowSnippetAnnotations=true",
    "--set", "controller.config.annotations-risk-level=Critical",
    "--set", "controller.resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "controller.resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "controller.resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "controller.resources.requests.memory=$($UserConfig.Resources.Requests.Memory)"
)
if ($UserConfig.HostPortEnabled) {
    $HelmArgs += @("--set", "controller.hostPort.enabled=true")
}
if ($UserConfig.MetalLbPool) {
    $HelmArgs += @("--set", "controller.service.annotations.metallb\.universe\.tf/address-pool=$($UserConfig.MetalLbPool)")
}
if ($DnsLabel) {
    $HelmArgs += @("--set", "controller.service.annotations.service\.beta\.kubernetes\.io/azure-dns-label-name=$DnsLabel")
}
if ($Platform -in @("Azure AKS", "AWS EKS")) {
    $HelmArgs += @("--set", "controller.service.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path=/healthz")
}

$HelmArgs += @("--timeout", "10m")

Reset-StuckHelmRelease -ReleaseName "ingress-nginx" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying NGINX Ingress Controller..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy NGINX Ingress Controller (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for rollout..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/ingress-nginx-controller", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout did not complete — check cluster state"; exit 1 }
Write-Host "  ✓ Rollout complete" -ForegroundColor Green

# Cloud platforms: wait for the LoadBalancer external IP and write it to .ingress-ip for Install-Base.ps1
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
    & kubectl get pods -n $Namespace -l app.kubernetes.io/name=ingress-nginx
}

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Ingress annotations:" -ForegroundColor Gray
Write-Host "    kubernetes.io/ingress.class: nginx" -ForegroundColor Yellow
Write-Host "    cert-manager.io/cluster-issuer: <issuer>" -ForegroundColor Yellow
Write-Host "    nginx.ingress.kubernetes.io/rewrite-target: /" -ForegroundColor Yellow
Write-Host "    nginx.ingress.kubernetes.io/proxy-body-size: 50m" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Ingress spec.ingressClassName:" -ForegroundColor Gray
Write-Host "    ingressClassName: nginx" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
