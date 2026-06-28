<#
.SYNOPSIS
    Sets up private container registry credentials centrally in the
    'registry' namespace — any number of feeds, each its own imagePullSecret
    (skipped for anonymous/public feeds) + informational ConfigMap.
    Uses Reflector pull-mode: other namespaces opt-in via annotation, e.g.:
      reflector.v1.k8s.emberstack.com/reflects: "registry/registry-<feed>"
.PARAMETER Platform
    Target platform
.PARAMETER RegistryUrl
    Registry host (from Prompt.ps1)
.PARAMETER Feeds
    Array of @{ Name; User; Password } (from Prompt.ps1). Password empty
    means an anonymous/public feed — no imagePullSecret created for it.
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$RegistryUrl = "",
    [hashtable[]]$Feeds  = @()
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

# Standalone: prompt if not provided
if ([string]::IsNullOrWhiteSpace($RegistryUrl)) {
    $inputs = & "$ScriptRoot\Prompt.ps1" -Platform $Platform
    if (-not $inputs -or -not $inputs.RegistryUrl) { Write-Host "  Skipped — no registry configured." -ForegroundColor Gray; exit 0 }
    $RegistryUrl = $inputs.RegistryUrl
    $Feeds       = $inputs.Feeds
}

if ($Feeds.Count -eq 0) { Write-Host "  Skipped — no feeds configured." -ForegroundColor Gray; exit 0 }

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform
$Namespace  = $FullConfig.Namespace

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 43 - Registry" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "  Registry:  $RegistryUrl" -ForegroundColor Gray
Write-Host "  Feeds:     $($Feeds.Count)" -ForegroundColor Gray
Write-Host "  Namespace: $Namespace  (source — other namespaces opt-in via annotation)" -ForegroundColor Gray
Write-Host ""

& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
Write-Host "  ✓ Namespace '$Namespace' ready" -ForegroundColor Green

# K8s resource names: lowercase alphanumeric + hyphens only, no leading/trailing hyphen.
function ConvertTo-FeedSlug {
    param([string]$Name)
    $slug = $Name.ToLower() -replace '[^a-z0-9-]', '-'
    $slug = $slug -replace '-+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = "feed" }
    return $slug
}

$createdResources = [System.Collections.Generic.List[hashtable]]::new()

foreach ($feed in $Feeds) {
    $slug       = ConvertTo-FeedSlug -Name $feed.Name
    $secretName = "registry-$slug"
    $configName = "registry-$slug-config"
    $hasAuth    = -not [string]::IsNullOrWhiteSpace($feed.User) -and -not [string]::IsNullOrWhiteSpace($feed.Password)

    Write-Host "  Feed '$($feed.Name)':" -ForegroundColor Gray

    if ($hasAuth) {
        # One vault path per feed — each feed's credentials are its own thing,
        # not lumped into a single shared registry-wide secret.
        $writeOk = Write-ClusterSecret -Path "registry/$slug" -BaseDir $BaseDir -Platform $Platform -Data @{
            user     = $feed.User
            password = $feed.Password
        }
        if ($writeOk) { Write-Host "    ✓ Credentials stored in vault" -ForegroundColor Green }
        else { Write-Host "    ⚠ No vault configured — credentials stored as K8s secret only" -ForegroundColor Yellow }

        $authB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$($feed.User):$($feed.Password)"))
        $dockerConfig = @{
            auths = @{
                $RegistryUrl = @{
                    username = $feed.User
                    password = $feed.Password
                    auth     = $authB64
                }
            }
        } | ConvertTo-Json -Compress

        $secretYaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: $secretName
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
            Write-Host "    ✓ imagePullSecret '$secretName' created" -ForegroundColor Green
        } else {
            Write-Error "Failed to create imagePullSecret '$secretName'"; exit 1
        }
    } else {
        Write-Host "    (anonymous feed — no imagePullSecret needed)" -ForegroundColor Gray
    }

    $configMapYaml = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: $configName
  namespace: $Namespace
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: ""
data:
  REGISTRY_HOST:         "$RegistryUrl"
  REGISTRY_FEED:         "$($feed.Name)"
  REGISTRY_IMAGE_PREFIX: "$RegistryUrl/$($feed.Name)/"
"@
    $configMapYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    ✓ ConfigMap '$configName' created" -ForegroundColor Green
    } else {
        Write-Error "Failed to create ConfigMap '$configName'"; exit 1
    }

    $createdResources.Add(@{
        Feed      = $feed.Name
        Secret    = $(if ($hasAuth) { $secretName } else { $null })
        ConfigMap = $configName
    }) | Out-Null
}

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
foreach ($r in $createdResources) {
    Write-Host "  Feed '$($r.Feed)':" -ForegroundColor Yellow
    if ($r.Secret) { Write-Host "    imagePullSecret: $($r.Secret)  (source: $Namespace)" -ForegroundColor Gray }
    Write-Host "    ConfigMap:       $($r.ConfigMap)  (source: $Namespace)" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  Opt in from another namespace (annotation on a new Secret/ConfigMap there):" -ForegroundColor DarkGray
Write-Host "    reflector.v1.k8s.emberstack.com/reflects: `"$Namespace/<name above>`"" -ForegroundColor DarkGray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
