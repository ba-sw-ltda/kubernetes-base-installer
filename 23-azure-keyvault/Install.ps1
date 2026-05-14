<#
.SYNOPSIS
    Sets up Azure Key Vault as the cluster secrets backend via the AKS Key Vault Secrets Provider addon.
    The addon installs the Secrets Store CSI Driver + Azure provider automatically.
    Creates a shared Managed Identity for CSI vault access, used by all app SecretProviderClasses.
.PARAMETER Platform
    Target platform
.PARAMETER UseExisting
    $true = use existing Key Vault, $false = create new
.PARAMETER VaultName
    Azure Key Vault name
.PARAMETER ResourceGroup
    Resource Group (only needed when creating new)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [bool]$UseExisting     = $false,
    [string]$VaultName     = "",
    [string]$ResourceGroup = ""
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose    = $VerbosePreference -eq 'Continue'
$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform
$UserConfig = $FullConfig.UserConfig

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 23 - Azure Key Vault" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── Load AKS state ───────────────────────────────────────────────
$aksStatePath2 = Join-Path $BaseDir ".aks-state.json"
if (-not (Test-Path $aksStatePath2)) { Write-Error "No .aks-state.json found — run AKS cluster setup first"; exit 1 }
$aksState    = Get-Content $aksStatePath2 | ConvertFrom-Json
$clusterName = $aksState.ClusterName
$aksRg       = $aksState.ResourceGroup
$location    = $aksState.Location
$subscriptionId = $aksState.SubscriptionId
$targetRg    = if ($ResourceGroup) { $ResourceGroup } else { $aksRg }

if ([string]::IsNullOrWhiteSpace($clusterName))  { Write-Error "ClusterName missing in .aks-state.json";  exit 1 }
if ([string]::IsNullOrWhiteSpace($aksRg))        { Write-Error "ResourceGroup missing in .aks-state.json"; exit 1 }
if ([string]::IsNullOrWhiteSpace($location))     { Write-Error "Location missing in .aks-state.json";      exit 1 }

# ── 0. Azure Login / Subscription ───────────────────────────────
& az account show 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n  Azure login required. Open the following URL in your browser:" -ForegroundColor Cyan
    Write-Host "    https://microsoft.com/devicelogin" -ForegroundColor Yellow
    Write-Host ""
    & az login --use-device-code
    if ($LASTEXITCODE -ne 0) { Write-Error "Azure login failed"; exit 1 }
}
if ($subscriptionId) {
    & az account set --subscription $subscriptionId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to set subscription '$subscriptionId'"; exit 1 }
}

Write-Host "  Vault:       $VaultName" -ForegroundColor Gray
Write-Host "  Mode:        $(if ($UseExisting) { 'Use existing' } else { 'Create new' })" -ForegroundColor Gray
Write-Host "  Resource Grp:$targetRg" -ForegroundColor Gray
Write-Host ""

# ── 1. Resource Provider registrieren ───────────────────────────
$kvProvider = & az provider show --namespace Microsoft.KeyVault --query "registrationState" --output tsv 2>$null
if ($kvProvider) { $kvProvider = $kvProvider.Trim() } else { $kvProvider = "" }
if ($kvProvider -ne "Registered") {
    $exitCode = Invoke-WithSpinner -Message "Registering Microsoft.KeyVault provider..." -Executable "az" `
        -Arguments @("provider", "register", "--namespace", "Microsoft.KeyVault", "--wait") -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Failed to register Microsoft.KeyVault provider"; exit 1 }
    Write-Host "  ✓ Microsoft.KeyVault provider registered" -ForegroundColor Green
} else {
    Write-Host "  ✓ Microsoft.KeyVault provider already registered" -ForegroundColor Green
}

# ── 2. Key Vault erstellen oder prüfen ───────────────────────────
if (-not $UseExisting) {
    # Create RG if it doesn't exist (vault may be in a separate RG from the cluster)
    $rgExists = & az group exists --name $targetRg 2>$null
    if ($rgExists) { $rgExists = $rgExists.Trim() } else { $rgExists = "" }
    if ($rgExists -ne "true") {
        $exitCode = Invoke-WithSpinner -Message "Creating Resource Group '$targetRg'..." -Executable "az" `
            -Arguments @("group", "create", "--name", $targetRg, "--location", $location) -ShowOutput:$verbose
        if ($exitCode -ne 0) { Write-Error "Failed to create Resource Group '$targetRg'"; exit 1 }
        Write-Host "  ✓ Resource Group '$targetRg' created" -ForegroundColor Green
    }

    $exists = & az keyvault show --name $VaultName --resource-group $targetRg 2>$null
    if (-not $exists) {
        # Check if vault is soft-deleted — let user choose recover or purge+create
        $softDeleted = & az keyvault list-deleted --query "[?name=='$VaultName'].name" --output tsv 2>$null
        if ($softDeleted) { $softDeleted = $softDeleted.Trim() } else { $softDeleted = "" }
        if ($softDeleted) {
            $recover = Read-YesNo `
                -Title "Key Vault '$VaultName' ist soft-deleted" `
                -Message "Soll er wiederhergestellt oder endgültig gelöscht (und neu erstellt) werden?" `
                -DefaultYes $true `
                -YesLabel "Wiederherstellen  (Secrets bleiben erhalten)" `
                -NoLabel  "Delete permanently and recreate (all secrets will be lost)" `
                -ContextTitle "Azure Key Vault" `
                -ContextCurrent ([ordered]@{ VaultName = $VaultName; ResourceGroup = $targetRg })
            if ($recover) {
                $exitCode = Invoke-WithSpinner -Message "Recovering soft-deleted Key Vault '$VaultName'..." -Executable "az" `
                    -Arguments @("keyvault", "recover", "--name", $VaultName) -ShowOutput:$verbose
                if ($exitCode -ne 0) { Write-Error "Failed to recover soft-deleted Key Vault '$VaultName'"; exit 1 }
                Write-Host "  ✓ Key Vault recovered from soft-deleted state" -ForegroundColor Green
            } else {
                Write-Host "  ⚠ Azure Key Vault purge kann bis zu 15 Minuten dauern..." -ForegroundColor Yellow
                $exitCode = Invoke-WithSpinner -Message "Purging soft-deleted Key Vault '$VaultName'..." -Executable "az" `
                    -Arguments @("keyvault", "purge", "--name", $VaultName, "--location", $location) -ShowOutput:$verbose
                if ($exitCode -ne 0) { Write-Error "Failed to purge Key Vault '$VaultName'"; exit 1 }
                Write-Host "  ✓ Key Vault purged" -ForegroundColor Green
                $exitCode = Invoke-WithSpinner -Message "Creating Key Vault '$VaultName'..." -Executable "az" `
                    -Arguments @("keyvault", "create",
                        "--name", $VaultName,
                        "--resource-group", $targetRg,
                        "--location", $location,
                        "--sku", $UserConfig.SkuName,
                        "--enable-rbac-authorization", "true") -ShowOutput:$verbose
                if ($exitCode -ne 0) { Write-Error "Failed to create Key Vault '$VaultName'"; exit 1 }
                Write-Host "  ✓ Key Vault created" -ForegroundColor Green
            }
        } else {
            $exitCode = Invoke-WithSpinner -Message "Creating Key Vault '$VaultName'..." -Executable "az" `
                -Arguments @("keyvault", "create",
                    "--name", $VaultName,
                    "--resource-group", $targetRg,
                    "--location", $location,
                    "--sku", $UserConfig.SkuName,
                    "--enable-rbac-authorization", "true") -ShowOutput:$verbose
            if ($exitCode -ne 0) { Write-Error "Failed to create Key Vault '$VaultName'"; exit 1 }
            Write-Host "  ✓ Key Vault created" -ForegroundColor Green
        }
    } else {
        Write-Host "  ✓ Key Vault already exists" -ForegroundColor Green
    }
} else {
    $check = & az keyvault show --name $VaultName 2>$null
    if (-not $check) { Write-Error "Key Vault '$VaultName' not found in subscription"; exit 1 }
    Write-Host "  ✓ Key Vault found" -ForegroundColor Green
}

$vaultUri = "https://$VaultName.vault.azure.net"
$vaultId  = & az keyvault show --name $VaultName --query "id" --output tsv 2>$null
if ($vaultId) { $vaultId = $vaultId.Trim() } else { $vaultId = "" }

# ── 3. AKS Key Vault Secrets Provider Addon aktivieren ───────────
# The addon installs Secrets Store CSI Driver + Azure provider automatically.
# It also enables Workload Identity support for the CSI driver.
$addonEnabled = & az aks show --name $clusterName --resource-group $aksRg `
    --query "addonProfiles.azureKeyvaultSecretsProvider.enabled" --output tsv 2>$null
if ($addonEnabled) { $addonEnabled = $addonEnabled.Trim() } else { $addonEnabled = "" }

if ($addonEnabled -ne "true") {
    $exitCode = Invoke-WithSpinner -Message "Enabling Key Vault Secrets Provider addon..." -Executable "az" `
        -Arguments @("aks", "enable-addons",
            "--addons", "azure-keyvault-secrets-provider",
            "--name", $clusterName,
            "--resource-group", $aksRg,
            "--enable-secret-rotation",
            "--rotation-poll-interval", "2m") -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Failed to enable Key Vault Secrets Provider addon"; exit 1 }
    Write-Host "  ✓ Key Vault Secrets Provider addon enabled" -ForegroundColor Green
} else {
    Write-Host "  ✓ Key Vault Secrets Provider addon already enabled" -ForegroundColor Green
}

# ── 4. Shared CSI Managed Identity ───────────────────────────────
# One identity per cluster — apps create per-app federated credentials later.
$miName = "$clusterName-csi-identity"
$miExists = & az identity show --name $miName --resource-group $aksRg 2>$null
if (-not $miExists) {
    $exitCode = Invoke-WithSpinner -Message "Creating CSI Managed Identity..." -Executable "az" `
        -Arguments @("identity", "create",
            "--name", $miName, "--resource-group", $aksRg, "--location", $location) -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Failed to create Managed Identity"; exit 1 }
    Write-Host "  ✓ CSI Managed Identity created" -ForegroundColor Green
} else {
    Write-Host "  ✓ CSI Managed Identity already exists" -ForegroundColor Green
}

$miClientId    = & az identity show --name $miName --resource-group $aksRg --query "clientId"    --output tsv 2>$null
$miPrincipalId = & az identity show --name $miName --resource-group $aksRg --query "principalId" --output tsv 2>$null
if ($miClientId)    { $miClientId    = $miClientId.Trim()    } else { $miClientId    = "" }
if ($miPrincipalId) { $miPrincipalId = $miPrincipalId.Trim() } else { $miPrincipalId = "" }

# ── 5. OIDC Issuer aktivieren ─────────────────────────────────────
$oidcEnabled = & az aks show --name $clusterName --resource-group $aksRg `
    --query "oidcIssuerProfile.enabled" --output tsv 2>$null
if ($oidcEnabled) { $oidcEnabled = $oidcEnabled.Trim() } else { $oidcEnabled = "" }
if ($oidcEnabled -ne "true") {
    $exitCode = Invoke-WithSpinner -Message "Enabling OIDC issuer + Workload Identity..." -Executable "az" `
        -Arguments @("aks", "update",
            "--name", $clusterName, "--resource-group", $aksRg,
            "--enable-oidc-issuer", "--enable-workload-identity") -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Failed to enable OIDC/Workload Identity"; exit 1 }
    Write-Host "  ✓ OIDC + Workload Identity enabled" -ForegroundColor Green
} else {
    Write-Host "  ✓ OIDC + Workload Identity already enabled" -ForegroundColor Green
}

$oidcIssuer = & az aks show --name $clusterName --resource-group $aksRg `
    --query "oidcIssuerProfile.issuerUrl" --output tsv 2>$null
if ($oidcIssuer) { $oidcIssuer = $oidcIssuer.Trim() } else { $oidcIssuer = "" }

# ── 6. Key Vault RBAC — Secrets Officer role ─────────────────────
# Grant current user access for writing secrets during installation
$currentUserObjectId = & az ad signed-in-user show --query "id" --output tsv 2>$null
if ($currentUserObjectId) { $currentUserObjectId = $currentUserObjectId.Trim() } else { $currentUserObjectId = "" }

foreach ($assignee in @(
    @{ Id = $miPrincipalId; Type = "ServicePrincipal"; Role = "Key Vault Secrets User"; Desc = "CSI identity" }
    @{ Id = $currentUserObjectId; Type = "User"; Role = "Key Vault Secrets Officer"; Desc = "current user (for installation)" }
)) {
    $exitCode = Invoke-WithSpinner -Message "Assigning '$($assignee.Role)' to $($assignee.Desc)..." -Executable "az" `
        -Arguments @("role", "assignment", "create",
            "--role", $assignee.Role,
            "--assignee-object-id", $assignee.Id,
            "--assignee-principal-type", $assignee.Type,
            "--scope", $vaultId) -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Warning "  Role assignment returned non-zero — may already exist" }
    else { Write-Host "  ✓ '$($assignee.Role)' assigned to $($assignee.Desc)" -ForegroundColor Green }
}

# ── 7. State speichern — Key Vault Info in .aks-state.json ───────
$aksStatePath = Join-Path $BaseDir ".aks-state.json"
$aksStateData = if (Test-Path $aksStatePath) {
    Get-Content $aksStatePath | ConvertFrom-Json -AsHashtable
} else { @{} }

$aksStateData['VaultName']   = $VaultName
$aksStateData['VaultUri']    = $vaultUri
$aksStateData['VaultRg']     = $targetRg
$aksStateData['MiName']      = $miName
$aksStateData['MiClientId']  = $miClientId
$aksStateData['OidcIssuer']  = $oidcIssuer

$aksStateData | ConvertTo-Json | Set-Content -Path $aksStatePath -Encoding UTF8
Write-Host "  ✓ State saved to $aksStatePath" -ForegroundColor Green

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Key Vault:      $vaultUri" -ForegroundColor Yellow
Write-Host "  CSI Identity:   $miClientId" -ForegroundColor Gray
Write-Host "  Auth:           Workload Identity per Pod" -ForegroundColor Gray
Write-Host "  Secrets:        mounted as files (no etcd)" -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0

