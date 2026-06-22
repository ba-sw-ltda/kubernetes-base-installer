<#
.SYNOPSIS
    Install OpenBao (open-source Vault fork) with auto-unseal and ESO ClusterSecretStore.
    Runs fully unattended — init, unseal, Kubernetes-auth and ClusterSecretStore are
    configured automatically. Unseal key + root token are saved to .openbao-state.json
    AND to a Kubernetes Secret so the unsealer pod can recover after restarts.
.PARAMETER Platform
    Target platform
.PARAMETER Hostname
    DNS hostname for the OpenBao UI ingress (from Prompt.ps1)
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Hostname,
    [string]$ConfigPath
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 23 - OpenBao" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig  = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath
$ChartVersion = $FullConfig.Version
$Repository   = $FullConfig.Repository
$Namespace    = $FullConfig.Namespace
$UserConfig   = $FullConfig.UserConfig
$StateFile    = Join-Path $BaseDir ".openbao-state.json"

Write-Host "  Chart:      openbao v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Storage:    $($UserConfig.StorageSize)" -ForegroundColor Gray
Write-Host ""

# ── 1. Helm install ──────────────────────────────────────────────
$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "openbao", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null

# StatefulSet spec is immutable — delete it before upgrade so Helm can recreate with new spec.
# The PVC is preserved (no --cascade=foreground), data survives the upgrade.
$stsExists = & kubectl get statefulset openbao -n $Namespace 2>$null
if ($stsExists) {
    $exitCode = Invoke-WithSpinner -Message "Removing old StatefulSet for upgrade (PVC preserved)..." -Executable "kubectl" `
        -Arguments @("delete", "statefulset", "openbao", "-n", $Namespace, "--cascade=orphan")
    if ($exitCode -ne 0) { Write-Warning "  Could not delete StatefulSet — upgrade may fail" }
}

$storageClassLine = if ($UserConfig.StorageClass) { "    storageClass: $($UserConfig.StorageClass)" } else { "" }

$HelmValues = @"
server:
  enabled: true
  dev:
    enabled: false
  ha:
    enabled: false
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
"@

$valuesFile = New-TemporaryFile
Set-Content -Path $valuesFile.FullName -Value $HelmValues -Encoding UTF8

$exitCode = Invoke-WithSpinner -Message "Deploying OpenBao..." -Executable "helm" `
    -Arguments @("upgrade", "--install", "openbao", "openbao/openbao",
                 "--namespace", $Namespace,
                 "--version", $ChartVersion,
                 "--values", $valuesFile.FullName,
                 "--wait=false",
                 "--timeout", "5m") -ShowOutput:$verbose
Remove-Item $valuesFile.FullName -Force -ErrorAction SilentlyContinue
if ($exitCode -ne 0) { Write-Error "Failed to deploy OpenBao (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

# Wait for pod to be Running (not Ready — readiness probe fails until initialized)
$exitCode = Invoke-WithSpinner -Message "Waiting for OpenBao pod..." -Executable "kubectl" `
    -Arguments @("wait", "pod/openbao-0", "-n", $Namespace,
                 "--for=jsonpath={.status.phase}=Running", "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "OpenBao pod did not start"; exit 1 }

# Wait until the OpenBao HTTP listener is up and returns parseable JSON.
# kubectl wait only checks the pod phase, not whether the process has bound its port.
$baoStatus = $null
$elapsed   = 0
$frames0   = @('|', '/', '-', '\'); $fi0 = 0
while ($elapsed -lt 60) {
    Write-Host ("`r  $($frames0[$fi0++ % 4]) Waiting for OpenBao listener... (${elapsed}s)") -NoNewline -ForegroundColor Cyan
    $raw = & kubectl exec openbao-0 -n $Namespace -- bao status -format=json 2>$null
    $jsonStart = if ($raw) { $raw.IndexOf('{') } else { -1 }
    if ($jsonStart -ge 0) {
        $baoStatus = $raw.Substring($jsonStart) | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
        if ($baoStatus) { break }
    }
    Start-Sleep -Seconds 3; $elapsed += 3
}
Write-Host ("`r" + (" " * 55) + "`r") -NoNewline
if (-not $baoStatus -and $elapsed -ge 60) {
    Write-Error "OpenBao listener did not respond after 60s — check pod logs: kubectl logs openbao-0 -n $Namespace"
    exit 1
}
Write-Host "  ✓ Pod running" -ForegroundColor Green

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
    # kubectl prefixes output with memcache/discovery warnings (ext.cattle.io/v1 stale API) —
    # strip everything before the first '{' to get clean JSON.
    $jsonStart = $initJson.IndexOf('{')
    if ($jsonStart -gt 0) { $initJson = $initJson.Substring($jsonStart) }
    if ($initJson -notmatch '^\s*\{') {
        Write-Error "bao operator init returned unexpected output (not JSON):`n$initJson"
        exit 1
    }
    $initResult = $initJson | ConvertFrom-Json -AsHashtable
    $unsealKey  = $initResult['unseal_keys_b64'][0]
    $rootToken  = $initResult['root_token']

    # Persist state locally
    @{ UnsealKey = $unsealKey; RootToken = $rootToken } |
        ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    Write-Host "  ✓ Initialized — state saved to $StateFile" -ForegroundColor Green

    # Store unseal key in Kubernetes Secret for the auto-unsealer
    & kubectl create secret generic openbao-unseal-keys -n $Namespace `
        --from-literal=unseal-key=$unsealKey `
        --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    Write-Host "  ✓ Unseal key stored in Kubernetes Secret" -ForegroundColor Green
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
    Write-Host "  ✓ Already initialized — loaded state from $StateFile" -ForegroundColor Green
}

if ($baoStatus['sealed']) {
    Invoke-WithSpinner -Message "Unsealing OpenBao..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", $Namespace, "--",
                     "bao", "operator", "unseal", $unsealKey) | Out-Null
    Write-Host "  ✓ Unsealed" -ForegroundColor Green
} else {
    Write-Host "  ✓ Already unsealed" -ForegroundColor Green
}

# ── 3. Kubernetes Auth + CSI Policy ──────────────────────────────
$frames = @('|', '/', '-', '\'); $fi = 0

function Invoke-BaoStep { param($msg, $cmd)
    Write-Host ("`r  $($frames[$script:fi++ % 4]) $msg") -NoNewline -ForegroundColor Cyan
    & kubectl exec openbao-0 -n $Namespace -- sh -c $cmd 2>$null | Out-Null
}

Invoke-BaoStep "Enabling KV-v2 secrets engine..." `
    "BAO_TOKEN=$rootToken bao secrets enable -path=$($UserConfig.SecretsPath) kv-v2"

Invoke-BaoStep "Enabling Kubernetes auth..." `
    "BAO_TOKEN=$rootToken bao auth enable kubernetes"

$k8sHost = (& kubectl exec openbao-0 -n $Namespace -- sh -c 'echo $KUBERNETES_SERVICE_HOST' 2>$null).Trim()

Invoke-BaoStep "Configuring Kubernetes auth..." `
    "BAO_TOKEN=$rootToken bao write auth/kubernetes/config kubernetes_host='https://${k8sHost}:443'"

# Read-only policy for CSI-mounted secrets — any service account with a matching role can read
$secrPath = $UserConfig.SecretsPath
Write-Host ("`r  $($frames[$fi++ % 4]) Writing CSI read policy...") -NoNewline -ForegroundColor Cyan
& kubectl exec openbao-0 -n $Namespace -- sh -c @"
BAO_TOKEN=$rootToken bao policy write csi-readonly - << 'POLICY'
path "$secrPath/data/*" {
  capabilities = ["read","list"]
}
path "$secrPath/metadata/*" {
  capabilities = ["read","list"]
}
POLICY
"@ 2>$null | Out-Null

Invoke-BaoStep "Creating ESO Kubernetes auth role..." `
    "BAO_TOKEN=$rootToken bao write auth/kubernetes/role/external-secrets bound_service_account_names=external-secrets bound_service_account_namespaces=external-secrets policies=csi-readonly ttl=1h"

Write-Host ("`r" + (" " * 55) + "`r") -NoNewline
Write-Host "  ✓ Kubernetes auth configured" -ForegroundColor Green

# ── 5. ESO ClusterSecretStore ─────────────────────────────────────
# Wait for the ESO webhook to accept CRD requests — it takes a few seconds after
# rollout before ClusterSecretStore resources can be applied without rejection.
$framesEso = @('|', '/', '-', '\'); $fiEso = 0; $elapsedEso = 0; $esoCrdFound = $false
while ($elapsedEso -lt 30) {
    $esoCrdFound = [bool](& kubectl get crd clustersecretstores.external-secrets.io `
        --ignore-not-found --request-timeout=5s 2>$null)
    if ($esoCrdFound) { break }
    Write-Host ("`r  $($framesEso[$fiEso++ % 4]) Waiting for ESO CRDs... (${elapsedEso}s)") -NoNewline -ForegroundColor Cyan
    Start-Sleep -Seconds 5; $elapsedEso += 5
}
Write-Host ("`r" + (" " * 55) + "`r") -NoNewline

# Name 'cluster-secrets' is the canonical store name across all platforms.
# Apps reference this name regardless of whether the backend is OpenBao, AWS, Azure, or GCP.
$cssYaml = @"
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: cluster-secrets
spec:
  provider:
    vault:
      server: "http://openbao.$Namespace.svc.cluster.local:8200"
      path: "$($UserConfig.SecretsPath)"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets"
          serviceAccountRef:
            name: "external-secrets"
            namespace: "external-secrets"
"@
# Retry — ESO CRD may exist but admission webhook needs a few extra seconds after rollout
$cssCreated = $false
$framesC = @('|', '/', '-', '\'); $fiC = 0
for ($attempt = 1; $attempt -le 10; $attempt++) {
    $cssYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $cssCreated = $true; break }
    Write-Host ("`r  $($framesC[$fiC++ % 4]) Waiting for ESO webhook to accept ClusterSecretStore... (attempt $attempt/10)") -NoNewline -ForegroundColor Cyan
    Start-Sleep -Seconds 6
}
Write-Host ("`r" + (" " * 70) + "`r") -NoNewline
if ($cssCreated) { Write-Host "  ✓ ClusterSecretStore 'cluster-secrets' created" -ForegroundColor Green }
else { Write-Warning "  ClusterSecretStore creation failed — check ESO: kubectl get pods -n external-secrets" }

# ── 6. Auto-Unsealer Deployment ───────────────────────────────────
# Uses HTTP status code to detect sealed state (503=sealed) — avoids grep/cut.
# `$ escapes $ so PowerShell does not expand shell variables in this here-string.
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
        image: curlimages/curl:latest
        command: ["/bin/sh", "-c"]
        args:
        - |
          BAO_ADDR=http://openbao.$($Namespace).svc.cluster.local:8200
          while true; do
            CODE=`$(curl -s -o /dev/null -w "%{http_code}" `$BAO_ADDR/v1/sys/health 2>/dev/null || echo "000")
            if [ "`$CODE" = "503" ]; then
              KEY=`$(head -n1 /var/run/secrets/unseal/unseal-key)
              curl -sf -X PUT `$BAO_ADDR/v1/sys/unseal -d "{\"key\":\"`$KEY\"}" -o /dev/null
              echo "Unsealed OpenBao"
            fi
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
if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Auto-unsealer deployed" -ForegroundColor Green }

# ── 6. Ingress ────────────────────────────────────────────────────
if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
    $ingressYaml = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openbao
  namespace: $Namespace
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
spec:
  ingressClassName: $(Get-IngressClass)
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
    if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Ingress configured ($Hostname)" -ForegroundColor Green }
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
if ($Hostname) { Write-Host "  UI:          http://$Hostname" -ForegroundColor Yellow }
Write-Host "  Root token:  $StateFile" -ForegroundColor Gray
Write-Host "  Policy:      csi-readonly (read-only on secret/*)" -ForegroundColor Gray
Write-Host ""
Write-Host "  SecretProviderClass example:" -ForegroundColor Gray
Write-Host "    apiVersion: secrets-store.csi.x-k8s.io/v1" -ForegroundColor Yellow
Write-Host "    kind: SecretProviderClass" -ForegroundColor Yellow
Write-Host "    spec:" -ForegroundColor Yellow
Write-Host "      provider: vault" -ForegroundColor Yellow
Write-Host "      parameters:" -ForegroundColor Yellow
Write-Host "        vaultAddress: http://openbao.$($Namespace).svc.cluster.local:8200" -ForegroundColor Yellow
Write-Host "        roleName: <app-role>    # created per app" -ForegroundColor Yellow
Write-Host "        objects: |" -ForegroundColor Yellow
Write-Host "          - objectName: mypassword" -ForegroundColor Yellow
Write-Host "            secretPath: $($UserConfig.SecretsPath)/data/myapp" -ForegroundColor Yellow
Write-Host "            secretKey: password" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
