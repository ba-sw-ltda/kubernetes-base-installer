<#
.SYNOPSIS
    Install Authelia — single sign-on gateway for components with no login of
    their own (Prometheus, Jaeger, Longhorn, ...).
.DESCRIPTION
    One shared "admin" user, one wildcard access_control rule covering every
    *.<clusterDomain> hostname — any component that calls Protect-ComponentIngress
    is automatically covered, no per-app Authelia config needed.
    Bootstrap secrets (session/JWT/storage-encryption-key) are generated once
    and left alone on re-install; the admin password is re-prompted and always
    replaces the previous one (see Prompt.ps1) — that's the rotation mechanism.
    Last step: migrates every pre-existing Basic-Auth component over to
    forward-auth (Get-BasicAuthIngresses) — one-directional, no way back.
.PARAMETER Platform
    Target platform
.PARAMETER Hostname
    Authelia login portal hostname (from Prompt.ps1)
.PARAMETER AdminPassword
    Shared admin password (from Prompt.ps1) — replaces every existing per-app password.
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'AdminPassword',
    Justification = 'Passed through to Vault/htpasswd only; never logged or stored in the cluster as plain text')]
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
    $inputs = & "$ScriptRoot\Prompt.ps1" -Platform $Platform
    if (-not $inputs) { Write-Host "  Aborted." -ForegroundColor Red; exit 0 }
    if ([string]::IsNullOrWhiteSpace($Hostname))      { $Hostname      = $inputs.Hostname }
    if ([string]::IsNullOrWhiteSpace($AdminPassword)) { $AdminPassword = $inputs.AdminPassword }
}

$verbose       = $VerbosePreference -eq 'Continue'
$clusterDomain = $Hostname -replace '^[^.]+\.', ''

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 35 - Authelia" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName    = $FullConfig.ChartName
$ChartVersion = $FullConfig.Version
$Repository   = $FullConfig.Repository
$Namespace    = $FullConfig.Namespace
$UserConfig   = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Hostname:   $Hostname" -ForegroundColor Gray
Write-Host "  Covers:     *.$clusterDomain" -ForegroundColor Gray
Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "authelia", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-Host "  ✓ Namespace ready" -ForegroundColor Green

# ── Session/JWT/storage-encryption secrets ──────────────────────────────────
# The chart auto-generates its own Secret for these three and points
# AUTHELIA_SESSION_SECRET_FILE/AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE/
# AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE at it
# unconditionally — defining them again in our own rendered config makes
# Authelia refuse to start ("already defined in other configuration
# sources"), confirmed against a live deploy. Left to the chart; only the
# admin password (the one thing a human actually picks) goes through Vault.

# This REPLACES whatever shared credential existed before — re-running this
# installer is the password-rotation mechanism. Hostname goes in here too —
# Sync-AutheliaConfiguration reads it back from here rather than needing it
# passed in directly, so a later OIDC client registration (which has no
# reason to know Authelia's own install-time parameters) can trigger the same
# render.
$adminCredWritten = Write-ClusterSecret -Path "authelia/admin-credential" -BaseDir $BaseDir -Platform $Platform -Data @{
    username = "admin"
    password = $AdminPassword
    hostname = $Hostname
}

$mount = New-CsiSecretMount `
    -AppName "authelia" -VaultPath "authelia/rendered-config" -Keys @("configuration.yaml", "users_database.yml") `
    -Namespace $Namespace -ServiceAccount "authelia" `
    -BaseDir $BaseDir -Platform $Platform

# A successful CSI-mount setup doesn't guarantee the credential write above
# also succeeded (e.g. a transient OpenBao hiccup right when this ran) —
# treat that mismatch the same as "Vault unavailable" rather than letting
# Sync-AutheliaConfiguration fail confusingly a few lines down.
if ($mount.Installed -and -not $adminCredWritten) {
    Write-Host "  ⚠ Admin credential could not be written to Vault — falling back to a generated K8s Secret (no CSI mount)" -ForegroundColor Yellow
    $mount.Installed = $false
}

if ($mount.Installed) {
    if (Sync-AutheliaConfiguration -BaseDir $BaseDir -Platform $Platform) {
        $mount.SpcYaml | & kubectl apply -f - 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Error "SecretProviderClass could not be applied — check CSI driver installation"; exit 1 }
        Write-Host "  ✓ Rendered config written to vault + SecretProviderClass created" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ Vault not available — falling back to a generated K8s Secret (no CSI mount)" -ForegroundColor Yellow
        $mount.Installed = $false
    }
}

if (-not $mount.Installed) {
    # No vault at all — OIDC needs Vault to persist machine-to-machine secrets
    # (hmac/jwks/per-client secrets), so this fallback covers the basic
    # forward-auth gateway only, same as before OIDC support existed.
    $adminHash = Get-HtpasswdHash -Username "admin" -Password $AdminPassword
    if (-not $adminHash) { Write-Error "Could not generate password hash for the admin user"; exit 1 }
    $adminHashOnly = ($adminHash -split ":", 2)[1]

    $usersYaml = @"
users:
  admin:
    displayname: "Admin"
    password: "$adminHashOnly"
    groups:
      - "admins"
"@

    $configYaml = @"
---
server:
  address: 'tcp://0.0.0.0:9091'

log:
  level: info

authentication_backend:
  file:
    path: /mnt/secrets/users_database.yml
    password:
      algorithm: bcrypt

access_control:
  default_policy: deny
  rules:
    - domain: "*.$clusterDomain"
      subject: "user:admin"
      policy: one_factor

session:
  cookies:
    - domain: $clusterDomain
      authelia_url: https://$Hostname
      default_redirection_url: https://$Hostname/

storage:
  local:
    path: /config/db.sqlite3

notifier:
  filesystem:
    filename: /config/notification.txt
"@
}

# NOTE: this chart nests resources/extraVolumes/extraVolumeMounts under a
# top-level "pod:" key (confirmed against the chart's values.yaml — most
# other charts in this repo use bare top-level keys, this one doesn't), and
# pod.kind defaults to DaemonSet, not Deployment.
# persistence.enabled mounts a PVC at /config (chart-fixed path, confirmed
# against deployment.yaml) — SQLite (OIDC consent records, regulation/ban
# history) and the notification file both point there now (see
# Sync-AutheliaConfiguration). Without this the DB lived on /tmp and was
# wiped on every pod restart — confirmed live: a user lost both their session
# and OIDC consent across a routine restart before this was added.
$HelmArgs = @(
    "upgrade", "--install", "--force", "authelia", "authelia/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "configMap.disabled=true",
    "--set", "rbac.enabled=true",
    "--set", "pod.kind=Deployment",
    "--set", "pod.command[0]=authelia",
    "--set", "pod.args[0]=--config",
    "--set", "pod.args[1]=/mnt/secrets/configuration.yaml",
    "--set", "persistence.enabled=true",
    "--set", "persistence.size=$($UserConfig.StorageSize)",
    # The PVC is ReadWriteOnce — the default RollingUpdate strategy tries to
    # bring up the new pod (to mount the volume) before killing the old one
    # (which still holds it), deadlocking on every upgrade. Confirmed live.
    "--set", "pod.strategy.type=Recreate",
    "--set", "pod.resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "pod.resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "pod.resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "pod.resources.requests.memory=$($UserConfig.Resources.Requests.Memory)"
)
if ($UserConfig.StorageClass) {
    $HelmArgs += "--set", "persistence.storageClass=$($UserConfig.StorageClass)"
}

if ($mount.Installed) {
    # New-CsiSecretMount's HelmArgs use bare top-level keys (matches charts
    # like Grafana) — re-prefix with "pod." for this chart's nesting.
    $HelmArgs += ($mount.HelmArgs | ForEach-Object { if ($_ -like "--set*") { $_ } else { "pod.$_" } })
} else {
    # No vault/CSI available — write the rendered config straight into a K8s
    # Secret and mount that at the same path instead, so the command/args
    # override above stays identical either way.
    $cm1 = Join-Path $env:TEMP "authelia-configuration.yaml"
    $cm2 = Join-Path $env:TEMP "authelia-users_database.yml"
    Set-Content -Path $cm1 -Value $configYaml -Encoding UTF8 -NoNewline
    Set-Content -Path $cm2 -Value $usersYaml -Encoding UTF8 -NoNewline
    & kubectl create secret generic authelia-config -n $Namespace `
        --from-file=configuration.yaml=$cm1 --from-file=users_database.yml=$cm2 `
        --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    Remove-Item $cm1, $cm2 -Force -ErrorAction SilentlyContinue

    $HelmArgs += "--set", "pod.extraVolumes[0].name=vault-secrets"
    $HelmArgs += "--set", "pod.extraVolumes[0].secret.secretName=authelia-config"
    $HelmArgs += "--set", "pod.extraVolumeMounts[0].name=vault-secrets"
    $HelmArgs += "--set", "pod.extraVolumeMounts[0].mountPath=/mnt/secrets"
    $HelmArgs += "--set", "pod.extraVolumeMounts[0].readOnly=true"
}

Reset-StuckHelmRelease -ReleaseName "authelia" -Namespace $Namespace

$exitCode = Invoke-WithSpinner -Message "Deploying Authelia..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Authelia (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for authelia (up to 5m)..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/authelia", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "  ── Pod status ──────────────────────────────" -ForegroundColor DarkGray
    & kubectl get pods -n $Namespace -l "app.kubernetes.io/name=authelia" 2>&1 | ForEach-Object { Write-Host "  $_" }
    Write-Error "Rollout of Authelia did not complete"
    exit 1
}
Write-Host "  ✓ Authelia ready" -ForegroundColor Green

# Sync-AutheliaConfiguration's own restart (triggered while writing the
# rendered config, earlier in this script) can get reverted by the Helm
# upgrade right after it: Helm's own template has no idea about the restart
# annotation, so if nothing else in the pod spec changed it just re-applies
# the pre-restart template, and the Deployment controller quietly scales back
# to the old ReplicaSet — confirmed live, not a hypothetical. One more
# restart here, after Helm has fully settled, guarantees the live Pod
# actually reflects the content just written, regardless of what Helm did.
& kubectl rollout restart deployment/authelia -n $Namespace 2>$null | Out-Null
$exitCode = Invoke-WithSpinner -Message "Restarting to pick up rendered config..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/authelia", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of Authelia did not complete after the post-deploy restart"; exit 1 }

$issuerName = Get-ClusterIssuerName -Platform $Platform
$tlsSecretName = "$($Hostname -replace '\.', '-')-tls"
$issuerAnnotationLine = if ($issuerName) { "    cert-manager.io/cluster-issuer: $issuerName" } else { "" }
$sslRedirect = if ($issuerName) { "true" } else { "false" }
$tlsBlock = if ($issuerName) {
@"
  tls:
  - hosts:
    - $Hostname
    secretName: $tlsSecretName
"@
} else { "" }

# Workaround for a confirmed Rancher bug (rancher/dashboard#12477, #16351) —
# Rancher's dashboard never sends a 'scope' parameter on the OIDC authorization
# request regardless of the AuthConfig's configured scope, so Authelia grants
# nothing (no 'openid' -> no id_token -> Rancher login fails). Authelia itself
# has no server-side default-scope override (confirmed against its docs), so
# this rewrites the request at the ingress before it reaches Authelia. Narrow
# match (only fires when scope is literally empty) — harmless to any client
# that sends real scopes. Remove once Rancher fixes this upstream.
# Requires controller.allowSnippetAnnotations=true (see 11-ingress-nginx).
# IMPORTANT: numbered regex captures must stay unbraced ($1/$2) — nginx's
# braced ${name} form only resolves named variables, not numbered captures,
# and rejects it at config-test time ("unknown "1" variable"). Confirmed live:
# this single typo (${1} instead of $1) made every nginx reload fail silently
# from the moment this snippet was first added, leaving the whole cluster's
# ingress config (not just Authelia's) stuck on stale pod IPs indefinitely.
$scopeFixSnippet = @"
      if (`$args ~ "^(.*)scope=&(.*)`$") {
        set `$args "`$1scope=openid%20profile%20email%20groups&`$2";
      }
"@

$ingressYaml = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: authelia
  namespace: $Namespace
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "$sslRedirect"
    nginx.ingress.kubernetes.io/configuration-snippet: |
$scopeFixSnippet
$issuerAnnotationLine
spec:
  ingressClassName: $(Get-IngressClass)
$tlsBlock
  rules:
  - host: $Hostname
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: authelia
            port:
              number: 80
"@
$ingressYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Ingress configured ($Hostname)$(if ($issuerName) { ' [TLS via ' + $issuerName + ']' })" -ForegroundColor Green }

# ── Migration sweep — switch every pre-existing Basic-Auth component over ──
Write-Host ""
Write-Host "Migrating Basic-Auth components to single sign-on" -ForegroundColor Cyan
Write-Host ""
$basicAuthIngresses = Get-BasicAuthIngresses
if ($basicAuthIngresses.Count -eq 0) {
    Write-Host "  Nothing to migrate." -ForegroundColor Gray
} else {
    foreach ($ing in $basicAuthIngresses) {
        Remove-ClusterSecret -Path $ing.VaultPath -Keys @("username", "password") -BaseDir $BaseDir -Platform $Platform | Out-Null

        # auth-snippet (X-Forwarded-Method) deliberately omitted — needs
        # allow-snippet-annotations enabled, which ingress-nginx disables by
        # default for good reason (arbitrary nginx config injection).
        $annotateOut = & kubectl annotate ingress $ing.Name -n $ing.Namespace --overwrite `
            "nginx.ingress.kubernetes.io/auth-url=http://authelia.authelia.svc.cluster.local/api/verify" `
            "nginx.ingress.kubernetes.io/auth-signin=http://${Hostname}/?rd=`$scheme://`$host`$request_uri" `
            "nginx.ingress.kubernetes.io/auth-response-headers=Remote-User,Remote-Groups,Remote-Name,Remote-Email" `
            "nginx.ingress.kubernetes.io/auth-type-" `
            "nginx.ingress.kubernetes.io/auth-secret-" `
            "nginx.ingress.kubernetes.io/auth-realm-" `
            "baseline.io/vault-path-" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  Failed to migrate $($ing.Name) (-n $($ing.Namespace)): $annotateOut"
            continue
        }

        & kubectl delete secret "$($ing.VaultPath)-basic-auth" -n $ing.Namespace --ignore-not-found 2>&1 | Out-Null

        Write-Host "  ✓ $($ing.Name) (-n $($ing.Namespace)) migrated to single sign-on" -ForegroundColor Green
    }
}

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Portal:  http://$Hostname" -ForegroundColor Yellow
Write-Host "  Login:   admin / <the password you just set>" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Covers every *.$clusterDomain Ingress automatically — no" -ForegroundColor Gray
Write-Host "  per-app Authelia config needed for components installed later." -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
