<#
.SYNOPSIS
    Module for installing prerequisites (kubectl, helm, cloud CLIs) and configuring kubectl.
#>

# Cluster bootstrap (tool installation, cluster create/connect) and generic
# installer utilities (Helm release recovery, ingress/LB IP discovery,
# IngressClass discovery) live in their own repo —
# https://github.com/ba-sw-ltda/powershell-cluster-bootstrap — checked out
# as a sibling directory (not a git submodule) so multiple installer repos
# share one working copy. Re-exported below so existing callers see no
# difference. Tools directory stays at this repo's existing ".tools" (one
# level up from _lib/) rather than the submodule's own generic default.
Import-Module "$PSScriptRoot\..\..\powershell-cluster-bootstrap\PowerShellClusterBootstrap.psd1" -Force -Verbose:$false
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
# One Invoke-ScriptBlockWithSpinner per group (not one job for all ~11
# helm/kubectl calls) so the result prints group-by-group as each check
# completes, instead of the console sitting on one spinner for ~25-30s and
# dumping every result at once at the end — mirrors Kubernetes.Infra's
# Get-PreinstalledDependencies loop. Each scriptblock defines its own
# Test-ReleasePresent/Test-NamespacePresent copies since Start-Job runs in a
# separate process per call and can't share functions across that boundary;
# PATH/KUBECONFIG must be forwarded explicitly for the same reason.
function Get-PreinstalledGroups {
    param([Parameter(Mandatory)][string]$Platform)

    $onPremOrKind = $Platform -in @("RKE2 (On-Premise)", "Kind (Local)")

    $groupChecks = [ordered]@{
        "Ingress & Load Balancing" = {
            param($path, $kubeconfig, $onPremOrKind)
            $env:PATH = $path
            if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }
            function Test-ReleasePresent($Name, $Namespace) {
                & helm status $Name --namespace $Namespace 2>&1 | Out-Null
                return $LASTEXITCODE -eq 0
            }
            $ingressOk = (Test-ReleasePresent "ingress-nginx" "ingress") -or (Test-ReleasePresent "traefik" "ingress")
            $metallbOk = -not $onPremOrKind -or (Test-ReleasePresent "metallb" "metallb-system")
            [PSCustomObject]@{ Found = ($ingressOk -and $metallbOk) }
        }
        "Storage (Longhorn)" = {
            param($path, $kubeconfig, $onPremOrKind)
            $env:PATH = $path
            if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }
            & helm status longhorn --namespace longhorn-system 2>&1 | Out-Null
            [PSCustomObject]@{ Found = ($LASTEXITCODE -eq 0) }
        }
        # Not a Helm release — checks for the default-deny-all NetworkPolicy
        # that Install-NetworkPolicyBaseline stamps into kube-system.
        "Network Segmentation" = {
            param($path, $kubeconfig, $onPremOrKind)
            $env:PATH = $path
            if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }
            & kubectl get networkpolicy default-deny-all -n kube-system 2>&1 | Out-Null
            [PSCustomObject]@{ Found = ($LASTEXITCODE -eq 0) }
        }
        # Cloud-native Vault (Azure Key Vault / AWS Secrets Manager / GCP
        # Secret Manager) isn't a Helm release — no reliable single check, so
        # Security & Certificates only unlocks on platforms that actually run
        # OpenBao (RKE2/Kind, and Magalu Cloud — Magalu has no native vault
        # equivalent of its own, so it uses OpenBao same as on-prem/Kind).
        # $onPremOrKind is reused across the other checks above for the
        # MetalLB/proxy-config gate, which is a different question (does this
        # platform lack a native LoadBalancer/proxy) — Magalu has its own
        # managed LB, so it must NOT be folded into $onPremOrKind itself.
        "Security & Certificates" = {
            param($path, $kubeconfig, $onPremOrKind, $platform)
            $env:PATH = $path
            if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }
            function Test-ReleasePresent($Name, $Namespace) {
                & helm status $Name --namespace $Namespace 2>&1 | Out-Null
                return $LASTEXITCODE -eq 0
            }
            $usesOpenBao = $onPremOrKind -or $platform -eq "Magalu Cloud"
            $vaultOk = $usesOpenBao -and (Test-ReleasePresent "openbao" "openbao")
            $found = $vaultOk -and (Test-ReleasePresent "cert-manager" "cert-manager") -and
                (Test-ReleasePresent "secrets-store-csi-driver" "kube-system") -and
                (Test-ReleasePresent "authelia" "authelia")
            [PSCustomObject]@{ Found = $found }
        }
        "Configuration Management" = {
            param($path, $kubeconfig, $onPremOrKind)
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
            # Registry (43-proget-registry) is optional — Prompt.ps1 defaults
            # to "no" and Install.ps1 never creates the "registry" namespace
            # when declined. Checking for it here made this group permanently
            # report "not installed" for anyone who legitimately skipped it,
            # even with reflector genuinely deployed. Only the two mandatory
            # members (reflector, and proxy-config on RKE2/Kind) count.
            $proxyConfigOk = -not $onPremOrKind -or (Test-NamespacePresent "proxy-config")
            $found = (Test-ReleasePresent "reflector" "kube-system") -and $proxyConfigOk
            [PSCustomObject]@{ Found = $found }
        }
    }

    $installed = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($groupName in $groupChecks.Keys) {
        if ($groupName -eq "Storage (Longhorn)" -and $Platform -ne "RKE2 (On-Premise)") { continue }

        $result = Invoke-ScriptBlockWithSpinner -Message "Checking $groupName..." `
            -ScriptBlock $groupChecks[$groupName] -ArgumentList @($env:PATH, $env:KUBECONFIG, $onPremOrKind, $Platform) |
            Select-Object -Last 1
        $found = $result.Found
        if ($found) { [void]$installed.Add($groupName) }
        $mark  = if ($found) { "✓" } else { "-" }
        $color = if ($found) { "Green" } else { "DarkGray" }
        $status = if ($found) { "already installed" } else { "not yet installed" }
        Write-Host "  $mark $groupName — $status" -ForegroundColor $color
    }

    # Comma operator prevents PowerShell from enumerating the HashSet onto the
    # pipeline — without it, an empty HashSet unrolls to zero objects and the
    # caller's assignment becomes $null instead of an empty collection.
    return ,$installed
}

Export-ModuleMember -Function Test-CommandExists, Install-Kubectl, Install-Helm, Install-RancherCli, Install-PlatformTools, Initialize-Rke2Cluster, Initialize-ClusterEnvironment, Update-HostsFile, Get-AksIngressIp, Get-EksIngressIp, Confirm-KubectlContext, Reset-StuckHelmRelease, Get-IngressClass, Set-RancherProjectAssignment, Get-PreinstalledGroups, Get-PortalIconDataUri, Test-Rke2SecretsEncryptionStatus, Test-Rke2AuditLoggingStatus, Get-Rke2ServerNodes, Enable-Rke2SecretsEncryption, Enable-Rke2AuditLogging
