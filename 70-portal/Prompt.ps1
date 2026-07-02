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
    -Prompt "Homer portal hostname" `
    -Default $defaultHostname `
    -ContextTitle "70 - Portal - Homer" `
    -ContextHint "DNS name under which the portal dashboard will be reachable" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; Domain = $Domain })

$title = Read-Plain `
    -Prompt "Dashboard title" `
    -Default "Kubernetes Portal" `
    -ContextTitle "70 - Portal - Homer" `
    -ContextHint "Heading shown at the top of the Homer dashboard" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; Hostname = $hostname })

$subtitle = Read-Plain `
    -Prompt "Dashboard subtitle (leave empty to skip)" `
    -Default "" `
    -ContextTitle "70 - Portal - Homer" `
    -ContextHint "Optional sub-heading beneath the title — press Enter to leave blank" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; Hostname = $hostname; Title = $title })

$themeUrl = Read-Plain `
    -Prompt "Website URL to copy accent color from (leave empty to skip)" `
    -Default "" `
    -ContextTitle "70 - Portal - Homer" `
    -ContextHint "Homer will extract the theme-color meta tag from this URL as its accent color" `
    -ContextCurrent ([ordered]@{ Platform = $Platform; Hostname = $hostname; Title = $title; Subtitle = $subtitle })

return @{
    Hostname       = $hostname.Trim()
    Title          = if ($title.Trim()) { $title.Trim() } else { "Kubernetes Portal" }
    Subtitle       = $subtitle.Trim()
    ThemeSourceUrl = $themeUrl.Trim()
}
