<#
.SYNOPSIS
    Import cluster into an existing Rancher instance by deploying the Rancher Agent.
.PARAMETER Platform
    Target platform
.PARAMETER RegistrationUrl
    Registration manifest URL from Rancher UI (Cluster Management → Import Existing)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$RegistrationUrl = ""
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: Rancher Agent" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($RegistrationUrl)) {
    Write-Host "  ⚠ No registration URL provided — skipping Rancher Agent" -ForegroundColor Yellow
    exit 0
}

Write-Host "  Registration URL: $RegistrationUrl" -ForegroundColor Gray
Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Applying Rancher registration manifest..." -Executable "kubectl" `
    -Arguments @("apply", "-f", $RegistrationUrl) -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to apply Rancher registration manifest (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Rancher Agent deployed" -ForegroundColor Green

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  The cluster will appear in Rancher UI once" -ForegroundColor Gray
Write-Host "  the agent connects (may take 1-2 minutes)." -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
