<#
.SYNOPSIS
    Collect Homer portal settings upfront.
.PARAMETER Platform
    Target platform
.PARAMETER Domain
    Cluster domain passed in from Install-Base.ps1
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Domain = "kubernetes.local"
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$defaultHostname = "portal.$Domain"

$hostname = Read-Plain `
    -Prompt "Homer hostname" `
    -Default $defaultHostname `
    -ContextTitle "Portal/Homer — $Platform" `
    -ContextHint "DNS name under which Homer will be reachable" `
    -ContextCurrent ([ordered]@{ Domain = $Domain })

$title = Read-Plain `
    -Prompt "Dashboard title" `
    -Default "Kubernetes Portal" `
    -ContextTitle "Portal/Homer — $Platform" `
    -ContextHint "Heading shown at the top of the Homer dashboard" `
    -ContextCurrent ([ordered]@{ Hostname = $hostname })

$subtitle = Read-Plain `
    -Prompt "Dashboard subtitle (leave empty to skip)" `
    -Default "" `
    -ContextTitle "Portal/Homer — $Platform" `
    -ContextHint "Optional sub-heading beneath the title — press Enter to leave blank" `
    -ContextCurrent ([ordered]@{ Hostname = $hostname; Title = $title })

return @{
    Hostname = $hostname.Trim()
    Title    = if ($title.Trim()) { $title.Trim() } else { "Kubernetes Portal" }
    Subtitle = $subtitle.Trim()
}
