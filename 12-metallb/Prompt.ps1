<#
.SYNOPSIS
    Collect MetalLB inputs upfront (called by Install-Base.ps1 before installation starts).
.PARAMETER Platform
    Target platform
.PARAMETER Domain
    Cluster domain (from Install-Base.ps1)
.PARAMETER IngressController
    Which ingress controller was chosen ("nginx" or "traefik") — only used to label
    the prompt correctly; MetalLB itself doesn't care which one consumes the IP.
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Domain = "kubernetes.local",
    [string]$IngressController = ""
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

# Only RKE2 needs manual input — Kind auto-detects
if ($Platform -ne "RKE2 (On-Premise)") { return @{} }

# Gespeicherte IP aus State-File als Default vorschlagen
$savedIp = $null
$stateFile = Join-Path $BaseDir ".rke2-state.json"
if (Test-Path $stateFile) {
    $state = Get-Content $stateFile | ConvertFrom-Json
    $savedIp = $state.LoadBalancerIP
}

$controllerLabel = switch ($IngressController) {
    "nginx"   { "NGINX" }
    "traefik" { "Traefik" }
    default   { "" }
}
$ipPrompt = if ($controllerLabel) { "$controllerLabel LoadBalancer IP" } else { "LoadBalancer IP" }

$nginxIp = Read-Plain `
    -Prompt $ipPrompt `
    -Default $savedIp `
    -ContextTitle "Ingress/MetalLB — $Platform" `
    -ContextHint "The IP your wildcard DNS (*.$Domain) points to"

if ([string]::IsNullOrWhiteSpace($nginxIp)) {
    Write-Error "$ipPrompt is required for RKE2."
    exit 1
}

return @{ NginxIp = $nginxIp.Trim() }
