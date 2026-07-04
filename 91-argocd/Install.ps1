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
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 91 - ArgoCD" -ForegroundColor Cyan
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

$issuerName    = Get-ClusterIssuerName -Platform $Platform
$tlsSecretName = if ($Hostname) { "argocd-$($Hostname -replace '\.', '-')-tls" } else { "" }
$sslRedirect   = if ($issuerName) { "true" } else { "false" }

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
    "--set", "configs.params.server\.insecure=$($UserConfig.ServerInsecure.ToString().ToLower())"
)

Reset-StuckHelmRelease -ReleaseName "argocd" -Namespace $Namespace

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

# ── OIDC: register ArgoCD as Authelia client, patch argocd-cm / argocd-secret ─
$oidcConfig = $null
if ($issuerName -and -not [string]::IsNullOrWhiteSpace($Hostname)) {
    $autheliaDeployed = (& kubectl get deployment authelia -n authelia --ignore-not-found -o name 2>$null).Trim()
    if ($autheliaDeployed) {
        $oidcConfig = Register-AutheliaOidcClient `
            -ClientId "argocd" -ClientName "ArgoCD" `
            -RedirectUris @("https://$Hostname/auth/callback") `
            -BaseDir $BaseDir -Platform $Platform
        if ($oidcConfig) {
            $secretB64   = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($oidcConfig.ClientSecret))
            $secretPatch = "{`"data`":{`"oidc.clientSecret`":`"$secretB64`"}}"
            & kubectl patch secret argocd-secret -n $Namespace --type merge -p $secretPatch 2>&1 | Out-Null

            # $oidc.clientSecret is ArgoCD's own template reference to argocd-secret, not a PS variable
            $oidcYaml = "name: Authelia`nissuer: $($oidcConfig.Issuer)`nclientID: argocd`nclientSecret: `$oidc.clientSecret`nrequestedScopes:`n  - openid`n  - profile`n  - email`n  - groups`nrequestedIDTokenClaims:`n  groups:`n    essential: true"
            $cmPatch   = @{ data = @{ "oidc.config" = $oidcYaml } } | ConvertTo-Json -Compress -Depth 5
            & kubectl patch configmap argocd-cm -n $Namespace --type merge -p $cmPatch 2>&1 | Out-Null

            $rbacPatch = @{ data = @{
                "policy.default" = "role:readonly"
                "policy.csv"     = "g, admins, role:admin"
                "scopes"         = "[groups, email]"
            }} | ConvertTo-Json -Compress -Depth 5
            & kubectl patch configmap argocd-rbac-cm -n $Namespace --type merge -p $rbacPatch 2>&1 | Out-Null
            Write-Host "  ✓ Authelia OIDC registered" -ForegroundColor Green

            $exitCode = Invoke-WithSpinner -Message "Restarting argocd-server for OIDC..." -Executable "kubectl" `
                -Arguments @("rollout", "restart", "deployment/argocd-server", "-n", $Namespace) -ShowOutput:$verbose
            $exitCode = Invoke-WithSpinner -Message "Waiting for argocd-server restart..." -Executable "kubectl" `
                -Arguments @("rollout", "status", "deployment/argocd-server", "-n", $Namespace, "--timeout=3m") -ShowOutput:$verbose
            if ($exitCode -ne 0) { Write-Warning "  ⚠ argocd-server restart timed out — OIDC may not be active yet" }
            else { Write-Host "  ✓ argocd-server restarted" -ForegroundColor Green }
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    $issuerAnnotation = if ($issuerName) { "`n    cert-manager.io/cluster-issuer: $issuerName" } else { "" }
    $tlsBlock = if ($issuerName -and $tlsSecretName) {
        "  tls:`n  - hosts:`n    - $Hostname`n    secretName: $tlsSecretName`n"
    } else { "" }

    $ingressYaml = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: $Namespace
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "$sslRedirect"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"$issuerAnnotation
spec:
  ingressClassName: $(Get-IngressClass)
${tlsBlock}  rules:
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

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

$scheme = if ($issuerName -and $Hostname) { "https" } else { "http" }
if ($Hostname) {
    Register-PortalEntry -Name "ArgoCD" -Url "${scheme}://$Hostname" -Category "Utilities" `
        -Subtitle "GitOps Continuous Delivery" -Order 91 `
        -InternalUrl "http://argocd-server.argocd.svc.cluster.local"
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    Write-Host "  Access:  ${scheme}://$Hostname" -ForegroundColor Yellow
    if ($oidcConfig) {
        Write-Host "  Login:   via Authelia SSO (OIDC)" -ForegroundColor Green
    }
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
