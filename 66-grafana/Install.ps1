<#
.SYNOPSIS
    Install Grafana (visualization — Prometheus, Loki, Tempo/Jaeger datasources)
.PARAMETER Platform
    Target platform
.PARAMETER Hostname
    Grafana hostname (from Prompt.ps1)
.PARAMETER AdminPassword
    Grafana admin password (from Prompt.ps1)
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'AdminPassword',
    Justification = 'Helm --set requires plain text; password is not logged or stored')]
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Hostname,
    [string]$AdminPassword,
    [string]$ConfigPath
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

# Standalone: if prompt parameters are missing, call Prompt.ps1 automatically
if ([string]::IsNullOrWhiteSpace($AdminPassword) -or [string]::IsNullOrWhiteSpace($Hostname)) {
    $aksState = if (Test-Path (Join-Path $BaseDir ".aks-state.json")) {
        Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
    } else { $null }
    $domain = if ($aksState) {
        $label = ($aksState.ClusterName -replace '[^a-z0-9-]', '-').ToLower()
        "$label.$($aksState.Location).cloudapp.azure.com"
    } else { "kubernetes.local" }
    $inputs = & "$ScriptRoot\Prompt.ps1" -Platform $Platform -Domain $domain
    if (-not $inputs) { Write-Host "  Aborted." -ForegroundColor Red; exit 0 }
    if ([string]::IsNullOrWhiteSpace($Hostname))       { $Hostname       = $inputs.Hostname }
    if ([string]::IsNullOrWhiteSpace($AdminPassword))  { $AdminPassword  = $inputs.AdminPassword }
}

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 66 - Grafana" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName    = $FullConfig.ChartName
$ChartVersion = $FullConfig.Version
$Repository   = $FullConfig.Repository
$Namespace    = $FullConfig.Namespace
$UserConfig   = $FullConfig.UserConfig
$ds           = $UserConfig.Datasources

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
if ($Hostname) { Write-Host "  Hostname:   $Hostname" -ForegroundColor Gray }
Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "grafana", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

# Pull proxy Secret via Reflector if proxy-config exists
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

# Auto-detect tracing backend (tempo-distributed uses tempo-query-frontend; legacy uses tempo)
$tracingDatasource = ""
& kubectl get svc tempo-query-frontend -n $Namespace 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    & kubectl get svc tempo -n $Namespace 2>&1 | Out-Null
}
if ($LASTEXITCODE -eq 0) {
    $tracingDatasource = @"
    - name: Tempo
      type: tempo
      url: $($ds.TempoUrl)
      access: proxy
      isDefault: false
"@
}
& kubectl get svc jaeger -n $Namespace 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    $tracingDatasource = @"
    - name: Jaeger
      type: jaeger
      url: $($ds.JaegerUrl)
      access: proxy
      isDefault: false
"@
}

$tempValues = Join-Path $env:TEMP "grafana-values.yaml"

$mount = New-CsiSecretMount `
    -AppName "grafana" -VaultPath "grafana" -Keys @("adminPassword") `
    -Namespace $Namespace -ServiceAccount "grafana" `
    -BaseDir $BaseDir -Platform $Platform

if ($mount.Installed) {
    $writeOk = Write-ClusterSecret -Path "grafana" -BaseDir $BaseDir -Platform $Platform -Data @{
        adminPassword = $AdminPassword
    }
    if ($writeOk) {
        $mount.SpcYaml | & kubectl apply -f - 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Error "SecretProviderClass could not be applied — check CSI driver installation"; exit 1 }
        Write-Host "  ✓ Credentials written to vault + SecretProviderClass created" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ Vault not available — falling back to direct password (no CSI mount)" -ForegroundColor Yellow
        $mount.Installed = $false
    }
}

$cmdWrapper = "export GF_SECURITY_ADMIN_PASSWORD=`$(cat $($mount.MountPath)/adminPassword) && exec /run.sh"

$valuesYaml = if ($mount.Installed) { @"
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      url: $($ds.PrometheusUrl)
      access: proxy
      isDefault: true
    - name: Loki
      type: loki
      url: $($ds.LokiUrl)
      access: proxy
      isDefault: false
$tracingDatasource
command:
  - /bin/sh
  - -c
  - "$cmdWrapper"
"@ } else { @"
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      url: $($ds.PrometheusUrl)
      access: proxy
      isDefault: true
    - name: Loki
      type: loki
      url: $($ds.LokiUrl)
      access: proxy
      isDefault: false
$tracingDatasource
"@ }
Set-Content -Path $tempValues -Value $valuesYaml -Encoding UTF8

$HelmArgs = @(
    "upgrade", "--install", "--force", "grafana", "grafana/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    "--values", $tempValues
)

if ($mount.Installed) {
    $HelmArgs += $mount.HelmArgs
    $HelmArgs += "--set", "adminUser=$($UserConfig.AdminUser)"
    $HelmArgs += "--set-string", "adminPassword=managed-by-vault"
} else {
    $HelmArgs += "--set", "adminUser=$($UserConfig.AdminUser)"
    $HelmArgs += "--set-string", "adminPassword=$AdminPassword"
}

Reset-StuckHelmRelease -ReleaseName "grafana" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying Grafana..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
Remove-Item $tempValues -Force -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { Write-Error "Failed to deploy Grafana (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for grafana (up to 10m)..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/grafana", "-n", $Namespace, "--timeout=10m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "  ── Pod status ──────────────────────────────" -ForegroundColor DarkGray
    & kubectl get pods -n $Namespace -l "app.kubernetes.io/name=grafana" 2>&1 | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "  ── Recent events ───────────────────────────" -ForegroundColor DarkGray
    & kubectl get events -n $Namespace --sort-by='.lastTimestamp' --field-selector type=Warning 2>&1 |
        Select-Object -Last 8 | ForEach-Object { Write-Host "  $_" }
    Write-Error "Rollout of Grafana did not complete"
    exit 1
}
Write-Host "  ✓ Grafana ready" -ForegroundColor Green

if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    $ingressYaml = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: $Namespace
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
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
            name: grafana
            port:
              number: 80
"@
    $ingressYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Ingress configured ($Hostname)" -ForegroundColor Green }
}

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
if ($Hostname) {
    Write-Host "  Access:  http://$Hostname" -ForegroundColor Yellow
}
Write-Host "  Login:   $($UserConfig.AdminUser) / <password you set>" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Datasources configured:" -ForegroundColor Gray
Write-Host "    Prometheus, Loki$(if ($tracingDatasource -match 'Tempo') { ', Tempo' } elseif ($tracingDatasource -match 'Jaeger') { ', Jaeger' })" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0

