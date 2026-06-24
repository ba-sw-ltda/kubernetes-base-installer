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
# ClusterSecret — platform-agnostic dispatcher that writes secrets to the
# appropriate backend (OpenBao for RKE2/Kind, Azure Key Vault for AKS, etc.)
# and ensures a ClusterSecretStore named 'cluster-secrets' is the target.
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
    [Console]::Write("`r  $($frames[$fi++ % 4]) Schreibe Secret '$Path' in Vault...")

    $result = switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            Write-OpenBaoSecret -Path $Path -Data $Data -BaseDir $BaseDir
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
        Write-Host ("`r  ✓ Secret '$Path' in Vault gespeichert" + (" " * 10)) -ForegroundColor Green
    } else {
        [Console]::Write("`r" + (" " * 60) + "`r")
    }
    return $result
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
        [string]$BaseDir = $script:InstallerBaseDir
    )

    $stateFile = Join-Path $BaseDir ".openbao-state.json"
    if (-not (Test-Path $stateFile)) { return $false }

    $rootToken = (Get-Content $stateFile | ConvertFrom-Json).RootToken
    if (-not $rootToken) { return $false }

    $podStatus = & kubectl get pod openbao-0 -n openbao `
        --no-headers -o custom-columns="S:.status.phase" 2>$null
    if ($podStatus -ne "Running") { return $false }

    $kvData  = ($Data.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " "
    & kubectl exec openbao-0 -n openbao -- `
        sh -c "BAO_TOKEN=$rootToken bao kv put secret/$Path $kvData" 2>$null | Out-Null

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
            if (-not (Test-Path (Join-Path $BaseDir ".openbao-state.json"))) { return $notInstalled }
            $baoState  = Get-Content (Join-Path $BaseDir ".openbao-state.json") | ConvertFrom-Json
            $rootToken = $baoState.RootToken

            # Vault Kubernetes auth role — single line to avoid shell backtick/continuation issues
            $baoCmd = "BAO_TOKEN=$rootToken bao write auth/kubernetes/role/$AppName bound_service_account_names='$ServiceAccount' bound_service_account_namespaces='$Namespace' policies='csi-readonly' ttl='1h'"
            & kubectl exec openbao-0 -n openbao -- sh -c $baoCmd 2>$null | Out-Null

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
  'Write-OpenBaoSecret'
  'Set-ClusterContext'
  'Clear-KubectlDiscoveryCache'
  'Write-ClusterSecret'
  'Write-AzureKeyVaultSecret'
  'Write-AwsSecretsManagerSecret'
  'Write-GcpSecretManagerSecret'
  'New-CsiSecretMount'
  'Get-ExternalSecretData'
  'Read-ComponentSelectionScreen'
)

Export-ModuleMember -Function $__exportFunctions