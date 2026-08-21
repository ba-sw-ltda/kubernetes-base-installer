<#
.SYNOPSIS
    Install SUSE Rancher
.PARAMETER Platform
    Target platform
.PARAMETER Hostname
    Rancher hostname (from Prompt.ps1)
.PARAMETER BootstrapPassword
    Initial admin password. Not collected by Prompt.ps1 — login goes through
    Authelia/OIDC, so this local account is a break-glass fallback only.
    Generated below (or reused from Vault) when left empty.
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
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
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
# Still recorded in vault for audit purposes (see Quick Reference below); vault
# rotation afterwards has no effect on a running Rancher.
# No longer prompted for — real login goes through Authelia/OIDC (the 'admins'
# group gets full admin rights automatically), so this is a break-glass
# fallback only. Generate once and reuse on re-install, same idiom as
# OpenBao's root CA: re-running the installer shouldn't silently change a
# credential nobody was told about.
if ([string]::IsNullOrWhiteSpace($BootstrapPassword)) {
    $existing = Get-ClusterSecret -Path "rancher" -Keys @("bootstrapPassword") -BaseDir $BaseDir -Platform $Platform
    if ($existing -and $existing["bootstrapPassword"]) {
        $BootstrapPassword = $existing["bootstrapPassword"]
    } else {
        $BootstrapPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    }
}

$secretsBackendInstalled = Write-ClusterSecret -Path "rancher" -BaseDir $BaseDir -Platform $Platform -Data @{
    bootstrapPassword = $BootstrapPassword
}

$issuerName = Get-ClusterIssuerName -Platform $Platform -BaseDir $BaseDir

$HelmArgs = @(
    "upgrade", "--install", "--force", "rancher", "rancher-stable/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "hostname=$Hostname",
    "--set", "bootstrapPassword=$BootstrapPassword",
    "--set", "replicas=$($UserConfig.Replicas)",
    "--set", "ingress.ingressClassName=$(Get-IngressClass)",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)"
)

if ($issuerName) {
    # Real cert via cert-manager/OpenBao PKI instead of Rancher's own self-signed
    # "rancher" source — needed so Rancher's own backend (server-to-server OIDC
    # discovery calls to Authelia) and browsers both get a chain they can verify.
    # NOTE: this requires `tls` to stay at the chart default ("ingress"), NOT
    # "external" — the chart's ingress template skips rendering any tls: block
    # at all when tls=external (see ingate/ingress.yaml's useExternalTls guard).
    $HelmArgs += "--set", "ingress.tls.source=secret"
    $HelmArgs += "--set", "ingress.tls.secretName=tls-rancher-ingress"
    $HelmArgs += "--set-string", "ingress.extraAnnotations.cert-manager\.io/cluster-issuer=$issuerName"

    # Rancher's backend validates certs against its own trust store, which does
    # not include our custom root CA by default — needed for the OIDC discovery
    # call to Authelia to succeed. `additionalTrustedCAs` mounts this secret.
    # Only needed when the default PKI is a self-signed Root CA we minted
    # ourselves — an Intermediate (externally-signed Corporate CA) or a future
    # ACME/Let's Encrypt PKI is already trusted without our help.
    $defaultPki = Get-OpenBaoDefaultRootPki -BaseDir $BaseDir -Platform $Platform
    if ($defaultPki) {
        $baoStateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
        if (Test-Path $baoStateFile) {
            $baoRootToken = (Get-Content $baoStateFile | ConvertFrom-Json).RootToken
            $caMount      = $defaultPki['MountPath']

            $caCert = & kubectl exec openbao-0 -n openbao -- sh -c "BAO_TOKEN=$baoRootToken bao read -field=certificate $caMount/cert/ca" 2>$null
            if ($caCert) {
                $caCertFile = New-TemporaryFile
                Set-Content -Path $caCertFile.FullName -Value $caCert -Encoding UTF8 -NoNewline
                & kubectl create secret generic tls-ca-additional -n $Namespace `
                    --from-file="ca-additional.pem=$($caCertFile.FullName)" `
                    --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
                Remove-Item $caCertFile.FullName -Force -ErrorAction SilentlyContinue
                $HelmArgs += "--set", "additionalTrustedCAs=true"
                Write-Host "  ✓ OpenBao root CA trusted by Rancher ($caMount, tls-ca-additional)" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "  · Default PKI isn't a self-signed Root CA — skipping CA-trust workaround" -ForegroundColor DarkGray
    }
} else {
    $HelmArgs += "--set", "ingress.tls.source=$($UserConfig.TlsSource)"
    if ($UserConfig.TlsExternal) {
        $HelmArgs += "--set", "tls=external"
    }
}

Reset-StuckHelmRelease -ReleaseName "rancher" -Namespace $Namespace

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
# Only relevant when tls=external was actually passed above (no issuer configured).
if (-not $issuerName -and $UserConfig.TlsExternal) {
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

# ── Single sign-on via Authelia ───────────────────────────────────
# Register-AutheliaOidcClient is generic — any component can call it (this
# is the first, more will follow). Field names below for Rancher's own
# AuthConfig/GlobalRoleBinding types are a best-effort mapping from Rancher's
# documented UI field labels (Client ID, Client Secret, Issuer, Custom Groups
# Claim) — Rancher's raw CRD shape has no public schema reference, unlike
# every other chart/CRD this repo already integrates with. If `kubectl apply`
# rejects this, the error message itself should reveal the real field names —
# adjust live rather than guessing further from here.
$oidc = Register-AutheliaOidcClient -ClientId "rancher" -ClientName "Rancher" `
    -RedirectUris @("https://$Hostname/verify-auth") -BaseDir $BaseDir -Platform $Platform

if ($oidc) {
    $authConfigYaml = @"
apiVersion: management.cattle.io/v3
kind: AuthConfig
metadata:
  name: oidc
type: oidcConfig
enabled: true
clientId: "rancher"
clientSecret: "$($oidc.ClientSecret)"
issuer: "$($oidc.Issuer)"
rancherUrl: "https://$Hostname/verify-auth"
groupsClaim: "groups"
scope: "openid profile email groups"
"@
    $authConfigYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ OIDC auth provider configured (Authelia)" -ForegroundColor Green

        # GlobalRoleBinding uses generateName (no fixed name) — check for an
        # existing one with the same group+role first so re-running this
        # installer doesn't pile up duplicate bindings.
        $existing = & kubectl get globalrolebindings.management.cattle.io -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        $alreadyBound = $existing.items | Where-Object {
            $_.groupPrincipalName -eq "oidc_group://admins" -and $_.globalRoleName -eq "admin"
        }
        if (-not $alreadyBound) {
            $bindingYaml = @"
apiVersion: management.cattle.io/v3
kind: GlobalRoleBinding
metadata:
  generateName: globalrolebinding-
globalRoleName: admin
groupPrincipalName: "oidc_group://admins"
"@
            # generateName objects can't be applied (apply needs a fixed name to
            # track) — create is correct here since $alreadyBound above already
            # guards against piling up duplicates on re-install.
            $bindingYaml | & kubectl create -f - 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ 'admins' group granted Rancher admin access" -ForegroundColor Green }
            else { Write-Warning "  Could not create GlobalRoleBinding for the 'admins' group — grant access manually if needed" }
        } else {
            Write-Host "  ✓ 'admins' group already has Rancher admin access" -ForegroundColor Green
        }
    } else {
        Write-Warning "  Could not configure OIDC auth provider — AuthConfig schema may need adjusting (see installer notes)"
    }
} else {
    Write-Warning "  Could not register Rancher as an Authelia OIDC client"
}

# Rancher's backend performs the OIDC discovery/token calls to Authelia over
# the same public hostname browsers use — cluster DNS must resolve it to
# Traefik. On a real domain this just works; on a synthetic hostname that
# only exists in a client's hosts file (or an environment without a real
# cluster-DNS entry at all), it doesn't, so the OIDC call fails with a DNS
# lookup error. Test-HostnameNeedsClusterAlias checks this live rather than
# guessing from the platform/hostname shape (see 66-grafana's identical
# workaround for the reasoning). The Rancher chart has no hostAliases value
# (unlike Grafana's), so this patches the Deployment directly — idempotent
# on re-install since a matching hostAliases entry is a no-op merge.
if ($oidc) {
    $autheliaHost = ([Uri]$oidc.Issuer).Host
    if (Test-HostnameNeedsClusterAlias -Hostname $autheliaHost -IngressNamespace "ingress" -IngressServiceName "traefik" -CheckNamespace $Namespace) {
        $traefikClusterIp = (& kubectl get svc traefik -n ingress -o jsonpath='{.spec.clusterIP}' 2>$null)
        if ($traefikClusterIp) {
            $hostAliasPatch = "{`"spec`":{`"template`":{`"spec`":{`"hostAliases`":[{`"ip`":`"$traefikClusterIp`",`"hostnames`":[`"$autheliaHost`"]}]}}}}"
            & kubectl patch deployment rancher -n $Namespace --type merge -p $hostAliasPatch 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $exitCode = Invoke-WithSpinner -Message "Restarting Rancher with hostAliases..." -Executable "kubectl" `
                    -Arguments @("rollout", "status", "deployment/rancher", "-n", $Namespace, "--timeout=10m") -ShowOutput:$verbose
                if ($exitCode -eq 0) {
                    Write-Host "  ✓ Rancher pod resolves $autheliaHost internally (hostAliases -> $traefikClusterIp)" -ForegroundColor Green
                } else {
                    Write-Warning "Rancher did not roll out cleanly after patching in the hostAliases entry for $autheliaHost — check pod status."
                }
            } else {
                Write-Warning "Could not patch Rancher's Deployment with a hostAliases entry for $autheliaHost — Rancher's OIDC calls to Authelia may fail with a DNS lookup error."
            }
        } else {
            Write-Warning "Could not resolve Traefik's ClusterIP in the 'ingress' namespace — skipping the hostAliases entry for $autheliaHost. If the cluster's DNS can't resolve this hostname on its own (e.g. a synthetic domain that only exists in a client's hosts file), Rancher's OIDC calls to Authelia will fail with a DNS lookup error."
        }
    } else {
        Write-Host "  · $autheliaHost already resolves correctly from inside the cluster — skipping hostAliases workaround" -ForegroundColor DarkGray
    }
}

Install-NetworkPolicyBaseline -Namespace $Namespace
$rancherPort = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "rancher" -ServicePortName "http"
Set-NetworkPolicyProviderIngress -Namespace $Namespace -Port $rancherPort
Set-NetworkPolicyConsumerEgress -Namespace "ingress" -TargetNamespace $Namespace -Port $rancherPort

# Rancher v2.14 embeds an aggregated API server (ext.cattle.io) directly in
# the rancher pod, registered as APIService v1.ext.cattle.io and backed by
# the imperative-api-extension Service. The Kubernetes API server's
# aggregation layer calls this directly using its own real network identity,
# not as a normal labeled-namespace consumer, so
# Set-NetworkPolicyProviderIngress's label-based rule can't cover it. Without
# this, the APIService silently times out (FailedDiscoveryCheck) and every
# post-login UI call through it (e.g. /v1/ext.cattle.io.selfuser) 404s —
# confirmed live on Magalu 2026-08-20, broke the UI after both local and
# OIDC login.
$rancherApiExtensionPort = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "imperative-api-extension"
if ($rancherApiExtensionPort) {
    Set-NetworkPolicyApiServerIngress -Namespace $Namespace -Port $rancherApiExtensionPort
} else {
    Write-Warning "Could not resolve the imperative-api-extension Service's real port — skipping Rancher's aggregated-API NetworkPolicy ingress rule. Rancher's embedded ext.cattle.io API (used by the UI right after login) may be unreachable until this is applied manually."
}

if ($oidc) {
    # Rancher itself calls out to Authelia's OIDC endpoints via the ingress hostname.
    # -Port is a mandatory int[] — an empty array is a terminating parameter-
    # binding error, not a graceful no-op, so an unresolved Traefik Service
    # (e.g. a cluster still running the pre-migration ingress-nginx controller)
    # must not be allowed to abort the whole install here.
    $ingressWebsecurePort = Resolve-ServiceRealPorts -Namespace "ingress" -ServiceName "traefik" -ServicePortName "websecure"
    if ($ingressWebsecurePort) {
        Set-NetworkPolicyConsumerEgress -Namespace $Namespace -TargetNamespace "ingress" -Port $ingressWebsecurePort
    } else {
        Write-Warning "Could not resolve Traefik's websecure port in the 'ingress' namespace — skipping Rancher's OIDC egress NetworkPolicy rule. If this cluster's ingress controller isn't Traefik yet, Rancher's OIDC calls to Authelia will be blocked until this is fixed manually or the ingress layer is migrated."
    }
}

# Rancher v2.14 creates these system namespaces itself (CAPI/turtles/UI-plugin
# operators, plus Fleet's own "local" namespace) but — unlike cattle-system,
# cattle-fleet-*, cattle-global-data, etc., which it assigns to the built-in
# "System" project automatically — leaves these four unassigned, so they show
# up under "Not in a Project" in the UI. Confirmed live; harmless but untidy.
foreach ($systemNs in @("cattle-capi-system", "cattle-turtles-system", "cattle-ui-plugin-system", "local")) {
    Set-RancherProjectAssignment -Namespace $systemNs -ProjectName "System"
}

# Components installed before Rancher existed on this cluster couldn't create a
# real Rancher project (the Project CRD isn't registered yet), so their own
# Set-RancherProjectAssignment call left a "rancher.k8s/pending-project" marker
# on the namespace instead. Now that Rancher is up, finish those off — this
# reads the markers each component already wrote on itself, not a list of
# components, so nothing here needs updating as components are added.
Resolve-PendingRancherProjectAssignments

$portalIcon = Get-PortalIconDataUri -ScriptRoot $ScriptRoot -IconFile $FullConfig.PortalIcon
Register-PortalEntry -Name $FullConfig.PortalTitle -Url "https://$Hostname" `
    -Category "Management" -Subtitle $FullConfig.PortalSubtitle -Order 51 `
    -InternalUrl "http://rancher.cattle-system.svc.cluster.local" `
    -LogoUrl $portalIcon

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Access:  https://$Hostname" -ForegroundColor Yellow
if ($oidc) {
    Write-Host "  Login:   Single Sign-On via Authelia (admin/<your Authelia password>)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  A local 'admin' bootstrap account also exists as a break-glass" -ForegroundColor Gray
    Write-Host "  fallback for first login — normal day-to-day login is via Authelia" -ForegroundColor Gray
    Write-Host "  above:" -ForegroundColor Gray
    Write-Host "    admin / $BootstrapPassword" -ForegroundColor Yellow
} else {
    Write-Host "  Login:   admin / $BootstrapPassword" -ForegroundColor Yellow
}
Write-Host ""
if ($secretsBackendInstalled) {
    Write-Host "  Vault (secret: rancher):" -ForegroundColor Gray
    Write-Host "    Bootstrap password auto-generated, stored for break-glass use." -ForegroundColor Gray
    Write-Host "    After first login Rancher stores credentials internally." -ForegroundColor Gray
    Write-Host "    Password rotation must be done via Rancher UI or API." -ForegroundColor Gray
    Write-Host "    Vault rotation has NO effect on a running Rancher." -ForegroundColor DarkGray
}
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
