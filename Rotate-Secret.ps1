<#
.SYNOPSIS
    Interactive secret rotation — platform-agnostic.
    Supports OpenBao (RKE2/Kind), Azure Key Vault (AKS) and GCP Secret Manager (GKE).
    Updates the secret in the backend, then restarts workloads that use it via CSI mount.
#>
[CmdletBinding()]
param()

$BaseDir = $PSScriptRoot
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

trap {
    Write-Host "`n`n  Error: $(<#
.SYNOPSIS
    Interactive secret rotation — platform-agnostic.
    Supports OpenBao (RKE2/Kind), Azure Key Vault (AKS) and GCP Secret Manager (GKE).
    Updates the secret in the backend, then restarts workloads that use it via CSI mount.
#>
[CmdletBinding()]
param()

$BaseDir = $PSScriptRoot
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

trap {
    Write-Host "

  Error: $(<#
.SYNOPSIS
    Interactive secret rotation — platform-agnostic.
    Supports OpenBao (RKE2/Kind), Azure Key Vault (AKS) and GCP Secret Manager (GKE).
    Updates the secret in the backend, then restarts workloads that use it via CSI mount.
#>
[CmdletBinding()]
param()

$BaseDir = $PSScriptRoot
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

trap {
    Write-Host "`n`n  Error: $(<#
.SYNOPSIS
    Interactive secret rotation — platform-agnostic.
    Supports OpenBao (RKE2/Kind), Azure Key Vault (AKS) and GCP Secret Manager (GKE).
    Updates the secret in the backend, then restarts workloads that use it via CSI mount.
#>
[CmdletBinding()]
param()

$BaseDir = $PSScriptRoot
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

trap {
    Write-Host "`n`n  Error: $(<#
.SYNOPSIS
    Interactive secret rotation — platform-agnostic.
    Supports OpenBao (RKE2/Kind), Azure Key Vault (AKS) and GCP Secret Manager (GKE).
    Updates the secret in the backend, then restarts workloads that use it via CSI mount.
#>
[CmdletBinding()]
param()

$BaseDir = $PSScriptRoot
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

trap {
    Write-Host "`n`n  Error: $(<#
.SYNOPSIS
    Interactive secret rotation — platform-agnostic.
    Supports OpenBao (RKE2/Kind), Azure Key Vault (AKS) and GCP Secret Manager (GKE).
    Updates the secret in the backend, then restarts workloads that use it via CSI mount.
#>
[CmdletBinding()]
param()

$BaseDir = $PSScriptRoot
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

trap {
    Write-Host "

  Error: $(<#
.SYNOPSIS
    Interactive secret rotation — platform-agnostic.
    Supports OpenBao (RKE2/Kind), Azure Key Vault (AKS) and GCP Secret Manager (GKE).
    Updates the secret in the backend, then restarts workloads that use it via CSI mount.
#>
[CmdletBinding()]
param()

$BaseDir = $PSScriptRoot
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

trap {
    Write-Host "`n`n  Error: $(<#
.SYNOPSIS
    Interactive secret rotation — platform-agnostic.
    Supports OpenBao (RKE2/Kind), Azure Key Vault (AKS) and GCP Secret Manager (GKE).
    Updates the secret in the backend, then restarts workloads that use it via CSI mount.
#>
[CmdletBinding()]
param()

$BaseDir = $PSScriptRoot
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

trap {
    Write-Host "`n`n  Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    exit 1
}

# ── 1. Select platform ───────────────────────────────────────
$platforms = @()
if (Test-Path (Join-Path $BaseDir ".rke2-state.json"))  { $platforms += @{ Label = "RKE2 (On-Premise)";  Value = "RKE2 (On-Premise)" } }
if (Test-Path (Join-Path $BaseDir ".kind-state.json"))  { $platforms += @{ Label = "Kind (Local)";        Value = "Kind (Local)" } }
if (Test-Path (Join-Path $BaseDir ".aks-state.json"))   { $platforms += @{ Label = "Azure AKS";           Value = "Azure AKS" } }
if (Test-Path (Join-Path $BaseDir ".eks-state.json"))   { $platforms += @{ Label = "AWS EKS";             Value = "AWS EKS" } }
if (Test-Path (Join-Path $BaseDir ".gke-state.json"))   { $platforms += @{ Label = "Google GKE";          Value = "Google GKE" } }

if ($platforms.Count -eq 0) { Write-Host "  No installed clusters found." -ForegroundColor Red; exit 1 }

$platform = if ($platforms.Count -eq 1) {
    $platforms[0].Value
} else {
    Read-SelectValue `
        -Title "Select cluster" `
        -Message "On which cluster should the secret be rotated?" `
        -Options $platforms -Default 0 `
        -ContextTitle "Secret Rotation" `
        -ContextHint "Multiple installed clusters found"
}
if (-not $platform) { exit 0 }

# ── 2. Kubecontext setzen ────────────────────────────────────────
Set-ClusterContext -BaseDir $BaseDir -Platform $platform

# ── 3. Backend initialisieren ────────────────────────────────────
$backendType = switch ($platform) {
    { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
        if (-not (Test-Path (Join-Path $BaseDir ".openbao-state.json"))) {
            Write-Host "  OpenBao not installed on $platform" -ForegroundColor Red; exit 1
        }
        "openbao"
    }
    "Azure AKS" {
        $aksS = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
        if (-not $aksS.VaultName) { Write-Host "  Azure Key Vault not configured for AKS" -ForegroundColor Red; exit 1 }
        "azurekv"
    }
    "AWS EKS" {
        $eksS = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
        if (-not $eksS.Region) { Write-Host "  EKS state not found" -ForegroundColor Red; exit 1 }
        "awssm"
    }
    "Google GKE" {
        $gkeS = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
        if (-not $gkeS.ProjectId) { Write-Host "  GKE state not found" -ForegroundColor Red; exit 1 }
        "gcpsm"
    }
    default { Write-Host "  Secret rotation for $platform not yet supported" -ForegroundColor Red; exit 1 }
}

$rootToken = $null
$vaultName = $null
$projectId = $null
$awsRegion = $null
if ($backendType -eq "openbao") {
    $rootToken = (Get-Content (Join-Path $BaseDir ".openbao-state.json") | ConvertFrom-Json).RootToken
} elseif ($backendType -eq "azurekv") {
    $vaultName = (Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json).VaultName
    $exitCode = Invoke-WithSpinner -Message "Prüfe Azure Login..." -Executable "az" `
        -Arguments @("account", "show")
    if ($exitCode -ne 0) {
        Write-Host "`n  Azure login erforderlich." -ForegroundColor Cyan
        & az login --use-device-code
        if ($LASTEXITCODE -ne 0) { Write-Host "  Azure login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
} elseif ($backendType -eq "awssm") {
    $awsRegion = (Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json).Region
    & aws sts get-caller-identity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  AWS not configured. Please run 'aws configure'." -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $projectId = (Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json).ProjectId
    $gcloudAccount = & gcloud config get-value account 2>$null
    if ([string]::IsNullOrWhiteSpace($gcloudAccount) -or $gcloudAccount -eq "(unset)") {
        Write-Host "`n  Google login erforderlich." -ForegroundColor Cyan
        & gcloud auth login --no-launch-browser
        if ($LASTEXITCODE -ne 0) { Write-Host "  Google login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
    & gcloud config set project $projectId 2>&1 | Out-Null
}

# ── 4. Select secret (loader with spinner) ─────────────────────
$selected = Read-SelectValue `
    -Title "Select secret" `
    -Message "Which secret should be rotated?" `
    -Options @(@{ Label = "[ Lade... ]"; Value = "" }) `
    -Default 0 `
    -ContextTitle "Secret Rotation" `
    -ContextHint "Reads SecretProviderClasses from the cluster" `
    -ContextCurrent ([ordered]@{ Cluster = $platform }) `
    -Loader {
        param($path); $env:PATH = $path
        $spcList = & kubectl get secretproviderclass -A -o json 2>$null | ConvertFrom-Json
        $items = if ($spcList -and $spcList.items) { $spcList.items } else { @() }
        if ($items.Count -eq 0) { return @(@{ Label = "[ No SecretProviderClasses found ]"; Value = "" }) }
        $items | ForEach-Object {
            @{ Label = "$($_.metadata.name)  ($($_.metadata.namespace))"; Value = "$($_.metadata.name)|$($_.metadata.namespace)" }
        } | Sort-Object { $_.Label }
    } `
    -LoadingMessage "Lade SecretProviderClasses..."

if (-not $selected) { exit 0 }

$spcName   = ($selected -split '\|')[0]
$spcNs     = ($selected -split '\|')[1]
$vaultPath = $spcName -replace '-vault$', ''   # grafana-vault → grafana

# ── 5. Aktuelles Secret lesen ────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$currentRef = [ref]$null
if ($backendType -eq "openbao") {
    Invoke-WithSpinner -Message "Reading secret from OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv get -format=json secret/$vaultPath") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "azurekv") {
    Invoke-WithSpinner -Message "Reading secret from Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "show",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--query", "value", "--output", "tsv") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "awssm") {
    Invoke-WithSpinner -Message "Reading secret from AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "get-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--query", "SecretString", "--output", "text") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "gcpsm") {
    Invoke-WithSpinner -Message "Reading secret from GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "access", "latest",
                     "--secret", $vaultPath, "--project", $projectId) `
        -OutputVariable $currentRef | Out-Null
}
if (-not ($currentRef.Value -and ($currentRef.Value -join "").Trim() -ne "")) {
    Write-Host "  Secret '$vaultPath' not found in backend." -ForegroundColor Red; exit 1
}
Write-Host "  ✓ Secret found" -ForegroundColor Green

# ── 6. Neues Passwort eingeben ───────────────────────────────────
do {
    $newPassword = Read-SecretPlainConfirm `
        -Prompt1 "Neues Passwort (min. 8 Zeichen)" `
        -Prompt2 "Passwort bestätigen" `
        -ContextTitle "Secret Rotation" `
        -ContextHint  "Aktuell: ••••••••" `
        -ContextCurrent ([ordered]@{ Secret = $spcName; Namespace = $spcNs; Cluster = $platform })
    if ($newPassword.Length -lt 8) {
        Write-Host "  Passwort muss mindestens 8 Zeichen haben." -ForegroundColor Red
    }
} while ($newPassword.Length -lt 8)

# ── 7. Secret schreiben ──────────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "  Secret:    $spcName" -ForegroundColor Gray
Write-Host "  Namespace: $spcNs" -ForegroundColor Gray
Write-Host "  Cluster:   $platform" -ForegroundColor Gray
Write-Host ""

if ($backendType -eq "openbao") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv put secret/$vaultPath adminPassword=$newPassword")
    if ($exitCode -ne 0) { Write-Host "  Error writing to OpenBao" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "azurekv") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "set",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--file", $tmpFile.FullName, "--encoding", "utf-8")
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to Azure Key Vault" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "awssm") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "put-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--secret-string", $newPassword)
    if ($exitCode -ne 0) { Write-Host "  Error writing to AWS Secrets Manager" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "add", $vaultPath,
                     "--project", $projectId, "--data-file", $tmpFile.FullName)
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to GCP Secret Manager" -ForegroundColor Red; exit 1 }
}
Write-Host "  ✓ Secret aktualisiert" -ForegroundColor Green
Write-Host ""

# ── 8. Betroffene Workloads neustarten ───────────────────────────
$restarted = @()
foreach ($kind in @("deployment", "statefulset", "daemonset")) {
    $resources = & kubectl get $kind -n $spcNs -o json 2>$null | ConvertFrom-Json
    if (-not $resources -or -not $resources.items) { continue }
    foreach ($r in $resources.items) {
        $usesSpc = $r.spec.template.spec.volumes | Where-Object {
            $_.csi -and
            $_.csi.driver -eq "secrets-store.csi.k8s.io" -and
            $_.csi.volumeAttributes.secretProviderClass -eq $spcName
        }
        if ($usesSpc) { $restarted += @{ Kind = $kind; Name = $r.metadata.name } }
    }
}

if ($restarted.Count -eq 0) {
    Write-Host "  No workloads with SPC '$spcName' in '$spcNs' found." -ForegroundColor Yellow
} else {
    foreach ($w in $restarted) {
        $exitCode = Invoke-WithSpinner -Message "Restarting $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "restart", "$($w.Kind)/$($w.Name)", "-n", $spcNs)
        if ($exitCode -ne 0) { Write-Host "  ✗ Restart failed: $($w.Kind)/$($w.Name)" -ForegroundColor Red; continue }

        $exitCode = Invoke-WithSpinner -Message "Waiting for $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "status", "$($w.Kind)/$($w.Name)", "-n", $spcNs, "--timeout=3m")
        if ($exitCode -eq 0) {
            Write-Host "  ✓ $($w.Kind)/$($w.Name) läuft mit neuem Passwort" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Rollout timeout — please check status manually" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Rotation complete" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    exit 1
}

# ── 1. Select platform ───────────────────────────────────────
$platforms = @()
if (Test-Path (Join-Path $BaseDir ".rke2-state.json"))  { $platforms += @{ Label = "RKE2 (On-Premise)";  Value = "RKE2 (On-Premise)" } }
if (Test-Path (Join-Path $BaseDir ".kind-state.json"))  { $platforms += @{ Label = "Kind (Local)";        Value = "Kind (Local)" } }
if (Test-Path (Join-Path $BaseDir ".aks-state.json"))   { $platforms += @{ Label = "Azure AKS";           Value = "Azure AKS" } }
if (Test-Path (Join-Path $BaseDir ".eks-state.json"))   { $platforms += @{ Label = "AWS EKS";             Value = "AWS EKS" } }
if (Test-Path (Join-Path $BaseDir ".gke-state.json"))   { $platforms += @{ Label = "Google GKE";          Value = "Google GKE" } }

if ($platforms.Count -eq 0) { Write-Host "  No installed clusters found." -ForegroundColor Red; exit 1 }

$platform = if ($platforms.Count -eq 1) {
    $platforms[0].Value
} else {
    Read-SelectValue `
        -Title "Select cluster" `
        -Message "On which cluster should the secret be rotated?" `
        -Options $platforms -Default 0 `
        -ContextTitle "Secret Rotation" `
        -ContextHint "Multiple installed clusters found"
}
if (-not $platform) { exit 0 }

# ── 2. Kubecontext setzen ────────────────────────────────────────
Set-ClusterContext -BaseDir $BaseDir -Platform $platform

# ── 3. Backend initialisieren ────────────────────────────────────
$backendType = switch ($platform) {
    { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
        if (-not (Test-Path (Join-Path $BaseDir ".openbao-state.json"))) {
            Write-Host "  OpenBao not installed on $platform" -ForegroundColor Red; exit 1
        }
        "openbao"
    }
    "Azure AKS" {
        $aksS = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
        if (-not $aksS.VaultName) { Write-Host "  Azure Key Vault not configured for AKS" -ForegroundColor Red; exit 1 }
        "azurekv"
    }
    "AWS EKS" {
        $eksS = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
        if (-not $eksS.Region) { Write-Host "  EKS state not found" -ForegroundColor Red; exit 1 }
        "awssm"
    }
    "Google GKE" {
        $gkeS = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
        if (-not $gkeS.ProjectId) { Write-Host "  GKE state not found" -ForegroundColor Red; exit 1 }
        "gcpsm"
    }
    default { Write-Host "  Secret rotation for $platform not yet supported" -ForegroundColor Red; exit 1 }
}

$rootToken = $null
$vaultName = $null
$projectId = $null
$awsRegion = $null
if ($backendType -eq "openbao") {
    $rootToken = (Get-Content (Join-Path $BaseDir ".openbao-state.json") | ConvertFrom-Json).RootToken
} elseif ($backendType -eq "azurekv") {
    $vaultName = (Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json).VaultName
    $exitCode = Invoke-WithSpinner -Message "Prüfe Azure Login..." -Executable "az" `
        -Arguments @("account", "show")
    if ($exitCode -ne 0) {
        Write-Host "`n  Azure login erforderlich." -ForegroundColor Cyan
        & az login --use-device-code
        if ($LASTEXITCODE -ne 0) { Write-Host "  Azure login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
} elseif ($backendType -eq "awssm") {
    $awsRegion = (Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json).Region
    & aws sts get-caller-identity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  AWS not configured. Please run 'aws configure'." -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $projectId = (Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json).ProjectId
    $gcloudAccount = & gcloud config get-value account 2>$null
    if ([string]::IsNullOrWhiteSpace($gcloudAccount) -or $gcloudAccount -eq "(unset)") {
        Write-Host "`n  Google login erforderlich." -ForegroundColor Cyan
        & gcloud auth login --no-launch-browser
        if ($LASTEXITCODE -ne 0) { Write-Host "  Google login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
    & gcloud config set project $projectId 2>&1 | Out-Null
}

# ── 4. Select secret (loader with spinner) ─────────────────────
$selected = Read-SelectValue `
    -Title "Select secret" `
    -Message "Which secret should be rotated?" `
    -Options @(@{ Label = "[ Lade... ]"; Value = "" }) `
    -Default 0 `
    -ContextTitle "Secret Rotation" `
    -ContextHint "Reads SecretProviderClasses from the cluster" `
    -ContextCurrent ([ordered]@{ Cluster = $platform }) `
    -Loader {
        param($path); $env:PATH = $path
        $spcList = & kubectl get secretproviderclass -A -o json 2>$null | ConvertFrom-Json
        $items = if ($spcList -and $spcList.items) { $spcList.items } else { @() }
        if ($items.Count -eq 0) { return @(@{ Label = "[ No SecretProviderClasses found ]"; Value = "" }) }
        $items | ForEach-Object {
            @{ Label = "$($_.metadata.name)  ($($_.metadata.namespace))"; Value = "$($_.metadata.name)|$($_.metadata.namespace)" }
        } | Sort-Object { $_.Label }
    } `
    -LoadingMessage "Lade SecretProviderClasses..."

if (-not $selected) { exit 0 }

$spcName   = ($selected -split '\|')[0]
$spcNs     = ($selected -split '\|')[1]
$vaultPath = $spcName -replace '-vault$', ''   # grafana-vault → grafana

# ── 5. Aktuelles Secret lesen ────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$currentRef = [ref]$null
if ($backendType -eq "openbao") {
    Invoke-WithSpinner -Message "Reading secret from OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv get -format=json secret/$vaultPath") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "azurekv") {
    Invoke-WithSpinner -Message "Reading secret from Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "show",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--query", "value", "--output", "tsv") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "awssm") {
    Invoke-WithSpinner -Message "Reading secret from AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "get-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--query", "SecretString", "--output", "text") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "gcpsm") {
    Invoke-WithSpinner -Message "Reading secret from GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "access", "latest",
                     "--secret", $vaultPath, "--project", $projectId) `
        -OutputVariable $currentRef | Out-Null
}
if (-not ($currentRef.Value -and ($currentRef.Value -join "").Trim() -ne "")) {
    Write-Host "  Secret '$vaultPath' not found in backend." -ForegroundColor Red; exit 1
}
Write-Host "  ✓ Secret found" -ForegroundColor Green

# ── 6. Neues Passwort eingeben ───────────────────────────────────
do {
    $newPassword = Read-SecretPlainConfirm `
        -Prompt1 "Neues Passwort (min. 8 Zeichen)" `
        -Prompt2 "Passwort bestätigen" `
        -ContextTitle "Secret Rotation" `
        -ContextHint  "Aktuell: ••••••••" `
        -ContextCurrent ([ordered]@{ Secret = $spcName; Namespace = $spcNs; Cluster = $platform })
    if ($newPassword.Length -lt 8) {
        Write-Host "  Passwort muss mindestens 8 Zeichen haben." -ForegroundColor Red
    }
} while ($newPassword.Length -lt 8)

# ── 7. Secret schreiben ──────────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "  Secret:    $spcName" -ForegroundColor Gray
Write-Host "  Namespace: $spcNs" -ForegroundColor Gray
Write-Host "  Cluster:   $platform" -ForegroundColor Gray
Write-Host ""

if ($backendType -eq "openbao") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv put secret/$vaultPath adminPassword=$newPassword")
    if ($exitCode -ne 0) { Write-Host "  Error writing to OpenBao" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "azurekv") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "set",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--file", $tmpFile.FullName, "--encoding", "utf-8")
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to Azure Key Vault" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "awssm") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "put-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--secret-string", $newPassword)
    if ($exitCode -ne 0) { Write-Host "  Error writing to AWS Secrets Manager" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "add", $vaultPath,
                     "--project", $projectId, "--data-file", $tmpFile.FullName)
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to GCP Secret Manager" -ForegroundColor Red; exit 1 }
}
Write-Host "  ✓ Secret aktualisiert" -ForegroundColor Green
Write-Host ""

# ── 8. Betroffene Workloads neustarten ───────────────────────────
$restarted = @()
foreach ($kind in @("deployment", "statefulset", "daemonset")) {
    $resources = & kubectl get $kind -n $spcNs -o json 2>$null | ConvertFrom-Json
    if (-not $resources -or -not $resources.items) { continue }
    foreach ($r in $resources.items) {
        $usesSpc = $r.spec.template.spec.volumes | Where-Object {
            $_.csi -and
            $_.csi.driver -eq "secrets-store.csi.k8s.io" -and
            $_.csi.volumeAttributes.secretProviderClass -eq $spcName
        }
        if ($usesSpc) { $restarted += @{ Kind = $kind; Name = $r.metadata.name } }
    }
}

if ($restarted.Count -eq 0) {
    Write-Host "  No workloads with SPC '$spcName' in '$spcNs' found." -ForegroundColor Yellow
} else {
    foreach ($w in $restarted) {
        $exitCode = Invoke-WithSpinner -Message "Restarting $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "restart", "$($w.Kind)/$($w.Name)", "-n", $spcNs)
        if ($exitCode -ne 0) { Write-Host "  ✗ Restart failed: $($w.Kind)/$($w.Name)" -ForegroundColor Red; continue }

        $exitCode = Invoke-WithSpinner -Message "Waiting for $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "status", "$($w.Kind)/$($w.Name)", "-n", $spcNs, "--timeout=3m")
        if ($exitCode -eq 0) {
            Write-Host "  ✓ $($w.Kind)/$($w.Name) läuft mit neuem Passwort" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Rollout timeout — please check status manually" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Rotation complete" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green


.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    exit 1
}

# ── 1. Select platform ───────────────────────────────────────
$platforms = @()
if (Test-Path (Join-Path $BaseDir ".rke2-state.json"))  { $platforms += @{ Label = "RKE2 (On-Premise)";  Value = "RKE2 (On-Premise)" } }
if (Test-Path (Join-Path $BaseDir ".kind-state.json"))  { $platforms += @{ Label = "Kind (Local)";        Value = "Kind (Local)" } }
if (Test-Path (Join-Path $BaseDir ".aks-state.json"))   { $platforms += @{ Label = "Azure AKS";           Value = "Azure AKS" } }
if (Test-Path (Join-Path $BaseDir ".eks-state.json"))   { $platforms += @{ Label = "AWS EKS";             Value = "AWS EKS" } }
if (Test-Path (Join-Path $BaseDir ".gke-state.json"))   { $platforms += @{ Label = "Google GKE";          Value = "Google GKE" } }

if ($platforms.Count -eq 0) { Write-Host "  No installed clusters found." -ForegroundColor Red; exit 1 }

$platform = if ($platforms.Count -eq 1) {
    $platforms[0].Value
} else {
    Read-SelectValue `
        -Title "Select cluster" `
        -Message "On which cluster should the secret be rotated?" `
        -Options $platforms -Default 0 `
        -ContextTitle "Secret Rotation" `
        -ContextHint "Multiple installed clusters found"
}
if (-not $platform) { exit 0 }

# ── 2. Kubecontext setzen ────────────────────────────────────────
Set-ClusterContext -BaseDir $BaseDir -Platform $platform

# ── 3. Backend initialisieren ────────────────────────────────────
$backendType = switch ($platform) {
    { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
        if (-not (Test-Path (Join-Path $BaseDir ".openbao-state.json"))) {
            Write-Host "  OpenBao not installed on $platform" -ForegroundColor Red; exit 1
        }
        "openbao"
    }
    "Azure AKS" {
        $aksS = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
        if (-not $aksS.VaultName) { Write-Host "  Azure Key Vault not configured for AKS" -ForegroundColor Red; exit 1 }
        "azurekv"
    }
    "AWS EKS" {
        $eksS = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
        if (-not $eksS.Region) { Write-Host "  EKS state not found" -ForegroundColor Red; exit 1 }
        "awssm"
    }
    "Google GKE" {
        $gkeS = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
        if (-not $gkeS.ProjectId) { Write-Host "  GKE state not found" -ForegroundColor Red; exit 1 }
        "gcpsm"
    }
    default { Write-Host "  Secret rotation for $platform not yet supported" -ForegroundColor Red; exit 1 }
}

$rootToken = $null
$vaultName = $null
$projectId = $null
$awsRegion = $null
if ($backendType -eq "openbao") {
    $rootToken = (Get-Content (Join-Path $BaseDir ".openbao-state.json") | ConvertFrom-Json).RootToken
} elseif ($backendType -eq "azurekv") {
    $vaultName = (Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json).VaultName
    $exitCode = Invoke-WithSpinner -Message "Prüfe Azure Login..." -Executable "az" `
        -Arguments @("account", "show")
    if ($exitCode -ne 0) {
        Write-Host "`n  Azure login erforderlich." -ForegroundColor Cyan
        & az login --use-device-code
        if ($LASTEXITCODE -ne 0) { Write-Host "  Azure login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
} elseif ($backendType -eq "awssm") {
    $awsRegion = (Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json).Region
    & aws sts get-caller-identity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  AWS not configured. Please run 'aws configure'." -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $projectId = (Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json).ProjectId
    $gcloudAccount = & gcloud config get-value account 2>$null
    if ([string]::IsNullOrWhiteSpace($gcloudAccount) -or $gcloudAccount -eq "(unset)") {
        Write-Host "`n  Google login erforderlich." -ForegroundColor Cyan
        & gcloud auth login --no-launch-browser
        if ($LASTEXITCODE -ne 0) { Write-Host "  Google login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
    & gcloud config set project $projectId 2>&1 | Out-Null
}

# ── 4. Select secret (loader with spinner) ─────────────────────
$selected = Read-SelectValue `
    -Title "Select secret" `
    -Message "Which secret should be rotated?" `
    -Options @(@{ Label = "[ Lade... ]"; Value = "" }) `
    -Default 0 `
    -ContextTitle "Secret Rotation" `
    -ContextHint "Reads SecretProviderClasses from the cluster" `
    -ContextCurrent ([ordered]@{ Cluster = $platform }) `
    -Loader {
        param($path); $env:PATH = $path
        $spcList = & kubectl get secretproviderclass -A -o json 2>$null | ConvertFrom-Json
        $items = if ($spcList -and $spcList.items) { $spcList.items } else { @() }
        if ($items.Count -eq 0) { return @(@{ Label = "[ No SecretProviderClasses found ]"; Value = "" }) }
        $items | ForEach-Object {
            @{ Label = "$($_.metadata.name)  ($($_.metadata.namespace))"; Value = "$($_.metadata.name)|$($_.metadata.namespace)" }
        } | Sort-Object { $_.Label }
    } `
    -LoadingMessage "Lade SecretProviderClasses..."

if (-not $selected) { exit 0 }

$spcName   = ($selected -split '\|')[0]
$spcNs     = ($selected -split '\|')[1]
$vaultPath = $spcName -replace '-vault$', ''   # grafana-vault → grafana

# ── 5. Aktuelles Secret lesen ────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$currentRef = [ref]$null
if ($backendType -eq "openbao") {
    Invoke-WithSpinner -Message "Reading secret from OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv get -format=json secret/$vaultPath") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "azurekv") {
    Invoke-WithSpinner -Message "Reading secret from Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "show",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--query", "value", "--output", "tsv") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "awssm") {
    Invoke-WithSpinner -Message "Reading secret from AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "get-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--query", "SecretString", "--output", "text") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "gcpsm") {
    Invoke-WithSpinner -Message "Reading secret from GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "access", "latest",
                     "--secret", $vaultPath, "--project", $projectId) `
        -OutputVariable $currentRef | Out-Null
}
if (-not ($currentRef.Value -and ($currentRef.Value -join "").Trim() -ne "")) {
    Write-Host "  Secret '$vaultPath' not found in backend." -ForegroundColor Red; exit 1
}
Write-Host "  ✓ Secret found" -ForegroundColor Green

# ── 6. Neues Passwort eingeben ───────────────────────────────────
do {
    $newPassword = Read-SecretPlainConfirm `
        -Prompt1 "Neues Passwort (min. 8 Zeichen)" `
        -Prompt2 "Passwort bestätigen" `
        -ContextTitle "Secret Rotation" `
        -ContextHint  "Aktuell: ••••••••" `
        -ContextCurrent ([ordered]@{ Secret = $spcName; Namespace = $spcNs; Cluster = $platform })
    if ($newPassword.Length -lt 8) {
        Write-Host "  Passwort muss mindestens 8 Zeichen haben." -ForegroundColor Red
    }
} while ($newPassword.Length -lt 8)

# ── 7. Secret schreiben ──────────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "  Secret:    $spcName" -ForegroundColor Gray
Write-Host "  Namespace: $spcNs" -ForegroundColor Gray
Write-Host "  Cluster:   $platform" -ForegroundColor Gray
Write-Host ""

if ($backendType -eq "openbao") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv put secret/$vaultPath adminPassword=$newPassword")
    if ($exitCode -ne 0) { Write-Host "  Error writing to OpenBao" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "azurekv") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "set",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--file", $tmpFile.FullName, "--encoding", "utf-8")
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to Azure Key Vault" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "awssm") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "put-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--secret-string", $newPassword)
    if ($exitCode -ne 0) { Write-Host "  Error writing to AWS Secrets Manager" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "add", $vaultPath,
                     "--project", $projectId, "--data-file", $tmpFile.FullName)
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to GCP Secret Manager" -ForegroundColor Red; exit 1 }
}
Write-Host "  ✓ Secret aktualisiert" -ForegroundColor Green
Write-Host ""

# ── 8. Betroffene Workloads neustarten ───────────────────────────
$restarted = @()
foreach ($kind in @("deployment", "statefulset", "daemonset")) {
    $resources = & kubectl get $kind -n $spcNs -o json 2>$null | ConvertFrom-Json
    if (-not $resources -or -not $resources.items) { continue }
    foreach ($r in $resources.items) {
        $usesSpc = $r.spec.template.spec.volumes | Where-Object {
            $_.csi -and
            $_.csi.driver -eq "secrets-store.csi.k8s.io" -and
            $_.csi.volumeAttributes.secretProviderClass -eq $spcName
        }
        if ($usesSpc) { $restarted += @{ Kind = $kind; Name = $r.metadata.name } }
    }
}

if ($restarted.Count -eq 0) {
    Write-Host "  No workloads with SPC '$spcName' in '$spcNs' found." -ForegroundColor Yellow
} else {
    foreach ($w in $restarted) {
        $exitCode = Invoke-WithSpinner -Message "Restarting $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "restart", "$($w.Kind)/$($w.Name)", "-n", $spcNs)
        if ($exitCode -ne 0) { Write-Host "  ✗ Restart failed: $($w.Kind)/$($w.Name)" -ForegroundColor Red; continue }

        $exitCode = Invoke-WithSpinner -Message "Waiting for $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "status", "$($w.Kind)/$($w.Name)", "-n", $spcNs, "--timeout=3m")
        if ($exitCode -eq 0) {
            Write-Host "  ✓ $($w.Kind)/$($w.Name) läuft mit neuem Passwort" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Rollout timeout — please check status manually" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Rotation complete" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    exit 1
}

# ── 1. Select platform ───────────────────────────────────────
$platforms = @()
if (Test-Path (Join-Path $BaseDir ".rke2-state.json"))  { $platforms += @{ Label = "RKE2 (On-Premise)";  Value = "RKE2 (On-Premise)" } }
if (Test-Path (Join-Path $BaseDir ".kind-state.json"))  { $platforms += @{ Label = "Kind (Local)";        Value = "Kind (Local)" } }
if (Test-Path (Join-Path $BaseDir ".aks-state.json"))   { $platforms += @{ Label = "Azure AKS";           Value = "Azure AKS" } }
if (Test-Path (Join-Path $BaseDir ".eks-state.json"))   { $platforms += @{ Label = "AWS EKS";             Value = "AWS EKS" } }
if (Test-Path (Join-Path $BaseDir ".gke-state.json"))   { $platforms += @{ Label = "Google GKE";          Value = "Google GKE" } }

if ($platforms.Count -eq 0) { Write-Host "  No installed clusters found." -ForegroundColor Red; exit 1 }

$platform = if ($platforms.Count -eq 1) {
    $platforms[0].Value
} else {
    Read-SelectValue `
        -Title "Select cluster" `
        -Message "On which cluster should the secret be rotated?" `
        -Options $platforms -Default 0 `
        -ContextTitle "Secret Rotation" `
        -ContextHint "Multiple installed clusters found"
}
if (-not $platform) { exit 0 }

# ── 2. Kubecontext setzen ────────────────────────────────────────
Set-ClusterContext -BaseDir $BaseDir -Platform $platform

# ── 3. Backend initialisieren ────────────────────────────────────
$backendType = switch ($platform) {
    { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
        if (-not (Test-Path (Join-Path $BaseDir ".openbao-state.json"))) {
            Write-Host "  OpenBao not installed on $platform" -ForegroundColor Red; exit 1
        }
        "openbao"
    }
    "Azure AKS" {
        $aksS = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
        if (-not $aksS.VaultName) { Write-Host "  Azure Key Vault not configured for AKS" -ForegroundColor Red; exit 1 }
        "azurekv"
    }
    "AWS EKS" {
        $eksS = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
        if (-not $eksS.Region) { Write-Host "  EKS state not found" -ForegroundColor Red; exit 1 }
        "awssm"
    }
    "Google GKE" {
        $gkeS = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
        if (-not $gkeS.ProjectId) { Write-Host "  GKE state not found" -ForegroundColor Red; exit 1 }
        "gcpsm"
    }
    default { Write-Host "  Secret rotation for $platform not yet supported" -ForegroundColor Red; exit 1 }
}

$rootToken = $null
$vaultName = $null
$projectId = $null
$awsRegion = $null
if ($backendType -eq "openbao") {
    $rootToken = (Get-Content (Join-Path $BaseDir ".openbao-state.json") | ConvertFrom-Json).RootToken
} elseif ($backendType -eq "azurekv") {
    $vaultName = (Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json).VaultName
    $exitCode = Invoke-WithSpinner -Message "Prüfe Azure Login..." -Executable "az" `
        -Arguments @("account", "show")
    if ($exitCode -ne 0) {
        Write-Host "`n  Azure login erforderlich." -ForegroundColor Cyan
        & az login --use-device-code
        if ($LASTEXITCODE -ne 0) { Write-Host "  Azure login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
} elseif ($backendType -eq "awssm") {
    $awsRegion = (Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json).Region
    & aws sts get-caller-identity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  AWS not configured. Please run 'aws configure'." -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $projectId = (Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json).ProjectId
    $gcloudAccount = & gcloud config get-value account 2>$null
    if ([string]::IsNullOrWhiteSpace($gcloudAccount) -or $gcloudAccount -eq "(unset)") {
        Write-Host "`n  Google login erforderlich." -ForegroundColor Cyan
        & gcloud auth login --no-launch-browser
        if ($LASTEXITCODE -ne 0) { Write-Host "  Google login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
    & gcloud config set project $projectId 2>&1 | Out-Null
}

# ── 4. Select secret (loader with spinner) ─────────────────────
$selected = Read-SelectValue `
    -Title "Select secret" `
    -Message "Which secret should be rotated?" `
    -Options @(@{ Label = "[ Lade... ]"; Value = "" }) `
    -Default 0 `
    -ContextTitle "Secret Rotation" `
    -ContextHint "Reads SecretProviderClasses from the cluster" `
    -ContextCurrent ([ordered]@{ Cluster = $platform }) `
    -Loader {
        param($path); $env:PATH = $path
        $spcList = & kubectl get secretproviderclass -A -o json 2>$null | ConvertFrom-Json
        $items = if ($spcList -and $spcList.items) { $spcList.items } else { @() }
        if ($items.Count -eq 0) { return @(@{ Label = "[ No SecretProviderClasses found ]"; Value = "" }) }
        $items | ForEach-Object {
            @{ Label = "$($_.metadata.name)  ($($_.metadata.namespace))"; Value = "$($_.metadata.name)|$($_.metadata.namespace)" }
        } | Sort-Object { $_.Label }
    } `
    -LoadingMessage "Lade SecretProviderClasses..."

if (-not $selected) { exit 0 }

$spcName   = ($selected -split '\|')[0]
$spcNs     = ($selected -split '\|')[1]
$vaultPath = $spcName -replace '-vault$', ''   # grafana-vault → grafana

# ── 5. Aktuelles Secret lesen ────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$currentRef = [ref]$null
if ($backendType -eq "openbao") {
    Invoke-WithSpinner -Message "Reading secret from OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv get -format=json secret/$vaultPath") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "azurekv") {
    Invoke-WithSpinner -Message "Reading secret from Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "show",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--query", "value", "--output", "tsv") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "awssm") {
    Invoke-WithSpinner -Message "Reading secret from AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "get-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--query", "SecretString", "--output", "text") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "gcpsm") {
    Invoke-WithSpinner -Message "Reading secret from GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "access", "latest",
                     "--secret", $vaultPath, "--project", $projectId) `
        -OutputVariable $currentRef | Out-Null
}
if (-not ($currentRef.Value -and ($currentRef.Value -join "").Trim() -ne "")) {
    Write-Host "  Secret '$vaultPath' not found in backend." -ForegroundColor Red; exit 1
}
Write-Host "  ✓ Secret found" -ForegroundColor Green

# ── 6. Neues Passwort eingeben ───────────────────────────────────
do {
    $newPassword = Read-SecretPlainConfirm `
        -Prompt1 "Neues Passwort (min. 8 Zeichen)" `
        -Prompt2 "Passwort bestätigen" `
        -ContextTitle "Secret Rotation" `
        -ContextHint  "Aktuell: ••••••••" `
        -ContextCurrent ([ordered]@{ Secret = $spcName; Namespace = $spcNs; Cluster = $platform })
    if ($newPassword.Length -lt 8) {
        Write-Host "  Passwort muss mindestens 8 Zeichen haben." -ForegroundColor Red
    }
} while ($newPassword.Length -lt 8)

# ── 7. Secret schreiben ──────────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "  Secret:    $spcName" -ForegroundColor Gray
Write-Host "  Namespace: $spcNs" -ForegroundColor Gray
Write-Host "  Cluster:   $platform" -ForegroundColor Gray
Write-Host ""

if ($backendType -eq "openbao") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv put secret/$vaultPath adminPassword=$newPassword")
    if ($exitCode -ne 0) { Write-Host "  Error writing to OpenBao" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "azurekv") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "set",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--file", $tmpFile.FullName, "--encoding", "utf-8")
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to Azure Key Vault" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "awssm") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "put-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--secret-string", $newPassword)
    if ($exitCode -ne 0) { Write-Host "  Error writing to AWS Secrets Manager" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "add", $vaultPath,
                     "--project", $projectId, "--data-file", $tmpFile.FullName)
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to GCP Secret Manager" -ForegroundColor Red; exit 1 }
}
Write-Host "  ✓ Secret aktualisiert" -ForegroundColor Green
Write-Host ""

# ── 8. Betroffene Workloads neustarten ───────────────────────────
$restarted = @()
foreach ($kind in @("deployment", "statefulset", "daemonset")) {
    $resources = & kubectl get $kind -n $spcNs -o json 2>$null | ConvertFrom-Json
    if (-not $resources -or -not $resources.items) { continue }
    foreach ($r in $resources.items) {
        $usesSpc = $r.spec.template.spec.volumes | Where-Object {
            $_.csi -and
            $_.csi.driver -eq "secrets-store.csi.k8s.io" -and
            $_.csi.volumeAttributes.secretProviderClass -eq $spcName
        }
        if ($usesSpc) { $restarted += @{ Kind = $kind; Name = $r.metadata.name } }
    }
}

if ($restarted.Count -eq 0) {
    Write-Host "  No workloads with SPC '$spcName' in '$spcNs' found." -ForegroundColor Yellow
} else {
    foreach ($w in $restarted) {
        $exitCode = Invoke-WithSpinner -Message "Restarting $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "restart", "$($w.Kind)/$($w.Name)", "-n", $spcNs)
        if ($exitCode -ne 0) { Write-Host "  ✗ Restart failed: $($w.Kind)/$($w.Name)" -ForegroundColor Red; continue }

        $exitCode = Invoke-WithSpinner -Message "Waiting for $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "status", "$($w.Kind)/$($w.Name)", "-n", $spcNs, "--timeout=3m")
        if ($exitCode -eq 0) {
            Write-Host "  ✓ $($w.Kind)/$($w.Name) läuft mit neuem Passwort" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Rollout timeout — please check status manually" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Rotation complete" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green



.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    exit 1
}

# ── 1. Select platform ───────────────────────────────────────
$platforms = @()
if (Test-Path (Join-Path $BaseDir ".rke2-state.json"))  { $platforms += @{ Label = "RKE2 (On-Premise)";  Value = "RKE2 (On-Premise)" } }
if (Test-Path (Join-Path $BaseDir ".kind-state.json"))  { $platforms += @{ Label = "Kind (Local)";        Value = "Kind (Local)" } }
if (Test-Path (Join-Path $BaseDir ".aks-state.json"))   { $platforms += @{ Label = "Azure AKS";           Value = "Azure AKS" } }
if (Test-Path (Join-Path $BaseDir ".eks-state.json"))   { $platforms += @{ Label = "AWS EKS";             Value = "AWS EKS" } }
if (Test-Path (Join-Path $BaseDir ".gke-state.json"))   { $platforms += @{ Label = "Google GKE";          Value = "Google GKE" } }

if ($platforms.Count -eq 0) { Write-Host "  No installed clusters found." -ForegroundColor Red; exit 1 }

$platform = if ($platforms.Count -eq 1) {
    $platforms[0].Value
} else {
    Read-SelectValue `
        -Title "Select cluster" `
        -Message "On which cluster should the secret be rotated?" `
        -Options $platforms -Default 0 `
        -ContextTitle "Secret Rotation" `
        -ContextHint "Multiple installed clusters found"
}
if (-not $platform) { exit 0 }

# ── 2. Kubecontext setzen ────────────────────────────────────────
Set-ClusterContext -BaseDir $BaseDir -Platform $platform

# ── 3. Backend initialisieren ────────────────────────────────────
$backendType = switch ($platform) {
    { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
        if (-not (Test-Path (Join-Path $BaseDir ".openbao-state.json"))) {
            Write-Host "  OpenBao not installed on $platform" -ForegroundColor Red; exit 1
        }
        "openbao"
    }
    "Azure AKS" {
        $aksS = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
        if (-not $aksS.VaultName) { Write-Host "  Azure Key Vault not configured for AKS" -ForegroundColor Red; exit 1 }
        "azurekv"
    }
    "AWS EKS" {
        $eksS = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
        if (-not $eksS.Region) { Write-Host "  EKS state not found" -ForegroundColor Red; exit 1 }
        "awssm"
    }
    "Google GKE" {
        $gkeS = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
        if (-not $gkeS.ProjectId) { Write-Host "  GKE state not found" -ForegroundColor Red; exit 1 }
        "gcpsm"
    }
    default { Write-Host "  Secret rotation for $platform not yet supported" -ForegroundColor Red; exit 1 }
}

$rootToken = $null
$vaultName = $null
$projectId = $null
$awsRegion = $null
if ($backendType -eq "openbao") {
    $rootToken = (Get-Content (Join-Path $BaseDir ".openbao-state.json") | ConvertFrom-Json).RootToken
} elseif ($backendType -eq "azurekv") {
    $vaultName = (Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json).VaultName
    $exitCode = Invoke-WithSpinner -Message "Prüfe Azure Login..." -Executable "az" `
        -Arguments @("account", "show")
    if ($exitCode -ne 0) {
        Write-Host "`n  Azure login erforderlich." -ForegroundColor Cyan
        & az login --use-device-code
        if ($LASTEXITCODE -ne 0) { Write-Host "  Azure login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
} elseif ($backendType -eq "awssm") {
    $awsRegion = (Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json).Region
    & aws sts get-caller-identity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  AWS not configured. Please run 'aws configure'." -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $projectId = (Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json).ProjectId
    $gcloudAccount = & gcloud config get-value account 2>$null
    if ([string]::IsNullOrWhiteSpace($gcloudAccount) -or $gcloudAccount -eq "(unset)") {
        Write-Host "`n  Google login erforderlich." -ForegroundColor Cyan
        & gcloud auth login --no-launch-browser
        if ($LASTEXITCODE -ne 0) { Write-Host "  Google login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
    & gcloud config set project $projectId 2>&1 | Out-Null
}

# ── 4. Select secret (loader with spinner) ─────────────────────
$selected = Read-SelectValue `
    -Title "Select secret" `
    -Message "Which secret should be rotated?" `
    -Options @(@{ Label = "[ Lade... ]"; Value = "" }) `
    -Default 0 `
    -ContextTitle "Secret Rotation" `
    -ContextHint "Reads SecretProviderClasses from the cluster" `
    -ContextCurrent ([ordered]@{ Cluster = $platform }) `
    -Loader {
        param($path); $env:PATH = $path
        $spcList = & kubectl get secretproviderclass -A -o json 2>$null | ConvertFrom-Json
        $items = if ($spcList -and $spcList.items) { $spcList.items } else { @() }
        if ($items.Count -eq 0) { return @(@{ Label = "[ No SecretProviderClasses found ]"; Value = "" }) }
        $items | ForEach-Object {
            @{ Label = "$($_.metadata.name)  ($($_.metadata.namespace))"; Value = "$($_.metadata.name)|$($_.metadata.namespace)" }
        } | Sort-Object { $_.Label }
    } `
    -LoadingMessage "Lade SecretProviderClasses..."

if (-not $selected) { exit 0 }

$spcName   = ($selected -split '\|')[0]
$spcNs     = ($selected -split '\|')[1]
$vaultPath = $spcName -replace '-vault$', ''   # grafana-vault → grafana

# ── 5. Aktuelles Secret lesen ────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$currentRef = [ref]$null
if ($backendType -eq "openbao") {
    Invoke-WithSpinner -Message "Reading secret from OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv get -format=json secret/$vaultPath") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "azurekv") {
    Invoke-WithSpinner -Message "Reading secret from Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "show",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--query", "value", "--output", "tsv") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "awssm") {
    Invoke-WithSpinner -Message "Reading secret from AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "get-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--query", "SecretString", "--output", "text") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "gcpsm") {
    Invoke-WithSpinner -Message "Reading secret from GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "access", "latest",
                     "--secret", $vaultPath, "--project", $projectId) `
        -OutputVariable $currentRef | Out-Null
}
if (-not ($currentRef.Value -and ($currentRef.Value -join "").Trim() -ne "")) {
    Write-Host "  Secret '$vaultPath' not found in backend." -ForegroundColor Red; exit 1
}
Write-Host "  ✓ Secret found" -ForegroundColor Green

# ── 6. Neues Passwort eingeben ───────────────────────────────────
do {
    $newPassword = Read-SecretPlainConfirm `
        -Prompt1 "Neues Passwort (min. 8 Zeichen)" `
        -Prompt2 "Passwort bestätigen" `
        -ContextTitle "Secret Rotation" `
        -ContextHint  "Aktuell: ••••••••" `
        -ContextCurrent ([ordered]@{ Secret = $spcName; Namespace = $spcNs; Cluster = $platform })
    if ($newPassword.Length -lt 8) {
        Write-Host "  Passwort muss mindestens 8 Zeichen haben." -ForegroundColor Red
    }
} while ($newPassword.Length -lt 8)

# ── 7. Secret schreiben ──────────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "  Secret:    $spcName" -ForegroundColor Gray
Write-Host "  Namespace: $spcNs" -ForegroundColor Gray
Write-Host "  Cluster:   $platform" -ForegroundColor Gray
Write-Host ""

if ($backendType -eq "openbao") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv put secret/$vaultPath adminPassword=$newPassword")
    if ($exitCode -ne 0) { Write-Host "  Error writing to OpenBao" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "azurekv") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "set",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--file", $tmpFile.FullName, "--encoding", "utf-8")
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to Azure Key Vault" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "awssm") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "put-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--secret-string", $newPassword)
    if ($exitCode -ne 0) { Write-Host "  Error writing to AWS Secrets Manager" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "add", $vaultPath,
                     "--project", $projectId, "--data-file", $tmpFile.FullName)
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to GCP Secret Manager" -ForegroundColor Red; exit 1 }
}
Write-Host "  ✓ Secret aktualisiert" -ForegroundColor Green
Write-Host ""

# ── 8. Betroffene Workloads neustarten ───────────────────────────
$restarted = @()
foreach ($kind in @("deployment", "statefulset", "daemonset")) {
    $resources = & kubectl get $kind -n $spcNs -o json 2>$null | ConvertFrom-Json
    if (-not $resources -or -not $resources.items) { continue }
    foreach ($r in $resources.items) {
        $usesSpc = $r.spec.template.spec.volumes | Where-Object {
            $_.csi -and
            $_.csi.driver -eq "secrets-store.csi.k8s.io" -and
            $_.csi.volumeAttributes.secretProviderClass -eq $spcName
        }
        if ($usesSpc) { $restarted += @{ Kind = $kind; Name = $r.metadata.name } }
    }
}

if ($restarted.Count -eq 0) {
    Write-Host "  No workloads with SPC '$spcName' in '$spcNs' found." -ForegroundColor Yellow
} else {
    foreach ($w in $restarted) {
        $exitCode = Invoke-WithSpinner -Message "Restarting $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "restart", "$($w.Kind)/$($w.Name)", "-n", $spcNs)
        if ($exitCode -ne 0) { Write-Host "  ✗ Restart failed: $($w.Kind)/$($w.Name)" -ForegroundColor Red; continue }

        $exitCode = Invoke-WithSpinner -Message "Waiting for $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "status", "$($w.Kind)/$($w.Name)", "-n", $spcNs, "--timeout=3m")
        if ($exitCode -eq 0) {
            Write-Host "  ✓ $($w.Kind)/$($w.Name) läuft mit neuem Passwort" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Rollout timeout — please check status manually" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Rotation complete" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    exit 1
}

# ── 1. Select platform ───────────────────────────────────────
$platforms = @()
if (Test-Path (Join-Path $BaseDir ".rke2-state.json"))  { $platforms += @{ Label = "RKE2 (On-Premise)";  Value = "RKE2 (On-Premise)" } }
if (Test-Path (Join-Path $BaseDir ".kind-state.json"))  { $platforms += @{ Label = "Kind (Local)";        Value = "Kind (Local)" } }
if (Test-Path (Join-Path $BaseDir ".aks-state.json"))   { $platforms += @{ Label = "Azure AKS";           Value = "Azure AKS" } }
if (Test-Path (Join-Path $BaseDir ".eks-state.json"))   { $platforms += @{ Label = "AWS EKS";             Value = "AWS EKS" } }
if (Test-Path (Join-Path $BaseDir ".gke-state.json"))   { $platforms += @{ Label = "Google GKE";          Value = "Google GKE" } }

if ($platforms.Count -eq 0) { Write-Host "  No installed clusters found." -ForegroundColor Red; exit 1 }

$platform = if ($platforms.Count -eq 1) {
    $platforms[0].Value
} else {
    Read-SelectValue `
        -Title "Select cluster" `
        -Message "On which cluster should the secret be rotated?" `
        -Options $platforms -Default 0 `
        -ContextTitle "Secret Rotation" `
        -ContextHint "Multiple installed clusters found"
}
if (-not $platform) { exit 0 }

# ── 2. Kubecontext setzen ────────────────────────────────────────
Set-ClusterContext -BaseDir $BaseDir -Platform $platform

# ── 3. Backend initialisieren ────────────────────────────────────
$backendType = switch ($platform) {
    { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
        if (-not (Test-Path (Join-Path $BaseDir ".openbao-state.json"))) {
            Write-Host "  OpenBao not installed on $platform" -ForegroundColor Red; exit 1
        }
        "openbao"
    }
    "Azure AKS" {
        $aksS = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
        if (-not $aksS.VaultName) { Write-Host "  Azure Key Vault not configured for AKS" -ForegroundColor Red; exit 1 }
        "azurekv"
    }
    "AWS EKS" {
        $eksS = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
        if (-not $eksS.Region) { Write-Host "  EKS state not found" -ForegroundColor Red; exit 1 }
        "awssm"
    }
    "Google GKE" {
        $gkeS = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
        if (-not $gkeS.ProjectId) { Write-Host "  GKE state not found" -ForegroundColor Red; exit 1 }
        "gcpsm"
    }
    default { Write-Host "  Secret rotation for $platform not yet supported" -ForegroundColor Red; exit 1 }
}

$rootToken = $null
$vaultName = $null
$projectId = $null
$awsRegion = $null
if ($backendType -eq "openbao") {
    $rootToken = (Get-Content (Join-Path $BaseDir ".openbao-state.json") | ConvertFrom-Json).RootToken
} elseif ($backendType -eq "azurekv") {
    $vaultName = (Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json).VaultName
    $exitCode = Invoke-WithSpinner -Message "Prüfe Azure Login..." -Executable "az" `
        -Arguments @("account", "show")
    if ($exitCode -ne 0) {
        Write-Host "`n  Azure login erforderlich." -ForegroundColor Cyan
        & az login --use-device-code
        if ($LASTEXITCODE -ne 0) { Write-Host "  Azure login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
} elseif ($backendType -eq "awssm") {
    $awsRegion = (Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json).Region
    & aws sts get-caller-identity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  AWS not configured. Please run 'aws configure'." -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $projectId = (Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json).ProjectId
    $gcloudAccount = & gcloud config get-value account 2>$null
    if ([string]::IsNullOrWhiteSpace($gcloudAccount) -or $gcloudAccount -eq "(unset)") {
        Write-Host "`n  Google login erforderlich." -ForegroundColor Cyan
        & gcloud auth login --no-launch-browser
        if ($LASTEXITCODE -ne 0) { Write-Host "  Google login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
    & gcloud config set project $projectId 2>&1 | Out-Null
}

# ── 4. Select secret (loader with spinner) ─────────────────────
$selected = Read-SelectValue `
    -Title "Select secret" `
    -Message "Which secret should be rotated?" `
    -Options @(@{ Label = "[ Lade... ]"; Value = "" }) `
    -Default 0 `
    -ContextTitle "Secret Rotation" `
    -ContextHint "Reads SecretProviderClasses from the cluster" `
    -ContextCurrent ([ordered]@{ Cluster = $platform }) `
    -Loader {
        param($path); $env:PATH = $path
        $spcList = & kubectl get secretproviderclass -A -o json 2>$null | ConvertFrom-Json
        $items = if ($spcList -and $spcList.items) { $spcList.items } else { @() }
        if ($items.Count -eq 0) { return @(@{ Label = "[ No SecretProviderClasses found ]"; Value = "" }) }
        $items | ForEach-Object {
            @{ Label = "$($_.metadata.name)  ($($_.metadata.namespace))"; Value = "$($_.metadata.name)|$($_.metadata.namespace)" }
        } | Sort-Object { $_.Label }
    } `
    -LoadingMessage "Lade SecretProviderClasses..."

if (-not $selected) { exit 0 }

$spcName   = ($selected -split '\|')[0]
$spcNs     = ($selected -split '\|')[1]
$vaultPath = $spcName -replace '-vault$', ''   # grafana-vault → grafana

# ── 5. Aktuelles Secret lesen ────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$currentRef = [ref]$null
if ($backendType -eq "openbao") {
    Invoke-WithSpinner -Message "Reading secret from OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv get -format=json secret/$vaultPath") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "azurekv") {
    Invoke-WithSpinner -Message "Reading secret from Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "show",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--query", "value", "--output", "tsv") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "awssm") {
    Invoke-WithSpinner -Message "Reading secret from AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "get-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--query", "SecretString", "--output", "text") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "gcpsm") {
    Invoke-WithSpinner -Message "Reading secret from GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "access", "latest",
                     "--secret", $vaultPath, "--project", $projectId) `
        -OutputVariable $currentRef | Out-Null
}
if (-not ($currentRef.Value -and ($currentRef.Value -join "").Trim() -ne "")) {
    Write-Host "  Secret '$vaultPath' not found in backend." -ForegroundColor Red; exit 1
}
Write-Host "  ✓ Secret found" -ForegroundColor Green

# ── 6. Neues Passwort eingeben ───────────────────────────────────
do {
    $newPassword = Read-SecretPlainConfirm `
        -Prompt1 "Neues Passwort (min. 8 Zeichen)" `
        -Prompt2 "Passwort bestätigen" `
        -ContextTitle "Secret Rotation" `
        -ContextHint  "Aktuell: ••••••••" `
        -ContextCurrent ([ordered]@{ Secret = $spcName; Namespace = $spcNs; Cluster = $platform })
    if ($newPassword.Length -lt 8) {
        Write-Host "  Passwort muss mindestens 8 Zeichen haben." -ForegroundColor Red
    }
} while ($newPassword.Length -lt 8)

# ── 7. Secret schreiben ──────────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "  Secret:    $spcName" -ForegroundColor Gray
Write-Host "  Namespace: $spcNs" -ForegroundColor Gray
Write-Host "  Cluster:   $platform" -ForegroundColor Gray
Write-Host ""

if ($backendType -eq "openbao") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv put secret/$vaultPath adminPassword=$newPassword")
    if ($exitCode -ne 0) { Write-Host "  Error writing to OpenBao" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "azurekv") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "set",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--file", $tmpFile.FullName, "--encoding", "utf-8")
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to Azure Key Vault" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "awssm") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "put-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--secret-string", $newPassword)
    if ($exitCode -ne 0) { Write-Host "  Error writing to AWS Secrets Manager" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "add", $vaultPath,
                     "--project", $projectId, "--data-file", $tmpFile.FullName)
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to GCP Secret Manager" -ForegroundColor Red; exit 1 }
}
Write-Host "  ✓ Secret aktualisiert" -ForegroundColor Green
Write-Host ""

# ── 8. Betroffene Workloads neustarten ───────────────────────────
$restarted = @()
foreach ($kind in @("deployment", "statefulset", "daemonset")) {
    $resources = & kubectl get $kind -n $spcNs -o json 2>$null | ConvertFrom-Json
    if (-not $resources -or -not $resources.items) { continue }
    foreach ($r in $resources.items) {
        $usesSpc = $r.spec.template.spec.volumes | Where-Object {
            $_.csi -and
            $_.csi.driver -eq "secrets-store.csi.k8s.io" -and
            $_.csi.volumeAttributes.secretProviderClass -eq $spcName
        }
        if ($usesSpc) { $restarted += @{ Kind = $kind; Name = $r.metadata.name } }
    }
}

if ($restarted.Count -eq 0) {
    Write-Host "  No workloads with SPC '$spcName' in '$spcNs' found." -ForegroundColor Yellow
} else {
    foreach ($w in $restarted) {
        $exitCode = Invoke-WithSpinner -Message "Restarting $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "restart", "$($w.Kind)/$($w.Name)", "-n", $spcNs)
        if ($exitCode -ne 0) { Write-Host "  ✗ Restart failed: $($w.Kind)/$($w.Name)" -ForegroundColor Red; continue }

        $exitCode = Invoke-WithSpinner -Message "Waiting for $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "status", "$($w.Kind)/$($w.Name)", "-n", $spcNs, "--timeout=3m")
        if ($exitCode -eq 0) {
            Write-Host "  ✓ $($w.Kind)/$($w.Name) läuft mit neuem Passwort" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Rollout timeout — please check status manually" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Rotation complete" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green


.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    exit 1
}

# ── 1. Select platform ───────────────────────────────────────
$platforms = @()
if (Test-Path (Join-Path $BaseDir ".rke2-state.json"))  { $platforms += @{ Label = "RKE2 (On-Premise)";  Value = "RKE2 (On-Premise)" } }
if (Test-Path (Join-Path $BaseDir ".kind-state.json"))  { $platforms += @{ Label = "Kind (Local)";        Value = "Kind (Local)" } }
if (Test-Path (Join-Path $BaseDir ".aks-state.json"))   { $platforms += @{ Label = "Azure AKS";           Value = "Azure AKS" } }
if (Test-Path (Join-Path $BaseDir ".eks-state.json"))   { $platforms += @{ Label = "AWS EKS";             Value = "AWS EKS" } }
if (Test-Path (Join-Path $BaseDir ".gke-state.json"))   { $platforms += @{ Label = "Google GKE";          Value = "Google GKE" } }

if ($platforms.Count -eq 0) { Write-Host "  No installed clusters found." -ForegroundColor Red; exit 1 }

$platform = if ($platforms.Count -eq 1) {
    $platforms[0].Value
} else {
    Read-SelectValue `
        -Title "Select cluster" `
        -Message "On which cluster should the secret be rotated?" `
        -Options $platforms -Default 0 `
        -ContextTitle "Secret Rotation" `
        -ContextHint "Multiple installed clusters found"
}
if (-not $platform) { exit 0 }

# ── 2. Kubecontext setzen ────────────────────────────────────────
Set-ClusterContext -BaseDir $BaseDir -Platform $platform

# ── 3. Backend initialisieren ────────────────────────────────────
$backendType = switch ($platform) {
    { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
        if (-not (Test-Path (Join-Path $BaseDir ".openbao-state.json"))) {
            Write-Host "  OpenBao not installed on $platform" -ForegroundColor Red; exit 1
        }
        "openbao"
    }
    "Azure AKS" {
        $aksS = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
        if (-not $aksS.VaultName) { Write-Host "  Azure Key Vault not configured for AKS" -ForegroundColor Red; exit 1 }
        "azurekv"
    }
    "AWS EKS" {
        $eksS = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
        if (-not $eksS.Region) { Write-Host "  EKS state not found" -ForegroundColor Red; exit 1 }
        "awssm"
    }
    "Google GKE" {
        $gkeS = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
        if (-not $gkeS.ProjectId) { Write-Host "  GKE state not found" -ForegroundColor Red; exit 1 }
        "gcpsm"
    }
    default { Write-Host "  Secret rotation for $platform not yet supported" -ForegroundColor Red; exit 1 }
}

$rootToken = $null
$vaultName = $null
$projectId = $null
$awsRegion = $null
if ($backendType -eq "openbao") {
    $rootToken = (Get-Content (Join-Path $BaseDir ".openbao-state.json") | ConvertFrom-Json).RootToken
} elseif ($backendType -eq "azurekv") {
    $vaultName = (Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json).VaultName
    $exitCode = Invoke-WithSpinner -Message "Prüfe Azure Login..." -Executable "az" `
        -Arguments @("account", "show")
    if ($exitCode -ne 0) {
        Write-Host "`n  Azure login erforderlich." -ForegroundColor Cyan
        & az login --use-device-code
        if ($LASTEXITCODE -ne 0) { Write-Host "  Azure login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
} elseif ($backendType -eq "awssm") {
    $awsRegion = (Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json).Region
    & aws sts get-caller-identity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  AWS not configured. Please run 'aws configure'." -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $projectId = (Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json).ProjectId
    $gcloudAccount = & gcloud config get-value account 2>$null
    if ([string]::IsNullOrWhiteSpace($gcloudAccount) -or $gcloudAccount -eq "(unset)") {
        Write-Host "`n  Google login erforderlich." -ForegroundColor Cyan
        & gcloud auth login --no-launch-browser
        if ($LASTEXITCODE -ne 0) { Write-Host "  Google login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
    & gcloud config set project $projectId 2>&1 | Out-Null
}

# ── 4. Select secret (loader with spinner) ─────────────────────
$selected = Read-SelectValue `
    -Title "Select secret" `
    -Message "Which secret should be rotated?" `
    -Options @(@{ Label = "[ Lade... ]"; Value = "" }) `
    -Default 0 `
    -ContextTitle "Secret Rotation" `
    -ContextHint "Reads SecretProviderClasses from the cluster" `
    -ContextCurrent ([ordered]@{ Cluster = $platform }) `
    -Loader {
        param($path); $env:PATH = $path
        $spcList = & kubectl get secretproviderclass -A -o json 2>$null | ConvertFrom-Json
        $items = if ($spcList -and $spcList.items) { $spcList.items } else { @() }
        if ($items.Count -eq 0) { return @(@{ Label = "[ No SecretProviderClasses found ]"; Value = "" }) }
        $items | ForEach-Object {
            @{ Label = "$($_.metadata.name)  ($($_.metadata.namespace))"; Value = "$($_.metadata.name)|$($_.metadata.namespace)" }
        } | Sort-Object { $_.Label }
    } `
    -LoadingMessage "Lade SecretProviderClasses..."

if (-not $selected) { exit 0 }

$spcName   = ($selected -split '\|')[0]
$spcNs     = ($selected -split '\|')[1]
$vaultPath = $spcName -replace '-vault$', ''   # grafana-vault → grafana

# ── 5. Aktuelles Secret lesen ────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$currentRef = [ref]$null
if ($backendType -eq "openbao") {
    Invoke-WithSpinner -Message "Reading secret from OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv get -format=json secret/$vaultPath") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "azurekv") {
    Invoke-WithSpinner -Message "Reading secret from Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "show",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--query", "value", "--output", "tsv") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "awssm") {
    Invoke-WithSpinner -Message "Reading secret from AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "get-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--query", "SecretString", "--output", "text") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "gcpsm") {
    Invoke-WithSpinner -Message "Reading secret from GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "access", "latest",
                     "--secret", $vaultPath, "--project", $projectId) `
        -OutputVariable $currentRef | Out-Null
}
if (-not ($currentRef.Value -and ($currentRef.Value -join "").Trim() -ne "")) {
    Write-Host "  Secret '$vaultPath' not found in backend." -ForegroundColor Red; exit 1
}
Write-Host "  ✓ Secret found" -ForegroundColor Green

# ── 6. Neues Passwort eingeben ───────────────────────────────────
do {
    $newPassword = Read-SecretPlainConfirm `
        -Prompt1 "Neues Passwort (min. 8 Zeichen)" `
        -Prompt2 "Passwort bestätigen" `
        -ContextTitle "Secret Rotation" `
        -ContextHint  "Aktuell: ••••••••" `
        -ContextCurrent ([ordered]@{ Secret = $spcName; Namespace = $spcNs; Cluster = $platform })
    if ($newPassword.Length -lt 8) {
        Write-Host "  Passwort muss mindestens 8 Zeichen haben." -ForegroundColor Red
    }
} while ($newPassword.Length -lt 8)

# ── 7. Secret schreiben ──────────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "  Secret:    $spcName" -ForegroundColor Gray
Write-Host "  Namespace: $spcNs" -ForegroundColor Gray
Write-Host "  Cluster:   $platform" -ForegroundColor Gray
Write-Host ""

if ($backendType -eq "openbao") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv put secret/$vaultPath adminPassword=$newPassword")
    if ($exitCode -ne 0) { Write-Host "  Error writing to OpenBao" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "azurekv") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "set",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--file", $tmpFile.FullName, "--encoding", "utf-8")
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to Azure Key Vault" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "awssm") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "put-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--secret-string", $newPassword)
    if ($exitCode -ne 0) { Write-Host "  Error writing to AWS Secrets Manager" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "add", $vaultPath,
                     "--project", $projectId, "--data-file", $tmpFile.FullName)
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to GCP Secret Manager" -ForegroundColor Red; exit 1 }
}
Write-Host "  ✓ Secret aktualisiert" -ForegroundColor Green
Write-Host ""

# ── 8. Betroffene Workloads neustarten ───────────────────────────
$restarted = @()
foreach ($kind in @("deployment", "statefulset", "daemonset")) {
    $resources = & kubectl get $kind -n $spcNs -o json 2>$null | ConvertFrom-Json
    if (-not $resources -or -not $resources.items) { continue }
    foreach ($r in $resources.items) {
        $usesSpc = $r.spec.template.spec.volumes | Where-Object {
            $_.csi -and
            $_.csi.driver -eq "secrets-store.csi.k8s.io" -and
            $_.csi.volumeAttributes.secretProviderClass -eq $spcName
        }
        if ($usesSpc) { $restarted += @{ Kind = $kind; Name = $r.metadata.name } }
    }
}

if ($restarted.Count -eq 0) {
    Write-Host "  No workloads with SPC '$spcName' in '$spcNs' found." -ForegroundColor Yellow
} else {
    foreach ($w in $restarted) {
        $exitCode = Invoke-WithSpinner -Message "Restarting $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "restart", "$($w.Kind)/$($w.Name)", "-n", $spcNs)
        if ($exitCode -ne 0) { Write-Host "  ✗ Restart failed: $($w.Kind)/$($w.Name)" -ForegroundColor Red; continue }

        $exitCode = Invoke-WithSpinner -Message "Waiting for $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "status", "$($w.Kind)/$($w.Name)", "-n", $spcNs, "--timeout=3m")
        if ($exitCode -eq 0) {
            Write-Host "  ✓ $($w.Kind)/$($w.Name) läuft mit neuem Passwort" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Rollout timeout — please check status manually" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Rotation complete" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    exit 1
}

# ── 1. Select platform ───────────────────────────────────────
$platforms = @()
if (Test-Path (Join-Path $BaseDir ".rke2-state.json"))  { $platforms += @{ Label = "RKE2 (On-Premise)";  Value = "RKE2 (On-Premise)" } }
if (Test-Path (Join-Path $BaseDir ".kind-state.json"))  { $platforms += @{ Label = "Kind (Local)";        Value = "Kind (Local)" } }
if (Test-Path (Join-Path $BaseDir ".aks-state.json"))   { $platforms += @{ Label = "Azure AKS";           Value = "Azure AKS" } }
if (Test-Path (Join-Path $BaseDir ".eks-state.json"))   { $platforms += @{ Label = "AWS EKS";             Value = "AWS EKS" } }
if (Test-Path (Join-Path $BaseDir ".gke-state.json"))   { $platforms += @{ Label = "Google GKE";          Value = "Google GKE" } }

if ($platforms.Count -eq 0) { Write-Host "  No installed clusters found." -ForegroundColor Red; exit 1 }

$platform = if ($platforms.Count -eq 1) {
    $platforms[0].Value
} else {
    Read-SelectValue `
        -Title "Select cluster" `
        -Message "On which cluster should the secret be rotated?" `
        -Options $platforms -Default 0 `
        -ContextTitle "Secret Rotation" `
        -ContextHint "Multiple installed clusters found"
}
if (-not $platform) { exit 0 }

# ── 2. Kubecontext setzen ────────────────────────────────────────
Set-ClusterContext -BaseDir $BaseDir -Platform $platform

# ── 3. Backend initialisieren ────────────────────────────────────
$backendType = switch ($platform) {
    { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
        if (-not (Test-Path (Join-Path $BaseDir ".openbao-state.json"))) {
            Write-Host "  OpenBao not installed on $platform" -ForegroundColor Red; exit 1
        }
        "openbao"
    }
    "Azure AKS" {
        $aksS = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
        if (-not $aksS.VaultName) { Write-Host "  Azure Key Vault not configured for AKS" -ForegroundColor Red; exit 1 }
        "azurekv"
    }
    "AWS EKS" {
        $eksS = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
        if (-not $eksS.Region) { Write-Host "  EKS state not found" -ForegroundColor Red; exit 1 }
        "awssm"
    }
    "Google GKE" {
        $gkeS = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
        if (-not $gkeS.ProjectId) { Write-Host "  GKE state not found" -ForegroundColor Red; exit 1 }
        "gcpsm"
    }
    default { Write-Host "  Secret rotation for $platform not yet supported" -ForegroundColor Red; exit 1 }
}

$rootToken = $null
$vaultName = $null
$projectId = $null
$awsRegion = $null
if ($backendType -eq "openbao") {
    $rootToken = (Get-Content (Join-Path $BaseDir ".openbao-state.json") | ConvertFrom-Json).RootToken
} elseif ($backendType -eq "azurekv") {
    $vaultName = (Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json).VaultName
    $exitCode = Invoke-WithSpinner -Message "Prüfe Azure Login..." -Executable "az" `
        -Arguments @("account", "show")
    if ($exitCode -ne 0) {
        Write-Host "`n  Azure login erforderlich." -ForegroundColor Cyan
        & az login --use-device-code
        if ($LASTEXITCODE -ne 0) { Write-Host "  Azure login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
} elseif ($backendType -eq "awssm") {
    $awsRegion = (Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json).Region
    & aws sts get-caller-identity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  AWS not configured. Please run 'aws configure'." -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $projectId = (Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json).ProjectId
    $gcloudAccount = & gcloud config get-value account 2>$null
    if ([string]::IsNullOrWhiteSpace($gcloudAccount) -or $gcloudAccount -eq "(unset)") {
        Write-Host "`n  Google login erforderlich." -ForegroundColor Cyan
        & gcloud auth login --no-launch-browser
        if ($LASTEXITCODE -ne 0) { Write-Host "  Google login fehlgeschlagen." -ForegroundColor Red; exit 1 }
    }
    & gcloud config set project $projectId 2>&1 | Out-Null
}

# ── 4. Select secret (loader with spinner) ─────────────────────
$selected = Read-SelectValue `
    -Title "Select secret" `
    -Message "Which secret should be rotated?" `
    -Options @(@{ Label = "[ Lade... ]"; Value = "" }) `
    -Default 0 `
    -ContextTitle "Secret Rotation" `
    -ContextHint "Reads SecretProviderClasses from the cluster" `
    -ContextCurrent ([ordered]@{ Cluster = $platform }) `
    -Loader {
        param($path); $env:PATH = $path
        $spcList = & kubectl get secretproviderclass -A -o json 2>$null | ConvertFrom-Json
        $items = if ($spcList -and $spcList.items) { $spcList.items } else { @() }
        if ($items.Count -eq 0) { return @(@{ Label = "[ No SecretProviderClasses found ]"; Value = "" }) }
        $items | ForEach-Object {
            @{ Label = "$($_.metadata.name)  ($($_.metadata.namespace))"; Value = "$($_.metadata.name)|$($_.metadata.namespace)" }
        } | Sort-Object { $_.Label }
    } `
    -LoadingMessage "Lade SecretProviderClasses..."

if (-not $selected) { exit 0 }

$spcName   = ($selected -split '\|')[0]
$spcNs     = ($selected -split '\|')[1]
$vaultPath = $spcName -replace '-vault$', ''   # grafana-vault → grafana

# ── 5. Aktuelles Secret lesen ────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$currentRef = [ref]$null
if ($backendType -eq "openbao") {
    Invoke-WithSpinner -Message "Reading secret from OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv get -format=json secret/$vaultPath") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "azurekv") {
    Invoke-WithSpinner -Message "Reading secret from Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "show",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--query", "value", "--output", "tsv") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "awssm") {
    Invoke-WithSpinner -Message "Reading secret from AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "get-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--query", "SecretString", "--output", "text") `
        -OutputVariable $currentRef | Out-Null
} elseif ($backendType -eq "gcpsm") {
    Invoke-WithSpinner -Message "Reading secret from GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "access", "latest",
                     "--secret", $vaultPath, "--project", $projectId) `
        -OutputVariable $currentRef | Out-Null
}
if (-not ($currentRef.Value -and ($currentRef.Value -join "").Trim() -ne "")) {
    Write-Host "  Secret '$vaultPath' not found in backend." -ForegroundColor Red; exit 1
}
Write-Host "  ✓ Secret found" -ForegroundColor Green

# ── 6. Neues Passwort eingeben ───────────────────────────────────
do {
    $newPassword = Read-SecretPlainConfirm `
        -Prompt1 "Neues Passwort (min. 8 Zeichen)" `
        -Prompt2 "Passwort bestätigen" `
        -ContextTitle "Secret Rotation" `
        -ContextHint  "Aktuell: ••••••••" `
        -ContextCurrent ([ordered]@{ Secret = $spcName; Namespace = $spcNs; Cluster = $platform })
    if ($newPassword.Length -lt 8) {
        Write-Host "  Passwort muss mindestens 8 Zeichen haben." -ForegroundColor Red
    }
} while ($newPassword.Length -lt 8)

# ── 7. Secret schreiben ──────────────────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Secret Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "  Secret:    $spcName" -ForegroundColor Gray
Write-Host "  Namespace: $spcNs" -ForegroundColor Gray
Write-Host "  Cluster:   $platform" -ForegroundColor Gray
Write-Host ""

if ($backendType -eq "openbao") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", "openbao", "--",
                     "sh", "-c", "BAO_TOKEN=$rootToken bao kv put secret/$vaultPath adminPassword=$newPassword")
    if ($exitCode -ne 0) { Write-Host "  Error writing to OpenBao" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "azurekv") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to Azure Key Vault..." -Executable "az" `
        -Arguments @("keyvault", "secret", "set",
                     "--vault-name", $vaultName, "--name", $vaultPath,
                     "--file", $tmpFile.FullName, "--encoding", "utf-8")
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to Azure Key Vault" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "awssm") {
    $exitCode = Invoke-WithSpinner -Message "Writing secret to AWS Secrets Manager..." -Executable "aws" `
        -Arguments @("secretsmanager", "put-secret-value",
                     "--secret-id", $vaultPath, "--region", $awsRegion,
                     "--secret-string", $newPassword)
    if ($exitCode -ne 0) { Write-Host "  Error writing to AWS Secrets Manager" -ForegroundColor Red; exit 1 }
} elseif ($backendType -eq "gcpsm") {
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile.FullName -Value $newPassword -Encoding UTF8 -NoNewline
    $exitCode = Invoke-WithSpinner -Message "Writing secret to GCP Secret Manager..." -Executable "gcloud" `
        -Arguments @("secrets", "versions", "add", $vaultPath,
                     "--project", $projectId, "--data-file", $tmpFile.FullName)
    Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Host "  Error writing to GCP Secret Manager" -ForegroundColor Red; exit 1 }
}
Write-Host "  ✓ Secret aktualisiert" -ForegroundColor Green
Write-Host ""

# ── 8. Betroffene Workloads neustarten ───────────────────────────
$restarted = @()
foreach ($kind in @("deployment", "statefulset", "daemonset")) {
    $resources = & kubectl get $kind -n $spcNs -o json 2>$null | ConvertFrom-Json
    if (-not $resources -or -not $resources.items) { continue }
    foreach ($r in $resources.items) {
        $usesSpc = $r.spec.template.spec.volumes | Where-Object {
            $_.csi -and
            $_.csi.driver -eq "secrets-store.csi.k8s.io" -and
            $_.csi.volumeAttributes.secretProviderClass -eq $spcName
        }
        if ($usesSpc) { $restarted += @{ Kind = $kind; Name = $r.metadata.name } }
    }
}

if ($restarted.Count -eq 0) {
    Write-Host "  No workloads with SPC '$spcName' in '$spcNs' found." -ForegroundColor Yellow
} else {
    foreach ($w in $restarted) {
        $exitCode = Invoke-WithSpinner -Message "Restarting $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "restart", "$($w.Kind)/$($w.Name)", "-n", $spcNs)
        if ($exitCode -ne 0) { Write-Host "  ✗ Restart failed: $($w.Kind)/$($w.Name)" -ForegroundColor Red; continue }

        $exitCode = Invoke-WithSpinner -Message "Waiting for $($w.Kind)/$($w.Name)..." -Executable "kubectl" `
            -Arguments @("rollout", "status", "$($w.Kind)/$($w.Name)", "-n", $spcNs, "--timeout=3m")
        if ($exitCode -eq 0) {
            Write-Host "  ✓ $($w.Kind)/$($w.Name) läuft mit neuem Passwort" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Rollout timeout — please check status manually" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Rotation complete" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green




