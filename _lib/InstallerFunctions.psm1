<#
.SYNOPSIS
    Module for installing prerequisites (kubectl, helm, cloud CLIs) and configuring kubectl.
#>

# Cluster bootstrap (tool installation, cluster create/connect) and generic
# installer utilities (Helm release recovery, ingress/LB IP discovery,
# IngressClass discovery) live in their own repo —
# https://github.com/ba-sw-ltda/powershell-cluster-bootstrap — vendored
# here as a git submodule so they can be reused outside this installer.
# Re-exported below so existing callers see no difference. Tools directory
# stays at this repo's existing ".tools" (one level up from _lib/) rather
# than the submodule's own generic default.
Import-Module "$PSScriptRoot\powershell-cluster-bootstrap\PowerShellClusterBootstrap.psd1" -Force -Verbose:$false
Set-ClusterBootstrapToolsDir -Path (Join-Path (Split-Path $PSScriptRoot -Parent) ".tools")

# -------------------------
# Rancher project organization
# -------------------------
# Projects/namespace assignment are plain management.cattle.io CRDs + an annotation —
# no Rancher API token/login required, the cluster-admin kubeconfig already has access.
# Both functions are no-ops (return silently) if Rancher isn't installed or the
# namespace doesn't exist yet — safe to call unconditionally from anywhere.

# Single namespace -> single project. Called directly by each component's own
# Install.ps1 right after it creates its namespace, so the assignment happens
# immediately and standalone (no Install-Base.ps1) runs get it too — not just
# when the centralized sweep below happens to run afterward.
function Set-RancherProjectAssignment {
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$ProjectName,
        [string]$ClusterName = "local"
    )

    & kubectl get crd projects.management.cattle.io 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return }  # Rancher not installed on this cluster — nothing to do

    & kubectl get namespace $Namespace 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return }  # namespace doesn't exist (yet) — nothing to do

    $jsonpath  = "{.items[?(@.spec.displayName==`"$ProjectName`")].metadata.name}"
    $projectId = (& kubectl get projects.management.cattle.io -n $ClusterName -o jsonpath=$jsonpath 2>$null)

    if ([string]::IsNullOrWhiteSpace($projectId)) {
        $projectYaml = @"
apiVersion: management.cattle.io/v3
kind: Project
metadata:
  generateName: p-
  namespace: $ClusterName
spec:
  clusterName: $ClusterName
  displayName: $ProjectName
  description: "Managed by installer"
"@
        $projectYaml | & kubectl create -f - 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "  ⚠ Could not create Rancher project '$ProjectName'"; return }

        $attempt = 0
        do {
            Start-Sleep -Seconds 2
            $projectId = (& kubectl get projects.management.cattle.io -n $ClusterName -o jsonpath=$jsonpath 2>$null)
            $attempt++
        } while ([string]::IsNullOrWhiteSpace($projectId) -and $attempt -lt 15)

        if ([string]::IsNullOrWhiteSpace($projectId)) {
            Write-Warning "  ⚠ Project '$ProjectName' created but ID could not be resolved — skipping namespace assignment"
            return
        }
        Write-Host "  ✓ Rancher project '$ProjectName' created ($projectId)" -ForegroundColor Green
    }

    $current = & kubectl get namespace $Namespace -o jsonpath='{.metadata.annotations.field\.cattle\.io/projectId}' 2>$null
    if ($current -eq "$ClusterName`:$projectId") { return }
    & kubectl annotate namespace $Namespace "field.cattle.io/projectId=$ClusterName`:$projectId" --overwrite 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ $Namespace -> $ProjectName (Rancher project)" -ForegroundColor Green
    } else {
        Write-Warning "  ⚠ Failed to assign namespace '$Namespace' to project '$ProjectName'"
    }
}

Export-ModuleMember -Function Test-CommandExists, Install-Kubectl, Install-Helm, Install-RancherCli, Install-PlatformTools, Initialize-Rke2Cluster, Initialize-ClusterEnvironment, Update-HostsFile, Get-AksIngressIp, Get-EksIngressIp, Confirm-KubectlContext, Reset-StuckHelmRelease, Get-IngressClass, Set-RancherProjectAssignment
