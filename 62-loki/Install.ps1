<#
.SYNOPSIS
    Install Loki (log aggregation backend)
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
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 62 - Loki" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName    = $FullConfig.ChartName
$ChartVersion = $FullConfig.Version
$Repository   = $FullConfig.Repository
$Namespace    = $FullConfig.Namespace
$UserConfig   = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Mode:       $($UserConfig.DeploymentMode)" -ForegroundColor Gray
Write-Host "  Retention:  $($UserConfig.Retention)" -ForegroundColor Gray
Write-Host "  Storage:    $($UserConfig.StorageSize)" -ForegroundColor Gray
Write-Host ""

Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false

Reset-StuckHelmRelease -ReleaseName "loki" -Namespace $Namespace

# Pre-flight: if the Loki pod is not Running, clean up stale attachment state that
# blocks Longhorn from advancing a volume out of creating/attaching state.
# Layers cleaned up (in order):
#   1. Longhorn Snapshot CRs with readyToUse=false  (block engine lifecycle transitions)
#   2. Longhorn VolumeAttachment CRD in longhorn-system  (blocks volume state machine)
#   3. K8s cluster-scoped VolumeAttachment (blocks CSI attacher)
# If the Longhorn volume has actualSize=0 and lastDegradedAt="" the volume has never
# held data, so we also delete the PVC so the StatefulSet can provision a fresh volume.
$lokiPhase = (& kubectl get pod loki-0 -n $Namespace -o jsonpath='{.status.phase}' 2>$null).Trim()
if ($lokiPhase -ne 'Running') {
    $lokiPvcs = try { (& kubectl get pvc -n $Namespace -o json 2>$null | ConvertFrom-Json).items } catch { @() }
    foreach ($pvc in @($lokiPvcs | Where-Object { $_.metadata.name -match '^storage-loki-' })) {
        $pvName = $pvc.spec.volumeName
        if (-not $pvName) { continue }
        $pvcName = $pvc.metadata.name

        # 1. Longhorn Snapshot CRs with readyToUse=false
        $lhSnapshots = try {
            (& kubectl get snapshot.longhorn.io -n longhorn-system -o json 2>$null | ConvertFrom-Json).items |
                Where-Object { $_.spec.volume -eq $pvName -and $_.status.readyToUse -eq $false }
        } catch { @() }
        foreach ($snap in @($lhSnapshots)) {
            Write-Host "  ⚠ Removing stuck Longhorn Snapshot '$($snap.metadata.name)' for PV '$pvName'..." -ForegroundColor Yellow
            & kubectl delete snapshot.longhorn.io $snap.metadata.name -n longhorn-system 2>$null | Out-Null
        }

        # 2. Longhorn VolumeAttachment CRD in longhorn-system
        & kubectl get volumeattachment.longhorn.io $pvName -n longhorn-system 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ⚠ Removing stuck Longhorn VolumeAttachment for PV '$pvName'..." -ForegroundColor Yellow
            & kubectl delete volumeattachment.longhorn.io $pvName -n longhorn-system 2>$null | Out-Null
        }

        # 3. K8s cluster-scoped VolumeAttachments
        $allVas = try { (& kubectl get volumeattachment -o json 2>$null | ConvertFrom-Json).items } catch { @() }
        foreach ($va in @($allVas | Where-Object { $_.spec.source.persistentVolumeName -eq $pvName })) {
            Write-Host "  ⚠ Removing stuck K8s VolumeAttachment for PV '$pvName' (was on $($va.spec.nodeName))..." -ForegroundColor Yellow
            & kubectl delete volumeattachment $va.metadata.name 2>$null | Out-Null
        }

        # 4. If the Longhorn volume has never held data, delete the PVC so the
        #    StatefulSet controller provisions a clean replacement volume.
        $lhVol = try { & kubectl get volume.longhorn.io $pvName -n longhorn-system -o json 2>$null | ConvertFrom-Json } catch { $null }
        if ($lhVol) {
            $actualSize    = [long]($lhVol.status.actualSize -replace '[^0-9]', '')
            $lastDegradedAt = $lhVol.status.lastDegradedAt
            $volState       = $lhVol.status.state
            if ($actualSize -eq 0 -and (-not $lastDegradedAt -or $lastDegradedAt -eq '') -and
                $volState -in @('creating', 'attaching', 'detached')) {
                Write-Host "  ⚠ Longhorn volume '$pvName' has never held data (actualSize=0, state=$volState)." -ForegroundColor Yellow
                Write-Host "    Deleting PVC '$pvcName' so the StatefulSet can provision a fresh volume..." -ForegroundColor Yellow
                & kubectl delete pvc $pvcName -n $Namespace 2>$null | Out-Null
                # Give K8s a moment to recreate the PVC before Helm install proceeds
                Start-Sleep -Seconds 5
            }
        }
    }
}

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "grafana", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

# Pull proxy Secret via Reflector if proxy-config exists
& kubectl get secret proxy-config -n proxy-config 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    $reflectedSecret = @"
apiVersion: v1
kind: Secret
metadata:
  name: proxy-config
  namespace: $Namespace
  annotations:
    reflector.v1.k8s.emberstack.com/reflects: "proxy-config/proxy-config"
type: Opaque
"@
    $reflectedSecret | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Proxy Secret reflected into $Namespace" -ForegroundColor Green
    }
}

$isSingleBinary = $UserConfig.DeploymentMode -eq "SingleBinary"

$HelmArgs = @(
    "upgrade", "--install", "--force", "loki", "grafana/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "deploymentMode=$($UserConfig.DeploymentMode)",
    "--set", "loki.auth_enabled=$($UserConfig.AuthEnabled.ToString().ToLower())",
    "--set", "loki.commonConfig.replication_factor=$($UserConfig.ReplicationFactor)",
    "--set", "loki.storage.type=$($UserConfig.StorageType)",
    "--set", "loki.compactor.retention_enabled=true",
    "--set", "loki.compactor.delete_request_store=$($UserConfig.StorageType)",
    "--set", "loki.limits_config.retention_period=$($UserConfig.Retention)",
    "--set", "loki.schemaConfig.configs[0].from=2024-04-01",
    "--set", "loki.schemaConfig.configs[0].store=tsdb",
    "--set", "loki.schemaConfig.configs[0].object_store=$($UserConfig.StorageType)",
    "--set", "loki.schemaConfig.configs[0].schema=v13",
    "--set", "loki.schemaConfig.configs[0].index.prefix=loki_index_",
    "--set", "loki.schemaConfig.configs[0].index.period=24h",
    "--set", "singleBinary.replicas=$(if ($isSingleBinary) { 1 } else { 0 })",
    "--set", "singleBinary.persistence.enabled=true",
    "--set", "singleBinary.persistence.size=$($UserConfig.StorageSize)",
    "--set", "singleBinary.resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "singleBinary.resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "singleBinary.resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "singleBinary.resources.requests.memory=$($UserConfig.Resources.Requests.Memory)",
    "--set", "backend.replicas=$(if ($isSingleBinary) { 0 } else { 1 })",
    "--set", "read.replicas=$(if ($isSingleBinary) { 0 } else { 1 })",
    "--set", "write.replicas=$(if ($isSingleBinary) { 0 } else { 1 })",
    "--set", "chunksCache.enabled=$($UserConfig.ChunksCacheEnabled.ToString().ToLower())",
    "--set", "resultsCache.enabled=$($UserConfig.ResultsCacheEnabled.ToString().ToLower())",
    "--set", "test.enabled=false",
    "--set", "lokiCanary.enabled=false",
    "--set", "gateway.enabled=$($UserConfig.GatewayEnabled.ToString().ToLower())"
)

$exitCode = Invoke-WithSpinner -Message "Deploying Loki..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Loki (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

if ($isSingleBinary) {
    $exitCode = Invoke-WithSpinner -Message "Waiting for loki (up to 10m)..." -Executable "kubectl" `
        -Arguments @("rollout", "status", "statefulset/loki", "-n", $Namespace, "--timeout=10m") `
        -ShowOutput:$verbose
    if ($exitCode -ne 0) {
        Write-Host ""
        Write-Host "  ── Pod status ──────────────────────────────" -ForegroundColor DarkGray
        & kubectl get pods -n $Namespace -l "app.kubernetes.io/name=loki" 2>&1 | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
        Write-Host "  ── Recent events ───────────────────────────" -ForegroundColor DarkGray
        & kubectl get events -n $Namespace --sort-by='.lastTimestamp' --field-selector type=Warning 2>&1 | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" }
        Write-Error "Rollout of Loki did not complete"
        exit 1
    }
} else {
    foreach ($sts in @("loki-backend", "loki-write")) {
        $exitCode = Invoke-WithSpinner -Message "Waiting for $sts..." -Executable "kubectl" `
            -Arguments @("rollout", "status", "statefulset/$sts", "-n", $Namespace, "--timeout=10m") `
            -ShowOutput:$verbose
        if ($exitCode -ne 0) { Write-Error "Rollout of $sts did not complete"; exit 1 }
    }
    $exitCode = Invoke-WithSpinner -Message "Waiting for loki-read..." -Executable "kubectl" `
        -Arguments @("rollout", "status", "deployment/loki-read", "-n", $Namespace, "--timeout=10m") `
        -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Rollout of loki-read did not complete"; exit 1 }
}
Write-Host "  ✓ Loki ready" -ForegroundColor Green

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
Write-Host "  Service (cluster-internal):" -ForegroundColor Gray
Write-Host "    http://loki.${Namespace}:3100" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Grafana datasource URL:" -ForegroundColor Gray
Write-Host "    http://loki.${Namespace}:3100" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
