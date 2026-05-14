<#
.SYNOPSIS
    Stores a wildcard PFX certificate in OpenBao and creates an ExternalSecret
    so ESO syncs it as a K8s TLS Secret 'wildcard-tls' in the cert-manager namespace.
    Reflector then distributes it to all opt-in namespaces.

    Renewal: update tls.crt + tls.key in the OpenBao UI — ESO picks it up automatically.
.PARAMETER Platform
    Target platform
.PARAMETER PfxPath
    Full path to the .pfx file
.PARAMETER PfxPassword
    Password for the .pfx file (empty string if none)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$PfxPath = "",
    [System.Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidUsingPlainTextForPassword', '')]
    [string]$PfxPassword = ""
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

if ($Platform -eq "Kind (Local)") { exit 0 }

$FullConfig = Import-PowerShellDataFile "$ScriptRoot\Config.psd1"
$Namespace  = $FullConfig.Namespace
$SecretName = $FullConfig.UserConfig.SecretName
$VaultPath  = $FullConfig.UserConfig.VaultPath

# Standalone: prompt if parameters are missing
if ([string]::IsNullOrWhiteSpace($PfxPath)) {
    $inputs = & "$ScriptRoot\Prompt.ps1" -Platform $Platform
    if (-not $inputs -or -not $inputs.PfxPath) { exit 0 }
    $PfxPath     = $inputs.PfxPath
    $PfxPassword = $inputs.PfxPassword
}

if ([string]::IsNullOrWhiteSpace($PfxPath)) { exit 0 }

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 24 - Wildcard TLS Certificate" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "  PFX:        $PfxPath" -ForegroundColor Gray
Write-Host "  Vault Path: $VaultPath" -ForegroundColor Gray
Write-Host "  Secret:     $SecretName  (Namespace: $Namespace)" -ForegroundColor Gray
Write-Host ""

# ── 1. PFX → PEM konvertieren ────────────────────────────────────
Write-Host "  Converting PFX..." -ForegroundColor Cyan
try {
    $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
             [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet

    $collection = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $collection.Import($PfxPath, $PfxPassword, $flags)
} catch {
    Write-Error "Could not load PFX — correct password?`n$_"
    exit 1
}

# Leaf certificate (has private key)
$leafCert = $collection | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
if (-not $leafCert) {
    Write-Error "No certificate with private key found in PFX file."
    exit 1
}

# Intermediate certificates (no private key) — for complete chain
$chainCerts = @($collection | Where-Object { -not $_.HasPrivateKey })

# tls.crt = leaf + intermediates as PEM chain
$pemParts = @()
$pemParts += "-----BEGIN CERTIFICATE-----"
$pemParts += [Convert]::ToBase64String($leafCert.RawData, [Base64FormattingOptions]::InsertLineBreaks)
$pemParts += "-----END CERTIFICATE-----"
foreach ($c in $chainCerts) {
    $pemParts += "-----BEGIN CERTIFICATE-----"
    $pemParts += [Convert]::ToBase64String($c.RawData, [Base64FormattingOptions]::InsertLineBreaks)
    $pemParts += "-----END CERTIFICATE-----"
}
$tlsCrt = $pemParts -join "`n"

# tls.key = PKCS#8 Private Key
try {
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($leafCert)
    $keyBytes = $rsa.ExportPkcs8PrivateKey()
} catch {
    Write-Error "Could not export private key — key algorithm supported?`n$_"
    exit 1
}
$tlsKey = @(
    "-----BEGIN PRIVATE KEY-----"
    [Convert]::ToBase64String($keyBytes, [Base64FormattingOptions]::InsertLineBreaks)
    "-----END PRIVATE KEY-----"
) -join "`n"

$subject = $leafCert.Subject
$expiry  = $leafCert.NotAfter.ToString("yyyy-MM-dd")
Write-Host "  ✓ Converted  ($subject  —  valid until $expiry)" -ForegroundColor Green

# ── 2. Store in OpenBao ─────────────────────────────────────────
# Write-ClusterSecret uses key=value shell args — unusable for multiline PEM data.
# Instead: base64-encode each PEM value, decode inside the container to temp files,
# then use 'bao kv put key=@file' which reads the raw file content as the value.
$baoStateFile = Join-Path $BaseDir ".openbao-state.json"
if (-not (Test-Path $baoStateFile)) {
    Write-Error "OpenBao state file not found ($baoStateFile) — is 23-openbao installed?"
    exit 1
}
$rootToken = (Get-Content $baoStateFile | ConvertFrom-Json).RootToken
if (-not $rootToken) {
    Write-Error "Root token not in state file — reinstall OpenBao."
    exit 1
}

$podStatus = & kubectl get pod openbao-0 -n openbao `
    --no-headers -o custom-columns="S:.status.phase" --request-timeout=5s 2>$null
if ($podStatus -ne "Running") {
    Write-Error "OpenBao pod is not running (status: $podStatus)"
    exit 1
}

# Base64-encode PEM data to a single line for safe transfer as shell argument
$certB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tlsCrt))
$keyB64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tlsKey))

$shellCmd = @"
printf '%s' '$certB64' | base64 -d > /tmp/_wc_cert.pem && \
printf '%s' '$keyB64'  | base64 -d > /tmp/_wc_key.pem  && \
BAO_TOKEN=$rootToken bao kv put secret/$VaultPath tls.crt=@/tmp/_wc_cert.pem tls.key=@/tmp/_wc_key.pem ; \
rm -f /tmp/_wc_cert.pem /tmp/_wc_key.pem
"@

# Invoke-WithSpinner is a PowerShell cmdlet — $LASTEXITCODE is not updated, capture return value.

$exitCode = Invoke-WithSpinner -Message "Storing certificate in OpenBao..." -Executable "kubectl" `
    -Arguments @("exec", "openbao-0", "-n", "openbao", "--", "sh", "-c", $shellCmd)
if ($exitCode -ne 0) {
    Write-Error "Error writing to OpenBao (exit $exitCode)"
    exit 1
}
Write-Host "  ✓ Certificate stored in OpenBao ($VaultPath)" -ForegroundColor Green

# ── 3. Create ExternalSecret — ESO syncs Vault → K8s TLS Secret ───
# ClusterSecretStore 'cluster-secrets' is created by OpenBao (23), but the
# ESO webhook needs a moment after rollout before it accepts CRD resources.
# Wait until the store is available before creating the ExternalSecret.
$frames3 = @('|', '/', '-', '\'); $fi3 = 0; $elapsed3 = 0
while ($elapsed3 -lt 60) {
    $css = & kubectl get clustersecretstore cluster-secrets --ignore-not-found --request-timeout=5s 2>$null
    if ($css) { break }
    Write-Host ("`r  $($frames3[$fi3++ % 4]) Waiting for ClusterSecretStore... (${elapsed3}s)") -NoNewline -ForegroundColor Cyan
    Start-Sleep -Seconds 5; $elapsed3 += 5
}
Write-Host ("`r" + (" " * 60) + "`r") -NoNewline
if (-not $css) {
    Write-Error "ClusterSecretStore 'cluster-secrets' not found — is 23-openbao installed and ESO ready?"
    exit 1
}

$esYaml = @"
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: $SecretName
  namespace: $Namespace
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: cluster-secrets
    kind: ClusterSecretStore
  target:
    name: $SecretName
    template:
      type: kubernetes.io/tls
      metadata:
        annotations:
          reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
          reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: ""
  data:
    - secretKey: tls.crt
      remoteRef:
        key: $VaultPath
        property: tls.crt
    - secretKey: tls.key
      remoteRef:
        key: $VaultPath
        property: tls.key
"@

$esYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "ExternalSecret could not be created"
    exit 1
}
Write-Host "  ✓ ExternalSecret '$SecretName' created" -ForegroundColor Green

# Kurz warten bis ESO das Secret synct
$elapsed = 0
$frames  = @('|', '/', '-', '\'); $fi = 0
while ($elapsed -lt 60) {
    Write-Host ("`r  $($frames[$fi++ % 4]) Waiting for ESO to sync secret... (${elapsed}s)") -NoNewline -ForegroundColor Cyan
    $secret = & kubectl get secret $SecretName -n $Namespace --ignore-not-found --request-timeout=5s 2>$null
    if ($secret) { break }
    Start-Sleep -Seconds 5; $elapsed += 5
}
Write-Host ("`r" + (" " * 60) + "`r") -NoNewline
if (-not $secret) {
    Write-Warning "  Secret '$SecretName' not yet available — ESO may still be syncing. Check: kubectl get externalsecret $SecretName -n $Namespace"
} else {
    Write-Host "  ✓ Secret '$SecretName' synced" -ForegroundColor Green
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Vault Path:  $VaultPath  (tls.crt / tls.key)" -ForegroundColor Gray
Write-Host "  K8s Secret:  $SecretName  (Namespace: $Namespace)" -ForegroundColor Gray
Write-Host ""
Write-Host "  Namespace opt-in (Annotation auf neuem Secret im Ziel-NS):" -ForegroundColor Gray
Write-Host "    reflector.v1.k8s.emberstack.com/reflects: `"$Namespace/$SecretName`"" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Ingress TLS:" -ForegroundColor Gray
Write-Host "    tls:" -ForegroundColor Yellow
Write-Host "      - hosts: [*.example.com]" -ForegroundColor Yellow
Write-Host "        secretName: $SecretName" -ForegroundColor Yellow
Write-Host "  Renewal: update tls.crt + tls.key in the OpenBao UI — ESO syncs automatically." -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0



