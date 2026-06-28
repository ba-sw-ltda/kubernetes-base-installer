<#
.SYNOPSIS
    Sets up GCP Secret Manager as the cluster secrets backend via the
    Secret Manager CSI driver and Workload Identity.
    Creates a shared GSA (Google Service Account) for CSI access used by all apps.
.PARAMETER Platform
    Target platform (must be "Google GKE")
#>
[CmdletBinding()]
param([string]$Platform)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose    = $VerbosePreference -eq 'Continue'
$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform
$UserConfig = $FullConfig.UserConfig

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 33 - GCP Secret Manager" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── Load GKE state ───────────────────────────────────────────────
$gkeStatePath = Join-Path $BaseDir ".gke-state.json"
if (-not (Test-Path $gkeStatePath)) { Write-Error "No .gke-state.json found — run GKE cluster setup first"; exit 1 }
$gkeState   = Get-Content $gkeStatePath | ConvertFrom-Json
$projectId  = $gkeState.ProjectId
$clusterName = $gkeState.ClusterName
$zone        = $gkeState.Zone

if ([string]::IsNullOrWhiteSpace($projectId))   { Write-Error "ProjectId missing in .gke-state.json";  exit 1 }
if ([string]::IsNullOrWhiteSpace($clusterName)) { Write-Error "ClusterName missing in .gke-state.json"; exit 1 }
if ([string]::IsNullOrWhiteSpace($zone))        { Write-Error "Zone missing in .gke-state.json";        exit 1 }

Write-Host "  Project:  $projectId" -ForegroundColor Gray
Write-Host "  Cluster:  $clusterName" -ForegroundColor Gray
Write-Host "  Zone:     $zone" -ForegroundColor Gray
Write-Host ""

# ── 1. APIs aktivieren ───────────────────────────────────────────
foreach ($api in @("secretmanager.googleapis.com", "container.googleapis.com")) {
    $enabled = & gcloud services list --project $projectId --filter "name:$api" --format "value(name)" 2>$null
    if ($enabled) {
        Write-Host "  ✓ $api already enabled" -ForegroundColor Green
    } else {
        $exitCode = Invoke-WithSpinner -Message "Enabling $api..." -Executable "gcloud" `
            -Arguments @("services", "enable", $api, "--project", $projectId) -ShowOutput:$verbose
        if ($exitCode -ne 0) { Write-Error "Failed to enable $api"; exit 1 }
        Write-Host "  ✓ $api enabled" -ForegroundColor Green
    }
}

# ── 2. Workload Identity am Cluster aktivieren ───────────────────
$wiEnabled = & gcloud container clusters describe $clusterName --zone $zone --project $projectId `
    --format "value(workloadIdentityConfig.workloadPool)" 2>$null
if ($wiEnabled) {
    Write-Host "  ✓ Workload Identity already enabled" -ForegroundColor Green
} else {
    $exitCode = Invoke-WithSpinner -Message "Enabling Workload Identity..." -Executable "gcloud" `
        -Arguments @("container", "clusters", "update", $clusterName,
            "--zone", $zone, "--project", $projectId,
            "--workload-pool=$projectId.svc.id.goog") -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Failed to enable Workload Identity"; exit 1 }
    Write-Host "  ✓ Workload Identity enabled" -ForegroundColor Green
}

# Nodepool auf GKE_METADATA umstellen — Pflicht damit Workload Identity in Pods funktioniert
$exitCode = Invoke-WithSpinner -Message "Configuring nodepool for GKE Metadata Server..." -Executable "gcloud" `
    -Arguments @("container", "node-pools", "update", "default-pool",
        "--cluster", $clusterName, "--zone", $zone, "--project", $projectId,
        "--workload-metadata=GKE_METADATA") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update nodepool workload metadata"; exit 1 }
Write-Host "  ✓ Nodepool configured for Workload Identity" -ForegroundColor Green

# ── 3. Shared CSI Google Service Account ─────────────────────────
$gsaName    = "$clusterName-csi-sa"
$gsaEmail   = "$gsaName@$projectId.iam.gserviceaccount.com"
$gsaExists  = & gcloud iam service-accounts describe $gsaEmail --project $projectId 2>$null
if ($gsaExists) {
    Write-Host "  ✓ CSI Service Account already exists" -ForegroundColor Green
} else {
    $exitCode = Invoke-WithSpinner -Message "Creating CSI Service Account..." -Executable "gcloud" `
        -Arguments @("iam", "service-accounts", "create", $gsaName,
            "--project", $projectId,
            "--display-name", "$clusterName CSI Secret Manager SA") -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Failed to create Service Account"; exit 1 }
    Write-Host "  ✓ CSI Service Account created" -ForegroundColor Green
}

# ── 4. Secret Manager Viewer Rolle zuweisen ──────────────────────
$exitCode = Invoke-WithSpinner -Message "Assigning Secret Manager Viewer role..." -Executable "gcloud" `
    -Arguments @("projects", "add-iam-policy-binding", $projectId,
        "--member", "serviceAccount:$gsaEmail",
        "--role", "roles/secretmanager.secretAccessor",
        "--condition=None") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to assign secretmanager.secretAccessor role to $gsaEmail"; exit 1 }
Write-Host "  ✓ roles/secretmanager.secretAccessor assigned to $gsaEmail" -ForegroundColor Green

# ── 5. GCP Secret Manager CSI Provider installieren ─────────────
# Official installation method: kubectl apply with the manifest from GitHub.
$providerUrl = "https://raw.githubusercontent.com/GoogleCloudPlatform/secrets-store-csi-driver-provider-gcp/main/deploy/provider-gcp-plugin.yaml"
$exitCode = Invoke-WithSpinner -Message "Installing GCP Secret Manager CSI Provider..." -Executable "kubectl" `
    -Arguments @("apply", "-f", $providerUrl) -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to install GCP Secret Manager CSI Provider"; exit 1 }
Write-Host "  ✓ GCP Secret Manager CSI Provider installed" -ForegroundColor Green

# ── 6. State speichern ───────────────────────────────────────────
$gkeStateData = Get-Content $gkeStatePath | ConvertFrom-Json -AsHashtable
$gkeStateData['CsiGsaEmail'] = $gsaEmail
$gkeStateData['CsiGsaName']  = $gsaName
$gkeStateData['WorkloadPool'] = "$projectId.svc.id.goog"
$gkeStateData | ConvertTo-Json | Set-Content -Path $gkeStatePath -Encoding UTF8
Write-Host "  ✓ State saved" -ForegroundColor Green

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $FullConfig.Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  CSI GSA:      $gsaEmail" -ForegroundColor Yellow
Write-Host "  Workload Pool: $projectId.svc.id.goog" -ForegroundColor Gray
Write-Host "  Auth:         Workload Identity per Pod" -ForegroundColor Gray
Write-Host "  Secrets:      mounted as files (no etcd)" -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
