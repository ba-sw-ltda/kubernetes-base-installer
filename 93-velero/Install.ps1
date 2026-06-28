<#
.SYNOPSIS
    Install Velero for cluster backup (resources + CSI volume snapshots).
.DESCRIPTION
    Fully wired on RKE2/Kind: backs onto an in-cluster MinIO instance
    (92-minio, installed automatically here — not separately selectable),
    uses Velero's built-in CSI support (v1.14+) with snapshot data movement
    so backups actually leave the cluster rather than staying as
    storage-local snapshots, and a VolumeSnapshotClass wired to Longhorn's
    CSI driver.
    Cloud platforms (AKS/EKS/GKE) are not yet wired up — same "documented
    roadmap gap, not silently guessed" treatment already used for EKS's
    ingress/cert-manager setup. Their native object storage (S3/Blob/GCS)
    would replace MinIO as the backup target; CSI snapshot support there
    typically pre-exists, so the integration is mostly a backupStorageLocation
    config swap, not new infrastructure.
.PARAMETER Platform
    Target platform
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER Schedule
    Cron expression for the recurring backup (from Prompt.ps1)
.PARAMETER RetentionDays
    Days completed backups are retained before Velero deletes them (from Prompt.ps1)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$ConfigPath,
    [string]$Schedule      = "",
    [int]$RetentionDays    = 0
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1"       -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

# Standalone: prompt if not provided
if ([string]::IsNullOrWhiteSpace($Schedule)) {
    $inputs = & "$ScriptRoot\Prompt.ps1" -Platform $Platform
    if (-not $inputs) { Write-Host "  Skipped — no backup schedule configured." -ForegroundColor Gray; exit 0 }
    $Schedule      = $inputs.Schedule
    $RetentionDays = $inputs.RetentionDays
}

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 93 - Velero (Backup)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if ($Platform -notin @("RKE2 (On-Premise)", "Kind (Local)")) {
    Write-Host "  Velero is not yet wired up for $Platform." -ForegroundColor Yellow
    Write-Host "  RKE2/Kind back onto an in-cluster MinIO instance; $Platform would" -ForegroundColor Gray
    Write-Host "  instead use its native object storage (S3/Blob/GCS) as the backup" -ForegroundColor Gray
    Write-Host "  target — not implemented yet. Tracked as a roadmap item, same as" -ForegroundColor Gray
    Write-Host "  EKS's ingress/cert-manager gap." -ForegroundColor Gray
    exit 0
}

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName       = $FullConfig.ChartName
$ChartVersion    = $FullConfig.Version
$Repository      = $FullConfig.Repository
$Namespace       = $FullConfig.Namespace
$CreateNamespace = $FullConfig.CreateNamespace
$UserConfig      = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Schedule:   $Schedule  |  Retention: $RetentionDays day(s)" -ForegroundColor Gray
Write-Host ""

# ── MinIO — Velero's backup target on RKE2/Kind, dispatched directly the
# same way 51-rancher dispatches to 51-rancher-agent ──
& "$BaseDir\92-minio\Install.ps1" -Platform $Platform
if ($LASTEXITCODE -ne 0) { Write-Error "MinIO setup failed — aborting Velero install"; exit 1 }

$minioCred = Get-ClusterSecret -Path "minio/velero-credential" -Keys @("accessKey", "secretKey") -BaseDir $BaseDir -Platform $Platform
if (-not $minioCred -or -not $minioCred["accessKey"]) { Write-Error "Could not read Velero's MinIO credential from Vault"; exit 1 }
$minioEndpoint = "http://minio.minio.svc.cluster.local:9000"
$minioBucket   = "velero-backups"

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "velero", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

if ($CreateNamespace) {
    & kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
    Write-Host "  ✓ Namespace ready" -ForegroundColor Green
}

# ── CSI VolumeSnapshot prerequisite — vanilla RKE2/Kind ship no
# external-snapshotter CRDs/controller at all (unlike most managed cloud
# clusters, which bundle one for their native CSI driver). Installed once per
# cluster; idempotent check so re-running this script doesn't reapply needlessly. ──
$snapshotCrdExists = & kubectl get crd volumesnapshotclasses.snapshot.storage.k8s.io --ignore-not-found 2>$null
if (-not $snapshotCrdExists) {
    $snapVersion = $UserConfig.SnapshotterVersion
    Write-Host "  Installing VolumeSnapshot CRDs..." -ForegroundColor Gray
    & kubectl kustomize "https://github.com/kubernetes-csi/external-snapshotter/client/config/crd?ref=$snapVersion" 2>&1 |
        & kubectl apply --server-side --force-conflicts -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to install VolumeSnapshot CRDs"; exit 1 }
    Write-Host "  ✓ VolumeSnapshot CRDs installed" -ForegroundColor Green

    & kubectl kustomize "https://github.com/kubernetes-csi/external-snapshotter/deploy/kubernetes/snapshot-controller?ref=$snapVersion" 2>&1 |
        & kubectl apply -n kube-system -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to install the snapshot-controller"; exit 1 }
    Write-Host "  ✓ snapshot-controller installed" -ForegroundColor Green

    $exitCode = Invoke-WithSpinner -Message "Waiting for snapshot-controller..." -Executable "kubectl" `
        -Arguments @("rollout", "status", "deployment/snapshot-controller", "-n", "kube-system", "--timeout=3m") `
        -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "snapshot-controller rollout did not complete"; exit 1 }
    Write-Host "  ✓ snapshot-controller ready" -ForegroundColor Green
} else {
    Write-Host "  ✓ VolumeSnapshot CRDs already present" -ForegroundColor Green
}

# velero.io/csi-volumesnapshot-class label is required — it's how Velero's
# built-in CSI support picks the right VolumeSnapshotClass for a given driver
# (confirmed against vmware-tanzu/velero-plugin-for-csi's docs).
$vscYaml = @"
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapshot
  labels:
    velero.io/csi-volumesnapshot-class: "true"
driver: driver.longhorn.io
deletionPolicy: Delete
"@
$vscYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create the Longhorn VolumeSnapshotClass"; exit 1 }
Write-Host "  ✓ VolumeSnapshotClass ready (driver.longhorn.io)" -ForegroundColor Green

# ── Credentials file for the aws plugin — written to a temp file only for
# the duration of the Helm call (--set-file needs a real path), then removed ──
$credsFile = Join-Path $env:TEMP "velero-credentials-$([Guid]::NewGuid().ToString('N').Substring(0,8)).tmp"
Set-Content -Path $credsFile -Value @"
[default]
aws_access_key_id=$($minioCred["accessKey"])
aws_secret_access_key=$($minioCred["secretKey"])
"@ -NoNewline

Reset-StuckHelmRelease -ReleaseName "velero" -Namespace $Namespace

try {
    $HelmArgs = @(
        "upgrade", "--install", "velero", "velero/$ChartName",
        "--namespace", $Namespace,
        "--version", $ChartVersion,
        "--set-file", "credentials.secretContents.cloud=$($credsFile.Replace('\', '/'))",
        "--set", "configuration.backupStorageLocation[0].name=default",
        "--set", "configuration.backupStorageLocation[0].provider=aws",
        "--set", "configuration.backupStorageLocation[0].bucket=$minioBucket",
        "--set", "configuration.backupStorageLocation[0].config.region=minio",
        "--set", "configuration.backupStorageLocation[0].config.s3Url=$minioEndpoint",
        "--set", "configuration.backupStorageLocation[0].config.s3ForcePathStyle=true",
        "--set", "configuration.features=EnableCSI",
        # snapshotsEnabled controls whether the chart creates a
        # VolumeSnapshotLocation object for the legacy native-snapshot
        # provider plugins (aws/azure/gcp) — not used here. The CSI plugin
        # (built into core Velero since v1.14) snapshots via VolumeSnapshot
        # objects directly and needs no VSL; leaving this true makes the
        # chart create an empty VSL with no provider, which the API rejects
        # outright (confirmed live: "spec.provider: Required value").
        "--set", "snapshotsEnabled=false",
        "--set", "deployNodeAgent=true",
        "--set", "initContainers[0].name=velero-plugin-for-aws",
        "--set", "initContainers[0].image=$($UserConfig.PluginImage)",
        "--set", "initContainers[0].volumeMounts[0].mountPath=/target",
        "--set", "initContainers[0].volumeMounts[0].name=plugins",
        "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
        "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
        "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
        "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)"
    )

    $exitCode = Invoke-WithSpinner -Message "Deploying Velero..." -Executable "helm" `
        -Arguments $HelmArgs -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Failed to deploy Velero (exit code $exitCode)"; exit 1 }
    Write-Host "  ✓ Deployed" -ForegroundColor Green
} finally {
    Remove-Item $credsFile -Force -ErrorAction SilentlyContinue
}

$exitCode = Invoke-WithSpinner -Message "Waiting for Velero..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/velero", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout did not complete — check cluster state"; exit 1 }
Write-Host "  ✓ Velero ready" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for node-agent..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "daemonset/node-agent", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "node-agent rollout did not complete"; exit 1 }
Write-Host "  ✓ node-agent ready" -ForegroundColor Green

# ── Recurring backup schedule ──
$ttlHours = $RetentionDays * 24
$scheduleYaml = @"
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: default-backup
  namespace: $Namespace
spec:
  schedule: "$Schedule"
  template:
    ttl: "${ttlHours}h0m0s"
    snapshotMoveData: true
    storageLocation: default
    excludedNamespaces:
    - kube-system
    - kube-public
    - kube-node-lease
"@
$scheduleYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create the backup Schedule"; exit 1 }
Write-Host "  ✓ Backup schedule created ($Schedule, ${RetentionDays}d retention)" -ForegroundColor Green

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace
}

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Trigger a backup now:" -ForegroundColor Gray
Write-Host "    velero backup create manual-$(Get-Date -Format yyyyMMdd) --snapshot-move-data" -ForegroundColor Yellow
Write-Host "  Check status:" -ForegroundColor Gray
Write-Host "    velero backup get" -ForegroundColor Yellow
Write-Host "    velero schedule get" -ForegroundColor Yellow
Write-Host "  Restore:" -ForegroundColor Gray
Write-Host "    velero restore create --from-backup <backup-name>" -ForegroundColor Yellow
Write-Host "  Backup target: MinIO, bucket '$minioBucket' (Vault: minio/root-credential, minio/velero-credential)" -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
