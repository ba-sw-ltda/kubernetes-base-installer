<#
.SYNOPSIS
    Tracing dispatcher — installs selected backend, uninstalls the other.
.PARAMETER Platform
    Target platform
.PARAMETER TracingBackend
    "Tempo" or "Jaeger" (from Prompt.ps1)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$TracingBackend = "Tempo",
    [string]$Hostname
)

$BaseDir    = Split-Path $PSScriptRoot -Parent
$verbose    = $VerbosePreference -eq 'Continue'
$extraArgs  = if ($verbose) { @{ Verbose = $true } } else { @{} }

# Install chosen backend — its own Install.ps1 removes the other backend
# first (right after printing its banner), so the removal output lands
# inside that install block instead of floating in its own section.
if ($TracingBackend -eq "Jaeger") {
    $jaegerArgs = @{ Platform = $Platform }
    if ($Hostname) { $jaegerArgs.Hostname = $Hostname }
    & (Join-Path $BaseDir "64-tracing-jaeger\Install.ps1") @jaegerArgs @extraArgs
    if ($LASTEXITCODE -ne 0) { exit 1 }
} else {
    & (Join-Path $BaseDir "64-tracing-tempo\Install.ps1") -Platform $Platform @extraArgs
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

exit 0
