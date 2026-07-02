<#
.SYNOPSIS
    Install Homer — the self-updating Kubernetes portal dashboard.
    Components register themselves via Register-PortalEntry; a sidecar
    regenerates Homer's config.yml every 30 s from those ConfigMaps.
.PARAMETER Platform
    Target platform
.PARAMETER Hostname
    Portal hostname (from Prompt.ps1)
.PARAMETER Title
    Dashboard heading (from Prompt.ps1)
.PARAMETER Subtitle
    Dashboard sub-heading (from Prompt.ps1)
.PARAMETER ConfigPath
    Path to custom configuration file (optional)
#>
[CmdletBinding()]
param(
    [string]$Platform,
    [string]$Hostname,
    [string]$Title          = "Kubernetes Portal",
    [string]$Subtitle       = "",
    [string]$ThemeSourceUrl = "",
    [string]$ConfigPath
)

$ScriptRoot = $PSScriptRoot
$BaseDir    = Split-Path $ScriptRoot -Parent
Import-Module "$BaseDir\_lib\Installer.Ui.psm1"       -Force -Verbose:$false
Import-Module "$BaseDir\_lib\InstallerFunctions.psm1" -Force -Verbose:$false
Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

# Standalone: prompt if called directly without parameters
if ([string]::IsNullOrWhiteSpace($Hostname)) {
    $aksState = if (Test-Path (Join-Path $BaseDir ".aks-state.json")) {
        Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
    } else { $null }
    $domain = if ($aksState) {
        $label = ($aksState.ClusterName -replace '[^a-z0-9-]', '-').ToLower()
        "$label.$($aksState.Location).cloudapp.azure.com"
    } else { "kubernetes.local" }
    $inputs = & "$ScriptRoot\Prompt.ps1" -Platform $Platform -Domain $domain
    if (-not $inputs) { Write-Host "  Aborted." -ForegroundColor Red; exit 0 }
    $Hostname       = $inputs.Hostname
    $Title          = $inputs.Title
    $Subtitle       = $inputs.Subtitle
    $ThemeSourceUrl = $inputs.ThemeSourceUrl
}

$verbose = $VerbosePreference -eq 'Continue'

# Extract theme data from reference website: accent color (theme-color meta) + company logo
$accentColor   = ""
$portalLogoB64 = ""
$portalLogoExt = "png"
if (-not [string]::IsNullOrWhiteSpace($ThemeSourceUrl)) {
    Write-Host "  Fetching theme data from $ThemeSourceUrl ..." -ForegroundColor Gray -NoNewline
    try {
        $page = Invoke-WebRequest -Uri $ThemeSourceUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop

        # Accent color
        $colorFound = $page.Content -match '(?i)<meta\s[^>]*name=[''"]theme-color[''"]\s[^>]*content=[''"]([^''"]+)' -or
                      $page.Content -match '(?i)<meta\s[^>]*content=[''"]([^''"]+)[''"]\s[^>]*name=[''"]theme-color'
        if ($colorFound) { $accentColor = $Matches[1].Trim() }

        # Company logo: og:image → apple-touch-icon → favicon.ico
        $logoSrc = [regex]::Match($page.Content, '<meta[^>]+property="og:image"[^>]+content="([^"]+)"', 'IgnoreCase').Groups[1].Value
        if (-not $logoSrc) {
            $logoSrc = [regex]::Match($page.Content, '<link[^>]+rel="apple-touch-icon[^"]*"[^>]+href="([^"]+)"', 'IgnoreCase').Groups[1].Value
        }
        if (-not $logoSrc) {
            $u = [uri]$ThemeSourceUrl
            $logoSrc = "$($u.Scheme)://$($u.Host)/favicon.ico"
        }
        $imgResp = Invoke-WebRequest -Uri $logoSrc -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
        if ($imgResp -and $imgResp.Content) {
            $bytes = if ($imgResp.Content -is [byte[]]) { $imgResp.Content } else { [System.Text.Encoding]::UTF8.GetBytes($imgResp.Content) }
            $portalLogoB64 = [Convert]::ToBase64String($bytes)
            $portalLogoExt = if ($logoSrc -match '\.svg') { "svg" } elseif ($logoSrc -match '\.ico') { "ico" } elseif ($logoSrc -match '\.png') { "png" } else { "png" }
        }

        $statusParts = @()
        if ($accentColor)   { $statusParts += "color: $accentColor" }
        if ($portalLogoB64) { $statusParts += "logo: $([math]::Round($portalLogoB64.Length * 3 / 4 / 1024))KB $portalLogoExt" }
        if ($statusParts) { Write-Host " ✓ $($statusParts -join ', ')" -ForegroundColor Green }
        else              { Write-Host " ⚠ no theme-color or logo found, using defaults" -ForegroundColor Yellow }
    } catch {
        Write-Host " ⚠ fetch failed ($($_.Exception.Message)) — using default theme" -ForegroundColor Yellow
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installing: 70 - Portal - Homer" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$FullConfig = Get-ComponentConfig -ScriptRoot $ScriptRoot -Platform $Platform -ConfigPath $ConfigPath
$Namespace  = $FullConfig.Namespace
$UserConfig = $FullConfig.UserConfig

Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Hostname:   $Hostname" -ForegroundColor Gray
Write-Host "  Title:      $Title" -ForegroundColor Gray
Write-Host ""

# ── 1. Namespace ──────────────────────────────────────────────────────────────
& kubectl create namespace $Namespace --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create namespace '$Namespace'"; exit 1 }
Write-Host "  ✓ Namespace ready" -ForegroundColor Green

# ── 2. RBAC — sidecar reads ConfigMaps within the portal namespace ─────────────
$rbacYaml = @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: portal
  namespace: $Namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: portal-configmap-reader
  namespace: $Namespace
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: portal-configmap-reader
  namespace: $Namespace
subjects:
- kind: ServiceAccount
  name: portal
  namespace: $Namespace
roleRef:
  kind: Role
  name: portal-configmap-reader
  apiGroup: rbac.authorization.k8s.io
"@
$rbacYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply RBAC for portal"; exit 1 }
Write-Host "  ✓ RBAC ready" -ForegroundColor Green

# ── 3. Sidecar sync script ConfigMap ─────────────────────────────────────────
# Single-quoted here-string: no PowerShell interpolation — $ belongs to the shell.
$syncScript = @'
#!/bin/sh
INTERVAL="${SYNC_INTERVAL:-30}"
CONFIG_FILE="/www/assets/config.yml"

generate() {
  DATA=$(kubectl get configmap -n portal -l "portal/entry=true" -o json 2>/dev/null) || return
  COUNT=$(printf '%s' "$DATA" | jq '.items | length' 2>/dev/null)
  [ "${COUNT:-0}" -eq 0 ] && return

  ACCENT="${PORTAL_ACCENT_COLOR:-}"
  LOGO_B64="${PORTAL_LOGO_B64:-}"
  LOGO_EXT="${PORTAL_LOGO_EXT:-png}"

  {
    printf '---\ntitle: "%s"\nsubtitle: "%s"\nheader: true\nfooter: false\ncolumns: 3\nconnectivityCheck: false\n\n' \
      "${PORTAL_TITLE:-Kubernetes Portal}" "${PORTAL_SUBTITLE:-}"

    if [ -n "$LOGO_B64" ]; then
      case "$LOGO_EXT" in
        svg) LOGO_MIME="image/svg+xml" ;;
        ico) LOGO_MIME="image/x-icon" ;;
        *)   LOGO_MIME="image/${LOGO_EXT}" ;;
      esac
      printf 'logo: "data:%s;base64,%s"\n\n' "$LOGO_MIME" "$LOGO_B64"
    fi

    if [ -n "$ACCENT" ]; then
      printf 'colors:\n  light:\n    highlight-primary: "%s"\n    highlight-secondary: "#f0f0f0"\n    highlight-hover: "#e0e0e0"\n    link: "%s"\n    link-hover: "#555555"\n  dark:\n    highlight-primary: "%s"\n    highlight-secondary: "#2b2b2b"\n    highlight-hover: "#3a3a3a"\n    link: "%s"\n    link-hover: "#aaaaaa"\n\n' \
        "$ACCENT" "$ACCENT" "$ACCENT" "$ACCENT"
    fi

    printf 'services:\n'

    printf '%s' "$DATA" | jq -r '
      def mime(ext):
        if ext == "svg" then "image/svg+xml"
        elif ext == "ico" then "image/x-icon"
        else "image/" + ext
        end;

      .items |
      sort_by((.data.order // "100") | tonumber) |
      group_by(.data.category // "Other")[] |
      ("- name: \"" + (.[0].data.category // "Other") + "\""),
      "  items:",
      (.[] |
        ("  - name: \"" + (.data.name // "Unknown") + "\""),
        ("    subtitle: \"" + (.data.subtitle // "") + "\""),
        ("    url: \"" + (.data.url // "#") + "\""),
        "    target: \"_blank\"",
        (if (.data["logo.b64"] // "") != "" then
          "    logo: \"data:" + mime(.data["logo.ext"] // "png") + ";base64," + .data["logo.b64"] + "\""
        else empty end)
      )
    '
  } > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
}

while true; do
  generate
  sleep "$INTERVAL"
done
'@

$scriptTmp = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllBytes($scriptTmp, [System.Text.Encoding]::UTF8.GetBytes($syncScript.Replace("`r`n", "`n")))
    & kubectl create configmap portal-sidecar-script -n $Namespace `
        --from-file="sync.sh=$scriptTmp" `
        --dry-run=client -o yaml 2>&1 | & kubectl apply -f - 2>&1 | Out-Null
} finally {
    Remove-Item $scriptTmp -Force -ErrorAction SilentlyContinue
}
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create sidecar script ConfigMap"; exit 1 }
Write-Host "  ✓ Sidecar script ConfigMap ready" -ForegroundColor Green

# ── 4. Deployment ─────────────────────────────────────────────────────────────
$deployYaml = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: homer
  namespace: $Namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: homer
  template:
    metadata:
      labels:
        app: homer
    spec:
      serviceAccountName: portal
      containers:
      - name: homer
        image: $($UserConfig.HomerImage)
        ports:
        - containerPort: 8080
        resources:
          limits:
            cpu: "200m"
            memory: "64Mi"
          requests:
            cpu: "50m"
            memory: "32Mi"
        volumeMounts:
        - name: config-vol
          mountPath: /www/assets
      - name: config-sync
        image: $($UserConfig.SidecarImage)
        command: ["/bin/sh", "/scripts/sync.sh"]
        env:
        - name: PORTAL_TITLE
          value: "$Title"
        - name: PORTAL_SUBTITLE
          value: "$Subtitle"
        - name: PORTAL_ACCENT_COLOR
          value: "$accentColor"
        - name: PORTAL_LOGO_B64
          value: "$portalLogoB64"
        - name: PORTAL_LOGO_EXT
          value: "$portalLogoExt"
        - name: SYNC_INTERVAL
          value: "30"
        resources:
          limits:
            cpu: "100m"
            memory: "128Mi"
          requests:
            cpu: "20m"
            memory: "64Mi"
        volumeMounts:
        - name: config-vol
          mountPath: /www/assets
        - name: sidecar-script
          mountPath: /scripts
      volumes:
      - name: config-vol
        emptyDir: {}
      - name: sidecar-script
        configMap:
          name: portal-sidecar-script
          defaultMode: 0755
"@
$deployYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply Homer Deployment"; exit 1 }
Write-Host "  ✓ Deployment applied" -ForegroundColor Green

# ── 5. Service ────────────────────────────────────────────────────────────────
$serviceYaml = @"
apiVersion: v1
kind: Service
metadata:
  name: homer
  namespace: $Namespace
spec:
  selector:
    app: homer
  ports:
  - port: 8080
    targetPort: 8080
"@
$serviceYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply Homer Service"; exit 1 }
Write-Host "  ✓ Service ready" -ForegroundColor Green

# ── 6. Rollout ────────────────────────────────────────────────────────────────
$exitCode = Invoke-WithSpinner -Message "Waiting for rollout..." -Executable "kubectl" `
    -Arguments @("rollout", "status", "deployment/homer", "-n", $Namespace, "--timeout=5m") `
    -ShowOutput:$verbose
if ($exitCode -ne 0) { Write-Error "Homer rollout did not complete — check cluster state"; exit 1 }
Write-Host "  ✓ Homer ready" -ForegroundColor Green

# ── 7. Ingress ────────────────────────────────────────────────────────────────
$protect = Protect-ComponentIngress -Hostname $Hostname -Platform $Platform
$authAnnotations = ($protect.Annotations.GetEnumerator() | ForEach-Object { "    $($_.Key): `"$($_.Value)`"" }) -join "`n"

$ingressYaml = @"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: homer
  namespace: $Namespace
  annotations:
$authAnnotations
spec:
  ingressClassName: $(Get-IngressClass)
$($protect.TlsBlock)
  rules:
  - host: $Hostname
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: homer
            port:
              number: 8080
"@
$ingressYaml | & kubectl apply -f - 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "  ✓ Ingress configured ($Hostname)" -ForegroundColor Green }
else { Write-Warning "  Could not apply Ingress — check cluster ingress controller" }

# ── 8. Rancher project ────────────────────────────────────────────────────────
if ($FullConfig.RancherProject) {
    Set-RancherProjectAssignment -Namespace $Namespace -ProjectName $FullConfig.RancherProject
}

$scheme = if (-not [string]::IsNullOrWhiteSpace($protect.TlsBlock)) { "https" } else { "http" }

if ($verbose) {
    Write-Host ""
    & kubectl get pods -n $Namespace
}

Write-Host ""
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Quick Reference" -ForegroundColor White
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Access:    ${scheme}://$Hostname" -ForegroundColor Yellow
Write-Host "  Entries:   kubectl get configmap -n portal -l portal/entry=true" -ForegroundColor Gray
Write-Host ""
Write-Host "  The sidecar regenerates config.yml every 30 s from ConfigMaps" -ForegroundColor Gray
Write-Host "  labelled portal/entry=true.  Components register automatically" -ForegroundColor Gray
Write-Host "  via Register-PortalEntry whether or not the portal is installed." -ForegroundColor Gray
Write-Host "  ──────────────────────────────────────────" -ForegroundColor DarkGray

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

exit 0
