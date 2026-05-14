<#
.SYNOPSIS
    Rotate the wildcard TLS certificate — platform-agnostic.
    Loads a new PFX, writes tls.crt + tls.key to the vault backend,
    and forces an immediate ESO resync of the 'wildcard-tls' secret.
    No kubectl knowledge required — just provide the new PFX file.
#>
[CmdletBinding()]
param()

$BaseDir = $PSScriptRoot
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

trap {
    Write-Host "`n`n  Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    exit 1
}

$VaultPath  = "infrastructure/wildcard-tls"
$SecretName = "wildcard-tls"
$Namespace  = "cert-manager"

# ── 1. Select platform ───────────────────────────────────────────
$platforms = @()
if (Test-Path (Join-Path $BaseDir ".rke2-state.json")) { $platforms += @{ Label = "RKE2 (On-Premise)"; Value = "RKE2 (On-Premise)" } }
if (Test-Path (Join-Path $BaseDir ".kind-state.json")) { $platforms += @{ Label = "Kind (Local)";       Value = "Kind (Local)" } }
if (Test-Path (Join-Path $BaseDir ".aks-state.json"))  { $platforms += @{ Label = "Azure AKS";          Value = "Azure AKS" } }
if (Test-Path (Join-Path $BaseDir ".eks-state.json"))  { $platforms += @{ Label = "AWS EKS";            Value = "AWS EKS" } }
if (Test-Path (Join-Path $BaseDir ".gke-state.json"))  { $platforms += @{ Label = "Google GKE";         Value = "Google GKE" } }

if ($platforms.Count -eq 0) { Write-Host "  No installed clusters found." -ForegroundColor Red; exit 1 }

$platform = if ($platforms.Count -eq 1) { $platforms[0].Value } else {
    Read-SelectValue `
        -Title "Select cluster" `
        -Message "On which cluster should the certificate be rotated?" `
        -Options $platforms -Default 0 `
        -ContextTitle "Certificate Rotation" `
        -ContextHint "Multiple installed clusters found"
}
if (-not $platform) { exit 0 }

Set-ClusterContext -BaseDir $BaseDir -Platform $platform

# ── 2. Display current certificate ──────────────────────────────
Clear-Host
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Certificate Rotation" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$existingSecret = & kubectl get secret $SecretName -n $Namespace --ignore-not-found --request-timeout=5s 2>$null
if ($existingSecret) {
    try {
        $certB64     = & kubectl get secret $SecretName -n $Namespace -o jsonpath='{.data.tls\.crt}' 2>$null
        $certBytes   = [Convert]::FromBase64String($certB64)
        $currentCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
        $san         = ($currentCert.Extensions |
            Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }).Format($false)
        Write-Host "  Current certificate:" -ForegroundColor Gray
        Write-Host "    Subject:  $($currentCert.Subject)" -ForegroundColor White
        Write-Host "    Valid:    $($currentCert.NotBefore.ToString('yyyy-MM-dd'))  –  $($currentCert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor White
        Write-Host "    SANs:     $san" -ForegroundColor White
        $daysLeft    = ($currentCert.NotAfter - (Get-Date)).Days
        $expiryColor = if ($daysLeft -lt 30) { "Red" } elseif ($daysLeft -lt 90) { "Yellow" } else { "Green" }
        Write-Host "    Expires:  in $daysLeft days" -ForegroundColor $expiryColor
    } catch { Write-Host "  (Could not read certificate details)" -ForegroundColor DarkGray }
} else {
    Write-Host "  No '$SecretName' secret found in '$Namespace' — first installation?" -ForegroundColor Yellow
}
Write-Host ""

# ── 3. Check vault connection ────────────────────────────────────
$rootToken = $null
switch ($platform) {
    { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
        $baoState = Join-Path $BaseDir ".openbao-state.json"
        if (-not (Test-Path $baoState)) {
            Write-Host "  OpenBao state file not found." -ForegroundColor Red; exit 1
        }
        $rootToken = (Get-Content $baoState | ConvertFrom-Json).RootToken
        $podStatus = & kubectl get pod openbao-0 -n openbao `
            --no-headers -o custom-columns="S:.status.phase" --request-timeout=5s 2>$null
        if ($podStatus -ne "Running") {
            Write-Host "  OpenBao pod is not running (status: $podStatus)" -ForegroundColor Red; exit 1
        }
    }
    default {
        Write-Host "  Certificate rotation for $platform not yet implemented." -ForegroundColor Red; exit 1
    }
}

# ── 4. Request new PFX ───────────────────────────────────────────
$pfxPath = $null
do {
    $raw = Read-Plain `
        -Prompt "Path to new PFX file" `
        -ContextTitle "Certificate Rotation" `
        -ContextHint "Full path to the .pfx file, e.g.:  C:\certs\wildcard-new.pfx"
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host "  Path must not be empty." -ForegroundColor Red; continue
    }
    $pfxPath = $raw.Trim().Trim('"')
    if (-not (Test-Path $pfxPath)) {
        Write-Host "  File not found: $pfxPath" -ForegroundColor Red
        Write-Host "  Please provide the full path." -ForegroundColor Gray
        $pfxPath = $null
    }
} while (-not $pfxPath)

$pfxPassword = Read-SecretPlain `
    -Prompt "PFX password (Enter = no password)" `
    -ContextTitle "Certificate Rotation" `
    -ContextHint "Password protecting the PFX file"

# ── 5. Convert PFX to PEM ────────────────────────────────────────
Write-Host ""
Write-Host "  Converting PFX..." -ForegroundColor Cyan
try {
    $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
             [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
    $collection = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    $collection.Import($pfxPath, $pfxPassword, $flags)
} catch {
    Write-Host "  Could not load PFX — correct password?`n$_" -ForegroundColor Red; exit 1
}

$leafCert = $collection | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
if (-not $leafCert) { Write-Host "  No certificate with private key found." -ForegroundColor Red; exit 1 }

$chainCerts = @($collection | Where-Object { -not $_.HasPrivateKey })
$pemParts   = @("-----BEGIN CERTIFICATE-----",
                [Convert]::ToBase64String($leafCert.RawData, [Base64FormattingOptions]::InsertLineBreaks),
                "-----END CERTIFICATE-----")
foreach ($c in $chainCerts) {
    $pemParts += @("-----BEGIN CERTIFICATE-----",
                   [Convert]::ToBase64String($c.RawData, [Base64FormattingOptions]::InsertLineBreaks),
                   "-----END CERTIFICATE-----")
}
$tlsCrt = $pemParts -join "`n"

try {
    $rsa      = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($leafCert)
    $keyBytes = $rsa.ExportPkcs8PrivateKey()
} catch {
    Write-Host "  Could not export private key.`n$_" -ForegroundColor Red; exit 1
}
$tlsKey = @("-----BEGIN PRIVATE KEY-----",
             [Convert]::ToBase64String($keyBytes, [Base64FormattingOptions]::InsertLineBreaks),
             "-----END PRIVATE KEY-----") -join "`n"

$newSan = ($leafCert.Extensions |
    Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }).Format($false)
Write-Host "  ✓ Converted" -ForegroundColor Green
Write-Host "    New:  $($leafCert.Subject)  —  valid until $($leafCert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor White
Write-Host "    SANs: $newSan" -ForegroundColor White
Write-Host ""

# ── 6. Write to vault ────────────────────────────────────────────
$certB64Enc = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tlsCrt))
$keyB64Enc  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($tlsKey))
$shellCmd   = "printf '%s' '$certB64Enc' | base64 -d > /tmp/_rc_cert.pem && printf '%s' '$keyB64Enc' | base64 -d > /tmp/_rc_key.pem && BAO_TOKEN=$rootToken bao kv put secret/$VaultPath tls.crt=@/tmp/_rc_cert.pem tls.key=@/tmp/_rc_key.pem ; rm -f /tmp/_rc_cert.pem /tmp/_rc_key.pem"

$exitCode = Invoke-WithSpinner -Message "Writing certificate to OpenBao..." -Executable "kubectl" `
    -Arguments @("exec", "openbao-0", "-n", "openbao", "--", "sh", "-c", $shellCmd)
if ($exitCode -ne 0) { Write-Host "  Error writing to OpenBao (exit $exitCode)" -ForegroundColor Red; exit 1 }
Write-Host "  ✓ Certificate updated in OpenBao ($VaultPath)" -ForegroundColor Green

# ── 7. Force ESO resync ──────────────────────────────────────────
$timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
& kubectl annotate externalsecret $SecretName -n $Namespace `
    "force-sync=$timestamp" --overwrite --request-timeout=10s 2>$null | Out-Null
Write-Host "  ✓ ESO resync triggered" -ForegroundColor Green

Start-Sleep -Seconds 5
$newCertB64 = & kubectl get secret $SecretName -n $Namespace `
    -o jsonpath='{.data.tls\.crt}' --request-timeout=5s 2>$null
if ($newCertB64) {
    try {
        $newCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            [Convert]::FromBase64String($newCertB64))
        if ($newCert.Subject -eq $leafCert.Subject -and $newCert.NotAfter -eq $leafCert.NotAfter) {
            Write-Host "  ✓ K8s secret '$SecretName' updated" -ForegroundColor Green
        } else {
            Write-Host "  ⚠ Secret not yet updated — ESO will sync within 1h automatically" -ForegroundColor Yellow
        }
    } catch { }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Rotation complete" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
Write-Host "  Reflector distributes 'wildcard-tls' automatically to all namespaces." -ForegroundColor Gray
Write-Host "  Ingresses pick up the new certificate without restart." -ForegroundColor Gray
Write-Host ""
