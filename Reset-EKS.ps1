<#
.SYNOPSIS
    Deletes the EKS cluster and optionally AWS Secrets Manager secrets and IAM resources.
    IAM roles, policies and Secrets Manager secrets are account-level resources
    and must be explicitly removed if no longer needed.
#>
[CmdletBinding()]
param()

$BaseDir   = $PSScriptRoot
$stateFile = Join-Path $BaseDir ".eks-state.json"

if (-not (Test-Path $stateFile)) {
    Write-Error "No EKS state file found at $stateFile. Nothing to reset."
    exit 1
}

$state = Get-Content $stateFile | ConvertFrom-Json
Import-Module "$BaseDir\_lib\Installer.Ui.psm1" -Force -Verbose:$false

Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "  EKS Teardown" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow
Write-Host "  Cluster: $($state.ClusterName)" -ForegroundColor Gray
Write-Host "  Region:  $($state.Region)" -ForegroundColor Gray
Write-Host "  Created: $($state.CreatedAt)" -ForegroundColor Gray
Write-Host ""

$confirm = Read-Host "  Type 'yes' to delete cluster '$($state.ClusterName)'"
if ($confirm -ne "yes") { Write-Host "  Aborted." -ForegroundColor Yellow; exit 0 }

& aws sts get-caller-identity 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  AWS credentials not configured. Run 'aws configure' first." -ForegroundColor Red
    exit 1
}

$eksctlPath = Join-Path $BaseDir ".tools\eksctl.exe"
if (-not (Test-Path $eksctlPath)) {
    Write-Error "eksctl not found at $eksctlPath. Run Install-Base.ps1 first to download it."
    exit 1
}

# ── 1. Delete cluster ───────────────────────────────────────────
$exitCode = Invoke-WithSpinner `
    -Message "Deleting EKS cluster '$($state.ClusterName)' (10-20 min)..." `
    -Executable $eksctlPath `
    -Arguments @("delete", "cluster", "--name", $state.ClusterName, "--region", $state.Region)
if ($exitCode -ne 0) { Write-Error "Failed to delete EKS cluster '$($state.ClusterName)'"; exit 1 }
Write-Host "  ✓ EKS cluster deleted" -ForegroundColor Green

# ── 2. Delete IAM role + policy? ────────────────────────────────
# These are account-level resources — they survive cluster deletion.
if ($state.CsiRoleName) {
    $deleteIam = Read-YesNo `
        -Title "IAM Role '$($state.CsiRoleName)' + Policy" `
        -Message "Delete as well?" `
        -DefaultYes $false `
        -YesLabel "Yes — delete IAM role and policy" `
        -NoLabel  "No — keep (reusable for a new cluster in the same account)" `
        -ContextTitle "EKS Teardown" `
        -ContextCurrent ([ordered]@{ Role = $state.CsiRoleName; Region = $state.Region })
    if ($deleteIam) {
        # Detach policy from role first
        if ($state.CsiPolicyArn) {
            Invoke-WithSpinner -Message "Detaching policy from role..." -Executable "aws" `
                -Arguments @("iam", "detach-role-policy",
                    "--role-name", $state.CsiRoleName,
                    "--policy-arn", $state.CsiPolicyArn) | Out-Null
        }
        $exitCode = Invoke-WithSpinner -Message "Deleting IAM role '$($state.CsiRoleName)'..." `
            -Executable "aws" `
            -Arguments @("iam", "delete-role", "--role-name", $state.CsiRoleName)
        if ($exitCode -eq 0) { Write-Host "  ✓ IAM role deleted" -ForegroundColor Green }
        else { Write-Warning "  IAM role delete failed — delete manually if needed" }

        if ($state.CsiPolicyArn) {
            $exitCode = Invoke-WithSpinner -Message "Deleting IAM policy..." -Executable "aws" `
                -Arguments @("iam", "delete-policy", "--policy-arn", $state.CsiPolicyArn)
            if ($exitCode -eq 0) { Write-Host "  ✓ IAM policy deleted" -ForegroundColor Green }
            else { Write-Warning "  IAM policy delete failed — delete manually if needed" }
        }
    } else {
        Write-Host "  ✓ IAM resources erhalten" -ForegroundColor Green
    }
}

# ── 3. AWS Secrets Manager Secrets ───────────────────────────────
Write-Host ""
Write-Host "  Hinweis: AWS Secrets Manager Secrets sind Account-Level Ressourcen" -ForegroundColor DarkGray
Write-Host "  and are not deleted automatically. Currently in $($state.Region):" -ForegroundColor DarkGray
$secrets = & aws secretsmanager list-secrets --region $state.Region `
    --query "SecretList[].Name" --output text 2>$null
if ($secrets) {
    $secrets -split "`t" | Where-Object { $_ } | ForEach-Object {
        Write-Host "    - $_" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  Zum Löschen: aws secretsmanager delete-secret --secret-id <name> --region $($state.Region)" -ForegroundColor DarkGray
} else {
    Write-Host "    (none found)" -ForegroundColor DarkGray
}

# ── 4. Remove state file ────────────────────────────────────────
Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "  ✓ State file removed" -ForegroundColor Green
Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  EKS Teardown Complete" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow

exit 0

