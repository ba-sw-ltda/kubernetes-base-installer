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
    [string]$IngressController = "nginx",
    [string]$DnsLabel = ""
)

$BaseDir = Split-Path $PSScriptRoot -Parent
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

# Patch all existing Ingress resources to use the new IngressClass.
# Needed when switching controllers (nginx ↔ traefik) so existing Ingresses
# don't keep pointing at the now-removed controller.
$existingIngresses = & kubectl get ingress -A -o json 2>$null | ConvertFrom-Json -AsHashtable
$updated = 0
foreach ($ing in $existingIngresses['items']) {
    if ($ing['spec']['ingressClassName'] -ne $IngressController) {
        $name = $ing['metadata']['name']
        $ns   = $ing['metadata']['namespace']
        & kubectl patch ingress $name -n $ns `
            -p "{`"spec`":{`"ingressClassName`":`"$IngressController`"}}" `
            --type=merge 2>$null | Out-Null
        $updated++
    }
}
if ($updated -gt 0) {
    Write-Host "  ✓ $updated Ingress resource(s) updated to ingressClassName=$IngressController" -ForegroundColor Green
}
