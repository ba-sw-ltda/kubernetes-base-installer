<#
.SYNOPSIS
    Collect Longhorn UI hostname upfront.
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

$defaultHostname = "storage.$Domain"

$hostname = Read-Plain `
    -Prompt "Longhorn hostname" `
    -Default $defaultHostname `
    -ContextTitle "Storage/Longhorn — $Platform" `
    -ContextHint "DNS name under which Longhorn will be reachable" `
    -ContextCurrent ([ordered]@{ Domain = $Domain })

# No password prompt here, ever — Protect-ComponentIngress (called from
# Install.ps1) always returns Authelia forward-auth annotations regardless of
# whether Authelia happens to be live yet, so there's nothing to collect.
return @{ Hostname = $hostname.Trim() }
