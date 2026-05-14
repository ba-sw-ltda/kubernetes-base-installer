<#
.SYNOPSIS
    Deletes the GKE cluster and optionally GCP project-level resources created by Install-Base.ps1.
    GCP Secret Manager secrets and the CSI Service Account survive cluster deletion
    and must be explicitly removed if no longer needed.
#>
[CmdletBinding()]
param()

$stateFile = Join-Path $PSScriptRoot ".gke-state.json"

if (-not (Test-Path $stateFile)) {
    Write-Error "No GKE state file found at $stateFile. Nothing to reset."
    exit 1
}

$state = Get-Content $stateFile | ConvertFrom-Json
Import-Module "$PSScriptRoot\_lib\Installer.Ui.psm1" -Force -Verbose:$false

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  GKE Teardown" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow
Write-Host "  Cluster: $($state.ClusterName)" -ForegroundColor Gray
Write-Host "  Project: $($state.ProjectId)" -ForegroundColor Gray
Write-Host "  Zone:    $($state.Zone)" -ForegroundColor Gray
Write-Host "  Created: $($state.CreatedAt)" -ForegroundColor Gray
Write-Host ""

$confirm = Read-Host "  Type 'yes' to delete cluster '$($state.ClusterName)'"
if ($confirm -ne "yes") { Write-Host "  Aborted." -ForegroundColor Yellow; exit 0 }

$account = (& gcloud config get-value account 2>&1).Trim()
if ($account -eq "(unset)" -or [string]::IsNullOrWhiteSpace($account)) {
    Write-Host "  Google Cloud not authenticated. Run 'gcloud auth login' first." -ForegroundColor Red
    exit 1
}

& gcloud config set project $state.ProjectId 2>&1 | Out-Null

# ── 1. Delete cluster ───────────────────────────────────────────
$exitCode = Invoke-WithSpinner `
    -Message "Deleting GKE cluster '$($state.ClusterName)' (5-10 min)..." `
    -Executable "gcloud" `
    -Arguments @("container", "clusters", "delete", $state.ClusterName,
                 "--zone", $state.Zone, "--project", $state.ProjectId, "--quiet")
if ($exitCode -ne 0) { Write-Error "Failed to delete GKE cluster '$($state.ClusterName)'"; exit 1 }
Write-Host "  ✓ GKE cluster deleted" -ForegroundColor Green

# ── 2. Delete CSI service account? ──────────────────────────────
# The CSI SA is a project-level resource — it survives cluster deletion.
# It can be reused if a new cluster is created in the same project.
if ($state.CsiGsaName) {
    $deleteSa = Read-YesNo `
        -Title "CSI Service Account '$($state.CsiGsaName)'" `
        -Message "Delete as well?" `
        -DefaultYes $false `
        -YesLabel "Yes — delete service account from project" `
        -NoLabel  "No — keep (reusable for a new cluster in the same project)" `
        -ContextTitle "GKE Teardown" `
        -ContextCurrent ([ordered]@{ Project = $state.ProjectId; SA = $state.CsiGsaEmail })
    if ($deleteSa) {
        $exitCode = Invoke-WithSpinner -Message "Deleting Service Account '$($state.CsiGsaName)'..." `
            -Executable "gcloud" `
            -Arguments @("iam", "service-accounts", "delete", $state.CsiGsaEmail,
                         "--project", $state.ProjectId, "--quiet")
        if ($exitCode -eq 0) { Write-Host "  ✓ CSI Service Account deleted" -ForegroundColor Green }
        else { Write-Warning "  Service Account delete failed — delete manually if needed" }
    } else {
        Write-Host "  ✓ CSI Service Account erhalten" -ForegroundColor Green
    }
}

# ── 3. GCP Secret Manager Secrets ────────────────────────────────
$secretNames = & gcloud secrets list --project $state.ProjectId --format "value(name)" 2>$null
$secretList  = if ($secretNames) { @($secretNames -split "`n" | Where-Object { $_ }) } else { @() }

if ($secretList.Count -gt 0) {
    Write-Host ""
    Write-Host "  GCP Secret Manager Secrets im Projekt:" -ForegroundColor DarkGray
    $secretList | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGray }

    $deleteSecrets = Read-YesNo `
        -Title "$($secretList.Count) secret(s) found in project" `
        -Message "Delete as well?" `
        -DefaultYes $false `
        -YesLabel "Yes — delete all secrets in project" `
        -NoLabel  "No — keep (can be reused for a new cluster)" `
        -ContextTitle "GKE Teardown" `
        -ContextCurrent ([ordered]@{ Project = $state.ProjectId; Secrets = $secretList.Count })
    if ($deleteSecrets) {
        foreach ($secret in $secretList) {
            $exitCode = Invoke-WithSpinner -Message "Deleting secret '$secret'..." -Executable "gcloud" `
                -Arguments @("secrets", "delete", $secret,
                             "--project", $state.ProjectId, "--quiet")
            if ($exitCode -eq 0) { Write-Host "  ✓ Secret '$secret' gelöscht" -ForegroundColor Green }
            else { Write-Warning "  Secret '$secret' delete failed — delete manually if needed" }
        }
    } else {
        Write-Host "  ✓ Secrets erhalten" -ForegroundColor Green
    }
} else {
    Write-Host ""
    Write-Host "  No GCP Secret Manager secrets found in project." -ForegroundColor DarkGray
}

# ── 4. Remove state file ────────────────────────────────────────
Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "  ✓ State file removed" -ForegroundColor Green
Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  GKE Teardown Complete" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow

exit 0

