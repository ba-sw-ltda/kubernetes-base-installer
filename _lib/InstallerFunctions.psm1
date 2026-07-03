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
# Already-installed detection (for re-run group skipping)
# -------------------------
# Lets Install-Base.ps1 unlock a normally-mandatory group's checkbox (and
# default it unchecked) once every member component is already on the
# cluster — so testing a later group (e.g. Observability Stack) doesn't force
# reinstalling Ingress/Storage/Security/Configuration Management every time.
# Conservative by design: any check it can't make confidently (cloud-native
# Vault has no single Helm release) just leaves the group out of the result,
# which keeps it locked/mandatory exactly like before this function existed.
#
# Runs ~11 helm/kubectl calls, ~25-30s total — done inside a single
# Invoke-ScriptBlockWithSpinner (from powershell-menu-ui, already loaded by
# the time Install-Base.ps1 calls this) so the console shows a spinner
# instead of sitting frozen. That function expects the caller to forward
# PATH/KUBECONFIG explicitly — Start-Job runs in a separate process that
# doesn't inherit either.
function Get-PreinstalledGroups {
    param([Parameter(Mandatory)][string]$Platform)

    $onPremOrKind = $Platform -in @("RKE2 (On-Premise)", "Kind (Local)")

    $joined = Invoke-ScriptBlockWithSpinner -Message "Checking for already-installed components..." -ScriptBlock {
        param($path, $kubeconfig, $platform, $onPremOrKind)
        $env:PATH = $path
        if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }

        function Test-ReleasePresent($Name, $Namespace) {
            & helm status $Name --namespace $Namespace 2>&1 | Out-Null
            return $LASTEXITCODE -eq 0
        }
        function Test-NamespacePresent($Name) {
            & kubectl get namespace $Name 2>&1 | Out-Null
            return $LASTEXITCODE -eq 0
        }

        $installed = @()

        $ingressOk = (Test-ReleasePresent "ingress-nginx" "ingress-nginx") -or (Test-ReleasePresent "traefik" "traefik")
        $metallbOk = -not $onPremOrKind -or (Test-ReleasePresent "metallb" "metallb-system")
        if ($ingressOk -and $metallbOk) { $installed += "Ingress & Load Balancing" }

        if ($platform -eq "RKE2 (On-Premise)" -and (Test-ReleasePresent "longhorn" "longhorn-system")) {
            $installed += "Storage (Longhorn)"
        }

        # Cloud-native Vault (Azure Key Vault / AWS Secrets Manager / GCP
        # Secret Manager) isn't a Helm release — no reliable single check, so
        # Security & Certificates only ever unlocks on RKE2/Kind (OpenBao).
        $vaultOk = $onPremOrKind -and (Test-ReleasePresent "openbao" "openbao")
        if ($vaultOk -and (Test-ReleasePresent "cert-manager" "cert-manager") -and
            (Test-ReleasePresent "secrets-store-csi-driver" "kube-system") -and
            (Test-ReleasePresent "authelia" "authelia")) {
            $installed += "Security & Certificates"
        }

        $proxyConfigOk = -not $onPremOrKind -or (Test-NamespacePresent "proxy-config")
        if ((Test-ReleasePresent "reflector" "kube-system") -and (Test-NamespacePresent "registry") -and $proxyConfigOk) {
            $installed += "Configuration Management"
        }

        # Joined into one string — the cleanest way for a value to survive
        # Start-Job's serialization boundary without surprises.
        return ($installed -join "|")
    } -ArgumentList @($env:PATH, $env:KUBECONFIG, $Platform, $onPremOrKind)

    $names = @($joined -split '\|' | Where-Object { $_ })
    return [System.Collections.Generic.HashSet[string]]::new([string[]]$names)
}

Export-ModuleMember -Function Test-CommandExists, Install-Kubectl, Install-Helm, Install-RancherCli, Install-PlatformTools, Initialize-Rke2Cluster, Initialize-ClusterEnvironment, Update-HostsFile, Get-AksIngressIp, Get-EksIngressIp, Confirm-KubectlContext, Reset-StuckHelmRelease, Get-IngressClass, Set-RancherProjectAssignment, Get-PreinstalledGroups
