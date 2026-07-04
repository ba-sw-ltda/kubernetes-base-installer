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
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Hostname,
    [string]$Domain,
    [array] $PKIs = @(),
    [string]$ConfigPath
)

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

Write-Host "  Chart:      openbao v$ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Storage:    $($UserConfig.StorageSize)" -ForegroundColor Gray
if ($PKIs.Count -gt 0) {
    Write-Host "  PKIs:       $($PKIs.Count) definiert ($( ($PKIs | ForEach-Object { $_.Name }) -join ', '))" -ForegroundColor Gray
}
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
    $jsonStart = $initJson.IndexOf('{')
    if ($jsonStart -gt 0) { $initJson = $initJson.Substring($jsonStart) }
    if ($initJson -notmatch '^\s*\{') {
        Write-Error "bao operator init returned unexpected output (not JSON):`n$initJson"; exit 1
    }
    $initResult = $initJson | ConvertFrom-Json -AsHashtable
    $unsealKey  = $initResult['unseal_keys_b64'][0]
    $rootToken  = $initResult['root_token']

    @{ UnsealKey = $unsealKey; RootToken = $rootToken } |
        ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    Write-Host "  ✓ Initialized — state saved to $StateFile" -ForegroundColor Green

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

Write-Host "  ✓ Kubernetes auth configured" -ForegroundColor Green

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
    Write-Host "  Keine PKIs definiert — PKI-Engine wird nicht aktiviert (kein TLS, kein ClusterIssuer)." -ForegroundColor Yellow
}

# The old single ClusterIssuer "openbao-pki" is intentionally NOT deleted here.
# Existing ingresses (Longhorn, Authelia, Rancher) still reference it and cert-manager
# would immediately fail to renew their certs if it disappears. Each component
# migrates to "openbao-pki-<name>" the next time its own Install.ps1 is re-run.
$oldIssuerExists = & kubectl get clusterissuer openbao-pki --ignore-not-found 2>$null
if ($oldIssuerExists -and ($PKIs | Where-Object { "HTTP" -in @($_.Roles) -and $_.MountPath -ne "pki" })) {
    Write-Host "  ℹ  Alter ClusterIssuer 'openbao-pki' bleibt erhalten." -ForegroundColor DarkGray
    Write-Host "     Komponenten migrieren beim nächsten Re-Install auf 'openbao-pki-<name>'." -ForegroundColor DarkGray
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

    Write-Host ""
    Write-Host "  ────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  PKI: $pkiName  ($pkiType · $mountPath)" -ForegroundColor Cyan

    # Skip if this is a pending external intermediate — Complete-PkiIntermediate handles it
    if ($currentStatus -eq "PendingCSR") {
        Write-Host "  ⏸ Status PendingCSR — warte auf externes Zertifikat (Complete-PkiIntermediate.ps1)" -ForegroundColor Yellow
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

    # Check if CA already exists on this mount (expected to return non-0 when CA not yet created)
    $caCheckExit = Invoke-WithSpinner -Message "Checking CA on $mountPath..." -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", $Namespace, "--", "sh", "-c",
                     "BAO_TOKEN=$rootToken bao read -field=certificate $mountPath/cert/ca 2>/dev/null")
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
            Write-Host "  ✓ Root CA erstellt (10y, CN=$cn)" -ForegroundColor Green
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
                Write-Host "  · Uploading CSR to pod..." -ForegroundColor DarkGray
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
                Write-Host "  · Uploading signed certificate to pod..." -ForegroundColor DarkGray
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
                Write-Host "  ✓ Intermediate CA signiert und importiert (Parent: $parentMount)" -ForegroundColor Green
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
                Write-Host "  ✓ CSR generiert und exportiert nach:" -ForegroundColor Green
                Write-Host "    $csrExportPath" -ForegroundColor Yellow
                Write-Host "  → Lasse die CSR von deiner Corporate CA signieren," -ForegroundColor DarkGray
                Write-Host "    dann: .\33-openbao\Complete-PkiIntermediate.ps1 -Platform $Platform" -ForegroundColor DarkGray

                $pki['Status']        = "PendingCSR"
                $pki['CSRExportPath'] = $csrExportPath
                $pkiResults.Add($pki) | Out-Null
                continue
            }
        }
    } else {
        Write-Host "  ✓ CA bereits vorhanden" -ForegroundColor Green
    }

    # ── Configure PKI roles ──────────────────────────────────────
    if ("HTTP" -in $roles) {
        # require_cn=false: cert-manager CSRs carry the hostname as SAN only (modern best practice)
        Invoke-BaoCmd "Configuring HTTP role (ServerAuth)..." `
            ("BAO_TOKEN=$rootToken bao write $mountPath/roles/http " +
             "allowed_domains='$Domain' allow_subdomains=true allow_bare_domains=true allow_any_name=false " +
             "require_cn=false max_ttl=720h ttl=720h key_type=rsa key_bits=2048 " +
             "key_usage='DigitalSignature,KeyEncipherment' ext_key_usage='ServerAuth'")
        Write-Host "  ✓ Rolle 'http' (ServerAuth, *.${Domain})" -ForegroundColor Green
    }

    if ("mTLS" -in $roles) {
        $ttlH = if ($pki.mTlsTtlHours) { [int]$pki.mTlsTtlHours } else { 336 }
        # allow_any_name=true: device identity (VIN, serial) goes in CN at issuance time
        Invoke-BaoCmd "Configuring mTLS role (ClientAuth, TTL=${ttlH}h)..." `
            ("BAO_TOKEN=$rootToken bao write $mountPath/roles/mtls " +
             "allow_any_name=true enforce_hostnames=false require_cn=true " +
             "max_ttl=${ttlH}h ttl=${ttlH}h key_type=rsa key_bits=2048 " +
             "key_usage='DigitalSignature' ext_key_usage='ClientAuth' no_store=false")
        Write-Host "  ✓ Rolle 'mtls' (ClientAuth, TTL=${ttlH}h)" -ForegroundColor Green

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
        Write-Host "  ✓ AppRole '$pkiName-enroll' bereit (Einmal-Token, 1h TTL)" -ForegroundColor Green
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
        $clusterIssuerYaml | & kubectl apply -f - 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ ClusterIssuer '$issuerName' bereit" -ForegroundColor Green
        } else {
            Write-Warning "  ClusterIssuer '$issuerName' konnte nicht angelegt werden — cert-manager CRDs fehlen noch?"
        }
    }

    $pki['Status'] = "Active"
    $pkiResults.Add($pki) | Out-Null
}

# ── 5. Persist PKI state ──────────────────────────────────────────
if ($pkiResults.Count -gt 0) {
    Save-OpenBaoPkis -PKIs @($pkiResults | ForEach-Object { [hashtable]$_ }) -BaseDir $BaseDir -Platform $Platform
    Write-Host ""
    Write-Host "  ✓ PKI-Status gespeichert ($StateFile)" -ForegroundColor Green
}

# ── 6. Auto-Unsealer Deployment ───────────────────────────────────
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

# ── 7. Ingress ────────────────────────────────────────────────────
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
    $portalIcon = Get-PortalIconDataUri -ScriptRoot $ScriptRoot -IconFile $FullConfig.PortalIcon
    Register-PortalEntry -Name $FullConfig.PortalTitle -Url "https://$Hostname" `
        -Category "Security" -Subtitle $FullConfig.PortalSubtitle -Order 33 `
        -InternalUrl "http://openbao.openbao.svc.cluster.local:8200" `
        -LogoUrl $portalIcon
}

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

# ── Summary ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
if ($Hostname) { Write-Host "  UI:         http://$Hostname" -ForegroundColor Yellow }
Write-Host "  Root token: $StateFile" -ForegroundColor Gray
Write-Host ""
Write-Host "  PKI Übersicht:" -ForegroundColor Gray
foreach ($r in $pkiResults) {
    $default = if ($r.IsDefault) { " [DEFAULT]" } else { "" }
    $roles   = (@($r.Roles) -join ", ")
    Write-Host "    $($r.Name)$default  $($r.Type) · $roles · $($r.Status)" -ForegroundColor $(
        if ($r.Status -eq "PendingCSR") { "Yellow" } else { "Green" })
}
$pendingList = @($pkiResults | Where-Object { $_.Status -eq "PendingCSR" })
if ($pendingList.Count -gt 0) {
    Write-Host ""
    Write-Host "  Ausstehende Intermediate CAs (Extern):" -ForegroundColor Yellow
    foreach ($p in $pendingList) {
        Write-Host "    $($p.Name) — CSR: $($p.CSRExportPath)" -ForegroundColor Yellow
    }
    Write-Host "  → Nach Signierung: .\33-openbao\Complete-PkiIntermediate.ps1 -Platform $Platform" -ForegroundColor DarkGray
}
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
