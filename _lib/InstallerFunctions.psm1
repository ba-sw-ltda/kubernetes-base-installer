<#
.SYNOPSIS
    Module for installing prerequisites (kubectl, helm, cloud CLIs) and configuring kubectl.
#>

$Script:ToolsDir = Join-Path $PSScriptRoot "..\.tools" | Resolve-Path -ErrorAction SilentlyContinue
if (-not $Script:ToolsDir) { $Script:ToolsDir = Join-Path $PSScriptRoot "..\.tools" }

if (-not (Test-Path $Script:ToolsDir)) {
    New-Item -ItemType Directory -Path $Script:ToolsDir -Force | Out-Null
}

if ($env:PATH -notlike "*$Script:ToolsDir*") {
    $env:PATH = "$Script:ToolsDir;$env:PATH"
}

function Test-CommandExists {
    param([string]$Command)
    return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-Os {
    $os = "windows"
    $arch = "amd64"
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if ($IsMacOS)   { $os = "darwin" }
        elseif ($IsLinux) { $os = "linux" }
        if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { $arch = "arm64" }
    }
    return $os, $arch
}

# -------------------------
# kubectl
# -------------------------
function Install-Kubectl {
    $path = Join-Path $Script:ToolsDir "kubectl.exe"

    if (-not (Test-Path $path)) {
        $version = "v1.29.0"
        $os, $arch = Get-Os
        $ext = if ($os -eq "windows") { ".exe" } else { "" }
        $url = "https://dl.k8s.io/release/$version/bin/$os/$arch/kubectl$ext"

        Write-Host "  Downloading kubectl $version..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
            if ($os -ne "windows") { chmod +x $path }
        } catch {
            Write-Error "Failed to download kubectl: $_"
            exit 1
        }
    }

    $v = & $path version --client 2>&1 | Select-String "Client Version|GitVersion" | Select-Object -First 1
    Write-Host "  ✓ kubectl: $($v.ToString().Trim())" -ForegroundColor Green
}

# -------------------------
# Helm
# -------------------------
function Install-Helm {
    $path = Join-Path $Script:ToolsDir "helm.exe"

    if (-not (Test-Path $path)) {
        $version = "v3.13.3"
        $zip = Join-Path $Script:ToolsDir "helm.zip"
        $url = "https://get.helm.sh/helm-$version-windows-amd64.zip"

        Write-Host "  Downloading helm $version..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            $tmp = Join-Path $Script:ToolsDir "helm-tmp"
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $exe = Get-ChildItem -Path $tmp -Recurse -Filter "helm.exe" | Select-Object -First 1
            if (-not $exe) { throw "helm.exe not found in archive" }
            Copy-Item -Path $exe.FullName -Destination $path -Force
        } catch {
            Write-Error "Failed to download helm: $_"
            exit 1
        } finally {
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $Script:ToolsDir "helm-tmp") -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $v = & $path version --short 2>&1
    Write-Host "  ✓ helm: $($v.ToString().Trim())" -ForegroundColor Green
}

# -------------------------
# Cloud CLI (platform-specific)
# -------------------------
function Install-PlatformTools {
    param([string]$Platform)

    switch ($Platform) {
        "Azure AKS" {
            # Add known install paths to session PATH before checking — CLI may already
            # be installed but missing from this session's PATH if installed previously
            foreach ($p in @("C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin", "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin")) {
                if ((Test-Path $p) -and $env:Path -notlike "*$p*") { $env:Path = "$p;$env:Path" }
            }

            if (-not (Test-CommandExists "az")) {
                Write-Host "  Downloading Azure CLI..." -ForegroundColor Cyan
                $msi = Join-Path $env:TEMP "AzureCLI.msi"
                $log = Join-Path $env:TEMP "AzureCLI_Install.log"
                Invoke-WebRequest -Uri "https://aka.ms/installazurecliwindows" -OutFile $msi -UseBasicParsing
                $proc = Start-Process msiexec.exe -Wait -PassThru -Verb RunAs -ArgumentList "/i `"$msi`" /qn /L*v `"$log`""
                Remove-Item $msi -Force -ErrorAction SilentlyContinue
                if ($proc.ExitCode -ne 0) { Write-Error "Azure CLI install failed (code $($proc.ExitCode)). Log: $log"; exit 1 }
                foreach ($p in @("C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin", "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin")) {
                    if ((Test-Path $p) -and $env:Path -notlike "*$p*") { $env:Path = "$p;$env:Path"; break }
                }
            }
            $v = & az version 2>&1 | ConvertFrom-Json
            Write-Host "  ✓ az: $($v.'azure-cli')" -ForegroundColor Green
        }

        "AWS EKS" {
            foreach ($p in @("C:\Program Files\Amazon\AWSCLIV2", "C:\Program Files (x86)\Amazon\AWSCLIV2")) {
                if ((Test-Path $p) -and $env:Path -notlike "*$p*") { $env:Path = "$p;$env:Path" }
            }

            if (-not (Test-CommandExists "aws")) {
                Write-Host "  Downloading AWS CLI..." -ForegroundColor Cyan
                $msi = Join-Path $env:TEMP "AWSCLIV2.msi"
                $log = Join-Path $env:TEMP "AWSCLI_Install.log"
                Invoke-WebRequest -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" -OutFile $msi -UseBasicParsing
                $proc = Start-Process msiexec.exe -Wait -PassThru -Verb RunAs -ArgumentList "/i `"$msi`" /qn /L*v `"$log`""
                Remove-Item $msi -Force -ErrorAction SilentlyContinue
                if ($proc.ExitCode -ne 0) { Write-Error "AWS CLI install failed (code $($proc.ExitCode)). Log: $log"; exit 1 }
                foreach ($p in @("C:\Program Files\Amazon\AWSCLIV2", "C:\Program Files (x86)\Amazon\AWSCLIV2")) {
                    if ((Test-Path $p) -and $env:Path -notlike "*$p*") { $env:Path = "$p;$env:Path"; break }
                }
            }
            $v = & aws --version 2>&1
            Write-Host "  ✓ aws: $($v.ToString().Trim())" -ForegroundColor Green

            $eksctlPath = Join-Path $Script:ToolsDir "eksctl.exe"
            if (-not (Test-Path $eksctlPath)) {
                Write-Host "  Downloading eksctl..." -ForegroundColor Cyan
                $zip = Join-Path $env:TEMP "eksctl.zip"
                try {
                    Invoke-WebRequest -Uri "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Windows_amd64.zip" -OutFile $zip -UseBasicParsing
                    $tmp = Join-Path $env:TEMP "eksctl-tmp"
                    Expand-Archive -Path $zip -DestinationPath $tmp -Force
                    $exe = Get-ChildItem -Path $tmp -Recurse -Filter "eksctl.exe" | Select-Object -First 1
                    if (-not $exe) { throw "eksctl.exe not found in archive" }
                    Copy-Item -Path $exe.FullName -Destination $eksctlPath -Force
                } catch {
                    Write-Error "Failed to download eksctl: $_"; exit 1
                } finally {
                    Remove-Item $zip -Force -ErrorAction SilentlyContinue
                    Remove-Item (Join-Path $env:TEMP "eksctl-tmp") -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            $v = & $eksctlPath version 2>&1
            Write-Host "  ✓ eksctl: $($v.ToString().Trim())" -ForegroundColor Green
        }

        "Google GKE" {
            if (-not (Test-CommandExists "gcloud")) {
                Write-Host "  Downloading Google Cloud SDK..." -ForegroundColor Cyan
                $exe = Join-Path $env:TEMP "gcloud-installer.exe"
                Invoke-WebRequest -Uri "https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe" -OutFile $exe -UseBasicParsing
                $proc = Start-Process -FilePath $exe -Wait -PassThru -ArgumentList "/S" -NoNewWindow
                Remove-Item $exe -Force -ErrorAction SilentlyContinue
                if ($proc.ExitCode -ne 0) { Write-Error "Google Cloud SDK install failed (code $($proc.ExitCode))"; exit 1 }
                foreach ($p in @("C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin", "C:\Program Files\Google\Cloud SDK\google-cloud-sdk\bin", "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin")) {
                    if ((Test-Path $p) -and $env:Path -notlike "*$p*") { $env:Path = "$p;$env:Path"; break }
                }
            }
            $v = & gcloud version 2>&1 | Select-String "Google Cloud SDK" | Select-Object -First 1
            Write-Host "  ✓ gcloud: $($v.ToString().Trim())" -ForegroundColor Green

            # Check PATH first, then the gcloud bin directory directly
            $pluginCmd = Get-Command "gke-gcloud-auth-plugin" -ErrorAction SilentlyContinue
            if (-not $pluginCmd) {
                $gcloudExe = (Get-Command "gcloud" -ErrorAction SilentlyContinue).Source
                $gcloudBin = if ($gcloudExe) { Split-Path $gcloudExe -Parent } else { $null }
                $pluginExe = if ($gcloudBin) { Join-Path $gcloudBin "gke-gcloud-auth-plugin.exe" } else { $null }
                if ($pluginExe -and (Test-Path $pluginExe)) {
                    if ($env:PATH -notlike "*$gcloudBin*") { $env:PATH = "$gcloudBin;$env:PATH" }
                    Write-Host "  ✓ gke-gcloud-auth-plugin found in gcloud bin" -ForegroundColor Green
                } else {
                    # gcloud blocks bundled Python in non-interactive mode (Start-Job counts as non-interactive).
                    # Fix: copy-bundled-python returns a standalone Python path we can pass as CLOUDSDK_PYTHON
                    # into the Start-Job via Invoke-WithSpinner's EnvVars parameter.
                    $extraEnv = @{}
                    $copiedPython = & gcloud components copy-bundled-python 2>&1 |
                        Where-Object { "$_".Trim() -ne "" -and "$_" -notmatch "^(WARNING|ERROR|System\.)" } |
                        Select-Object -Last 1
                    if ($copiedPython -and (Test-Path "$copiedPython")) {
                        $extraEnv["CLOUDSDK_PYTHON"] = "$copiedPython"
                    }
                    $exitCode = Invoke-WithSpinner -Message "Installing gke-gcloud-auth-plugin..." `
                        -Executable "gcloud" -Arguments @("components", "install", "gke-gcloud-auth-plugin", "--quiet") `
                        -EnvVars $extraEnv
                    if ($exitCode -eq 0) {
                        if ($gcloudBin -and $env:PATH -notlike "*$gcloudBin*") { $env:PATH = "$gcloudBin;$env:PATH" }
                        Write-Host "  ✓ gke-gcloud-auth-plugin installed" -ForegroundColor Green
                    } else {
                        Write-Host "  ⚠ Could not auto-install gke-gcloud-auth-plugin" -ForegroundColor Yellow
                        Write-Host "    Run manually: gcloud components install gke-gcloud-auth-plugin" -ForegroundColor Yellow
                    }
                }
            }
        }

        "Kind (Local)" {
            $path = Join-Path $Script:ToolsDir "kind.exe"
            if (-not (Test-Path $path)) {
                Write-Host "  Downloading kind..." -ForegroundColor Cyan
                $url = "https://github.com/kubernetes-sigs/kind/releases/download/v0.20.0/kind-windows-amd64"
                try {
                    Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
                } catch {
                    Write-Error "Failed to download kind: $_"
                    exit 1
                }
            }
            $v = & $path version 2>&1
            Write-Host "  ✓ kind: $($v.ToString().Trim())" -ForegroundColor Green
        }

        "RKE2 (On-Premise)" {
            $plinkPath = Join-Path $Script:ToolsDir "plink.exe"
            if (-not (Test-Path $plinkPath) -and -not (Get-Command "plink.exe" -ErrorAction SilentlyContinue)) {
                Write-Host "  Downloading plink.exe (PuTTY)..." -ForegroundColor Cyan
                try {
                    Invoke-WebRequest -Uri "https://the.earth.li/~sgtatham/putty/latest/w64/plink.exe" `
                        -OutFile $plinkPath -UseBasicParsing
                    Write-Host "  ✓ plink.exe downloaded" -ForegroundColor Green
                } catch {
                    Write-Warning "  ⚠ Could not download plink.exe — password SSH will not be available"
                }
            } else {
                Write-Host "  ✓ plink: available" -ForegroundColor Green
            }
            if ((Test-Path $plinkPath) -and $env:PATH -notlike "*$Script:ToolsDir*") {
                $env:PATH = "$Script:ToolsDir;$env:PATH"
            }
        }
    }
}

# -------------------------
# Hosts file update (Kind — single UAC elevation, all hostnames at once)
# -------------------------
function Update-HostsFile {
    param(
        [string[]]$Hostnames,
        [string]$IpAddress = "127.0.0.1"
    )

    $hostsFile = "C:\Windows\System32\drivers\etc\hosts"
    $lines     = if (Test-Path $hostsFile) { Get-Content $hostsFile -Encoding UTF8 } else { @() }

    $toAdd    = [System.Collections.Generic.List[string]]::new()
    $toUpdate = [System.Collections.Generic.List[string]]::new()

    foreach ($h in ($Hostnames | Where-Object { $_ })) {
        $existingLine = $lines | Where-Object { $_ -match "\s+$([regex]::Escape($h))(\s|$)" } | Select-Object -First 1
        if (-not $existingLine) {
            $toAdd.Add($h)
        } elseif ($existingLine -notmatch "^$([regex]::Escape($IpAddress))\s") {
            $toUpdate.Add($h)
        }
    }

    if ($toAdd.Count -eq 0 -and $toUpdate.Count -eq 0) {
        Write-Host "  ✓ All hostnames already in hosts file with correct IP" -ForegroundColor Green
        return
    }

    # Build new hosts file content: replace outdated lines, append new ones
    $updatedLines = $lines | ForEach-Object {
        $line = $_
        $matched = $toUpdate | Where-Object { $line -match "\s+$([regex]::Escape($_))(\s|$)" } | Select-Object -First 1
        if ($matched) { "$IpAddress`t$matched" } else { $line }
    }
    foreach ($h in $toAdd) { $updatedLines += "$IpAddress`t$h" }

    $newContent = ($updatedLines -join "`r`n") + "`r`n"
    $tempEntry  = Join-Path $env:TEMP "hosts-update.txt"
    Set-Content -Path $tempEntry -Value $newContent -Encoding UTF8 -NoNewline

    $tempScript = Join-Path $env:TEMP "hosts-elevated.ps1"
    $scriptContent = @(
        "`$ErrorActionPreference = 'Stop'"
        "try {"
        "  Set-Content -Path '$hostsFile' -Value (Get-Content -Path '$tempEntry' -Raw -Encoding UTF8) -Encoding UTF8 -NoNewline"
        "  exit 0"
        "} catch { Write-Error `$_; exit 1 }"
    ) -join "`n"
    Set-Content -Path $tempScript -Value $scriptContent -Encoding UTF8

    $proc = Start-Process pwsh -Verb RunAs `
        -ArgumentList "-NonInteractive", "-File", "`"$tempScript`"" `
        -Wait -PassThru
    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    Remove-Item $tempEntry  -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -ne 0) { Write-Error "Failed to update hosts file"; exit 1 }

    foreach ($h in $toUpdate) { Write-Host "  ✓ Updated: $IpAddress`t$h" -ForegroundColor Green }
    foreach ($h in $toAdd)    { Write-Host "  ✓ Added:   $IpAddress`t$h" -ForegroundColor Green }
}

# -------------------------
# kubectl context configuration
# -------------------------
function Reset-StuckHelmRelease {
    param(
        [string]$ReleaseName,
        [string]$Namespace
    )
    $statusOutput = & helm status $ReleaseName --namespace $Namespace --output json 2>&1
    if ($LASTEXITCODE -ne 0) { return }  # release does not exist, nothing to do

    try {
        $releaseStatus = ($statusOutput | ConvertFrom-Json).info.status
        if ($releaseStatus -notin @("pending-install", "pending-upgrade", "pending-rollback", "failed")) { return }

        Write-Host "  ⚠ Release '$ReleaseName' in state '$releaseStatus' — resetting..." -ForegroundColor Yellow

        # failed releases cannot be rolled back — uninstall directly so next run is a clean install
        if ($releaseStatus -ne "failed") {
            & helm rollback $ReleaseName --namespace $Namespace 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  ✓ Release reset via rollback" -ForegroundColor Green
                return
            }
        }

        # Use --no-hooks to bypass pre-delete hooks that may also be broken
        & helm uninstall $ReleaseName --namespace $Namespace --no-hooks 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ✗ helm uninstall failed — cannot reset release '$ReleaseName'" -ForegroundColor Red
            return $false
        }

        Write-Host "  ✓ Failed release uninstalled — will do fresh install" -ForegroundColor Green
        return $true
    } catch { }
}

function Confirm-KubectlContext {
    param([string]$ExpectedContext)

    $current = & kubectl config current-context 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($current)) {
        Write-Error "kubectl has no active context after get-credentials — kubeconfig may not have been updated"
        exit 1
    }

    if ($current.Trim() -ne $ExpectedContext) {
        Write-Warning "  ⚠ kubectl context is '$($current.Trim())' but expected '$ExpectedContext'"
        Write-Warning "    Run: kubectl config use-context $ExpectedContext"
        & kubectl config use-context $ExpectedContext 2>&1 | Out-Null
        $current = & kubectl config current-context 2>&1
        if ($current.Trim() -ne $ExpectedContext) {
            Write-Error "Failed to switch kubectl context to '$ExpectedContext'"
            exit 1
        }
    }

    Write-Host "  ✓ kubectl context: $($current.Trim())" -ForegroundColor Green
}

function Get-AksIngressIp {
    param(
        [string]$Namespace   = "ingress-nginx",
        [string]$ServiceName = "ingress-nginx-controller",
        [int]$TimeoutSeconds = 300
    )

    Write-Host "  Waiting for ingress LoadBalancer IP..." -ForegroundColor Cyan
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $ip = & kubectl get svc $ServiceName -n $Namespace -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
        if ($ip -and $ip -match '^\d+\.\d+\.\d+\.\d+$') {
            Write-Host "  ✓ External IP: $ip" -ForegroundColor Green
            return $ip
        }
        Start-Sleep -Seconds 10
        $elapsed += 10
        Write-Host "    Still waiting... (${elapsed}s / ${TimeoutSeconds}s)" -ForegroundColor DarkGray
    }
    Write-Warning "  ⚠ Could not determine external IP within $TimeoutSeconds seconds"
    return $null
}

function Get-EksIngressIp {
    param(
        [string]$Namespace   = "ingress-nginx",
        [string]$ServiceName = "ingress-nginx-controller",
        [int]$TimeoutSeconds = 300
    )

    Write-Host "  Waiting for ingress LoadBalancer hostname..." -ForegroundColor Cyan
    $elapsed  = 0
    $hostname = $null
    while ($elapsed -lt $TimeoutSeconds) {
        $hostname = & kubectl get svc $ServiceName -n $Namespace -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>$null
        if (-not [string]::IsNullOrWhiteSpace($hostname)) {
            Write-Host "  ✓ LoadBalancer hostname: $hostname" -ForegroundColor Green
            break
        }
        Start-Sleep -Seconds 10
        $elapsed += 10
        Write-Host "    Still waiting... (${elapsed}s / ${TimeoutSeconds}s)" -ForegroundColor DarkGray
    }

    if ([string]::IsNullOrWhiteSpace($hostname)) {
        Write-Warning "  ⚠ Could not determine LoadBalancer hostname within $TimeoutSeconds seconds"
        return $null
    }

    try {
        $ip = [System.Net.Dns]::GetHostAddresses($hostname) |
              Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
              Select-Object -First 1
        if ($ip) {
            Write-Host "  ✓ Resolved IP: $($ip.IPAddressToString)" -ForegroundColor Green
            return $ip.IPAddressToString
        }
    } catch { }
    Write-Warning "  ⚠ Could not resolve '$hostname' to an IP address"
    return $null
}

function Initialize-AksCluster {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroup,
        [string]$Location,
        [string]$ClusterName,
        [int]$NodeCount        = 1,
        [string]$VmSize        = "Standard_D2s_v3",
        [bool]$ReplaceCluster  = $false,
        [bool]$UseExisting     = $false
    )

    & az account show 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "  Azure login required. Open the following URL in your browser:" -ForegroundColor Cyan
        Write-Host "    https://microsoft.com/devicelogin" -ForegroundColor Yellow
        Write-Host "  Then enter the code shown below." -ForegroundColor Cyan
        Write-Host ""
        & az login --use-device-code
        if ($LASTEXITCODE -ne 0) { Write-Error "Azure login failed"; exit 1 }
    }

    $exitCode = Invoke-WithSpinner -Message "Setting subscription '$SubscriptionId'..." -Executable "az" `
        -Arguments @("account", "set", "--subscription", $SubscriptionId)
    if ($exitCode -ne 0) { Write-Error "Failed to set subscription '$SubscriptionId'"; exit 1 }
    Write-Host "  ✓ Subscription set" -ForegroundColor Green

    $kubefile = Join-Path $env:USERPROFILE ".kube\aks-$ClusterName.yaml"
    $env:KUBECONFIG = $kubefile

    if ($UseExisting) {
        $exitCode = Invoke-WithSpinner -Message "Fetching credentials for '$ClusterName'..." -Executable "az" `
            -Arguments @("aks", "get-credentials", "--resource-group", $ResourceGroup, "--name", $ClusterName, "--overwrite-existing", "--file", $kubefile)
        if ($exitCode -ne 0) { Write-Error "Failed to get credentials for '$ClusterName'"; exit 1 }
        Confirm-KubectlContext -ExpectedContext $ClusterName
        return
    }

    if ($ReplaceCluster) {
        $rgExists = & az group exists --name $ResourceGroup 2>$null
        if ($rgExists -eq "true") {
            $exitCode = Invoke-WithSpinner -Message "Deleting resource group '$ResourceGroup' (this may take several minutes)..." `
                -Executable "az" -Arguments @("group", "delete", "--name", $ResourceGroup, "--yes")
            if ($exitCode -ne 0) { Write-Warning "  ⚠ Resource group delete returned non-zero — continuing" }
            else { Write-Host "  ✓ Resource group deleted" -ForegroundColor Green }
        } else {
            Write-Host "  ✓ Resource group '$ResourceGroup' does not exist — skipping delete" -ForegroundColor Green
        }
    }

    $exitCode = Invoke-WithSpinner -Message "Creating resource group '$ResourceGroup' in $Location..." -Executable "az" `
        -Arguments @("group", "create", "--name", $ResourceGroup, "--location", $Location)
    if ($exitCode -ne 0) { Write-Error "Failed to create resource group '$ResourceGroup'"; exit 1 }
    Write-Host "  ✓ Resource group ready" -ForegroundColor Green

    & az aks show --resource-group $ResourceGroup --name $ClusterName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $exitCode = Invoke-WithSpinner -Message "Registering Microsoft.ContainerService provider (once per subscription)..." -Executable "az" `
            -Arguments @("provider", "register", "--namespace", "Microsoft.ContainerService", "--wait")
        if ($exitCode -ne 0) { Write-Error "Failed to register Microsoft.ContainerService provider"; exit 1 }
        Write-Host "  ✓ Provider registered" -ForegroundColor Green

        $exitCode = Invoke-WithSpinner -Message "Creating AKS cluster '$ClusterName' ($NodeCount x $VmSize) — this takes 5-10 minutes..." `
            -Executable "az" -Arguments @(
                "aks", "create",
                "--resource-group", $ResourceGroup,
                "--name", $ClusterName,
                "--node-count", "$NodeCount",
                "--node-vm-size", $VmSize,
                "--location", $Location,
                "--generate-ssh-keys",
                "--network-plugin", "azure"
            )
        if ($exitCode -ne 0) { Write-Error "Failed to create AKS cluster '$ClusterName'"; exit 1 }
        Write-Host "  ✓ AKS cluster '$ClusterName' created" -ForegroundColor Green
    } else {
        Write-Host "  ✓ Cluster '$ClusterName' already exists — skipping creation" -ForegroundColor Yellow
    }

    $exitCode = Invoke-WithSpinner -Message "Fetching kubectl credentials..." -Executable "az" `
        -Arguments @("aks", "get-credentials", "--resource-group", $ResourceGroup, "--name", $ClusterName, "--overwrite-existing", "--file", $kubefile)
    if ($exitCode -ne 0) { Write-Error "Failed to get credentials for '$ClusterName'"; exit 1 }
    Confirm-KubectlContext -ExpectedContext $ClusterName
}

function Initialize-EksCluster {
    param(
        [string]$AccessKeyId,
        [string]$SecretAccessKey,
        [string]$Region,
        [string]$ClusterName,
        [int]$NodeCount       = 1,
        [string]$NodeType     = "t3.large",
        [bool]$ReplaceCluster = $false,
        [bool]$UseExisting    = $false
    )

    & aws configure set default.region $Region 2>&1 | Out-Null
    & aws sts get-caller-identity 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        if (-not $AccessKeyId -or -not $SecretAccessKey) {
            Write-Error "AWS authentication failed — credentials not configured. Re-run Install-Base.ps1."
            exit 1
        }
        Write-Host "  Configuring AWS credentials..." -ForegroundColor Cyan
        & aws configure set aws_access_key_id $AccessKeyId 2>&1 | Out-Null
        & aws configure set aws_secret_access_key $SecretAccessKey 2>&1 | Out-Null
        & aws sts get-caller-identity 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Error "AWS authentication failed — check Access Key ID and Secret"; exit 1 }
    }
    Write-Host "  ✓ AWS authenticated" -ForegroundColor Green

    $kubefile = Join-Path $env:USERPROFILE ".kube\eks-$ClusterName.yaml"
    $env:KUBECONFIG = $kubefile

    if ($UseExisting) {
        $exitCode = Invoke-WithSpinner -Message "Fetching credentials for '$ClusterName'..." -Executable "aws" `
            -Arguments @("eks", "update-kubeconfig", "--region", $Region, "--name", $ClusterName, "--kubeconfig", $kubefile)
        if ($exitCode -ne 0) { Write-Error "Failed to get credentials for '$ClusterName'"; exit 1 }
        $ctx = (& kubectl config current-context 2>&1).Trim()
        Write-Host "  ✓ kubectl context: $ctx" -ForegroundColor Green
        return
    }

    $eksctlPath = Join-Path $Script:ToolsDir "eksctl.exe"

    if ($ReplaceCluster) {
        $exitCode = Invoke-WithSpinner -Message "Deleting EKS cluster '$ClusterName' (this may take several minutes)..." `
            -Executable $eksctlPath -Arguments @("delete", "cluster", "--name", $ClusterName, "--region", $Region)
        if ($exitCode -ne 0) { Write-Warning "  ⚠ Cluster delete returned exit code $exitCode" }
        else { Write-Host "  ✓ Cluster deleted" -ForegroundColor Green }
    }

    & aws eks describe-cluster --region $Region --name $ClusterName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $exitCode = Invoke-WithSpinner `
            -Message "Creating EKS cluster '$ClusterName' ($NodeCount x $NodeType) — this takes 20-40 minutes..." `
            -Executable $eksctlPath `
            -Arguments @("create", "cluster", "--name", $ClusterName, "--region", $Region,
                "--node-type", $NodeType, "--nodes", "$NodeCount", "--timeout", "45m")
        if ($exitCode -ne 0) {
            Write-Host ""
            Write-Host "  ✗ EKS cluster creation failed." -ForegroundColor Red
            Write-Host "  Prüfe CloudFormation Console für Details:" -ForegroundColor Yellow
            Write-Host "    https://console.aws.amazon.com/cloudformation/home?region=$Region" -ForegroundColor Yellow
            Write-Host "  Aufräumen: eksctl delete cluster --region=$Region --name=$ClusterName" -ForegroundColor Yellow
            Write-Error "Failed to create EKS cluster '$ClusterName'"
            exit 1
        }
        Write-Host "  ✓ EKS cluster '$ClusterName' created" -ForegroundColor Green
    } else {
        Write-Host "  ✓ Cluster '$ClusterName' already exists — skipping creation" -ForegroundColor Yellow
    }

    $attempt = 0
    do {
        $exitCode = Invoke-WithSpinner -Message "Fetching kubectl credentials..." -Executable "aws" `
            -Arguments @("eks", "update-kubeconfig", "--region", $Region, "--name", $ClusterName, "--kubeconfig", $kubefile)
        if ($exitCode -ne 0 -and $attempt -lt 3) {
            $attempt++
            Write-Host "  Waiting 30s for API propagation (attempt $attempt/3)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 30
        }
    } while ($exitCode -ne 0 -and $attempt -lt 3)
    if ($exitCode -ne 0) { Write-Error "Failed to get credentials for '$ClusterName'"; exit 1 }
    $ctx = (& kubectl config current-context 2>&1).Trim()
    Write-Host "  ✓ kubectl context: $ctx" -ForegroundColor Green
}

function Initialize-GkeCluster {
    param(
        [string]$ProjectId,
        [string]$Zone,
        [string]$ClusterName,
        [int]$NodeCount       = 1,
        [string]$MachineType  = "e2-standard-4",
        [bool]$ReplaceCluster = $false,
        [bool]$UseExisting    = $false
    )

    $accountRaw = & gcloud config get-value account 2>&1
    $account = if ($accountRaw -is [System.Management.Automation.ErrorRecord]) { "" } else { "$accountRaw".Trim() }
    if ($account -eq "(unset)" -or [string]::IsNullOrWhiteSpace($account)) {
        Write-Host ""
        Write-Host "  Google Cloud login required." -ForegroundColor Cyan
        Write-Host "  Open the URL that appears below in your browser." -ForegroundColor Cyan
        Write-Host ""
        & gcloud auth login --no-launch-browser
        if ($LASTEXITCODE -ne 0) { Write-Error "Google Cloud login failed"; exit 1 }
    }
    Write-Host "  ✓ Google Cloud authenticated" -ForegroundColor Green

    & gcloud config set project $ProjectId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to set project '$ProjectId'"; exit 1 }
    Write-Host "  ✓ Project set: $ProjectId" -ForegroundColor Green

    $kubefile = Join-Path $env:USERPROFILE ".kube\gke-$ClusterName.yaml"
    $env:KUBECONFIG = $kubefile

    if ($UseExisting) {
        $exitCode = Invoke-WithSpinner -Message "Fetching credentials for '$ClusterName'..." -Executable "gcloud" `
            -Arguments @("container", "clusters", "get-credentials", $ClusterName, "--zone", $Zone, "--project", $ProjectId)
        if ($exitCode -ne 0) { Write-Error "Failed to get credentials for '$ClusterName'"; exit 1 }
        $ctx = (& kubectl config current-context 2>&1).Trim()
        Write-Host "  ✓ kubectl context: $ctx" -ForegroundColor Green
        return
    }

    if ($ReplaceCluster) {
        $exitCode = Invoke-WithSpinner -Message "Deleting GKE cluster '$ClusterName' (this may take several minutes)..." `
            -Executable "gcloud" -Arguments @("container", "clusters", "delete", $ClusterName, "--zone", $Zone, "--project", $ProjectId, "--quiet")
        if ($exitCode -ne 0) { Write-Warning "  ⚠ Cluster delete returned exit code $exitCode" }
        else { Write-Host "  ✓ Cluster deleted" -ForegroundColor Green }
    }

    & gcloud container clusters describe $ClusterName --zone $Zone --project $ProjectId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $exitCode = Invoke-WithSpinner -Message "Enabling GKE API (once per project)..." -Executable "gcloud" `
            -Arguments @("services", "enable", "container.googleapis.com", "--project", $ProjectId)
        if ($exitCode -ne 0) { Write-Error "Failed to enable GKE API"; exit 1 }
        Write-Host "  ✓ GKE API enabled — waiting 30s for propagation..." -ForegroundColor Green
        Start-Sleep -Seconds 30

        $exitCode = Invoke-WithSpinner `
            -Message "Creating GKE cluster '$ClusterName' ($NodeCount x $MachineType) — this takes 5-10 minutes..." `
            -Executable "gcloud" `
            -Arguments @("container", "clusters", "create", $ClusterName,
                "--zone", $Zone, "--project", $ProjectId,
                "--num-nodes", "$NodeCount", "--machine-type", $MachineType,
                "--disk-type", "pd-standard", "--disk-size", "50",
                "--no-enable-autoupgrade")
        if ($exitCode -ne 0) { Write-Error "Failed to create GKE cluster '$ClusterName'"; exit 1 }
        Write-Host "  ✓ GKE cluster '$ClusterName' created" -ForegroundColor Green
    } else {
        Write-Host "  ✓ Cluster '$ClusterName' already exists — skipping creation" -ForegroundColor Yellow
    }

    $attempt = 0
    do {
        $exitCode = Invoke-WithSpinner -Message "Fetching kubectl credentials..." -Executable "gcloud" `
            -Arguments @("container", "clusters", "get-credentials", $ClusterName, "--zone", $Zone, "--project", $ProjectId)
        if ($exitCode -ne 0 -and $attempt -lt 3) {  # gcloud respects $env:KUBECONFIG set above
            $attempt++
            Write-Host "  Waiting 30s for API propagation (attempt $attempt/3)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 30
        }
    } while ($exitCode -ne 0 -and $attempt -lt 3)
    if ($exitCode -ne 0) { Write-Error "Failed to get credentials for '$ClusterName'"; exit 1 }

    $ctx = (& kubectl config current-context 2>&1).Trim()
    Write-Host "  ✓ kubectl context: $ctx" -ForegroundColor Green
}

function Initialize-KindCluster {
    param(
        [string]$ClusterName   = "my-kind-cluster",
        [bool]$ReplaceCluster  = $false
    )

    $kindExe    = Join-Path $Script:ToolsDir "kind.exe"
    $existing   = & $kindExe get clusters 2>&1
    $kindConfig = Join-Path $env:TEMP "kind-cluster-config.yaml"

    Set-Content -Path $kindConfig -Value @"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:v1.32.0
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
"@ -Encoding UTF8

    if ($existing -contains $ClusterName) {
        if ($ReplaceCluster) {
            $exitCode = Invoke-WithSpinner -Message "Deleting Kind cluster '$ClusterName'..." `
                -Executable $kindExe -Arguments @("delete", "cluster", "--name", $ClusterName)
            if ($exitCode -ne 0) { Write-Error "Failed to delete Kind cluster '$ClusterName'"; exit 1 }
            Write-Host "  ✓ Cluster deleted" -ForegroundColor Green

            $exitCode = Invoke-WithSpinner -Message "Creating Kind cluster '$ClusterName'..." `
                -Executable $kindExe -Arguments @("create", "cluster", "--name", $ClusterName, "--config", $kindConfig)
            if ($exitCode -ne 0) { Write-Error "Failed to create Kind cluster '$ClusterName'"; exit 1 }
            Write-Host "  ✓ Kind cluster '$ClusterName' created" -ForegroundColor Green
        } else {
            Write-Host "  ✓ Kind cluster '$ClusterName' already exists" -ForegroundColor Green
        }
    } else {
        $exitCode = Invoke-WithSpinner -Message "Creating Kind cluster '$ClusterName'..." `
            -Executable $kindExe -Arguments @("create", "cluster", "--name", $ClusterName, "--config", $kindConfig)
        if ($exitCode -ne 0) { Write-Error "Failed to create Kind cluster '$ClusterName'"; exit 1 }
        Write-Host "  ✓ Kind cluster '$ClusterName' created" -ForegroundColor Green
    }
    Remove-Item $kindConfig -Force -ErrorAction SilentlyContinue

    $kubefile = Join-Path $env:USERPROFILE ".kube\kind-$ClusterName.yaml"
    & $kindExe export kubeconfig --name $ClusterName --kubeconfig $kubefile 2>&1 | Out-Null
    $env:KUBECONFIG = $kubefile
    Write-Host "  ✓ kubectl context set to kind-$ClusterName" -ForegroundColor Green
}

function Initialize-Rke2Cluster {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'SshPassword',
        Justification = 'Password is passed as CLI argument to plink.exe — SecureString provides no benefit here')]
    param(
        [string]$KubeconfigPath = "",
        [string]$SshServer      = "",
        [string]$SshUser        = "root",
        [string]$SshKeyPath     = "",
        [string]$SshPassword    = ""
    )

    if ([string]::IsNullOrWhiteSpace($KubeconfigPath)) {
        $safeName = if ($SshServer) { $SshServer -replace '[^a-zA-Z0-9-]', '-' } else { "rke2" }
        $KubeconfigPath = "$env:USERPROFILE\.kube\rke2-$safeName.yaml"
    }
    $KubeconfigPath = $KubeconfigPath -replace '^~', $env:USERPROFILE

    # Auto-fetch via SSH if server is provided
    if (-not [string]::IsNullOrWhiteSpace($SshServer)) {
        $rawConfig = $null

        if (-not [string]::IsNullOrWhiteSpace($SshPassword)) {
            $plinkExe = Get-Command "plink.exe" -ErrorAction SilentlyContinue
            if (-not $plinkExe) {
                Write-Error "Password-based SSH requires plink.exe. Install PuTTY or use an SSH key instead."
                exit 1
            }
            # Pre-run: accept and cache the host key
            $exitCode = Invoke-WithSpinner -Message "Caching SSH host key for $SshServer..." `
                -Executable "plink.exe" -Arguments @("-ssh", "-pw", $SshPassword, "$SshUser@$SshServer", "exit")
            # Fetch kubeconfig (key is now cached, -batch safe)
            $rawRef = [ref]$null
            $exitCode = Invoke-WithSpinner -Message "Fetching kubeconfig from $SshUser@$SshServer..." `
                -Executable "plink.exe" -Arguments @("-ssh", "-batch", "-pw", $SshPassword, "$SshUser@$SshServer", "cat /etc/rancher/rke2/rke2.yaml") `
                -OutputVariable $rawRef
            $rawConfig = $rawRef.Value
        } else {
            $sshArgs = @("-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes")
            if (-not [string]::IsNullOrWhiteSpace($SshKeyPath)) {
                $SshKeyPath = $SshKeyPath -replace '^~', $env:USERPROFILE
                $sshArgs += @("-i", $SshKeyPath)
            }
            $sshArgs += @("$SshUser@$SshServer", "cat /etc/rancher/rke2/rke2.yaml")
            $rawRef   = [ref]$null
            $exitCode = Invoke-WithSpinner -Message "Fetching kubeconfig from $SshUser@$SshServer..." `
                -Executable "ssh.exe" -Arguments $sshArgs -OutputVariable $rawRef
            $rawConfig = $rawRef.Value
        }

        if ($exitCode -ne 0) { Write-Error "SSH failed — check credentials and server address"; exit 1 }

        # Strip any plink/ssh status lines (stderr mixed in via 2>&1) — keep only the YAML part
        $yamlLines  = @($rawConfig) | ForEach-Object { "$_" }
        $yamlStart  = 0
        for ($i = 0; $i -lt $yamlLines.Count; $i++) {
            if ($yamlLines[$i] -match '^(apiVersion:|---)') { $yamlStart = $i; break }
        }
        $cleanYaml = ($yamlLines[$yamlStart..($yamlLines.Count - 1)] -join "`n")

        # RKE2 kubeconfig has 127.0.0.1 — replace with the actual server IP/VIP
        $patchedConfig = $cleanYaml -replace 'https://127\.0\.0\.1:6443', "https://$SshServer`:6443"

        $kubeconfigDir = Split-Path $KubeconfigPath -Parent
        if (-not (Test-Path $kubeconfigDir)) { New-Item -ItemType Directory -Path $kubeconfigDir -Force | Out-Null }
        Set-Content -Path $KubeconfigPath -Value $patchedConfig -Encoding UTF8
        Write-Host "  ✓ Kubeconfig saved to $KubeconfigPath" -ForegroundColor Green
    } elseif (Test-Path $KubeconfigPath) {
        Write-Host "  ✓ Using existing kubeconfig: $KubeconfigPath" -ForegroundColor Green
    } else {
        Write-Error "Kubeconfig not found at '$KubeconfigPath'. Copy it from your RKE2 server:  scp user@<node1>:/etc/rancher/rke2/rke2.yaml $KubeconfigPath"
        exit 1
    }

    $env:KUBECONFIG = $KubeconfigPath
    Write-Host "  Using kubeconfig: $KubeconfigPath" -ForegroundColor Gray

    $nodesRef = [ref]$null
    $exitCode = Invoke-WithSpinner -Message "Verifying cluster connectivity..." `
        -Executable "kubectl" -Arguments @("get", "nodes", "--no-headers") -OutputVariable $nodesRef
    if ($exitCode -ne 0) {
        Write-Error "Cannot reach cluster. Check kubeconfig and that the cluster is running."
        exit 1
    }
    $nodeCount = ($nodesRef.Value | Measure-Object).Count
    Write-Host "  ✓ Connected — $nodeCount node(s) ready" -ForegroundColor Green
}

function Initialize-ClusterEnvironment {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Rke2SshPassword',
        Justification = 'Password is passed as CLI argument to plink.exe — SecureString provides no benefit here')]
    param(
        [string]$Platform,
        # Kind
        [string]$KindClusterName   = "my-kind-cluster",
        [bool]$KindReplaceCluster  = $false,
        [string]$KindDomain        = "kubernetes.local",
        # AKS
        [string]$AksSubscriptionId = "",
        [string]$AksResourceGroup  = "",
        [string]$AksLocation       = "",
        [string]$AksClusterName    = "",
        [int]$AksNodeCount         = 1,
        [string]$AksVmSize         = "Standard_D2s_v3",
        [bool]$AksReplaceCluster   = $false,
        [bool]$AksUseExisting      = $false,
        # EKS
        [string]$EksAccessKeyId     = "",
        [string]$EksSecretAccessKey = "",
        [string]$EksRegion          = "",
        [string]$EksClusterName     = "",
        [int]$EksNodeCount          = 1,
        [string]$EksNodeType        = "t3.large",
        [bool]$EksReplaceCluster    = $false,
        [bool]$EksUseExisting       = $false,
        # GKE
        [string]$GkeProjectId    = "",
        [string]$GkeZone         = "",
        [string]$GkeClusterName  = "",
        [int]$GkeNodeCount       = 1,
        [string]$GkeMachineType  = "e2-standard-4",
        [bool]$GkeReplaceCluster = $false,
        [bool]$GkeUseExisting    = $false,
        # RKE2
        [string]$Rke2KubeconfigPath = "",
        [string]$Rke2SshServer      = "",
        [string]$Rke2SshUser        = "root",
        [string]$Rke2SshKeyPath     = "",
        [string]$Rke2SshPassword    = ""
    )

    switch ($Platform) {
        "Azure AKS" {
            Initialize-AksCluster `
                -SubscriptionId $AksSubscriptionId -ResourceGroup $AksResourceGroup `
                -Location $AksLocation -ClusterName $AksClusterName `
                -NodeCount $AksNodeCount -VmSize $AksVmSize `
                -ReplaceCluster $AksReplaceCluster -UseExisting $AksUseExisting
        }
        "AWS EKS" {
            Initialize-EksCluster `
                -AccessKeyId $EksAccessKeyId -SecretAccessKey $EksSecretAccessKey `
                -Region $EksRegion -ClusterName $EksClusterName `
                -NodeCount $EksNodeCount -NodeType $EksNodeType `
                -ReplaceCluster $EksReplaceCluster -UseExisting $EksUseExisting
        }
        "Google GKE" {
            Initialize-GkeCluster `
                -ProjectId $GkeProjectId -Zone $GkeZone -ClusterName $GkeClusterName `
                -NodeCount $GkeNodeCount -MachineType $GkeMachineType `
                -ReplaceCluster $GkeReplaceCluster -UseExisting $GkeUseExisting
        }
        "RKE2 (On-Premise)" {
            Initialize-Rke2Cluster -KubeconfigPath $Rke2KubeconfigPath `
                -SshServer $Rke2SshServer -SshUser $Rke2SshUser `
                -SshKeyPath $Rke2SshKeyPath -SshPassword $Rke2SshPassword
        }
        "Kind (Local)" {
            Initialize-KindCluster -ClusterName $KindClusterName -ReplaceCluster $KindReplaceCluster
        }
    }
}

function Get-IngressClass {
    # Prefer the IngressClass annotated as cluster default, fall back to first available.
    $default = & kubectl get ingressclass `
        -o jsonpath='{.items[?(@.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' `
        2>$null
    if ($default) { return $default.Trim() }

    $first = & kubectl get ingressclass -o jsonpath='{.items[0].metadata.name}' 2>$null
    if ($first) { return $first.Trim() }

    return "nginx"  # last-resort fallback
}

Export-ModuleMember -Function Test-CommandExists, Install-Kubectl, Install-Helm, Install-PlatformTools, Initialize-Rke2Cluster, Initialize-ClusterEnvironment, Update-HostsFile, Get-AksIngressIp, Get-EksIngressIp, Confirm-KubectlContext, Reset-StuckHelmRelease, Get-IngressClass
