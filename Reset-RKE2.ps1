<#
.SYNOPSIS
    Removes all installed stack components from the RKE2 cluster.
    The cluster itself (RKE2, nodes) remains intact — only Helm releases,
    namespaces and CRDs of the installed stack components are deleted.
#>
[CmdletBinding()]
param()

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  RKE2 — Stack Reset" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow
Write-Host "  The RKE2 cluster itself remains intact." -ForegroundColor Gray
Write-Host "  Removes: all Helm releases, namespaces and CRDs" -ForegroundColor Gray
Write-Host "  of the installed stack (Monitoring, Ingress, Storage, etc.)." -ForegroundColor Gray
Write-Host ""
Write-Host "  WARNING: All data in Longhorn volumes will be lost." -ForegroundColor Red
Write-Host ""

$confirm = Read-Host "  Type 'yes' to continue"
if ($confirm -ne "yes") {
    Write-Host "  Aborted." -ForegroundColor Yellow
    exit 0
}

# ── Set kubecontext to RKE2 ──────────────────────────────────────
$stateFile = Join-Path $PSScriptRoot ".rke2-state.json"
if (-not (Test-Path $stateFile)) {
    Write-Error "State file not found: $stateFile — run Install-Base.ps1 first."
    exit 1
}
$rke2State = Get-Content $stateFile | ConvertFrom-Json
$kubeconfigPath = $rke2State.KubeconfigPath -replace '^~', $env:USERPROFILE
if (-not (Test-Path $kubeconfigPath)) {
    Write-Error "RKE2 kubeconfig not found: $kubeconfigPath"
    exit 1
}
$env:KUBECONFIG = $kubeconfigPath
Write-Host "  Kubeconfig: $kubeconfigPath" -ForegroundColor Gray

Import-Module "$PSScriptRoot\_lib\Installer.Ui.psm1" -Force -Verbose:$false

# ── Remove stale APIServices ──────────────────────────────────
# Rancher registers APIServices (e.g. ext.cattle.io/v1) that linger as ServiceNotFound
# after Rancher is removed. Every kubectl call that does API discovery then waits for
# the timeout of this dead endpoint — multiplied across hundreds of resources this
# can add hours to the reset.
$staleApis = & kubectl get apiservice --no-headers --request-timeout=10s 2>$null |
    Select-String "False|Unknown" |
    ForEach-Object { ($_ -split '\s+')[0] }
if ($staleApis) {
    foreach ($api in $staleApis) {
        & kubectl delete apiservice $api --ignore-not-found --request-timeout=5s 2>$null | Out-Null
        Write-Host "  ✓ Stale APIService removed: $api" -ForegroundColor Green
    }
}

# ── Helper: remove Helm release ─────────────────────────────────
function Remove-HelmRelease {
    param(
        [string]$Release,
        [string]$Namespace,
        [string]$PvcSelector = ""
    )
    $existing = & helm list -n $Namespace --filter "^$Release$" --short 2>&1
    if (-not $existing) { return }
    $exitCode = Invoke-WithSpinner -Message "Uninstalling $Release ($Namespace)..." `
        -Executable "helm" -Arguments @("uninstall", $Release, "-n", $Namespace, "--no-hooks")
    if ($exitCode -eq 0) { Write-Host "  ✓ $Release removed" -ForegroundColor Green }
    else { Write-Warning "  ${Release}: uninstall returned non-zero — continuing" }

    if ($PvcSelector) {
        $pvcs = & kubectl get pvc -n $Namespace -l $PvcSelector -o name --request-timeout=5s 2>$null
        foreach ($pvc in $pvcs) {
            & kubectl patch $pvc -n $Namespace `
                -p '{"metadata":{"finalizers":[]}}' --type=merge --request-timeout=5s 2>$null | Out-Null
            & kubectl delete $pvc -n $Namespace --ignore-not-found --request-timeout=5s 2>$null | Out-Null
            Write-Host "  ✓ PVC removed: $($pvc -replace 'persistentvolumeclaims/','')" -ForegroundColor Green
        }
    }
}

# ── Helper: delete namespace and wait ───────────────────────────
function Remove-Namespace {
    param([string]$Namespace)
    $exists = & kubectl get namespace $Namespace --ignore-not-found 2>&1
    if (-not $exists) { return }

    # Remove finalizers from ALL resource types and explicitly delete each resource.
    # Patch-only is not enough — Kubernetes won't complete namespace deletion until every
    # resource is gone. Explicit delete triggers the GC immediately.
    $frames = @('|', '/', '-', '\'); $fi = 0
    $allResourceTypes = & kubectl api-resources --verbs=list --namespaced -o name --request-timeout=15s 2>$null
    foreach ($rt in $allResourceTypes) {
        Write-Host ("`r  $($frames[$fi++ % 4]) Cleaning up $Namespace...") -NoNewline -ForegroundColor Cyan
        $raw = & kubectl get $rt -n $Namespace -o json --request-timeout=5s 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { continue }
        try {
            $items = ($raw | ConvertFrom-Json).items
            if (-not $items) { continue }
            foreach ($item in $items) {
                $name = $item.metadata.name
                if ($item.metadata.finalizers) {
                    & kubectl patch $rt $name -n $Namespace `
                        -p '{"metadata":{"finalizers":[]}}' --type=merge --request-timeout=5s 2>$null | Out-Null
                }
                & kubectl delete $rt $name -n $Namespace --ignore-not-found --request-timeout=5s 2>$null | Out-Null
            }
        } catch { }
    }
    Write-Host ("`r" + (" " * 50) + "`r") -NoNewline

    # 1. Delete first → namespace enters Terminating state
    & kubectl delete namespace $Namespace --ignore-not-found --wait=false 2>&1 | Out-Null
    # 2. Clear both finalizer fields (finalize-API only works in Terminating state)
    # metadata.finalizers: set by Rancher (e.g. controller.cattle.io/namespace-auth) — blocks hard deletion.
    # spec.finalizers: set by Kubernetes — blocks resource cleanup loop.
    & kubectl patch namespace $Namespace `
        -p '{"metadata":{"finalizers":[]}}' --type=merge --request-timeout=5s 2>$null | Out-Null
    $nsData = & kubectl get namespace $Namespace -o json --request-timeout=5s 2>$null
    if ($LASTEXITCODE -eq 0 -and $nsData) {
        try {
            $nsObj = $nsData | ConvertFrom-Json
            $nsObj.spec | Add-Member -Name "finalizers" -Value @() -MemberType NoteProperty -Force
            $tmpFile = New-TemporaryFile
            $nsObj | ConvertTo-Json -Depth 20 -Compress |
                Set-Content -Path $tmpFile.FullName -Encoding UTF8
            & kubectl replace --raw "/api/v1/namespaces/$Namespace/finalize" `
                -f $tmpFile.FullName 2>$null | Out-Null
            Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
        } catch { }
    }

    $elapsed = 0
    while ($elapsed -lt 60) {
        $phase = & kubectl get namespace $Namespace -o jsonpath='{.status.phase}' --ignore-not-found 2>$null
        if (-not $phase) { break }
        if ($phase -eq "Active") {
            Write-Warning "  Namespace $Namespace recreated as Active — managed by a built-in controller, skipping"
            return
        }
        Write-Host ("`r  $($frames[$fi++ % 4]) Waiting for $Namespace to terminate... (${elapsed}s)") -NoNewline -ForegroundColor Cyan
        Start-Sleep -Seconds 5; $elapsed += 5
    }
    Write-Host ("`r" + (" " * 60) + "`r") -NoNewline

    if ($elapsed -ge 60) {
        Write-Warning "  Namespace $Namespace still present after 60s — check manually"
    } else {
        Write-Host "  ✓ Namespace $Namespace deleted" -ForegroundColor Green
    }
}

# ── 1. ArgoCD (70) ──────────────────────────────────────────────
Write-Host "`n--- 1. ArgoCD ---" -ForegroundColor Magenta
Remove-HelmRelease -Release "argocd" -Namespace "argocd"
Remove-Namespace   -Namespace "argocd"

# ── 2. Grafana (66) ─────────────────────────────────────────────
Write-Host "`n--- 2. Grafana ---" -ForegroundColor Magenta
Remove-HelmRelease -Release "grafana" -Namespace "grafana"
Remove-Namespace   -Namespace "grafana"

# ── 3. OpenTelemetry Collector (65) ─────────────────────────────
Write-Host "`n--- 3. OpenTelemetry Collector ---" -ForegroundColor Magenta
Remove-HelmRelease -Release "opentelemetry-collector" -Namespace "opentelemetry"
Remove-Namespace   -Namespace "opentelemetry"

# ── 4. Tracing: Tempo / Jaeger (64) ─────────────────────────────
Write-Host "`n--- 4. Tracing ---" -ForegroundColor Magenta
Remove-HelmRelease -Release "tempo"  -Namespace "tempo"  -PvcSelector "app.kubernetes.io/instance=tempo"
Remove-HelmRelease -Release "jaeger" -Namespace "jaeger" -PvcSelector "app.kubernetes.io/instance=jaeger"
Remove-Namespace   -Namespace "tempo"
Remove-Namespace   -Namespace "jaeger"

# ── 5. Promtail (63) ────────────────────────────────────────────
Write-Host "`n--- 5. Promtail ---" -ForegroundColor Magenta
Remove-HelmRelease -Release "promtail" -Namespace "promtail"
Remove-Namespace   -Namespace "promtail"

# ── 6. Loki (62) ────────────────────────────────────────────────
Write-Host "`n--- 6. Loki ---" -ForegroundColor Magenta
Remove-HelmRelease -Release "loki" -Namespace "loki" -PvcSelector "app.kubernetes.io/instance=loki"
Remove-Namespace   -Namespace "loki"

# ── 7. Prometheus (61) ──────────────────────────────────────────
Write-Host "`n--- 7. Prometheus ---" -ForegroundColor Magenta
Remove-HelmRelease -Release "prometheus" -Namespace "prometheus" -PvcSelector "app.kubernetes.io/name=prometheus"
Remove-Namespace   -Namespace "prometheus"

# ── 8. Rancher + Agent (51) ─────────────────────────────────────
Write-Host "`n--- 8. Rancher ---" -ForegroundColor Magenta
Remove-HelmRelease -Release "rancher-agent" -Namespace "cattle-system"
Remove-HelmRelease -Release "rancher"       -Namespace "cattle-system"

# Remove only Rancher/cattle.io webhook configurations before deleting cattle-system.
# Rancher registers MutatingWebhookConfigurations pointing to cattle-system.
# Once that namespace is gone the webhook service is missing and EVERY
# resource mutation cluster-wide fails — including secrets in unrelated namespaces.
# Other webhooks (cert-manager, ingress-nginx, etc.) are left intact.
$mwhcs = & kubectl get mutatingwebhookconfigurations -o name 2>$null |
    Where-Object { $_ -match "cattle|rancher|fleet" }
$vwhcs = & kubectl get validatingwebhookconfigurations -o name 2>$null |
    Where-Object { $_ -match "cattle|rancher|fleet" }
if ($mwhcs -or $vwhcs) {
    Write-Host "  Removing Rancher webhook configurations..." -ForegroundColor Yellow
    foreach ($w in $mwhcs) { & kubectl delete $w --ignore-not-found 2>&1 | Out-Null }
    foreach ($w in $vwhcs) { & kubectl delete $w --ignore-not-found 2>&1 | Out-Null }
    Write-Host "  ✓ Rancher webhook configurations removed" -ForegroundColor Green
}

# cattle-fleet-* and fleet-* namespaces are RKE2 built-ins — they will be
# recreated automatically. Only clean up cattle-system (pure Rancher).
Remove-Namespace -Namespace "cattle-system"
Remove-Namespace -Namespace "rancher-operator-system"

# ── 9. Config Syncer / Reflector (41) — vor Proxy Config, da es Finalizer auf den Secret setzt ──
Write-Host "`n--- 9. Config Syncer (Reflector) ---" -ForegroundColor Magenta
Remove-HelmRelease -Release "reflector" -Namespace "kube-system"

# ── 10. Proxy Config (42) ───────────────────────────────────────
Write-Host "`n--- 10. Proxy Config ---" -ForegroundColor Magenta
# Explicitly remove Reflector annotation and finalizer before namespace deletion.
# Sonst re-added Reflector seinen Finalizer, solange der Pod noch läuft (Terminating-Race).
$proxySecret = & kubectl get secret proxy-config -n proxy-config --ignore-not-found 2>$null
if ($proxySecret) {
    & kubectl annotate secret proxy-config -n proxy-config `
        "reflector.v1.k8s.emberstack.com/reflection-allowed-" `
        "reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces-" 2>$null | Out-Null
    & kubectl patch secret proxy-config -n proxy-config `
        -p '{"metadata":{"finalizers":[]}}' --type=merge 2>$null | Out-Null
    & kubectl delete secret proxy-config -n proxy-config --ignore-not-found 2>$null | Out-Null
    Write-Host "  ✓ proxy-config Secret removed" -ForegroundColor Green
}
Remove-HelmRelease -Release "proxy-config" -Namespace "proxy-config"
# Namespace ist an dieser Stelle leer (Secret oben bereits gelöscht) —
# Skip api-resources loop — patch finalizer and delete directly.
$nsExists = & kubectl get namespace proxy-config --ignore-not-found 2>$null
if ($nsExists) {
    # 1. Delete first → namespace enters Terminating state
    & kubectl delete namespace proxy-config --ignore-not-found --wait=false 2>$null | Out-Null
    # 2. Now patch both finalizer fields (finalize-API only works in Terminating state)
    & kubectl patch namespace proxy-config -p '{"metadata":{"finalizers":[]}}' --type=merge --request-timeout=5s 2>$null | Out-Null
    $nsData = & kubectl get namespace proxy-config -o json --request-timeout=5s 2>$null
    if ($nsData) {
        try {
            $nsObj = $nsData | ConvertFrom-Json
            $nsObj.spec | Add-Member -Name "finalizers" -Value @() -MemberType NoteProperty -Force
            $tmpFile = New-TemporaryFile
            $nsObj | ConvertTo-Json -Depth 20 -Compress | Set-Content -Path $tmpFile.FullName -Encoding UTF8
            & kubectl replace --raw "/api/v1/namespaces/proxy-config/finalize" -f $tmpFile.FullName 2>$null | Out-Null
            Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
        } catch { }
    }
    Write-Host "  ✓ Namespace proxy-config deleted" -ForegroundColor Green
}

# ── 11. OpenBao (23) — vor Longhorn, da PVC auf Longhorn-Storage liegt ──
Write-Host "`n--- 11. OpenBao ---" -ForegroundColor Magenta

# CSS name was inconsistent across installs — try both variants.
# Direct delete (no kubectl get) to avoid hanging on stale ext.cattle.io/v1 API discovery.
& kubectl delete clustersecretstore openbao cluster-secrets `
    --ignore-not-found --request-timeout=10s 2>$null | Out-Null

# Auto-unsealer is a kubectl-applied Deployment, not managed by Helm.
& kubectl delete deployment openbao-unsealer -n openbao --ignore-not-found --wait=false 2>$null | Out-Null

# Scale StatefulSet to 0 BEFORE helm uninstall so pods stop mounting PVCs.
# With no pods, the pvc-protection controller can remove its finalizer cleanly.
# This must happen while the namespace is still Active — patching PVCs in a
# Terminating namespace always fails with "namespace not found".
$obaoNs = & kubectl get namespace openbao --ignore-not-found --request-timeout=5s 2>$null
if ($obaoNs) {
    & kubectl scale statefulset openbao -n openbao --replicas=0 --request-timeout=15s 2>$null | Out-Null
    # Force-kill any remaining pods so pvc-protection sees zero consumers immediately
    & kubectl delete pods -n openbao --all --force --grace-period=0 --request-timeout=10s 2>$null | Out-Null

    # Wait up to 20s for pod to disappear
    $elapsed = 0
    while ($elapsed -lt 20) {
        $pod = & kubectl get pod openbao-0 -n openbao --ignore-not-found --request-timeout=5s 2>$null
        if (-not $pod) { break }
        Start-Sleep -Seconds 3; $elapsed += 3
    }

    # Delete PVCs while namespace is Active — clean path for pvc-protection controller.
    # If the Longhorn admission webhook is unavailable (broken between resets), the normal
    # delete will be blocked; in that case remove the webhook configs temporarily and
    # force-patch the finalizer. Longhorn recreates its webhooks on next startup; since
    # Longhorn itself is removed in the next step this is safe.
    $obaoPvcs = & kubectl get pvc -n openbao --no-headers --request-timeout=5s 2>$null
    if ($obaoPvcs) {
        foreach ($line in ($obaoPvcs -split "`n" | Where-Object { $_ })) {
            $pvcName = ($line -split '\s+')[0]
            & kubectl delete pvc $pvcName -n openbao --wait=false --request-timeout=10s 2>$null | Out-Null

            # Give pvc-protection controller 15s to remove its finalizer on its own
            $pvcGone = $false; $elapsed = 0
            while ($elapsed -lt 15) {
                $check = & kubectl get pvc $pvcName -n openbao --ignore-not-found --request-timeout=5s 2>$null
                if (-not $check) { $pvcGone = $true; break }
                Start-Sleep -Seconds 3; $elapsed += 3
            }

            if (-not $pvcGone) {
                # pvc-protection controller is stuck — Longhorn webhook likely unavailable.
                # Remove webhook configs (safe: Longhorn is removed in the next step anyway).
                & kubectl delete validatingwebhookconfiguration longhorn-webhook-validator `
                    --ignore-not-found --request-timeout=5s 2>$null | Out-Null
                & kubectl delete mutatingwebhookconfiguration longhorn-webhook-mutator `
                    --ignore-not-found --request-timeout=5s 2>$null | Out-Null
                & kubectl patch pvc $pvcName -n openbao --type='json' `
                    -p='[{"op":"remove","path":"/metadata/finalizers/0"}]' --request-timeout=5s 2>$null | Out-Null
            }
            Write-Host "  ✓ PVC '$pvcName' removed" -ForegroundColor Green
        }
    }
}

Remove-HelmRelease -Release "openbao" -Namespace "openbao"

$obaoNsExists = & kubectl get namespace openbao --ignore-not-found --request-timeout=5s 2>$null
if ($obaoNsExists) {
    & kubectl delete namespace openbao --ignore-not-found --wait=false 2>$null | Out-Null
    & kubectl patch namespace openbao --type=merge -p '{"metadata":{"finalizers":[]}}' --request-timeout=5s 2>$null | Out-Null
    $nsData = & kubectl get namespace openbao -o json --request-timeout=5s 2>$null
    if ($nsData) {
        try {
            $nsObj = $nsData | ConvertFrom-Json
            $nsObj.spec | Add-Member -Name "finalizers" -Value @() -MemberType NoteProperty -Force
            $tmpFile = New-TemporaryFile
            $nsObj | ConvertTo-Json -Depth 20 -Compress | Set-Content -Path $tmpFile.FullName -Encoding UTF8
            & kubectl replace --raw "/api/v1/namespaces/openbao/finalize" -f $tmpFile.FullName 2>$null | Out-Null
            Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
        } catch { }
    }
    $elapsed = 0; $frames2 = @('|', '/', '-', '\'); $fi2 = 0
    while ($elapsed -lt 30) {
        $phase = & kubectl get namespace openbao -o jsonpath='{.status.phase}' --ignore-not-found 2>$null
        if (-not $phase) { break }
        Write-Host ("`r  $($frames2[$fi2++ % 4]) Waiting for openbao namespace... (${elapsed}s)") -NoNewline -ForegroundColor Cyan
        Start-Sleep -Seconds 5; $elapsed += 5
    }
    Write-Host ("`r" + (" " * 60) + "`r") -NoNewline
    if ($elapsed -ge 30) { Write-Warning "  Namespace openbao still present after 30s — check manually" }
    else { Write-Host "  ✓ Namespace openbao removed" -ForegroundColor Green }
} else {
    Write-Host "  ✓ Namespace openbao already gone" -ForegroundColor Green
}

Remove-Item (Get-OpenBaoStateFile -BaseDir $PSScriptRoot -Platform "RKE2 (On-Premise)") -Force -ErrorAction SilentlyContinue

# ── 12. Longhorn (31) — nach allen Workloads die Storage nutzen ──
Write-Host "`n--- 12. Longhorn (PVCs, CRDs, Namespace) ---" -ForegroundColor Magenta

# Longhorn webhooks must be removed before CRD cleanup — if the webhook service is
# already gone, every patch/delete request hangs 10s on webhook timeout per resource.
& kubectl delete validatingwebhookconfiguration longhorn-webhook-validator `
    --ignore-not-found --request-timeout=5s 2>$null | Out-Null
& kubectl delete mutatingwebhookconfiguration longhorn-webhook-mutator `
    --ignore-not-found --request-timeout=5s 2>$null | Out-Null

Remove-HelmRelease -Release "longhorn" -Namespace "longhorn-system"

# Remove Longhorn CRD finalizers and delete
$longhornCrdNamesRef = [ref]$null
Invoke-WithSpinner -Message "Checking for Longhorn CRDs..." -Executable "kubectl" `
    -Arguments @("get", "crd", "-o", "name", "--request-timeout=10s") -OutputVariable $longhornCrdNamesRef | Out-Null
$longhornCrdNames = $longhornCrdNamesRef.Value | Where-Object { $_ -match "longhorn\.io" } |
    ForEach-Object { ($_ -split "/")[-1] }
if ($longhornCrdNames) {
    $frames = @('|', '/', '-', '\'); $fi = 0
    foreach ($crdName in $longhornCrdNames) {
        Write-Host ("`r  $($frames[$fi++ % 4]) Clearing $crdName...") -NoNewline -ForegroundColor Cyan
        # 1. Patch all CR instances — Longhorn controller is gone so finalizers won't be
        #    processed otherwise; kubectl delete crd would hang waiting for them forever.
        $raw = & kubectl get $crdName -A -o json --request-timeout=5s 2>$null
        if ($raw) {
            try {
                $items = ($raw | ConvertFrom-Json -AsHashtable)['items']
                foreach ($item in $items) {
                    $iName = $item['metadata']['name']
                    $iNs   = $item['metadata']['namespace']
                    $nsArg = if ($iNs) { @("-n", $iNs) } else { @("--all-namespaces") }
                    & kubectl patch $crdName $iName @nsArg `
                        -p '{"metadata":{"finalizers":[]}}' --type=merge --request-timeout=5s 2>$null | Out-Null
                    & kubectl delete $crdName $iName @nsArg `
                        --ignore-not-found --request-timeout=5s 2>$null | Out-Null
                }
            } catch { }
        }
        # 2. Patch CRD finalizers, then delete with --wait=false
        & kubectl patch crd $crdName -p '{"metadata":{"finalizers":[]}}' `
            --type=merge --request-timeout=5s 2>$null | Out-Null
        & kubectl delete crd $crdName --ignore-not-found --wait=false --request-timeout=10s 2>$null | Out-Null
    }
    Write-Host ("`r" + (" " * 60) + "`r") -NoNewline
    Write-Host "  ✓ Longhorn CRDs removed" -ForegroundColor Green
}

Remove-Namespace -Namespace "longhorn-system"

# ── 14. Cert-Manager (21) ───────────────────────────────────────
Write-Host "`n--- 14. Cert-Manager ---" -ForegroundColor Magenta
Remove-HelmRelease -Release "cert-manager" -Namespace "cert-manager"
Remove-Namespace   -Namespace "cert-manager"
& kubectl delete crd -l "app.kubernetes.io/name=cert-manager" --ignore-not-found 2>&1 | Out-Null

# ── 14. MetalLB (12) ────────────────────────────────────────────
Write-Host "`n--- 14. MetalLB ---" -ForegroundColor Magenta
Remove-HelmRelease -Release "metallb" -Namespace "metallb-system"
Remove-Namespace   -Namespace "metallb-system"

# ── 15. Ingress (11) ────────────────────────────────────────────
Write-Host "`n--- 15. Ingress ---" -ForegroundColor Magenta
Remove-HelmRelease -Release "ingress-nginx" -Namespace "ingress-nginx"
Remove-HelmRelease -Release "traefik"       -Namespace "traefik"
Remove-Namespace   -Namespace "ingress-nginx"
Remove-Namespace   -Namespace "traefik"

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Stack Reset Complete" -ForegroundColor Green
Write-Host "  RKE2-Cluster läuft weiter — bereit" -ForegroundColor Green
Write-Host "  für Neuinstallation via Install-Base.ps1" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

exit 0


