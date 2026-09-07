<#
.SYNOPSIS
    Install OpenBao (open-source Vault fork) with auto-unseal.
    Runs fully unattended — init, unseal, and Kubernetes-auth are configured
    automatically. Unseal key + root token are saved to a per-platform state
    file (.openbao-state-rke2.json / .openbao-state-kind.json — see
    Get-OpenBaoStateFile; never shared between platforms, since the same
    BaseDir checkout is routinely used against both)
    AND to a Kubernetes Secret so the unsealer pod can recover after restarts.
.PARAMETER Platform
    Target platform
.PARAMETER Hostname
    DNS hostname for the OpenBao UI ingress (from Prompt.ps1)
.PARAMETER Domain
    Cluster base domain (from Prompt.ps1) — used as allowed_domains for PKI
    roles that issue ingress certificates.
.PARAMETER PKIs
    Array of PKI definitions from Prompt.ps1. Each entry is a hashtable with:
      Name, MountPath, Type (Root|Intermediate), Roles[], IsDefault, Status,
      and optionally ParentType, ParentMountPath, mTlsTtlHours.
    If empty/omitted, a single "ingress" Root CA is created for backward compat.
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER HAEnabled
    Enable High Availability (Raft integrated storage, 3 replicas) instead of
    single-node file storage (from Prompt.ps1). Switching modes on an
    existing install has no in-place migration — see the mode-switch wipe
    logic below.
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Hostname,
    [string]$Domain,
    [array] $PKIs = @(),
    [string]$ConfigPath,
    [bool]  $HAEnabled = $false
)

$HAReplicas = 3

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1"       -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1"  -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 33 - OpenBao" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig  = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath
$ChartVersion = $FullConfig.Version
$Repository   = $FullConfig.Repository
$Namespace    = $FullConfig.Namespace
$UserConfig   = $FullConfig.UserConfig
$StateFile    = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform

# ── Storage-mode switch detection ────────────────────────────────
# OpenBao/Vault has no in-place migration between "file" and "raft"
# storage — this is a deliberate fresh-reinit design (user-confirmed
# 2026-09-06: full reinstalls are already routine practice on every
# platform, including the persistent RKE2 cluster). "Mode" is persisted
# in the same state JSON Save-OpenBaoPkis already read-merges into, so no
# separate state file is needed.
$requestedMode = if ($HAEnabled) { "ha" } else { "standalone" }
$previousMode  = $null
if (Test-Path $StateFile) {
    $existingState = Get-Content $StateFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($existingState) {
        # Pre-HA state files predate the Mode field — every install before
        # this feature was standalone-only, so its absence here safely
        # means "standalone", not "unknown"/skip.
        $previousMode = if ($existingState.Mode) { $existingState.Mode } else { "standalone" }
    }
}
$modeSwitch = (-not [string]::IsNullOrWhiteSpace($previousMode)) -and ($previousMode -ne $requestedMode)

Write-Host "  Chart:      openbao v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Mode:       $requestedMode$(if ($HAEnabled) { " ($HAReplicas replicas)" })" -ForegroundColor Gray
Write-Host "  Storage:    $($UserConfig.StorageSize)" -ForegroundColor Gray
if ($PKIs.Count -gt 0) {
    Write-Host "  PKIs:       $($PKIs.Count) defined ($( ($PKIs | ForEach-Object { $_.Name }) -join ', '))" -ForegroundColor Gray
}
Write-Host ""

Start-Group -Title "Preparation"

# ── 1. Helm install ──────────────────────────────────────────────
$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "openbao", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }

& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null

# StatefulSet spec is immutable — delete it before upgrade so Helm can recreate with new spec.
# The PVC is preserved (no --cascade=foreground), data survives the upgrade.
$stsExists = & kubectl get statefulset openbao -n $Namespace 2>$null
if ($stsExists) {
    $exitCode = Invoke-WithSpinner -Message "Removing old StatefulSet for upgrade (PVC preserved)..." -Executable "kubectl" `
        -Arguments @("delete", "statefulset", "openbao", "-n", $Namespace, "--cascade=orphan")
    if ($exitCode -ne 0) { Write-Warning "  Could not delete StatefulSet — upgrade may fail" }
}

# Storage-mode switch (standalone <-> ha): no in-place migration exists, so
# force a fresh reinit — wipe PVC(s), the unseal-key Secret, and the state
# file, then fall through to the normal "not yet initialized" path below.
# PVC names come from the chart's volumeClaimTemplate and aren't hardcoded
# here — discovered live, same dynamic-lookup approach Reset-RKE2.ps1
# already uses for the same PVCs during a full teardown.
if ($modeSwitch) {
    # The user already made this call and saw its consequences at Prompt.ps1
    # time (see the HA toggle's ContextHint there) — nothing can be done in
    # reaction to it here, since every input runs upfront and Install.ps1
    # never prompts mid-run. This just reports what's happening, so it's a
    # plain status line rather than an alarming runtime warning.
    Write-GroupLine "ℹ Storage mode changing ($previousMode → $requestedMode) — wiping existing data for a fresh reinit (no in-place migration)" -ForegroundColor Yellow

    & kubectl delete pods -n $Namespace --all --force --grace-period=0 --request-timeout=10s 2>$null | Out-Null

    $obaoPvcLines = & kubectl get pvc -n $Namespace --no-headers --request-timeout=5s 2>$null
    foreach ($line in @($obaoPvcLines | Where-Object { $_ })) {
        $pvcName = ($line -split '\s+')[0]
        & kubectl delete pvc $pvcName -n $Namespace --wait=false --request-timeout=10s 2>$null | Out-Null
        $pvcElapsed = 0
        while ($pvcElapsed -lt 15) {
            $pvcCheck = & kubectl get pvc $pvcName -n $Namespace --ignore-not-found --request-timeout=5s 2>$null
            if (-not $pvcCheck) { break }
            Start-Sleep -Seconds 3; $pvcElapsed += 3
        }
        if ($pvcElapsed -ge 15) {
            Write-Warning "  PVC '$pvcName' still terminating after 15s — Helm's re-deploy may fail if it's not gone yet"
        } else {
            Write-GroupLine "✓ PVC '$pvcName' wiped" -ForegroundColor Yellow
        }
    }

    & kubectl delete secret openbao-unseal-keys -n $Namespace --ignore-not-found --request-timeout=5s 2>$null | Out-Null
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Write-GroupLine "✓ Unseal-key Secret and state file removed" -ForegroundColor Yellow
}

Complete-Group

$storageClassLine = if ($UserConfig.StorageClass) { "    storageClass: $($UserConfig.StorageClass)" } else { "" }

# HA branch: Raft integrated storage across $HAReplicas pods. The chart
# templates no peer-join logic of its own (verified against its own source —
# no init container/postStart hook writes retry_join) so auto_join uses
# go-discover's "k8s" provider to find sibling pods by label at runtime,
# rather than hardcoding N static leader_api_addr entries. RBAC for this
# (get/watch/list pods) is already granted by the chart's own
# server-discovery-role.yaml whenever mode=ha, since
# server.serviceAccount.serviceDiscovery.enabled defaults to true — no
# extra Role/RoleBinding needed here.
# Label selector matches this release's own server pods exactly (chart's
# server-statefulset.yaml pod-template labels, release name "openbao"):
# app.kubernetes.io/name=openbao,app.kubernetes.io/instance=openbao,component=server
$modeYaml = if ($HAEnabled) {
    @"
  ha:
    enabled: true
    replicas: $HAReplicas
    raft:
      enabled: true
      config: |
        ui = true

        listener "tcp" {
          tls_disable = 1
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          telemetry {
            unauthenticated_metrics_access = "true"
          }
        }
        storage "raft" {
          path = "/openbao/data"
          retry_join {
            # The label_selector value is itself comma-separated key=value
            # pairs (standard k8s selector syntax), so it contains embedded
            # "=" characters. go-discover's own config-string parser reads
            # this whole auto_join string as space-separated key=value
            # tokens and requires any value containing "=" to be enclosed
            # in double quotes, or it errors and silently drops retry_join
            # entirely — confirmed live 2026-09-06 (openbao-1 looped
            # "equals in key's value, enclosing double-quote needed" and
            # could never join Raft, no matter how long it waited).
            auto_join = "provider=k8s namespace=$Namespace label_selector=\"app.kubernetes.io/name=openbao,app.kubernetes.io/instance=openbao,component=server\""
            auto_join_scheme = "http"
            auto_join_port = 8200
          }
        }

        telemetry {
          prometheus_retention_time = "30s"
          disable_hostname = true
        }
"@
} else {
    @"
  ha:
    enabled: false
  standalone:
    config: |
      ui = true

      listener "tcp" {
        tls_disable = 1
        address = "[::]:8200"
        cluster_address = "[::]:8201"
        telemetry {
          unauthenticated_metrics_access = "true"
        }
      }
      storage "file" {
        path = "/openbao/data"
      }

      telemetry {
        prometheus_retention_time = "30s"
        disable_hostname = true
      }
"@
}

$HelmValues = @"
server:
  enabled: true
  dev:
    enabled: false
$modeYaml
  dataStorage:
    enabled: true
    size: $($UserConfig.StorageSize)
$storageClassLine
  resources:
    limits:
      cpu: $($UserConfig.Resources.Limits.Cpu)
      memory: $($UserConfig.Resources.Limits.Memory)
    requests:
      cpu: $($UserConfig.Resources.Requests.Cpu)
      memory: $($UserConfig.Resources.Requests.Memory)
ui:
  enabled: true
injector:
  enabled: false
csi:
  enabled: true
  extraArgs:
    - --endpoint=/provider/vault.sock
global:
  serverTelemetry:
    prometheusOperator: true
serverTelemetry:
  serviceMonitor:
    enabled: true
"@

$valuesFile = New-TemporaryFile
Set-Content -Path $valuesFile.FullName -Value $HelmValues -Encoding UTF8

Reset-StuckHelmRelease -ReleaseName "openbao" -Namespace $Namespace

Start-Group -Title "Deploy"

$exitCode = Invoke-WithSpinner -Message "Deploying OpenBao..." -Executable "helm" `
    -Arguments @("upgrade", "--install", "openbao", "openbao/openbao",
                 "--namespace", $Namespace,
                 "--version", $ChartVersion,
                 "--values", $valuesFile.FullName,
                 "--wait=false",
                 "--timeout", "5m") -ShowOutput:$verbose
Remove-Item $valuesFile.FullName -Force -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { Write-Error "Failed to deploy OpenBao (exit code $exitCode)"; exit 1 }

# Wait for pod to be Running (not Ready — readiness probe fails until initialized)
$exitCode = Invoke-WithSpinner -Message "Waiting for OpenBao pod..." -Executable "kubectl" `
    -Arguments @("wait", "pod/openbao-0", "-n", $Namespace,
                 "--for=jsonpath={.status.phase}=Running", "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "OpenBao pod did not start"; exit 1 }

# Wait until the OpenBao HTTP listener is up and returns parseable JSON.
$baoStatus = Invoke-ScriptBlockWithSpinner -Message "Waiting for OpenBao listener..." -ShowElapsed `
    -ArgumentList @($Namespace) -ScriptBlock {
        param($Namespace)
        $elapsed = 0
        while ($elapsed -lt 60) {
            $raw = & kubectl exec openbao-0 -n $Namespace -- bao status -format=json 2>$null
            $jsonStart = if ($raw) { $raw.IndexOf('{') } else { -1 }
            if ($jsonStart -ge 0) {
                $parsed = $raw.Substring($jsonStart) | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
                if ($parsed) { return $parsed }
            }
            Start-Sleep -Seconds 3; $elapsed += 3
        }
        return $null
    }

if (-not $baoStatus) {
    Write-Error "OpenBao listener did not respond after 60s — check pod logs: kubectl logs openbao-0 -n $Namespace"
    exit 1
}
Write-GroupLine "✓ Pod running" -ForegroundColor Green

Complete-Group
Start-Group -Title "Unseal"

# ── 2. Init / Unseal ─────────────────────────────────────────────
$unsealKey = $null
$rootToken = $null

if (-not $baoStatus['initialized']) {
    $initRef = [ref]$null
    Invoke-WithSpinner -Message "Initializing OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", $Namespace, "--",
                     "bao", "operator", "init", "-key-shares=1", "-key-threshold=1", "-format=json") `
        -OutputVariable $initRef | Out-Null
    $initJson = $initRef.Value -join "`n"
    $jsonStart = $initJson.IndexOf('{')
    if ($jsonStart -gt 0) { $initJson = $initJson.Substring($jsonStart) }
    if ($initJson -notmatch '^\s*\{') {
        Write-Error "bao operator init returned unexpected output (not JSON):`n$initJson"; exit 1
    }
    $initResult = $initJson | ConvertFrom-Json -AsHashtable
    $unsealKey  = $initResult['unseal_keys_b64'][0]
    $rootToken  = $initResult['root_token']

    @{ UnsealKey = $unsealKey; RootToken = $rootToken; Mode = $requestedMode } |
        ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    Write-GroupLine "✓ Initialized — state saved to $StateFile" -ForegroundColor Green

    & kubectl create secret generic openbao-unseal-keys -n $Namespace `
        --from-literal=unseal-key=$unsealKey `
        --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    Write-GroupLine "✓ Unseal key stored in Kubernetes Secret" -ForegroundColor Green
} else {
    if (-not (Test-Path $StateFile)) {
        Write-Error @"
OpenBao is already initialized but no state file found at:
  $StateFile

The unseal keys are lost — the instance cannot be used.
Run Reset-RKE2.ps1 to wipe the OpenBao PVC, then re-run Install-Base.ps1.
"@
        exit 1
    }
    $state     = Get-Content $StateFile | ConvertFrom-Json
    $unsealKey = $state.UnsealKey
    $rootToken = $state.RootToken
    Write-GroupLine "✓ Already initialized — loaded state from $StateFile" -ForegroundColor Green
}

if ($baoStatus['sealed']) {
    Invoke-WithSpinner -Message "Unsealing OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", $Namespace, "--",
                     "bao", "operator", "unseal", $unsealKey) | Out-Null
    Write-GroupLine "✓ Unsealed" -ForegroundColor Green
} else {
    Write-GroupLine "✓ Already unsealed" -ForegroundColor Green
}

# ── 2b. Join + unseal remaining HA replicas ──────────────────────
# retry_join/auto_join (go-discover "k8s" provider, configured above in
# $modeYaml) joins each replica's Raft storage to the cluster automatically
# at pod startup — no manual "bao operator raft join" needed here. What
# auto-join does NOT do is unseal: every replica ships sealed and needs the
# same Shamir key applied to it individually, same as pod-0 above.
if ($HAEnabled) {
    for ($i = 1; $i -lt $HAReplicas; $i++) {
        $podName = "openbao-$i"

        # This StatefulSet uses the default OrderedReady pod management policy:
        # pod $i isn't even created until pod $i-1 passes its readiness probe
        # (bao status, which fails while sealed) — so right after unsealing the
        # previous pod, this one may not exist for anywhere from a few seconds
        # to a few minutes yet. `kubectl wait` doesn't tolerate that: it errors
        # immediately with NotFound instead of polling for the object to appear
        # (confirmed live 2026-09-06 — the loop raced ahead of the StatefulSet
        # controller and gave up on openbao-1/openbao-2 before they existed).
        # Poll for existence first; only then hand off to kubectl wait below
        # for the actual Running condition.
        $joined = $false
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            if ($attempt -eq 1) {
                $existElapsed = 0
                $podExists = $false
                while ($existElapsed -lt 300) {
                    $existCheck = & kubectl get pod/$podName -n $Namespace --ignore-not-found --request-timeout=5s 2>$null
                    if ($existCheck) { $podExists = $true; break }
                    Start-Sleep -Seconds 5; $existElapsed += 5
                }
                if (-not $podExists) {
                    Write-Warning "  $podName was never created by the StatefulSet — check: kubectl describe statefulset openbao -n $Namespace"
                    break
                }
            } else {
                # First attempt's Raft-join wait timed out. A Running-but-stuck
                # replica is often just executing whatever config existed when
                # its pod was created — Helm upgrades the ConfigMap in place,
                # but OpenBao only reads config at process start, so a pod left
                # over from an earlier attempt (or created moments before this
                # run's `helm upgrade` landed) keeps retrying auto-join against
                # a stale rendered config forever (confirmed live 2026-09-06:
                # the ConfigMap already held the corrected retry_join string,
                # but the running process kept logging the old parse error
                # until the pod itself was restarted). One forced restart picks
                # up whatever config is current before giving up for good.
                Write-GroupLine "↻ $podName still not joined — restarting pod to pick up current config" -ForegroundColor Yellow
                & kubectl delete pod/$podName -n $Namespace --ignore-not-found --request-timeout=10s 2>$null | Out-Null

                $existElapsed = 0
                $podExists = $false
                while ($existElapsed -lt 300) {
                    $existCheck = & kubectl get pod/$podName -n $Namespace --ignore-not-found --request-timeout=5s 2>$null
                    if ($existCheck) { $podExists = $true; break }
                    Start-Sleep -Seconds 5; $existElapsed += 5
                }
                if (-not $podExists) {
                    Write-Warning "  $podName was never recreated after restart — check: kubectl describe statefulset openbao -n $Namespace"
                    break
                }
            }

            $exitCode = Invoke-WithSpinner -Message "Waiting for $podName..." -Executable "kubectl" `
                -Arguments @("wait", "pod/$podName", "-n", $Namespace,
                             "--for=jsonpath={.status.phase}=Running", "--timeout=5m") `
                -ShowOutput:$verbose
            if ($exitCode -ne 0) {
                Write-Warning "  $podName did not start — check pod logs: kubectl logs $podName -n $Namespace"
                break
            }

            $peerStatus = Invoke-ScriptBlockWithSpinner -Message "Waiting for $podName to join Raft..." -ShowElapsed `
                -ArgumentList @($Namespace, $podName) -ScriptBlock {
                    param($Namespace, $podName)
                    $elapsed = 0
                    while ($elapsed -lt 120) {
                        $raw = & kubectl exec $podName -n $Namespace -- bao status -format=json 2>$null
                        $jsonStart = if ($raw) { $raw.IndexOf('{') } else { -1 }
                        if ($jsonStart -ge 0) {
                            $parsed = $raw.Substring($jsonStart) | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
                            # The listener answers (a parseable status response) well
                            # before auto-join has actually pulled the Raft snapshot
                            # from the leader — until that finishes, the node reports
                            # sealed: true but initialized: false, and unsealing it
                            # fails with "Vault is not initialized" (confirmed live
                            # 2026-09-06). Wait for initialized too, not just parseable.
                            if ($parsed -and $parsed['initialized']) { return $parsed }
                        }
                        Start-Sleep -Seconds 3; $elapsed += 3
                    }
                    return $null
                }

            if ($peerStatus) { $joined = $true; break }
        }

        if (-not $joined) {
            Write-Warning "  $podName did not finish joining Raft after two attempts — check pod logs: kubectl logs $podName -n $Namespace"
            continue
        }

        if ($peerStatus['sealed']) {
            # Exit code was previously discarded (piped to Out-Null), so the
            # "✓ joined and unsealed" line printed unconditionally even when this
            # command failed outright — confirmed live 2026-09-06, where the
            # unseal call errored ("Vault is not initialized", now fixed above)
            # but the script still reported success. Check it for real.
            $unsealExit = Invoke-WithSpinner -Message "Unsealing $podName..." -Executable "kubectl" `
                -Arguments @("exec", $podName, "-n", $Namespace, "--",
                             "bao", "operator", "unseal", $unsealKey)
            if ($unsealExit -ne 0) {
                Write-Warning "  Failed to unseal $podName — check: kubectl exec $podName -n $Namespace -- bao status"
                continue
            }
            Write-GroupLine "✓ $podName joined and unsealed" -ForegroundColor Green
        } else {
            Write-GroupLine "✓ $podName already unsealed" -ForegroundColor Green
        }
    }
}

Complete-Group
Start-Group -Title "Configuration"

# ── 3. Kubernetes Auth + KV-v2 ───────────────────────────────────
function Invoke-BaoCmd {
    param([string]$Msg, [string]$Cmd)
    Invoke-WithSpinner -Message $Msg -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", $Namespace, "--", "sh", "-c", "$Cmd 2>/dev/null") | Out-Null
}

Invoke-BaoCmd "Enabling KV-v2 secrets engine..." `
    "BAO_TOKEN=$rootToken bao secrets enable -path=$($UserConfig.SecretsPath) kv-v2 || true"

Invoke-BaoCmd "Enabling Kubernetes auth..." `
    "BAO_TOKEN=$rootToken bao auth enable kubernetes || true"

$k8sHost = (& kubectl exec openbao-0 -n $Namespace -- sh -c 'echo $KUBERNETES_SERVICE_HOST' 2>$null).Trim()

Invoke-BaoCmd "Configuring Kubernetes auth..." `
    "BAO_TOKEN=$rootToken bao write auth/kubernetes/config kubernetes_host='https://${k8sHost}:443'"

Write-GroupLine "✓ Kubernetes auth configured" -ForegroundColor Green

# ── 3b. Audit device (Finding #9) ─────────────────────────────────
# Local file audit log on the existing data PVC (no new volume needed) —
# gives OpenBao its own record of who accessed which secret, mirroring the
# Kubernetes API audit logging this same finding adds for the cluster.
$auditListRef = [ref]$null
Invoke-WithSpinner -Message "Checking OpenBao audit devices..." -Executable "kubectl" `
    -Arguments @("exec", "openbao-0", "-n", $Namespace, "--", "sh", "-c",
                 "BAO_TOKEN=$rootToken bao audit list -format=json 2>/dev/null") `
    -OutputVariable $auditListRef | Out-Null
$auditListJson = ($auditListRef.Value -join "`n")
if ($auditListJson -notmatch '"file/"') {
    Invoke-BaoCmd "Enabling audit device (file)..." `
        "BAO_TOKEN=$rootToken bao audit enable file file_path=/openbao/data/audit/audit.log || true"
    Write-GroupLine "✓ Audit device enabled (/openbao/data/audit/audit.log)" -ForegroundColor Green
} else {
    Write-GroupLine "✓ Audit device already enabled" -ForegroundColor Green
}

# ── 4. PKI Engines — one per PKI definition ───────────────────────
# Each PKI becomes a separate secrets engine mount ("pki-<name>").
# Supported types:
#   Root         — self-signed root CA (10y), fully automated
#   Intermediate/OpenBao  — signed by another PKI in this list, fully automated
#   Intermediate/External — CSR exported, signed externally, Status=PendingCSR
#
# Roles:
#   HTTP        → ServerAuth, allow_subdomains, cert-manager ClusterIssuer created
#   mTLS        → ClientAuth, allow_any_name, AppRole for enrollment created
#   CodeSigning → placeholder, no Vault commands yet
#
# Backward compat: if no PKIs are passed, create the legacy single "ingress" PKI
# on mount "pki" so existing clusters keep working without re-running Prompt.ps1.

if ($PKIs.Count -eq 0) {
    Write-GroupLine "No PKIs defined — PKI engine will not be activated (no TLS, no ClusterIssuer)." -ForegroundColor Yellow
}

# The old single ClusterIssuer "openbao-pki" is intentionally NOT deleted here.
# Existing ingresses (Longhorn, Authelia, Rancher) still reference it and cert-manager
# would immediately fail to renew their certs if it disappears. Each component
# migrates to "openbao-pki-<name>" the next time its own Install.ps1 is re-run.
$oldIssuerExists = & kubectl get clusterissuer openbao-pki --ignore-not-found 2>$null
if ($oldIssuerExists -and ($PKIs | Where-Object { "HTTP" -in @($_.Roles) -and $_.MountPath -ne "pki" })) {
    Write-GroupLine "ℹ  Old ClusterIssuer 'openbao-pki' is kept." -ForegroundColor DarkGray
    Write-GroupLine "   Components migrate to 'openbao-pki-<name>' on their next re-install." -ForegroundColor DarkGray
}

# Helper: write a Vault policy via file + kubectl cp (avoids CRLF issues with heredocs)
function Write-BaoPolicy {
    param([string]$PolicyName, [string]$PolicyHcl)
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp.FullName -Value $PolicyHcl -Encoding UTF8 -NoNewline
    $remote = "/tmp/$PolicyName.hcl"
    Push-Location (Split-Path $tmp.FullName)
    & kubectl cp "./$(Split-Path $tmp.FullName -Leaf)" "${Namespace}/openbao-0:$remote" 2>$null | Out-Null
    Pop-Location
    Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
    & kubectl exec openbao-0 -n $Namespace -- sh -c "BAO_TOKEN=$rootToken bao policy write $PolicyName $remote" 2>$null | Out-Null
    & kubectl exec openbao-0 -n $Namespace -- rm -f $remote 2>$null | Out-Null
}

# Enable AppRole auth once (shared across all mTLS PKIs)
$appRoleEnabled = $false

$pkiResults = [System.Collections.Generic.List[hashtable]]::new()

foreach ($pki in $PKIs) {
    $pkiName      = $pki.Name
    $mountPath    = $pki.MountPath
    $pkiType      = $pki.Type
    $roles        = @($pki.Roles)
    $isDefault    = [bool]$pki.IsDefault
    $currentStatus = $pki.Status

    Write-GroupLine "────────────────────────────────────────" -ForegroundColor DarkGray
    Write-GroupLine "PKI: $pkiName  ($pkiType · $mountPath)" -ForegroundColor Cyan

    # Skip if this is a pending external intermediate — Complete-PkiIntermediate handles it
    if ($currentStatus -eq "PendingCSR") {
        Write-GroupLine "⏸ Status PendingCSR — waiting for external certificate (Complete-PkiIntermediate.ps1)" -ForegroundColor Yellow
        $pkiResults.Add($pki) | Out-Null
        continue
    }

    # Check if mount already exists
    $mountsRef = [ref]$null
    Invoke-WithSpinner -Message "Checking PKI mounts..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", $Namespace, "--", "sh", "-c",
                     "BAO_TOKEN=$rootToken bao secrets list -format=json 2>/dev/null") `
        -OutputVariable $mountsRef | Out-Null
    $mountsJson = $mountsRef.Value
    $jsonStart2 = if ($mountsJson) { ($mountsJson -join "`n").IndexOf('{') } else { -1 }
    $mountExists = $false
    $caExists    = $false
    if ($jsonStart2 -ge 0) {
        $mounts = ($mountsJson -join "`n").Substring($jsonStart2) | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
        if ($mounts) { $mountExists = $mounts.ContainsKey("$mountPath/") }
    }

    if (-not $mountExists) {
        Invoke-BaoCmd "Enabling PKI engine ($mountPath)..." `
            "BAO_TOKEN=$rootToken bao secrets enable -path=$mountPath pki || true"
        Invoke-BaoCmd "Setting PKI max TTL (10y)..." `
            "BAO_TOKEN=$rootToken bao secrets tune -max-lease-ttl=87600h $mountPath"
    }

    # Check if CA already exists on this mount. A non-0 exit here is a normal,
    # expected outcome the first time a PKI is created (there's no CA yet) —
    # not a failure — so -ExpectedNonZero keeps the step green/✓ instead of
    # rendering as an alarming ✗ (and suppresses the harmless stderr echo)
    # while $caCheckExit still carries the real exit code for the branch below.
    $caCheckExit = Invoke-WithSpinner -Message "Checking CA on $mountPath..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", $Namespace, "--", "sh", "-c",
                     "BAO_TOKEN=$rootToken bao read -field=certificate $mountPath/cert/ca 2>/dev/null") `
        -ExpectedNonZero
    $caExists = $caCheckExit -eq 0

    if (-not $caExists) {
        if ($pkiType -eq "Root") {
            $cn = "$pkiName.$Domain"
            Invoke-BaoCmd "Generating Root CA (CN=$cn)..." `
                "BAO_TOKEN=$rootToken bao write -field=certificate $mountPath/root/generate/internal common_name='$cn' ttl=87600h"
            Invoke-BaoCmd "Configuring CA URLs..." `
                ("BAO_TOKEN=$rootToken bao write $mountPath/config/urls " +
                 "issuing_certificates='http://openbao.$Namespace.svc.cluster.local:8200/v1/$mountPath/ca' " +
                 "crl_distribution_points='http://openbao.$Namespace.svc.cluster.local:8200/v1/$mountPath/crl'")
            Write-GroupLine "✓ Root CA created (10y, CN=$cn)" -ForegroundColor Green
        }
        elseif ($pkiType -eq "Intermediate") {
            $cn = "$pkiName-intermediate.$Domain"

            if ($pki.ParentType -eq "OpenBao") {
                # Fully automated: generate CSR → sign with parent → import
                $parentMount = $pki.ParentMountPath

                $csrRef = [ref]$null
                Invoke-WithSpinner -Message "Generating intermediate CSR ($mountPath)..." -Executable "kubectl" `
                    -Arguments @("exec", "openbao-0", "-n", $Namespace, "--", "sh", "-c",
                                 "BAO_TOKEN=$rootToken bao write -field=csr $mountPath/intermediate/generate/internal common_name='$cn'") `
                    -OutputVariable $csrRef | Out-Null
                $csr = ($csrRef.Value -join "`n").Trim()

                # Write CSR to a temp file on the pod, sign with parent, capture signed cert
                $csrRemote = "/tmp/$pkiName-csr.pem"
                $csrTmp = New-TemporaryFile
                Set-Content -Path $csrTmp.FullName -Value $csr -Encoding UTF8 -NoNewline
                Write-GroupLine "· Uploading CSR to pod..." -ForegroundColor DarkGray
                Push-Location (Split-Path $csrTmp.FullName)
                & kubectl cp "./$(Split-Path $csrTmp.FullName -Leaf)" "${Namespace}/openbao-0:$csrRemote" 2>$null | Out-Null
                Pop-Location
                Remove-Item $csrTmp.FullName -Force -ErrorAction SilentlyContinue

                $signedRef = [ref]$null
                Invoke-WithSpinner -Message "Signing intermediate with parent PKI ($parentMount)..." -Executable "kubectl" `
                    -Arguments @("exec", "openbao-0", "-n", $Namespace, "--", "sh", "-c",
                                 "BAO_TOKEN=$rootToken bao write -field=certificate $parentMount/root/sign-intermediate csr=@$csrRemote common_name='$cn' ttl=43800h") `
                    -OutputVariable $signedRef | Out-Null
                $signedCert = ($signedRef.Value -join "`n").Trim()
                & kubectl exec openbao-0 -n $Namespace -- rm -f $csrRemote 2>$null | Out-Null

                # Import signed cert
                $signedRemote = "/tmp/$pkiName-signed.pem"
                $signedTmp = New-TemporaryFile
                Set-Content -Path $signedTmp.FullName -Value $signedCert -Encoding UTF8 -NoNewline
                Write-GroupLine "· Uploading signed certificate to pod..." -ForegroundColor DarkGray
                Push-Location (Split-Path $signedTmp.FullName)
                & kubectl cp "./$(Split-Path $signedTmp.FullName -Leaf)" "${Namespace}/openbao-0:$signedRemote" 2>$null | Out-Null
                Pop-Location
                Remove-Item $signedTmp.FullName -Force -ErrorAction SilentlyContinue

                $importExit = Invoke-WithSpinner -Message "Importing signed intermediate certificate..." -Executable "kubectl" `
                    -Arguments @("exec", "openbao-0", "-n", $Namespace, "--", "sh", "-c",
                                 "BAO_TOKEN=$rootToken bao write $mountPath/intermediate/set-signed certificate=@$signedRemote")
                & kubectl exec openbao-0 -n $Namespace -- rm -f $signedRemote 2>$null | Out-Null
                if ($importExit -ne 0) {
                    Write-Error "Signed certificate import failed for $mountPath — check certificate format and that the CSR was signed by the correct parent CA"
                    $pkiResults.Add($pki) | Out-Null
                    continue
                }

                Invoke-BaoCmd "Configuring CA URLs..." `
                    ("BAO_TOKEN=$rootToken bao write $mountPath/config/urls " +
                     "issuing_certificates='http://openbao.$Namespace.svc.cluster.local:8200/v1/$mountPath/ca' " +
                     "crl_distribution_points='http://openbao.$Namespace.svc.cluster.local:8200/v1/$mountPath/crl'")
                Write-GroupLine "✓ Intermediate CA signed and imported (Parent: $parentMount)" -ForegroundColor Green
            }
            elseif ($pki.ParentType -eq "External") {
                # Export CSR, set PendingCSR status — Complete-PkiIntermediate.ps1 finishes this
                $csrRef = [ref]$null
                Invoke-WithSpinner -Message "Generating intermediate CSR ($mountPath)..." -Executable "kubectl" `
                    -Arguments @("exec", "openbao-0", "-n", $Namespace, "--", "sh", "-c",
                                 "BAO_TOKEN=$rootToken bao write -field=csr $mountPath/intermediate/generate/internal common_name='$cn'") `
                    -OutputVariable $csrRef | Out-Null
                $csr = ($csrRef.Value -join "`n").Trim()

                $csrExportPath = Join-Path $BaseDir "$pkiName-intermediate.csr"
                Set-Content -Path $csrExportPath -Value $csr -Encoding UTF8
                Write-GroupLine "✓ CSR generated and exported to:" -ForegroundColor Green
                Write-GroupLine "  $csrExportPath" -ForegroundColor Yellow
                Write-GroupLine "→ Have the CSR signed by your Corporate CA," -ForegroundColor DarkGray
                Write-GroupLine "  then: .\33-openbao\Complete-PkiIntermediate.ps1 -Platform $Platform" -ForegroundColor DarkGray

                $pki['Status']        = "PendingCSR"
                $pki['CSRExportPath'] = $csrExportPath
                $pkiResults.Add($pki) | Out-Null
                continue
            }
        }
    } else {
        Write-GroupLine "✓ CA already exists" -ForegroundColor Green
    }

    # ── Configure PKI roles ──────────────────────────────────────
    if ("HTTP" -in $roles) {
        # require_cn=false: cert-manager CSRs carry the hostname as SAN only (modern best practice)
        Invoke-BaoCmd "Configuring HTTP role (ServerAuth)..." `
            ("BAO_TOKEN=$rootToken bao write $mountPath/roles/http " +
             "allowed_domains='$Domain' allow_subdomains=true allow_bare_domains=true allow_any_name=false " +
             "require_cn=false max_ttl=720h ttl=720h key_type=rsa key_bits=2048 " +
             "key_usage='DigitalSignature,KeyEncipherment' ext_key_usage='ServerAuth'")
        Write-GroupLine "✓ Role 'http' (ServerAuth, *.${Domain})" -ForegroundColor Green
    }

    if ("mTLS" -in $roles) {
        $ttlH = if ($pki.mTlsTtlHours) { [int]$pki.mTlsTtlHours } else { 336 }
        # allow_any_name=true: device identity (VIN, serial) goes in CN at issuance time
        Invoke-BaoCmd "Configuring mTLS role (ClientAuth, TTL=${ttlH}h)..." `
            ("BAO_TOKEN=$rootToken bao write $mountPath/roles/mtls " +
             "allow_any_name=true enforce_hostnames=false require_cn=true " +
             "max_ttl=${ttlH}h ttl=${ttlH}h key_type=rsa key_bits=2048 " +
             "key_usage='DigitalSignature' ext_key_usage='ClientAuth' no_store=false")
        Write-GroupLine "✓ Role 'mtls' (ClientAuth, TTL=${ttlH}h)" -ForegroundColor Green

        # AppRole for device enrollment (one-time token) — infrastructure only.
        # Actual token generation happens in the vehicle/MQTT onboarding script.
        if (-not $appRoleEnabled) {
            Invoke-BaoCmd "Enabling AppRole auth..." `
                "BAO_TOKEN=$rootToken bao auth enable approle || true"
            $appRoleEnabled = $true
        }
        Write-BaoPolicy -PolicyName "vehicle-enroll-$pkiName" -PolicyHcl @"
path "$mountPath/sign/mtls" {
  capabilities = ["create", "update"]
}
"@
        Invoke-BaoCmd "Configuring AppRole for '$pkiName' enrollment..." `
            ("BAO_TOKEN=$rootToken bao write auth/approle/role/$pkiName-enroll " +
             "secret_id_ttl=1h token_policies=vehicle-enroll-$pkiName " +
             "token_ttl=10m token_max_ttl=30m")
        Write-GroupLine "✓ AppRole '$pkiName-enroll' ready (one-time token, 1h TTL)" -ForegroundColor Green
    }

    # ── cert-manager ClusterIssuer (HTTP role only) ───────────────
    if ("HTTP" -in $roles) {
        # Backward compat: the legacy "pki" mount keeps the name "openbao-pki" so
        # existing ingresses (Longhorn, Authelia, Rancher) need no immediate update.
        # Any new PKI on a different mount gets the new "openbao-pki-<name>" scheme.
        $issuerName = if ($mountPath -eq "pki") { "openbao-pki" } else { "openbao-pki-$pkiName" }
        $pki['ClusterIssuerName'] = $issuerName

        Write-BaoPolicy -PolicyName "cert-manager-$pkiName" -PolicyHcl @"
path "$mountPath/sign/http" {
  capabilities = ["create", "update"]
}
"@
        Invoke-BaoCmd "Configuring Vault role for cert-manager ($pkiName)..." `
            ("BAO_TOKEN=$rootToken bao write auth/kubernetes/role/cert-manager-$pkiName " +
             "bound_service_account_names=cert-manager bound_service_account_namespaces=cert-manager " +
             "policies=cert-manager-$pkiName ttl=20m")

        $clusterIssuerYaml = @"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $issuerName
spec:
  vault:
    server: http://openbao.$Namespace.svc.cluster.local:8200
    path: $mountPath/sign/http
    auth:
      kubernetes:
        role: cert-manager-$pkiName
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager
"@
        # cert-manager's rollout-status wait (31-cert-manager/Install.ps1) only
        # confirms the webhook Deployment's pods are Ready — it doesn't confirm
        # cainjector has finished injecting the webhook's caBundle into the
        # ValidatingWebhookConfiguration yet. Applying a ClusterIssuer in that
        # short gap fails admission with a webhook-connection error, easily
        # mistaken for "CRDs missing" since kubectl's stderr is swallowed above.
        # Same transient-miss-right-after-another-component's-Helm-deploy
        # reasoning as Write-OpenBaoSecret's pod-status retry — retry briefly
        # instead of failing PKI setup over what's normally a ~10-20s window.
        $issuerApplied = $false
        for ($i = 0; $i -lt 6; $i++) {
            $applyOutput = $clusterIssuerYaml | & kubectl apply -f - 2>&1
            if ($LASTEXITCODE -eq 0) { $issuerApplied = $true; break }
            Start-Sleep -Seconds 5
        }
        if ($issuerApplied) {
            Write-GroupLine "✓ ClusterIssuer '$issuerName' ready" -ForegroundColor Green
        } else {
            Write-Warning "  ClusterIssuer '$issuerName' could not be created after retries: $applyOutput"
        }
    }

    $pki['Status'] = "Active"
    $pkiResults.Add($pki) | Out-Null
}

# ── 5. Persist PKI state ──────────────────────────────────────────
if ($pkiResults.Count -gt 0) {
    Save-OpenBaoPkis -PKIs @($pkiResults | ForEach-Object { [hashtable]$_ }) -BaseDir $BaseDir -Platform $Platform
    Write-GroupLine "✓ PKI status saved ($StateFile)" -ForegroundColor Green
}

# ── 6. Auto-Unsealer Deployment ───────────────────────────────────
# Under standalone this is just the one pod, same as before. Under HA, the
# load-balanced "openbao" ClusterIP Service round-robins across all 3 pods —
# polling only it could keep landing on the already-unsealed replicas and
# never notice a sealed one. Target each pod individually instead, via its
# stable per-pod DNS name on the chart's headless "-internal" Service
# (server-headless-service.yaml: name "{{ fullname }}-internal", resolves
# to "openbao-internal" for this release), which unifies standalone/HA into
# one address-list-driven loop rather than two separate code paths.
$replicaCount = if ($HAEnabled) { $HAReplicas } else { 1 }
$unsealAddrs  = (0..($replicaCount - 1) | ForEach-Object {
    "http://openbao-$_.openbao-internal.$Namespace.svc.cluster.local:8200"
}) -join " "

$unsealerYaml = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openbao-unsealer
  namespace: $Namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openbao-unsealer
  template:
    metadata:
      labels:
        app: openbao-unsealer
    spec:
      serviceAccountName: default
      containers:
      - name: unsealer
        image: curlimages/curl:8.21.0
        command: ["/bin/sh", "-c"]
        args:
        - |
          ADDRS="$unsealAddrs"
          while true; do
            for ADDR in `$ADDRS; do
              CODE=`$(curl -s -o /dev/null -w "%{http_code}" `$ADDR/v1/sys/health 2>/dev/null || echo "000")
              if [ "`$CODE" = "503" ]; then
                KEY=`$(head -n1 /var/run/secrets/unseal/unseal-key)
                curl -sf -X PUT `$ADDR/v1/sys/unseal -d "{\"key\":\"`$KEY\"}" -o /dev/null
                echo "Unsealed `$ADDR"
              fi
            done
            sleep 30
          done
        resources:
          limits:   { cpu: "50m", memory: "32Mi" }
          requests: { cpu: "10m", memory: "16Mi" }
        volumeMounts:
        - name: unseal-secret
          mountPath: /var/run/secrets/unseal
          readOnly: true
      volumes:
      - name: unseal-secret
        secret:
          secretName: openbao-unseal-keys
"@
$unsealerYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-GroupLine "✓ Auto-unsealer deployed ($replicaCount replica(s))" -ForegroundColor Green }

# ── 7. Ingress ────────────────────────────────────────────────────
# TLS terminates at the ingress (same convention as Grafana/Rancher/etc.) —
# OpenBao itself keeps serving plain HTTP on its ClusterIP service, which is
# also what the ClusterIssuer's own "vault.server" field talks to internally.
# Gated behind Authelia forward-auth (Protect-ComponentIngress) since only
# humans use this public hostname — internal consumers (cert-manager, etc.)
# reach OpenBao via openbao.openbao.svc.cluster.local instead.
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    $protect = Protect-ComponentIngress -Hostname $Hostname -Platform $Platform -BaseDir $BaseDir
    $authAnnotations = ($protect.Annotations.GetEnumerator() | ForEach-Object { "    $($_.Key): `"$($_.Value)`"" }) -join "`n"

    $ingressYaml = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openbao
  namespace: $Namespace
  annotations:
$authAnnotations
spec:
  ingressClassName: $(Get-IngressClass)
$($protect.TlsBlock)
  rules:
  - host: $Hostname
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: openbao
            port:
              number: 8200
"@
    $ingressYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-GroupLine "✓ Ingress configured ($Hostname)" -ForegroundColor Green }
    $scheme = if (-not [string]::IsNullOrWhiteSpace($protect.TlsBlock)) { "https" } else { "http" }
    $portalIcon = Get-PortalIconDataUri -ScriptRoot $ScriptRoot -IconFile $FullConfig.PortalIcon
    Register-PortalEntry -Name $FullConfig.PortalTitle -Url "${scheme}://$Hostname" `
        -Category "Security" -Namespace $Namespace -Subtitle $FullConfig.PortalSubtitle -Order 33 `
        -InternalUrl "http://openbao.openbao.svc.cluster.local:8200" `
        -LogoUrl $portalIcon
}

Complete-Group
Complete-Group

# Reverses the "nothing usable" verdict from earlier on 2026-09-06 (that
# pass only checked the monitoring.mixins.dev Vault mixin — dashboard-only,
# no alerts.libsonnet — and the chart's own commented-out example rules).
# Two real, mutually-corroborating alerting-rules sources turned up after
# the user pointed at them: see prometheusrules/openbao.yaml for the full
# provenance. Metrics telemetry + the chart-native ServiceMonitor are
# enabled above (server.standalone.config's telemetry stanzas,
# global.serverTelemetry.prometheusOperator, serverTelemetry.serviceMonitor)
# — both default to the `release: prometheus` label this cluster's
# Prometheus Operator requires, confirmed against the chart's own
# prometheus-servicemonitor.yaml template. No Grafana dashboard yet: a
# community one exists (grafana.com 23725) but needs `${DS_PROMXY}`/
# `${metrics_prefix}` template-variable resolution work not done in this
# pass — deliberately deferred, same unresolved-datasource-variable
# situation this repo already ships as-is for 31-cert-manager's dashboard.
Start-Group -Title "Monitoring"
Register-PrometheusRule -Namespace $Namespace -Name "openbao" `
    -YamlPath "$ScriptRoot\prometheusrules\openbao.yaml"
Complete-Group

if ($FullConfig.RancherProject) {
    Start-Group -Title "Rancher"
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
    Write-GroupLine "✓ Assigned to Rancher project '$($FullConfig.RancherProject)'" -ForegroundColor Green
    Complete-Group
}

Start-Group -Title "Network Policy"

Install-NetworkPolicyBaseline -Namespace $Namespace
# Only the external-facing "http" port (8200) — 8201 is OpenBao's internal
# cluster port between its own pods (request forwarding under standalone;
# under HA it also carries real Raft peer-to-peer replication traffic once
# HAEnabled is set — see $modeYaml above), never something other
# namespaces need to reach, so this stays unaffected by HA either way.
$openbaoIngressPort = Resolve-ServiceRealPorts -Namespace $Namespace -ServiceName "openbao" -ServicePortName "http"
Set-NetworkPolicyProviderIngress -Namespace $Namespace -Port $openbaoIngressPort
# Consumer-side counterpart, missing until 2026-08-20 (confirmed live on
# Magalu: vault.<hostname> gave a Traefik Gateway Timeout — "ingress" never
# had the "network.k8s/allow-openbao" label, so default-deny-all silently
# dropped every Traefik->openbao packet). Every other public-Ingress
# component (35-authelia, 51-rancher, 66-grafana, ...) already pairs its
# provider-ingress rule with this call; OpenBao's Vault-UI route just never
# got it. Gated on Hostname like the Ingress block above — no route, nothing
# to register as a consumer of.
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    # Real namespace of whichever ingress controller is actually installed —
    # "ingress" on fresh installs, but pre-rename clusters (e.g. live RKE2) can
    # still have ingress-nginx in the legacy "ingress-nginx" namespace
    # (compliance finding #2, NetworkPolicy audit 2026-09-05; see
    # project_rke2_ingress_namespace_mismatch memory).
    $ingressNamespace = Resolve-IngressNamespace
    Set-NetworkPolicyConsumerEgress -Namespace $ingressNamespace -TargetNamespace $Namespace -Port $openbaoIngressPort
}

Complete-Group

# ── Summary ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
if ($Hostname) { Write-Host "  UI:         https://$Hostname" -ForegroundColor Yellow }
Write-Host "  Root token: $StateFile" -ForegroundColor Gray
Write-Host ""
Write-Host "  PKI overview:" -ForegroundColor Gray
foreach ($r in $pkiResults) {
    $default = if ($r.IsDefault) { " [DEFAULT]" } else { "" }
    $roles   = (@($r.Roles) -join ", ")
    Write-Host "    $($r.Name)$default  $($r.Type) · $roles · $($r.Status)" -ForegroundColor $(
        if ($r.Status -eq "PendingCSR") { "Yellow" } else { "Green" })
}
$pendingList = @($pkiResults | Where-Object { $_.Status -eq "PendingCSR" })
if ($pendingList.Count -gt 0) {
    Write-Host ""
    Write-Host "  Pending Intermediate CAs (External):" -ForegroundColor Yellow
    foreach ($p in $pendingList) {
        Write-Host "    $($p.Name) — CSR: $($p.CSRExportPath)" -ForegroundColor Yellow
    }
    Write-Host "  → After signing: .\33-openbao\Complete-PkiIntermediate.ps1 -Platform $Platform" -ForegroundColor DarkGray
}
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
