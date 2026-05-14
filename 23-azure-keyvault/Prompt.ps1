<#
.SYNOPSIS
    Collect Azure Key Vault settings upfront.
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param([string]$Platform)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

# Pre-fill from AKS state and existing Key Vault state
$aksState = $null
$aksStateFile = Join-Path $BaseDir ".aks-state.json"
if (Test-Path $aksStateFile) { $aksState = Get-Content $aksStateFile | ConvertFrom-Json }

$selected = Read-SelectValue `
    -Title "Azure Key Vault" `
    -Message "Select an existing Key Vault or create a new one" `
    -Options @(@{ Label = "[ Neuen Key Vault erstellen ]"; Value = "__new__" }) `
    -Default 0 `
    -DefaultValue ($aksState.VaultName) `
    -ContextTitle "Secrets Backend" `
    -ContextHint "Bestehend = vorhandener Vault wird verwendet. Neu = vollautomatisch über Script angelegt." `
    -ContextCurrent ([ordered]@{ Platform = $Platform }) `
    -Loader {
        param($path); $env:PATH = $path
        $raw = & az keyvault list --query "[].{name:name, rg:resourceGroup, location:location}" --output json 2>$null
        $vaults = try { $raw | ConvertFrom-Json } catch { @() }
        $opts = @(@{ Label = "[ Neuen Key Vault erstellen ]"; Value = "__new__" })
        foreach ($v in $vaults) { $opts += @{ Label = "$($v.name)  ($($v.rg) · $($v.location))"; Value = $v.name } }
        return $opts
    } `
    -LoadingMessage "Lade Key Vaults..."


if (-not $selected) { return $null }

if ($selected -ne "__new__") {
    return @{
        UseExisting = $true
        VaultName   = $selected
    }
}

$defaultName      = if ($aksState) { "$($aksState.ClusterName)-vault" } else { "k8s-vault" }
$suggestedVaultRg = if ($aksState) { "$($aksState.ClusterName)-vault-rg" } else { "vault-rg" }

$vaultName = Read-Plain `
    -Prompt "Key Vault name" `
    -Default $defaultName `
    -ContextTitle "Azure Key Vault (new)" `
    -ContextHint "Globally unique name, 3-24 chars, alphanumeric and hyphens only" `
    -ContextCurrent ([ordered]@{ Platform = $Platform })

$selectedRg = Read-SelectValue `
    -Title "Resource Group für Key Vault" `
    -Message "Recommended: separate RG so the vault survives a cluster reset" `
    -Options @(@{ Label = "[ Neue Resource Group erstellen ]"; Value = "__new__" }) `
    -Default 0 `
    -DefaultValue $suggestedVaultRg `
    -ContextTitle "Azure Key Vault (new)" `
    -ContextHint "Separate RG = Vault bleibt bei 'Reset-AKS.ps1' erhalten" `
    -ContextCurrent ([ordered]@{ VaultName = $vaultName.Trim() }) `
    -Loader {
        param($path, $clusterRg); $env:PATH = $path
        $raw = & az group list --query "[].{name:name, location:location}" --output json 2>$null
        $rgs = try { $raw | ConvertFrom-Json } catch { @() }
        $opts = @(@{ Label = "[ Neue Resource Group erstellen ]"; Value = "__new__" })
        foreach ($rg in ($rgs | Sort-Object name)) {
            $marker = if ($rg.name -eq $clusterRg) { "  [Cluster RG]" } else { "" }
            $opts += @{ Label = "$($rg.name)  ($($rg.location))$marker"; Value = $rg.name }
        }
        return $opts
    } `
    -LoaderArgs @($aksState.ResourceGroup) `
    -LoadingMessage "Lade Resource Groups..."

if (-not $selectedRg) { return $null }

if ($selectedRg -eq "__new__") {
    $selectedRg = Read-Plain `
        -Prompt "Neue Resource Group" `
        -Default $suggestedVaultRg `
        -ContextTitle "Azure Key Vault (new)" `
        -ContextHint "Wird automatisch erstellt" `
        -ContextCurrent ([ordered]@{ VaultName = $vaultName.Trim() })
    if ([string]::IsNullOrWhiteSpace($selectedRg)) { $selectedRg = $suggestedVaultRg }
}

return @{
    UseExisting   = $false
    VaultName     = $vaultName.Trim()
    ResourceGroup = $selectedRg.Trim()
}

