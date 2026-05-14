<#
.SYNOPSIS
    Phase 1 — fundamental choice: expose Longhorn UI via Ingress?
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Domain = ""
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$exposeUi = Read-YesNo `
    -Title "Expose Longhorn UI via Ingress?" `
    -DefaultYes $true `
    -YesLabel "Yes — create an Ingress for the Longhorn dashboard" `
    -NoLabel  "No  — access via port-forward only" `
    -ContextTitle "Longhorn Storage" `
    -ContextCurrent ([ordered]@{ Platform = $Platform })

return @{ ExposeUi = $exposeUi }
