<#
.SYNOPSIS
    Install cert-manager
.DESCRIPTION
    Installs cert-manager via Helm.
    For Kind (Local): also creates a SelfSigned ClusterIssuer and a CA-backed ClusterIssuer.
    For all other platforms: installs cert-manager only — issuers are managed externally.
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER Platform
    Target platform (Azure AKS, AWS EKS, Google GKE, RKE2, Kind)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Platform,
    [string]$PfxPath     = "",
    [string]$PfxPassword = ""
)

$ScriptRoot = $PSScriptRoot
$BaseDir = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 21 - cert-manager" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName       = $FullConfig.ChartName
$ChartVersion    = $FullConfig.Version
$Repository      = $FullConfig.Repository
$Namespace       = $FullConfig.Namespace
$CreateNamespace = $FullConfig.CreateNamespace
$UserConfig      = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName $ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
if ($UserConfig.CreateSelfSignedIssuer) {
    Write-Host "  Issuer:     SelfSigned → CA ($($UserConfig.SelfSignedIssuerName))" -ForegroundColor Gray
} else {
    Write-Host "  Issuer:     none (managed externally)" -ForegroundColor Gray
}
Write-Host ""

# Helm repository
$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "jetstack", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

# Namespace
if ($CreateNamespace) {
    & kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
    Write-Host "  ✓ Namespace ready" -ForegroundColor Green
}

# Deploy
$HelmArgs = @(
    "upgrade", "--install", "cert-manager", "jetstack/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "installCRDs=$($UserConfig.InstallCRDs.ToString().ToLower())",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)"
)

$exitCode = Invoke-WithSpinner -Message "Deploying cert-manager..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy cert-manager (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

# Wait for all three components
foreach ($dep in @("cert-manager", "cert-manager-cainjector", "cert-manager-webhook")) {
    $exitCode = Invoke-WithSpinner -Message "Waiting for $dep..." -Executable "kubectl" `
        -Arguments @("rollout", "status", "deployment/$dep", "-n", $Namespace, "--timeout=5m") `
        -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Rollout of $dep did not complete"; exit 1 }
    Write-Host "  ✓ $dep ready" -ForegroundColor Green
}

# Create SelfSigned issuer chain (platform-configured)
if ($UserConfig.CreateSelfSignedIssuer) {

    # Brief pause — webhook needs a moment after becoming "available"
    Start-Sleep -Seconds 5

    $selfSignedIssuer = @"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
"@

    $rootCert = @"
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: local-ca
  namespace: $Namespace
spec:
  isCA: true
  commonName: local-ca
  secretName: local-ca-secret
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
"@

    $caIssuer = @"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $($UserConfig.SelfSignedIssuerName)
spec:
  ca:
    secretName: local-ca-secret
"@

    $selfSignedIssuer | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create selfsigned-issuer"; exit 1 }

    $rootCert | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create root CA certificate"; exit 1 }

    # Wait for root CA certificate to be issued
    $exitCode = Invoke-WithSpinner -Message "Waiting for root CA to be issued..." -Executable "kubectl" `
        -Arguments @("wait", "--for=condition=ready", "certificate/local-ca", "-n", $Namespace, "--timeout=2m") `
        -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Root CA certificate was not issued in time"; exit 1 }

    $caIssuer | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create CA ClusterIssuer"; exit 1 }
    Write-Host "  ✓ ClusterIssuer '$($UserConfig.SelfSignedIssuerName)' ready" -ForegroundColor Green
}

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
if ($UserConfig.CreateSelfSignedIssuer) {
    Write-Host "  Ingress — TLS annotation:" -ForegroundColor Gray
    Write-Host "    cert-manager.io/cluster-issuer: $($UserConfig.SelfSignedIssuerName)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Ingress — TLS spec:" -ForegroundColor Gray
    Write-Host "    tls:" -ForegroundColor Yellow
    Write-Host "      - hosts: [your.host.example]" -ForegroundColor Yellow
    Write-Host "        secretName: your-host-tls" -ForegroundColor Yellow
} else {
    Write-Host "  No issuer created — configure a ClusterIssuer for your environment." -ForegroundColor Gray
}
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
