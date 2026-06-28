<#
.SYNOPSIS
    GCP Secret Manager has no user-configurable options at install time.
    Workload Identity and the CSI driver are fully automated.
#>
[CmdletBinding()]
param([string]$Platform)

# No user input needed — all configuration is derived from .gke-state.json
return @{}
