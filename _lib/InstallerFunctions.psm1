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
# Generic: reads RancherProject + Namespace from every component's Config.psd1 and
# assigns each namespace to that Rancher project (creating the project if needed).
# Projects/namespace assignment are plain management.cattle.io CRDs + an annotation —
# no Rancher API token/login required, the cluster-admin kubeconfig already has access.
function Sync-RancherProjects {
    param(
        [Parameter(Mandatory)][string]$BaseDir,
        [string]$ClusterName = "local"
    )

    & kubectl get crd projects.management.cattle.io 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return }  # Rancher not installed on this cluster — nothing to do

    Write-Host "`n--- Organizing namespaces into Rancher projects ---" -ForegroundColor Magenta

    $projectMap = [ordered]@{}
    Get-ChildItem -Path $BaseDir -Directory | Where-Object { $_.Name -match '^\d{2}-' } | Sort-Object Name | ForEach-Object {
        $configFile = Join-Path $_.FullName "Config.psd1"
        if (-not (Test-Path $configFile)) { return }
        try { $cfg = Import-PowerShellDataFile -Path $configFile } catch { return }
        if (-not $cfg.RancherProject -or -not $cfg.Namespace) { return }
        if (-not $projectMap.Contains($cfg.RancherProject)) {
            $projectMap[$cfg.RancherProject] = [System.Collections.Generic.List[string]]::new()
        }
        if ($cfg.Namespace -notin $projectMap[$cfg.RancherProject]) {
            $projectMap[$cfg.RancherProject].Add($cfg.Namespace)
        }
    }

    foreach ($projectName in $projectMap.Keys) {
        $namespaces = @($projectMap[$projectName] | Where-Object {
            & kubectl get namespace $_ 2>&1 | Out-Null
            $LASTEXITCODE -eq 0
        })
        if ($namespaces.Count -eq 0) { continue }

        $jsonpath  = "{.items[?(@.spec.displayName==`"$projectName`")].metadata.name}"
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
  displayName: $projectName
  description: "Managed by installer"
"@
            $projectYaml | & kubectl create -f - 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Warning "  ⚠ Could not create Rancher project '$projectName'"; continue }

            $attempt = 0
            do {
                Start-Sleep -Seconds 2
                $projectId = (& kubectl get projects.management.cattle.io -n $ClusterName -o jsonpath=$jsonpath 2>$null)
                $attempt++
            } while ([string]::IsNullOrWhiteSpace($projectId) -and $attempt -lt 15)

            if ([string]::IsNullOrWhiteSpace($projectId)) {
                Write-Warning "  ⚠ Project '$projectName' created but ID could not be resolved — skipping namespace assignment"
                continue
            }
            Write-Host "  ✓ Rancher project '$projectName' created ($projectId)" -ForegroundColor Green
        }

        foreach ($ns in $namespaces) {
            $current = & kubectl get namespace $ns -o jsonpath='{.metadata.annotations.field\.cattle\.io/projectId}' 2>$null
            if ($current -eq "$ClusterName`:$projectId") { continue }
            & kubectl annotate namespace $ns "field.cattle.io/projectId=$ClusterName`:$projectId" --overwrite 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✓ $ns -> $projectName" -ForegroundColor Green
            } else {
                Write-Warning "  ⚠ Failed to assign namespace '$ns' to project '$projectName'"
            }
        }
    }
}

Export-ModuleMember -Function Test-CommandExists, Install-Kubectl, Install-Helm, Install-RancherCli, Install-PlatformTools, Initialize-Rke2Cluster, Initialize-ClusterEnvironment, Update-HostsFile, Get-AksIngressIp, Get-EksIngressIp, Confirm-KubectlContext, Reset-StuckHelmRelease, Get-IngressClass, Sync-RancherProjects
