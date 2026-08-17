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

# Standalone: if prompt parameters are missing, call Prompt.ps1 automatically
if ([string]::IsNullOrWhiteSpace($Hostname)) {
    $aksState = if (Test-Path (Join-Path $BaseDir ".aks-state.json")) {
        Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
    } else { $null }
    $domain = if ($aksState) {
        $label = ($aksState.ClusterName -replace '[^a-z0-9-]', '-').ToLower()
        "$label.$($aksState.Location).cloudapp.azure.com"
    } else { "kubernetes.local" }
    $inputs = & "$ScriptRoot\Prompt.ps1" -Platform $Platform -Domain $domain
    if (-not $inputs) { Write-Host "  Aborted." -ForegroundColor Red; exit 0 }
    if ([string]::IsNullOrWhiteSpace($Hostname)) { $Hostname = $inputs.Hostname }
}

# Admin password is auto-generated — SSO (Authelia) handles login; this is only for emergency fallback
$AdminPassword = [System.Guid]::NewGuid().ToString("N")

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

& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-Host "  ✓ Namespace ready" -ForegroundColor Green

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
$tracingNamespace  = ""
& kubectl get svc tempo-query-frontend -n tempo 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    & kubectl get svc tempo -n tempo 2>&1 | Out-Null
}
if ($LASTEXITCODE -eq 0) {
    $tracingDatasource = @"
    - name: Tempo
      type: tempo
      url: $($ds.TempoUrl)
      access: proxy
      isDefault: false
"@
    $tracingNamespace = "tempo"
}
& kubectl get svc jaeger -n jaeger 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    $tracingDatasource = @"
    - name: Jaeger
      type: jaeger
      url: $($ds.JaegerUrl)
      access: proxy
      isDefault: false
"@
    $tracingNamespace = "jaeger"
}

# ── TLS issuer + OIDC (Authelia) ─────────────────────────────────────────────
$issuerName    = Get-ClusterIssuerName -Platform $Platform -BaseDir $BaseDir
$tlsSecretName = if ($Hostname) { "$($Hostname -replace '\.', '-')-tls" } else { "" }
$sslRedirect   = if ($issuerName) { "true" } else { "false" }
$tlsBlock      = if ($issuerName -and $Hostname) {
@"
  tls:
  - hosts:
    - $Hostname
    secretName: $tlsSecretName
"@
} else { "" }
$issuerAnnotationLine = if ($issuerName) { "    cert-manager.io/cluster-issuer: $issuerName" } else { "" }

$oidcConfig = $null
if ($issuerName -and -not [string]::IsNullOrWhiteSpace($Hostname)) {
    $autheliaDeployed = (@(& kubectl get deployment authelia -n authelia --ignore-not-found -o name 2>$null) -join "").Trim()
    if ($autheliaDeployed) {
        Write-Host "  · Registering Grafana as OIDC client in Authelia..." -ForegroundColor DarkGray
        $oidcConfig = Register-AutheliaOidcClient `
            -ClientId "grafana" -ClientName "Grafana" `
            -RedirectUris @("https://$Hostname/login/generic_oauth") `
            -BaseDir $BaseDir -Platform $Platform
        if ($oidcConfig) {
            Write-Host "  ✓ Registered as OIDC client" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Could not sync Authelia config — OIDC skipped" -ForegroundColor Yellow
        }
    }
}

$tempValues     = Join-Path $env:TEMP "grafana-values.yaml"
$tempOidcValues = Join-Path $env:TEMP "grafana-oidc-values.yaml"

$mountKeys = @("adminPassword")
if ($oidcConfig) { $mountKeys += "oidcClientSecret" }

$mount = New-CsiSecretMount `
    -AppName "grafana" -VaultPath "grafana" -Keys $mountKeys `
    -Namespace $Namespace -ServiceAccount "grafana" `
    -BaseDir $BaseDir -Platform $Platform

if ($mount.Installed) {
    $secretData = @{ adminPassword = $AdminPassword }
    if ($oidcConfig) { $secretData['oidcClientSecret'] = $oidcConfig.ClientSecret }
    $writeOk = Write-ClusterSecret -Path "grafana" -BaseDir $BaseDir -Platform $Platform -Data $secretData
    if ($writeOk) {
        $mount.SpcYaml | & kubectl apply -f - 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Error "SecretProviderClass could not be applied — check CSI driver installation"; exit 1 }
        Write-Host "  ✓ Credentials written to vault + SecretProviderClass created" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ Vault not available — falling back to direct password (no CSI mount)" -ForegroundColor Yellow
        $mount.Installed = $false
    }
}

$oidcSecretExport = if ($oidcConfig -and $mount.Installed) {
    " && export GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=`$(cat $($mount.MountPath)/oidcClientSecret)"
} else { "" }
$cmdWrapper = "export GF_SECURITY_ADMIN_PASSWORD=`$(cat $($mount.MountPath)/adminPassword)$oidcSecretExport && exec /run.sh"

# OIDC ini block — built after mount so we know whether to use env-var expansion or literal.
# The Grafana chart rejects client_secret as a literal value when assertNoLeakedSecrets=true
# (default). When Vault/CSI is available we inject it via env var exported from the mounted
# file; the ini references ${GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET} which Grafana expands at
# startup. When Vault is unavailable we fall back to the literal and disable the guard.
$oidcIniBlock = ""
if ($oidcConfig) {
    $oidcIssuer = $oidcConfig.Issuer
    $clientSecretInIni = if ($mount.Installed) { '${GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET}' } else { $oidcConfig.ClientSecret }
    $oidcIniBlock = @"
grafana.ini:
  server:
    root_url: "https://$Hostname/"
  auth.generic_oauth:
    enabled: "true"
    name: "Authelia"
    allow_sign_up: "true"
    client_id: "grafana"
    client_secret: "$clientSecretInIni"
    scopes: "openid profile email groups"
    auth_url: "$oidcIssuer/api/oidc/authorization"
    token_url: "$oidcIssuer/api/oidc/token"
    api_url: "$oidcIssuer/api/oidc/userinfo"
    login_attribute_path: "preferred_username"
    name_attribute_path: "name"
    email_attribute_path: "email"
    groups_attribute_path: "groups"
    role_attribute_path: "contains(groups[*], 'admins') && 'Admin' || 'Viewer'"
    use_pkce: "true"
    use_refresh_token: "true"
"@
}

# Grafana's backend performs the OIDC token/userinfo exchange with Authelia server-side,
# which must trust the OpenBao root CA — same trust-store gap Rancher and ArgoCD already
# work around (see 51-rancher and 91-argocd). Grafana has no per-provider TLS-CA setting,
# so an init container appends the CA to the pod's system bundle instead: the grafana/grafana
# image already ships a flat /etc/ssl/certs/ca-certificates.crt (standard Alpine layout),
# which Go's x509 package reads directly — no update-ca-certificates or root needed.
$caTrustViaSet = $false
if ($oidcConfig) {
    $baoStateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
    if (Test-Path $baoStateFile) {
        $baoRootToken = (Get-Content $baoStateFile | ConvertFrom-Json).RootToken
        $defaultPkis  = Get-OpenBaoPkis -BaseDir $BaseDir -Platform $Platform
        $defaultPki   = $defaultPkis | Where-Object { $_['IsDefault'] } | Select-Object -First 1
        if (-not $defaultPki) { $defaultPki = $defaultPkis | Select-Object -First 1 }
        $caMount      = if ($defaultPki) { $defaultPki['MountPath'] } else { "pki" }

        $caCert = & kubectl exec openbao-0 -n openbao -- sh -c "BAO_TOKEN=$baoRootToken bao read -field=certificate $caMount/cert/ca" 2>$null
        if ($caCert) {
            # kubectl's stdout is captured by PowerShell as a string array (one element
            # per line). Set-Content -NoNewline with an array input concatenates elements
            # with NO separator at all (not just no *trailing* newline) — this previously
            # collapsed the multi-line PEM into one unparseable line, silently defeating
            # Go's encoding/pem line-based parser (bytes present, but never actually
            # loaded into the trust store). Re-join with real newlines first.
            $caCertText = ($caCert -join "`n") + "`n"
            $caCertFile = New-TemporaryFile
            Set-Content -Path $caCertFile.FullName -Value $caCertText -Encoding UTF8 -NoNewline
            & kubectl create secret generic tls-ca-additional -n $Namespace `
                --from-file="ca-additional.pem=$($caCertFile.FullName)" `
                --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
            Remove-Item $caCertFile.FullName -Force -ErrorAction SilentlyContinue

            # extraVolumeMounts[0] is already claimed by New-CsiSecretMount's --set flags
            # (vault-secrets, see $mount.HelmArgs below). --set is applied by Helm after all
            # -f/--values files, and merges into an existing array *by index*, field-by-field
            # — it does not append. Putting our own entry at index 0 here previously got
            # silently field-merged with the vault-secrets mount (name/mountPath overwritten
            # by --set, our subPath surviving), which mounted neither correctly and broke
            # OIDC token exchange (unknown-authority TLS error). When CSI is active, our
            # mount is added as index [1] via --set instead (see below); the YAML form here
            # is only safe to use in the no-CSI fallback, where nothing else claims index 0.
            $caTrustExtraVolumeMountsYaml = if (-not $mount.Installed) { @"
extraVolumeMounts:
  - name: ca-bundle
    mountPath: /etc/ssl/certs/ca-certificates.crt
    subPath: ca-certificates.crt
    readOnly: true
"@ } else { "" }

            $oidcIniBlock += @"

extraContainerVolumes:
  - name: ca-additional
    secret:
      secretName: tls-ca-additional
  - name: ca-bundle
    emptyDir: {}
extraInitContainers:
  - name: trust-openbao-ca
    image: "{{ .Values.global.imageRegistry | default .Values.image.registry }}/{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
    command: ["sh", "-c", "cp /etc/ssl/certs/ca-certificates.crt /ca-bundle/ca-certificates.crt && cat /extra-ca/ca-additional.pem >> /ca-bundle/ca-certificates.crt"]
    volumeMounts:
      - name: ca-additional
        mountPath: /extra-ca
        readOnly: true
      - name: ca-bundle
        mountPath: /ca-bundle
$caTrustExtraVolumeMountsYaml
"@
            $caTrustViaSet = $mount.Installed
            Write-Host "  ✓ OpenBao root CA trusted by Grafana OIDC ($caMount, tls-ca-additional)" -ForegroundColor Green
        }
    }
}

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
if ($oidcConfig) {
    Set-Content -Path $tempOidcValues -Value $oidcIniBlock -Encoding UTF8
}

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
if ($oidcConfig) {
    $HelmArgs += "--values", $tempOidcValues
}
if ($oidcConfig -and -not $mount.Installed) {
    $HelmArgs += "--set", "assertNoLeakedSecrets=false"
}

if ($mount.Installed) {
    $HelmArgs += $mount.HelmArgs
    $HelmArgs += "--set", "adminUser=$($UserConfig.AdminUser)"
    $HelmArgs += "--set-string", "adminPassword=managed-by-vault"
    if ($caTrustViaSet) {
        # index [1] — [0] is vault-secrets, set by $mount.HelmArgs above.
        $HelmArgs += "--set", "extraVolumeMounts[1].name=ca-bundle"
        $HelmArgs += "--set", "extraVolumeMounts[1].mountPath=/etc/ssl/certs/ca-certificates.crt"
        $HelmArgs += "--set", "extraVolumeMounts[1].subPath=ca-certificates.crt"
        $HelmArgs += "--set", "extraVolumeMounts[1].readOnly=true"
    }
} else {
    $HelmArgs += "--set", "adminUser=$($UserConfig.AdminUser)"
    $HelmArgs += "--set-string", "adminPassword=$AdminPassword"
}

Reset-StuckHelmRelease -ReleaseName "grafana" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying Grafana..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
Remove-Item $tempValues     -Force -ErrorAction SilentlyContinue
Remove-Item $tempOidcValues -Force -ErrorAction SilentlyContinue
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
    nginx.ingress.kubernetes.io/ssl-redirect: "$sslRedirect"
$issuerAnnotationLine
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
$tlsBlock
"@
    $ingressYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Ingress configured ($Hostname)" -ForegroundColor Green }
    $scheme = if ($issuerName) { "https" } else { "http" }
    $portalIcon = Get-PortalIconDataUri -ScriptRoot $ScriptRoot -IconFile $FullConfig.PortalIcon
    Register-PortalEntry -Name $FullConfig.PortalTitle -Url "${scheme}://$Hostname" `
        -Category "Observability" -Subtitle $FullConfig.PortalSubtitle -Order 66 `
        -InternalUrl "http://grafana.grafana.svc.cluster.local" `
        -LogoUrl $portalIcon
}

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Install-NetworkPolicyBaseline -Namespace $Namespace
# NetworkPolicy ports match the pod's actual container port, not the Service
# port (80) that fronts it via kube-proxy DNAT — Grafana's container listens
# on 3000, so the policy must allow 3000 or ingress traffic is silently dropped.
Set-NetworkPolicyProviderIngress -Namespace $Namespace -Port 3000
# The provider-ingress rule above only matches traffic from namespaces carrying
# network.k8s/allow-$Namespace — but the ingress controller has no per-backend
# Install.ps1 hook to label itself as a consumer. Grafana, as the exposed
# provider, labels the ingress controller's namespace directly instead. This
# is a plain label add — deliberately NOT Set-NetworkPolicyConsumerEgress,
# which would also install ingress-nginx's first-ever NetworkPolicy object
# and flip it into default-deny egress for every namespace it fronts.
$ingressCtrlNamespace = "ingress-nginx"
& kubectl get namespace $ingressCtrlNamespace 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { $ingressCtrlNamespace = "traefik" }
& kubectl get namespace $ingressCtrlNamespace 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    & kubectl label namespace $ingressCtrlNamespace "network.k8s/allow-$Namespace=true" --overwrite 2>&1 | Out-Null
}
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "prometheus" -Port 9090
Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "loki" -Port 3100
if ($tracingNamespace -eq "jaeger") {
    Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "jaeger" -Port 16686
} elseif ($tracingNamespace -eq "tempo") {
    Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "tempo" -Port 3200
}
if ($oidcConfig) {
    $ingressNamespace = "ingress-nginx"
    & kubectl get namespace ingress-nginx 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $ingressNamespace = "traefik" }
    # auth_url/token_url/api_url are all https://$autheliaHost/... (public ingress
    # hostname, TLS-terminated at the ingress controller) — port 443, not 80.
    Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace $ingressNamespace -Port 443
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
if ($Hostname) {
    $scheme = if ($issuerName) { "https" } else { "http" }
    Write-Host "  Access:  ${scheme}://$Hostname" -ForegroundColor Yellow
}
if ($oidcConfig) {
    Write-Host "  Login:   Single Sign-On via Authelia" -ForegroundColor Yellow
} else {
    Write-Host "  Login:   $($UserConfig.AdminUser) / (auto-generated — check secret '$Namespace/grafana' or Vault)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Datasources configured:" -ForegroundColor Gray
Write-Host "    Prometheus, Loki$(if ($tracingDatasource -match 'Tempo') { ', Tempo' } elseif ($tracingDatasource -match 'Jaeger') { ', Jaeger' })" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0

