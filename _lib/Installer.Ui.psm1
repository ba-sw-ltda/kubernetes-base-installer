Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Generic console UI primitives (Read-SelectValue, Read-MultiSelectValues, Read-Plain, Read-Secret*,
# Invoke-WithSpinner, Write-Context/-Section, ConvertTo-UiOptions, ToSafeName) live in their own repo —
# https://github.com/ba-sw-ltda/powershell-menu-ui — vendored here as a git submodule so they can be
# reused outside this installer. Re-exported below so existing callers see no difference.
Import-Module "$PSScriptRoot\powershell-menu-ui\PowerShellMenuUI.psd1" -Force -Verbose:$false

# Cluster bootstrap (Set-ClusterContext, cloud-native secret writers, Get-IngressClass, ...) lives
# in https://github.com/ba-sw-ltda/powershell-cluster-bootstrap — same vendoring approach.
Import-Module "$PSScriptRoot\powershell-cluster-bootstrap\PowerShellClusterBootstrap.psd1" -Force -Verbose:$false

# Module-level base directory — one level up from _lib/.
# Write-ClusterSecret / New-CsiSecretMount default their -BaseDir to this.
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
# ClusterSecret — platform-agnostic dispatcher that writes secrets directly to
# the appropriate backend (OpenBao for RKE2/Kind, Azure Key Vault for AKS,
# etc.) via that backend's own CLI/API — no ESO/ExternalSecret involved.
# Returns $true on success, $false if no secrets backend is configured.
# -------------------------
function Write-ClusterSecret {
    param(
        [string]$Path,
        [hashtable]$Data,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "Write-ClusterSecret: -Platform ist erforderlich. Bitte Connect-Cluster aufrufen oder -Platform explizit übergeben."
            return $false
        }
    }

    $frames = @('|','/','-','\'); $fi = 0
    [Console]::Write("`r  $($frames[$fi++ % 4]) Writing secret '$Path' to Vault...")

    $result = switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            Write-OpenBaoSecret -Path $Path -Data $Data -BaseDir $BaseDir -Platform $Platform
        }
        "Azure AKS" {
            Write-AzureKeyVaultSecret -Path $Path -Data $Data -BaseDir $BaseDir
        }
        "AWS EKS" {
            Write-AwsSecretsManagerSecret -Path $Path -Data $Data -BaseDir $BaseDir
        }
        "Google GKE" {
            Write-GcpSecretManagerSecret -Path $Path -Data $Data -BaseDir $BaseDir
        }
        default { $false }
    }

    if ($result) {
        Write-Host ("`r  ✓ Secret '$Path' stored in Vault" + (" " * 10)) -ForegroundColor Green
    } else {
        [Console]::Write("`r" + (" " * 60) + "`r")
    }
    return $result
}

# -------------------------
# Remove-ClusterSecret — deletion counterpart to Write-ClusterSecret. Same
# per-platform dispatch. -Keys must match whatever -Data keys were originally
# written (cloud backends name one secret per key once there's more than one).
# Returns $true on success, $false if no secrets backend is configured.
# -------------------------
function Remove-ClusterSecret {
    param(
        [string]$Path,
        [string[]]$Keys,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "Remove-ClusterSecret: -Platform ist erforderlich. Bitte Connect-Cluster aufrufen oder -Platform explizit übergeben."
            return $false
        }
    }

    $result = switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            Remove-OpenBaoSecret -Path $Path -BaseDir $BaseDir -Platform $Platform
        }
        "Azure AKS" {
            Remove-AzureKeyVaultSecret -Path $Path -Keys $Keys -BaseDir $BaseDir
        }
        "AWS EKS" {
            Remove-AwsSecretsManagerSecret -Path $Path -Keys $Keys -BaseDir $BaseDir
        }
        "Google GKE" {
            Remove-GcpSecretManagerSecret -Path $Path -Keys $Keys -BaseDir $BaseDir
        }
        default { $false }
    }

    if ($result) {
        Write-Host "  ✓ Secret '$Path' in Vault deaktiviert" -ForegroundColor Green
    }
    return $result
}

# -------------------------
# OpenBao runs on both RKE2 and Kind, and installer scripts are routinely run
# against either from the same BaseDir checkout (e.g. testing on Kind, then
# deploying to RKE2) — a single shared ".openbao-state.json" would let
# whichever platform was last (re-)installed silently overwrite the other's
# root token, with no error until some later write fails with a confusing
# permission-denied. Confirmed live: this exact collision broke a real RKE2
# install after Kind-cluster testing from the same checkout. Every other
# platform already gets its own state file (.rke2-state.json, .kind-state.json,
# .aks-state.json, ...) — OpenBao's needs the same per-platform scoping.
# -------------------------
function Get-OpenBaoStateFile {
    param(
        [string]$BaseDir,
        [string]$Platform
    )
    $slug = switch ($Platform) {
        "RKE2 (On-Premise)" { "rke2"  }
        "Kind (Local)"      { "kind"  }
        "Azure AKS"         { "aks"   }
        "AWS EKS"           { "eks"   }
        "Google GKE"        { "gke"   }
        default             { "unknown" }
    }
    return Join-Path $BaseDir ".openbao-state-$slug.json"
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
# Per-platform cert-manager ClusterIssuer name — components that render their
# own Ingress (Authelia, Rancher, ...) call this to decide whether to add a
# tls: block + cert-manager.io/cluster-issuer annotation.
#
# With multi-PKI support, the name is derived from the state file:
#   "openbao-pki-<name>" for the PKI named by -PKIName (or the default PKI).
# Backward compat: if the state file has no PKIs array (old format), returns
# "openbao-pki" so existing clusters keep working until OpenBao is re-run.
# Cloud platforms return "" — no ClusterIssuer wired up yet.
# -------------------------
function Get-ClusterIssuerName {
    param(
        [string]$Platform,
        [string]$PKIName  = "",
        [string]$BaseDir  = $script:InstallerBaseDir
    )
    # No early-return on cloud — OpenBao will run on all platforms for PKI.
    # The state file's existence is the authoritative signal: if OpenBao is
    # not installed (yet), the file won't exist and we return "" correctly.

    $stateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
    if (-not (Test-Path $stateFile)) { return "" }

    $state = Get-Content $stateFile | ConvertFrom-Json -AsHashtable

    # Backward compat: old state file without PKIs array (pre-multi-PKI)
    if (-not $state.ContainsKey('PKIs') -or -not $state['PKIs']) { return "openbao-pki" }

    $pkis = @($state['PKIs'])

    $pki = if ($PKIName) {
        $pkis | Where-Object { $_['Name'] -eq $PKIName } | Select-Object -First 1
    } else {
        $found = $pkis | Where-Object { $_['IsDefault'] -eq $true } | Select-Object -First 1
        if (-not $found) { $found = $pkis | Select-Object -First 1 }
        $found
    }

    if (-not $pki) { return "" }
    if (@($pki['Roles']) -notcontains 'HTTP') { return "" }
    if ($pki['Status'] -ne 'Active') { return "" }

    # Prefer the stored ClusterIssuerName (set by Install.ps1) — it handles the
    # backward-compat case where the "pki" mount keeps the name "openbao-pki".
    if ($pki['ClusterIssuerName']) { return $pki['ClusterIssuerName'] }
    return "openbao-pki-$($pki['Name'])"
}

# -------------------------
# OpenBao — writes key/value pairs to OpenBao KV-v2 at the given path.
# Returns $true on success, $false if OpenBao is not installed or not ready.
# Callers fall back to direct Helm --set when $false is returned.
# -------------------------
function Write-OpenBaoSecret {
    param(
        [string]$Path,
        [hashtable]$Data,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = $script:InstallerPlatform }
    $stateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
    if (-not (Test-Path $stateFile)) {
        Write-Warning "Write-OpenBaoSecret('$Path'): no '$stateFile' — OpenBao not installed yet for '$Platform'?"
        return $false
    }

    $rootToken = (Get-Content $stateFile | ConvertFrom-Json).RootToken
    if (-not $rootToken) {
        Write-Warning "Write-OpenBaoSecret('$Path'): '$stateFile' has no RootToken"
        return $false
    }

    # A single status read right after another component's Helm deploy can
    # transiently miss — retry briefly instead of failing the whole write on
    # what's usually just API-server/scheduler lag, confirmed live on RKE2.
    $podStatus = $null
    for ($i = 0; $i -lt 5; $i++) {
        $podStatus = & kubectl get pod openbao-0 -n openbao `
            --no-headers -o custom-columns="S:.status.phase" 2>$null
        if ($podStatus -eq "Running") { break }
        Start-Sleep -Seconds 2
    }
    if ($podStatus -ne "Running") {
        Write-Warning "Write-OpenBaoSecret('$Path'): openbao-0 pod status is '$podStatus', not Running"
        return $false
    }

    # Values go through a file + 'kubectl cp' + 'key=@file' rather than an inline
    # "key=value" shell string — needed once a value can contain newlines/quotes
    # (e.g. Authelia's rendered multi-line YAML config), and harmless for the
    # simple single-line passwords/tokens every other caller writes.
    $remoteDir = "/tmp/installer-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    & kubectl exec openbao-0 -n openbao -- mkdir -p $remoteDir 2>$null | Out-Null

    $kvArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Data.GetEnumerator()) {
        $tmpFile = New-TemporaryFile
        Set-Content -Path $tmpFile.FullName -Value $entry.Value -Encoding UTF8 -NoNewline
        $remoteFile = "$remoteDir/$($entry.Key -replace '[^\w.-]', '_')"
        # kubectl cp on Windows misparses an absolute "C:\..." local path as a
        # remote namespace:path spec (the drive letter looks like a colon
        # prefix) — cd into the temp file's folder and pass a relative name.
        Push-Location (Split-Path $tmpFile.FullName)
        & kubectl cp "./$(Split-Path $tmpFile.FullName -Leaf)" "openbao/openbao-0:$remoteFile" 2>$null | Out-Null
        Pop-Location
        Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
        $kvArgs.Add("$($entry.Key)=@$remoteFile") | Out-Null
    }

    $putOut = & kubectl exec openbao-0 -n openbao -- `
        sh -c "BAO_TOKEN=$rootToken bao kv put secret/$Path $($kvArgs -join ' ')" 2>&1
    $ok = $LASTEXITCODE -eq 0
    if (-not $ok) { Write-Warning "Write-OpenBaoSecret('$Path'): bao kv put failed — $putOut" }

    & kubectl exec openbao-0 -n openbao -- rm -rf $remoteDir 2>$null | Out-Null
    return $ok
}

# -------------------------
# Get-OpenBaoSecret — read-back counterpart to Write-OpenBaoSecret. KV-v2
# returns the whole document in one call, so (unlike the cloud backends)
# there's no need to know the key names ahead of time.
# -------------------------
function Get-OpenBaoSecret {
    param(
        [string]$Path,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = $script:InstallerPlatform }
    $stateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
    if (-not (Test-Path $stateFile)) { return $null }
    $rootToken = (Get-Content $stateFile | ConvertFrom-Json).RootToken
    if (-not $rootToken) { return $null }

    $raw = & kubectl exec openbao-0 -n openbao -- `
        sh -c "BAO_TOKEN=$rootToken bao kv get -format=json secret/$Path" 2>$null
    if (-not $raw) { return $null }

    $joined    = $raw -join "`n"
    $jsonStart = $joined.IndexOf('{')
    if ($jsonStart -lt 0) { return $null }

    try {
        $parsed = $joined.Substring($jsonStart) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch { return $null }

    if (-not $parsed -or -not $parsed['data'] -or -not $parsed['data']['data']) { return $null }
    return $parsed['data']['data']
}

# -------------------------
# Get-ClusterSecret — read-back counterpart to Write-ClusterSecret. For the
# cloud backends, -Keys must be the same list (same count) used in the
# original Write-ClusterSecret -Data call — secret names are computed from
# the count ("$Path" if one key, "$Path-$key" per key otherwise), so the
# count has to match to land on the same names. OpenBao ignores -Keys and
# returns everything stored at the path, since KV-v2 has no such limitation.
# Returns $null if the path doesn't exist or the backend is unavailable.
# -------------------------
function Get-ClusterSecret {
    param(
        [string]$Path,
        [string[]]$Keys = @(),
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "Get-ClusterSecret: -Platform ist erforderlich. Bitte Connect-Cluster aufrufen oder -Platform explizit übergeben."
            return $null
        }
    }

    switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            return Get-OpenBaoSecret -Path $Path -BaseDir $BaseDir -Platform $Platform
        }
        "Azure AKS"  { return Get-AzureKeyVaultSecret -Path $Path -Keys $Keys -BaseDir $BaseDir }
        "AWS EKS"    { return Get-AwsSecretsManagerSecret -Path $Path -Keys $Keys -BaseDir $BaseDir }
        "Google GKE" { return Get-GcpSecretManagerSecret -Path $Path -Keys $Keys -BaseDir $BaseDir }
        default      { return $null }
    }
}

# -------------------------
# OpenBao — soft-deletes a KV-v2 path (recoverable via 'bao kv undelete').
# -------------------------
function Remove-OpenBaoSecret {
    param(
        [string]$Path,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) { $Platform = $script:InstallerPlatform }
    $stateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
    if (-not (Test-Path $stateFile)) {
        Write-Warning "Remove-OpenBaoSecret('$Path'): no '$stateFile' — OpenBao not installed yet for '$Platform'?"
        return $false
    }

    $rootToken = (Get-Content $stateFile | ConvertFrom-Json).RootToken
    if (-not $rootToken) {
        Write-Warning "Remove-OpenBaoSecret('$Path'): '$stateFile' has no RootToken"
        return $false
    }

    $podStatus = & kubectl get pod openbao-0 -n openbao `
        --no-headers -o custom-columns="S:.status.phase" 2>$null
    if ($podStatus -ne "Running") {
        Write-Warning "Remove-OpenBaoSecret('$Path'): openbao-0 pod status is '$podStatus', not Running"
        return $false
    }

    & kubectl exec openbao-0 -n openbao -- `
        sh -c "BAO_TOKEN=$rootToken bao kv delete secret/$Path" 2>$null | Out-Null

    return $LASTEXITCODE -eq 0
}

# -------------------------
# New-CsiSecretMount — platform-agnostic helper that an app installer calls once.
# Handles:
#   - Workload Identity binding (AKS: Federated Credential, GKE: IAM, OpenBao: Vault role)
#   - SecretProviderClass YAML generation (platform-specific, internal)
#   - CSI Helm args (same for all platforms)
#
# Returns a hashtable:
#   Installed  = $true/$false (whether a secrets backend is configured)
#   SpcYaml    = string to pipe to 'kubectl apply -f -'
#   HelmArgs   = array to append to HelmArgs
#   SpcName    = name of the SecretProviderClass
#   MountPath  = mount path inside the pod
# -------------------------
function New-CsiSecretMount {
    param(
        [string]$AppName,
        [string]$VaultPath,
        [string[]]$Keys,
        [string]$Namespace,
        [string]$ServiceAccount,
        [string]$MountPath  = "/mnt/secrets",
        [string]$BaseDir    = $script:InstallerBaseDir,
        [string]$Platform   = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "New-CsiSecretMount: -Platform ist erforderlich. Bitte Connect-Cluster aufrufen oder -Platform explizit übergeben."
            return @{ Installed = $false; SpcYaml = ""; HelmArgs = @(); SpcName = ""; MountPath = $MountPath }
        }
    }

    $notInstalled = @{ Installed = $false; SpcYaml = ""; HelmArgs = @(); SpcName = ""; MountPath = $MountPath }
    $spcName = "$AppName-vault"

    # ── Platform-specific auth setup + SPC YAML ──────────────────
    $spcYaml = switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            $baoStateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
            if (-not (Test-Path $baoStateFile)) { return $notInstalled }
            $baoState  = Get-Content $baoStateFile | ConvertFrom-Json
            $rootToken = $baoState.RootToken

            # Least privilege: a dedicated policy per app, scoped to that app's own
            # path only — never a shared policy that would let any app read every
            # other app's secrets just because it can authenticate at all.
            # Policy content goes through a file + kubectl cp, NOT a heredoc piped
            # through sh -c — a heredoc here is silently corrupted by Windows CRLF
            # line endings (the 'POLICY' terminator line gets a trailing \r, sh
            # never recognizes it as the end of input, and the literal word
            # "POLICY" ends up as bogus policy content) — confirmed live, not
            # hypothetical. Same temp-file/kubectl-cp/relative-path idiom already
            # proven in Write-OpenBaoSecret.
            $policyName = "$AppName-readonly"
            $policyHcl  = @"
path "secret/data/$VaultPath" {
  capabilities = ["read","list"]
}
path "secret/metadata/$VaultPath" {
  capabilities = ["read","list"]
}
"@
            $policyTmpFile = New-TemporaryFile
            Set-Content -Path $policyTmpFile.FullName -Value $policyHcl -Encoding UTF8 -NoNewline
            $remotePolicyFile = "/tmp/$AppName-readonly-policy.hcl"
            Write-Host "  · Uploading Vault policy for $AppName..." -ForegroundColor DarkGray
            Push-Location (Split-Path $policyTmpFile.FullName)
            & kubectl cp "./$(Split-Path $policyTmpFile.FullName -Leaf)" "openbao/openbao-0:$remotePolicyFile" 2>$null | Out-Null
            $cpExit = $LASTEXITCODE
            Pop-Location
            Remove-Item $policyTmpFile.FullName -Force -ErrorAction SilentlyContinue
            if ($cpExit -ne 0) {
                Write-Error "New-CsiSecretMount: Failed to copy policy file to OpenBao pod — is OpenBao running?"
                return $notInstalled
            }
            Write-Host "  ✓ Vault policy uploaded" -ForegroundColor Green

            $policyExit = Invoke-WithSpinner -Message "Writing Vault policy '$policyName'..." -Executable "kubectl" `
                -Arguments @("exec", "openbao-0", "-n", "openbao", "--", "sh", "-c",
                             "BAO_TOKEN=$rootToken bao policy write $policyName $remotePolicyFile 2>/dev/null")
            & kubectl exec openbao-0 -n openbao -- rm -f $remotePolicyFile 2>$null | Out-Null
            if ($policyExit -ne 0) {
                Write-Error "New-CsiSecretMount: Failed to write Vault policy '$policyName' — check OpenBao root token in state file"
                return $notInstalled
            }
            Write-Host "  ✓ Vault policy '$policyName' written" -ForegroundColor Green

            # Vault Kubernetes auth role — single line to avoid shell backtick/continuation issues
            $baoCmd = "BAO_TOKEN=$rootToken bao write auth/kubernetes/role/$AppName bound_service_account_names='$ServiceAccount' bound_service_account_namespaces='$Namespace' policies='$policyName' ttl='1h' 2>/dev/null"
            $roleExit = Invoke-WithSpinner -Message "Registering Kubernetes auth role '$AppName'..." -Executable "kubectl" `
                -Arguments @("exec", "openbao-0", "-n", "openbao", "--", "sh", "-c", $baoCmd)
            if ($roleExit -ne 0) {
                Write-Error "New-CsiSecretMount: Failed to register Kubernetes auth role '$AppName' — check Kubernetes auth method is enabled in OpenBao"
                return $notInstalled
            }
            Write-Host "  ✓ Kubernetes auth role '$AppName' registered" -ForegroundColor Green

            $objects = ($Keys | ForEach-Object { @"
      - objectName: "$_"
        secretPath: "secret/data/$VaultPath"
        secretKey: "$_"
"@ }) -join "`n"
@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: $spcName
  namespace: $Namespace
spec:
  provider: vault
  parameters:
    vaultAddress: "http://openbao.openbao.svc.cluster.local:8200"
    roleName: "$AppName"
    objects: |
$objects
"@
        }

        "Azure AKS" {
            $aksState = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
            if (-not $aksState.VaultName) { return $notInstalled }
            $tenantId = & az account show --query tenantId --output tsv 2>$null
            if ($tenantId) { $tenantId = $tenantId.Trim() }

            # Federated Credential
            $fedName   = "$AppName-csi"
            $fedExists = & az identity federated-credential show `
                --name $fedName --identity-name $aksState.MiName `
                --resource-group $aksState.ResourceGroup 2>$null
            if (-not $fedExists) {
                & az identity federated-credential create `
                    --name $fedName `
                    --identity-name $aksState.MiName `
                    --resource-group $aksState.ResourceGroup `
                    --issuer $aksState.OidcIssuer `
                    --subject "system:serviceaccount:${Namespace}:${ServiceAccount}" `
                    --audience "api://AzureADTokenExchange" 2>$null | Out-Null
            }

            $objects = if ($Keys.Count -eq 1) {
@"
      array:
        - |
          objectName: $VaultPath
          objectType: secret
          objectAlias: $($Keys[0])
"@
            } else {
                ($Keys | ForEach-Object { @"
      array:
        - |
          objectName: $VaultPath-$_
          objectType: secret
          objectAlias: $_
"@ }) -join "`n"
            }
@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: $spcName
  namespace: $Namespace
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "$($aksState.MiClientId)"
    keyvaultName: "$($aksState.VaultName)"
    tenantId: "$tenantId"
    objects: |
$objects
"@
        }

        "AWS EKS" {
            $eksState = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
            if (-not $eksState.CsiRoleArn) { return $notInstalled }

            # IRSA annotation — pod SA gets role via annotation, no per-app binding needed
            $objects = ($Keys | ForEach-Object { @"
      - objectName: "$_"
        objectType: "secretsmanager"
        objectAlias: "$_"
"@ }) -join "`n"
@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: $spcName
  namespace: $Namespace
spec:
  provider: aws
  parameters:
    objects: |
$objects
"@
        }

        "Google GKE" {
            $gkeState = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
            if (-not $gkeState.CsiGsaEmail) { return $notInstalled }

            # Workload Identity IAM binding
            & gcloud iam service-accounts add-iam-policy-binding $gkeState.CsiGsaEmail `
                --project $gkeState.ProjectId `
                --role "roles/iam.workloadIdentityUser" `
                --member "serviceAccount:$($gkeState.ProjectId).svc.id.goog[$Namespace/$ServiceAccount]" 2>$null | Out-Null

            $secrets = ($Keys | ForEach-Object { @"
      - resourceName: "projects/$($gkeState.ProjectId)/secrets/$VaultPath/versions/latest"
        fileName: "$_"
"@ }) -join "`n"
@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: $spcName
  namespace: $Namespace
spec:
  provider: gcp
  parameters:
    secrets: |
$secrets
"@
        }

        default { return $notInstalled }
    }

    # ── CSI Helm args — identical for all platforms ───────────────
    $helmArgs = @(
        "--set", "extraVolumes[0].name=vault-secrets",
        "--set", "extraVolumes[0].csi.driver=secrets-store.csi.k8s.io",
        "--set", "extraVolumes[0].csi.readOnly=true",
        "--set", "extraVolumes[0].csi.volumeAttributes.secretProviderClass=$spcName",
        "--set", "extraVolumeMounts[0].name=vault-secrets",
        "--set", "extraVolumeMounts[0].mountPath=$MountPath",
        "--set", "extraVolumeMounts[0].readOnly=true"
    )

    # Platform-specific pod identity labels/annotations
    if ($Platform -eq "Azure AKS") {
        $aksState = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
        $helmArgs += "--set",        "serviceAccount.annotations.azure\.workload\.identity/client-id=$($aksState.MiClientId)"
        $helmArgs += "--set-string", "podLabels.azure\.workload\.identity/use=true"
    }
    if ($Platform -eq "AWS EKS") {
        $eksState = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
        $helmArgs += "--set", "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$($eksState.CsiRoleArn)"
    }
    if ($Platform -eq "Google GKE") {
        $gkeState = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
        $helmArgs += "--set", "serviceAccount.annotations.iam\.gke\.io/gcp-service-account=$($gkeState.CsiGsaEmail)"
    }

    return @{
        Installed = $true
        SpcYaml   = $spcYaml
        HelmArgs  = $helmArgs
        SpcName   = $spcName
        MountPath = $MountPath
    }
}

# -------------------------
# Remove-CsiSecretMount — deletion counterpart to New-CsiSecretMount. Reverses
# whatever Workload Identity binding/role was created (OpenBao: Kubernetes-auth
# role + the per-app least-privilege policy; AKS: Federated Credential; GKE:
# IAM policy binding — AWS EKS's IRSA is just a ServiceAccount annotation,
# nothing extra to revoke there) and deletes the SecretProviderClass itself.
# Identity-binding revocation is best-effort (warnings, not failures) since the
# SecretProviderClass deletion — the part that actually determines whether the
# secret is still reachable from the cluster — happens either way.
# -------------------------
function Remove-CsiSecretMount {
    param(
        [string]$AppName,
        [string]$Namespace,
        [string]$ServiceAccount,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "Remove-CsiSecretMount: -Platform ist erforderlich. Bitte Connect-Cluster aufrufen oder -Platform explizit übergeben."
            return $false
        }
    }

    $spcName = "$AppName-vault"

    switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            $stateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
            if (Test-Path $stateFile) {
                $rootToken = (Get-Content $stateFile | ConvertFrom-Json).RootToken
                if ($rootToken) {
                    & kubectl exec openbao-0 -n openbao -- `
                        sh -c "BAO_TOKEN=$rootToken bao delete auth/kubernetes/role/$AppName" 2>$null | Out-Null
                    & kubectl exec openbao-0 -n openbao -- `
                        sh -c "BAO_TOKEN=$rootToken bao policy delete $AppName-readonly" 2>$null | Out-Null
                }
            }
        }
        "Azure AKS" {
            $aksState = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
            if ($aksState.MiName) {
                & az identity federated-credential delete --name "$AppName-csi" `
                    --identity-name $aksState.MiName --resource-group $aksState.ResourceGroup --yes 2>$null | Out-Null
            }
        }
        "Google GKE" {
            $gkeState = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
            if ($gkeState.CsiGsaEmail) {
                & gcloud iam service-accounts remove-iam-policy-binding $gkeState.CsiGsaEmail `
                    --project $gkeState.ProjectId --role "roles/iam.workloadIdentityUser" `
                    --member "serviceAccount:$($gkeState.ProjectId).svc.id.goog[$Namespace/$ServiceAccount]" 2>$null | Out-Null
            }
        }
        # AWS EKS: IRSA is just a ServiceAccount annotation -- nothing else to revoke.
    }

    & kubectl delete secretproviderclass $spcName -n $Namespace --ignore-not-found 2>$null | Out-Null
    return $true
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
    $output  = & kubectl run $podName --rm -i --restart=Never --quiet `
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
    $output  = & kubectl run $podName --rm -i --restart=Never --quiet `
        --image=authelia/authelia:latest --command -- `
        authelia crypto hash generate pbkdf2 --variant sha512 --password $Secret --no-confirm 2>$null

    $line = $output | Where-Object { $_ -match '\$pbkdf2-sha512\$' } | Select-Object -First 1
    if ($line -and ($line -match '(\$pbkdf2-sha512\$\S+)')) { return $Matches[1] }
    return $null
}

# -------------------------
# Protect-ComponentIngress — platform-agnostic auth gate for an app's Ingress.
# Authelia is mandatory baseline, so this always returns forward-auth
# annotations — they're static references to Authelia's fixed in-cluster
# Service address, correct the moment Authelia exists and harmless before
# that (nginx's auth_request just gets a connection error, fails closed, not
# an open Ingress). Deliberately does not check Test-AutheliaInstalled —
# doesn't matter whether it's live yet, and nothing needs to come back and
# retrofit this annotation later, so callers never need to special-case
# install order. Returns @{ Annotations = @{ ... }; TlsBlock = "..." } to
# merge into the caller's own Ingress YAML — same "pieces to merge"
# convention as New-CsiSecretMount.
#
# TlsBlock/ssl-redirect/cluster-issuer (same shape 35-authelia/Install.ps1
# already uses for its own Ingress) are included here, not left to each
# caller, because they're not optional polish: Authelia's session cookie is
# Secure (it only ever runs behind HTTPS — see Sync-AutheliaConfiguration's
# authelia_url), so a protected app still served over plain HTTP never
# receives that cookie back, and current browsers actively block the
# https->http downgrade redirect anyway ("insecure redirect blocked").
# Confirmed live: Longhorn and Prometheus both bounced back to the Authelia
# login screen after a successful login until this was added. Cloud
# platforms get no TlsBlock and keep ssl-redirect "false", same as before —
# Get-ClusterIssuerName returns "" there (no ClusterIssuer wired up yet).
# -------------------------
function Protect-ComponentIngress {
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "Protect-ComponentIngress: -Platform ist erforderlich. Bitte Connect-Cluster aufrufen oder -Platform explizit übergeben."
            return @{ Annotations = @{}; TlsBlock = "" }
        }
    }

    $autheliaHost = & kubectl get ingress authelia -n authelia -o jsonpath='{.spec.rules[0].host}' 2>$null
    if (-not $autheliaHost) { $autheliaHost = "authelia.$($Hostname -replace '^[^.]+\.', '')" }

    $issuerName    = Get-ClusterIssuerName -Platform $Platform
    $tlsSecretName = "$($Hostname -replace '\.', '-')-tls"
    $sslRedirect   = if ($issuerName) { "true" } else { "false" }
    $tlsBlock = if ($issuerName) {
@"
  tls:
  - hosts:
    - $Hostname
    secretName: $tlsSecretName
"@
    } else { "" }

    $annotations = @{
        "nginx.ingress.kubernetes.io/auth-url"              = "http://authelia.authelia.svc.cluster.local/api/verify"
        "nginx.ingress.kubernetes.io/auth-signin"           = "http://$autheliaHost/?rd=`$scheme://`$host`$request_uri"
        "nginx.ingress.kubernetes.io/auth-response-headers" = "Remote-User,Remote-Groups,Remote-Name,Remote-Email"
        "nginx.ingress.kubernetes.io/ssl-redirect"          = $sslRedirect
        # auth-snippet (X-Forwarded-Method) deliberately omitted — needs
        # allow-snippet-annotations enabled, which ingress-nginx disables
        # by default for good reason (arbitrary nginx config injection).
        # Not re-enabling that just for this one header.
    }
    if ($issuerName) { $annotations["cert-manager.io/cluster-issuer"] = $issuerName }

    return @{
        Annotations = $annotations
        TlsBlock    = $tlsBlock
    }
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
# Portal entry registration — accumulates ConfigMaps in the portal namespace so
# the Homer dashboard sidecar can build its config.yml.  Registration always
# runs, even if the portal component is not yet installed: the namespace is
# created idempotently and the ConfigMaps wait until the pod arrives.
# -------------------------
function Register-PortalEntry {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Category,
        [string]$Subtitle = "",
        [int]   $Order    = 100,
        [string]$LogoUrl  = ""
    )
    & kubectl create namespace portal --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    $logoB64 = ""; $logoExt = "png"; $targetUrl = $LogoUrl
    if ([string]::IsNullOrWhiteSpace($targetUrl)) {
        try {
            $page = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8 -SkipCertificateCheck -ErrorAction SilentlyContinue
            if ($page) {
                # Prefer high-quality PNG icons: apple-touch-icon or og:image before falling back to favicon.ico
                $pngIcon = [regex]::Match($page.Content, '<link[^>]+rel="apple-touch-icon[^"]*"[^>]+href="([^"]+\.png[^"]*)"', 'IgnoreCase').Groups[1].Value
                if (-not $pngIcon) {
                    $pngIcon = [regex]::Match($page.Content, '<link[^>]+href="([^"]+\.png[^"]*)"[^>]+rel="apple-touch-icon[^"]*"', 'IgnoreCase').Groups[1].Value
                }
                if (-not $pngIcon) {
                    $pngIcon = [regex]::Match($page.Content, '<meta[^>]+property="og:image"[^>]+content="([^"]+)"', 'IgnoreCase').Groups[1].Value
                }
                if ($pngIcon) {
                    # Resolve relative URLs
                    $u = [uri]$Url
                    $targetUrl = if ($pngIcon -match '^https?://') { $pngIcon } else { "$($u.Scheme)://$($u.Host)$pngIcon" }
                }
            }
        } catch {}
        if ([string]::IsNullOrWhiteSpace($targetUrl)) {
            try {
                $u = [uri]$Url
                $targetUrl = "$($u.Scheme)://$($u.Host)/favicon.ico"
            } catch {}
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($targetUrl)) {
        try {
            $resp = Invoke-WebRequest -Uri $targetUrl -UseBasicParsing -TimeoutSec 10 -SkipCertificateCheck -ErrorAction SilentlyContinue
            if ($resp -and $resp.Content) {
                $bytes = if ($resp.Content -is [byte[]]) { $resp.Content } else { [System.Text.Encoding]::UTF8.GetBytes($resp.Content) }
                $logoB64 = [Convert]::ToBase64String($bytes)
                $logoExt = if ($targetUrl -match '\.svg') { "svg" } elseif ($targetUrl -match '\.png') { "png" } elseif ($targetUrl -match '\.ico') { "ico" } else { "png" }
            }
        } catch {}
    }
    $slug = ($Name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    $cmYaml = @"
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-entry-$slug
  namespace: portal
  labels:
    portal/entry: "true"
data:
  name: "$Name"
  subtitle: "$Subtitle"
  url: "$Url"
  category: "$Category"
  order: "$Order"
  logo.ext: "$logoExt"
"@
    $tmp = New-TemporaryFile
    try {
        Set-Content -Path $tmp.FullName -Value $cmYaml -Encoding UTF8
        & kubectl apply -f $tmp.FullName 2>&1 | Out-Null
    } finally {
        Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ⚠ Portal: could not register entry for '$Name'" -ForegroundColor Yellow
        return
    }
    if ($logoB64) {
        $patchFile = New-TemporaryFile
        try {
            Set-Content -Path $patchFile.FullName -Value "{`"data`":{`"logo.b64`":`"$logoB64`"}}" -Encoding UTF8 -NoNewline
            & kubectl patch configmap "portal-entry-$slug" -n portal --type=merge --patch-file $patchFile.FullName 2>&1 | Out-Null
        } finally {
            Remove-Item $patchFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "  ✓ Portal entry registered: $Name" -ForegroundColor Green
}

function Unregister-PortalEntry {
    param([Parameter(Mandatory)][string]$Name)
    $slug = ($Name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    & kubectl delete configmap "portal-entry-$slug" -n portal --ignore-not-found 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Portal entry removed: $Name" -ForegroundColor Green
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
# Config loading with platform overrides
# -------------------------
function Merge-Config {
    param([hashtable]$Base, [hashtable]$Override)
    $result = @{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    foreach ($key in $Override.Keys) {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $result[$key] = Merge-Config -Base $result[$key] -Override $Override[$key]
        } else {
            $result[$key] = $Override[$key]
        }
    }
    return $result
}

function Get-ComponentConfig {
    param(
        [string]$ScriptRoot,
        [string]$Platform = "",
        [string]$ConfigPath = ""
    )
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        return Import-PowerShellDataFile -Path $ConfigPath
    }

    $config = Import-PowerShellDataFile -Path (Join-Path $ScriptRoot "Config.psd1")

    $platformShort = switch ($Platform) {
        "Azure AKS"         { "AzureAKS" }
        "AWS EKS"           { "AWSEKS" }
        "Google GKE"        { "GoogleGKE" }
        "RKE2 (On-Premise)" { "RKE2" }
        "Kind (Local)"      { "Kind" }
        default             { "" }
    }

    if ($platformShort) {
        $overridePath = Join-Path $ScriptRoot "Config.$platformShort.psd1"
        if (Test-Path $overridePath) {
            $override = Import-PowerShellDataFile -Path $overridePath
            $config = Merge-Config -Base $config -Override $override
        }
    }

    return $config
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