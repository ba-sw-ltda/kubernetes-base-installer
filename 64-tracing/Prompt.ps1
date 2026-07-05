<#
.SYNOPSIS
    Select tracing backend and collect required settings.
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

$backend = Read-SelectValue `
    -Title "Select Tracing Backend" `
    -Message "Choose the distributed tracing backend" `
    -Options @(
        @{ Label = "Tempo  (Grafana-native, no separate UI)"; Value = "Tempo" }
        @{ Label = "Jaeger (CNCF, includes dedicated Jaeger UI)"; Value = "Jaeger" }
    ) `
    -Default 0 `
    -ContextTitle "Observability/Tracing — $Platform" `
    -ContextHint "Tempo integrates natively with Grafana. Jaeger adds a standalone UI." `
    -ContextCurrent ([ordered]@{})

if (-not $backend) { return $null }

$result = @{ TracingBackend = $backend }

if ($backend -eq "Jaeger") {
    $defaultHostname = "jaeger.$Domain"
    $hostname = Read-Plain `
        -Prompt "Jaeger hostname" `
        -Default $defaultHostname `
        -ContextTitle "Observability/Jaeger — $Platform" `
        -ContextHint "DNS name under which Jaeger will be reachable" `
        -ContextCurrent ([ordered]@{ Domain = $Domain })
    $result.Hostname = $hostname.Trim()
}

return $result
