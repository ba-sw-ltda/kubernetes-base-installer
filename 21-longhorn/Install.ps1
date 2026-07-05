<#
.SYNOPSIS
    Install Longhorn distributed block storage and set it as the default StorageClass.
.DESCRIPTION
    Installs Longhorn via Helm, sets it as the default StorageClass, and removes the
    default annotation from the local-path StorageClass if present (RKE2 ships one).
.PARAMETER Platform
    Target platform
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER Hostname
    DNS hostname for the Longhorn UI ingress (e.g. storage.kubernetes.example.com)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$ConfigPath,
    [string]$Hostname = ""
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1"       -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 21 - Longhorn Storage" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName       = $FullConfig.ChartName
$ChartVersion    = $FullConfig.Version
$Repository      = $FullConfig.Repository
$Namespace       = $FullConfig.Namespace
$CreateNamespace = $FullConfig.CreateNamespace
$UserConfig      = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Replicas:   $($UserConfig.ReplicaCount)  |  Default StorageClass: yes" -ForegroundColor Gray
if ($Hostname) { Write-Host "  UI:         $Hostname" -ForegroundColor Gray }
Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "longhorn", $Repository, "--force-update") -ShowOutput:$verbose
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

$resetOk = Reset-StuckHelmRelease -ReleaseName "longhorn" -Namespace $Namespace
if ($resetOk -eq $false) { Write-Error "Could not reset Longhorn release — aborting"; exit 1 }

# Remove leftover Longhorn hook jobs — Helm never cleans up failed hook jobs automatically
& kubectl delete job longhorn-pre-upgrade  -n $Namespace --ignore-not-found 2>&1 | Out-Null
& kubectl delete job longhorn-uninstall    -n $Namespace --ignore-not-found 2>&1 | Out-Null

# Remove finalizers from any Longhorn CRDs stuck in Terminating state.
# This happens when a previous install failed: the Longhorn controller never ran to clean up
# instances, so the CRD finalizer was never removed. Without this step the CRDs stay in
# Terminating indefinitely and the new manager cannot start.
$allCrds = & kubectl get crd -o json 2>$null | ConvertFrom-Json -AsHashtable
$stuckCrds = $allCrds['items'] | Where-Object {
    $_['metadata']['name'] -like "*.longhorn.io" -and $_['metadata']['deletionTimestamp']
}
foreach ($crd in $stuckCrds) {
    & kubectl patch crd $crd['metadata']['name'] `
        -p '{"metadata":{"finalizers":[]}}' --type=merge 2>$null | Out-Null
    Write-Host "  ✓ Removed finalizer from stuck CRD: $($crd['metadata']['name'])" -ForegroundColor Yellow
}
if ($stuckCrds) {
    Write-Host "  Waiting for stuck CRDs to clear..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
}

# Longhorn manages CRDs via a hook job (not in crds/ dir) so helm show crds returns nothing.
# Apply them explicitly via helm template --include-crds so the correct API versions are always
# registered before the manager starts — Helm never updates CRDs on its own.
$crdYaml = ""
$exitCode = Invoke-WithSpinner -Message "Applying Longhorn CRDs..." -Executable "helm" `
    -Arguments @("template", "longhorn", "longhorn/$ChartName", "--version", $ChartVersion,
                 "--include-crds", "--namespace", $Namespace) `
    -ShowOutput:$false -OutputVariable ([ref]$crdYaml)
if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($crdYaml)) {
    $crdOnly = ($crdYaml -split "(?m)^---") | Where-Object { $_ -match "kind:\s*CustomResourceDefinition" }
    if ($crdOnly) {
        ($crdOnly -join "`n---`n") | & kubectl apply --server-side --force-conflicts -f - 2>&1 | Out-Null
        Write-Host "  ✓ CRDs applied" -ForegroundColor Green
    }
}

$HelmArgs = @(
    "upgrade", "--install", "longhorn", "longhorn/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "persistence.defaultClass=true",
    "--set", "persistence.defaultClassReplicaCount=$($UserConfig.ReplicaCount)",
    "--set", "defaultSettings.defaultReplicaCount=$($UserConfig.ReplicaCount)"
)

$exitCode = Invoke-WithSpinner -Message "Deploying Longhorn..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy Longhorn (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for longhorn-manager (up to 20m)..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "daemonset/longhorn-manager", "-n", $Namespace, "--timeout=20m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "  ── Pod status ──────────────────────────────" -ForegroundColor DarkGray
    & kubectl get pods -n $Namespace -l "app=longhorn-manager" 2>&1 | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "  ── Recent events ───────────────────────────" -ForegroundColor DarkGray
    & kubectl get events -n $Namespace --sort-by='.lastTimestamp' --field-selector type=Warning 2>&1 | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "  Tip: Longhorn requires open-iscsi on all nodes:" -ForegroundColor Yellow
    Write-Host "    apt-get install -y open-iscsi && systemctl enable --now iscsid" -ForegroundColor Yellow
    Write-Error "Rollout of longhorn-manager did not complete"
    exit 1
}
Write-Host "  ✓ longhorn-manager ready" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for longhorn-driver-deployer..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/longhorn-driver-deployer", "-n", $Namespace, "--timeout=15m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of longhorn-driver-deployer did not complete"; exit 1 }
Write-Host "  ✓ longhorn-driver-deployer ready" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for longhorn-ui..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/longhorn-ui", "-n", $Namespace, "--timeout=15m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of longhorn-ui did not complete"; exit 1 }
Write-Host "  ✓ longhorn-ui ready" -ForegroundColor Green

# Remove default annotation from local-path StorageClass (RKE2 ships with it as default)
$lpExists = & kubectl get storageclass local-path --ignore-not-found 2>&1
if ($lpExists) {
    $patch = '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    & kubectl patch storageclass local-path -p $patch 2>&1 | Out-Null
    Write-Host "  ✓ local-path StorageClass de-defaulted" -ForegroundColor Green
}

# Ingress for Longhorn UI
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    $protect = Protect-ComponentIngress -Hostname $Hostname -Platform $Platform
    $authAnnotations = ($protect.Annotations.GetEnumerator() | ForEach-Object { "    $($_.Key): `"$($_.Value)`"" }) -join "`n"

    $ingressYaml = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ui
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
            name: longhorn-frontend
            port:
              number: 80
"@
    $applyOut = $ingressYaml | & kubectl apply -f - 2>&1
    if ($LASTEXITCODE -ne 0) {
        foreach ($line in $applyOut) { Write-Host $line -ForegroundColor Red }
        Write-Error "Failed to create Longhorn UI Ingress"; exit 1
    }
    Write-Host "  ✓ Ingress configured ($Hostname)" -ForegroundColor Green
    $scheme = if (-not [string]::IsNullOrWhiteSpace($protect.TlsBlock)) { "https" } else { "http" }
    $portalIcon = Get-PortalIconDataUri -ScriptRoot $ScriptRoot -IconFile $FullConfig.PortalIcon
    Register-PortalEntry -Name $FullConfig.PortalTitle -Url "${scheme}://$Hostname" `
        -Category "Storage" -Subtitle $FullConfig.PortalSubtitle -Order 21 `
        -InternalUrl "http://longhorn-frontend.longhorn-system.svc.cluster.local" `
        -LogoUrl $portalIcon
}

if ($verbose) {
    Write-Host ""
    & kubectl get storageclass
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
Write-Host "  Default StorageClass: longhorn" -ForegroundColor Gray
Write-Host ""
Write-Host "  Use Longhorn explicitly:" -ForegroundColor Gray
Write-Host "    storageClassName: longhorn" -ForegroundColor Yellow
Write-Host ""
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    Write-Host "  Longhorn UI:  http://$Hostname" -ForegroundColor Yellow
} else {
    Write-Host "  Longhorn UI (port-forward):" -ForegroundColor Gray
    Write-Host "    kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80" -ForegroundColor Yellow
    Write-Host "    → http://localhost:8080" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Node prerequisite (open-iscsi must be installed on all nodes):" -ForegroundColor Gray
Write-Host "    apt-get install -y open-iscsi && systemctl enable --now iscsid   # Debian/Ubuntu" -ForegroundColor Yellow
Write-Host "    yum install -y iscsi-initiator-utils && systemctl enable --now iscsid  # RHEL/Rocky" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0

