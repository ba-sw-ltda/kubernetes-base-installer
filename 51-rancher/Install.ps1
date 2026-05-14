<#
.SYNOPSIS
    Install SUSE Rancher
.PARAMETER Platform
    Target platform
.PARAMETER Hostname
    Rancher hostname (from Prompt.ps1)
.PARAMETER BootstrapPassword
    Initial admin password (from Prompt.ps1)
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'BootstrapPassword',
    Justification = 'Helm --set requires plain text; password is not logged or stored')]
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$ManagementMode    = "Full",
    [string]$Hostname          = "",
    [string]$BootstrapPassword = "",
    [string]$RegistrationUrl   = "",
    [string]$ConfigPath
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

# Dispatch to Agent installer when importing into existing Rancher
if ($ManagementMode -eq "Agent") {
    & "$BaseDir\51-rancher-agent\Install.ps1" -Platform $Platform -RegistrationUrl $RegistrationUrl
    exit $LASTEXITCODE
}

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 51 - Rancher" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName    = $FullConfig.ChartName
$ChartVersion = $FullConfig.Version
$Repository   = $FullConfig.Repository
$Namespace    = $FullConfig.Namespace
$UserConfig   = $FullConfig.UserConfig

Write-Host "  Chart:     $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace: $Namespace" -ForegroundColor Gray
Write-Host "  Hostname:  $Hostname" -ForegroundColor Gray
Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "rancher-stable", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-Host "  ✓ Namespace ready" -ForegroundColor Green

# Pull proxy Secret from proxy-config namespace via Reflector (if proxy is configured)
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

# Bootstrap password is passed directly to Helm — it's a one-time credential used
# only on first login. After Rancher bootstraps, it stores credentials internally.
# No vault storage needed: the password is ephemeral and irrelevant after first login.

$HelmArgs = @(
    "upgrade", "--install", "--force", "rancher", "rancher-stable/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "hostname=$Hostname",
    "--set", "bootstrapPassword=$BootstrapPassword",
    "--set", "replicas=$($UserConfig.Replicas)",
    "--set", "ingress.tls.source=$($UserConfig.TlsSource)",
    "--set", "ingress.ingressClassName=$(Get-IngressClass)",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)"
)

if ($UserConfig.TlsExternal) {
    $HelmArgs += "--set", "tls=external"
    # tls=external causes Helm to add backend-protocol:HTTPS annotation which breaks
    # HTTP backends. Remove it after deploy so nginx uses plain HTTP to reach Rancher.
}

$exitCode = Invoke-WithSpinner -Message "Deploying Rancher..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Rancher (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for rollout..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/rancher", "-n", $Namespace, "--timeout=10m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of Rancher did not complete — check cluster state"; exit 1 }
Write-Host "  ✓ Rancher ready" -ForegroundColor Green

# tls=external causes Rancher Helm to set backend-protocol:HTTPS which breaks plain HTTP backends.
# Remove it so nginx connects to Rancher via HTTP (TLS is terminated at nginx, not re-encrypted).
if ($UserConfig.TlsExternal) {
    Invoke-WithSpinner -Message "Fixing ingress backend protocol..." -Executable "kubectl" `
        -Arguments @("annotate", "ingress", "rancher", "-n", $Namespace,
                     "nginx.ingress.kubernetes.io/backend-protocol-", "--overwrite") | Out-Null
    Write-Host "  ✓ Ingress backend protocol fixed (HTTP)" -ForegroundColor Green
}

# Set server-url so Rancher knows its external hostname.
# Without this Rancher redirects to https://localhost causing the UI to fail.
Invoke-WithSpinner -Message "Configuring server URL..." -Executable "kubectl" `
    -Arguments @("patch", "settings.management.cattle.io", "server-url",
                 "--type", "merge", "-p", "{`"value`":`"https://$Hostname`"}") | Out-Null
Write-Host "  ✓ Server URL configured (https://$Hostname)" -ForegroundColor Green

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Access:  https://$Hostname" -ForegroundColor Yellow
Write-Host "  Login:   admin / <bootstrap password you set>" -ForegroundColor Yellow
Write-Host ""
Write-Host "  IMPORTANT: Change password after first login!" -ForegroundColor Red
Write-Host ""
if ($secretsBackendInstalled) {
    Write-Host "  Vault (secret: rancher):" -ForegroundColor Gray
    Write-Host "    Bootstrap password stored for audit purposes only." -ForegroundColor Gray
    Write-Host "    The bootstrap password is used ONCE on first login." -ForegroundColor Gray
    Write-Host "    After first login Rancher stores credentials internally." -ForegroundColor Gray
    Write-Host "    Password rotation must be done via Rancher UI or API." -ForegroundColor Gray
    Write-Host "    Vault rotation has NO effect on a running Rancher." -ForegroundColor DarkGray
}
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
