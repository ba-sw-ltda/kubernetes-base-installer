Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Module-level base directory — one level up from _lib/.
# All functions use this as default so callers never need to pass -BaseDir or -Platform.
$script:InstallerBaseDir     = Split-Path $PSScriptRoot -Parent
$script:InstallerPlatform    = ""   # set by Connect-Cluster
# $env:INSTALLER_LAST_CONTEXT tracks last set context across module reloads (survives -Force reimport)

# -------------------------
# Connect-Cluster — one-time session initializer for standalone app installers.
# Selects platform, runs login, checks required tools, sets kubectl context.
# After calling this, Write-ClusterSecret / New-CsiSecretMount need no -Platform.
# -------------------------
function Connect-Cluster {
    param(
        [string]$BaseDir = $script:InstallerBaseDir,
        [string]$Platform = ""    # skip selection if already known
    )

    # ── Platform auswählen ──────────────────────────────────────
    if (-not $Platform) {
        $Platform = Read-SelectValue `
            -Title "Zielplattform auswählen" `
            -Message "Auf welchem Cluster soll die Installation ausgeführt werden?" `
            -Options @(
                @{ Label = "Azure AKS";         Value = "Azure AKS" }
                @{ Label = "AWS EKS";           Value = "AWS EKS" }
                @{ Label = "Google GKE";        Value = "Google GKE" }
                @{ Label = "RKE2 (On-Premise)"; Value = "RKE2 (On-Premise)" }
                @{ Label = "Kind (Local)";      Value = "Kind (Local)" }
            ) `
            -Default 0 `
            -ContextTitle "Cluster verbinden" `
            -ContextHint "Wählt die Plattform, setzt den kubectl Context und prüft Tools"
        if (-not $Platform) { return $false }
    }

    # ── Login / Context setzen ──────────────────────────────────
    Set-ClusterContext -BaseDir $BaseDir -Platform $Platform

    # ── Modul-Variable setzen ───────────────────────────────────
    $script:InstallerPlatform = $Platform
    $script:InstallerBaseDir  = $BaseDir
    return $true
}

# -------------------------
# Basics
# -------------------------
function Test-CommandExists {
  param([string]$Name)
  return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function ToSafeName {
  param([string]$s)
  if ([string]::IsNullOrWhiteSpace($s)) { return "" }
  return ($s -replace '[^a-zA-Z0-9]', '-').ToLower()
}

function Get-ContextEntries {
  param($Current)

  if ($null -eq $Current) { return @() }

  # 1) Liste von Einträgen (Key/Value) -> 그대로
  if ($Current -is [System.Collections.IEnumerable] -and -not ($Current -is [System.Collections.IDictionary]) -and -not ($Current -is [string])) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Current) {
      if ($null -eq $e) { continue }

      # Hashtable/PSCustomObject mit Key/Value
      $k = $null
      $v = $null
      if ($e -is [System.Collections.IDictionary]) {
        if ($e.Contains("Key")) { $k = $e["Key"] }
        if ($e.Contains("Value")) { $v = $e["Value"] }
      } else {
        $kp = $e.PSObject.Properties["Key"]
        $vp = $e.PSObject.Properties["Value"]
        if ($kp) { $k = $kp.Value }
        if ($vp) { $v = $vp.Value }
      }

      if ($null -ne $k) {
        $out.Add([pscustomobject]@{ Key = [string]$k; Value = $v }) | Out-Null
      }
    }
    return $out.ToArray()
  }

  # 2) Dictionary (Hashtable, OrderedDictionary, [ordered]@{}) -> Enumerationsreihenfolge
  if ($Current -is [System.Collections.IDictionary]) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $Current.GetEnumerator()) {
      $out.Add([pscustomobject]@{ Key = [string]$entry.Key; Value = $entry.Value }) | Out-Null
    }
 
    return $out.ToArray()
  }

  # 3) Fallback
  return @([pscustomobject]@{ Key = "Value"; Value = $Current })
}


# -------------------------
# Context / Sections
# - Menüs clearen immer den Screen, daher rendern wir Kontext + Werte bei jedem Refresh erneut.
# -------------------------
function Write-Context {
  param(
    [string]$Title = "",
    [string]$Hint = "",
    $Current = $null,
    [string[]]$MaskKeys = @()
  )

  Clear-Host

  if ($Title) { Write-Host $Title -ForegroundColor Cyan }
  if ($Hint)  { Write-Host $Hint  -ForegroundColor DarkGray }

  Write-Host ""
  $entries = @(Get-ContextEntries $Current)
  if ($entries.Count -gt 0) {
    foreach ($e in $entries) {
      $k = $e.Key
      $v = $e.Value
      if ($null -eq $v) { $v = "" }
      if ($MaskKeys -contains $k) { $v = "********" }

      Write-Host ("{0}: {1}" -f $k, $v) -ForegroundColor Gray
    }
  }
}

function Write-Section {
  param(
    [string]$Title,
    [string]$Hint = "",
    $Current = $null,
    [string[]]$MaskKeys = @()
  )
  Write-Context -Title $Title -Hint $Hint -Current $Current -MaskKeys $MaskKeys
}

# -------------------------
# Options: Label/Value normalization
# Supports:
# - "text"                     => Label="text", Value="text"
# - @{Label="X"; Value=123}     => Label="X", Value=123
# - [pscustomobject] with Label/Value
# - fallback => Label=ToString(), Value=object
# -------------------------
function ConvertTo-UiOptions {
  param(
    $Options
  )

  # 1) Eingabe stabil in eine Item-Liste normalisieren, ohne PowerShell-Flattening (@(...))
  $items = New-Object System.Collections.Generic.List[object]

  if ($null -eq $Options) {
    # nichts
  }
  elseif ($Options -is [string]) {
    $items.Add($Options) | Out-Null
  }
  elseif ($Options -is [System.Collections.IDictionary]) {
    # Hashtable ist IEnumerable -> darf NICHT automatisch zerlegt werden, wenn es eine "single option" ist.
    $hasLabel = $false
    $hasValue = $false
    foreach ($k in $Options.Keys) {
      if ($k.ToString().Equals("Label",[System.StringComparison]::OrdinalIgnoreCase)) { $hasLabel = $true }
      if ($k.ToString().Equals("Value",[System.StringComparison]::OrdinalIgnoreCase)) { $hasValue = $true }
    }

    if ($hasLabel -or $hasValue) {
      # Single option => als EIN Element behandeln
      $items.Add($Options) | Out-Null
    } else {
      # Dictionary ohne Label/Value => ebenfalls als EIN Element (nicht zerlegen)
      $items.Add($Options) | Out-Null
    }
  }
  elseif (($Options -is [System.Collections.IEnumerable]) -and -not ($Options -is [string])) {
    # Arrays/Listen/Enumerables => explizit einsammeln
    foreach ($x in $Options) { $items.Add($x) | Out-Null }
  }
  else {
    $items.Add($Options) | Out-Null
  }

  # 2) In UI-Options (Label/Value) transformieren
  $out = New-Object System.Collections.Generic.List[object]

  foreach ($o in $items) {
    if ($null -eq $o) { continue }

    if ($o -is [string]) {
      $out.Add([pscustomobject]@{ Label = $o; Value = $o }) | Out-Null
      continue
    }

    if ($o -is [System.Collections.IDictionary]) {
      $label = $null
      $value = $null

      foreach ($k in $o.Keys) {
        if ($k -match '^(?i)label$') { $label = $o[$k] }
        if ($k -match '^(?i)value$') { $value = $o[$k] }
      }

      if ($null -eq $label) { $label = [string]$o }
      if ($null -eq $value) { $value = $label }

      $out.Add([pscustomobject]@{ Label = [string]$label; Value = $value }) | Out-Null
      continue
    }

    $p = $o.PSObject.Properties
    $labelProp = $p | Where-Object { $_.Name -match '^(?i)label$' } | Select-Object -First 1
    $valueProp = $p | Where-Object { $_.Name -match '^(?i)value$' } | Select-Object -First 1

    if ($labelProp) {
      $label = [string]$labelProp.Value
      $value = if ($valueProp) { $valueProp.Value } else { $label }
      $out.Add([pscustomobject]@{ Label = $label; Value = $value }) | Out-Null
      continue
    }

    $out.Add([pscustomobject]@{ Label = [string]$o; Value = $o }) | Out-Null
  }

  # 3) Rückgabe ohne @(...)-Binder: echtes Array via .ToArray()
  return $out.ToArray()
}

# -------------------------
# Select (vertical only)
# - Returns index or value
# -------------------------
function Read-SelectIndex {
  param(
    [string]$Title,
    [string]$Message,
    [object]$Options,
    [int]$Default = 0,

    [string]$ContextTitle = "",
    [string]$ContextHint = "",
    $ContextCurrent = $null,
    [string[]]$MaskKeys = @()
  )

  $ui = ConvertTo-UiOptions -Options $Options
  if (-not $ui -or $ui.Count -eq 0) { throw "Options leer: $Title" }

  $labels = @($ui | ForEach-Object { $_.Label })
  $idx = [Math]::Min([Math]::Max($Default,0), $labels.Count-1)

  while ($true) {
    Write-Context -Title $ContextTitle -Hint $ContextHint -Current $ContextCurrent -MaskKeys $MaskKeys

    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    if ($Message)  { Write-Host $Message -ForegroundColor Gray }
    Write-Host ""

    for ($i=0; $i -lt $labels.Length; $i++) {
      if ($i -eq $idx) { Write-Host ("> " + $labels[$i]) -ForegroundColor Green }
      else { Write-Host ("  " + $labels[$i]) }
    }

    $k = [Console]::ReadKey($true)
    switch ($k.Key) {
      'UpArrow'   { $idx = ($idx - 1 + $labels.Length) % $labels.Length }
      'DownArrow' { $idx = ($idx + 1) % $labels.Length }
      'Enter'     { return $idx }
      'Escape'    { return -1 }
    }
  }
}

function Read-SelectValue {
  param(
    [string]$Title,
    [string]$Message,
    $Options,
    [int]$Default = 0,

    [string]$ContextTitle = "",
    [string]$ContextHint = "",
    $ContextCurrent = $null,
    [string[]]$MaskKeys = @(),
    [scriptblock]$Loader = $null,     # optional: runs first, shows spinner, result replaces $Options
    [string]$LoadingMessage = "Lade Daten...",
    [string]$DefaultValue = "",       # pre-select by value after Loader runs
    [object[]]$LoaderArgs = @()       # extra args passed to Loader after $env:PATH
  )

  # If a loader is provided: render the context+title, show spinner, run loader, then show result
  if ($Loader) {
    Write-Context -Title $ContextTitle -Hint $ContextHint -Current $ContextCurrent -MaskKeys $MaskKeys
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    if ($Message) { Write-Host $Message -ForegroundColor Gray }
    Write-Host ""

    $frames = @('|','/','-','\'); $fi = 0
    $job = Start-Job -ScriptBlock $Loader -ArgumentList (@($env:PATH) + $LoaderArgs)
    while ($job.State -eq 'Running') {
      [Console]::Write("`r  $($frames[$fi++ % 4]) $LoadingMessage")
      Start-Sleep -Milliseconds 150
    }
    [Console]::Write("`r" + (" " * ($LoadingMessage.Length + 6)) + "`r")
    $loaded = Receive-Job $job -Wait; Remove-Job $job -Force
    if ($loaded) { $Options = $loaded }

    # Re-calculate default index based on DefaultValue after Loader replaced options
    if ($DefaultValue) {
        $ui2 = ConvertTo-UiOptions -Options $Options
        $found = ($ui2 | ForEach-Object { $_.Value }).IndexOf($DefaultValue)
        if ($found -ge 0) { $Default = $found }
    }
  }

  $ui = ConvertTo-UiOptions -Options $Options
  if (-not $ui -or $ui.Count -eq 0) { throw "Options leer: $Title" }

  $i = Read-SelectIndex -Title $Title -Message $Message -Options $ui -Default $Default `
    -ContextTitle $ContextTitle -ContextHint $ContextHint -ContextCurrent $ContextCurrent -MaskKeys $MaskKeys

  if ($i -lt 0) { return $null }
  return $ui[$i].Value
}

# -------------------------
# Yes/No (vertical only, returns bool)
# -------------------------
function Read-YesNo {
  param(
    [string]$Title,
    [string]$Message,
    [bool]$DefaultYes = $true,
    [string]$YesLabel = "Yes",
    [string]$NoLabel  = "No",

    [string]$ContextTitle = "",
    [string]$ContextHint = "",
    $ContextCurrent = $null,
    [string[]]$MaskKeys = @()
  )

  $opts = @(
    @{ Label = $YesLabel; Value = $true  }
    @{ Label = $NoLabel;  Value = $false }
  )
  $def = if ($DefaultYes) { 0 } else { 1 }

  $val = Read-SelectValue -Title $Title -Message $Message -Options $opts -Default $def `
    -ContextTitle $ContextTitle -ContextHint $ContextHint -ContextCurrent $ContextCurrent -MaskKeys $MaskKeys

  if ($null -eq $val) { return $false }
  return [bool]$val
}

# -------------------------
# MultiSelect (vertical, returns Values)
# - Space toggles, Enter confirms
# - Options support Label/Value
# -------------------------
function Read-MultiSelectValues {
  param(
    [string]$Title,
    [string]$Message,
    [object]$Options,
    [object[]]$DefaultValues = @(),
    [hashtable]$Disabled = @{},

    [string]$ContextTitle = "",
    [string]$ContextHint = "",
    $ContextCurrent = $null,
    [string[]]$MaskKeys = @()
  )

  $ui = ConvertTo-UiOptions -Options $Options
  if (-not $ui -or $ui.Count -eq 0) { throw "Options leer: $Title" }

  $labels = @($ui | ForEach-Object { $_.Label })

  $sel = @{}
  0..($labels.Count-1) | ForEach-Object { $sel[$_] = $false }

  # defaults by value
  for ($i=0; $i -lt $ui.Count; $i++) {
    if ($DefaultValues -contains $ui[$i].Value) { $sel[$i] = $true }
  }

  $idx = 0
  $done = $false

  while (-not $done) {
    Write-Context -Title $ContextTitle -Hint $ContextHint -Current $ContextCurrent -MaskKeys $MaskKeys

    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    if ($Message)  { Write-Host $Message -ForegroundColor Gray }
    Write-Host ""

    for ($i=0; $i -lt $labels.Length; $i++) {
      $mark = if ($sel[$i]) { "[x]" } else { "[ ]" }
      $prefix = if ($i -eq $idx) { ">" } else { " " }
      $name = $labels[$i]

      $isDisabled = $Disabled.ContainsKey($name) -and $Disabled[$name]
      $line = "{0} {1} {2}" -f $prefix, $mark, $name

      if ($isDisabled) { Write-Host $line -ForegroundColor DarkGray }
      elseif ($i -eq $idx) { Write-Host $line -ForegroundColor Green }
      else { Write-Host $line }
    }

    $k = [Console]::ReadKey($true)
    switch ($k.Key) {
      'UpArrow'   { $idx = ($idx - 1 + $labels.Length) % $labels.Length }
      'DownArrow' { $idx = ($idx + 1) % $labels.Length }
      'Spacebar'  {
        $name = $labels[$idx]
        $isDisabled = $Disabled.ContainsKey($name) -and $Disabled[$name]
        if (-not $isDisabled) { $sel[$idx] = -not $sel[$idx] }
      }
      'Enter'  { $done = $true }
      'Escape' { return $null }
    }
  }

  $idxs = @($sel.GetEnumerator() | Where-Object Value | ForEach-Object { [int]$_.Key } | Sort-Object)
  return @($idxs | ForEach-Object { $ui[$_].Value })
}

# -------------------------
# Component selection screen — two-level: group headers + checkboxes/radios
#
# $Sections = @(
#   @{ Label = "Ingress"; Items = @(
#     @{ Label = "NGINX"; Value = "nginx";    Type = "radio"; RadioGroup = "ingress"; Default = $true  }
#     @{ Label = "Traefik"; Value = "traefik"; Type = "radio"; RadioGroup = "ingress"; Default = $false }
#     @{ Label = "MetalLB"; Value = "metallb"; Type = "check";                        Default = $true  }
#   )}
# )
#
# Returns hashtable: Value -> $true/$false.
# For radio groups exactly one item per group is $true.
# Returns $null if the user presses Escape.
# -------------------------
function Read-ComponentSelectionScreen {
  # Two-level component selector.
  #
  # $Sections = @(
  #   @{ Label = "Ingress & LB"          # non-interactive separator (Screen-1 group name)
  #      Items = @(
  #        @{ Label="Ingress"; Value="ingress"; Type="group"; Default=$true; Children=@(
  #            @{ Label="NGINX"; Value="nginx"; Type="radio"; RadioGroup="ingress"; Default=$true }
  #            @{ Label="Traefik"; Value="traefik"; Type="radio"; RadioGroup="ingress"; Default=$false }
  #        )}
  #        @{ Label="MetalLB"; Value="metallb"; Type="check"; Default=$true }
  #      )
  #   }
  # )
  # Returns hashtable: Value -> $true/$false.  $null on Escape.
  param(
    [string]$Title   = "Select components",
    [string]$Message = "",
    [object[]]$Sections
  )

  # Build flat list: sep | group | check | radio
  # radio items carry ParentValue so we know which group they belong to
  $flat = [System.Collections.Generic.List[hashtable]]::new()
  foreach ($sec in $Sections) {
    $flat.Add(@{ Kind="sep"; Label=$sec.Label }) | Out-Null
    foreach ($item in @($sec.Items)) {
      if ($item.Type -eq "group") {
        $flat.Add(@{ Kind="group"; Label=$item.Label; Value=$item.Value; Checked=[bool]$item.Default }) | Out-Null
        foreach ($child in @($item.Children)) {
          $flat.Add(@{
            Kind        = "radio"
            Label       = $child.Label
            Value       = $child.Value
            RadioGroup  = $child.RadioGroup
            Checked     = [bool]$child.Default
            ParentValue = $item.Value
          }) | Out-Null
        }
      } else {
        $flat.Add(@{ Kind=$item.Type; Label=$item.Label; Value=$item.Value; Checked=[bool]$item.Default }) | Out-Null
      }
    }
  }

  # Ensure each radio group has exactly one item selected
  $flat | Where-Object { $_.Kind -eq "radio" } | Group-Object RadioGroup | ForEach-Object {
    $sel = @($_.Group | Where-Object { $_.Checked })
    if ($sel.Count -eq 0) { $_.Group[0].Checked = $true }
    elseif ($sel.Count -gt 1) { $_.Group | ForEach-Object { $_.Checked = $false }; $_.Group[0].Checked = $true }
  }

  # Visible interactive items: sep skipped, radios hidden when parent group unchecked
  function Get-Nav($f) {
    $checkedGroups = @($f | Where-Object { $_.Kind -eq "group" -and $_.Checked } | ForEach-Object { $_.Value })
    @($f | Where-Object {
      $_.Kind -notin @("sep") -and
      ($_.Kind -ne "radio" -or $checkedGroups -contains $_.ParentValue)
    })
  }

  $cursor = 0
  $done   = $false

  while (-not $done) {
    $nav = Get-Nav $flat
    if ($cursor -ge $nav.Count) { $cursor = [Math]::Max(0, $nav.Count - 1) }

    Clear-Host
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Cyan
    if ($Message) { Write-Host "  $Message" -ForegroundColor Gray }
    Write-Host "  Space = toggle   Enter = confirm   Esc = cancel" -ForegroundColor DarkGray
    Write-Host ""

    # Pre-count top-level items per section — single-item sections skip the separator
    $secCounts = @{}; $curSep = ""
    foreach ($item in $flat) {
      if ($item.Kind -eq "sep") { $curSep = $item.Label; $secCounts[$curSep] = 0 }
      elseif ($item.Kind -ne "radio" -and $curSep) { $secCounts[$curSep]++ }
    }

    $lastSep = ""
    $navPos  = 0
    foreach ($item in $flat) {
      if ($item.Kind -eq "sep") {
        $lastSep = $item.Label
        continue
      }
      if ($item.Kind -eq "radio") {
        $parent = $flat | Where-Object { $_.Kind -eq "group" -and $_.Value -eq $item.ParentValue } | Select-Object -First 1
        if (-not $parent -or -not $parent.Checked) { continue }
      }

      # Print section separator label before first item of a new section
      if ($lastSep) {
        if ($secCounts[$lastSep] -gt 1) {
          Write-Host ""
          Write-Host "  $lastSep" -ForegroundColor DarkGray
        }
        $lastSep = ""
      }

      $isFocused = ($navPos -eq $cursor)
      $arrow     = if ($isFocused) { ">" } else { " " }

      switch ($item.Kind) {
        "group" {
          $mark = if ($item.Checked) { "[X]" } else { "[ ]" }
          $line = "  $arrow $mark $($item.Label)"
          if ($isFocused) { Write-Host $line -ForegroundColor Green }
          else            { Write-Host $line }
        }
        "check" {
          $mark = if ($item.Checked) { "[X]" } else { "[ ]" }
          $line = "  $arrow $mark $($item.Label)"
          if ($isFocused) { Write-Host $line -ForegroundColor Green }
          else            { Write-Host $line }
        }
        "radio" {
          $mark = if ($item.Checked) { "(*)" } else { "( )" }
          $line = "  $arrow     $mark $($item.Label)"
          if ($isFocused) { Write-Host $line -ForegroundColor Green }
          else            { Write-Host $line -ForegroundColor Gray }
        }
      }
      $navPos++
    }

    Write-Host ""
    $k = [Console]::ReadKey($true)
    switch ($k.Key) {
      'UpArrow'   { $cursor = [Math]::Max(0, $cursor - 1) }
      'DownArrow' { $cursor = [Math]::Min($nav.Count - 1, $cursor + 1) }
      'Spacebar'  {
        $item = $nav[$cursor]
        switch ($item.Kind) {
          "group" {
            $item.Checked = -not $item.Checked
            $nav2 = Get-Nav $flat
            if ($cursor -ge $nav2.Count) { $cursor = [Math]::Max(0, $nav2.Count - 1) }
          }
          "check" { $item.Checked = -not $item.Checked }
          "radio" {
            $flat | Where-Object { $_.Kind -eq "radio" -and $_.RadioGroup -eq $item.RadioGroup } |
              ForEach-Object { $_.Checked = $false }
            $item.Checked = $true
          }
        }
      }
      'Enter'  { $done = $true }
      'Escape' { return $null }
    }
  }

  # Build result: group/check values + radio values (only from checked groups)
  $result = @{}
  $checkedGroups = @($flat | Where-Object { $_.Kind -eq "group" -and $_.Checked } | ForEach-Object { $_.Value })
  $flat | Where-Object { $_.Kind -in @("group", "check") } | ForEach-Object { $result[$_.Value] = $_.Checked }
  $flat | Where-Object { $_.Kind -eq "radio" -and $checkedGroups -contains $_.ParentValue } |
    ForEach-Object { $result[$_.Value] = $_.Checked }
  return $result
}

# -------------------------
# Plain input
# -------------------------
function Read-Plain {
  param(
    [string]$Prompt,
    [string]$Default = "",
    [string]$ContextTitle = "",
    [string]$ContextHint = "",
    $ContextCurrent = $null,
    [string[]]$MaskKeys = @()
  )

  Write-Context -Title $ContextTitle -Hint $ContextHint -Current $ContextCurrent -MaskKeys $MaskKeys
  $displayPrompt = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
  $value = Read-Host $displayPrompt
  if ([string]::IsNullOrWhiteSpace($value) -and $Default) { $Default } else { $value }
}

# -------------------------
# Secret input
# -------------------------
function Read-Secret {
  param(
    [string]$Prompt
  )

  $sec = Read-Host -AsSecureString $Prompt
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($b) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Read-SecretPlain {
  param(
    [string]$Prompt,
  
    [string]$ContextTitle = "",
    [string]$ContextHint = "",
    $ContextCurrent = $null,
    [string[]]$MaskKeys = @()
  )

  Write-Context -Title $ContextTitle -Hint $ContextHint -Current $ContextCurrent -MaskKeys $MaskKeys
  Read-Secret $Prompt
}


function Read-SecretPlainConfirm {
  param(
    [string]$Prompt1 = "Passwort",
    [string]$Prompt2 = "Passwort erneut eingeben",
  
    [string]$ContextTitle = "",
    [string]$ContextHint = "",
    $ContextCurrent = $null,
    [string[]]$MaskKeys = @()
  )

  while ($true) {
    Write-Context -Title $ContextTitle -Hint $ContextHint -Current $ContextCurrent -MaskKeys $MaskKeys

    $p1 = Read-Secret $Prompt1
    if ([string]::IsNullOrWhiteSpace($p1)) {
      Write-Host "  Passwort darf nicht leer sein. Bitte erneut eingeben (ESC/Ctrl-C zum Abbrechen)." -ForegroundColor Yellow
      Start-Sleep -Milliseconds 700
      continue
    }

    $p2 = Read-Secret $Prompt2
    if ($p1 -ne $p2) {
      Write-Host "  Passwörter stimmen nicht überein. Bitte erneut." -ForegroundColor Yellow
      Start-Sleep -Milliseconds 700
      continue
    }
    return $p1
  }
}

# -------------------------
# High-level: Install Identity
# - Simulation: SIM + ProjectCode (no separator)
# - Generic: Name
# - Result contains FinalNameRaw/FinalNameSafe + Namespace/Release (both = FinalNameSafe)
# -------------------------
function Read-InstallIdentity {
  param(
    [hashtable]$Existing = $null,
    [string]$SimulationPrefix = "SIM"
  )

  if ($null -ne $Existing) { return $Existing }

  $ctx = [ordered]@{
  }

  $installType = Read-SelectValue `
    -Title "Installationstyp auswählen" `
    -Message "Simulation: Kundensimulationsanlage; Allgemein: Allgemeine Installation;" `
    -Options @(
      @{ Label = "Simulation"; Value = "Simulation" }
      @{ Label = "Allgemein";    Value = "Generic" }
    ) `
    -Default 0 `
    -ContextTitle "Identität" `
    -ContextHint "Bestimmt die Art der Installation und somit den finalen Namen." `
    -ContextCurrent $ctx

  if (-not $installType) { return $null }

  $ctx = [ordered]@{
    "Installationstyp" = $installType
  }

  if ($installType -eq "Simulation") {
    $projectCode = Read-Plain -Prompt "Projektkürzel" -ContextTitle "Identität" -ContextHint "Der finale Name wird aus $SimulationPrefix und Projektkürzel zusammengebaut." -ContextCurrent $ctx
    if ([string]::IsNullOrWhiteSpace($projectCode)) { throw "Projektkürzel ist Pflicht" }
    $finalRaw = "{0}{1}" -f $SimulationPrefix, $projectCode
    $name = ""
  } else {
    $name = Read-Plain -Prompt "Name" -ContextTitle "Identität" -ContextHint "" -ContextCurrent $ctx
    if ([string]::IsNullOrWhiteSpace($name)) { throw "Name ist Pflicht" }
    $finalRaw = $name
    $projectCode = ""
  }

  $finalSafe = ToSafeName $finalRaw
  if ([string]::IsNullOrWhiteSpace($finalSafe)) { throw "Finaler Name nach Normalisierung leer: '$finalRaw'" }

  return @{
    InstallType   = $installType
    ProjectCode   = $projectCode
    Name          = $name
    FinalNameRaw  = $finalRaw
    FinalNameSafe = $finalSafe
    Namespace     = $finalSafe
    Release       = $finalSafe
  }
}

# -------------------------
# High-level: DB Settings
# Rules:
# - Show defaults; if accepted => use them all
# - If sqlHost/sqlPort not default OR adminUser != default => direct admin password prompt
# - Returns _adminPassword only in memory (caller decides whether to keep it)
# -------------------------
function Read-DbSettings {
  param(
    [hashtable]$Existing = $null,

    [string]$DefaultSqlHost = "mssql.sql-server.svc.cluster.local",
    [int]$DefaultSqlPort = 1433,
    [bool]$DefaultCreateDatabase = $true,

    [string]$DefaultAdminSecretName = "database-sa",
    [string]$DefaultAdminSecretKey  = "SA_PASSWORD",

    [string]$DefaultAdminUser = "SA",

    [string]$DefaultDbAccessSecretName = "db-access"
  )

  if ($null -ne $Existing) { return $Existing }

  $ctxDefault = [ordered]@{
    "SQL Server"       = "${DefaultSqlHost}:$DefaultSqlPort"
    "Admin User"       = "$DefaultAdminUser"
  }

  $sqlHost = $DefaultSqlHost
  $sqlPort = $DefaultSqlPort
  $createDb = $DefaultCreateDatabase
  $adminSecretName = $DefaultAdminSecretName
  $adminSecretKey  = $DefaultAdminSecretKey
  $adminUser = $DefaultAdminUser
  $dbAccessSecretName = $DefaultDbAccessSecretName

  $useDefaults = Read-YesNo `
    -Title "Standardeinstellungen übernehmen?" `
    -DefaultYes $true `
    -ContextTitle "Datenbankeinstellungen" `
    -ContextHint "Wenn 'Nein' ausgewählt wird, folgt die Abfrage der einzelnen Optionen." `
    -ContextCurrent $ctxDefault

  if (-not $useDefaults) {
    $ctx = [ordered]@{}

    $h = Read-Plain "SQL Host (default $DefaultSqlHost)" -ContextTitle "Datenbankeinstellungen" -ContextHint "Werte eingeben (leer = Default)" -ContextCurrent $ctx
    if (-not [string]::IsNullOrWhiteSpace($h)) { $sqlHost = $h }
    $ctx.Add("SQL Host", $sqlHost)

    $p = Read-Plain "SQL Port (default $DefaultSqlPort)" -ContextTitle "Datenbankeinstellungen" -ContextHint "Werte eingeben (leer = Default)" -ContextCurrent $ctx
    if (-not [string]::IsNullOrWhiteSpace($p)) { $sqlPort = [int]$p }
    $ctx.Add("SQL Port", $sqlPort)
    $serverIsDefault = ($sqlHost -eq $DefaultSqlHost -and [int]$sqlPort -eq [int]$DefaultSqlPort)

    # $createDb = Read-YesNo `
    #   -Title "Datenbank erstellen" `
    #   -Message "Datenbank erstellen, falls nicht vorhanden?" `
    #   -DefaultYes $DefaultCreateDatabase `
    #   -ContextTitle "Datenbankeinstellungen" `
    #   -ContextHint "Werte eingeben (leer = Default)" `
    #   -ContextCurrent $ctx
    # $ctx.Add("Datenbank erstellen", $createDb ? "Ja" : "Nein");

    $adminUserIn = Read-Plain "Admin User (default $DefaultAdminUser)" -ContextTitle "Datenbankeinstellungen" -ContextHint "Werte eingeben (leer = Default)" -ContextCurrent $ctx
    if (-not [string]::IsNullOrWhiteSpace($adminUserIn)) { $adminUser = $adminUserIn }
    $ctx.add("Admin User", $adminUser)
    $adminUserIsDefault = ($adminUser -eq $DefaultAdminUser)

    # if ($serverIsDefault -and $adminUserIsDefault) {
    #   $adminSecretNameIn = Read-Plain "SA Secret Name (default $DefaultAdminSecretName)" -ContextTitle "Datenbankeinstellungen" -ContextHint "Werte eingeben (leer = Default)" -ContextCurrent $ctx
    #   if (-not [string]::IsNullOrWhiteSpace($adminSecretNameIn)) { $adminSecretName = $adminSecretNameIn }
    #   $ctx.add("SA Secret Name", $adminSecretName)

    #   $adminSecretKeyIn = Read-Plain "SA Secret Key (default $DefaultAdminSecretKey)" -ContextTitle "Datenbankeinstellungen" -ContextHint "Werte eingeben (leer = Default)" -ContextCurrent $ctx
    #   if (-not [string]::IsNullOrWhiteSpace($adminSecretKeyIn)) { $adminSecretKey = $adminSecretKeyIn }
    #   $ctx.add("SA Secret Key", $adminSecretKey)
    # }
    
    # $dbAccessSecretNameIn = Read-Plain "DB Access Secret Name (default $DefaultDbAccessSecretName)" -ContextTitle "Datenbankeinstellungen" -ContextHint "Werte eingeben (leer = Default)" -ContextCurrent $ctx
    # if (-not [string]::IsNullOrWhiteSpace($dbAccessSecretNameIn)) { $dbAccessSecretName = $dbAccessSecretNameIn }
    # $ctx.add("DB Access Secret Name", $dbAccessSecretName)
  } else {
    $serverIsDefault = $true
    $adminUserIsDefault = $true
  }

  $adminAuthMode = "secret"
  $adminPassword = ""

  if (-not $serverIsDefault -or -not $adminUserIsDefault) {
    $adminAuthMode = "direct"
    $adminPassword = Read-SecretPlain -Prompt "Passwort für $adminUser (verdeckt)"
      -ContextTitle "Datenbankeinstellungen" -ContextHint "Es wurden nicht Standardserver und -benutzer verwendet -> Admin Passwort direkt eingeben" -ContextCurrent $ctx
    if ([string]::IsNullOrWhiteSpace($adminPassword)) { throw "Admin Passwort darf nicht leer sein (direct auth)" }
  }

  return @{
    sql = @{
      host = $sqlHost
      port = [int]$sqlPort
      adminUser = $adminUser
      adminAuth = @{
        mode = $adminAuthMode
        secretName = $adminSecretName
        secretKey  = $adminSecretKey
      }
    }
    createDatabase = [bool]$createDb
    dbAccessSecret = @{
      name = $dbAccessSecretName
    }
    _adminPassword = $adminPassword
  }
}

# -------------------------
# ClusterSecret — platform-agnostic dispatcher that writes secrets to the
# appropriate backend (OpenBao for RKE2/Kind, Azure Key Vault for AKS, etc.)
# and ensures a ClusterSecretStore named 'cluster-secrets' is the target.
# Returns $true on success, $false if no secrets backend is configured.
# -------------------------
function Write-ClusterSecret {
    param(
        [string]$Path,
        [hashtable]$Data,
        [string]$BaseDir  = $script:InstallerBaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "Write-ClusterSecret: -Platform ist erforderlich. Bitte Connect-Cluster aufrufen oder -Platform explizit übergeben."
            return $false
        }
    }

    $frames = @('|','/','-','\'); $fi = 0
    [Console]::Write("`r  $($frames[$fi++ % 4]) Schreibe Secret '$Path' in Vault...")

    $result = switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            Write-OpenBaoSecret -Path $Path -Data $Data -BaseDir $BaseDir
        }
        "Azure AKS" {
            Write-AzureKeyVaultSecret -Path $Path -Data $Data -BaseDir $BaseDir
        }
        "AWS EKS" {
            Write-AwsSecretsManagerSecret -Path $Path -Data $Data -BaseDir $BaseDir
        }
        "Google GKE" {
            Write-GcpSecretManagerSecret -Path $Path -Data $Data -BaseDir $BaseDir
        }
        default { $false }
    }

    if ($result) {
        Write-Host ("`r  ✓ Secret '$Path' in Vault gespeichert" + (" " * 10)) -ForegroundColor Green
    } else {
        [Console]::Write("`r" + (" " * 60) + "`r")
    }
    return $result
}

# -------------------------
# OpenBao — writes key/value pairs to OpenBao KV-v2 at the given path.
# Returns $true on success, $false if OpenBao is not installed or not ready.
# Callers fall back to direct Helm --set when $false is returned.
# -------------------------
function Write-OpenBaoSecret {
    param(
        [string]$Path,
        [hashtable]$Data,
        [string]$BaseDir = $script:InstallerBaseDir
    )

    $stateFile = Join-Path $BaseDir ".openbao-state.json"
    if (-not (Test-Path $stateFile)) { return $false }

    $rootToken = (Get-Content $stateFile | ConvertFrom-Json).RootToken
    if (-not $rootToken) { return $false }

    $podStatus = & kubectl get pod openbao-0 -n openbao `
        --no-headers -o custom-columns="S:.status.phase" 2>$null
    if ($podStatus -ne "Running") { return $false }

    $kvData  = ($Data.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " "
    & kubectl exec openbao-0 -n openbao -- `
        sh -c "BAO_TOKEN=$rootToken bao kv put secret/$Path $kvData" 2>$null | Out-Null

    return $LASTEXITCODE -eq 0
}

# -------------------------
# ClusterContext — sets kubectl context from the appropriate state file.
# Platform is ALWAYS required — no auto-detection from state files.
# Called from Install-Base.ps1 and every standalone component script.
# -------------------------
function Set-ClusterContext {
    param(
        [string]$BaseDir,
        [Parameter(Mandatory)][string]$Platform
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        Write-Error "Set-ClusterContext: -Platform ist erforderlich. Keine automatische Erkennung aus State-Files."
        return
    }

    $contextKey = "$Platform|$BaseDir"
    $alreadySet = $env:INSTALLER_LAST_CONTEXT -eq $contextKey

    $kubeDir = Join-Path $env:USERPROFILE ".kube"
    if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Path $kubeDir -Force | Out-Null }

    switch ($Platform) {
        "RKE2 (On-Premise)" {
            $s = Get-Content (Join-Path $BaseDir ".rke2-state.json") | ConvertFrom-Json
            $env:KUBECONFIG = $s.KubeconfigPath -replace '^~', $env:USERPROFILE
            if (-not $alreadySet) { Write-Host "  Cluster: $($s.SshServer)  [RKE2]" -ForegroundColor DarkGray }
        }
        "Azure AKS" {
            $s        = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
            $kubefile = Join-Path $kubeDir "aks-$($s.ClusterName).yaml"
            if (-not $alreadySet) {
                & az account set --subscription $s.SubscriptionId 2>$null | Out-Null
                & az aks get-credentials --resource-group $s.ResourceGroup `
                    --name $s.ClusterName --overwrite-existing --file $kubefile 2>$null | Out-Null
            }
            $env:KUBECONFIG = $kubefile
            & kubectl config use-context $s.ClusterName 2>$null | Out-Null
            if (-not $alreadySet) { Write-Host "  Cluster: $($s.ClusterName)  ($($s.ResourceGroup) · $($s.Location))  [AKS]" -ForegroundColor DarkGray }
        }
        "AWS EKS" {
            $s        = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
            $kubefile = Join-Path $kubeDir "eks-$($s.ClusterName).yaml"
            if (-not $alreadySet) {
                & aws eks update-kubeconfig --region $s.Region --name $s.ClusterName --kubeconfig $kubefile 2>$null | Out-Null
            }
            $env:KUBECONFIG = $kubefile
            $eksCtx = & kubectl config get-contexts --output name 2>$null | Where-Object { $_ -like "*$($s.ClusterName)*" } | Select-Object -First 1
            if ($eksCtx) { & kubectl config use-context $eksCtx 2>$null | Out-Null }
            if (-not $alreadySet) { Write-Host "  Cluster: $($s.ClusterName)  ($($s.Region))  [EKS]" -ForegroundColor DarkGray }
        }
        "Google GKE" {
            $s        = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
            $kubefile = Join-Path $kubeDir "gke-$($s.ClusterName).yaml"
            if (-not $alreadySet) {
                $env:KUBECONFIG = $kubefile
                & gcloud container clusters get-credentials $s.ClusterName `
                    --zone $s.Zone --project $s.ProjectId 2>$null | Out-Null
            }
            $env:KUBECONFIG = $kubefile
            & kubectl config use-context $s.ClusterName 2>$null | Out-Null
            if (-not $alreadySet) { Write-Host "  Cluster: $($s.ClusterName)  ($($s.Zone))  [GKE]" -ForegroundColor DarkGray }
        }
        "Kind (Local)" {
            $kindState = Join-Path $BaseDir ".kind-state.json"
            if (Test-Path $kindState) {
                $s        = Get-Content $kindState | ConvertFrom-Json
                $kubefile = Join-Path $kubeDir "kind-$($s.ClusterName).yaml"
                if (-not $alreadySet) {
                    $kindExe = Join-Path $BaseDir ".tools\kind.exe"
                    if (Test-Path $kindExe) {
                        & $kindExe export kubeconfig --name $s.ClusterName --kubeconfig $kubefile 2>$null | Out-Null
                    }
                }
                $env:KUBECONFIG = $kubefile
                & kubectl config use-context "kind-$($s.ClusterName)" 2>$null | Out-Null
                if (-not $alreadySet) { Write-Host "  Cluster: $($s.ClusterName)  [Kind]" -ForegroundColor DarkGray }
            }
        }
    }
    $env:INSTALLER_LAST_CONTEXT = $contextKey
}

# -------------------------
# Azure Key Vault — writes each key as a separate secret named "$Path-$key".
# Separate secrets avoid jmesPath dependency and mount cleanly as individual files.
# Uses 'az keyvault secret set' — requires az CLI authenticated and Key Vault state file.
# -------------------------
function Write-AzureKeyVaultSecret {
    param([string]$Path, [hashtable]$Data, [string]$BaseDir = $script:InstallerBaseDir)

    $stateFile = Join-Path $BaseDir ".aks-state.json"
    if (-not (Test-Path $stateFile)) { return $false }

    $vaultName = (Get-Content $stateFile | ConvertFrom-Json).VaultName
    if (-not $vaultName) { return $false }

    # Azure RBAC can take 1-2 minutes to propagate — retry with increasing delays.
    $frames = @('|','/','-','\'); $fi = 0
    $delays = @(0, 30, 60)

    foreach ($entry in $Data.GetEnumerator()) {
        $secretName = if ($Data.Count -eq 1) { $Path } else { "$Path-$($entry.Key)" }
        $tmpFile = New-TemporaryFile
        Set-Content -Path $tmpFile.FullName -Value $entry.Value -Encoding UTF8 -NoNewline
        $written = $false
        foreach ($delay in $delays) {
            if ($delay -gt 0) {
                for ($i = 0; $i -lt $delay; $i++) {
                    [Console]::Write("`r  $($frames[$fi++ % 4]) Warte auf RBAC-Propagation... (${i}s)")
                    Start-Sleep -Seconds 1
                }
            }
            & az keyvault secret set --vault-name $vaultName --name $secretName --file $tmpFile.FullName --encoding utf-8 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $written = $true; break }
        }
        Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
        if (-not $written) { return $false }
    }
    return $true
}

# -------------------------
# AWS Secrets Manager — writes each key as a separate secret named "$Path-$key".
# Requires aws CLI configured and .eks-state.json with Region.
# -------------------------
function Write-AwsSecretsManagerSecret {
    param([string]$Path, [hashtable]$Data, [string]$BaseDir = $script:InstallerBaseDir)

    $stateFile = Join-Path $BaseDir ".eks-state.json"
    if (-not (Test-Path $stateFile)) { return $false }

    $region = (Get-Content $stateFile | ConvertFrom-Json).Region
    if (-not $region) { return $false }

    foreach ($entry in $Data.GetEnumerator()) {
        $secretName = if ($Data.Count -eq 1) { $Path } else { "$Path-$($entry.Key)" }

        & aws secretsmanager describe-secret --secret-id $secretName --region $region 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & aws secretsmanager create-secret --name $secretName --region $region `
                --secret-string $entry.Value 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { return $false }
        } else {
            & aws secretsmanager put-secret-value --secret-id $secretName --region $region `
                --secret-string $entry.Value 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { return $false }
        }
    }
    return $true
}

# -------------------------
# GCP Secret Manager — writes each key as a separate secret named "$Path-$key".
# Requires gcloud CLI authenticated and .gke-state.json with ProjectId.
# -------------------------
function Write-GcpSecretManagerSecret {
    param([string]$Path, [hashtable]$Data, [string]$BaseDir = $script:InstallerBaseDir)

    $stateFile = Join-Path $BaseDir ".gke-state.json"
    if (-not (Test-Path $stateFile)) { return $false }

    $projectId = (Get-Content $stateFile | ConvertFrom-Json).ProjectId
    if (-not $projectId) { return $false }

    foreach ($entry in $Data.GetEnumerator()) {
        $secretName = if ($Data.Count -eq 1) { $Path } else { "$Path-$($entry.Key)" }

        $exists = & gcloud secrets describe $secretName --project $projectId 2>$null
        if (-not $exists) {
            & gcloud secrets create $secretName --project $projectId --replication-policy automatic 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { return $false }
        }

        $tmpFile = New-TemporaryFile
        Set-Content -Path $tmpFile.FullName -Value $entry.Value -Encoding UTF8 -NoNewline
        & gcloud secrets versions add $secretName --project $projectId --data-file $tmpFile.FullName 2>$null | Out-Null
        Remove-Item $tmpFile.FullName -Force -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) { return $false }
    }
    return $true
}

# -------------------------
# New-CsiSecretMount — platform-agnostic helper that an app installer calls once.
# Handles:
#   - Workload Identity binding (AKS: Federated Credential, GKE: IAM, OpenBao: Vault role)
#   - SecretProviderClass YAML generation (platform-specific, internal)
#   - CSI Helm args (same for all platforms)
#
# Returns a hashtable:
#   Installed  = $true/$false (whether a secrets backend is configured)
#   SpcYaml    = string to pipe to 'kubectl apply -f -'
#   HelmArgs   = array to append to HelmArgs
#   SpcName    = name of the SecretProviderClass
#   MountPath  = mount path inside the pod
# -------------------------
function New-CsiSecretMount {
    param(
        [string]$AppName,
        [string]$VaultPath,
        [string[]]$Keys,
        [string]$Namespace,
        [string]$ServiceAccount,
        [string]$MountPath  = "/mnt/secrets",
        [string]$BaseDir    = $script:InstallerBaseDir,
        [string]$Platform   = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        $Platform = $script:InstallerPlatform
        if (-not $Platform) {
            Write-Error "New-CsiSecretMount: -Platform ist erforderlich. Bitte Connect-Cluster aufrufen oder -Platform explizit übergeben."
            return @{ Installed = $false; SpcYaml = ""; HelmArgs = @(); SpcName = ""; MountPath = $MountPath }
        }
    }

    $notInstalled = @{ Installed = $false; SpcYaml = ""; HelmArgs = @(); SpcName = ""; MountPath = $MountPath }
    $spcName = "$AppName-vault"

    # ── Platform-specific auth setup + SPC YAML ──────────────────
    $spcYaml = switch ($Platform) {
        { $_ -in @("RKE2 (On-Premise)", "Kind (Local)") } {
            if (-not (Test-Path (Join-Path $BaseDir ".openbao-state.json"))) { return $notInstalled }
            $baoState  = Get-Content (Join-Path $BaseDir ".openbao-state.json") | ConvertFrom-Json
            $rootToken = $baoState.RootToken

            # Vault Kubernetes auth role — single line to avoid shell backtick/continuation issues
            $baoCmd = "BAO_TOKEN=$rootToken bao write auth/kubernetes/role/$AppName bound_service_account_names='$ServiceAccount' bound_service_account_namespaces='$Namespace' policies='csi-readonly' ttl='1h'"
            & kubectl exec openbao-0 -n openbao -- sh -c $baoCmd 2>$null | Out-Null

            $objects = ($Keys | ForEach-Object { @"
      - objectName: "$_"
        secretPath: "secret/data/$VaultPath"
        secretKey: "$_"
"@ }) -join "`n"
@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: $spcName
  namespace: $Namespace
spec:
  provider: vault
  parameters:
    vaultAddress: "http://openbao.openbao.svc.cluster.local:8200"
    roleName: "$AppName"
    objects: |
$objects
"@
        }

        "Azure AKS" {
            $aksState = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
            if (-not $aksState.VaultName) { return $notInstalled }
            $tenantId = & az account show --query tenantId --output tsv 2>$null
            if ($tenantId) { $tenantId = $tenantId.Trim() }

            # Federated Credential
            $fedName   = "$AppName-csi"
            $fedExists = & az identity federated-credential show `
                --name $fedName --identity-name $aksState.MiName `
                --resource-group $aksState.ResourceGroup 2>$null
            if (-not $fedExists) {
                & az identity federated-credential create `
                    --name $fedName `
                    --identity-name $aksState.MiName `
                    --resource-group $aksState.ResourceGroup `
                    --issuer $aksState.OidcIssuer `
                    --subject "system:serviceaccount:${Namespace}:${ServiceAccount}" `
                    --audience "api://AzureADTokenExchange" 2>$null | Out-Null
            }

            $objects = if ($Keys.Count -eq 1) {
@"
      array:
        - |
          objectName: $VaultPath
          objectType: secret
          objectAlias: $($Keys[0])
"@
            } else {
                ($Keys | ForEach-Object { @"
      array:
        - |
          objectName: $VaultPath-$_
          objectType: secret
          objectAlias: $_
"@ }) -join "`n"
            }
@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: $spcName
  namespace: $Namespace
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    clientID: "$($aksState.MiClientId)"
    keyvaultName: "$($aksState.VaultName)"
    tenantId: "$tenantId"
    objects: |
$objects
"@
        }

        "AWS EKS" {
            $eksState = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
            if (-not $eksState.CsiRoleArn) { return $notInstalled }

            # IRSA annotation — pod SA gets role via annotation, no per-app binding needed
            $objects = ($Keys | ForEach-Object { @"
      - objectName: "$_"
        objectType: "secretsmanager"
        objectAlias: "$_"
"@ }) -join "`n"
@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: $spcName
  namespace: $Namespace
spec:
  provider: aws
  parameters:
    objects: |
$objects
"@
        }

        "Google GKE" {
            $gkeState = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
            if (-not $gkeState.CsiGsaEmail) { return $notInstalled }

            # Workload Identity IAM binding
            & gcloud iam service-accounts add-iam-policy-binding $gkeState.CsiGsaEmail `
                --project $gkeState.ProjectId `
                --role "roles/iam.workloadIdentityUser" `
                --member "serviceAccount:$($gkeState.ProjectId).svc.id.goog[$Namespace/$ServiceAccount]" 2>$null | Out-Null

            $secrets = ($Keys | ForEach-Object { @"
      - resourceName: "projects/$($gkeState.ProjectId)/secrets/$VaultPath/versions/latest"
        fileName: "$_"
"@ }) -join "`n"
@"
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: $spcName
  namespace: $Namespace
spec:
  provider: gcp
  parameters:
    secrets: |
$secrets
"@
        }

        default { return $notInstalled }
    }

    # ── CSI Helm args — identical for all platforms ───────────────
    $helmArgs = @(
        "--set", "extraVolumes[0].name=vault-secrets",
        "--set", "extraVolumes[0].csi.driver=secrets-store.csi.k8s.io",
        "--set", "extraVolumes[0].csi.readOnly=true",
        "--set", "extraVolumes[0].csi.volumeAttributes.secretProviderClass=$spcName",
        "--set", "extraVolumeMounts[0].name=vault-secrets",
        "--set", "extraVolumeMounts[0].mountPath=$MountPath",
        "--set", "extraVolumeMounts[0].readOnly=true"
    )

    # Platform-specific pod identity labels/annotations
    if ($Platform -eq "Azure AKS") {
        $aksState = Get-Content (Join-Path $BaseDir ".aks-state.json") | ConvertFrom-Json
        $helmArgs += "--set",        "serviceAccount.annotations.azure\.workload\.identity/client-id=$($aksState.MiClientId)"
        $helmArgs += "--set-string", "podLabels.azure\.workload\.identity/use=true"
    }
    if ($Platform -eq "AWS EKS") {
        $eksState = Get-Content (Join-Path $BaseDir ".eks-state.json") | ConvertFrom-Json
        $helmArgs += "--set", "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$($eksState.CsiRoleArn)"
    }
    if ($Platform -eq "Google GKE") {
        $gkeState = Get-Content (Join-Path $BaseDir ".gke-state.json") | ConvertFrom-Json
        $helmArgs += "--set", "serviceAccount.annotations.iam\.gke\.io/gcp-service-account=$($gkeState.CsiGsaEmail)"
    }

    return @{
        Installed = $true
        SpcYaml   = $spcYaml
        HelmArgs  = $helmArgs
        SpcName   = $spcName
        MountPath = $MountPath
    }
}

# -------------------------
# ExternalSecret data section — returns platform-specific YAML fragment for
# the 'data:' section of an ExternalSecret, matching the storage format of
# each backend (OpenBao: JSON blob with property, AKV: separate secrets).
# -------------------------
function Get-ExternalSecretData {
    param(
        [string]$Path,
        [string[]]$Keys,
        [string]$BaseDir,
        [string]$Platform = ""
    )

    if ([string]::IsNullOrWhiteSpace($Platform)) {
        if (Test-Path (Join-Path $BaseDir ".openbao-state.json"))       { $Platform = "RKE2 (On-Premise)" }
        elseif (Test-Path (Join-Path $BaseDir ".aks-keyvault-state.json")) { $Platform = "Azure AKS" }
    }

    $lines = @()
    foreach ($key in $Keys) {
        $lines += "  - secretKey: $key"
        $lines += "    remoteRef:"
        $lines += "      key: $Path"
        $lines += "      property: $key"
    }
    return $lines -join "`n"
}

# -------------------------
# IngressClass — returns the active IngressClass name from the cluster.
# Prefers the class annotated as default; falls back to first available; then "nginx".
# -------------------------
function Get-IngressClass {
    $default = & kubectl get ingressclass `
        -o jsonpath='{.items[?(@.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' `
        2>$null
    if ($default) { return $default.Trim() }

    $first = & kubectl get ingressclass -o jsonpath='{.items[0].metadata.name}' 2>$null
    if ($first) { return $first.Trim() }

    return "nginx"
}

# -------------------------
# kubectl discovery cache — clears the local cache so newly installed CRDs
# (e.g. ESO, cert-manager) are visible to kubectl apply without a 10-min wait.
# Suppresses Write-Progress to avoid console noise from Remove-Item -Recurse.
# -------------------------
function Clear-KubectlDiscoveryCache {
    $cacheDir = Join-Path $env:USERPROFILE ".kube\cache\discovery"
    if (-not (Test-Path $cacheDir)) { return }
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    Remove-Item $cacheDir -Recurse -Force -ErrorAction SilentlyContinue
    $ProgressPreference = $prev
}

# -------------------------
# Spinner — runs an executable in a background job and animates while waiting.
# KUBECONFIG is explicitly forwarded to the job so standalone script execution works.
# Returns the exit code of the process.
# -------------------------
function Invoke-WithSpinner {
  [CmdletBinding()]
  param(
    [string]$Message,
    [string]$Executable,
    [string[]]$Arguments = @(),
    [switch]$ShowOutput,
    [hashtable]$EnvVars = @{},
    $OutputVariable = $null
  )

  $argsEncoded       = $Arguments -join "`0"
  $currentPath       = $env:PATH
  $currentKubeconfig = $env:KUBECONFIG

  $job = Start-Job -ScriptBlock {
    param($exe, $argsEncoded, $path, $envVars, $kubeconfig)
    $env:PATH = $path
    if ($kubeconfig) { $env:KUBECONFIG = $kubeconfig }
    foreach ($k in $envVars.Keys) { Set-Item "env:$k" $envVars[$k] }
    $argList = if ($argsEncoded) { $argsEncoded -split "`0" } else { @() }
    $out = & $exe @argList 2>&1
    [PSCustomObject]@{ Output = $out; ExitCode = $LASTEXITCODE }
  } -ArgumentList $Executable, $argsEncoded, $currentPath, $EnvVars, $currentKubeconfig

  $frames = @('|', '/', '-', '\')
  $i = 0
  try {
    while ($job.State -eq 'Running') {
      [Console]::Write("`r  $($frames[$i % 4]) $Message")
      $i++
      Start-Sleep -Milliseconds 150
    }
  } finally {
    if ($job.State -eq 'Running') { Stop-Job -Job $job }
    [Console]::Write("`r" + (" " * ($Message.Length + 6)) + "`r")
  }

  $result = Receive-Job -Job $job -Wait
  Remove-Job -Job $job -Force

  if ($null -ne $result.Output) {
    if ($null -ne $OutputVariable -and $OutputVariable -is [ref]) { $OutputVariable.Value = $result.Output }
    $isError = $result.ExitCode -ne 0
    if ($isError -or $ShowOutput) {
      $color = if ($isError) { "Red" } else { "Gray" }
      foreach ($line in $result.Output) { if ($line) { Write-Host $line -ForegroundColor $color } }
    }
  }

  return [int]$result.ExitCode
}

# -------------------------
# Config loading with platform overrides
# -------------------------
function Merge-Config {
    param([hashtable]$Base, [hashtable]$Override)
    $result = @{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    foreach ($key in $Override.Keys) {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $result[$key] = Merge-Config -Base $result[$key] -Override $Override[$key]
        } else {
            $result[$key] = $Override[$key]
        }
    }
    return $result
}

function Get-ComponentConfig {
    param(
        [string]$ScriptRoot,
        [string]$Platform = "",
        [string]$ConfigPath = ""
    )
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        return Import-PowerShellDataFile -Path $ConfigPath
    }

    $config = Import-PowerShellDataFile -Path (Join-Path $ScriptRoot "Config.psd1")

    $platformShort = switch ($Platform) {
        "Azure AKS"         { "AzureAKS" }
        "AWS EKS"           { "AWSEKS" }
        "Google GKE"        { "GoogleGKE" }
        "RKE2 (On-Premise)" { "RKE2" }
        "Kind (Local)"      { "Kind" }
        default             { "" }
    }

    if ($platformShort) {
        $overridePath = Join-Path $ScriptRoot "Config.$platformShort.psd1"
        if (Test-Path $overridePath) {
            $override = Import-PowerShellDataFile -Path $overridePath
            $config = Merge-Config -Base $config -Override $override
        }
    }

    return $config
}

# -------------------------
# Export (single variant, robust)
# -------------------------
$__exportFunctions = @(
  'Test-CommandExists'
  'ToSafeName'
  'Write-Context'
  'Write-Section'
  'Read-SelectIndex'
  'Read-SelectValue'
  'Read-YesNo'
  'Read-MultiSelectValues'
  'Read-Plain'
  'Read-SecretPlain'
  'Read-SecretPlainConfirm'
  'Read-InstallIdentity'
  'Read-DbSettings'
  'ConvertTo-UiOptions'
  'Invoke-WithSpinner'
  'Get-ComponentConfig'
  'Merge-Config'
  'Get-IngressClass'
  'Write-OpenBaoSecret'
  'Set-ClusterContext'
  'Clear-KubectlDiscoveryCache'
  'Write-ClusterSecret'
  'Write-AzureKeyVaultSecret'
  'Write-AwsSecretsManagerSecret'
  'Write-GcpSecretManagerSecret'
  'New-CsiSecretMount'
  'Connect-Cluster'
  'Get-ExternalSecretData'
  'Read-ComponentSelectionScreen'
)

Export-ModuleMember -Function $__exportFunctions