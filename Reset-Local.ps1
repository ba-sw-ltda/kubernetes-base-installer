<#
.SYNOPSIS
    Vollständiges Zurücksetzen der lokalen Kind-Umgebung.
    Entfernt: Kind-Cluster, kubeconfig-Einträge, hosts-Einträge, Acrylic DNS, .tools-Verzeichnis.
.PARAMETER ClusterName
    Name des Kind-Clusters (default: my-kind-cluster)
.PARAMETER Domain
    Lokale DNS-Domain deren Einträge aus der hosts-Datei entfernt werden (default: kubernetes.local)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ClusterName = "my-kind-cluster",
    [string]$Domain      = "kubernetes.local"
)

$ToolsDir  = Join-Path $PSScriptRoot ".tools"
$kindExe   = Join-Path $ToolsDir "kind.exe"
$kubectlExe = Join-Path $ToolsDir "kubectl.exe"
$hostsFile = "C:\Windows\System32\drivers\etc\hosts"

Write-Host "`n========================================" -ForegroundColor Red
Write-Host "  Reset: Kind Local Environment" -ForegroundColor Red
Write-Host "========================================`n" -ForegroundColor Red

# ── 1. Delete Kind cluster ──────────────────────────────────────
Write-Host "--- 1. Kind Cluster ---" -ForegroundColor Magenta
if (Test-Path $kindExe) {
    $clusters = & $kindExe get clusters 2>&1
    if ($clusters -contains $ClusterName) {
        Write-Host "  Deleting Kind cluster '$ClusterName'..." -ForegroundColor Cyan
        & $kindExe delete cluster --name $ClusterName 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ✓ Cluster '$ClusterName' deleted" -ForegroundColor Green
        } else {
            Write-Warning "  Could not delete cluster '$ClusterName' — continuing"
        }
    } else {
        Write-Host "  ✓ No cluster '$ClusterName' found — skipping" -ForegroundColor Green
    }
} else {
    Write-Host "  ✓ kind.exe not found — skipping" -ForegroundColor Green
}

# ── 2. kubeconfig aufräumen ──────────────────────────────────────
Write-Host "`n--- 2. kubeconfig ---" -ForegroundColor Magenta
$contextName = "kind-$ClusterName"
if (Test-Path $kubectlExe) {
    $contexts = & $kubectlExe config get-contexts -o name 2>&1
    if ($contexts -contains $contextName) {
        & $kubectlExe config delete-context $contextName  2>&1 | Out-Null
        & $kubectlExe config delete-cluster  $contextName 2>&1 | Out-Null
        & $kubectlExe config unset "users.$contextName"   2>&1 | Out-Null
        Write-Host "  ✓ kubeconfig entries for '$contextName' removed" -ForegroundColor Green
    } else {
        Write-Host "  ✓ No kubeconfig entry for '$contextName' found — skipping" -ForegroundColor Green
    }
} else {
    # Fallback: direkt in der kubeconfig YAML bearbeiten
    $kubeConfig = Join-Path $env:USERPROFILE ".kube\config"
    if (Test-Path $kubeConfig) {
        $yaml = Get-Content $kubeConfig -Raw
        if ($yaml -match [regex]::Escape($contextName)) {
            Write-Warning "  kubectl not available — please manually remove '$contextName' from $kubeConfig"
        } else {
            Write-Host "  ✓ No kubeconfig entry for '$contextName' found — skipping" -ForegroundColor Green
        }
    } else {
        Write-Host "  ✓ No kubeconfig found — skipping" -ForegroundColor Green
    }
}

# ── 3. hosts-Einträge + DNS-Adapter zurücksetzen (UAC) ──────────
Write-Host "`n--- 3. Hosts file + DNS adapters ---" -ForegroundColor Magenta

$hostsLines    = if (Test-Path $hostsFile) { Get-Content $hostsFile -Encoding UTF8 } else { @() }
$hostsFiltered = $hostsLines | Where-Object { $_ -notmatch [regex]::Escape($Domain) }
$hostsChanged  = $hostsFiltered.Count -lt $hostsLines.Count

$physicalAdapters = Get-NetAdapter | Where-Object {
    $_.Status -eq "Up" -and
    $_.InterfaceAlias -notmatch "vEthernet|Loopback|TAP|NordLynx|OpenVPN|VMware|VMnet"
}
$adaptersToReset = $physicalAdapters | Where-Object {
    $v4 = (Get-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    $v6 = (Get-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue).ServerAddresses
    ($v4 -contains "127.0.0.1") -or ($v6 -contains "::1")
}

if ($hostsChanged -or $adaptersToReset.Count -gt 0) {
    $tempFile   = Join-Path $env:TEMP "hosts-clean.txt"
    $tempScript = Join-Path $env:TEMP "hosts-reset-elevated.ps1"

    if ($hostsChanged) {
        Set-Content -Path $tempFile -Value $hostsFiltered -Encoding UTF8
    }

    $adapterLines = $adaptersToReset | ForEach-Object {
        $idx       = $_.InterfaceIndex
        $v4cur     = (Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        $v6cur     = (Get-DnsClientServerAddress -InterfaceIndex $idx -AddressFamily IPv6 -ErrorAction SilentlyContinue).ServerAddresses
        $remaining = @(
            ($v4cur | Where-Object { $_ -and $_ -ne "127.0.0.1" })
            ($v6cur | Where-Object { $_ -and $_ -ne "::1" })
        ) | Where-Object { $_ }
        if ($remaining) {
            $addrStr = $remaining -join "','"
            "Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @('$addrStr')"
        } else {
            "Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses"
        }
    }

    $tempLog = Join-Path $env:TEMP "hosts-reset-elevated.log"
    $scriptLines = @(
        "`$ErrorActionPreference = 'Stop'"
        "try {"
        if ($hostsChanged) { "  Copy-Item -Path '$tempFile' -Destination '$hostsFile' -Force" }
        $adapterLines | ForEach-Object { "  $_" }
        "  exit 0"
        "} catch {"
        "  `$_ | Out-File '$tempLog' -Encoding UTF8"
        "  exit 1"
        "}"
    ) | Where-Object { $_ }
    Set-Content -Path $tempScript -Value ($scriptLines -join "`n") -Encoding UTF8

    $proc = Start-Process pwsh -Verb RunAs `
        -ArgumentList "-NonInteractive", "-File", "`"$tempScript`"" `
        -Wait -PassThru
    Remove-Item $tempScript -Force -ErrorAction SilentlyContinue
    Remove-Item $tempFile   -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -eq 0) {
        Remove-Item $tempLog -Force -ErrorAction SilentlyContinue
        if ($hostsChanged) {
            Write-Host "  ✓ Removed $($hostsLines.Count - $hostsFiltered.Count) line(s) containing '$Domain' from hosts" -ForegroundColor Green
        } else {
            Write-Host "  ✓ hosts file unchanged" -ForegroundColor Green
        }
        if ($adaptersToReset.Count -gt 0) {
            Write-Host "  ✓ DNS reset on: $($adaptersToReset.Name -join ', ')" -ForegroundColor Green
        } else {
            Write-Host "  ✓ DNS adapters already clean" -ForegroundColor Green
        }
    } else {
        $errMsg = if (Test-Path $tempLog) { Get-Content $tempLog -Raw; Remove-Item $tempLog -Force } else { "(no details)" }
        Write-Warning "  Elevated script failed: $errMsg"
    }
} else {
    Write-Host "  ✓ hosts file unchanged" -ForegroundColor Green
    Write-Host "  ✓ DNS adapters already clean" -ForegroundColor Green
}

# ── 4. Acrylic DNS deinstallieren ───────────────────────────────
Write-Host "`n--- 4. Acrylic DNS Proxy ---" -ForegroundColor Magenta
$acrylicService = Get-Service -Name "AcrylicDNSProxySvc" -ErrorAction SilentlyContinue

# Find uninstall command from Windows registry (works regardless of install path)
$uninstallCmd = $null
$regPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
foreach ($regPath in $regPaths) {
    $entry = Get-ItemProperty $regPath -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match "Acrylic" } |
        Select-Object -First 1
    if ($entry) { $uninstallCmd = $entry.UninstallString; break }
}

if ($acrylicService -or $uninstallCmd) {
    if ($uninstallCmd) {
        Write-Host "  Uninstalling Acrylic DNS Proxy..." -ForegroundColor Cyan
        # NSIS uninstallers need /SILENT; strip any existing flags first
        $uninstExe  = ($uninstallCmd -split ' ')[0].Trim('"')
        $proc = Start-Process $uninstExe -ArgumentList "/SILENT" -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-Host "  ✓ Acrylic DNS Proxy uninstalled" -ForegroundColor Green
        } else {
            Write-Warning "  Uninstaller returned $($proc.ExitCode) — please remove manually via Settings > Apps"
        }
    } else {
        Write-Warning "  Service found but no uninstaller entry in registry — please remove Acrylic DNS Proxy manually via Settings > Apps"
    }
} else {
    Write-Host "  ✓ Acrylic not installed — skipping" -ForegroundColor Green
}

# ── 5. .tools Verzeichnis leeren ────────────────────────────────
Write-Host "`n--- 5. Tools (.tools/) ---" -ForegroundColor Magenta
if (Test-Path $ToolsDir) {
    Remove-Item -Path $ToolsDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $ToolsDir)) {
        Write-Host "  ✓ .tools/ removed" -ForegroundColor Green
    } else {
        Write-Warning "  Could not fully remove .tools/ — check for locked files"
    }
} else {
    Write-Host "  ✓ .tools/ not found — skipping" -ForegroundColor Green
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Reset complete — ready for fresh install" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

