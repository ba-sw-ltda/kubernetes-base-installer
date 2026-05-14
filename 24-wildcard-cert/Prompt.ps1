<#
.SYNOPSIS
    Collect wildcard certificate inputs upfront.
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param([string]$Platform)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

# Kind uses self-signed CA — no external certificate needed
if ($Platform -eq "Kind (Local)") { return @{} }

$installCert = Read-YesNo `
    -Title "Install wildcard certificate?" `
    -Message "Store PFX certificate in vault and deploy as 'wildcard-tls' in the cluster?" `
    -DefaultYes $true `
    -ContextTitle "Wildcard TLS Certificate" `
    -ContextHint "One-time setup. Renewal later via OpenBao UI — no kubectl required."

if (-not $installCert) { return @{} }

# ── PFX path ──────────────────────────────────────────────────────
$pfxPath = $null
do {
    $raw = Read-Plain `
        -Prompt "Path to PFX file" `
        -ContextTitle "Wildcard TLS Certificate" `
        -ContextHint "Full path to the .pfx file, e.g.:  C:\certs\wildcard.pfx"

    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host "  Path must not be empty." -ForegroundColor Red
        continue
    }

    $pfxPath = $raw.Trim().Trim('"')

    if (-not (Test-Path $pfxPath)) {
        Write-Host "  File not found: $pfxPath" -ForegroundColor Red
        Write-Host "  Please provide the full path (e.g. C:\certs\wildcard.pfx)" -ForegroundColor Gray
        $pfxPath = $null
    }
} while (-not $pfxPath)

# ── PFX password ──────────────────────────────────────────────────
$pfxPassword = Read-SecretPlain `
    -Prompt "PFX password (Enter = no password)" `
    -ContextTitle "Wildcard TLS Certificate" `
    -ContextHint "Password protecting the PFX file — leave empty if the file has no password"

return @{
    PfxPath     = $pfxPath
    PfxPassword = if ($pfxPassword) { $pfxPassword } else { "" }
}
