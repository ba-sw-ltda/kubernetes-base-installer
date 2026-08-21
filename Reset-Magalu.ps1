<#
.SYNOPSIS
    Deletes the Magalu Cloud Kubernetes cluster created by Install-Base.ps1.
.DESCRIPTION
    Magalu has no cloud-native Vault/Secrets-Manager integration wired up yet
    (see project notes), so there are no project-level resources to clean up
    beyond the cluster itself — unlike Reset-EKS.ps1/Reset-GKE.ps1. Managed
    PostgreSQL is explicitly out of scope for this repo and was never created
    by Install-Base.ps1, so this script never touches it either.
#>
[CmdletBinding()]
param()

$BaseDir   = $PSScriptRoot
$stateFile = Join-Path $BaseDir ".magalu-state.json"

if (-not (Test-Path $stateFile)) {
    Write-Error "No Magalu state file found at $stateFile. Nothing to reset."
    exit 1
}

$state = Get-Content $stateFile | ConvertFrom-Json
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

# Removes .magalu-state.json only if it still describes the cluster this
# script tore down. Guards against a race with a concurrent Install-Base.ps1
# run: both scripts read/write the same fixed-path state file with no
# cluster-identity check, so if a new cluster was created (and its state
# written) while this teardown was in flight, an unconditional Remove-Item
# here would wipe out live state for a cluster that's still running — this
# actually happened (2026-08-17). Only delete the file if nothing else has
# claimed it since.
function Remove-StateFileIfUnchanged {
    param([string]$StateFile, [string]$ExpectedClusterName)
    $current = if (Test-Path $StateFile) { try { Get-Content $StateFile -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $null } } else { $null }
    if (-not $current -or $current.ClusterName -eq $ExpectedClusterName) {
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Write-Host "  ✓ State file removed" -ForegroundColor Green
    } else {
        Write-Host "  ⚠ State file now describes a different cluster ('$($current.ClusterName)') — left untouched (a new cluster was likely created while this teardown was running)." -ForegroundColor Yellow
    }
}

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  Magalu Cloud Teardown" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow
Write-Host "  Cluster: $($state.ClusterName)" -ForegroundColor Gray
Write-Host "  Region:  $($state.Region)" -ForegroundColor Gray
Write-Host "  Domain:  $($state.Domain)" -ForegroundColor Gray
Write-Host "  Created: $($state.CreatedAt)" -ForegroundColor Gray
Write-Host ""

$confirm = Read-Host "  Type 'yes' to delete cluster '$($state.ClusterName)'"
if ($confirm -ne "yes") { Write-Host "  Aborted." -ForegroundColor Yellow; exit 0 }

# ── 1. Login check ───────────────────────────────────────────────
$exitCode = Invoke-WithSpinner -Message "Checking Magalu Cloud login..." -Executable "mgc" `
    -Arguments @("auth", "access-token", "-r")
if ($exitCode -ne 0) {
    do {
        Write-Host "`n  Magalu Cloud login required — a browser window will open." -ForegroundColor Cyan
        Write-Host ""
        & mgc auth login
    } while ($LASTEXITCODE -ne 0 -and (Confirm-RetryOrExit -Reason "Magalu Cloud login failed"))
}

# ── 2. Resolve cluster UUID ──────────────────────────────────────
# `mgc kubernetes cluster delete` only accepts --cluster-id (a UUID), not the
# cluster name. Newer state files capture ClusterId directly at creation
# time (Install-Base.ps1) — use it straight away, no lookup or name-matching
# needed. Older state files (written before this field existed) fall back to
# resolving it by listing clusters and matching on name, same ANSI-strip /
# first-brace JSON technique as the Install-Base.ps1 Magalu Loaders and
# Get-MagaluClusterId in powershell-cluster-bootstrap (mgc still emits ANSI
# escapes and spinner frames under -o json). Either way, `cluster list` is
# still fetched to confirm the cluster (by ID or name) actually still exists.
$raw = & mgc kubernetes cluster list --region $state.Region -o json 2>&1
$joined = (($raw -join "`n") -replace "`e\[[0-9;]*m", "")
$jsonStart = -1
foreach ($ch in @('{', '[')) {
    $i = $joined.IndexOf($ch)
    if ($i -ge 0 -and ($jsonStart -lt 0 -or $i -lt $jsonStart)) { $jsonStart = $i }
}
$parsed = if ($jsonStart -ge 0) { try { $joined.Substring($jsonStart) | ConvertFrom-Json -ErrorAction Stop } catch { $null } } else { $null }

$clusterId = $state.ClusterId
if ($clusterId) {
    if (-not ($parsed.results | Where-Object { $_.id -eq $clusterId })) { $clusterId = $null }
} else {
    $clusterId = ($parsed.results | Where-Object { $_.name -eq $state.ClusterName } | Select-Object -First 1).id
}

if (-not $clusterId) {
    Write-Host "  Cluster '$($state.ClusterName)' not found in region '$($state.Region)' — already deleted?" -ForegroundColor Yellow
    Remove-StateFileIfUnchanged -StateFile $stateFile -ExpectedClusterName $state.ClusterName
    exit 0
}

# ── 2b. Capture orphan-risk PV volume IDs before the cluster dies ────────
# Deleting the whole cluster (including its API server) means the CSI driver
# (block.csi.magalu.cloud) never gets a chance to react to PVC deletion — the
# underlying block-storage volumes are simply abandoned and keep billing
# forever unless deleted explicitly. So: read every PV's volumeHandle now,
# while the API server (and thus kubectl) is still alive, and delete those
# volumes ourselves after the cluster is confirmed gone. Best-effort — if
# kubectl can't reach the cluster (already half-dead, credentials stale,
# etc.) this just warns and skips, rather than aborting the whole teardown;
# the volumes will still show up in `mgc block-storage volumes list` for
# manual cleanup.
$orphanVolumeIds = @()
try {
    Set-ClusterContext -BaseDir $BaseDir -Platform "Magalu Cloud"
    $pvOutput = Invoke-ScriptBlockWithSpinner -Message "Checking for PersistentVolumes to clean up..." -ScriptBlock {
        param($path, $kubeconfig)
        $env:PATH = $path
        if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }
        & kubectl get pv -o json 2>$null
    } -ArgumentList @($env:PATH, $env:KUBECONFIG)
    $pvJson = ($pvOutput | Select-Object -SkipLast 1) -join "`n"
    $pvs    = try { $pvJson | ConvertFrom-Json -ErrorAction Stop } catch { $null }
    $orphanVolumeIds = @($pvs.items |
        Where-Object { $_.spec.csi.driver -eq "block.csi.magalu.cloud" } |
        ForEach-Object { $_.spec.csi.volumeHandle } |
        Where-Object { $_ })
    if ($orphanVolumeIds.Count -gt 0) {
        Write-Host "  Found $($orphanVolumeIds.Count) block-storage volume(s) backing this cluster's PVCs — will delete after cluster teardown." -ForegroundColor Gray
    }
} catch {
    Write-Warning "  ⚠ Could not read PersistentVolumes before teardown ($_) — check 'mgc block-storage volumes list --region $($state.Region)' manually afterwards for orphaned volumes."
}

# ── 3. Delete cluster ────────────────────────────────────────────
# `mgc kubernetes cluster delete` returns as soon as the API *accepts* the
# request, not when the cluster is actually gone — Magalu tears it down
# asynchronously and it keeps showing up in `cluster list` for several more
# minutes. Wait-MagaluClusterDeleted polls until it's really gone before
# printing success, so this script doesn't lie about the cluster being dead
# while it's still visibly sitting in the Magalu console.
$exitCode = Invoke-WithSpinner `
    -Message "Deleting Magalu cluster '$($state.ClusterName)'..." `
    -Executable "mgc" `
    -Arguments @("kubernetes", "cluster", "delete", "--cluster-id", $clusterId, "--region", $state.Region, "--no-confirm")
if ($exitCode -ne 0) { Write-Error "Failed to delete Magalu cluster '$($state.ClusterName)'"; exit 1 }

if (Wait-MagaluClusterDeleted -Region $state.Region -ClusterName $state.ClusterName) {
    Write-Host "  ✓ Magalu cluster deleted" -ForegroundColor Green
} else {
    Write-Warning "  ⚠ Cluster '$($state.ClusterName)' still shows up in 'cluster list' after the wait timeout — it may still be tearing down in the background. Check the Magalu console."
}

# ── 3b. Delete orphaned block-storage volumes ─────────────────────
# Tolerate individual failures (a volume may already be gone, still
# mid-detach, etc.) — report and move on rather than aborting, since the
# cluster itself is already gone at this point.
if ($orphanVolumeIds.Count -gt 0) {
    Write-Host ""
    foreach ($volId in $orphanVolumeIds) {
        $exitCode = Invoke-WithSpinner -Message "Deleting orphaned volume $volId..." -Executable "mgc" `
            -Arguments @("block-storage", "volumes", "delete", "--id", $volId, "--region", $state.Region, "--no-confirm")
        if ($exitCode -eq 0) {
            Write-Host "  ✓ Volume $volId deleted" -ForegroundColor Green
        } else {
            Write-Warning "  ⚠ Could not delete volume $volId — check 'mgc block-storage volumes list --region $($state.Region)' manually."
        }
    }
}

# ── 3c. Sweep for any other orphaned volumes ──────────────────────
# Step 2b/3b only catches volumes it managed to read from `kubectl get pv`
# *before* the cluster died — if that read fails (kubectl already
# unreachable, this script gets interrupted, a previous cluster was deleted
# out-of-band via the Magalu console, etc.), those volumes are never
# captured and are left behind permanently despite this script having run.
# Confirmed live 2026-08-21: exactly this happened — 7 volumes (80GiB)
# predating the current cluster were found still sitting in state
# "available". This second, account-wide sweep is the general safety net:
# it deletes every unattached volume in the region regardless of which
# teardown (or lack of one) orphaned it, so drift never has to be found and
# cleaned up by hand again — see [[feedback_no_manual_intervention]].
Write-Host ""
Write-Host "--- Orphaned-volume sweep ---" -ForegroundColor Magenta
Remove-MagaluOrphanedVolumes -Region $state.Region | Out-Null

# ── 4. Remove OpenBao unseal/root-token state ──────────────────────
# A recreated cluster gets a brand-new OpenBao instance — these unseal keys
# and root token describe the one that just got deleted. Leaving this file
# behind makes 33-openbao/Install.ps1 think the new instance is already
# initialized and try to unseal it with credentials that no longer apply to
# anything. Same reasoning/pattern as Reset-RKE2.ps1's equivalent cleanup.
Write-Host ""
Write-Host "--- OpenBao state ---" -ForegroundColor Magenta
Remove-Item (Get-OpenBaoStateFile -BaseDir $BaseDir -Platform "Magalu Cloud") -Force -ErrorAction SilentlyContinue
Write-Host "  ✓ OpenBao state file removed" -ForegroundColor Green

# ── 5. Clean up hosts file entries for this cluster's domain ────────
# Update-HostsFile (used by Install-Base.ps1) rewrites existing hostname
# lines in place, so this isn't strictly required for a same-named recreate
# — but until that next run happens, these entries point at a LoadBalancer
# IP that's now gone, and if the recreated cluster ever gets a different
# domain/hostnames, these would otherwise sit here orphaned forever. Same
# domain-match approach as Reset-Local.ps1, but scoped to just the hosts
# file (no DNS-adapter reset — that's an Acrylic/Kind-local concern only).
Write-Host "`n--- Hosts file ---" -ForegroundColor Magenta
$hostsFile     = "C:\Windows\System32\drivers\etc\hosts"
$hostsLines    = if (Test-Path $hostsFile) { Get-Content $hostsFile -Encoding UTF8 } else { @() }
$hostsFiltered = $hostsLines | Where-Object { $_ -notmatch [regex]::Escape($state.Domain) }
$hostsChanged  = $hostsFiltered.Count -lt $hostsLines.Count

if ($hostsChanged) {
    $tempFile   = Join-Path $env:TEMP "magalu-hosts-clean.txt"
    $tempScript = Join-Path $env:TEMP "magalu-hosts-reset-elevated.ps1"
    $tempLog    = Join-Path $env:TEMP "magalu-hosts-reset-elevated.log"
    Set-Content -Path $tempFile -Value $hostsFiltered -Encoding UTF8

    $scriptLines = @(
        "`$ErrorActionPreference = 'Stop'"
        "try {"
        "  Copy-Item -Path '$tempFile' -Destination '$hostsFile' -Force"
        "  exit 0"
        "} catch {"
        "  `$_ | Out-File '$tempLog' -Encoding UTF8"
        "  exit 1"
        "}"
    )
    Set-Content -Path $tempScript -Value ($scriptLines -join "`n") -Encoding UTF8

    $proc = Start-Process pwsh -Verb RunAs `
        -ArgumentList "-NonInteractive", "-File", "`"$tempScript`"" `
        -Wait -PassThru
    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    Remove-Item $tempFile   -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -eq 0) {
        Remove-Item $tempLog -Force -ErrorAction SilentlyContinue
        Write-Host "  ✓ Removed $($hostsLines.Count - $hostsFiltered.Count) line(s) containing '$($state.Domain)' from hosts" -ForegroundColor Green
    } else {
        $errMsg = if (Test-Path $tempLog) { Get-Content $tempLog -Raw; Remove-Item $tempLog -Force } else { "(no details)" }
        Write-Warning "  Elevated hosts-file update failed: $errMsg"
    }
} else {
    Write-Host "  ✓ hosts file unchanged (no entries for '$($state.Domain)')" -ForegroundColor Green
}

# ── 6. Remove state file ─────────────────────────────────────────
Write-Host ""
Remove-StateFileIfUnchanged -StateFile $stateFile -ExpectedClusterName $state.ClusterName
Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  Magalu Cloud Teardown Complete" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow

exit 0
