<#
.SYNOPSIS
    Collect Authelia settings upfront.
.DESCRIPTION
    Installing Authelia is the single sign-on switch-over moment: the password
    collected here becomes the one shared "admin" credential for every
    component protected by Protect-ComponentIngress, replacing whatever
    distinct per-app Basic-Auth passwords existed before. Re-running this
    prompt (re-installing Authelia) is also how that shared password gets
    rotated later.
.PARAMETER Platform
    Target platform
.PARAMETER Domain
    Cluster domain (from Install-Base.ps1)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'AdminPassword',
    Justification = 'Passed through to Vault only; never logged or stored in the cluster as plain text')]
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Domain = "kubernetes.local"
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$defaultHostname = "auth.$Domain"

$hostname = Read-Plain `
    -Prompt "Authelia hostname" `
    -Default $defaultHostname `
    -ContextTitle "Security/Authelia — $Platform" `
    -ContextHint "DNS name under which Authelia will be reachable" `
    -ContextCurrent ([ordered]@{ Domain = $Domain })

do {
    $adminPassword = Read-SecretPlainConfirm `
        -Prompt1 "Shared admin password (min. 8 chars)" `
        -Prompt2 "Confirm admin password" `
        -ContextTitle "Security/Authelia — $Platform" `
        -ContextCurrent ([ordered]@{ Hostname = $hostname })
    if ($adminPassword.Length -lt 8) {
        Write-Host "  Password must be at least 8 characters." -ForegroundColor Red
    }
} while ($adminPassword.Length -lt 8)

return @{
    Hostname      = $hostname.Trim()
    AdminPassword = $adminPassword.Trim()
}
