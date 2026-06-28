<#
.SYNOPSIS
    Collect Rancher settings upfront.
.DESCRIPTION
    No bootstrap-password prompt — login goes through Authelia/OIDC (the
    'admins' group gets full admin rights automatically), so the local
    bootstrap admin is just a break-glass fallback. Install.ps1 generates
    and persists that password in Vault on its own, no user input needed.
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

$mode = Read-SelectValue `
    -Title "Management Mode" `
    -Message "Install full Rancher Server or import this cluster into an existing Rancher?" `
    -Options @(
        @{ Label = "Rancher Server  (install full Rancher on this cluster)"; Value = "Full" }
        @{ Label = "Rancher Agent   (import this cluster into existing Rancher)"; Value = "Agent" }
    ) `
    -Default 0 `
    -ContextTitle "Rancher — $Platform" `
    -ContextHint "Full = Rancher UI runs here. Agent = cluster is registered in an external Rancher."

if (-not $mode) { return $null }

if ($mode -eq "Agent") {
    $registrationUrl = Read-Plain `
        -Prompt "Rancher registration URL" `
        -ContextTitle "Rancher/Agent — $Platform" `
        -ContextHint "In Rancher UI: Import Existing → Generic → Create → copy the URL ending in .yaml"
    return @{ ManagementMode = "Agent"; RegistrationUrl = $registrationUrl.Trim() }
}

# Full Rancher Server
$defaultHostname = "rancher.$Domain"
$hostname = Read-Plain `
    -Prompt "Rancher hostname" `
    -Default $defaultHostname `
    -ContextTitle "Rancher/Server — $Platform" `
    -ContextHint "DNS name under which Rancher will be reachable — must resolve to your ingress IP" `
    -ContextCurrent ([ordered]@{ Domain = $Domain })

return @{
    ManagementMode = "Full"
    Hostname       = $hostname.Trim()
}
