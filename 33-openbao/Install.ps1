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
    Cluster base domain (from Prompt.ps1) — used as allowed_domains for the
    PKI role that issues ingress certificates (RKE2 only, see step 4 below).
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Hostname,
    [string]$Domain,
    [string]$ConfigPath
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
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

Reset-StuckHelmRelease -ReleaseName "openbao" -Namespace $Namespace

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

Write-Host ("`r" + (" " * 55) + "`r") -NoNewline
Write-Host "  ✓ Kubernetes auth configured" -ForegroundColor Green

# Per-app read policies (one per app, scoped to that app's own path only) are
# created on demand by New-CsiSecretMount when each component installs — not
# here. There is deliberately no shared catch-all policy: a role that could
# read every app's secrets defeats the point of having per-app paths at all.

# ── 4. PKI Engine + Root CA (on-prem/Kind only — cloud not wired up yet) ──
# Replaces the old manually-rotated wildcard certificate: cert-manager (see
# 31-cert-manager) signs real per-hostname certs against this root CA via
# Vault's Kubernetes-auth integration. Cloud platforms still have no
# ClusterIssuer (see Get-ClusterIssuerName) — only RKE2 and Kind run OpenBao.
if ($Platform -in @("RKE2 (On-Premise)", "Kind (Local)") -and -not [string]::IsNullOrWhiteSpace($Domain)) {
    & kubectl exec openbao-0 -n $Namespace -- sh -c "BAO_TOKEN=$rootToken bao read -field=certificate pki/cert/ca" 2>&1 | Out-Null
    $caExists = $LASTEXITCODE -eq 0

    if (-not $caExists) {
        Invoke-BaoStep "Enabling PKI secrets engine..." `
            "BAO_TOKEN=$rootToken bao secrets enable pki"
        Invoke-BaoStep "Setting PKI max lease TTL (10y)..." `
            "BAO_TOKEN=$rootToken bao secrets tune -max-lease-ttl=87600h pki"
        Invoke-BaoStep "Generating root CA..." `
            "BAO_TOKEN=$rootToken bao write -field=certificate pki/root/generate/internal common_name='$Domain' ttl=87600h"
        Invoke-BaoStep "Configuring CA URLs..." `
            ("BAO_TOKEN=$rootToken bao write pki/config/urls " +
             "issuing_certificates='http://openbao.$Namespace.svc.cluster.local:8200/v1/pki/ca' " +
             "crl_distribution_points='http://openbao.$Namespace.svc.cluster.local:8200/v1/pki/crl'")
        Write-Host ("`r" + (" " * 55) + "`r") -NoNewline
        Write-Host "  ✓ Root CA generated (10y, CN=$Domain)" -ForegroundColor Green
    } else {
        Write-Host "  ✓ Root CA already configured" -ForegroundColor Green
    }

    # require_cn=false: cert-manager's CSRs carry the hostname only as a SAN,
    # never as the Subject CN (modern best practice) — Vault must accept that.
    Invoke-BaoStep "Configuring PKI role for ingress certificates..." `
        ("BAO_TOKEN=$rootToken bao write pki/roles/ingress allowed_domains='$Domain' " +
         "allow_subdomains=true allow_bare_domains=true require_cn=false " +
         "max_ttl=720h ttl=720h key_type=rsa key_bits=2048")
    Write-Host ("`r" + (" " * 55) + "`r") -NoNewline
    Write-Host "  ✓ PKI role 'ingress' ready (*.${Domain})" -ForegroundColor Green

    # cert-manager (component 31) already installed by this point — it comes
    # earlier in the fixed install order than OpenBao (33) — so its CRDs and
    # controller ServiceAccount exist. Scoped policy: sign-only, this one role,
    # nothing else (same least-privilege convention as every other Vault-reading
    # component's own policy).
    $cmPolicyName   = "cert-manager-pki"
    $cmPolicyHcl    = @"
path "pki/sign/ingress" {
  capabilities = ["create", "update"]
}
"@
    $cmPolicyTmpFile = New-TemporaryFile
    Set-Content -Path $cmPolicyTmpFile.FullName -Value $cmPolicyHcl -Encoding UTF8 -NoNewline
    $cmRemotePolicyFile = "/tmp/cert-manager-pki-policy.hcl"
    Push-Location (Split-Path $cmPolicyTmpFile.FullName)
    & kubectl cp "./$(Split-Path $cmPolicyTmpFile.FullName -Leaf)" "${Namespace}/openbao-0:$cmRemotePolicyFile" 2>$null | Out-Null
    Pop-Location
    Remove-Item $cmPolicyTmpFile.FullName -Force -ErrorAction SilentlyContinue
    & kubectl exec openbao-0 -n $Namespace -- sh -c "BAO_TOKEN=$rootToken bao policy write $cmPolicyName $cmRemotePolicyFile" 2>$null | Out-Null
    & kubectl exec openbao-0 -n $Namespace -- rm -f $cmRemotePolicyFile 2>$null | Out-Null

    Invoke-BaoStep "Configuring Vault role for cert-manager..." `
        ("BAO_TOKEN=$rootToken bao write auth/kubernetes/role/cert-manager " +
         "bound_service_account_names=cert-manager bound_service_account_namespaces=cert-manager " +
         "policies=$cmPolicyName ttl=20m")
    Write-Host ("`r" + (" " * 55) + "`r") -NoNewline
    Write-Host "  ✓ cert-manager Vault role ready" -ForegroundColor Green

    $clusterIssuerYaml = @"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openbao-pki
spec:
  vault:
    server: http://openbao.$Namespace.svc.cluster.local:8200
    path: pki/sign/ingress
    auth:
      kubernetes:
        role: cert-manager
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager
"@
    $clusterIssuerYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ ClusterIssuer 'openbao-pki' ready" -ForegroundColor Green }
    else { Write-Warning "  Could not create ClusterIssuer 'openbao-pki' — cert-manager CRDs may not be installed yet" }
}

# ── 5. Auto-Unsealer Deployment ───────────────────────────────────
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

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
if ($Hostname) { Write-Host "  UI:          http://$Hostname" -ForegroundColor Yellow }
Write-Host "  Root token:  $StateFile" -ForegroundColor Gray
Write-Host "  Policy:      one per app, scoped to that app's own path (least privilege)" -ForegroundColor Gray
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
