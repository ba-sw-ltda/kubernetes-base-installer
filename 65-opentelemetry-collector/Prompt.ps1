<#
.SYNOPSIS
    Ask whether to install the OpenTelemetry Collector. Observability's other
    components (Prometheus, Loki, Promtail, Tracing, Grafana) are mandatory
    once the group is selected — this is the one real remaining choice,
    same treatment as Configuration Management's Registry gate.
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param([string]$Platform)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$enabled = Read-YesNo `
    -Title "Install the OpenTelemetry Collector?" `
    -DefaultYes $true `
    -ContextTitle "Observability/OpenTelemetry Collector — $Platform" `
    -ContextHint "Receives OTLP traces/metrics/logs and forwards them to Tempo/Jaeger, Prometheus, and Loki — only needed if your workloads emit OTLP directly"

return @{ Enabled = $enabled }
