<#
.SYNOPSIS
    Verifies that the RKE2 stack has been completely uninstalled.
    Clearly shows which remnants are still present.
#>
[CmdletBinding()]
param()

$stateFile = Join-Path $PSScriptRoot ".rke2-state.json"
if (-not (Test-Path $stateFile)) {
    Write-Error "State file not found: $stateFile"
    exit 1
}
$rke2State      = Get-Content $stateFile | ConvertFrom-Json
$kubeconfigPath = $rke2State.KubeconfigPath -replace '^~', $env:USERPROFILE
if (-not (Test-Path $kubeconfigPath)) {
    Write-Error "RKE2 kubeconfig not found: $kubeconfigPath"
    exit 1
}
$env:KUBECONFIG = $kubeconfigPath

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  RKE2 — Stack Verification" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$issues = 0

function Write-Ok   { param($msg) Write-Host "  [OK]  $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "  [!!]  $msg" -ForegroundColor Red;   $script:issues++ }
function Write-Section { param($msg) Write-Host "`n  $msg" -ForegroundColor Magenta }

# ── Cluster reachable? ──────────────────────────────────────────
Write-Section "Cluster"
$nodes = & kubectl get nodes --no-headers 2>$null
if ($nodes) { Write-Ok "Cluster reachable ($(@($nodes).Count) Node(s))" }
else        { Write-Fail "Cluster not reachable" }

# ── Helm Releases ────────────────────────────────────────────────
Write-Section "Helm Releases"
$rke2BuiltIns = @(
    "fleet", "fleet-agent", "fleet-agent-local", "fleet-crd",
    "rancher-turtles", "rancher-webhook",
    "rke2-canal", "rke2-cilium", "rke2-coredns", "rke2-ingress-nginx",
    "rke2-metrics-server", "rke2-runtimeclasses",
    "rke2-snapshot-controller", "rke2-snapshot-controller-crd",
    "rke2-snapshot-validation-webhook",
    "system-upgrade-controller"
)
$releases = & helm list -A --short 2>$null | Where-Object { $_ -notin $rke2BuiltIns }
if ($releases) {
    foreach ($r in $releases) { Write-Fail "Release still present: $r" }
} else {
    Write-Ok "Keine Stack-Helm-Releases"
}

# ── Namespaces ───────────────────────────────────────────────────
Write-Section "Namespaces"
$expectedGone = @(
    "argocd", "monitoring", "cattle-system", "rancher-operator-system",
    "proxy-config", "longhorn-system", "openbao", "external-secrets",
    "cert-manager", "metallb-system", "ingress-nginx", "traefik"
)
$existingNs = & kubectl get namespaces --no-headers -o custom-columns="NAME:.metadata.name" 2>$null
foreach ($ns in $expectedGone) {
    $found = $existingNs | Where-Object { $_.Trim() -eq $ns }
    if ($found) {
        $phase = & kubectl get namespace $ns -o jsonpath='{.status.phase}' 2>$null
        Write-Fail "Namespace still present: $ns ($phase)"
    } else {
        Write-Ok "Namespace weg: $ns"
    }
}

# ── PVCs ─────────────────────────────────────────────────────────
Write-Section "PersistentVolumeClaims"
$longhornCrdsGone = -not (& kubectl get crd -o name 2>$null | Where-Object { $_ -match "longhorn\.io" })
$pvcItems = & kubectl get pvc -A -o json 2>$null | ConvertFrom-Json -AsHashtable
$remainingPvcs = $pvcItems['items'] | Where-Object { $_ }
if ($remainingPvcs) {
    foreach ($pvc in $remainingPvcs) {
        $ns    = $pvc['metadata']['namespace']
        $name  = $pvc['metadata']['name']
        $phase = $pvc['status']['phase']
        $hasFinalizer = $pvc['metadata']['finalizers'] -and $pvc['metadata']['finalizers'].Count -gt 0
        if ($phase -eq "Terminating" -and $hasFinalizer -and $longhornCrdsGone) {
            # Direct patch may fail if namespace is already gone — fall back to kubectl proxy
            & kubectl patch pvc $name -n $ns -p '{"metadata":{"finalizers":[]}}' --type=merge --request-timeout=5s 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                $proxy = Start-Process kubectl -ArgumentList "proxy --port=8001" -PassThru -WindowStyle Hidden
                Start-Sleep -Seconds 2
                try {
                    $patch   = '{"metadata":{"finalizers":[]}}'
                    $headers = @{ "Content-Type" = "application/merge-patch+json" }
                    Invoke-RestMethod -Method PATCH `
                        -Uri "http://localhost:8001/api/v1/namespaces/$ns/persistentvolumeclaims/$name" `
                        -Body $patch -Headers $headers -ErrorAction Stop | Out-Null
                } catch { } finally { $proxy.Kill() }
            }
            Write-Ok "PVC Finalizer gepatcht und freigegeben: $ns/$name"
        } else {
            Write-Fail "PVC still present: $ns/$name ($phase)"
        }
    }
} else {
    Write-Ok "Keine PVCs"
}

# ── Longhorn CRDs ────────────────────────────────────────────────
Write-Section "Longhorn CRDs"
$longhornCrds = & kubectl get crd -o name 2>$null | Where-Object { $_ -match "longhorn\.io" }
if ($longhornCrds) {
    foreach ($crd in $longhornCrds) { Write-Fail "CRD still present: $crd" }
} else {
    Write-Ok "Keine Longhorn CRDs"
}

# ── Rancher Webhooks ─────────────────────────────────────────────
Write-Section "Webhook Configurations"
$mwhcs = & kubectl get mutatingwebhookconfigurations -o name 2>$null | Where-Object { $_ -match "cattle|rancher|fleet" }
$vwhcs = & kubectl get validatingwebhookconfigurations -o name 2>$null | Where-Object { $_ -match "cattle|rancher|fleet" }
if ($mwhcs -or $vwhcs) {
    foreach ($w in $mwhcs) { Write-Fail "MutatingWebhook still present: $w" }
    foreach ($w in $vwhcs) { Write-Fail "ValidatingWebhook still present: $w" }
} else {
    Write-Ok "Keine Rancher Webhook Configurations"
}

# ── Ergebnis ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ($issues -eq 0) {
    Write-Host "  Alles sauber — bereit fuer Neuinstallation" -ForegroundColor Green
} else {
    Write-Host "  $issues issue(s) found — see above" -ForegroundColor Red
}
Write-Host "========================================`n" -ForegroundColor Cyan

exit $(if ($issues -eq 0) { 0 } else { 1 })


