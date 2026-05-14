<#
.SYNOPSIS
    Collect ProGet (or any private Docker registry) credentials upfront.
#>
[CmdletBinding()]
param([string]$Platform)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$FullConfig = Get-ComponentConfig -ScriptRoot $PSScriptRoot -Platform $Platform
$UserConfig = $FullConfig.UserConfig

# Registry URL — prompt if not set in Config.psd1
$registryUrl = $UserConfig.RegistryUrl
if ([string]::IsNullOrWhiteSpace($registryUrl)) {
    $registryUrl = Read-Plain `
        -Prompt "Registry URL" `
        -ContextTitle "ProGet Registry" `
        -ContextHint "Hostname of your private Docker registry, e.g. registry.example.com"
}

# Main feed name
$feed = $UserConfig.Feed
if ([string]::IsNullOrWhiteSpace($feed)) {
    $feed = Read-Plain `
        -Prompt "Docker feed name" `
        -ContextTitle "ProGet Registry" `
        -ContextHint "Name of the Docker feed in your registry" `
        -ContextCurrent ([ordered]@{ Registry = $registryUrl })
}

# API token for main feed
do {
    $token = Read-SecretPlain `
        -Prompt "API token for '$feed'" `
        -ContextTitle "ProGet Registry" `
        -ContextHint "Token for user '$($UserConfig.User)' on $registryUrl" `
        -ContextCurrent ([ordered]@{ Registry = $registryUrl; Feed = $feed; User = $UserConfig.User })
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Host "  Token must not be empty." -ForegroundColor Red
    }
} while ([string]::IsNullOrWhiteSpace($token))

$result = @{ Token = $token; RegistryUrl = $registryUrl; Feed = $feed }

# On-premise: optional second feed for prototype/internal images
if ($Platform -in @("RKE2 (On-Premise)", "Kind (Local)")) {
    $prototypeFeed = $UserConfig.PrototypeFeed
    if ([string]::IsNullOrWhiteSpace($prototypeFeed)) {
        $prototypeFeed = Read-Plain `
            -Prompt "Prototype feed name (Enter to skip)" `
            -ContextTitle "ProGet Registry — Prototype Feed" `
            -ContextHint "Optional: second feed for on-premise prototype images. Leave empty to skip." `
            -ContextCurrent ([ordered]@{ Registry = $registryUrl })
    }

    if (-not [string]::IsNullOrWhiteSpace($prototypeFeed)) {
        do {
            $prototypeToken = Read-SecretPlain `
                -Prompt "API token for '$prototypeFeed'" `
                -ContextTitle "ProGet Registry — Prototype Feed" `
                -ContextHint "Kubernetes install key for feed '$prototypeFeed' (on-premise only)" `
                -ContextCurrent ([ordered]@{ Registry = $registryUrl; Feed = $prototypeFeed; User = $UserConfig.User })
            if ([string]::IsNullOrWhiteSpace($prototypeToken)) {
                Write-Host "  Token must not be empty." -ForegroundColor Red
            }
        } while ([string]::IsNullOrWhiteSpace($prototypeToken))
        $result.PrototypeFeed  = $prototypeFeed
        $result.PrototypeToken = $prototypeToken
    }
}

return $result
