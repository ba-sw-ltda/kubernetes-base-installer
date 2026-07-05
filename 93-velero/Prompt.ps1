<#
.SYNOPSIS
    Collect Velero backup schedule settings upfront.
.PARAMETER Platform
    Target platform
#>
[CmdletBinding()]
param(
    [string]$Platform
)

$BaseDir = Split-Path $PSScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

$schedule = Read-Plain `
    -Prompt "Backup schedule (cron)" `
    -Default "0 2 * * *" `
    -ContextTitle "Utilities/Velero — $Platform" `
    -ContextHint "Standard 5-field cron expression — default is daily at 02:00" `
    -ContextCurrent ([ordered]@{})

$retentionDays = Read-Plain `
    -Prompt "Backup retention (days)" `
    -Default "14" `
    -ContextTitle "Utilities/Velero — $Platform" `
    -ContextHint "How long completed backups are kept before Velero deletes them" `
    -ContextCurrent ([ordered]@{ "Backup schedule" = $schedule.Trim() })

return @{
    Schedule       = $schedule.Trim()
    RetentionDays  = [int]$retentionDays.Trim()
}
