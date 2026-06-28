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
    -YesLabel "Yes" `
    -NoLabel  "No" `
    -ContextTitle "Storage/Longhorn — $Platform"

return @{ ExposeUi = $exposeUi }
