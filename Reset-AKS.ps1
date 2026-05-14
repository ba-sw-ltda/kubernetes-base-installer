<#
.SYNOPSIS
    Deletes the AKS cluster and resource group created by Install-Base.ps1
#>
[CmdletBinding()]
param()

$stateFile = Join-Path $PSScriptRoot ".aks-state.json"

if (-not (Test-Path $stateFile)) {
    Write-Error "No AKS state file found at $stateFile. Nothing to reset."
    exit 1
}

$state = Get-Content $stateFile | ConvertFrom-Json
Import-Module "$PSScriptRoot\_lib\Installer.Ui.psm1" -Force -Verbose:$false

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  AKS Teardown" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow
Write-Host "  Cluster:        $($state.ClusterName)" -ForegroundColor Gray
Write-Host "  Resource Group: $($state.ResourceGroup)" -ForegroundColor Gray
Write-Host "  Subscription:   $($state.SubscriptionId)" -ForegroundColor Gray
Write-Host "  Region:         $($state.Location)" -ForegroundColor Gray
Write-Host "  Created:        $($state.CreatedAt)" -ForegroundColor Gray
Write-Host ""

$confirm = Read-Host "  Type 'yes' to delete resource group '$($state.ResourceGroup)' and ALL contents"
if ($confirm -ne "yes") {
    Write-Host "  Aborted." -ForegroundColor Yellow
    exit 0
}

& az account show 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "  Azure login required. Open the following URL in your browser:" -ForegroundColor Cyan
    Write-Host "    https://microsoft.com/devicelogin" -ForegroundColor Yellow
    Write-Host "  Then enter the code shown below." -ForegroundColor Cyan
    Write-Host ""
    & az login --use-device-code
    if ($LASTEXITCODE -ne 0) { Write-Error "Azure login failed"; exit 1 }
}

$exitCode = Invoke-WithSpinner -Message "Setting subscription..." -Executable "az" `
    -Arguments @("account", "set", "--subscription", $state.SubscriptionId)
if ($exitCode -ne 0) { Write-Error "Failed to set subscription"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Deleting resource group '$($state.ResourceGroup)' (5-10 min)..." -Executable "az" `
    -Arguments @("group", "delete", "--name", $state.ResourceGroup, "--yes")
if ($exitCode -ne 0) { Write-Error "Failed to delete resource group '$($state.ResourceGroup)'"; exit 1 }

Remove-Item $stateFile -Force -ErrorAction SilentlyContinue

# Key Vault: only purge if vault is in the SAME resource group as the cluster.
# If vault has its own RG it was intentionally separated and should survive the reset.
if ($state.VaultName) {
    $vaultRg = if ($state.VaultRg) { $state.VaultRg } else { $state.ResourceGroup }
    if ($vaultRg -eq $state.ResourceGroup) {
        # Same RG → deleted with cluster → purge so name can be reused
        $softDeleted = & az keyvault list-deleted --query "[?name=='$($state.VaultName)'].name" --output tsv 2>$null
        if ($softDeleted) {
            Write-Host "  ⚠ Azure Key Vault purge kann bis zu 15 Minuten dauern..." -ForegroundColor Yellow
            $exitCode = Invoke-WithSpinner -Message "Purging soft-deleted Key Vault '$($state.VaultName)'..." -Executable "az" `
                -Arguments @("keyvault", "purge", "--name", $state.VaultName, "--location", $state.Location)
            if ($exitCode -eq 0) { Write-Host "  ✓ Key Vault purged" -ForegroundColor Green }
            else { Write-Warning "  Key Vault purge failed — purge manually if needed" }
        }
    } else {
        # Separate RG → ask whether to delete it too
        $deleteVault = Read-YesNo `
            -Title "Key Vault '$($state.VaultName)' in eigener RG '$vaultRg'" `
            -Message "Delete as well?" `
            -DefaultYes $false `
            -YesLabel "Yes — delete resource group '$vaultRg' and Key Vault" `
            -NoLabel  "No — keep Key Vault (reusable for a new cluster)"
        if ($deleteVault) {
            $exitCode = Invoke-WithSpinner -Message "Deleting Resource Group '$vaultRg'..." -Executable "az" `
                -Arguments @("group", "delete", "--name", $vaultRg, "--yes")
            if ($exitCode -eq 0) {
                Write-Host "  ✓ Key Vault Resource Group '$vaultRg' deleted" -ForegroundColor Green
                $softDeleted = & az keyvault list-deleted --query "[?name=='$($state.VaultName)'].name" --output tsv 2>$null
                if ($softDeleted) {
                    Invoke-WithSpinner -Message "Purging Key Vault '$($state.VaultName)'..." -Executable "az" `
                        -Arguments @("keyvault", "purge", "--name", $state.VaultName, "--location", $state.Location) | Out-Null
                    Write-Host "  ✓ Key Vault purged" -ForegroundColor Green
                }
            } else {
                Write-Warning "  Resource Group delete failed — delete manually if needed"
            }
        } else {
            Write-Host "  ✓ Key Vault '$($state.VaultName)' in RG '$vaultRg' — preserved" -ForegroundColor Green
        }
    }
}

Write-Host ""
Write-Host "  ✓ Resource group and all resources deleted" -ForegroundColor Green
Write-Host "  ✓ State files removed" -ForegroundColor Green
Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  AKS Teardown Complete" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow

exit 0

