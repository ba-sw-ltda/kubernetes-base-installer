<#
.SYNOPSIS
    Sets up ProGet registry credentials centrally in the 'registry' namespace.
    Uses Reflector with pull-mode: other namespaces opt-in via annotation:
      reflector.v1.k8s.emberstack.com/reflects: "registry/proget-registry"
.PARAMETER Platform
    Target platform
.PARAMETER Token
    ProGet API token (from Prompt.ps1)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Token        = "",
    [string]$RegistryUrl  = "",
    [string]$Feed         = "",
    [string]$PrototypeFeed  = "",
    [string]$PrototypeToken = ""
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform
$UserConfig = $FullConfig.UserConfig
$Namespace  = $FullConfig.Namespace

# Standalone: prompt if not provided
if ([string]::IsNullOrWhiteSpace($Token)) {
    $inputs = & "$ScriptRoot\Prompt.ps1" -Platform $Platform
    if (-not $inputs) { Write-Host "  Aborted." -ForegroundColor Red; exit 0 }
    $Token          = $inputs.Token
    $RegistryUrl    = $inputs.RegistryUrl
    $Feed           = $inputs.Feed
    $PrototypeFeed  = $inputs.PrototypeFeed
    $PrototypeToken = $inputs.PrototypeToken
}

# Merge prompt values into UserConfig so the rest of the script uses them
if (-not [string]::IsNullOrWhiteSpace($RegistryUrl)) { $UserConfig.RegistryUrl   = $RegistryUrl }
if (-not [string]::IsNullOrWhiteSpace($Feed))        { $UserConfig.Feed          = $Feed }
if (-not [string]::IsNullOrWhiteSpace($PrototypeFeed)) { $UserConfig.PrototypeFeed = $PrototypeFeed }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 43 - Private Registry" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "  Registry:  $($UserConfig.RegistryUrl)" -ForegroundColor Gray
Write-Host "  Feed:      $($UserConfig.Feed)" -ForegroundColor Gray
Write-Host "  User:      $($UserConfig.User)" -ForegroundColor Gray
Write-Host "  Namespace: $Namespace  (source — other namespaces opt-in via annotation)" -ForegroundColor Gray
Write-Host ""

# ── 1. Store token in vault ───────────────────────────────────────
$writeOk = Write-ClusterSecret -Path "proget-registry" -BaseDir $BaseDir -Platform $Platform -Data @{
    token = $Token
}
if ($writeOk) {
    Write-Host "  ✓ Token stored in vault" -ForegroundColor Green
} else {
    Write-Host "  ⚠ No vault configured — token stored as K8s secret only" -ForegroundColor Yellow
}

# ── 2. Create namespace ───────────────────────────────────────────
& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
Write-Host "  ✓ Namespace '$Namespace' ready" -ForegroundColor Green

# ── 3. imagePullSecret erstellen (pull-mode Reflector) ───────────
$authB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($UserConfig.User):$Token"))
$dockerConfig = @{
    auths = @{
        $UserConfig.RegistryUrl = @{
            username = $UserConfig.User
            password = $Token
            auth     = $authB64
        }
    }
} | ConvertTo-Json -Compress

$secretYaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: proget-registry
  namespace: $Namespace
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: ""
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($dockerConfig)))
"@
$secretYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ imagePullSecret 'proget-registry' created" -ForegroundColor Green
} else {
    Write-Error "Failed to create imagePullSecret"; exit 1
}

# ── 4. Create ConfigMap (pull-mode Reflector) ─────────────────────
$configMapYaml = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: proget-config
  namespace: $Namespace
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: ""
data:
  PROGET_REGISTRY: "$($UserConfig.RegistryUrl)"
  PROGET_FEED: "$($UserConfig.Feed)"
  PROGET_USER: "$($UserConfig.User)"
  PROGET_IMAGE_PREFIX: "$($UserConfig.RegistryUrl)/$($UserConfig.Feed)/"
"@
$configMapYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✓ ConfigMap 'proget-config' created" -ForegroundColor Green
} else {
    Write-Error "Failed to create ConfigMap"; exit 1
}

# ── Prototype feed (RKE2 / Kind only) ────────────────────────────
if (-not [string]::IsNullOrWhiteSpace($PrototypeToken)) {
    $authB64Proto = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($UserConfig.User):$PrototypeToken"))
    $dockerConfigProto = @{
        auths = @{
            $UserConfig.RegistryUrl = @{
                username = $UserConfig.User
                password = $PrototypeToken
                auth     = $authB64Proto
            }
        }
    } | ConvertTo-Json -Compress

    $protoSecretYaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: proget-prototype
  namespace: $Namespace
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: ""
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($dockerConfigProto)))
"@
    $protoSecretYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ imagePullSecret 'proget-prototype' created" -ForegroundColor Green
    } else {
        Write-Error "Failed to create prototype imagePullSecret"; exit 1
    }

    $protoConfigMapYaml = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: proget-prototype-config
  namespace: $Namespace
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: ""
data:
  PROGET_REGISTRY: "$($UserConfig.RegistryUrl)"
  PROGET_FEED: "$($UserConfig.PrototypeFeed)"
  PROGET_USER: "$($UserConfig.User)"
  PROGET_IMAGE_PREFIX: "$($UserConfig.RegistryUrl)/$($UserConfig.PrototypeFeed)/"
"@
    $protoConfigMapYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ ConfigMap 'proget-prototype-config' created" -ForegroundColor Green
    } else {
        Write-Error "Failed to create prototype ConfigMap"; exit 1
    }
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  imagePullSecret: proget-registry  (Quelle: $Namespace)" -ForegroundColor Yellow
Write-Host "  ConfigMap:       proget-config    (Quelle: $Namespace)" -ForegroundColor Gray
if (-not [string]::IsNullOrWhiteSpace($PrototypeToken)) {
    Write-Host "  imagePullSecret: proget-prototype       (Quelle: $Namespace)" -ForegroundColor Yellow
    Write-Host "  ConfigMap:       proget-prototype-config (Quelle: $Namespace)" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  Namespace einbinden (Annotation auf Secret/ConfigMap im Ziel-NS):" -ForegroundColor DarkGray
Write-Host "    reflector.v1.k8s.emberstack.com/reflects: `"$Namespace/proget-registry`"" -ForegroundColor DarkGray
if (-not [string]::IsNullOrWhiteSpace($PrototypeToken)) {
    Write-Host "    reflector.v1.k8s.emberstack.com/reflects: `"$Namespace/proget-prototype`"" -ForegroundColor DarkGray
}
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
