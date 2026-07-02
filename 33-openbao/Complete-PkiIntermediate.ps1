<#
.SYNOPSIS
    Complete the setup of an External Intermediate CA whose CSR was exported
    by Install.ps1 and signed by a Corporate CA outside of OpenBao.

    Run this after the Corporate CA has returned the signed certificate:
        .\33-openbao\Complete-PkiIntermediate.ps1 -Platform "RKE2 (On-Premise)"

    The script finds all PKIs with Status=PendingCSR, lets you select one,
    asks for the path to the signed certificate PEM file, imports it, and
    configures the PKI roles + cert-manager ClusterIssuer (if HTTP role is set).
.PARAMETER Platform
    Target platform ("RKE2 (On-Premise)" or "Kind (Local)")
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("RKE2 (On-Premise)", "Kind (Local)")]
    [string]$Platform
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1"       -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1"  -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Complete Intermediate CA Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$Namespace = "openbao"

# ── Load state ───────────────────────────────────────────────────
$StateFile = Get-OpenBaoStateFile -BaseDir $BaseDir -Platform $Platform
if (-not (Test-Path $StateFile)) {
    Write-Error "Kein State File gefunden ($StateFile) — OpenBao wurde noch nicht installiert."
    exit 1
}
$state     = Get-Content $StateFile | ConvertFrom-Json
$rootToken = $state.RootToken
if (-not $rootToken) {
    Write-Error "RootToken im State File fehlt — OpenBao neu initialisieren."
    exit 1
}

# ── Find pending PKIs ─────────────────────────────────────────────
$allPkis     = Get-OpenBaoPkis -BaseDir $BaseDir -Platform $Platform
$pendingPkis = @($allPkis | Where-Object { $_['Status'] -eq 'PendingCSR' })

if ($pendingPkis.Count -eq 0) {
    Write-Host "  Keine ausstehenden Intermediate CAs gefunden." -ForegroundColor Green
    Write-Host "  (Status=PendingCSR nicht vorhanden — alles bereits abgeschlossen?)" -ForegroundColor DarkGray
    exit 0
}

# ── Select which PKI to complete ─────────────────────────────────
$pkiOptions = $pendingPkis | ForEach-Object {
    $csrHint = if ($_['CSRExportPath']) { " — CSR: $($_['CSRExportPath'])" } else { "" }
    @{ Label = "$($_['Name']) ($($_['MountPath']))$csrHint"; Value = $_['Name'] }
}

$selectedName = if ($pendingPkis.Count -eq 1) {
    Write-Host "  Ausstehend: $($pendingPkis[0].Name) ($($pendingPkis[0].MountPath))" -ForegroundColor Yellow
    $pendingPkis[0]['Name']
} else {
    Read-SelectValue `
        -Title   "Welche PKI abschließen?" `
        -Options $pkiOptions `
        -Default 0 `
        -ContextTitle "Complete Intermediate CA — $Platform"
}
if (-not $selectedName) { Write-Host "Abgebrochen." -ForegroundColor Red; exit 0 }

$pki = $pendingPkis | Where-Object { $_['Name'] -eq $selectedName } | Select-Object -First 1
$mountPath = $pki['MountPath']
$roles     = @($pki['Roles'])

Write-Host ""
Write-Host "  PKI:       $($pki.Name)" -ForegroundColor White
Write-Host "  MountPath: $mountPath" -ForegroundColor Gray
Write-Host "  Rollen:    $($roles -join ', ')" -ForegroundColor Gray
Write-Host ""

# ── Ask for signed certificate file ──────────────────────────────
$defaultCertPath = if ($pki['CSRExportPath']) {
    $pki['CSRExportPath'] -replace '\.csr$', '-signed.pem'
} else {
    Join-Path $BaseDir "$selectedName-signed.pem"
}

$certPath = Read-Plain `
    -Prompt       "Pfad zur signierten Zertifikat-Datei (PEM)" `
    -Default      $defaultCertPath `
    -ContextTitle "Complete Intermediate CA — $($pki.Name)" `
    -ContextHint  "Die von der Corporate CA signierte Zertifikat-Kette (PEM Format)"

$certPath = $certPath.Trim()
if (-not (Test-Path $certPath)) {
    Write-Error "Datei nicht gefunden: $certPath"
    exit 1
}

$signedCert = Get-Content -Path $certPath -Raw
if ($signedCert -notmatch '-----BEGIN CERTIFICATE-----') {
    Write-Error "Datei enthält kein gültiges PEM-Zertifikat: $certPath"
    exit 1
}

Write-Host ""

# ── Import signed certificate into OpenBao ────────────────────────
function Invoke-BaoCmd {
    param([string]$Msg, [string]$Cmd)
    Invoke-WithSpinner -Message $Msg -Executable "kubectl" `
        -Arguments @("exec", "openbao-0", "-n", $Namespace, "--", "sh", "-c", "$Cmd 2>/dev/null") | Out-Null
}

$signedRemote = "/tmp/$selectedName-signed.pem"
$signedTmp = New-TemporaryFile
Set-Content -Path $signedTmp.FullName -Value $signedCert -Encoding UTF8 -NoNewline
Write-Host "  · Uploading signed certificate to pod..." -ForegroundColor DarkGray
Push-Location (Split-Path $signedTmp.FullName)
& kubectl cp "./$(Split-Path $signedTmp.FullName -Leaf)" "${Namespace}/openbao-0:$signedRemote" 2>$null | Out-Null
Pop-Location
Remove-Item $signedTmp.FullName -Force -ErrorAction SilentlyContinue

$Domain = if ($pki['Domain']) { $pki['Domain'] } else {
    # Fall back to reading from state / deriving from hostname
    Write-Host "  · Looking up domain from ingress..." -ForegroundColor DarkGray
    $hostFromState = & kubectl get ingress openbao -n openbao -o jsonpath='{.spec.rules[0].host}' 2>$null
    if ($hostFromState) { $hostFromState -replace '^[^.]+\.', '' } else { "cluster.local" }
}

$importExit = Invoke-WithSpinner -Message "Importing signed intermediate certificate..." -Executable "kubectl" `
    -Arguments @("exec", "openbao-0", "-n", $Namespace, "--", "sh", "-c",
                 "BAO_TOKEN=$rootToken bao write $mountPath/intermediate/set-signed certificate=@$signedRemote")
& kubectl exec openbao-0 -n $Namespace -- rm -f $signedRemote 2>$null | Out-Null

if ($importExit -ne 0) {
    Write-Error "Zertifikat konnte nicht importiert werden — ist die PEM-Datei korrekt?"
    exit 1
}
Write-Host "  ✓ Signiertes Zertifikat importiert" -ForegroundColor Green

# CA URLs
Invoke-BaoCmd "Configuring CA URLs..." `
    ("BAO_TOKEN=$rootToken bao write $mountPath/config/urls " +
     "issuing_certificates='http://openbao.$Namespace.svc.cluster.local:8200/v1/$mountPath/ca' " +
     "crl_distribution_points='http://openbao.$Namespace.svc.cluster.local:8200/v1/$mountPath/crl'")

# ── Helper: write Vault policy via temp file ──────────────────────
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

# ── Configure roles ───────────────────────────────────────────────
if ("HTTP" -in $roles) {
    Invoke-BaoCmd "Configuring HTTP role (ServerAuth)..." `
        ("BAO_TOKEN=$rootToken bao write $mountPath/roles/http " +
         "allowed_domains='$Domain' allow_subdomains=true allow_bare_domains=true allow_any_name=false " +
         "require_cn=false max_ttl=720h ttl=720h key_type=rsa key_bits=2048 " +
         "key_usage='DigitalSignature,KeyEncipherment' ext_key_usage='ServerAuth'")
    Write-Host "  ✓ Rolle 'http' (ServerAuth)" -ForegroundColor Green
}

if ("mTLS" -in $roles) {
    $ttlH = if ($pki['mTlsTtlHours']) { [int]$pki['mTlsTtlHours'] } else { 336 }
    Invoke-BaoCmd "Configuring mTLS role (ClientAuth, ${ttlH}h)..." `
        ("BAO_TOKEN=$rootToken bao write $mountPath/roles/mtls " +
         "allow_any_name=true enforce_hostnames=false require_cn=true " +
         "max_ttl=${ttlH}h ttl=${ttlH}h key_type=rsa key_bits=2048 " +
         "key_usage='DigitalSignature' ext_key_usage='ClientAuth' no_store=false")
    Write-Host "  ✓ Rolle 'mtls' (ClientAuth, ${ttlH}h)" -ForegroundColor Green
}

# ── cert-manager ClusterIssuer ─────────────────────────────────────
if ("HTTP" -in $roles) {
    $issuerName = "openbao-pki-$selectedName"
    Write-BaoPolicy -PolicyName "cert-manager-$selectedName" -PolicyHcl @"
path "$mountPath/sign/http" {
  capabilities = ["create", "update"]
}
"@
    Invoke-BaoCmd "Configuring Vault role for cert-manager ($selectedName)..." `
        ("BAO_TOKEN=$rootToken bao write auth/kubernetes/role/cert-manager-$selectedName " +
         "bound_service_account_names=cert-manager bound_service_account_namespaces=cert-manager " +
         "policies=cert-manager-$selectedName ttl=20m")

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
        role: cert-manager-$selectedName
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager
"@
    $clusterIssuerYaml | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ ClusterIssuer '$issuerName' bereit" -ForegroundColor Green
    } else {
        Write-Warning "  ClusterIssuer '$issuerName' konnte nicht angelegt werden"
    }
}

# ── Update PKI status in state file ──────────────────────────────
$pki['Status'] = "Active"
if ($pki.ContainsKey('CSRExportPath')) { $pki.Remove('CSRExportPath') }

$updatedPkis = @($allPkis | ForEach-Object {
    if ($_['Name'] -eq $selectedName) { $pki } else { $_ }
})
Save-OpenBaoPkis -PKIs $updatedPkis -BaseDir $BaseDir -Platform $Platform

Write-Host ""
Write-Host "  ✓ PKI '$selectedName' ist jetzt aktiv" -ForegroundColor Green
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Intermediate CA abgeschlossen" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
