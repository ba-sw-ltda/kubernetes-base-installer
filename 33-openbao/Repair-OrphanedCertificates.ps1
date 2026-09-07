<#
.SYNOPSIS
    One-off repair for Certificates orphaned by an OpenBao root CA rotation
    that happened before Set-OpenBaoCertificatesToReissue existed (Install.ps1
    now runs this automatically on every future rotation — see 33-openbao/Install.ps1).

    Run this once to fix TLS trust for any component whose Certificate was
    issued against a now-replaced root CA:
        .\33-openbao\Repair-OrphanedCertificates.ps1 -Platform "RKE2 (On-Premise)"
.PARAMETER Platform
    Target platform ("RKE2 (On-Premise)" or "Kind (Local)")
.PARAMETER IssuerName
    ClusterIssuer to reissue Certificates for. Defaults to the platform's
    default Root PKI's ClusterIssuerName (from the state file) — override only
    if repairing a non-default PKI mount.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("RKE2 (On-Premise)", "Kind (Local)")]
    [string]$Platform,
    [string]$IssuerName
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1"       -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1"  -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Repair Orphaned Certificates" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not $IssuerName) {
    $rootPki = Get-OpenBaoDefaultRootPki -BaseDir $BaseDir -Platform $Platform
    if (-not $rootPki) {
        Write-Error "No default Root PKI found in the state file — pass -IssuerName explicitly."
        exit 1
    }
    $IssuerName = $rootPki['ClusterIssuerName']
    Write-Host "  Using default Root PKI's ClusterIssuer: $IssuerName" -ForegroundColor DarkGray
}

Set-OpenBaoCertificatesToReissue -IssuerName $IssuerName

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Repair complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
