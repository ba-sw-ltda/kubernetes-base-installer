<#
.SYNOPSIS
    Install MetalLB
.DESCRIPTION
    Installs MetalLB load balancer for on-premise and local Kubernetes clusters.
    Kind:  pools are auto-detected from the docker Kind network (IPv4 + IPv6).
    RKE2:  creates a dedicated ingress-pool with the IP your DNS points to.
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
.PARAMETER Platform
    Target platform (RKE2, Kind)
.PARAMETER NginxIp
    IP address for the nginx LoadBalancer pool (RKE2 only — collected via Prompt.ps1)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$Platform,
    [string]$NginxIp
)

$ScriptRoot = $PSScriptRoot
$BaseDir = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose = $VerbosePreference -eq 'Continue'

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 12 - MetalLB" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath

$ChartName       = $FullConfig.ChartName
$ChartVersion    = $FullConfig.Version
$Repository      = $FullConfig.Repository
$Namespace       = $FullConfig.Namespace
$CreateNamespace = $FullConfig.CreateNamespace
$UserConfig      = $FullConfig.UserConfig

Write-Host "  Chart:      $ChartName $ChartVersion" -ForegroundColor Gray
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray

# Resolve pools per platform
if ($Platform -eq "RKE2 (On-Premise)") {
    if ([string]::IsNullOrWhiteSpace($NginxIp)) {
        Write-Error "NginxIp is required for RKE2. Run via Install-Base.ps1 or pass -NginxIp directly."
        exit 1
    }
    Write-Host "  ingress pool: $NginxIp  ($($UserConfig.IngressPoolName))" -ForegroundColor Gray
} else {
    # Kind: auto-detect IPv4 + IPv6 from docker network
    $allSubnets = & docker network inspect kind --format "{{range .IPAM.Config}}{{.Subnet}} {{end}}" 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($allSubnets)) {
        Write-Error "Could not detect Kind docker network. Is the cluster running?"
        exit 1
    }
    $subnets = $allSubnets -split '\s+' | Where-Object { $_ }

    $v4Subnet = $subnets | Where-Object { $_ -notmatch ':' } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($v4Subnet)) {
        Write-Error "No IPv4 subnet found in Kind docker network."
        exit 1
    }
    $octets   = ($v4Subnet.Trim() -split '/')[0] -split '\.'
    $kindIpv4 = "$($octets[0]).$($octets[1]).255.200-$($octets[0]).$($octets[1]).255.250"

    $v6Subnet = $subnets | Where-Object { $_ -match ':' } | Select-Object -First 1
    $kindIpv6 = $null
    if (-not [string]::IsNullOrWhiteSpace($v6Subnet)) {
        $v6Prefix = ($v6Subnet -split '/')[0].TrimEnd(':')
        $kindIpv6 = "${v6Prefix}::200-${v6Prefix}::250"
    }

    Write-Host "  IPv4 pool:  $kindIpv4  ($($UserConfig.PoolName)-v4, auto-detected)" -ForegroundColor Gray
    if ($kindIpv6) { Write-Host "  IPv6 pool:  $kindIpv6  ($($UserConfig.PoolName)-v6, auto-detected)" -ForegroundColor Gray }
}

Write-Host ""

$exitCode = Invoke-WithSpinner -Message "Adding Helm repository..." -Executable "helm" `
    -Arguments @("repo", "add", "metallb", $Repository, "--force-update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to add Helm repository"; exit 1 }

$exitCode = Invoke-WithSpinner -Message "Updating Helm repositories..." -Executable "helm" `
    -Arguments @("repo", "update") -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to update Helm repositories"; exit 1 }
Write-Host "  ✓ Repository ready" -ForegroundColor Green

if ($CreateNamespace) {
    & kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
    Write-Host "  ✓ Namespace ready" -ForegroundColor Green
}

$HelmArgs = @(
    "upgrade", "--install", "metallb", "metallb/$ChartName",
    "--namespace", $Namespace,
    "--version", $ChartVersion,
    "--set", "controller.resources.limits.cpu=$($UserConfig.Resources.Limits.Cpu)",
    "--set", "controller.resources.limits.memory=$($UserConfig.Resources.Limits.Memory)",
    "--set", "controller.resources.requests.cpu=$($UserConfig.Resources.Requests.Cpu)",
    "--set", "controller.resources.requests.memory=$($UserConfig.Resources.Requests.Memory)"
)

$exitCode = Invoke-WithSpinner -Message "Deploying MetalLB..." -Executable "helm" `
    -Arguments $HelmArgs -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to deploy MetalLB (exit code $exitCode)"; exit 1 }
Write-Host "  ✓ Deployed" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for metallb-controller..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/metallb-controller", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of metallb-controller did not complete"; exit 1 }
Write-Host "  ✓ metallb-controller ready" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for metallb-speaker..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "daemonset/metallb-speaker", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Rollout of metallb-speaker did not complete"; exit 1 }
Write-Host "  ✓ metallb-speaker ready" -ForegroundColor Green

$exitCode = Invoke-WithSpinner -Message "Waiting for MetalLB CRDs..." -Executable "kubectl" `
    -Arguments @("wait", "--for=condition=established", "--timeout=2m",
                 "crd/ipaddresspools.metallb.io", "crd/l2advertisements.metallb.io") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "MetalLB CRDs did not become established in time"; exit 1 }
Write-Host "  ✓ CRDs ready" -ForegroundColor Green

# Build pool YAML per platform
if ($Platform -eq "RKE2 (On-Premise)") {
    # MetalLB requires CIDR or range notation — auto-append /32 for bare IPs
    $nginxIpAddr = if ($NginxIp -match '[/\-]') { $NginxIp } else { "$NginxIp/32" }
    $poolYaml = @"
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: $($UserConfig.IngressPoolName)
  namespace: $Namespace
spec:
  addresses:
  - $nginxIpAddr
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: $($UserConfig.IngressPoolName)
  namespace: $Namespace
spec:
  ipAddressPools:
  - $($UserConfig.IngressPoolName)
"@
} else {
    $poolYaml = @"
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: $($UserConfig.PoolName)-v4
  namespace: $Namespace
spec:
  addresses:
  - $kindIpv4
"@
    if ($kindIpv6) {
        $poolYaml += @"

---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: $($UserConfig.PoolName)-v6
  namespace: $Namespace
spec:
  addresses:
  - $kindIpv6
"@
    }
    $poolNames  = @("$($UserConfig.PoolName)-v4")
    if ($kindIpv6) { $poolNames += "$($UserConfig.PoolName)-v6" }
    $poolList   = ($poolNames | ForEach-Object { "  - $_" }) -join "`n"
    $poolYaml  += @"

---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: $($UserConfig.PoolName)
  namespace: $Namespace
spec:
  ipAddressPools:
$poolList
"@
}

$applyOutput = $poolYaml | & kubectl apply -f - 2>&1
if ($LASTEXITCODE -ne 0) {
    foreach ($line in $applyOutput) { Write-Host $line -ForegroundColor Red }
    Write-Error "Failed to configure IP address pools"; exit 1
}

if ($Platform -eq "RKE2 (On-Premise)") {
    Write-Host "  ✓ Pool '$($UserConfig.IngressPoolName)' configured ($NginxIp)" -ForegroundColor Green
} else {
    Write-Host "  ✓ Pool '$($UserConfig.PoolName)-v4' configured ($kindIpv4)" -ForegroundColor Green
    if ($kindIpv6) { Write-Host "  ✓ Pool '$($UserConfig.PoolName)-v6' configured ($kindIpv6)" -ForegroundColor Green }
}

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Expose a service via MetalLB:" -ForegroundColor Gray
Write-Host "    spec.type: LoadBalancer" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Pin to a specific pool (annotation):" -ForegroundColor Gray
Write-Host "    metallb.universe.tf/address-pool: <pool-name>" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

# IP im State-File persistieren damit Prompt.ps1 sie beim nächsten Mal als Default anbieten kann
if ($Platform -eq "RKE2 (On-Premise)" -and -not [string]::IsNullOrWhiteSpace($NginxIp)) {
    $stateFile = Join-Path $BaseDir ".rke2-state.json"
    if (Test-Path $stateFile) {
        $state = Get-Content $stateFile | ConvertFrom-Json -AsHashtable
        $state['LoadBalancerIP'] = $NginxIp
        $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
