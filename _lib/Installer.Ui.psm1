Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Generic console UI primitives (Read-SelectValue, Read-MultiSelectValues, Read-Plain, Read-Secret*,
# Invoke-WithSpinner, Write-Context/-Section, ConvertTo-UiOptions, ToSafeName) live in their own repo —
# https://github.com/ba-sw-ltda/powershell-menu-ui — checked out as a sibling directory (not a git
# submodule) so multiple installer repos share one working copy. Re-exported below so existing
# callers see no difference.
Import-Module "$PSScriptRoot\..\..\powershell-menu-ui\PowerShellMenuUI.psd1" -Force -Verbose:$false

# Cluster bootstrap (Set-ClusterContext, cloud-native secret writers, Get-IngressClass, ...) lives
# in https://github.com/ba-sw-ltda/powershell-cluster-bootstrap — same sibling-checkout approach.
Import-Module "$PSScriptRoot\..\..\powershell-cluster-bootstrap\PowerShellClusterBootstrap.psd1" -Force -Verbose:$false

# Module-level base directory — one level up from _lib/.
# Get-OpenBaoPkis / Save-OpenBaoPkis / Sync-AutheliaConfiguration /
# Register-AutheliaOidcClient (all BaseLine-only, kept local) default their
# -BaseDir/-Platform to this.
$script:InstallerBaseDir     = Split-Path $PSScriptRoot -Parent
$script:InstallerPlatform    = ""
# $env:INSTALLER_LAST_CONTEXT tracks last set context across module reloads (survives -Force reimport)

# -------------------------
# High-level: Install Identity
# - Simulation: SIM + ProjectCode (no separator)
# - Generic: Name
# - Result contains FinalNameRaw/FinalNameSafe + Namespace/Release (both = FinalNameSafe)
# -------------------------
function Read-InstallIdentity {
  param(
    [hashtable]$Existing = $null,
    [string]$SimulationPrefix = "SIM"
  )

  if ($null -ne $Existing) { return $Existing }

  $ctx = [ordered]@{
  }

  $installType = Read-SelectValue `
    -Title "Installationstyp auswählen" `
    -Message "Simulation: Kundensimulationsanlage; Allgemein: Allgemeine Installation;" `
    -Options @(
      @{ Label = "Simulation"; Value = "Simulation" }
      @{ Label = "Allgemein";    Value = "Generic" }
    ) `
    -Default 0 `
    -ContextTitle "Identität" `
    -ContextHint "Bestimmt die Art der Installation und somit den finalen Namen." `
    -ContextCurrent $ctx

  if (-not $installType) { return $null }

  $ctx = [ordered]@{
    "Installationstyp" = $installType
  }

  if ($installType -eq "Simulation") {
    $projectCode = Read-Plain -Prompt "Projektkürzel" -ContextTitle "Identität" -ContextHint "Der finale Name wird aus $SimulationPrefix und Projektkürzel zusammengebaut." -ContextCurrent $ctx
    if ([string]::IsNullOrWhiteSpace($projectCode)) { throw "Projektkürzel ist Pflicht" }
    $finalRaw = "{0}{1}" -f $SimulationPrefix, $projectCode
    $name = ""
  } else {
    $name = Read-Plain -Prompt "Name" -ContextTitle "Identität" -ContextHint "" -ContextCurrent $ctx
    if ([string]::IsNullOrWhiteSpace($name)) { throw "Name ist Pflicht" }
    $finalRaw = $name
    $projectCode = ""
  }

  $finalSafe = ToSafeName $finalRaw
  if ([string]::IsNullOrWhiteSpace($finalSafe)) { throw "Finaler Name nach Normalisierung leer: '$finalRaw'" }

  return @{
    InstallType   = $installType
    ProjectCode   = $projectCode
    Name          = $name
    FinalNameRaw  = $finalRaw
    FinalNameSafe = $finalSafe
    Namespace     = $finalSafe
    Release       = $finalSafe
  }
}

# -------------------------
# High-level: DB Settings
# Rules:
# - Show defaults; if accepted => use them all
# - If sqlHost/sqlPort not default OR adminUser != default => direct admin password prompt
# - Returns _adminPassword only in memory (caller decides whether to keep it)
# -------------------------
function Read-DbSettings {
  param(
    [hashtable]$Existing = $null,

    [string]$DefaultSqlHost = "mssql.sql-server.svc.cluster.local",
    [int]$DefaultSqlPort = 1433,
    [bool]$DefaultCreateDatabase = $true,

    [string]$DefaultAdminSecretName = "database-sa",
    [string]$DefaultAdminSecretKey  = "SA_PASSWORD",

    [string]$DefaultAdminUser = "SA",

    [string]$DefaultDbAccessSecretName = "db-access"
  )

  if ($null -ne $Existing) { return $Existing }

  $ctxDefault = [ordered]@{
    "SQL Server"       = "${DefaultSqlHost}:$DefaultSqlPort"
    "Admin User"       = "$DefaultAdminUser"
  }

  $sqlHost = $DefaultSqlHost
  $sqlPort = $DefaultSqlPort
  $createDb = $DefaultCreateDatabase
  $adminSecretName = $DefaultAdminSecretName
  $adminSecretKey  = $DefaultAdminSecretKey
  $adminUser = $DefaultAdminUser
  $dbAccessSecretName = $DefaultDbAccessSecretName

  $useDefaults = Read-YesNo `
    -Title "Standardeinstellungen übernehmen?" `
    -DefaultYes $true `
    -ContextTitle "Datenbankeinstellungen" `
    -ContextHint "Wenn 'Nein' ausgewählt wird, folgt die Abfrage der einzelnen Optionen." `
    -ContextCurrent $ctxDefault

  if (-not $useDefaults) {
    $ctx = [ordered]@{}

    $h = Read-Plain "SQL Host (default $DefaultSqlHost)" -ContextTitle "Datenbankeinstellungen" -ContextHint "Werte eingeben (leer = Default)" -ContextCurrent $ctx
    if (-not [string]::IsNullOrWhiteSpace($h)) { $sqlHost = $h }
    $ctx.Add("SQL Host", $sqlHost)

    $p = Read-Plain "SQL Port (default $DefaultSqlPort)" -ContextTitle "Datenbankeinstellungen" -ContextHint "Werte eingeben (leer = Default)" -ContextCurrent $ctx
    if (-not [string]::IsNullOrWhiteSpace($p)) { $sqlPort = [int]$p }
    $ctx.Add("SQL Port", $sqlPort)
    $serverIsDefault = ($sqlHost -eq $DefaultSqlHost -and [int]$sqlPort -eq [int]$DefaultSqlPort)

    # $createDb = Read-YesNo `
    #   -Title "Datenbank erstellen" `
    #   -Message "Datenbank erstellen, falls nicht vorhanden?" `
    #   -DefaultYes $DefaultCreateDatabase `
    #   -ContextTitle "Datenbankeinstellungen" `
    #   -ContextHint "Werte eingeben (leer = Default)" `
    #   -ContextCurrent $ctx
    # $ctx.Add("Datenbank erstellen", $createDb ? "Ja" : "Nein");

    $adminUserIn = Read-Plain "Admin User (default $DefaultAdminUser)" -ContextTitle "Datenbankeinstellungen" -ContextHint "Werte eingeben (leer = Default)" -ContextCurrent $ctx
    if (-not [string]::IsNullOrWhiteSpace($adminUserIn)) { $adminUser = $adminUserIn }
    $ctx.add("Admin User", $adminUser)
    $adminUserIsDefault = ($adminUser -eq $DefaultAdminUser)

    # if ($serverIsDefault -and $adminUserIsDefault) {
    #   $adminSecretNameIn = Read-Plain "SA Secret Name (default $DefaultAdminSecretName)" -ContextTitle "Datenbankeinstellungen" -ContextHint "Werte eingeben (leer = Default)" -ContextCurrent $ctx
    #   if (-not [string]::IsNullOrWhiteSpace($adminSecretNameIn)) { $adminSecretName = $adminSecretNameIn }
    #   $ctx.add("SA Secret Name", $adminSecretName)

    #   $adminSecretKeyIn = Read-Plain "SA Secret Key (default $DefaultAdminSecretKey)" -ContextTitle "Datenbankeinstellungen" -ContextHint "Werte eingeben (leer = Default)" -ContextCurrent $ctx
    #   if (-not [string]::IsNullOrWhiteSpace($adminSecretKeyIn)) { $adminSecretKey = $adminSecretKeyIn }
    #   $ctx.add("SA Secret Key", $adminSecretKey)
    # }
    
    # $dbAccessSecretNameIn = Read-Plain "DB Access Secret Name (default $DefaultDbAccessSecretName)" -ContextTitle "Datenbankeinstellungen" -ContextHint "Werte eingeben (leer = Default)" -ContextCurrent $ctx
    # if (-not [string]::IsNullOrWhiteSpace($dbAccessSecretNameIn)) { $dbAccessSecretName = $dbAccessSecretNameIn }
    # $ctx.add("DB Access Secret Name", $dbAccessSecretName)
  } else {
    $serverIsDefault = $true
    $adminUserIsDefault = $true
  }

  $adminAuthMode = "secret"
  $adminPassword = ""

  if (-not $serverIsDefault -or -not $adminUserIsDefault) {
    $adminAuthMode = "direct"
    $adminPassword = Read-SecretPlain -Prompt "Passwort für $adminUser (verdeckt)"
      -ContextTitle "Datenbankeinstellungen" -ContextHint "Es wurden nicht Standardserver und -benutzer verwendet -> Admin Passwort direkt eingeben" -ContextCurrent $ctx
    if ([string]::IsNullOrWhiteSpace($adminPassword)) { throw "Admin Passwort darf nicht leer sein (direct auth)" }
  }

  return @{
    sql = @{
      host = $sqlHost
      port = [int]$sqlPort
      adminUser = $adminUser
      adminAuth = @{
        mode = $adminAuthMode
        secretName = $adminSecretName
        secretKey  = $adminSecretKey
      }
    }
    createDatabase = [bool]$createDb
    dbAccessSecret = @{
      name = $dbAccessSecretName
    }
    _adminPassword = $adminPassword
  }
}


# -------------------------
# PKI state helpers — read/write the PKIs array inside the per-platform
# OpenBao state file. Each PKI entry is a hashtable with at minimum:
#   Name, MountPath, Type (Root|Intermediate), Roles[], IsDefault, Status
# These are the only two places that touch the PKIs key; everything else
# (UnsealKey, RootToken) is written by 33-openbao/Install.ps1 directly.
# -------------------------
function Get-OpenBaoPkis {
    param(
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )
    if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = $script:InstallerPlatform }
    $stateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
    if (-not (Test-Path $stateFile)) { return @() }
    $state = Get-Content $stateFile | ConvertFrom-Json -AsHashtable
    if (-not $state.ContainsKey('PKIs') -or -not $state['PKIs']) { return @() }
    return @($state['PKIs'])
}

function Save-OpenBaoPkis {
    param(
        [array]$PKIs,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )
    if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = $script:InstallerPlatform }
    $stateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
    if (Test-Path $stateFile) {
        $state = Get-Content $stateFile | ConvertFrom-Json -AsHashtable
    } else {
        $state = @{}
    }
    $state['PKIs'] = $PKIs
    $state | ConvertTo-Json -Depth 10 | Set-Content -Path $stateFile -Encoding UTF8
}


# -------------------------
# Generates an htpasswd-format bcrypt hash via a throwaway pod (httpd:alpine
# ships htpasswd) — avoids needing the binary on the machine running this
# installer. Not exported; internal to Protect-ComponentIngress.
# -------------------------
function Get-HtpasswdHash {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'htpasswd requires plain text; password is not logged or stored')]
    param([string]$Username, [string]$Password)

    $podName = "htpasswd-gen-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $output  = & kubectl run $podName -n authelia --rm -i --restart=Never --quiet `
        --image=httpd:alpine --command -- htpasswd -nbB $Username $Password 2>$null

    $escapedUser = [regex]::Escape($Username)
    $line = $output | Where-Object { $_ -match "^${escapedUser}:\`$2[aby]?\`$" } | Select-Object -First 1
    return $line
}

# -------------------------
# Generates an Authelia-format pbkdf2-sha512 secret hash via a throwaway pod
# running Authelia's own CLI (same "throwaway pod, regex out the result line"
# idiom as Get-HtpasswdHash, just using the tool's own hashing command
# instead of hand-rolling the digest format). Output format confirmed against
# Authelia's own CLI reference docs at design time, not yet against a live
# run — if the regex below ever returns $null, check the pod's raw output
# first (kubectl logs), the "Digest: " prefix (or lack of it) is the likely
# culprit.
# -------------------------
function Get-AutheliaSecretHash {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Secret',
        Justification = 'authelia crypto hash generate requires plain text; value is not logged or stored')]
    param([string]$Secret)

    $podName = "authelia-hash-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $output  = & kubectl run $podName -n authelia --rm -i --restart=Never --quiet `
        --image=authelia/authelia:latest --command -- `
        authelia crypto hash generate pbkdf2 --variant sha512 --password $Secret --no-confirm 2>$null

    $line = $output | Where-Object { $_ -match '\$pbkdf2-sha512\$' } | Select-Object -First 1
    if ($line -and ($line -match '(\$pbkdf2-sha512\$\S+)')) { return $Matches[1] }
    return $null
}


# -------------------------
# Sync-AutheliaConfiguration — (re)assembles Authelia's full configuration.yaml
# + users_database.yml from whatever's currently in Vault (admin credential,
# OIDC provider keys, registered OIDC clients) and pushes it to the same
# Vault path Authelia's own CSI mount reads from (authelia/rendered-config).
# Restarts Authelia if it's already deployed, so a later OIDC client
# registration takes effect without a full re-install.
# Used by 35-authelia/Install.ps1 itself (first render, before Authelia's
# Helm deploy even runs) and by Register-AutheliaOidcClient (every later
# client registration) — the only place that knows how to build this file,
# so both produce the same shape.
# -------------------------
function Sync-AutheliaConfiguration {
    param(
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "Sync-AutheliaConfiguration: -Platform ist erforderlich. Bitte Connect-Cluster aufrufen oder -Platform explizit übergeben."
            return $false
        }
    }

    # ── Admin user + hostname (written by 35-authelia/Install.ps1) ──
    Write-Host "  · Reading admin credential from Vault..." -ForegroundColor DarkGray
    $admin = Get-ClusterSecret -Path "authelia/admin-credential" -Keys @("username", "password", "hostname") -BaseDir $BaseDir -Platform $Platform
    if (-not $admin -or -not $admin["hostname"]) {
        Write-Error "Sync-AutheliaConfiguration: no admin credential found in vault — run 35-authelia/Install.ps1 first."
        return $false
    }
    $hostname      = $admin["hostname"]
    $clusterDomain = $hostname -replace '^[^.]+\.', ''
    Write-Host "  · Computing password hash (starting helper pod, may take 10-30s)..." -ForegroundColor DarkGray
    $adminHash     = Get-HtpasswdHash -Username "admin" -Password $admin["password"]
    if (-not $adminHash) { Write-Error "Sync-AutheliaConfiguration: could not hash the admin password"; return $false }
    $adminHashOnly = ($adminHash -split ":", 2)[1]

    # ── OIDC provider keys — generate once, persist, reuse (machine-to-machine
    # secrets, not something a human re-types like the admin password) ──
    $providerState = Get-ClusterSecret -Path "authelia/oidc-provider" -Keys @("hmac_secret", "private_key") -BaseDir $BaseDir -Platform $Platform
    if ($providerState -and $providerState["hmac_secret"] -and $providerState["private_key"]) {
        $hmacSecret = $providerState["hmac_secret"]
        $rsaPem     = $providerState["private_key"]
    } else {
        $hmacSecret = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 64 | ForEach-Object { [char]$_ })
        $rsa        = [System.Security.Cryptography.RSA]::Create(2048)
        $rsaPem     = "-----BEGIN PRIVATE KEY-----`n" +
            [Convert]::ToBase64String($rsa.ExportPkcs8PrivateKey(), [Base64FormattingOptions]::InsertLineBreaks) +
            "`n-----END PRIVATE KEY-----"
        Write-ClusterSecret -Path "authelia/oidc-provider" -BaseDir $BaseDir -Platform $Platform -Data @{
            hmac_secret = $hmacSecret
            private_key = $rsaPem
        } | Out-Null
    }

    # ── Registered OIDC clients ──
    $registry  = Get-ClusterSecret -Path "authelia/oidc-clients-registry" -Keys @("ids") -BaseDir $BaseDir -Platform $Platform
    $clientIds = @()
    if ($registry -and $registry["ids"]) { $clientIds = @($registry["ids"] -split ',' | Where-Object { $_ }) }

    $clientYamlBlocks = foreach ($id in $clientIds) {
        $client = Get-ClusterSecret -Path "authelia/oidc-clients/$id" -Keys @("secret", "name", "redirect_uris", "scopes") -BaseDir $BaseDir -Platform $Platform
        if (-not $client -or -not $client["secret"]) { continue }
        Write-Host "  · Hashing OIDC client secret for '$id'..." -ForegroundColor DarkGray
        $hashedSecret = Get-AutheliaSecretHash -Secret $client["secret"]
        if (-not $hashedSecret) { Write-Warning "  Sync-AutheliaConfiguration: could not hash secret for OIDC client '$id' — skipping it this round"; continue }
        $redirectUris = @($client["redirect_uris"] -split ',' | Where-Object { $_ })
        $scopes       = if ($client["scopes"]) { @($client["scopes"] -split ',' | Where-Object { $_ }) } else { @("openid", "profile", "email", "groups") }
        # offline_access is what makes Authelia issue a refresh_token at all —
        # without it (and without refresh_token below in grant_types), Rancher's
        # periodic group-membership refresh has nothing to call, and its OIDC
        # client mishandles that failure badly enough to corrupt its own claims
        # parsing (confirmed live: "failed to unmarshal claims: invalid
        # character 'T'", and the user's group principal never gets attached —
        # admin group membership granted via GlobalRoleBinding never applies).
        if ($scopes -notcontains "offline_access") { $scopes += "offline_access" }
        $redirectYaml = ($redirectUris | ForEach-Object { "          - `"$_`"" }) -join "`n"
        $scopesYaml   = ($scopes | ForEach-Object { "          - `"$_`"" }) -join "`n"
@"
      - client_id: "$id"
        client_secret: "$hashedSecret"
        client_name: "$($client["name"])"
        redirect_uris:
$redirectYaml
        scopes:
$scopesYaml
        grant_types:
          - "authorization_code"
          - "refresh_token"
        response_types:
          - "code"
        token_endpoint_auth_method: "client_secret_basic"
        # Authelia defaults OIDC clients to two_factor regardless of the
        # access_control policy below — no 2FA enrollment flow (TOTP/WebAuthn)
        # is built yet, so without this every OIDC login dead-ends on a
        # "register your first device" screen. Matches the one_factor stance
        # already used for the web-portal access_control rule. Revisit once
        # real 2FA enrollment is actually built.
        authorization_policy: "one_factor"
        # implicit: never show consent screen for these internal trusted clients.
        # Default (explicit) asks on every new auth flow even if already consented —
        # confirmed as the cause of "must click Accept every login" on Rancher.
        consent_mode: "implicit"
        # Since Authelia 4.39's claims-policy overhaul, granting a scope no
        # longer puts its claims in the ID token by default — they only show
        # up via the userinfo endpoint unless a claims_policy explicitly lists
        # them under id_token. Confirmed live with the authelia debug oidc
        # claims command: the groups claim was present in userinfo but
        # completely absent from the ID token. Rancher's group-membership
        # sync reads the ID token, so without this it silently computes zero
        # groups (no error — the GlobalRoleBinding for the admins group just
        # never applies, and the user sees no clusters).
        claims_policy: "default"
"@
    }
    $clientsYaml = $clientYamlBlocks -join "`n"

    $oidcBlock = if ($clientsYaml) {
@"

identity_providers:
  oidc:
    hmac_secret: "$hmacSecret"
    jwks:
      - key_id: "main"
        algorithm: "RS256"
        key: |
$(($rsaPem -split "`n" | ForEach-Object { "          $_" }) -join "`n")
    claims_policies:
      default:
        id_token:
          - "groups"
          - "email"
          - "email_verified"
          - "preferred_username"
          - "name"
    clients:
$clientsYaml
"@
    } else { "" }

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

# Authelia requires a secure (https) scheme for authelia_url/default_redirection_url
# even though this codebase's internal admin tools otherwise run over plain HTTP
# (ssl-redirect: "false" everywhere else) — a real gap to close before production
# use, flagged here rather than silently worked around.
session:
  cookies:
    - domain: $clusterDomain
      authelia_url: https://$hostname
      default_redirection_url: https://$hostname/

# /config is the chart's persistence.enabled PVC mount path (35-authelia
# enables it) — OIDC consent records and the regulation/ban-list otherwise
# live on /tmp and get wiped on every pod restart.
storage:
  local:
    path: /config/db.sqlite3

notifier:
  filesystem:
    filename: /config/notification.txt
$oidcBlock
"@

    $writeOk = Write-ClusterSecret -Path "authelia/rendered-config" -BaseDir $BaseDir -Platform $Platform -Data @{
        "configuration.yaml" = $configYaml
        "users_database.yml" = $usersYaml
    }
    if (-not $writeOk) {
        Write-Warning "  Sync-AutheliaConfiguration: could not write rendered config to vault"
        return $false
    }

    # Best-effort — Authelia may not be deployed yet (first install, before the
    # Helm deploy that follows this call) or may not exist at all on this
    # platform's vault backend yet. Mounted-secret content changing alone
    # doesn't trigger a new Pod, so an existing Deployment needs an explicit
    # nudge to pick up the change.
    $exists = & kubectl get deployment authelia -n authelia --ignore-not-found -o name 2>$null
    if ($exists) {
        & kubectl rollout restart deployment/authelia -n authelia 2>$null | Out-Null
    }
    return $true
}

# -------------------------
# Register-AutheliaOidcClient — generic "register this app as an OIDC client
# of Authelia" primitive, called by any component's own Install.ps1 (Rancher
# first, more to follow — Grafana named as the next one). Never shares a
# secret between clients; each gets its own, generated once and persisted.
# -------------------------
function Register-AutheliaOidcClient {
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientName,
        [Parameter(Mandatory)][string[]]$RedirectUris,
        [string[]]$Scopes = @("openid", "profile", "email", "groups"),
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "Register-AutheliaOidcClient: -Platform ist erforderlich. Bitte Connect-Cluster aufrufen oder -Platform explizit übergeben."
            return $null
        }
    }

    # Generate-or-reuse this client's own plaintext secret — never shared.
    $existing = Get-ClusterSecret -Path "authelia/oidc-clients/$ClientId" -Keys @("secret", "name", "redirect_uris", "scopes") -BaseDir $BaseDir -Platform $Platform
    $secret = if ($existing -and $existing["secret"]) {
        $existing["secret"]
    } else {
        -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 48 | ForEach-Object { [char]$_ })
    }

    $writeOk = Write-ClusterSecret -Path "authelia/oidc-clients/$ClientId" -BaseDir $BaseDir -Platform $Platform -Data @{
        secret        = $secret
        name          = $ClientName
        redirect_uris = ($RedirectUris -join ',')
        scopes        = ($Scopes -join ',')
    }
    if (-not $writeOk) {
        Write-Error "Register-AutheliaOidcClient: could not write client '$ClientId' to vault"
        return $null
    }

    # Add this client to the registry Sync-AutheliaConfiguration reads, if not already there.
    $registry  = Get-ClusterSecret -Path "authelia/oidc-clients-registry" -Keys @("ids") -BaseDir $BaseDir -Platform $Platform
    $clientIds = if ($registry -and $registry["ids"]) { @($registry["ids"] -split ',' | Where-Object { $_ }) } else { @() }
    if ($ClientId -notin $clientIds) {
        $clientIds += $ClientId
        Write-ClusterSecret -Path "authelia/oidc-clients-registry" -BaseDir $BaseDir -Platform $Platform -Data @{
            ids = ($clientIds -join ',')
        } | Out-Null
    }

    if (-not (Sync-AutheliaConfiguration -BaseDir $BaseDir -Platform $Platform)) {
        Write-Error "Register-AutheliaOidcClient: client '$ClientId' was registered but Authelia's configuration could not be synced"
        return $null
    }

    $autheliaHost = & kubectl get ingress authelia -n authelia -o jsonpath='{.spec.rules[0].host}' 2>$null
    return @{
        ClientSecret = $secret
        Issuer       = "https://$autheliaHost"
    }
}


# -------------------------
# kubectl discovery cache — clears the local cache so newly installed CRDs
# (e.g. ESO, cert-manager) are visible to kubectl apply without a 10-min wait.
# Suppresses Write-Progress to avoid console noise from Remove-Item -Recurse.
# -------------------------
function Clear-KubectlDiscoveryCache {
    $cacheDir = Join-Path $env:USERPROFILE ".kube\cache\discovery"
    if (-not (Test-Path $cacheDir)) { return }
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    Remove-Item $cacheDir -Recurse -Force -ErrorAction SilentlyContinue
    $ProgressPreference = $prev
}


# -------------------------
# Export (single variant, robust)
# -------------------------
$__exportFunctions = @(
  'Test-CommandExists'
  'ToSafeName'
  'Write-Context'
  'Write-Section'
  'Read-SelectIndex'
  'Read-SelectValue'
  'Read-YesNo'
  'Confirm-RetryOrExit'
  'Read-MultiSelectValues'
  'Read-Plain'
  'Read-SecretPlain'
  'Read-SecretPlainConfirm'
  'Read-InstallIdentity'
  'Read-DbSettings'
  'ConvertTo-UiOptions'
  'Invoke-WithSpinner'
  'Invoke-ScriptBlockWithSpinner'
  'Get-ComponentConfig'
  'Merge-Config'
  'Get-IngressClass'
  'Reset-StuckHelmRelease'
  'Set-ClusterContext'
  'Clear-KubectlDiscoveryCache'
  'Write-ClusterSecret'
  'Write-OpenBaoSecret'
  'Get-ClusterSecret'
  'Get-OpenBaoSecret'
  'Remove-ClusterSecret'
  'Remove-OpenBaoSecret'
  'Get-OpenBaoStateFile'
  'Get-OpenBaoPkis'
  'Save-OpenBaoPkis'
  'Get-ClusterIssuerName'
  'Write-AzureKeyVaultSecret'
  'Write-AwsSecretsManagerSecret'
  'Write-GcpSecretManagerSecret'
  'Remove-AzureKeyVaultSecret'
  'Remove-AwsSecretsManagerSecret'
  'Remove-GcpSecretManagerSecret'
  'New-CsiSecretMount'
  'Remove-CsiSecretMount'
  'Protect-ComponentIngress'
  'Get-HtpasswdHash'
  'Get-AutheliaSecretHash'
  'Sync-AutheliaConfiguration'
  'Register-AutheliaOidcClient'
  'Test-AutheliaInstalled'
  'Get-BasicAuthIngresses'
  'Register-PortalEntry'
  'Unregister-PortalEntry'
  'Read-ComponentSelectionScreen'
)

Export-ModuleMember -Function $__exportFunctions
