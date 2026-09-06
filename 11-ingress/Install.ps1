<#
.SYNOPSIS
    Ingress controller orchestrator — installs chosen controller, removes the other if present.
.PARAMETER Platform
    Target platform
.PARAMETER IngressController
    "nginx" or "traefik" (collected via Prompt.ps1)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$IngressController = "traefik",
    [string]$DnsLabel = ""
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
$verbose = $VerbosePreference -eq 'Continue'
$extraArgs = if ($verbose) { @{ Verbose = $true } } else { @{} }

# Install chosen controller — its own Install.ps1 removes the other
# controller first (right after printing its banner), so the removal output
# lands inside that install block instead of floating in its own section.
$installScript = Join-Path $BaseDir "11-ingress-$IngressController\Install.ps1"
if (-not (Test-Path $installScript)) {
    Write-Error "Install script not found: $installScript"
    exit 1
}
$dnsArgs = if ($DnsLabel) { @{ DnsLabel = $DnsLabel } } else { @{} }
& $installScript -Platform $Platform @extraArgs @dnsArgs
if ($LASTEXITCODE -ne 0) { exit 1 }

# Ingress-class sync used to run here, as its own group, but that meant it
# executed after $installScript had already exited and printed its own
# "Installation Complete" banner — so its output landed outside that block
# instead of inside it (user-flagged 2026-09-05). Moved into each specific
# controller's own Install.ps1 (11-ingress-traefik, 11-ingress-nginx) instead,
# right before that script's own "Installation Complete" banner.
