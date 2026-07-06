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
    [string]$Title      = "Kubernetes Portal",
    [string]$Subtitle   = "",
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
    $Hostname = $inputs.Hostname
    $Title    = $inputs.Title
    $Subtitle = $inputs.Subtitle
}

$verbose = $VerbosePreference -eq 'Continue'

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

# Fetch a logo from an internal service URL.
# Tries apple-touch-icon, favicon.png, favicon.ico in order.
# Outputs "base64data|ext" on success, returns 1 on failure.
fetch_logo() {
  base="${1%/}"
  [ -z "$base" ] && return 1
  tmp=$(mktemp)
  for path_ext in "/apple-touch-icon.png:png" "/apple-touch-icon-precomposed.png:png" "/favicon.png:png" "/favicon.ico:ico"; do
    path=$(printf '%s' "$path_ext" | cut -d: -f1)
    ext=$(printf '%s' "$path_ext" | cut -d: -f2)
    if wget -qO "$tmp" --timeout=5 --no-check-certificate "${base}${path}" 2>/dev/null; then
      size=$(wc -c < "$tmp" | tr -d '[:space:]')
      if [ "${size:-0}" -gt 200 ]; then
        printf '%s|%s' "$(base64 -w 0 < "$tmp")" "$ext"
        rm -f "$tmp"
        return 0
      fi
    fi
  done
  rm -f "$tmp"
  return 1
}

# Fixed-color badge behind every logo so monochrome/white brand marks (OpenBao,
# Jaeger, Longhorn, ...) stay visible regardless of Homer's light/dark theme.
write_custom_css() {
  cat > /www/assets/custom.css <<'CSS'
.card .image {
  background: #12151a;
  border-radius: 10px;
  padding: 6px;
}
CSS
}

generate() {
  DATA=$(kubectl get configmap -n portal -l "portal/entry=true" -o json 2>/dev/null) || return
  COUNT=$(printf '%s' "$DATA" | jq '.items | length' 2>/dev/null)
  [ "${COUNT:-0}" -eq 0 ] && return

  write_custom_css

  # Build logo overrides: entries with url.internal but no embedded logo.b64
  OVERRIDES="{}"
  printf '%s' "$DATA" | jq -r '
    .items[] |
    select((.data["logo.b64"] // "") == "" and (.data["url.internal"] // "") != "") |
    "\(.metadata.name)|\(.data["url.internal"])"
  ' > /tmp/portal_needs_logos.txt
  while IFS='|' read -r cm_name int_url; do
    [ -z "$cm_name" ] && continue
    result=$(fetch_logo "$int_url") || continue
    b64=$(printf '%s' "$result" | cut -d'|' -f1)
    ext=$(printf '%s' "$result" | cut -d'|' -f2)
    OVERRIDES=$(printf '%s' "$OVERRIDES" | jq \
      --arg n "$cm_name" --arg b "$b64" --arg e "$ext" \
      '. + {($n): {"b64": $b, "ext": $e}}')
  done < /tmp/portal_needs_logos.txt
  rm -f /tmp/portal_needs_logos.txt

  {
    printf '---\ntitle: "%s"\nsubtitle: "%s"\nheader: true\nfooter: false\ncolumns: 3\nconnectivityCheck: false\nstylesheet:\n  - "assets/custom.css"\n\n' \
      "${PORTAL_TITLE:-Kubernetes Portal}" "${PORTAL_SUBTITLE:-}"

    printf 'services:\n'

    printf '%s' "$DATA" | jq -r --argjson overrides "$OVERRIDES" '
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
        (($overrides[.metadata.name].b64 // "") as $ob64 |
        ($overrides[.metadata.name].ext // "png") as $oext |
        (.data["logo.b64"] // "") as $sb64 |
        (.data["logo.ext"] // "png") as $sext |
        (if $sb64 != "" then $sb64 else $ob64 end) as $logo_b64 |
        (if $sb64 != "" then $sext else $oext end) as $logo_ext |
        ("  - name: \"" + (.data.name // "Unknown") + "\""),
        ("    subtitle: \"" + (.data.subtitle // "") + "\""),
        ("    url: \"" + (.data.url // "#") + "\""),
        "    target: \"_blank\"",
        (if $logo_b64 != "" then
          "    logo: \"data:" + mime($logo_ext) + ";base64," + $logo_b64 + "\""
        else empty end))
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

# The config-sync container reads sync.sh once at process start; updating the
# ConfigMap alone doesn't restart the pod, so a re-applied script would sit
# unused until something else happened to recreate the pod. Stamping its hash
# onto the pod template forces a rollout whenever the script actually changes.
$syncScriptHash = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($syncScript))
) -replace '-', ''

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
      annotations:
        checksum/sync-script: "$syncScriptHash"
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
