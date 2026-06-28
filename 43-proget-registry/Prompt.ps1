<#
.SYNOPSIS
    Collect private container registry settings upfront (ProGet, Harbor,
    Artifactory, or any registry that speaks the standard Docker config
    format) — one host, then any number of feeds in a loop.
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param([string]$Platform)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$useRegistry = Read-YesNo `
    -Title "Registry" `
    -Message "Use a private container registry?" `
    -DefaultYes $false `
    -ContextTitle "Configuration/Registry — $Platform" `
    -ContextHint "Only needed if your images come from a private registry (ProGet, Harbor, Artifactory, ...)"

if (-not $useRegistry) { return @{} }

$registryUrl = Read-Plain `
    -Prompt "Registry host" `
    -ContextTitle "Configuration/Registry — $Platform" `
    -ContextHint "Hostname of your private registry, e.g. registry.example.com"

if ([string]::IsNullOrWhiteSpace($registryUrl)) { return @{} }
$registryUrl = $registryUrl.Trim()

$feeds = [System.Collections.Generic.List[hashtable]]::new()
$feedNum = 1
while ($true) {
    $feedName = Read-Plain `
        -Prompt "Feed $feedNum name (Enter to finish)" `
        -ContextTitle "Configuration/Registry — $Platform" `
        -ContextHint "Name of the feed/repository on $registryUrl" `
        -ContextCurrent ([ordered]@{ Registry = $registryUrl; "Feeds so far" = $feeds.Count })
    if ([string]::IsNullOrWhiteSpace($feedName)) { break }
    $feedName = $feedName.Trim()

    $user = Read-Plain `
        -Prompt "  User for '$feedName' (Enter for an anonymous/public feed)" `
        -Default "api" `
        -ContextTitle "Configuration/Registry — $Platform" `
        -ContextCurrent ([ordered]@{ Registry = $registryUrl; Feed = $feedName })

    $password = ""
    if (-not [string]::IsNullOrWhiteSpace($user)) {
        $password = Read-SecretPlain `
            -Prompt "  Password/API token for '$user'" `
            -ContextTitle "Configuration/Registry — $Platform" `
            -ContextHint "Leave empty to make this feed anonymous/public after all" `
            -ContextCurrent ([ordered]@{ Registry = $registryUrl; Feed = $feedName; User = $user })
    }

    $feeds.Add(@{
        Name     = $feedName
        User     = $user.Trim()
        Password = $password.Trim()
    }) | Out-Null
    $feedNum++
}

if ($feeds.Count -eq 0) { return @{} }

return @{
    RegistryUrl = $registryUrl
    Feeds       = $feeds.ToArray()
}
