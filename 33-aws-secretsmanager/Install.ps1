<#
.SYNOPSIS
    Sets up AWS Secrets Manager as the cluster secrets backend via the
    AWS Secrets and Configuration Provider (ASCP) and IRSA (IAM Roles for Service Accounts).
    Creates a shared IAM role for CSI access used by all apps.
.PARAMETER Platform
    Target platform (must be "AWS EKS")
#>
[CmdletBinding()]
param([string]$Platform)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

$verbose    = $VerbosePreference -eq 'Continue'
$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform
$UserConfig = $FullConfig.UserConfig

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 33 - AWS Secrets Manager" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── Load EKS state ───────────────────────────────────────────────
$eksStatePath = Join-Path $BaseDir ".eks-state.json"
if (-not (Test-Path $eksStatePath)) { Write-Error "No .eks-state.json found — run EKS cluster setup first"; exit 1 }
$eksState    = Get-Content $eksStatePath | ConvertFrom-Json
$clusterName = $eksState.ClusterName
$region      = $eksState.Region

if ([string]::IsNullOrWhiteSpace($clusterName)) { Write-Error "ClusterName missing in .eks-state.json"; exit 1 }
if ([string]::IsNullOrWhiteSpace($region))      { Write-Error "Region missing in .eks-state.json";      exit 1 }

Write-Host "  Cluster: $clusterName" -ForegroundColor Gray
Write-Host "  Region:  $region" -ForegroundColor Gray
Write-Host ""

# ── 1. OIDC Provider aktivieren ──────────────────────────────────
$oidcUrl = & aws eks describe-cluster --name $clusterName --region $region `
    --query "cluster.identity.oidc.issuer" --output text 2>$null
if ($oidcUrl) { $oidcUrl = $oidcUrl.Trim() }

$oidcId = $oidcUrl -replace "https://", "" -replace ".*/", ""

$oidcExists = & aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?ends_with(Arn,'$oidcId')]" --output text 2>$null
if (-not $oidcExists) {
    $exitCode = Invoke-WithSpinner -Message "Creating OIDC provider for IRSA..." -Executable "eksctl" `
        -Arguments @("utils", "associate-iam-oidc-provider",
            "--cluster", $clusterName, "--region", $region, "--approve") -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Failed to create OIDC provider"; exit 1 }
    Write-Host "  ✓ OIDC provider created" -ForegroundColor Green
} else {
    Write-Host "  ✓ OIDC provider already exists" -ForegroundColor Green
}

# ── 2. AWS Account ID ermitteln ──────────────────────────────────
$accountId = & aws sts get-caller-identity --query Account --output text 2>$null
if ($accountId) { $accountId = $accountId.Trim() }

# ── 3. CSI IAM Policy erstellen ──────────────────────────────────
$policyName = "$clusterName-csi-secrets-policy"
$policyArn  = "arn:aws:iam::${accountId}:policy/$policyName"

$policyExists = & aws iam get-policy --policy-arn $policyArn 2>$null
if (-not $policyExists) {
    $policyDoc = @"
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": [
            "secretsmanager:GetSecretValue",
            "secretsmanager:DescribeSecret"
        ],
        "Resource": "arn:aws:secretsmanager:${region}:${accountId}:secret:*"
    }]
}
"@
    $tmpPolicy = New-TemporaryFile
    Set-Content -Path $tmpPolicy.FullName -Value $policyDoc -Encoding UTF8
    $exitCode = Invoke-WithSpinner -Message "Creating IAM policy '$policyName'..." -Executable "aws" `
        -Arguments @("iam", "create-policy",
            "--policy-name", $policyName,
            "--policy-document", "file://$($tmpPolicy.FullName)") -ShowOutput:$verbose
    Remove-Item $tmpPolicy.FullName -Force -ErrorAction SilentlyContinue
    if ($exitCode -ne 0) { Write-Error "Failed to create IAM policy"; exit 1 }
    Write-Host "  ✓ IAM policy created" -ForegroundColor Green
} else {
    Write-Host "  ✓ IAM policy already exists" -ForegroundColor Green
}

# ── 4. CSI IAM Role + Service Account erstellen ──────────────────
$saName   = "$clusterName-csi-sa"
$roleName = "$clusterName-csi-role"

$roleExists = & aws iam get-role --role-name $roleName 2>$null
if (-not $roleExists) {
    $exitCode = Invoke-WithSpinner -Message "Creating IAM role + ServiceAccount (IRSA)..." -Executable "eksctl" `
        -Arguments @("create", "iamserviceaccount",
            "--name", $saName,
            "--namespace", "kube-system",
            "--cluster", $clusterName,
            "--region", $region,
            "--attach-policy-arn", $policyArn,
            "--role-name", $roleName,
            "--approve", "--override-existing-serviceaccounts") -ShowOutput:$verbose
    if ($exitCode -ne 0) { Write-Error "Failed to create IRSA role"; exit 1 }
    Write-Host "  ✓ IAM role + ServiceAccount created" -ForegroundColor Green
} else {
    Write-Host "  ✓ IAM role already exists" -ForegroundColor Green
}

$roleArn = & aws iam get-role --role-name $roleName --query "Role.Arn" --output text 2>$null
if ($roleArn) { $roleArn = $roleArn.Trim() }

# ── 5. ASCP installieren ─────────────────────────────────────────
$exitCode = Invoke-WithSpinner -Message "Installing AWS Secrets and Config Provider (ASCP)..." -Executable "kubectl" `
    -Arguments @("apply", "-f",
        "https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Failed to install ASCP"; exit 1 }
Write-Host "  ✓ ASCP installed" -ForegroundColor Green

# ── 6. State speichern ───────────────────────────────────────────
$eksStateData = Get-Content $eksStatePath | ConvertFrom-Json -AsHashtable
$eksStateData['CsiRoleName']  = $roleName
$eksStateData['CsiRoleArn']   = $roleArn
$eksStateData['CsiSaName']    = $saName
$eksStateData['CsiPolicyArn'] = $policyArn
$eksStateData['AccountId']    = $accountId
$eksStateData['OidcId']       = $oidcId
$eksStateData | ConvertTo-Json | Set-Content -Path $eksStatePath -Encoding UTF8
Write-Host "  ✓ State saved" -ForegroundColor Green

if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $FullConfig.Namespace -ProjectName $FullConfig.RancherProject
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  CSI Role:   $roleArn" -ForegroundColor Yellow
Write-Host "  Auth:       IRSA per Pod (annotated ServiceAccount)" -ForegroundColor Gray
Write-Host "  Secrets:    mounted as files (no etcd)" -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
exit 0
