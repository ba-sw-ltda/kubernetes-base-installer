<#
.SYNOPSIS
    Main script for setting up the Kubernetes base installation.
#>
[CmdletBinding()]
param()

[Console]::TreatControlCAsInput = $false

# Import the modules
Import-Module "$PSScriptRoot/_lib/Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$PSScriptRoot/_lib/InstallerFunctions.psm1" -Force -Verbose:$false

trap {
    Write-Host "`n`n  Installation aborted: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkGray
    Write-Host "" -ForegroundColor DarkGray
    Write-Host "  Stack trace:" -ForegroundColor DarkGray
    $_.ScriptStackTrace -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    exit 1
}

function Start-Installation {

    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║          Kubernetes Base Installer                       ║" -ForegroundColor Cyan
    Write-Host "  ║          AKS · EKS · GKE · RKE2 · Kind                   ║" -ForegroundColor Cyan
    Write-Host "  ╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "  ║  Installs a production-ready K8s stack including:        ║" -ForegroundColor DarkCyan
    Write-Host "  ║  Ingress · Cert-Manager · Vault · Storage · Observ.      ║" -ForegroundColor DarkCyan
    Write-Host "  ║  External Secrets · Reflector · ArgoCD · Rancher         ║" -ForegroundColor DarkCyan
    Write-Host "  ╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "  ║  Copyright (c) 2026 BA Software LTDA                     ║" -ForegroundColor DarkGray
    Write-Host "  ║  MIT License — provided as-is, without warranty          ║" -ForegroundColor DarkGray
    Write-Host "  ║  github.com/ba-sw-ltda/kubernetes-base-installer         ║" -ForegroundColor DarkGray
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  All inputs are collected upfront. No prompts during installation." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Press any key to continue..." -ForegroundColor DarkGray
    [Console]::ReadKey($true) | Out-Null
    Clear-Host

    # Platform Selection
    $platform = Read-SelectValue `
        -Title "Select Target Platform" `
        -Message "Choose the Kubernetes platform for your deployment" `
        -Options @(
            @{ Label = "Azure AKS"; Value = "Azure AKS" }
            @{ Label = "AWS EKS"; Value = "AWS EKS" }
            @{ Label = "Google GKE"; Value = "Google GKE" }
            @{ Label = "RKE2 (On-Premise)"; Value = "RKE2 (On-Premise)" }
            @{ Label = "Kind (Local)"; Value = "Kind (Local)" }
        ) `
        -Default 0
    
    if (-not $platform) {
        Write-Host "Installation cancelled." -ForegroundColor Red
        exit
    }

    # Step 1: Install Tools (before any platform-specific prompts, which
    # call az/aws/gcloud directly and need them already on PATH)
    Write-Section -Title "Step 1: Checking and Installing Tools — $platform" `
        -Hint "Downloads kubectl, helm, rancher CLI, and the platform CLI if missing" `
        -Current ([ordered]@{})
    Write-Host ""
    Write-Host "Installing tools" -ForegroundColor Cyan
    Write-Host ""
    Install-Kubectl
    Install-Helm
    Install-RancherCli
    Install-PlatformTools -Platform $platform
    Write-Host "`nTools ready." -ForegroundColor Green
    Start-Sleep -Seconds 1
    Write-Host "Press any key to continue..." -ForegroundColor DarkGray
    [Console]::ReadKey($true) | Out-Null

    # AKS variables
    $aksSubscriptionId = $null
    $aksResourceGroup  = $null
    $aksLocation       = $null
    $aksClusterName    = $null
    $aksNodeCount      = 1
    $aksVmSize         = $null
    $aksDnsLabel       = $null
    $aksDomain         = $null
    $aksReplaceCluster = $false
    $aksUseExisting    = $false

    # EKS variables
    $eksAccessKeyId     = $null
    $eksSecretAccessKey = $null
    $eksRegion          = $null
    $eksClusterName     = $null
    $eksNodeCount       = 1
    $eksNodeType        = $null
    $eksDomain          = $null
    $eksReplaceCluster  = $false
    $eksUseExisting     = $false

    # GKE variables
    $gkeProjectId    = $null
    $gkeZone         = $null
    $gkeClusterName  = $null
    $gkeNodeCount    = 1
    $gkeMachineType  = $null
    $gkeDomain       = $null
    $gkeReplaceCluster = $false
    $gkeUseExisting  = $false

    # RKE2 variables
    $rke2UseExisting    = $false
    $rke2KubeconfigPath = $null
    $rke2Domain         = $null
    $rke2SshServer      = $null
    $rke2SshUser        = $null
    $rke2SshKeyPath     = $null
    $rke2SshPassword    = $null

    if ($platform -eq "RKE2 (On-Premise)") {
        $rke2StateFile = Join-Path $PSScriptRoot ".rke2-state.json"
        if (Test-Path $rke2StateFile) {
            $rke2ExistingState   = Get-Content $rke2StateFile | ConvertFrom-Json
            $rke2ChangeSettings  = Read-YesNo `
                -Title "Existing RKE2 cluster found" `
                -DefaultYes $false `
                -YesLabel "Change Settings  (re-enter SSH details and domain)" `
                -NoLabel  "Use Existing Cluster" `
                -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                -ContextCurrent ([ordered]@{ Server = $rke2ExistingState.SshServer; User = $rke2ExistingState.SshUser; Domain = $rke2ExistingState.Domain; Connected = $rke2ExistingState.ConnectedAt })
            if (-not $rke2ChangeSettings) {
                $rke2UseExisting    = $true
                $rke2SshServer      = $rke2ExistingState.SshServer
                $rke2SshUser        = $rke2ExistingState.SshUser
                $rke2SshKeyPath     = $rke2ExistingState.SshKeyPath
                $rke2Domain         = $rke2ExistingState.Domain
                $rke2KubeconfigPath = $rke2ExistingState.KubeconfigPath
            }
        }

        if (-not $rke2UseExisting) {
            $sshAvailable = $null -ne (Get-Command "ssh.exe" -ErrorAction SilentlyContinue)

            $useSsh = $false
            if ($sshAvailable) {
                $useSsh = Read-YesNo `
                    -Title "Fetch kubeconfig automatically via SSH?" `
                    -DefaultYes $true `
                    -YesLabel "Auto-fetch via SSH  (script copies it from the server)" `
                    -NoLabel  "Manual path  (you already have the file locally)" `
                    -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                    -ContextHint "SSH is available on this machine" `
                    -ContextCurrent ([ordered]@{})
            }

            if ($useSsh) {
                $authMethod = Read-SelectValue `
                    -Title "SSH Authentication" `
                    -Options @(
                        @{ Label = "SSH Key  (recommended)"; Value = "key" }
                        @{ Label = "Password (via plink.exe)";  Value = "password" }
                    ) `
                    -Default 0 `
                    -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                    -ContextHint "How to authenticate with the server" `
                    -ContextCurrent ([ordered]@{})

                $rke2SshServer = Read-Plain `
                    -Prompt "RKE2 server IP or hostname" `
                    -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                    -ContextHint "The VIP or first control plane node IP" `
                    -ContextCurrent ([ordered]@{ Auth = $authMethod })
                if ([string]::IsNullOrWhiteSpace($rke2SshServer)) { Write-Host "Server IP is required." -ForegroundColor Red; exit 1 }

                $rke2SshUser = Read-Plain `
                    -Prompt "SSH user (default: root)" `
                    -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                    -ContextCurrent ([ordered]@{ Auth = $authMethod; Server = $rke2SshServer })
                if ([string]::IsNullOrWhiteSpace($rke2SshUser)) { $rke2SshUser = "root" }

                if ($authMethod -eq "key") {
                    $rke2SshKeyPath = Read-Plain `
                        -Prompt "SSH key path (leave empty for ssh-agent / default key)" `
                        -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                        -ContextCurrent ([ordered]@{ Auth = $authMethod; Server = $rke2SshServer; User = $rke2SshUser })
                    if ([string]::IsNullOrWhiteSpace($rke2SshKeyPath)) { $rke2SshKeyPath = "" }
                } else {
                    $rke2SshPassword = Read-SecretPlain `
                        -Prompt "SSH password for $rke2SshUser@$rke2SshServer" `
                        -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                        -ContextCurrent ([ordered]@{ Auth = $authMethod; Server = $rke2SshServer; User = $rke2SshUser })
                }

                $rke2KubeconfigPath = "$env:USERPROFILE\.kube\rke2-config"
            } else {
                $defaultKubeconfig  = "$env:USERPROFILE\.kube\config"
                $rke2KubeconfigPath = Read-Plain `
                    -Prompt "Local path to kubeconfig (default: $defaultKubeconfig)" `
                    -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                    -ContextHint "Copy manually: scp user@<node>:/etc/rancher/rke2/rke2.yaml $defaultKubeconfig" `
                    -ContextCurrent ([ordered]@{})
                if ([string]::IsNullOrWhiteSpace($rke2KubeconfigPath)) { $rke2KubeconfigPath = $defaultKubeconfig }
            }

            $rke2Domain = Read-Plain `
                -Prompt "Cluster domain (default: kubernetes.example.com)" `
                -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                -ContextHint "Wildcard *.{domain} should point to the MetalLB ingress IP in your DNS" `
                -ContextCurrent ([ordered]@{})
            if ([string]::IsNullOrWhiteSpace($rke2Domain)) { $rke2Domain = "kubernetes.example.com" }
        }
    }

    # Kind: ask for cluster name and handle existing cluster
    $kindClusterName = $null
    $kindReplaceCluster = $false
    $kindClusterExisted = $false
    $kindDomain = $null
    if ($platform -eq "Kind (Local)") {
        $kindClusterName = Read-Plain `
            -Prompt "Kind cluster name (default: my-kind-cluster)" `
            -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
            -ContextHint "Leave empty to use the default name" `
            -ContextCurrent ([ordered]@{})
        if ([string]::IsNullOrWhiteSpace($kindClusterName)) { $kindClusterName = "my-kind-cluster" }

        $kindDomain = Read-Plain `
            -Prompt "Local DNS domain (default: kubernetes.local)" `
            -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
            -ContextHint "Wildcard *.{domain} will be routed to nginx via Acrylic DNS" `
            -ContextCurrent ([ordered]@{ Cluster = $kindClusterName })
        if ([string]::IsNullOrWhiteSpace($kindDomain)) { $kindDomain = "kubernetes.local" }

        # If kind.exe is already available, check whether the cluster exists
        $kindExe = Join-Path $PSScriptRoot ".tools/kind.exe"
        if (Test-Path $kindExe) {
            $existingClusters = & $kindExe get clusters 2>&1
            if ($existingClusters -contains $kindClusterName) {
                $kindClusterExisted = $true
                $kindReplaceCluster = Read-YesNo `
                    -Title "Cluster already exists" `
                    -DefaultYes $false `
                    -YesLabel "Delete & Recreate  (all cluster data will be lost)" `
                    -NoLabel  "Keep Existing" `
                    -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                    -ContextCurrent ([ordered]@{ Cluster = $kindClusterName })
            }
        }
    }

    if ($platform -eq "Azure AKS") {
        # Load existing state for pre-selection
        $aksStateFile = Join-Path $PSScriptRoot ".aks-state.json"
        $aksExistingState = if (Test-Path $aksStateFile) { Get-Content $aksStateFile | ConvertFrom-Json } else { $null }

        # ── 1. Azure Login ──────────────────────────────────────────
        Clear-Host
        Write-Context -Title "Step 2: Initializing Cluster Environment — $platform" -Current ([ordered]@{})
        $exitCode = Invoke-WithSpinner -Message "Prüfe Azure Login..." -Executable "az" `
            -Arguments @("account", "show")
        if ($exitCode -ne 0) {
            do {
                Write-Host "`n  Azure login required. Open the following URL in your browser:" -ForegroundColor Cyan
                Write-Host "    https://microsoft.com/devicelogin" -ForegroundColor Yellow
                Write-Host ""
                & az login --use-device-code
            } while ($LASTEXITCODE -ne 0 -and (Confirm-RetryOrExit -Reason "Azure login failed"))
        }

        # ── 2. Subscription ─────────────────────────────────────────
        $defaultSub = if ($aksExistingState.SubscriptionId) { $aksExistingState.SubscriptionId } else { "" }
        $aksSubscriptionId = Read-Plain `
            -Prompt "Azure Subscription ID" `
            -Default $defaultSub `
            -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
            -ContextHint "Find it in Azure Portal > Subscriptions" `
            -ContextCurrent ([ordered]@{})
        if ([string]::IsNullOrWhiteSpace($aksSubscriptionId)) {
            Write-Host "  Subscription ID is required." -ForegroundColor Red; exit 1
        }
        & az account set --subscription $aksSubscriptionId 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "  Failed to set subscription '$aksSubscriptionId'." -ForegroundColor Red; exit 1 }

        # ── 3. Select cluster ───────────────────────────────────────────
        $preselectedCluster = if ($aksExistingState) {
            "$($aksExistingState.ClusterName)|$($aksExistingState.ResourceGroup)|$($aksExistingState.Location)"
        } else { "" }

        $selectedCluster = Read-SelectValue `
            -Title "Select AKS cluster" `
            -Message "Bestehenden Cluster verwenden oder neuen erstellen" `
            -Options @(@{ Label = "[ Neuen AKS-Cluster erstellen ]"; Value = "__new__" }) `
            -Default 0 `
            -DefaultValue $preselectedCluster `
            -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
            -ContextCurrent ([ordered]@{ Subscription = $aksSubscriptionId }) `
            -Loader {
                param($path); $env:PATH = $path
                $raw = & az aks list --query "[].{name:name, rg:resourceGroup, location:location}" --output json 2>$null
                $clusters = try { $raw | ConvertFrom-Json } catch { @() }
                $opts = @(@{ Label = "[ Neuen AKS-Cluster erstellen ]"; Value = "__new__" })
                foreach ($c in $clusters) {
                    $opts += @{ Label = "$($c.name)  ($($c.rg) · $($c.location))"; Value = "$($c.name)|$($c.rg)|$($c.location)" }
                }
                return $opts
            } `
            -LoadingMessage "Lade AKS-Cluster..."

        if (-not $selectedCluster) { Write-Host "Aborted." -ForegroundColor Red; exit 1 }

        if ($selectedCluster -ne "__new__") {
            $parts             = $selectedCluster -split '\|'
            $aksUseExisting    = $true
            $aksClusterName    = $parts[0]
            $aksResourceGroup  = $parts[1]
            $aksLocation       = $parts[2]
            $aksDnsLabel = ($aksClusterName -replace '[^a-z0-9-]', '-').ToLower()
            $aksDomain   = "$aksDnsLabel.$aksLocation.cloudapp.azure.com"
        }

        if (-not $aksUseExisting) {
            $aksClusterName = Read-Plain `
                -Prompt "AKS cluster name (default: my-aks-cluster)" `
                -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                -ContextHint "Lowercase letters, numbers, hyphens" `
                -ContextCurrent ([ordered]@{ Subscription = $aksSubscriptionId })
            if ([string]::IsNullOrWhiteSpace($aksClusterName)) { $aksClusterName = "my-aks-cluster" }

            $aksResourceGroup = Read-Plain `
                -Prompt "Resource group name (default: $aksClusterName-rg)" `
                -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                -ContextHint "Will be created — all cluster resources go here" `
                -ContextCurrent ([ordered]@{ Cluster = $aksClusterName })
            if ([string]::IsNullOrWhiteSpace($aksResourceGroup)) { $aksResourceGroup = "$aksClusterName-rg" }

            $aksLocation = Read-SelectValue `
                -Title "Select Azure Region" `
                -Message "Region where the AKS cluster will be deployed" `
                -Options @(
                    @{ Label = "West Europe       (Amsterdam)";  Value = "westeurope" }
                    @{ Label = "North Europe      (Dublin)";     Value = "northeurope" }
                    @{ Label = "East US           (Virginia)";   Value = "eastus" }
                    @{ Label = "East US 2         (Virginia)";   Value = "eastus2" }
                    @{ Label = "West US 2         (Washington)"; Value = "westus2" }
                    @{ Label = "UK South          (London)";     Value = "uksouth" }
                    @{ Label = "Germany West Central (Frankfurt)"; Value = "germanywestcentral" }
                    @{ Label = "Switzerland North (Zurich)";     Value = "switzerlandnorth" }
                    @{ Label = "Central US        (Iowa)";       Value = "centralus" }
                ) `
                -Default 0 `
                -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                -ContextCurrent ([ordered]@{ Cluster = $aksClusterName })
            if (-not $aksLocation) { Write-Host "Region is required." -ForegroundColor Red; exit 1 }

            $nodeCountStr = Read-SelectValue `
                -Title "Number of nodes" `
                -Message "VM size is chosen automatically based on node count" `
                -Options @(
                    @{ Label = "1 node  (Standard_D4s_v3 — 4 vCPU / 16 GB RAM)"; Value = "1" }
                    @{ Label = "2 nodes (Standard_D2s_v3 — 2 vCPU / 8 GB RAM each)"; Value = "2" }
                    @{ Label = "3 nodes (Standard_D2s_v3 — 2 vCPU / 8 GB RAM each)"; Value = "3" }
                ) `
                -Default 0 `
                -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                -ContextCurrent ([ordered]@{ Cluster = $aksClusterName; Region = $aksLocation })
            $aksNodeCount = [int]$nodeCountStr
            $aksVmSize    = if ($aksNodeCount -eq 1) { "Standard_D4s_v3" } else { "Standard_D2s_v3" }

            $aksDnsLabel = ($aksClusterName -replace '[^a-z0-9-]', '-').ToLower()
            $aksDomain   = "$aksDnsLabel.$aksLocation.cloudapp.azure.com"
        }
    }

    if ($platform -eq "AWS EKS") {
        $eksStateFile     = Join-Path $PSScriptRoot ".eks-state.json"
        $eksExistingState = if (Test-Path $eksStateFile) { Get-Content $eksStateFile | ConvertFrom-Json } else { $null }

        # ── 1. AWS Credentials ──────────────────────────────────────
        Clear-Host
        Write-Context -Title "Step 2: Initializing Cluster Environment — $platform" -Current ([ordered]@{})
        $exitCode = Invoke-WithSpinner -Message "Prüfe AWS Credentials..." -Executable "aws" `
            -Arguments @("sts", "get-caller-identity")
        if ($exitCode -ne 0) {
            $defaultKeyId = if ($eksExistingState.AccessKeyId) { $eksExistingState.AccessKeyId } else { "" }
            do {
                $eksAccessKeyId = Read-Plain `
                    -Prompt "AWS Access Key ID" `
                    -Default $defaultKeyId `
                    -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                    -ContextHint "IAM user with EKS + EC2 + CloudFormation + IAM permissions" `
                    -ContextCurrent ([ordered]@{})
                if ([string]::IsNullOrWhiteSpace($eksAccessKeyId)) { Write-Host "  Access Key ID is required." -ForegroundColor Red; exit 1 }

                $eksSecretAccessKey = Read-SecretPlain `
                    -Prompt "AWS Secret Access Key" `
                    -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                    -ContextCurrent ([ordered]@{ AccessKeyId = $eksAccessKeyId })
                if ([string]::IsNullOrWhiteSpace($eksSecretAccessKey)) { Write-Host "  Secret Access Key is required." -ForegroundColor Red; exit 1 }

                & aws configure set aws_access_key_id     $eksAccessKeyId     2>&1 | Out-Null
                & aws configure set aws_secret_access_key $eksSecretAccessKey 2>&1 | Out-Null
                & aws sts get-caller-identity 2>&1 | Out-Null
                $awsAuthOk    = $LASTEXITCODE -eq 0
                $defaultKeyId = $eksAccessKeyId
            } while (-not $awsAuthOk -and (Confirm-RetryOrExit -Reason "AWS authentication failed — check Access Key ID and Secret"))
        } else {
            $eksAccessKeyId = (& aws configure get aws_access_key_id 2>$null).Trim()
        }

        # ── 2. Region ────────────────────────────────────────────────
        $defaultRegion = if ($eksExistingState.Region) { $eksExistingState.Region } else { "" }
        $eksRegion = Read-SelectValue `
            -Title "Select AWS Region" `
            -Message "Region where the EKS cluster will be deployed" `
            -Options @(
                @{ Label = "EU West 1       (Ireland)";       Value = "eu-west-1" }
                @{ Label = "EU Central 1    (Frankfurt)";     Value = "eu-central-1" }
                @{ Label = "EU North 1      (Stockholm)";     Value = "eu-north-1" }
                @{ Label = "EU West 2       (London)";        Value = "eu-west-2" }
                @{ Label = "US East 1       (N. Virginia)";   Value = "us-east-1" }
                @{ Label = "US East 2       (Ohio)";          Value = "us-east-2" }
                @{ Label = "US West 2       (Oregon)";        Value = "us-west-2" }
                @{ Label = "AP Southeast 1  (Singapore)";     Value = "ap-southeast-1" }
                @{ Label = "AP Northeast 1  (Tokyo)";         Value = "ap-northeast-1" }
            ) `
            -Default 0 `
            -DefaultValue $defaultRegion `
            -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
            -ContextCurrent ([ordered]@{})
        if (-not $eksRegion) { Write-Host "  Region is required." -ForegroundColor Red; exit 1 }
        Clear-Host
        Write-Context -Title "Step 2: Initializing Cluster Environment — $platform" -Current ([ordered]@{})
        Invoke-WithSpinner -Message "Setze Region '$eksRegion'..." -Executable "aws" `
            -Arguments @("configure", "set", "default.region", $eksRegion) | Out-Null

        # ── 3. Select cluster ───────────────────────────────────────────
        $preselectedCluster = if ($eksExistingState) { $eksExistingState.ClusterName } else { "" }

        $selectedCluster = Read-SelectValue `
            -Title "Select EKS cluster" `
            -Message "Bestehenden Cluster verwenden oder neuen erstellen" `
            -Options @(@{ Label = "[ Neuen EKS-Cluster erstellen ]"; Value = "__new__" }) `
            -Default 0 `
            -DefaultValue $preselectedCluster `
            -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
            -ContextCurrent ([ordered]@{ Region = $eksRegion }) `
            -Loader {
                param($path, $region); $env:PATH = $path
                $raw = & aws eks list-clusters --region $region --query "clusters" --output json 2>$null
                $clusters = try { $raw | ConvertFrom-Json } catch { @() }
                $opts = @(@{ Label = "[ Neuen EKS-Cluster erstellen ]"; Value = "__new__" })
                foreach ($c in $clusters) { $opts += @{ Label = $c; Value = $c } }
                return $opts
            } `
            -LoaderArgs @($eksRegion) `
            -LoadingMessage "Lade EKS-Cluster..."

        if (-not $selectedCluster) { Write-Host "Aborted." -ForegroundColor Red; exit 1 }

        if ($selectedCluster -ne "__new__") {
            $eksUseExisting = $true
            $eksClusterName = $selectedCluster
            $eksDomain      = "$eksClusterName.eks.local"
        }

        if (-not $eksUseExisting) {
            $eksClusterName = Read-Plain `
                -Prompt "EKS cluster name (default: my-eks-cluster)" `
                -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                -ContextHint "Lowercase letters, numbers, hyphens" `
                -ContextCurrent ([ordered]@{ Region = $eksRegion })
            if ([string]::IsNullOrWhiteSpace($eksClusterName)) { $eksClusterName = "my-eks-cluster" }

            $eksNodeType = Read-SelectValue `
                -Title "Instance Type" `
                -Message "Wähle einen Instance-Typ — bei Capacity-Problemen t3a oder m5 probieren" `
                -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                -Options @(
                    @{ Label = "t3.medium   (2 vCPU / 4 GB  — Standard)";            Value = "t3.medium" }
                    @{ Label = "t3a.medium  (2 vCPU / 4 GB  — AMD, oft verfügbar)";  Value = "t3a.medium" }
                    @{ Label = "t3.large    (2 vCPU / 8 GB)";                         Value = "t3.large" }
                    @{ Label = "t3a.large   (2 vCPU / 8 GB  — AMD)";                 Value = "t3a.large" }
                    @{ Label = "m5.large    (2 vCPU / 8 GB  — breite Verfügbarkeit)"; Value = "m5.large" }
                    @{ Label = "m5a.large   (2 vCPU / 8 GB  — AMD)";                 Value = "m5a.large" }
                    @{ Label = "t3.micro    (2 vCPU / 1 GB  — Free Tier, nur zum Testen)"; Value = "t3.micro" }
                    @{ Label = "t2.micro    (1 vCPU / 1 GB  — Free Tier, nur zum Testen)"; Value = "t2.micro" }
                ) `
                -Default 0 `
                -ContextCurrent ([ordered]@{ Cluster = $eksClusterName; Region = $eksRegion })
            if (-not $eksNodeType) { Write-Host "  Instance type is required." -ForegroundColor Red; exit 1 }

            $nodeCountStr = Read-SelectValue `
                -Title "Number of nodes" `
                -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                -Options @(
                    @{ Label = "1 node";  Value = "1" }
                    @{ Label = "2 nodes"; Value = "2" }
                    @{ Label = "3 nodes"; Value = "3" }
                ) `
                -Default 0 `
                -ContextCurrent ([ordered]@{ Cluster = $eksClusterName; Region = $eksRegion; Type = $eksNodeType })
            $eksNodeCount = [int]$nodeCountStr
            $eksDomain    = "$eksClusterName.eks.local"
        }
    }

    if ($platform -eq "Google GKE") {
        $gkeStateFile     = Join-Path $PSScriptRoot ".gke-state.json"
        $gkeExistingState = if (Test-Path $gkeStateFile) { Get-Content $gkeStateFile | ConvertFrom-Json } else { $null }

        # ── 1. gcloud Login ─────────────────────────────────────────
        Clear-Host
        Write-Context -Title "Step 2: Initializing Cluster Environment — $platform" -Current ([ordered]@{})
        $accountRef = [ref]$null
        Invoke-WithSpinner -Message "Prüfe Google Login..." -Executable "gcloud" `
            -Arguments @("config", "get-value", "account") -OutputVariable $accountRef | Out-Null
        $gcloudAccount = ($accountRef.Value -join "").Trim()
        $notLoggedIn = [string]::IsNullOrWhiteSpace($gcloudAccount) -or $gcloudAccount -eq "(unset)"
        if ($notLoggedIn) {
            do {
                Write-Host "`n  Google login erforderlich..." -ForegroundColor Cyan
                & gcloud auth login --no-launch-browser
            } while ($LASTEXITCODE -ne 0 -and (Confirm-RetryOrExit -Reason "Google login failed"))
        }

        # ── 2. Project ID ────────────────────────────────────────────
        $defaultProject = if ($gkeExistingState.ProjectId) { $gkeExistingState.ProjectId } else { "" }
        $gkeProjectId = Read-Plain `
            -Prompt "Google Cloud Project ID" `
            -Default $defaultProject `
            -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
            -ContextHint "Find it in Google Cloud Console — top navigation bar" `
            -ContextCurrent ([ordered]@{})
        if ([string]::IsNullOrWhiteSpace($gkeProjectId)) { Write-Host "  Project ID is required." -ForegroundColor Red; exit 1 }
        Clear-Host
        Write-Context -Title "Step 2: Initializing Cluster Environment — $platform" -Current ([ordered]@{})
        Invoke-WithSpinner -Message "Setze Projekt '$gkeProjectId'..." -Executable "gcloud" `
            -Arguments @("config", "set", "project", $gkeProjectId) | Out-Null

        # ── 3. Select cluster ───────────────────────────────────────────
        $preselectedCluster = if ($gkeExistingState) {
            "$($gkeExistingState.ClusterName)|$($gkeExistingState.Zone)"
        } else { "" }

        $selectedCluster = Read-SelectValue `
            -Title "Select GKE cluster" `
            -Message "Bestehenden Cluster verwenden oder neuen erstellen" `
            -Options @(@{ Label = "[ Neuen GKE-Cluster erstellen ]"; Value = "__new__" }) `
            -Default 0 `
            -DefaultValue $preselectedCluster `
            -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
            -ContextCurrent ([ordered]@{ Project = $gkeProjectId }) `
            -Loader {
                param($path, $projectId); $env:PATH = $path
                $raw = & gcloud container clusters list --project $projectId `
                    --format "json(name,zone,status)" 2>$null
                $clusters = try { $raw | ConvertFrom-Json } catch { @() }
                $opts = @(@{ Label = "[ Neuen GKE-Cluster erstellen ]"; Value = "__new__" })
                foreach ($c in $clusters) {
                    $opts += @{ Label = "$($c.name)  ($($c.zone))  [$($c.status)]"; Value = "$($c.name)|$($c.zone)" }
                }
                return $opts
            } `
            -LoaderArgs @($gkeProjectId) `
            -LoadingMessage "Lade GKE-Cluster..."

        if (-not $selectedCluster) { Write-Host "Aborted." -ForegroundColor Red; exit 1 }

        if ($selectedCluster -ne "__new__") {
            $parts          = $selectedCluster -split '\|'
            $gkeUseExisting = $true
            $gkeClusterName = $parts[0]
            $gkeZone        = $parts[1]
            $gkeDomain      = "$gkeClusterName.gke.local"
        }

        if (-not $gkeUseExisting) {
            $gkeZone = Read-SelectValue `
                -Title "Select GKE Zone" `
                -Message "Zone where the GKE cluster will be deployed" `
                -Options @(
                    @{ Label = "europe-west1-b   (Belgium)";      Value = "europe-west1-b" }
                    @{ Label = "europe-west3-a   (Frankfurt)";    Value = "europe-west3-a" }
                    @{ Label = "europe-west4-a   (Netherlands)";  Value = "europe-west4-a" }
                    @{ Label = "europe-west6-a   (Zurich)";       Value = "europe-west6-a" }
                    @{ Label = "us-central1-a    (Iowa)";         Value = "us-central1-a" }
                    @{ Label = "us-east1-b       (S. Carolina)";  Value = "us-east1-b" }
                    @{ Label = "us-west1-a       (Oregon)";       Value = "us-west1-a" }
                    @{ Label = "asia-northeast1-a (Tokyo)";       Value = "asia-northeast1-a" }
                ) `
                -Default 0 `
                -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                -ContextCurrent ([ordered]@{ Project = $gkeProjectId })
            if (-not $gkeZone) { Write-Host "  Zone is required." -ForegroundColor Red; exit 1 }

            $gkeClusterName = Read-Plain `
                -Prompt "GKE cluster name (default: my-gke-cluster)" `
                -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                -ContextHint "Lowercase letters, numbers, hyphens" `
                -ContextCurrent ([ordered]@{ Project = $gkeProjectId; Zone = $gkeZone })
            if ([string]::IsNullOrWhiteSpace($gkeClusterName)) { $gkeClusterName = "my-gke-cluster" }

            $nodeCountStr = Read-SelectValue `
                -Title "Number of nodes" `
                -Message "Machine type is chosen automatically based on node count" `
                -Options @(
                    @{ Label = "1 node  (e2-standard-4 — 4 vCPU / 16 GB RAM)";    Value = "1" }
                    @{ Label = "2 nodes (e2-standard-2 — 2 vCPU / 8 GB RAM each)"; Value = "2" }
                    @{ Label = "3 nodes (e2-standard-2 — 2 vCPU / 8 GB RAM each)"; Value = "3" }
                ) `
                -Default 0 `
                -ContextTitle "Step 2: Initializing Cluster Environment — $platform" `
                -ContextCurrent ([ordered]@{ Project = $gkeProjectId; Cluster = $gkeClusterName; Zone = $gkeZone })
            $gkeNodeCount   = [int]$nodeCountStr
            $gkeMachineType = if ($gkeNodeCount -eq 1) { "e2-standard-4" } else { "e2-standard-2" }
            $gkeDomain      = "$gkeClusterName.gke.local"
        }
    }

    # Context shown on Step 2's page below — same info the old plain-text
    # summary used to print, just rendered through the shared context panel.
    # Platform is the ContextTitle everywhere it's used, not an entry here.
    $clusterContext = [ordered]@{}
    if ($kindClusterName) { $clusterContext["Cluster"] = $kindClusterName; $clusterContext["Domain"] = "*.$kindDomain" }
    if ($aksDomain)       { $clusterContext["Cluster"] = "$aksClusterName ($aksLocation)"; $clusterContext["Domain"] = "*.$aksDomain" }
    if ($eksDomain)       { $clusterContext["Cluster"] = "$eksClusterName ($eksRegion)"; $clusterContext["Domain"] = "*.$eksDomain" }
    if ($gkeDomain)       { $clusterContext["Cluster"] = "$gkeClusterName ($gkeZone)"; $clusterContext["Domain"] = "*.$gkeDomain" }
    if ($platform -eq "RKE2 (On-Premise)") {
        $clusterContext["Kubeconfig"] = $rke2KubeconfigPath
        $clusterContext["Domain"]     = "*.$rke2Domain"
    }

    # Save state files before cluster init so a partial failure is recoverable
    if ($platform -eq "Azure AKS" -and -not $aksUseExisting) {
        @{ SubscriptionId = $aksSubscriptionId; ResourceGroup = $aksResourceGroup
           ClusterName = $aksClusterName; Location = $aksLocation
           CreatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        } | ConvertTo-Json | Set-Content -Path "$PSScriptRoot/.aks-state.json" -Encoding UTF8
    }
    if ($platform -eq "AWS EKS" -and -not $eksUseExisting) {
        @{ AccessKeyId = $eksAccessKeyId; Region = $eksRegion
           ClusterName = $eksClusterName; NodeType = $eksNodeType; Domain = $eksDomain
           CreatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        } | ConvertTo-Json | Set-Content -Path "$PSScriptRoot/.eks-state.json" -Encoding UTF8
    }
    if ($platform -eq "Google GKE" -and -not $gkeUseExisting) {
        @{ ProjectId = $gkeProjectId; Zone = $gkeZone
           ClusterName = $gkeClusterName; Domain = $gkeDomain
           CreatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        } | ConvertTo-Json | Set-Content -Path "$PSScriptRoot/.gke-state.json" -Encoding UTF8
    }
    if ($platform -eq "RKE2 (On-Premise)" -and -not $rke2UseExisting) {
        @{ SshServer = $rke2SshServer; SshUser = $rke2SshUser; SshKeyPath = $rke2SshKeyPath
           Domain = $rke2Domain; KubeconfigPath = $rke2KubeconfigPath
           ConnectedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        } | ConvertTo-Json | Set-Content -Path "$PSScriptRoot/.rke2-state.json" -Encoding UTF8
    }
    if ($platform -eq "Kind (Local)") {
        @{ ClusterName = $kindClusterName; Domain = $kindDomain
           CreatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        } | ConvertTo-Json | Set-Content -Path "$PSScriptRoot/.kind-state.json" -Encoding UTF8
    }

    # Step 2: Configure Kubectl
    # RKE2 never creates anything here (it's pre-existing on-prem infra) —
    # this is only ever a connect. The other platforms either reused an
    # existing cluster (selected from the list / kept on the "already
    # exists" prompt) or are about to create a brand new one.
    $usingExistingCluster = switch ($platform) {
        "RKE2 (On-Premise)" { $true }
        "Azure AKS"         { $aksUseExisting }
        "AWS EKS"           { $eksUseExisting }
        "Google GKE"        { $gkeUseExisting }
        "Kind (Local)"      { $kindClusterExisted -and -not $kindReplaceCluster }
        default             { $false }
    }
    $step2Hint   = if ($usingExistingCluster) { "Connects to the cluster and configures kubectl" } else { "Creates the cluster and configures kubectl" }
    $step2Action = if ($usingExistingCluster) { "Connecting to cluster" } else { "Creating cluster" }

    Write-Section -Title "Step 2: Initializing Cluster Environment — $platform" `
        -Hint $step2Hint `
        -Current $clusterContext
    Write-Host ""
    Write-Host $step2Action -ForegroundColor Cyan
    Write-Host ""
    # When reusing existing RKE2 state: skip SSH re-fetch if kubeconfig is already present
    $rke2SshServerArg = if ($rke2UseExisting -and (Test-Path ($rke2KubeconfigPath -replace '^~', $env:USERPROFILE))) { "" } else { $rke2SshServer }
    Initialize-ClusterEnvironment -Platform $platform `
        -KindClusterName $kindClusterName -KindReplaceCluster $kindReplaceCluster -KindDomain $kindDomain `
        -AksSubscriptionId $aksSubscriptionId -AksResourceGroup $aksResourceGroup `
        -AksLocation $aksLocation -AksClusterName $aksClusterName `
        -AksNodeCount $aksNodeCount -AksVmSize $aksVmSize `
        -AksReplaceCluster $aksReplaceCluster -AksUseExisting $aksUseExisting `
        -EksAccessKeyId $eksAccessKeyId -EksSecretAccessKey $eksSecretAccessKey `
        -EksRegion $eksRegion -EksClusterName $eksClusterName `
        -EksNodeCount $eksNodeCount -EksNodeType $eksNodeType `
        -EksReplaceCluster $eksReplaceCluster -EksUseExisting $eksUseExisting `
        -GkeProjectId $gkeProjectId -GkeZone $gkeZone -GkeClusterName $gkeClusterName `
        -GkeNodeCount $gkeNodeCount -GkeMachineType $gkeMachineType `
        -GkeReplaceCluster $gkeReplaceCluster -GkeUseExisting $gkeUseExisting `
        -Rke2KubeconfigPath $rke2KubeconfigPath `
        -Rke2SshServer $rke2SshServerArg -Rke2SshUser $rke2SshUser `
        -Rke2SshKeyPath $rke2SshKeyPath -Rke2SshPassword $rke2SshPassword

    Write-Host "`nBase installation complete for $platform." -ForegroundColor Green

    # Kubernetes version check — components like OpenBao require >= 1.30
    $k8sVersion = & kubectl version --output json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    $serverVersion = if ($k8sVersion -and $k8sVersion.serverVersion) {
        "$($k8sVersion.serverVersion.major).$($k8sVersion.serverVersion.minor -replace '[^0-9]','')"
    } else { "0.0" }
    $k8sMajor = [int]($serverVersion -split '\.')[0]
    $k8sMinor = [int]($serverVersion -split '\.')[1]
    if ($k8sMajor -lt 1 -or ($k8sMajor -eq 1 -and $k8sMinor -lt 30)) {
        Write-Host ""
        Write-Host "  ⚠ Kubernetes $serverVersion detected — some components (e.g. OpenBao) require >= 1.30." -ForegroundColor Yellow
        Write-Host "  Bitte den Cluster auf 1.30+ upgraden." -ForegroundColor Yellow
        Write-Host ""
    }
    Start-Sleep -Seconds 1
    Write-Host "Press any key to continue..." -ForegroundColor DarkGray
    [Console]::ReadKey($true) | Out-Null

    # Build component options based on platform
    # Numbering follows actual install order ($installOrder below), not the
    # alphabetic/conceptual grouping — Storage installs before Security (so
    # the Vault backend can use Longhorn as its StorageClass), so Storage is
    # "20" and Security is "30", not the other way around.
    $ingressLabel = "10 - Ingress & Load Balancing"

    $componentOptions = @(
        @{ Label = $ingressLabel; Value = "Ingress & Load Balancing" }
    )

    # Storage (Longhorn) is only ever offered on RKE2 (other platforms have
    # their own native StorageClass) — mandatory wherever it IS offered, same
    # as Ingress & Load Balancing / Security & Certificates below.
    $storageLabel = "20 - Storage"
    if ($platform -eq "RKE2 (On-Premise)") {
        $componentOptions += @{ Label = $storageLabel; Value = "Storage (Longhorn)" }
    }

    $componentOptions += @{ Label = "30 - Security & Certificates"; Value = "Security & Certificates" }

    $componentOptions += @(
        @{ Label = "40 - Configuration Management"; Value = "Configuration Management" }
    )
    # "Rancher", not the generic "Management" — unlike Registry (39, generic
    # on purpose, multiple products fit), there's only ever one product here,
    # so naming it specifically is clearer, not less clear.
    $componentOptions += @{
        Label = "50 - Rancher"
        Value = "Management"
    }
    $componentOptions += @(
        @{ Label = "60 - Observability Stack"; Value = "Observability Stack" }
        @{ Label = "90 - Utilities (DevOps)"; Value = "Utilities" }
    )

    # Build default values based on platform
    $defaultValues = @("Ingress & Load Balancing", "Security & Certificates", "Configuration Management")
    if ($platform -in @("RKE2 (On-Premise)", "Kind (Local)")) {
        $defaultValues += "Management"
    }
    if ($platform -eq "RKE2 (On-Premise)") {
        $defaultValues += "Storage (Longhorn)"
    }
    
    # Optional Components Selection
    # Ingress & Load Balancing, Security & Certificates, Configuration
    # Management, and (where offered) Storage are mandatory — shown checked
    # and locked, not hidden, so it's clear they're part of the install
    # rather than silently always-on.
    $disabledGroups = @{
        $ingressLabel                    = $true
        "30 - Security & Certificates"   = $true
        "40 - Configuration Management"  = $true
    }
    if ($platform -eq "RKE2 (On-Premise)") { $disabledGroups[$storageLabel] = $true }

    $selectedComponentGroups = Read-MultiSelectValues `
        -Title "Select Optional Component Groups" `
        -Options $componentOptions `
        -DefaultValues $defaultValues `
        -Disabled $disabledGroups `
        -ContextTitle $platform `
        -ContextCurrent $clusterContext

    if ($null -eq $selectedComponentGroups) {
        Write-Host "Installation cancelled." -ForegroundColor Red
        exit
    }

    # Step 3: Install Optional Components
    if ($selectedComponentGroups.Count -gt 0) {
        Write-Section -Title "Step 3: Installing Optional Components — $platform" `
            -Hint "Select, then install, one component group at a time" `
            -Current ([ordered]@{ Groups = $selectedComponentGroups })
        Write-Host ""

        # Define component installation order
        # SelKey links each component to its Screen 2 value for filtering.
        # Components with no SelKey are always installed when their group is selected.
        # Ingress and tracing have no PromptPhase=1 — type is pre-filled from Screen 2 radio.
        $vaultName = switch ($platform) {
            "Azure AKS"  { "azure-keyvault"    }
            "AWS EKS"    { "aws-secretsmanager" }
            "Google GKE" { "gcp-secretmanager"  }
            default      { "openbao"            }
        }
        $ingressComponents = [System.Collections.Generic.List[hashtable]]::new()
        $ingressComponents.Add(@{ Number="11"; Name="ingress"; SelKey="ingress"; DisplayName="Ingress Controller" }) | Out-Null
        if ($platform -in @("Kind (Local)", "RKE2 (On-Premise)")) {
            # No SelKey — always installed alongside ingress on these platforms,
            # never shown or asked about (see comment above on no-SelKey components).
            $ingressComponents.Add(@{ Number="12"; Name="metallb"; DisplayName="MetalLB" }) | Out-Null
        }

        $componentMap = @{
            "Ingress & Load Balancing" = $ingressComponents.ToArray()
            # No SelKey on any of these — the whole group is mandatory baseline now
            # (no ESO, no wildcard-cert: see ARCHITECTURE notes on why both were
            # retired). Authelia included: it's the SSO every later component can
            # rely on, not an optional add-on anymore.
            "Security & Certificates" = @(
                @{ Number="31"; Name="cert-manager";       DisplayName="Certificate Manager" }
                @{ Number="32"; Name="secrets-csi-driver"; DisplayName="Secrets Store CSI Driver" }
                @{ Number="33"; Name=$vaultName;           DisplayName="Vault" }
                @{ Number="35"; Name="authelia";           DisplayName="Authelia (Single Sign-On)" }
            )
            "Storage (Longhorn)" = @(
                @{ Number="21"; Name="longhorn"; SelKey="longhorn"; PromptPhase=1; PromptOrder="65"; DisplayName="Longhorn Storage" }
            )
            # No SelKey on any of these — mandatory baseline, no checkbox. Each
            # still gets its own internal yes/no gate (Proxy Configuration and
            # Registry both no-op cleanly if the user says no — same pattern).
            "Configuration Management" = @(
                @{ Number="41"; Name="config-syncer";   DisplayName="Configuration Syncer" }
                @{ Number="43"; Name="proget-registry"; DisplayName="Registry" }
                if ($platform -in @("RKE2 (On-Premise)", "Kind (Local)")) {
                    @{ Number="42"; Name="proxy-config"; DisplayName="Proxy Configuration" }
                }
            )
            "Management" = @(
                @{ Number="51"; Name="rancher"; SelKey="rancher"; DisplayName="Rancher" }
            )
            "Observability Stack" = @(
                @{ Number="61"; Name="prometheus";              SelKey="prometheus";              DisplayName="Prometheus" }
                @{ Number="62"; Name="loki";                    SelKey="loki";                    DisplayName="Loki" }
                @{ Number="63"; Name="promtail";                SelKey="promtail";                DisplayName="Promtail" }
                @{ Number="64"; Name="tracing";                 SelKey="tracing";                 DisplayName="Tracing" }
                @{ Number="65"; Name="opentelemetry-collector"; SelKey="opentelemetry-collector"; DisplayName="OpenTelemetry Collector" }
                @{ Number="66"; Name="grafana";                 SelKey="grafana";                 DisplayName="Grafana" }
            )
            "Utilities" = @(
                @{ Number="91"; Name="argocd"; SelKey="argocd"; DisplayName="ArgoCD" }
                @{ Number="93"; Name="velero"; SelKey="velero"; DisplayName="Velero (Backup)" }
            )
        }

        $domain = if ($platform -eq "Kind (Local)") { $kindDomain }
                  elseif ($platform -eq "Azure AKS") { $aksDomain }
                  elseif ($platform -eq "AWS EKS") { $eksDomain }
                  elseif ($platform -eq "Google GKE") { $gkeDomain }
                  elseif ($platform -eq "RKE2 (On-Premise)") { $rke2Domain }
                  else { "" }

        function Get-PromptExtraArgs($component) {
            $extra = @{}
            if ($component.Name -in @("argocd", "grafana", "tracing", "prometheus", "longhorn", "openbao", "rancher", "authelia", "metallb")) {
                if (-not [string]::IsNullOrWhiteSpace($domain)) { $extra.Domain = $domain }
            }
            if ($component.Name -eq "metallb" -and $componentInputs.ContainsKey("ingress")) {
                $extra.IngressController = $componentInputs["ingress"].IngressController
            }
            return $extra
        }

        # ── Per-group: component selection → parameter collection ─────────
        # Each group with choices gets its own compact selection screen,
        # followed immediately by parameter prompts for the selected components.
        # Single-component groups skip the selection screen.
        $compSel         = @{}
        $componentInputs = @{}

        foreach ($group in $selectedComponentGroups) {
            # Build section data for groups that have real choices
            $section = $null
            switch ($group) {
                "Observability Stack" {
                    $section = @{ Label=$group; Items=@(
                        @{ Label="Prometheus (kube-prometheus-stack)"; Value="prometheus";              Type="check"; Default=$true }
                        @{ Label="Loki";                               Value="loki";                    Type="check"; Default=$true }
                        @{ Label="Promtail";                           Value="promtail";                Type="check"; Default=$true }
                        @{
                            Label="Tracing"; Value="tracing"; Type="group"; Default=$true
                            Children=@(
                                @{ Label="Tempo";  Value="tempo";  Type="radio"; RadioGroup="tracing"; Default=$true  }
                                @{ Label="Jaeger"; Value="jaeger"; Type="radio"; RadioGroup="tracing"; Default=$false }
                            )
                        }
                        @{ Label="OpenTelemetry Collector"; Value="opentelemetry-collector"; Type="check"; Default=$true }
                        @{ Label="Grafana";                 Value="grafana";                 Type="check"; Default=$true }
                    )}
                }
                "Utilities" {
                    $section = @{ Label=$group; Items=@(
                        @{ Label="ArgoCD";          Value="argocd"; Type="check"; Default=$true }
                        @{ Label="Velero (Backup)"; Value="velero"; Type="check"; Default=$true }
                    )}
                }
            }

            # Show per-group component selection (only if group has choices)
            if ($section) {
                $groupSel = Read-ComponentSelectionScreen `
                    -Title $group `
                    -Sections @($section)
                if ($null -eq $groupSel) { Write-Host "Installation cancelled." -ForegroundColor Red; exit }
                $groupSel.Keys | ForEach-Object { $compSel[$_] = $groupSel[$_] }
            }

            # Ingress & Load Balancing is mandatory and has no other choices left —
            # ask the one remaining question directly instead of a checkbox screen.
            if ($group -eq "Ingress & Load Balancing") {
                $ingressType = Read-SelectValue -Title "Which Ingress Controller should be installed?" `
                    -Options @(
                        @{ Label = "NGINX Ingress Controller"; Value = "nginx" }
                        @{ Label = "Traefik";                  Value = "traefik" }
                    ) -Default 0 -ContextTitle "Ingress — $platform"
                if ($null -eq $ingressType) { Write-Host "Installation cancelled." -ForegroundColor Red; exit }
                $componentInputs["ingress"] = @{ IngressController = $ingressType }
                if ($platform -eq "Azure AKS" -and -not [string]::IsNullOrWhiteSpace($aksDnsLabel)) {
                    $componentInputs["ingress"]["DnsLabel"] = $aksDnsLabel
                }
            }
            if ($group -eq "Observability Stack") {
                $tracingType = if ($compSel["tempo"]) { "tempo" } else { "jaeger" }
                $componentInputs["tracing"] = @{ TracingBackend = $tracingType }
            }

            # Collect parameters for selected components of this group immediately after selection
            if ($componentMap.ContainsKey($group)) {
                $groupComponents = @($componentMap[$group] | Where-Object {
                    (-not $_.SelKey) -or
                    (-not $compSel.ContainsKey($_.SelKey)) -or
                    ($compSel[$_.SelKey] -eq $true)
                } | Sort-Object { if ($_.PromptOrder) { [int]$_.PromptOrder } else { [int]$_.Number } })

                foreach ($component in $groupComponents) {
                    $componentDir  = Join-Path $PSScriptRoot "$($component.Number)-$($component.Name)"
                    $promptScript  = Join-Path $componentDir "Prompt.ps1"
                    $prompt2Script = Join-Path $componentDir "Prompt2.ps1"
                    $extraArgs     = Get-PromptExtraArgs $component

                    if ((Test-Path $promptScript) -and -not $componentInputs.ContainsKey($component.Name)) {
                        $inputs = & $promptScript -Platform $platform @extraArgs
                        if ($inputs) { $componentInputs[$component.Name] = $inputs }
                    }

                    if (Test-Path $prompt2Script) {
                        $existingInputs = if ($componentInputs.ContainsKey($component.Name)) { $componentInputs[$component.Name] } else { @{} }
                        $inputs = & $prompt2Script -Platform $platform @extraArgs @existingInputs
                        if ($inputs) {
                            if ($componentInputs.ContainsKey($component.Name)) {
                                foreach ($k in $inputs.Keys) { $componentInputs[$component.Name][$k] = $inputs[$k] }
                            } else { $componentInputs[$component.Name] = $inputs }
                        }
                    }
                }
            }
        }

        # ── Dependency validation ─────────────────────────────────────
        # Build the full set of keys that will actually be installed.
        # $compSel contains Screen-2 selections (value = SelKey).
        # Single-component groups (no Screen 2) use their SelKey directly.
        $willInstall = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $compSel.Keys | Where-Object { $compSel[$_] -eq $true } |
            ForEach-Object { $willInstall.Add($_) | Out-Null }
        # Ingress & Load Balancing and Security & Certificates are mandatory and have
        # no Screen-2 checkboxes anymore — add their components directly so the
        # soft-deps below still see them.
        $willInstall.Add("ingress") | Out-Null
        if ("Security & Certificates" -in $selectedComponentGroups) {
            @("cert-manager", "secrets-csi-driver", "vault", "authelia") | ForEach-Object { $willInstall.Add($_) | Out-Null }
        }
        if ("Storage (Longhorn)" -in $selectedComponentGroups) { $willInstall.Add("longhorn") | Out-Null }
        if ("Management"         -in $selectedComponentGroups) { $willInstall.Add("rancher")  | Out-Null }
        # Utilities now has a real Screen-2 (like Observability Stack) — argocd/velero
        # come from the generic compSel loop above, no hardcoded add needed.

        # Hard deps: component is auto-deselected when dep is missing.
        # Use SelKey values — same keys used in $compSel and $componentMap.
        $hardDeps = @(
            @{ C="promtail";                Needs="loki";             Reason="has no log destination without Loki" }
            @{ C="opentelemetry-collector"; Needs="tracing";          Reason="has no tracing backend (Tempo or Jaeger)" }
            # Registry needing config-syncer used to be a real hard-dep check —
            # now both are mandatory members of the same group, so it can never
            # actually be violated. Removed rather than left as dead code.
        )
        # Soft deps: installs fine but something won't work — warn only.
        $softDeps = @(
            @{ C="rancher";  Needs="ingress"; Reason="UI will not be reachable without an Ingress Controller" }
            @{ C="argocd";   Needs="ingress"; Reason="UI will not be reachable without an Ingress Controller" }
            @{ C="grafana";  Needs="ingress"; Reason="UI will not be reachable without an Ingress Controller" }
            @{ C="vault";    Needs="ingress"; Reason="UI will not be reachable without an Ingress Controller" }
            @{ C="authelia"; Needs="ingress"; Reason="login portal will not be reachable without an Ingress Controller" }
        )

        $deselected = [System.Collections.Generic.List[hashtable]]::new()
        $warnings   = [System.Collections.Generic.List[hashtable]]::new()
        $seen       = [System.Collections.Generic.HashSet[string]]::new()

        foreach ($dep in $hardDeps) {
            if ($willInstall.Contains($dep.C) -and -not $willInstall.Contains($dep.Needs)) {
                $willInstall.Remove($dep.C) | Out-Null
                # Deselect in $compSel so installation loop skips it
                $compSel[$dep.C] = $false
                # Deselect the whole group for single-component groups
                if ($dep.C -eq "rancher")  { [void]$selectedComponentGroups.Remove("Management") }
                if ($dep.C -eq "argocd")   { [void]$selectedComponentGroups.Remove("Utilities") }
                if ($dep.C -eq "longhorn") { [void]$selectedComponentGroups.Remove("Storage (Longhorn)") }
                if ($seen.Add($dep.C)) { $deselected.Add($dep) | Out-Null }
            }
        }
        foreach ($dep in $softDeps) {
            if ($willInstall.Contains($dep.C) -and -not $willInstall.Contains($dep.Needs)) {
                $warnings.Add($dep) | Out-Null
            }
        }

        if ($deselected.Count -gt 0 -or $warnings.Count -gt 0) {
            Clear-Host
            Write-Host ""
            Write-Host "  Dependency Check" -ForegroundColor Cyan
            Write-Host "  ────────────────────────────────────────────────────" -ForegroundColor DarkGray

            if ($deselected.Count -gt 0) {
                Write-Host ""
                Write-Host "  Automatically deselected — missing dependencies:" -ForegroundColor Red
                Write-Host ""
                foreach ($d in $deselected) {
                    Write-Host "  ✗  $($d.C)" -ForegroundColor Red
                    Write-Host "     → requires '$($d.Needs)': $($d.Reason)" -ForegroundColor DarkGray
                }
            }

            if ($warnings.Count -gt 0) {
                Write-Host ""
                Write-Host "  Will install but functionality is limited:" -ForegroundColor Yellow
                Write-Host ""
                foreach ($w in $warnings) {
                    Write-Host "  ⚠  $($w.C)" -ForegroundColor Yellow
                    Write-Host "     → $($w.Reason)" -ForegroundColor DarkGray
                }
            }

            Write-Host ""
            Write-Host "  ────────────────────────────────────────────────────" -ForegroundColor DarkGray
            Write-Host ""

            $continue = Read-YesNo `
                -Title "Continue with adjusted selection?" `
                -DefaultYes $true `
                -YesLabel "Continue — proceed with the adjustments above" `
                -NoLabel  "Cancel — exit and re-run to reconfigure" `
                -ContextTitle "Dependency Check"

            if (-not $continue) { Write-Host "  Installation cancelled." -ForegroundColor Yellow; exit 0 }
        }

        # Update Windows hosts file upfront for Kind (127.0.0.1, single UAC prompt)
        if ($platform -eq "Kind (Local)") {
            $hostnames = @()
            foreach ($inputs in $componentInputs.Values) {
                if ($inputs -is [hashtable] -and $inputs.ContainsKey('Hostname') -and -not [string]::IsNullOrWhiteSpace($inputs['Hostname'])) {
                    $hostnames += $inputs['Hostname']
                }
            }
            if ($hostnames.Count -gt 0) {
                Write-Host "`n--- Updating local hosts file ---" -ForegroundColor Magenta
                Update-HostsFile -Hostnames $hostnames
            }
        }

        # Fixed installation order — user selects WHAT, this defines WHEN.
        # Storage comes before Security so the Vault backend can use Longhorn as its storage class.
        $installOrder = @(
            "Ingress & Load Balancing"
            "Storage (Longhorn)"
            "Security & Certificates"
            "Configuration Management"
            "Management"
            "Observability Stack"
            "Utilities"
        )

        Clear-Host
        foreach ($group in $installOrder) {
            if ($group -notin $selectedComponentGroups) { continue }
            if ($componentMap.ContainsKey($group)) {
                Write-Host "`nInstalling components for: $group" -ForegroundColor Yellow
                $installComponents = @($componentMap[$group] | Where-Object {
                    (-not $_.SelKey) -or
                    (-not $compSel.ContainsKey($_.SelKey)) -or
                    ($compSel[$_.SelKey] -eq $true)
                } | Sort-Object { [int]$_.Number })
                foreach ($component in $installComponents) {
                    $componentDir = Join-Path $PSScriptRoot "$($component.Number)-$($component.Name)"
                    $installScript = Join-Path $componentDir "Install.ps1"

                    if (Test-Path $installScript) {
                        $extraArgs = if ($VerbosePreference -eq 'Continue') { @{ Verbose = $true } } else { @{} }
                        $promptArgs = if ($componentInputs.ContainsKey($component.Name)) { $componentInputs[$component.Name] } else { @{} }
                        & $installScript -Platform $platform @extraArgs @promptArgs
                        if ($LASTEXITCODE -ne 0) {
                            Write-Error "  ✗ $($component.DisplayName) installation failed — aborting"
                            exit 1
                        }
                    } else {
                        Write-Warning "  ⚠ Installation script not found: $installScript"
                    }
                }

                # Cloud platforms: nginx Install.ps1 wrote the external IP to .ingress-ip — update hosts file
                if ($group -eq "Ingress & Load Balancing" -and $platform -in @("Azure AKS", "AWS EKS", "Google GKE")) {
                    $ipStateFile = Join-Path $PSScriptRoot ".ingress-ip"
                    if (Test-Path $ipStateFile) {
                        $externalIp = (Get-Content $ipStateFile -Raw).Trim()
                        Remove-Item $ipStateFile -Force -ErrorAction SilentlyContinue
                        if ($externalIp) {
                            $hostnames = @()
                            foreach ($inputs in $componentInputs.Values) {
                                if ($inputs -is [hashtable] -and $inputs.ContainsKey('Hostname') -and -not [string]::IsNullOrWhiteSpace($inputs['Hostname'])) {
                                    $hostnames += $inputs['Hostname']
                                }
                            }
                            if ($hostnames.Count -gt 0) {
                                Write-Host "`n--- Updating local hosts file ---" -ForegroundColor Magenta
                                Update-HostsFile -Hostnames $hostnames -IpAddress $externalIp
                            }
                        }
                    } else {
                        Write-Warning "  ⚠ Could not get external IP — update hosts file manually with the ingress LoadBalancer IP"
                    }
                }
            }
        }
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "  All installations complete!" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
}

# Start the process
Start-Installation

