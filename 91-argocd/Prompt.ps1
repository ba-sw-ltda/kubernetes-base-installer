<#
.SYNOPSIS
    Collect ArgoCD settings upfront.
.PARAMETER Platform
    Target platform
.PARAMETER Domain
    Cluster domain (from Install-Base.ps1)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Domain = "kubernetes.local"
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$defaultHostname = "argocd.$Domain"

$hostname = Read-Plain `
    -Prompt "ArgoCD hostname" `
    -Default $defaultHostname `
    -ContextTitle "90 - Utilities - ArgoCD — $Platform" `
    -ContextHint "DNS name under which ArgoCD will be reachable" `
    -ContextCurrent ([ordered]@{ Domain = $Domain })

return @{
    Hostname = $hostname.Trim()
}
