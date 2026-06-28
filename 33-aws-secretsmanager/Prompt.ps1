<#
.SYNOPSIS
    AWS Secrets Manager has no user-configurable options at install time.
    IRSA and the ASCP are fully automated from the EKS state file.
#>
[CmdletBinding()]
param([string]$Platform)

return @{}
