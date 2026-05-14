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

if ($TracingBackend -eq "Jaeger") {
    $uninstall = Join-Path $BaseDir "64-tracing-tempo\Uninstall.ps1"
    if (Test-Path $uninstall) { & $uninstall -Platform $Platform @extraArgs }

    $jaegerArgs = @{ Platform = $Platform }
    if ($Hostname) { $jaegerArgs.Hostname = $Hostname }
    & (Join-Path $BaseDir "64-tracing-jaeger\Install.ps1") @jaegerArgs @extraArgs
    if ($LASTEXITCODE -ne 0) { exit 1 }
} else {
    $uninstall = Join-Path $BaseDir "64-tracing-jaeger\Uninstall.ps1"
    if (Test-Path $uninstall) { & $uninstall -Platform $Platform @extraArgs }

    & (Join-Path $BaseDir "64-tracing-tempo\Install.ps1") -Platform $Platform @extraArgs
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

exit 0
