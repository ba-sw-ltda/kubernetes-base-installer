<#
.SYNOPSIS
    Collect proxy settings upfront (RKE2 and Kind only).
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param([string]$Platform)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

# Only on-premise and local platforms need proxy configuration
if ($Platform -ne "RKE2 (On-Premise)" -and $Platform -ne "Kind (Local)") { return @{} }

$useProxy = Read-YesNo `
    -Title "Proxy Configuration" `
    -Message "Does your network require a proxy to reach the internet?" `
    -DefaultYes $false `
    -ContextTitle "Proxy Configuration" `
    -ContextHint "Required if cluster nodes cannot reach the internet directly" `
    -ContextCurrent ([ordered]@{ Platform = $Platform })

if (-not $useProxy) { return @{} }

$httpProxy = Read-Plain `
    -Prompt "HTTP_PROXY" `
    -Default "http://proxy.fts.linz:3218" `
    -ContextTitle "Proxy Configuration" `
    -ContextHint "Full URL including port" `
    -ContextCurrent ([ordered]@{ Platform = $Platform })

if ([string]::IsNullOrWhiteSpace($httpProxy)) { return @{} }

$httpsProxy = Read-Plain `
    -Prompt "HTTPS_PROXY (default: same as HTTP_PROXY)" `
    -ContextTitle "Proxy Configuration" `
    -ContextHint "Leave empty to use the same value as HTTP_PROXY" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; HTTP_PROXY = $httpProxy })
if ([string]::IsNullOrWhiteSpace($httpsProxy)) { $httpsProxy = $httpProxy }

$noProxyExtra = Read-Plain `
    -Prompt "NO_PROXY additions (comma-separated, optional)" `
    -Default ".fts.linz" `
    -ContextTitle "Proxy Configuration" `
    -ContextHint "Added to defaults: localhost,127.0.0.1,.cluster.local,.svc,10.0.0.0/8,192.168.0.0/16" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; HTTP_PROXY = $httpProxy; HTTPS_PROXY = $httpsProxy })

return @{
    HttpProxy      = $httpProxy.Trim()
    HttpsProxy     = $httpsProxy.Trim()
    NoProxyExtra   = $noProxyExtra.Trim()
}
