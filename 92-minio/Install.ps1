<#
.SYNOPSIS
    Install MinIO as the in-cluster S3-compatible backup target for Velero.
.DESCRIPTION
    RKE2/Kind only — cloud platforms back Velero with their own native object
    storage (S3/Blob/GCS) instead, wired directly in 93-velero/Install.ps1.
    Not a user-selectable component: dispatched directly from
    93-velero/Install.ps1, the same way 51-rancher dispatches to
    51-rancher-agent. Still its own Config/Install pair so it can be re-run
    standalone for debugging.
.PARAMETER Platform
    Target platform
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$ConfigPath
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1"       -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

if ($Platform -notin @("RKE2 (On-Premise)", "Kind (Local)")) {
    Write-Host "  Skipped — MinIO is only used as Velero's backup target on RKE2/Kind." -ForegroundColor Gray
    exit 0
}

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 92 - MinIO" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName       = $FullConfig.ChartName
$ChartVersion    = $FullConfig.Version
$Repository      = $FullConfig.Repository
$Namespace       = $FullConfig.Namespace
$CreateNamespace = $FullConfig.CreateNamespace
$UserConfig      = $FullConfig.UserConfig
$BucketName      = $UserConfig.BucketName

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Bucket:     $BucketName" -ForegroundColor Gray
Write-Host ""

# ── Credentials — generate once, persist in Vault, reuse on re-install ──
# Root creds: full MinIO admin access, used only by this script to provision
# the scoped Velero user below — never handed to Velero itself.
$root = Get-ClusterSecret -Path "minio/root-credential" -Keys @("user", "password") -BaseDir $BaseDir -Platform $Platform
if ($root -and $root["user"] -and $root["password"]) {
    $rootUser     = $root["user"]
    $rootPassword = $root["password"]
} else {
    $rootUser     = "minioadmin"
    $rootPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    Write-ClusterSecret -Path "minio/root-credential" -BaseDir $BaseDir -Platform $Platform -Data @{
        user     = $rootUser
        password = $rootPassword
    } | Out-Null
}

# Velero's own scoped credential — least-privilege, restricted to just the
# backup bucket below, never the root account (see Vault least-privilege
# convention used everywhere else in this repo).
$veleroCred = Get-ClusterSecret -Path "minio/velero-credential" -Keys @("accessKey", "secretKey") -BaseDir $BaseDir -Platform $Platform
if ($veleroCred -and $veleroCred["accessKey"] -and $veleroCred["secretKey"]) {
    $veleroAccessKey = $veleroCred["accessKey"]
    $veleroSecretKey = $veleroCred["secretKey"]
} else {
    $veleroAccessKey = "velero-" + (-join ((97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ }))
    $veleroSecretKey = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 40 | ForEach-Object { [char]$_ })
    Write-ClusterSecret -Path "minio/velero-credential" -BaseDir $BaseDir -Platform $Platform -Data @{
        accessKey = $veleroAccessKey
        secretKey = $veleroSecretKey
    } | Out-Null
}

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "minio", $Repository, "--force-update") -ShowOutput:$verbose
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

# Pre-flight: if the MinIO pod is not Running, clean up stale Longhorn attachment
# state that blocks a Longhorn volume from leaving creating/attaching/faulted state.
# Also deletes the PVC when the volume has never held data so a fresh (correctly
# sized) PVC is provisioned by Helm on the next install.
$minioPodPhaseRaw = & kubectl get pods -n $Namespace -l "app=minio" -o jsonpath='{.items[0].status.phase}' 2>$null
$minioPodPhase = if ($minioPodPhaseRaw) { $minioPodPhaseRaw.Trim() } else { "" }
if ($minioPodPhase -ne 'Running') {
    $minioPvc = try { & kubectl get pvc minio -n $Namespace -o json 2>$null | ConvertFrom-Json } catch { $null }
    if ($minioPvc) {
        $pvName = $minioPvc.spec.volumeName
        if ($pvName) {
            $lhSnapshots = try {
                (& kubectl get snapshot.longhorn.io -n longhorn-system -o json 2>$null | ConvertFrom-Json).items |
                    Where-Object { $_.spec.volume -eq $pvName -and $_.status.readyToUse -eq $false }
            } catch { @() }
            foreach ($snap in @($lhSnapshots)) {
                Write-Host "  ⚠ Removing stuck Longhorn Snapshot '$($snap.metadata.name)'..." -ForegroundColor Yellow
                & kubectl delete snapshot.longhorn.io $snap.metadata.name -n longhorn-system 2>$null | Out-Null
            }

            & kubectl get volumeattachment.longhorn.io $pvName -n longhorn-system 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ⚠ Removing stuck Longhorn VolumeAttachment for '$pvName'..." -ForegroundColor Yellow
                & kubectl delete volumeattachment.longhorn.io $pvName -n longhorn-system 2>$null | Out-Null
            }

            $allVas = try { (& kubectl get volumeattachment -o json 2>$null | ConvertFrom-Json).items } catch { @() }
            foreach ($va in @($allVas | Where-Object { $_.spec.source.persistentVolumeName -eq $pvName })) {
                Write-Host "  ⚠ Removing stuck K8s VolumeAttachment for '$pvName'..." -ForegroundColor Yellow
                & kubectl delete volumeattachment $va.metadata.name 2>$null | Out-Null
            }

            $lhVol = try { & kubectl get volume.longhorn.io $pvName -n longhorn-system -o json 2>$null | ConvertFrom-Json } catch { $null }
            if ($lhVol) {
                $actualSize     = [long]($lhVol.status.actualSize -replace '[^0-9]', '')
                $lastDegradedAt = $lhVol.status.lastDegradedAt
                $volState       = $lhVol.status.state
                if ($actualSize -eq 0 -and (-not $lastDegradedAt -or $lastDegradedAt -eq '') -and
                    $volState -in @('creating', 'attaching', 'detached', 'faulted')) {
                    Write-Host "  ⚠ Longhorn volume '$pvName' has never held data (state=$volState) — deleting PVC for fresh provisioning..." -ForegroundColor Yellow
                    & kubectl delete pvc minio -n $Namespace 2>$null | Out-Null
                    Start-Sleep -Seconds 5
                }
            }
        }
    }
}

Reset-StuckHelmRelease -ReleaseName "minio" -Namespace $Namespace

# Override chart defaults: clear users/buckets/policies so no post-install hook job
# is created. The chart ships with a default console user that triggers the hook even
# when no explicit provisioning args are passed. We do our own provisioning via mc below.
$tempMinioValues = Join-Path $env:TEMP "minio-override-values.yaml"
Set-Content -Path $tempMinioValues -Encoding UTF8 -Value @"
users: []
buckets: []
policies: []
svcaccts: []
"@

$HelmArgs = @(
    "upgrade", "--install", "minio", "minio/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "mode=standalone",
    "--set", "rootUser=$rootUser",
    "--set", "rootPassword=$rootPassword",
    "--set", "persistence.enabled=true",
    "--set", "persistence.size=$($UserConfig.StorageSize)",
    "--set", "resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    "--set", "service.type=ClusterIP",
    "--set", "consoleService.type=ClusterIP",
    "--values", $tempMinioValues
)
if ($UserConfig.StorageClass) {
    $HelmArgs += "--set", "persistence.storageClass=$($UserConfig.StorageClass)"
}

$exitCode = Invoke-WithSpinner -Message "Deploying MinIO..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
Remove-Item $tempMinioValues -Force -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { Write-Error "Failed to deploy MinIO (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for rollout..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/minio", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout did not complete — check cluster state"; exit 1 }
Write-Host "  ✓ Rollout complete" -ForegroundColor Green

# ── Scoped Velero user + bucket-restricted policy — throwaway pod runs mc,
# the tool's own CLI, same idiom as Get-HtpasswdHash/Get-AutheliaSecretHash ──
$policyJson = "{`"Version`":`"2012-10-17`",`"Statement`":[{`"Effect`":`"Allow`",`"Action`":[`"s3:*`"],`"Resource`":[`"arn:aws:s3:::$BucketName`",`"arn:aws:s3:::$BucketName/*`"]}]}"
$mcScript = "mc alias set target http://minio.$Namespace.svc.cluster.local:9000 $rootUser $rootPassword >/dev/null && " +
    "mc mb --ignore-existing target/$BucketName && " +
    "echo '$policyJson' > /tmp/velero-policy.json && " +
    "mc admin policy create target velero-policy /tmp/velero-policy.json && " +
    "mc admin user add target $veleroAccessKey $veleroSecretKey && " +
    "mc admin policy attach target velero-policy --user $veleroAccessKey"

$podName = "minio-mc-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
& kubectl run $podName -n $Namespace --rm -i --restart=Never --quiet `
    --image=minio/mc:latest --command -- sh -c $mcScript 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
if ($LASTEXITCODE -ne 0) {
    Write-Warning "  ⚠ Could not provision the scoped Velero MinIO user — check manually with 'mc admin user list'"
} else {
    Write-Host "  ✓ Velero user scoped to bucket '$BucketName'" -ForegroundColor Green
}

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Endpoint (in-cluster):  http://minio.$Namespace.svc.cluster.local:9000" -ForegroundColor Yellow
Write-Host "  Bucket:                 $BucketName" -ForegroundColor Yellow
Write-Host "  Root credentials:       Vault secret 'minio/root-credential'" -ForegroundColor Gray
Write-Host "  Velero credentials:     Vault secret 'minio/velero-credential'" -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
