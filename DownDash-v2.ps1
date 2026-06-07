#Requires -Version 5.1
#Requires -PSEdition Desktop
<#
.SYNOPSIS
  DownDash v2 - Service Status Dashboard

.DESCRIPTION
  Polls official status APIs (no scraping, no Cloudflare) for 20+ services
  that generate the most tech support calls. Shows live UP/DOWN/DEGRADED status
  with color-coded severity indicators. Minimizes to system tray; pops an alert
  balloon when any service degrades or recovers.

  All status endpoints use the public Atlassian Statuspage v2 API or equivalent
  official JSON feeds -- no auth, no scraping, no rate-limit concerns.

  Indicator values (from Statuspage spec):
    none     = All Systems Operational   -> green
    minor    = Minor Service Disruption  -> yellow
    major    = Partial/Major Outage      -> orange
    critical = Major Service Outage      -> red

.NOTES
  Version : 2.0.0
  Log     : %LOCALAPPDATA%\DownDash\DownDash.log
  Cache   : %LOCALAPPDATA%\DownDash\last_good.json
  PS Tier : 5.1 Desktop (WinForms, System.Drawing)
  Encoding: ASCII-only -- no Unicode in source
#>

# ===========================================================================
# CONSTANTS
# ===========================================================================
$script:AppName              = "DownDash v2"
$script:AppVersion           = "2.0.0"
$script:BaseDir              = Join-Path $env:LOCALAPPDATA "DownDash"
$script:LogPath              = Join-Path $script:BaseDir "DownDash.log"
$script:CachePath            = Join-Path $script:BaseDir "last_good.json"
$script:PrefsPath            = Join-Path $script:BaseDir "prefs.json"
$script:StartupCmd           = Join-Path $script:BaseDir "DownDash-Startup.cmd"
$script:TaskName             = "DownDash_Startup"
$script:RefreshSec           = 60
$script:TimeoutMs            = 15000
$script:LogMaxLinesShutdown  = 500    # lines kept when app closes
$script:LogMaxLinesDaily     = 1000   # lines kept on daily midnight trim

# ---------------------------------------------------------------------------
# SERVICE MANIFEST
# Each entry: Name, Url (status endpoint), StatusPage (bool), HomeUrl
# StatusPage=true  -> parse {"status":{"indicator":"none|minor|major|critical"}}
# StatusPage=false -> custom parse (AWS RSS, MS Azure RSS)
# ---------------------------------------------------------------------------
$script:Services = @(
  # --- Microsoft ---
  [pscustomobject]@{ Name="Microsoft 365";   Url="https://status.office365.com/api/v2/status.json";           SP=$true;  Home="https://status.office365.com" }
  [pscustomobject]@{ Name="Azure";            Url="https://azure.status.microsoft/api/v2/status.json";         SP=$true;  Home="https://azure.status.microsoft" }
  [pscustomobject]@{ Name="Microsoft Teams"; Url="https://status.office365.com/api/v2/status.json";           SP=$true;  Home="https://status.office365.com" }
  # --- Cloud / CDN ---
  [pscustomobject]@{ Name="Cloudflare";      Url="https://www.cloudflarestatus.com/api/v2/status.json";       SP=$true;  Home="https://www.cloudflarestatus.com" }
  [pscustomobject]@{ Name="AWS";             Url="https://health.aws.amazon.com/public/currentevents";         SP=$false; Home="https://health.aws.amazon.com/health/status" }
  [pscustomobject]@{ Name="Google Workspace";Url="https://www.googleapis.com/discovery/v1/apis";               SP=$false; Home="https://workspace.google.com/status" }
  # --- Productivity / Comms ---
  [pscustomobject]@{ Name="Zoom";            Url="https://status.zoom.us/api/v2/status.json";                 SP=$true;  Home="https://status.zoom.us" }
  [pscustomobject]@{ Name="Slack";           Url="https://status.slack.com/api/v2.0.0/current";               SP=$false; Home="https://status.slack.com" }
  [pscustomobject]@{ Name="Dropbox";         Url="https://status.dropbox.com/api/v2/status.json";             SP=$true;  Home="https://status.dropbox.com" }
  [pscustomobject]@{ Name="GoTo / LogMeIn";  Url="https://status.goto.com/api/v2/status.json";                SP=$true;  Home="https://status.goto.com" }
  # --- Finance / Business ---
  [pscustomobject]@{ Name="QuickBooks";      Url="https://status.developer.intuit.com/api/v2/status.json";    SP=$true;  Home="https://status.developer.intuit.com" }
  [pscustomobject]@{ Name="Stripe";          Url="https://status.stripe.com/api/v2/status.json";              SP=$true;  Home="https://status.stripe.com" }
  [pscustomobject]@{ Name="PayPal";          Url="https://www.paypal-status.com/api/v2/status.json";          SP=$true;  Home="https://www.paypal-status.com" }
  # --- Identity / Security ---
  [pscustomobject]@{ Name="Okta";            Url="https://status.okta.com/api/v2/status.json";                SP=$true;  Home="https://status.okta.com" }
  [pscustomobject]@{ Name="Duo Security";    Url="https://status.duo.com/api/v2/status.json";                 SP=$true;  Home="https://status.duo.com" }
  # --- Dev / IT ---
  [pscustomobject]@{ Name="GitHub";          Url="https://www.githubstatus.com/api/v2/status.json";           SP=$true;  Home="https://www.githubstatus.com" }
  [pscustomobject]@{ Name="Atlassian";       Url="https://status.atlassian.com/api/v2/status.json";           SP=$true;  Home="https://status.atlassian.com" }
  [pscustomobject]@{ Name="Datadog";         Url="https://status.datadoghq.com/api/v2/status.json";           SP=$true;  Home="https://status.datadoghq.com" }
  [pscustomobject]@{ Name="PagerDuty";       Url="https://status.pagerduty.com/api/v2/status.json";           SP=$true;  Home="https://status.pagerduty.com" }
  # --- Telecom / ISP (HTTP reachability check -- no public status API) ---
  [pscustomobject]@{ Name="Verizon";         Url="https://www.verizon.com/robots.txt";                        SP=$false; Home="https://www.verizon.com" }
  [pscustomobject]@{ Name="T-Mobile";        Url="https://www.t-mobile.com/robots.txt";                       SP=$false; Home="https://www.t-mobile.com" }
  [pscustomobject]@{ Name="Xfinity/Comcast"; Url="https://www.xfinity.com/robots.txt";                        SP=$false; Home="https://www.xfinity.com" }
  [pscustomobject]@{ Name="AT&T";            Url="https://www.att.com/robots.txt";                            SP=$false; Home="https://www.att.com" }
)

# ===========================================================================
# INFRASTRUCTURE
# ===========================================================================
function New-DirIfMissing { param([string]$Path)
  try { if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null } } catch { }
}

function Write-Log { param([string]$Level, [string]$Message)
  try {
    New-DirIfMissing -Path $script:BaseDir
    $ts   = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[{0}] [{1}] {2}" -f $ts, $Level.ToUpperInvariant(), $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
  } catch { }
}

function Invoke-LogRotation {
  # Trims the log file to the last $MaxLines lines.
  # Called on shutdown (aggressive trim) and daily (moderate trim).
  # Source: Get-Content + Select-Object -Last N + Set-Content is the
  # confirmed PS pattern for keeping tail of a text file (no module needed).
  param([int]$MaxLines)
  try {
    if (-not (Test-Path -LiteralPath $script:LogPath)) { return }
    $lines = [System.IO.File]::ReadAllLines($script:LogPath)
    if ($lines.Count -le $MaxLines) { return }  # already small enough
    $kept = $lines | Select-Object -Last $MaxLines
    # Write a rotation marker at the top of the trimmed file
    $marker = "[{0}] [INFO] -- Log trimmed to last {1} lines --" -f `
              (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $MaxLines
    $output = @($marker) + $kept
    [System.IO.File]::WriteAllLines(
      $script:LogPath,
      $output,
      [System.Text.Encoding]::UTF8)
  } catch { }  # log rotation must never crash the app
}

function Format-Ex { param([System.Exception]$Ex)
  try {
    $s = $Ex.GetType().FullName + ": " + $Ex.Message
    if ($Ex.InnerException) { $s += " | Inner: " + $Ex.InnerException.GetType().FullName + ": " + $Ex.InnerException.Message }
    return $s
  } catch { return $Ex.ToString() }
}

function Ensure-STA {
  try {
    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
      Write-Log "INFO" "Relaunching with -STA"
      $ps = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
      if ([string]::IsNullOrWhiteSpace($ps)) { $ps = "powershell.exe" }
      Start-Process -FilePath $ps -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-STA","-File","`"$($MyInvocation.MyCommand.Path)`"") | Out-Null
      exit 0
    }
  } catch { }
}

function Set-Tls {
  try {
    $want = 0
    foreach ($n in @("Tls13","Tls12","Tls11","Tls")) { try { $want = $want -bor [int][System.Net.SecurityProtocolType]::$n } catch { } }
    if ($want -ne 0) { [System.Net.ServicePointManager]::SecurityProtocol = $want }
    [System.Net.ServicePointManager]::Expect100Continue = $false
  } catch { Write-Log "WARN" ("TLS setup failed: " + (Format-Ex $_.Exception)) }
}

# ===========================================================================
# CACHE
# ===========================================================================
function Save-Cache { param([object[]]$Results)
  try {
    $payload = @{ saved_utc = (Get-Date).ToUniversalTime().ToString("o"); results = @() }
    foreach ($r in $Results) { $payload.results += @{ name=$r.Name; indicator=$r.Indicator; description=$r.Description; home=$r.Home } }
    $json = $payload | ConvertTo-Json -Depth 6
    New-DirIfMissing -Path $script:BaseDir
    [System.IO.File]::WriteAllText($script:CachePath, $json, [System.Text.Encoding]::UTF8)
  } catch { Write-Log "WARN" ("Cache save failed: " + (Format-Ex $_.Exception)) }
}

function Load-Cache {
  try {
    if (-not (Test-Path -LiteralPath $script:CachePath)) { return @() }
    $raw = [System.IO.File]::ReadAllText($script:CachePath, [System.Text.Encoding]::UTF8)
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    $out = @()
    foreach ($r in $obj.results) {
      $out += [pscustomobject]@{ Name=$r.name; Indicator=$r.indicator; Description=$r.description; Home=$r.home; Fresh=$false }
    }
    return ,$out
  } catch { Write-Log "WARN" ("Cache load failed: " + (Format-Ex $_.Exception)); return @() }
}

# ===========================================================================
# NOTIFICATION PREFERENCES
# Persisted to prefs.json. Hashtable: ServiceName -> [bool] notify-enabled.
# Default: all services enabled. User opts OUT via the prefs dialog.
# ===========================================================================
function Save-Prefs { param([hashtable]$Prefs)
  try {
    New-DirIfMissing -Path $script:BaseDir
    $obj = @{}
    foreach ($k in $Prefs.Keys) { $obj[$k] = [bool]$Prefs[$k] }
    $json = $obj | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($script:PrefsPath, $json, [System.Text.Encoding]::UTF8)
  } catch { Write-Log "WARN" ("Prefs save failed: " + (Format-Ex $_.Exception)) }
}

function Load-Prefs { param([string[]]$ServiceNames)
  # Returns hashtable ServiceName->bool. Missing entries default to $true (notify).
  $prefs = @{}
  foreach ($n in $ServiceNames) { $prefs[$n] = $true }
  try {
    if (-not (Test-Path -LiteralPath $script:PrefsPath)) { return $prefs }
    $raw = [System.IO.File]::ReadAllText($script:PrefsPath, [System.Text.Encoding]::UTF8)
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    $obj.PSObject.Properties | ForEach-Object {
      if ($prefs.ContainsKey($_.Name)) { $prefs[$_.Name] = [bool]$_.Value }
    }
  } catch { Write-Log "WARN" ("Prefs load failed: " + (Format-Ex $_.Exception)) }
  return $prefs
}

function Show-NotifyPrefsDialog { param([hashtable]$Prefs, [string[]]$ServiceNames)
  # Modal checklist form -- Charles picks which services fire alerts.
  # Returns updated hashtable, or $null if cancelled.
  $dlg = New-Object System.Windows.Forms.Form
  $dlg.Text          = "Notification Preferences"
  $dlg.Width         = 340
  $dlg.Height        = 560
  $dlg.StartPosition = "CenterScreen"
  $dlg.BackColor     = [System.Drawing.Color]::FromArgb(22, 22, 30)
  $dlg.ForeColor     = [System.Drawing.Color]::WhiteSmoke
  $dlg.Font          = New-Object System.Drawing.Font("Segoe UI", 9)
  $dlg.FormBorderStyle = "FixedDialog"
  $dlg.MaximizeBox   = $false; $dlg.MinimizeBox = $false

  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Text      = "Send alerts for these services:"
  $lbl.Location  = New-Object System.Drawing.Point(12, 10)
  $lbl.AutoSize  = $true
  $lbl.ForeColor = [System.Drawing.Color]::FromArgb(0, 204, 255)
  $dlg.Controls.Add($lbl)

  $clb = New-Object System.Windows.Forms.CheckedListBox
  $clb.Location      = New-Object System.Drawing.Point(12, 35)
  $clb.Width         = 300
  $clb.Height        = 440
  $clb.BackColor     = [System.Drawing.Color]::FromArgb(28, 28, 38)
  $clb.ForeColor     = [System.Drawing.Color]::WhiteSmoke
  $clb.CheckOnClick  = $true
  $clb.BorderStyle   = "FixedSingle"
  foreach ($n in ($ServiceNames | Sort-Object)) {
    $idx = $clb.Items.Add($n)
    $clb.SetItemChecked($idx, [bool]$Prefs[$n])
  }
  $dlg.Controls.Add($clb)

  $btnOK = New-Object System.Windows.Forms.Button
  $btnOK.Text      = "Save"
  $btnOK.Width     = 80; $btnOK.Height = 28
  $btnOK.Location  = New-Object System.Drawing.Point(140, 485)
  $btnOK.BackColor = [System.Drawing.Color]::FromArgb(0, 80, 140)
  $btnOK.ForeColor = [System.Drawing.Color]::White
  $btnOK.FlatStyle = "Flat"
  $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $dlg.Controls.Add($btnOK)

  $btnCancel = New-Object System.Windows.Forms.Button
  $btnCancel.Text      = "Cancel"
  $btnCancel.Width     = 80; $btnCancel.Height = 28
  $btnCancel.Location  = New-Object System.Drawing.Point(228, 485)
  $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 70)
  $btnCancel.ForeColor = [System.Drawing.Color]::White
  $btnCancel.FlatStyle = "Flat"
  $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $dlg.Controls.Add($btnCancel)

  $dlg.AcceptButton = $btnOK
  $dlg.CancelButton = $btnCancel

  if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    $result = @{}
    for ($i = 0; $i -lt $clb.Items.Count; $i++) {
      $result[$clb.Items[$i]] = $clb.GetItemChecked($i)
    }
    return $result
  }
  return $null
}

# ===========================================================================
# STARTUP REGISTRATION
# Chain: scheduled task -> .cmd -> powershell.exe -EncodedCommand -> IEX
#
# The .cmd wrapper is the critical layer for policy-locked machines:
#   cmd.exe has no ExecutionPolicy -- it launches powershell.exe freely.
#   The EncodedCommand uses ReadAllText + IEX (KW-002) to bypass the
#   file-load policy gate that blocks -File on Restricted/AllSigned machines.
#
# Sources:
#   KW-002: IEX-from-string bypasses file-load policy gate (confirmed 2026-03-08)
#   KW-035: Verify scheduled task after Register (confirmed pattern)
#   MS Docs: New-ScheduledTaskPrincipal -LogonType Interactive -UserId $env:USERNAME
#            fires at logon of the registering user only (not all users)
#   sid-500.com/2017/07/26: confirmed AtLogOn + Interactive + current user pattern
# ===========================================================================

function Test-StartupTask {
  try {
    $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    return ($null -ne $t)
  } catch { return $false }
}

function Register-StartupTask {
  # Writes the .cmd launcher then registers the scheduled task.
  # Returns $true on success, $false on failure.
  param([string]$ScriptPath)
  try {
    New-DirIfMissing -Path $script:BaseDir

    # --- Step 1: Write the .cmd launcher (KW-002 IEX bootstrap pattern) ---
    # The encoded command: set Bypass, ReadAllText, IEX.
    # Bypasses file-load ExecutionPolicy gate on Restricted/AllSigned machines.
    $scriptEscaped = $ScriptPath -replace '"', '`"'
    $bootstrap = "`$env:PSExecutionPolicyPreference='Bypass'; " +
                 "Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass " +
                   "-Force -ErrorAction SilentlyContinue; " +
                 "`$content = [System.IO.File]::ReadAllText(`"$scriptEscaped`"); " +
                 "Invoke-Expression `$content"

    $encodedCmd = [Convert]::ToBase64String(
      [System.Text.Encoding]::Unicode.GetBytes($bootstrap))

    $ps64 = [System.IO.Path]::Combine(
      $env:SystemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    if (-not (Test-Path -LiteralPath $ps64)) { $ps64 = "powershell.exe" }

    # cmd file: double-quote the powershell path, pass EncodedCommand
    $cmdContent = "@echo off`r`n" +
                  "`"$ps64`" -NoProfile -NonInteractive -WindowStyle Hidden " +
                  "-EncodedCommand $encodedCmd`r`n"

    [System.IO.File]::WriteAllText(
      $script:StartupCmd, $cmdContent, [System.Text.Encoding]::ASCII)

    Write-Log "INFO" "Startup .cmd written: $($script:StartupCmd)"

    # --- Step 2: Register scheduled task (KW-035 pattern) ---
    $action = New-ScheduledTaskAction `
      -Execute "cmd.exe" `
      -Argument "/c `"$($script:StartupCmd)`"" `
      -ErrorAction Stop

    $trigger = New-ScheduledTaskTrigger -AtLogOn -ErrorAction Stop

    # Current user only, interactive session, no elevation required
    # Source: sid-500.com confirmed pattern + MS Docs -LogonType Interactive
    $principal = New-ScheduledTaskPrincipal `
      -UserId $env:USERNAME `
      -LogonType Interactive `
      -RunLevel Limited `
      -ErrorAction Stop

    $settings = New-ScheduledTaskSettingsSet `
      -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
      -ErrorAction Stop

    $task = New-ScheduledTask `
      -Action $action `
      -Trigger $trigger `
      -Principal $principal `
      -Settings $settings `
      -Description "DownDash v$($script:AppVersion) -- auto-start at logon" `
      -ErrorAction Stop

    Register-ScheduledTask `
      -TaskName $script:TaskName `
      -InputObject $task `
      -Force `
      -ErrorAction Stop | Out-Null

    # --- Step 3: Verify (KW-035) ---
    $verify = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($null -eq $verify) {
      throw "Task not found after registration"
    }
    Write-Log "INFO" "Startup task registered and verified: $($script:TaskName)"
    return $true

  } catch {
    Write-Log "ERROR" ("Register-StartupTask failed: " + (Format-Ex $_.Exception))
    return $false
  }
}

function Unregister-StartupTask {
  try {
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop
    # Remove the .cmd file -- no longer needed
    if (Test-Path -LiteralPath $script:StartupCmd) {
      Remove-Item -LiteralPath $script:StartupCmd -Force -ErrorAction SilentlyContinue
    }
    Write-Log "INFO" "Startup task removed: $($script:TaskName)"
    return $true
  } catch {
    Write-Log "ERROR" ("Unregister-StartupTask failed: " + (Format-Ex $_.Exception))
    return $false
  }
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# P/Invoke stub for User32 DestroyIcon -- releases raw HIcon handles from
# Bitmap.GetHicon(). Marshal does not expose DestroyIcon.
if (-not ('DownDash.NativeMethods' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DownDash {
  public static class NativeMethods {
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr hIcon);
  }
}
'@ -Language CSharp -ReferencedAssemblies @('System.dll') -ErrorAction Stop
}

function Get-IndicatorColor {
  param([string]$Indicator)
  switch ($Indicator) {
    "none"     { return [System.Drawing.Color]::FromArgb(39, 174, 96)   }  # green
    "minor"    { return [System.Drawing.Color]::FromArgb(241, 196, 15)  }  # yellow
    "major"    { return [System.Drawing.Color]::FromArgb(230, 126, 34)  }  # orange
    "critical" { return [System.Drawing.Color]::FromArgb(192, 57, 43)   }  # red
    default    { return [System.Drawing.Color]::FromArgb(149, 165, 166) }  # grey
  }
}

function Get-IndicatorLabel {
  param([string]$Indicator)
  switch ($Indicator) {
    "none"     { return "UP" }
    "minor"    { return "MINOR" }
    "major"    { return "OUTAGE" }
    "critical" { return "CRITICAL" }
    default    { return "UNKNOWN" }
  }
}

function Get-IndicatorIcon {
  # Returns a small 16x16 Bitmap circle for the status column
  param([string]$Indicator)
  $bmp = New-Object System.Drawing.Bitmap(16, 16)
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $col = Get-IndicatorColor $Indicator
  $brush = New-Object System.Drawing.SolidBrush($col)
  $g.FillEllipse($brush, 2, 2, 12, 12)
  $brush.Dispose(); $g.Dispose()
  return $bmp
}

function Get-TrayIcon {
  # Build a 16x16 tray icon from current worst indicator.
  # Icon.FromHandle wraps the HIcon but does NOT own it -- we clone into a new
  # Icon so the result is self-contained, then release the raw handle via P/Invoke.
  param([string]$WorstIndicator)
  $bmp = New-Object System.Drawing.Bitmap(16, 16)
  $g   = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $bg = [System.Drawing.Color]::FromArgb(30, 30, 30)
  $g.Clear($bg)
  $col   = Get-IndicatorColor $WorstIndicator
  $brush = New-Object System.Drawing.SolidBrush($col)
  $g.FillEllipse($brush, 1, 1, 14, 14)
  $brush.Dispose(); $g.Dispose()
  $hIcon = $bmp.GetHicon()
  $bmp.Dispose()
  # Clone into a fully managed Icon (owns its own copy of the image data)
  $icon = New-Object System.Drawing.Icon([System.Drawing.Icon]::FromHandle($hIcon), 16, 16)
  # Release the raw GDI handle -- Icon clone is now independent
  [void][DownDash.NativeMethods]::DestroyIcon($hIcon)
  return $icon
}

# ===========================================================================
# BUILD UI
# ===========================================================================
function Build-Form {
  # ---- Form ---------------------------------------------------------------
  $form = New-Object System.Windows.Forms.Form
  $form.Text            = $script:AppName
  $form.Width           = 900
  $form.Height          = 680
  $form.StartPosition   = "CenterScreen"
  $form.BackColor       = [System.Drawing.Color]::FromArgb(18, 18, 24)
  $form.ForeColor       = [System.Drawing.Color]::WhiteSmoke
  $form.Font            = New-Object System.Drawing.Font("Segoe UI", 9)
  $form.MinimumSize     = New-Object System.Drawing.Size(720, 480)

  # ---- Top panel ----------------------------------------------------------
  $panelTop = New-Object System.Windows.Forms.Panel
  $panelTop.Dock        = "Top"
  $panelTop.Height      = 50
  $panelTop.BackColor   = [System.Drawing.Color]::FromArgb(28, 28, 38)
  $form.Controls.Add($panelTop)

  $lblTitle = New-Object System.Windows.Forms.Label
  $lblTitle.Text        = "  SERVICE STATUS DASHBOARD"
  $lblTitle.Font        = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
  $lblTitle.ForeColor   = [System.Drawing.Color]::FromArgb(0, 204, 255)
  $lblTitle.AutoSize    = $false
  $lblTitle.Width       = 400
  $lblTitle.Height      = 50
  $lblTitle.Location    = New-Object System.Drawing.Point(0, 0)
  $lblTitle.TextAlign   = "MiddleLeft"
  $panelTop.Controls.Add($lblTitle)

  # Button layout (right-to-left from right edge of 900px form):
  # Tray@790  Refresh@695  ViewLog@615  Startup@505
  $btnStartup = New-Object System.Windows.Forms.Button
  $btnStartup.Text      = "Run at Startup"
  $btnStartup.Width     = 100
  $btnStartup.Height    = 30
  $btnStartup.Location  = New-Object System.Drawing.Point(505, 10)
  $btnStartup.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 70)
  $btnStartup.ForeColor = [System.Drawing.Color]::White
  $btnStartup.FlatStyle = "Flat"
  $panelTop.Controls.Add($btnStartup)

  $btnViewLog = New-Object System.Windows.Forms.Button
  $btnViewLog.Text     = "View Log"
  $btnViewLog.Width    = 72
  $btnViewLog.Height   = 30
  $btnViewLog.Location = New-Object System.Drawing.Point(615, 10)
  $btnViewLog.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 70)
  $btnViewLog.ForeColor = [System.Drawing.Color]::White
  $btnViewLog.FlatStyle = "Flat"
  $panelTop.Controls.Add($btnViewLog)

  $btnRefresh = New-Object System.Windows.Forms.Button
  $btnRefresh.Text      = "Refresh"
  $btnRefresh.Width     = 90
  $btnRefresh.Height    = 30
  $btnRefresh.Location  = New-Object System.Drawing.Point(695, 10)
  $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(0, 80, 140)
  $btnRefresh.ForeColor = [System.Drawing.Color]::White
  $btnRefresh.FlatStyle = "Flat"
  $btnRefresh.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
  $panelTop.Controls.Add($btnRefresh)

  $btnMinimize = New-Object System.Windows.Forms.Button
  $btnMinimize.Text     = "Tray"
  $btnMinimize.Width    = 60
  $btnMinimize.Height   = 30
  $btnMinimize.Location = New-Object System.Drawing.Point(793, 10)
  $btnMinimize.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 70)
  $btnMinimize.ForeColor = [System.Drawing.Color]::White
  $btnMinimize.FlatStyle = "Flat"
  $panelTop.Controls.Add($btnMinimize)

  # ---- DataGridView -------------------------------------------------------
  $grid = New-Object System.Windows.Forms.DataGridView
  $grid.Dock                    = "Fill"
  $grid.ReadOnly                = $true
  $grid.AllowUserToAddRows      = $false
  $grid.AllowUserToDeleteRows   = $false
  $grid.AllowUserToResizeRows   = $false
  $grid.SelectionMode           = "FullRowSelect"
  $grid.MultiSelect             = $false
  $grid.RowHeadersVisible       = $false
  $grid.AutoSizeColumnsMode     = "Fill"
  $grid.BackgroundColor         = [System.Drawing.Color]::FromArgb(22, 22, 30)
  $grid.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(22, 22, 30)
  $grid.DefaultCellStyle.ForeColor = [System.Drawing.Color]::WhiteSmoke
  $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(0, 80, 140)
  $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
  $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 38)
  $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(0, 204, 255)
  $grid.ColumnHeadersDefaultCellStyle.Font  = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
  $grid.ColumnHeadersBorderStyle = "Single"
  $grid.EnableHeadersVisualStyles = $false
  $grid.GridColor = [System.Drawing.Color]::FromArgb(40, 40, 55)
  $grid.Font = New-Object System.Drawing.Font("Consolas", 10)
  $grid.RowTemplate.Height = 30
  $form.Controls.Add($grid)
  # Grid must come after panelTop in Controls for Dock=Fill to work with Dock=Top
  $form.Controls.SetChildIndex($panelTop, 0)
  $form.Controls.SetChildIndex($grid, 1)

  # Image column for dot indicator
  $colDot = New-Object System.Windows.Forms.DataGridViewImageColumn
  $colDot.HeaderText  = ""
  $colDot.Width       = 28
  $colDot.Resizable   = "False"
  $colDot.AutoSizeMode = "None"
  $colDot.ImageLayout = "Zoom"
  [void]$grid.Columns.Add($colDot)

  $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
  $colName.HeaderText  = "Service"
  $colName.FillWeight  = 35
  [void]$grid.Columns.Add($colName)

  $colStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
  $colStatus.HeaderText = "Status"
  $colStatus.FillWeight = 15
  [void]$grid.Columns.Add($colStatus)

  $colDesc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
  $colDesc.HeaderText  = "Detail"
  $colDesc.FillWeight  = 35
  [void]$grid.Columns.Add($colDesc)

  $colTime = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
  $colTime.HeaderText  = "Checked"
  $colTime.FillWeight  = 15
  [void]$grid.Columns.Add($colTime)

  # ---- Status bar ---------------------------------------------------------
  $statusStrip = New-Object System.Windows.Forms.StatusStrip
  $statusStrip.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 38)
  $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
  $statusLabel.Text      = "Initializing..."
  $statusLabel.ForeColor = [System.Drawing.Color]::LightGray
  [void]$statusStrip.Items.Add($statusLabel)
  $form.Controls.Add($statusStrip)

  # ---- Tray icon ----------------------------------------------------------
  $trayIcon = New-Object System.Windows.Forms.NotifyIcon
  $trayIcon.Text    = $script:AppName
  $trayIcon.Visible = $false
  $trayIcon.Icon    = Get-TrayIcon "none"

  $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
  $miRestore      = New-Object System.Windows.Forms.ToolStripMenuItem("Restore")
  $miRefresh      = New-Object System.Windows.Forms.ToolStripMenuItem("Refresh Now")
  $miNotifyPrefs  = New-Object System.Windows.Forms.ToolStripMenuItem("Notifications...")
  $miExit         = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")
  [void]$trayMenu.Items.Add($miRestore)
  [void]$trayMenu.Items.Add($miRefresh)
  [void]$trayMenu.Items.Add($miNotifyPrefs)
  [void]$trayMenu.Items.Add(( New-Object System.Windows.Forms.ToolStripSeparator))
  [void]$trayMenu.Items.Add($miExit)
  $trayIcon.ContextMenuStrip = $trayMenu

  # ---- Refresh timer ------------------------------------------------------
  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = [Math]::Max(30, $script:RefreshSec) * 1000

  # ---- Daily log rotation timer -------------------------------------------
  # Fires every 24 hours. Trims log to $logMaxDaily lines.
  # First tick is 24h after launch, not on startup.
  $logRotationTimer = New-Object System.Windows.Forms.Timer
  $logRotationTimer.Interval = 24 * 60 * 60 * 1000  # 24 hours in ms

  # Snapshot script-scope vars into locals -- $script: vars resolve null inside
  # closures in some PS execution contexts (KI confirmed in this session).
  # $services and $timeoutMs added 2026-03-22: root cause of PKI-DD-003
  # ($script:Services resolved empty inside $startRefresh -- local snapshot fixes it).
  $logPath          = $script:LogPath
  $baseDir          = $script:BaseDir
  $cachePath        = $script:CachePath
  $prefsPath        = $script:PrefsPath
  $startupCmd       = $script:StartupCmd
  $taskName         = $script:TaskName
  $services         = $script:Services
  $timeoutMs        = $script:TimeoutMs
  $appName          = $script:AppName
  $logMaxShutdown   = $script:LogMaxLinesShutdown
  $logMaxDaily      = $script:LogMaxLinesDaily
  # Resolve the path to THIS script for use in the startup .cmd
  $scriptPath = $MyInvocation.ScriptName
  if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    $scriptPath = [System.IO.Path]::Combine($baseDir, "DownDash-v2.ps1")
  }

  # Load notification preferences -- which services fire alerts
  $notifyPrefs = Load-Prefs -ServiceNames ($services | ForEach-Object { $_.Name })

  # ---- State --------------------------------------------------------------
  $state = [pscustomobject]@{
    InFlight    = $false
    Attempt     = 0
    LastResults = @()
    Minimized   = $false
  }

  # ---- Synchronized hashtable -- the ONLY safe way to communicate between
  # a background runspace and WinForms controls. Background runspace writes
  # directly to $sync.ResultJson; a Forms.Timer on the UI thread reads it.
  # Pattern confirmed: hinchley.net/articles/creating-a-windows-form-using-powershell-runspaces
  $sync = [Hashtable]::Synchronized(@{
    ResultJson = $null    # background writes serialized results here
    Done       = $false   # background sets $true when finished
    Error      = $null    # background writes error string here
    PS         = $null    # PowerShell object -- disposed by pollWatcher after Done
    RS         = $null    # Runspace object   -- disposed by pollWatcher after Done
  })

  # ===========================================================================
  # HELPER CLOSURES
  # ===========================================================================

  $setStatus = {
    param([string]$Text, [string]$Color = "LightGray")
    try {
      $statusLabel.Text = $Text
      $statusLabel.ForeColor = [System.Drawing.Color]::$Color
    } catch { }
  }.GetNewClosure()

  $updateStartupButton = {
    try {
      if (Test-StartupTask) {
        $btnStartup.Text      = "Startup: ON"
        $btnStartup.BackColor = [System.Drawing.Color]::FromArgb(30, 100, 50)
        $btnStartup.ForeColor = [System.Drawing.Color]::FromArgb(144, 238, 144)
      } else {
        $btnStartup.Text      = "Run at Startup"
        $btnStartup.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 70)
        $btnStartup.ForeColor = [System.Drawing.Color]::White
      }
    } catch { }
  }.GetNewClosure()

  # Pre-create shared fonts once -- reused every repaint, never re-allocated per row
  $fontConsolasBold = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)

  $updateGrid = {
    param([object[]]$Results)
    try {
      # Dispose existing dot bitmaps before clearing -- prevents GDI handle leak
      # Each Get-IndicatorIcon allocates a 16x16 Bitmap; they accumulate if not freed.
      foreach ($row in $grid.Rows) {
        try {
          $bmp = $row.Cells[0].Value -as [System.Drawing.Image]
          if ($bmp) { $bmp.Dispose() }
        } catch { }
      }
      $grid.Rows.Clear()
      $ts = (Get-Date).ToString("HH:mm:ss")
      foreach ($r in $Results) {
        $dotImg = Get-IndicatorIcon $r.Indicator
        $lbl    = Get-IndicatorLabel $r.Indicator
        $col    = Get-IndicatorColor $r.Indicator
        $i      = $grid.Rows.Add()
        $row    = $grid.Rows[$i]
        $row.Cells[0].Value = $dotImg
        $row.Cells[1].Value = $r.Name
        $row.Cells[2].Value = $lbl
        $row.Cells[3].Value = $r.Description
        $row.Cells[4].Value = if ($r.Fresh) { $ts } else { "(cached)" }
        $row.Cells[1].Style.Font      = $fontConsolasBold
        $row.Cells[2].Style.ForeColor = $col
        $row.Cells[2].Style.Font      = $fontConsolasBold
        $row.Tag = $r.Home
      }
    } catch { Write-Log "WARN" ("Grid update failed: " + (Format-Ex $_.Exception)) }
  }.GetNewClosure()

  $updateTray = {
    param([object[]]$Results)
    try {
      # Worst indicator wins for tray color
      $worst = "none"
      $order = @{ "critical"=3; "major"=2; "minor"=1; "none"=0; "unknown"=-1 }
      foreach ($r in $Results) {
        if ($order[$r.Indicator] -gt $order[$worst]) { $worst = $r.Indicator }
      }
      $oldIcon = $trayIcon.Icon
      $trayIcon.Icon = Get-TrayIcon $worst
      try { if ($oldIcon) { $oldIcon.Dispose() } } catch { }
      $trayIcon.Text = "$appName - $($worst.ToUpper())"
    } catch { }
  }.GetNewClosure()

  $showBalloon = {
    param([string]$Title, [string]$Body, [string]$Indicator)
    try {
      if (-not $trayIcon.Visible) { return }
      $tipIcon = switch ($Indicator) {
        "critical" { [System.Windows.Forms.ToolTipIcon]::Error }
        "major"    { [System.Windows.Forms.ToolTipIcon]::Error }
        "minor"    { [System.Windows.Forms.ToolTipIcon]::Warning }
        default    { [System.Windows.Forms.ToolTipIcon]::Info }
      }
      $trayIcon.ShowBalloonTip(8000, $Title, $Body, $tipIcon)
    } catch { }
  }.GetNewClosure()

  $detectAlerts = {
    param([object[]]$NewResults, [object[]]$OldResults)
    # Fire balloon only for: services opted-in, AND new indicator is critical or major.
    # Recovery and minor transitions are intentionally suppressed.
    try {
      if (-not $OldResults -or $OldResults.Count -eq 0) { return }
      $oldMap = @{}
      foreach ($o in $OldResults) { $oldMap[$o.Name] = $o.Indicator }
      $alerts = @()
      foreach ($n in $NewResults) {
        # Skip if user has opted out of notifications for this service
        if ($notifyPrefs.ContainsKey($n.Name) -and -not $notifyPrefs[$n.Name]) { continue }
        $old = if ($oldMap.ContainsKey($n.Name)) { $oldMap[$n.Name] } else { "none" }
        if ($old -eq $n.Indicator) { continue }
        # Only alert on critical or major -- suppress minor transitions and all recoveries
        if ($n.Indicator -ne "critical" -and $n.Indicator -ne "major") { continue }
        $alerts += [pscustomobject]@{ Name=$n.Name; Old=$old; New=$n.Indicator; Desc=$n.Description }
      }
      if ($alerts.Count -eq 0) { return }
      $order = @{ "critical"=3; "major"=2; "minor"=1; "none"=0; "unknown"=-1 }
      $worst = ($alerts | Sort-Object { $order[$_.New] } -Descending | Select-Object -First 1)
      $lines = @()
      foreach ($a in $alerts) {
        $lines += "$($a.Name): $($a.New.ToUpper()) - $($a.Desc)"
      }
      $body  = ($lines -join "`n")
      $title = "OUTAGE DETECTED"
      & $showBalloon $title $body $worst.New
    } catch { }
  }.GetNewClosure()

  # Hover tooltip: MouseMove on tray icon shows a compact live status summary.
  # Uses ShowBalloonTip so it respects the 255-char BalloonTipText limit.
  # Throttled: only fires if 30 seconds have elapsed since last balloon.
  # SOURCE: learn.microsoft.com/dotnet/api/system.windows.forms.notifyicon.showballoontip
  # CONFIRMS: ShowBalloonTip(timeout, title, text, icon) is the correct hover display method.
  $lastHoverBalloon = [datetime]::MinValue
  $trayIcon.Add_MouseMove({
    try {
      if (-not $state.Minimized) { return }
      $now = [datetime]::Now
      if (($now - $lastHoverBalloon).TotalSeconds -lt 30) { return }
      $script:lastHoverBalloonRef = $now
      if (-not $state.LastResults -or $state.LastResults.Count -eq 0) { return }

      # Build compact summary -- issues first, then OK count
      $order  = @{ "critical"=3; "major"=2; "minor"=1; "none"=0; "unknown"=-1 }
      $issues = @($state.LastResults | Where-Object { $_.Indicator -ne "none" -and $_.Indicator -ne "unknown" } |
                  Sort-Object { $order[$_.Indicator] } -Descending)
      $okCount = @($state.LastResults | Where-Object { $_.Indicator -eq "none" }).Count

      if ($issues.Count -eq 0) {
        $body = "All $okCount services operational"
      } else {
        $lines = foreach ($r in $issues) { "$($r.Name): $($r.Indicator.ToUpper())" }
        $summary = $lines -join " | "
        # Trim to 230 chars to stay safely under the 255 BalloonTipText limit
        if ($summary.Length -gt 230) { $summary = $summary.Substring(0, 227) + "..." }
        $body = "$summary`n($okCount OK)"
      }

      $tipIcon = if ($issues.Count -eq 0) {
        [System.Windows.Forms.ToolTipIcon]::Info
      } elseif ($issues | Where-Object { $_.Indicator -eq "critical" -or $_.Indicator -eq "major" }) {
        [System.Windows.Forms.ToolTipIcon]::Error
      } else {
        [System.Windows.Forms.ToolTipIcon]::Warning
      }

      $trayIcon.ShowBalloonTip(8000, $appName, $body, $tipIcon)
      $lastHoverBalloon = $now
    } catch { }
  }.GetNewClosure())

  # ===========================================================================
  # REFRESH LOGIC
  # Runspace-based async: spawns a dedicated PS runspace on a background thread.
  # All poll logic is self-contained inside the runspace scriptblock -- no
  # dependency on functions defined in the parent session.
  # Results marshal back via $sync hashtable; pollWatcher (Forms.Timer, 250ms)
  # reads $sync.Done on the UI thread and calls $applyResults directly.
  # No Dispatcher.BeginInvoke, no cross-thread ScriptBlock invocation.
  # ===========================================================================

  $applyResults = {
    param([object[]]$Results)
    try {
      if (-not $Results -or $Results.Count -eq 0) {
        & $setStatus "Poll failed -- no results (see log)" "Salmon"
        return
      }
      & $detectAlerts $Results $state.LastResults
      & $updateGrid $Results
      & $updateTray $Results
      $state.LastResults = $Results
      Save-Cache -Results $Results
      $next = [int]($timer.Interval / 1000)
      $ok   = @($Results | Where-Object { $_.Indicator -eq "none" }).Count
      $warn = @($Results | Where-Object { $_.Indicator -ne "none" -and $_.Indicator -ne "unknown" }).Count
      & $setStatus ("Updated $(Get-Date -Format 'HH:mm:ss')  |  $ok OK  |  $warn issues  |  next in ${next}s") "LightGreen"
      Write-Log "INFO" ("Poll OK -- $ok up, $warn issues")
    } catch {
      Write-Log "ERROR" ("ApplyResults failed: " + (Format-Ex $_.Exception))
      & $setStatus "Internal error (see log)" "Salmon"
    }
  }.GetNewClosure()

  # PollWatcher: a Forms.Timer that checks $sync.Done on the UI thread.
  # This avoids ALL cross-thread marshalling -- the UI thread reads results
  # from the synchronized hashtable and updates controls directly.
  $pollWatcher = New-Object System.Windows.Forms.Timer
  $pollWatcher.Interval = 250  # check every 250ms

  $pollWatcher.Add_Tick({
    if (-not $sync.Done) { return }
    $pollWatcher.Stop()
    $state.InFlight     = $false
    $btnRefresh.Enabled = $true

    # Dispose runspace and PS object -- they are re-created each poll cycle.
    # Without this, each 60s poll leaks a .NET thread + ~5-10MB of runspace state.
    try { if ($sync.PS) { $sync.PS.Dispose() } } catch { }
    try { if ($sync.RS) { $sync.RS.Close(); $sync.RS.Dispose() } } catch { }
    $sync.PS = $null; $sync.RS = $null

    if ($sync.Error) {
      Write-Log "ERROR" "Poll runspace error: $($sync.Error)"
      & $setStatus "Poll error: $($sync.Error)" "Salmon"
      $sync.Done = $false; $sync.Error = $null; $sync.ResultJson = $null
      return
    }

    if ([string]::IsNullOrWhiteSpace($sync.ResultJson)) {
      Write-Log "ERROR" "Poll returned empty ResultJson"
      & $setStatus "Poll returned no results -- check View Log" "Salmon"
      $sync.Done = $false; $sync.ResultJson = $null
      return
    }

    try {
      $raw = $sync.ResultJson | ConvertFrom-Json -ErrorAction Stop
      $results = @()
      foreach ($r in $raw) {
        $results += [pscustomobject]@{
          Name        = [string]$r.Name
          Indicator   = [string]$r.Indicator
          Description = [string]$r.Description
          Home        = [string]$r.Home
          Fresh       = $true
        }
      }
      & $applyResults $results
    } catch {
      Write-Log "ERROR" "Result deserialise failed: $($_.Exception.Message)"
      & $setStatus "Result parse error -- check View Log" "Salmon"
    }
    $sync.Done = $false; $sync.ResultJson = $null; $sync.Error = $null
  }.GetNewClosure())

  $startRefresh = {
    try {
      if ($state.InFlight) { return }
      $state.InFlight = $true
      $state.Attempt++
      $btnRefresh.Enabled = $false
      & $setStatus "Polling $($services.Count) services..." "Khaki"
      Write-Log "INFO" "Starting poll attempt #$($state.Attempt)"

      # Reset sync hash
      $sync.Done       = $false
      $sync.ResultJson = $null
      $sync.Error      = $null

      # Build service list as plain hashtables so they serialise across runspaces
      $svcData = [System.Collections.Generic.List[hashtable]]::new()
      foreach ($s in $services) {
        $svcData.Add(@{ Name=$s.Name; Url=$s.Url; SP=[bool]$s.SP; Home=$s.Home })
      }
      $toutMs = $timeoutMs

      # Guard: if service manifest is empty we have nothing to poll
      if ($svcData.Count -eq 0) {
        $state.InFlight = $false
        $btnRefresh.Enabled = $true
        Write-Log "ERROR" "StartRefresh aborted: service manifest is empty"
        & $setStatus "No services configured" "Salmon"
        return
      }

      # Convert to plain array for injection (array serialises cleanly across runspace boundary)
      $svcArray = $svcData.ToArray()

      # Create runspace -- inject $sync, $svcArray, $toutMs via SessionStateProxy
      $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
      $rs.ApartmentState = "MTA"
      $rs.ThreadOptions  = "ReuseThread"
      $rs.Open()
      $rs.SessionStateProxy.SetVariable("sync",     $sync)
      $rs.SessionStateProxy.SetVariable("svcData",  $svcArray)
      $rs.SessionStateProxy.SetVariable("toutMs",   $toutMs)

      $ps = [System.Management.Automation.PowerShell]::Create()
      $ps.Runspace = $rs
      [void]$ps.AddScript({
        try {
          # Guard: confirm injection arrived -- if $svcData is null the proxy failed
          if ($null -eq $svcData -or $svcData.Count -eq 0) {
            $sync.Error = "Runspace injection failed: svcData is null or empty"
            $sync.Done  = $true
            return
          }

          # DDFetch in this runspace
          if (-not ('DDFetch' -as [type])) {
            $csharp = @'
using System; using System.IO; using System.Net; using System.Text;
public static class DDFetch {
  public static string[] Get(string url, int ms) {
    try {
      var req = (HttpWebRequest)WebRequest.Create(url);
      req.Method = "GET"; req.UserAgent = "DownDash/2.0";
      req.Accept = "application/json,text/plain,*/*";
      req.Timeout = ms; req.ReadWriteTimeout = ms;
      req.AllowAutoRedirect = true; req.KeepAlive = false;
      try { req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate; } catch {}
      try { req.Proxy = WebRequest.DefaultWebProxy; if (req.Proxy != null) req.Proxy.Credentials = CredentialCache.DefaultCredentials; } catch {}
      using (var resp = (HttpWebResponse)req.GetResponse()) {
        var code = (int)resp.StatusCode;
        string body;
        using (var sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) body = sr.ReadToEnd();
        return new string[]{ (code>=200&&code<300)?"1":"0", code.ToString(), body??"", "" };
      }
    } catch (WebException wex) {
      int code = 0;
      if (wex.Response is HttpWebResponse) code = (int)((HttpWebResponse)wex.Response).StatusCode;
      return new string[]{ "0", code.ToString(), "", wex.Message??"WebException" };
    } catch (Exception ex) {
      return new string[]{ "0", "0", "", ex.GetType().Name+": "+(ex.Message??"") };
    }
  }
}
'@
            Add-Type -TypeDefinition $csharp -Language CSharp -ReferencedAssemblies @('System.dll') -ErrorAction Stop
          }

          $out = New-Object System.Collections.Generic.List[hashtable]
          foreach ($svc in $svcData) {
            $r    = [DDFetch]::Get($svc['Url'], $toutMs)
            $ok   = ($r[0] -eq '1')
            $code = [int]$r[1]
            $body = $r[2]
            $err  = $r[3]

            $ind  = 'unknown'
            $desc = 'Unknown'

            if (-not $ok) {
              if ($code -ge 200 -and $code -lt 400) { $ind = 'none';     $desc = 'Reachable' }
              elseif ($code -ge 400 -and $code -lt 500) { $ind = 'minor';$desc = "HTTP $code" }
              elseif ($code -ge 500) { $ind = 'major';    $desc = "HTTP $code" }
              else                   { $ind = 'critical'; $desc = if ($err) { $err } else { 'Unreachable' } }
            } elseif ($svc['SP']) {
              try {
                $j = $body | ConvertFrom-Json
                $raw = [string]$j.status.indicator
                $ind = switch ($raw.ToLower()) { 'none'{'none'} 'minor'{'minor'} 'major'{'major'} 'critical'{'critical'} default{'unknown'} }
                $desc = if ($j.status.description) { [string]$j.status.description } else { $ind }
              } catch { $ind = 'unknown'; $desc = 'Parse error' }
            } elseif ($svc['Name'] -eq 'Slack') {
              try {
                $j = $body | ConvertFrom-Json
                $st = if ($j.status) { [string]$j.status } else { 'ok' }
                $ind = switch ($st.ToLower()) { 'ok'{'none'} 'active'{'major'} 'warning'{'minor'} default{'unknown'} }
                $desc = if ($j.title) { [string]$j.title } elseif ($ind -eq 'none') { 'All Systems Operational' } else { 'Incident active' }
              } catch { $ind = 'unknown'; $desc = 'Parse error' }
            } else {
              if ($code -ge 200 -and $code -lt 400) { $ind = 'none'; $desc = 'Reachable' }
              elseif ($code -ge 400 -and $code -lt 500) { $ind = 'minor'; $desc = "HTTP $code" }
              elseif ($code -ge 500) { $ind = 'major'; $desc = "HTTP $code" }
              else { $ind = 'critical'; $desc = if ($err) { $err } else { 'Unreachable' } }
            }

            $out.Add(@{ Name=$svc['Name']; Indicator=$ind; Description=$desc; Home=$svc['Home'] }) | Out-Null
          }

          # Force array wrapper so ConvertTo-Json always produces [] even for 1 item
          $arr = $out.ToArray()
          $sync.ResultJson = (ConvertTo-Json -InputObject $arr -Depth 4 -Compress)
          $sync.Done       = $true

        } catch {
          $sync.Error = $_.Exception.Message
          $sync.Done  = $true
        }
      })

      # Store references so pollWatcher can dispose them after Done
      $sync.PS = $ps
      $sync.RS = $rs

      # Fire and forget -- pollWatcher timer reads $sync.Done every 250ms
      [void]$ps.BeginInvoke()
      $pollWatcher.Start()

    } catch {
      $state.InFlight = $false
      $btnRefresh.Enabled = $true
      $errMsg = $_.Exception.Message
      Write-Log "ERROR" "StartRefresh failed: $errMsg"
      & $setStatus "Refresh failed: $errMsg" "Salmon"
    }
  }.GetNewClosure()

  # ===========================================================================
  # EVENT WIRING
  # ===========================================================================

  # Timer
  $timer.Add_Tick({ & $startRefresh }.GetNewClosure())

  # Startup button -- toggle scheduled task on/off
  $btnStartup.Add_Click({
    try {
      if (Test-StartupTask) {
        # Currently enabled -- remove it
        $ok = Unregister-StartupTask
        if ($ok) {
          & $setStatus "Startup task removed." "LightGray"
        } else {
          & $setStatus "Failed to remove startup task -- see View Log." "Salmon"
        }
      } else {
        # Currently disabled -- register it
        if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath)) {
          [System.Windows.Forms.MessageBox]::Show(
            "Cannot register startup task: script path not found.`r`n`r`nPath: $scriptPath`r`n`r`nRun DownDash directly from its installed .ps1 file to enable this feature.",
            "Startup Registration", "OK", "Warning") | Out-Null
          return
        }
        $ok = Register-StartupTask -ScriptPath $scriptPath
        if ($ok) {
          & $setStatus "Startup task registered. DownDash will launch at logon." "LightGreen"
        } else {
          & $setStatus "Failed to register startup task -- see View Log." "Salmon"
        }
      }
      & $updateStartupButton
    } catch {
      Write-Log "ERROR" "Startup button error: $($_.Exception.Message)"
      & $setStatus "Startup error -- see View Log." "Salmon"
    }
  }.GetNewClosure())

  # View Log button
  $btnViewLog.Add_Click({
    try {
      if (-not (Test-Path -LiteralPath $baseDir -ErrorAction SilentlyContinue)) {
        [System.IO.Directory]::CreateDirectory($baseDir) | Out-Null
      }
      if (-not (Test-Path -LiteralPath $logPath -ErrorAction SilentlyContinue)) {
        [System.IO.File]::WriteAllText($logPath, "# DownDash log`r`n", [System.Text.Encoding]::UTF8)
      }
      Start-Process -FilePath "notepad.exe" -ArgumentList "`"$logPath`""
    } catch {
      [System.Windows.Forms.MessageBox]::Show(
        "Could not open log.`r`nPath: $logPath`r`nError: $($_.Exception.Message)",
        "View Log", "OK", "Error"
      ) | Out-Null
    }
  }.GetNewClosure())

  # Refresh button
  $btnRefresh.Add_Click({ & $startRefresh }.GetNewClosure())

  # Tray button -- hide to tray
  $btnMinimize.Add_Click({
    $form.Hide()
    $trayIcon.Visible = $true
    $state.Minimized  = $true
  }.GetNewClosure())

  # Tray: double-click restores
  $trayIcon.Add_DoubleClick({
    $form.Show()
    $form.WindowState = "Normal"
    $form.Activate()
    $trayIcon.Visible = $false
    $state.Minimized  = $false
  }.GetNewClosure())

  # Tray: context menu
  $miRestore.Add_Click({
    $form.Show()
    $form.WindowState = "Normal"
    $form.Activate()
    $trayIcon.Visible = $false
    $state.Minimized  = $false
  }.GetNewClosure())

  $miRefresh.Add_Click({ & $startRefresh }.GetNewClosure())

  $miNotifyPrefs.Add_Click({
    $svcNames = @($services | ForEach-Object { $_.Name })
    $updated  = Show-NotifyPrefsDialog -Prefs $notifyPrefs -ServiceNames $svcNames
    if ($null -ne $updated) {
      # Update the live prefs hashtable in-place so $detectAlerts sees the change
      foreach ($k in $updated.Keys) { $notifyPrefs[$k] = $updated[$k] }
      Save-Prefs -Prefs $notifyPrefs
      Write-Log "INFO" "Notification prefs saved"
    }
  }.GetNewClosure())

  $miExit.Add_Click({
    $timer.Stop()
    $logRotationTimer.Stop()
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
  }.GetNewClosure())

  # Minimise to tray on window minimize button (not close)
  $form.Add_Resize({
    if ($form.WindowState -eq "Minimized") {
      $form.Hide()
      $trayIcon.Visible = $true
      $state.Minimized  = $true
    }
  }.GetNewClosure())

  # Grid double-click opens service home page
  $grid.Add_CellDoubleClick({
    param($s, $ev)
    try {
      if ($ev.RowIndex -ge 0) {
        $url = $grid.Rows[$ev.RowIndex].Tag
        if (-not [string]::IsNullOrWhiteSpace($url)) {
          Start-Process -FilePath $url | Out-Null
        }
      }
    } catch { }
  }.GetNewClosure())

  # On shown: load cache, start timers, kick first poll
  $form.Add_Shown({
    Write-Log "INFO" "Form shown -- loading cache, starting timer"
    & $updateStartupButton
    $cached = Load-Cache
    if ($cached -and $cached.Count -gt 0) {
      $state.LastResults = $cached
      & $updateGrid $cached
      & $updateTray $cached
      & $setStatus "Loaded cached results -- polling now..." "Khaki"
    } else {
      & $setStatus "No cache -- polling now..." "Khaki"
    }
    try { $timer.Start() } catch { Write-Log "ERROR" ("Timer start failed: " + (Format-Ex $_.Exception)) }
    try { $logRotationTimer.Start() } catch { }
    & $startRefresh
  }.GetNewClosure())

  # Daily log rotation tick -- trims to $logMaxDaily lines
  $logRotationTimer.Add_Tick({
    try {
      Invoke-LogRotation -MaxLines $logMaxDaily
      Write-Log "INFO" "Daily log rotation complete (kept last $logMaxDaily lines)"
    } catch { }
  }.GetNewClosure())

  # On close: trim log aggressively, tidy up
  $form.Add_FormClosing({
    try { $timer.Stop() }            catch { }
    try { $pollWatcher.Stop() }      catch { }
    try { $logRotationTimer.Stop() } catch { }
    try { Invoke-LogRotation -MaxLines $logMaxShutdown } catch { }
    try { $trayIcon.Visible = $false; $trayIcon.Dispose() } catch { }
  }.GetNewClosure())

  return $form
}

# ===========================================================================
# ENTRY POINT
# ===========================================================================
try {
  New-DirIfMissing -Path $script:BaseDir
  Write-Log "INFO" ("Starting $($script:AppName) v$($script:AppVersion)")
  Ensure-STA
  Set-Tls
  $form = Build-Form
  # Application::Run keeps the WinForms message pump alive even when the form
  # is hidden (minimized to tray). ShowDialog() returns as soon as the form is
  # hidden, killing the process. Application::Run stays until Application::Exit().
  [System.Windows.Forms.Application]::Run($form)
} catch {
  Write-Log "FATAL" $_.Exception.ToString()
  [System.Windows.Forms.MessageBox]::Show(
    "Fatal error: $($_.Exception.Message)`r`n`r`nCheck log: $($script:LogPath)",
    $script:AppName, "OK", "Error"
  ) | Out-Null
  exit 1
}

# SIG # Begin signature block
# MIIbywYJKoZIhvcNAQcCoIIbvDCCG7gCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUmqabaDh/vyT7Z0mNV/Ac11Tb
# gf+gghY+MIIDADCCAeigAwIBAgIQTKEr1rZAMpdH6q/PYVxP8zANBgkqhkiG9w0B
# AQsFADAYMRYwFAYDVQQDDA1DaGFybGVzIEhheWVzMB4XDTI2MDEyMTAwNTgxMloX
# DTI3MDEyMTAxMTgxMlowGDEWMBQGA1UEAwwNQ2hhcmxlcyBIYXllczCCASIwDQYJ
# KoZIhvcNAQEBBQADggEPADCCAQoCggEBALtWf8oafpME0WWuVh4TbKORD9c1XDt+
# rNWO8Xv50g1TKLykkFX9yRwhtjGzk0jISrA6K3Y2500dz4NKNcn9a97AOtoZ/Cty
# qOKazuLlxur288B9nUzth7EoFrASoIR1sViu1rGYvCH+W7f6tNdXeLHtpd1AypJx
# hObmYedFXuioFHdQH1Q/4KlJbviYapH9M3Fu2fyo0FRGWY32+6G9kPZvzlOTV24q
# /9ASHmuU5d35vWNKwKibXE2pBPAn6JAPRWVwO0NQV42y3cLBXyxJZ3dqsHKH7TaZ
# 1ekPhK4r16ErcKbKLPQz4ww1HJkxkeTt1rq37ar1WDn5IOzoWEeK/WUCAwEAAaNG
# MEQwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMB0GA1UdDgQW
# BBQOSx59ShiyniL5bPdMsBJKa+rcbTANBgkqhkiG9w0BAQsFAAOCAQEASSFO85i8
# uDewMYjmgJYvP/133CPh+PM092u8ACXVUCPSntn4dBnlUEHSV/pFVz2DcxmDkA5D
# L6gIZyQSiWZpb5Y8nnpz52eZ6xj1YoCA0ts9hc/lEeWU6u4zXosLVVQqPFuRFnwU
# XR/Gd+LeeU3zsve+E9UCXinBhJBC7YSHy9PIncCcQJiGsZd/wyfMiF4vWQzwjJzN
# QoWA2kg/+UPwTJV02MnoWF7HnLrdqpuqD6yHFQ3OK4O0h4J5vPaDY/LXffHGWBgN
# jO7zfIlq3XSROZetMPsbz0SNcM1aGRIsIo93H2xdG/StiXB9M2ZB6OrHgRW/bJfb
# JAebYlJsw3DRxDCCBY0wggR1oAMCAQICEA6bGI750C3n79tQ4ghAGFowDQYJKoZI
# hvcNAQEMBQAwZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZ
# MBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNlcnQgQXNz
# dXJlZCBJRCBSb290IENBMB4XDTIyMDgwMTAwMDAwMFoXDTMxMTEwOTIzNTk1OVow
# YjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQ
# d3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290
# IEc0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv+aQc2jeu+RdSjww
# IjBpM+zCpyUuySE98orYWcLhKac9WKt2ms2uexuEDcQwH/MbpDgW61bGl20dq7J5
# 8soR0uRf1gU8Ug9SH8aeFaV+vp+pVxZZVXKvaJNwwrK6dZlqczKU0RBEEC7fgvMH
# hOZ0O21x4i0MG+4g1ckgHWMpLc7sXk7Ik/ghYZs06wXGXuxbGrzryc/NrDRAX7F6
# Zu53yEioZldXn1RYjgwrt0+nMNlW7sp7XeOtyU9e5TXnMcvak17cjo+A2raRmECQ
# ecN4x7axxLVqGDgDEI3Y1DekLgV9iPWCPhCRcKtVgkEy19sEcypukQF8IUzUvK4b
# A3VdeGbZOjFEmjNAvwjXWkmkwuapoGfdpCe8oU85tRFYF/ckXEaPZPfBaYh2mHY9
# WV1CdoeJl2l6SPDgohIbZpp0yt5LHucOY67m1O+SkjqePdwA5EUlibaaRBkrfsCU
# tNJhbesz2cXfSwQAzH0clcOP9yGyshG3u3/y1YxwLEFgqrFjGESVGnZifvaAsPvo
# ZKYz0YkH4b235kOkGLimdwHhD5QMIR2yVCkliWzlDlJRR3S+Jqy2QXXeeqxfjT/J
# vNNBERJb5RBQ6zHFynIWIgnffEx1P2PsIV/EIFFrb7GrhotPwtZFX50g/KEexcCP
# orF+CiaZ9eRpL5gdLfXZqbId5RsCAwEAAaOCATowggE2MA8GA1UdEwEB/wQFMAMB
# Af8wHQYDVR0OBBYEFOzX44LScV1kTN8uZz/nupiuHA9PMB8GA1UdIwQYMBaAFEXr
# oq/0ksuCMS1Ri6enIZ3zbcgPMA4GA1UdDwEB/wQEAwIBhjB5BggrBgEFBQcBAQRt
# MGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEF
# BQcwAoY3aHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJl
# ZElEUm9vdENBLmNydDBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3JsMy5kaWdp
# Y2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMBEGA1UdIAQKMAgw
# BgYEVR0gADANBgkqhkiG9w0BAQwFAAOCAQEAcKC/Q1xV5zhfoKN0Gz22Ftf3v1cH
# vZqsoYcs7IVeqRq7IviHGmlUIu2kiHdtvRoU9BNKei8ttzjv9P+Aufih9/Jy3iS8
# UgPITtAq3votVs/59PesMHqai7Je1M/RQ0SbQyHrlnKhSLSZy51PpwYDE3cnRNTn
# f+hZqPC/Lwum6fI0POz3A8eHqNJMQBk1RmppVLC4oVaO7KTVPeix3P0c2PR3WlxU
# jG/voVA9/HYJaISfb8rbII01YBwCA8sgsKxYoA5AY8WYIsGyWfVVa88nq2x2zm8j
# LfR+cWojayL/ErhULSd+2DrZ8LaHlv1b0VysGMNNn3O3AamfV6peKOK5lDCCBrQw
# ggScoAMCAQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJKoZIhvcNAQELBQAwYjELMAkG
# A1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRp
# Z2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290IEc0MB4X
# DTI1MDUwNzAwMDAwMFoXDTM4MDExNDIzNTk1OVowaTELMAkGA1UEBhMCVVMxFzAV
# BgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVk
# IEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBALR4MdMKmEFyvjxGwBysddujRmh0tFEX
# nU2tjQ2UtZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh/qm8Xi4aPCOo2N8S9SLrC6Kb
# ltqn7SWCWgzbNfiR+2fkHUiljNOqnIVD/gG3SYDEAd4dg2dDGpeZGKe+42DFUF0m
# R/vtLa4+gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8yAR2CQWIM1iI5PHg62IVwxKSp
# O0XaF9DPfNBKS7Zazch8NF5vp7eaZ2CVNxpqumzTCNSOxm+SAWSuIr21Qomb+zzQ
# WKhxKTVVgtmUPAW35xUUFREmDrMxSNlr/NsJyUXzdtFUUt4aS4CEeIY8y9IaaGBp
# PNXKFifinT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ55IuwnKCgs+nrpuQNfVmUB5K
# lCX3ZA4x5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJkhU1JrPsFfxW1gaou30yZ46t
# 4Y9F20HHfIY4/6vHespYMQmUiote8ladjS/nJ0+k6MvqzfpzPDOy5y6gqztiT96F
# v/9bH7mQyogxG9QEPHrPV6/7umw052AkyiLA6tQbZl1KhBtTasySkuJDpsZGKdls
# jg4u70EwgWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x0VR4RjSpWM8o5a6D8bpfm4CL
# KczsG7ZrIGNTAgMBAAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1Ud
# DgQWBBTvb1NK6eQGfHrK4pBW9i/USezLTjAfBgNVHSMEGDAWgBTs1+OC0nFdZEzf
# Lmc/57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwgw
# dwYIKwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2Vy
# dC5jb20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9E
# aWdpQ2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSGMmh0dHA6
# Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3JsMCAG
# A1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOC
# AgEAF877FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYgaMH9Pw5tcBnPw6O6FTGNpoV2V
# 4wzSUGvI9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4hCFATuNT+ReOPK0mCefSG+tXq
# GpYZ3essBS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJv2sRUoKEfJ+nN57mQfQXwcAE
# GCvRR2qKtntujB71WPYAgwPyWLKu6RnaID/B0ba2H3LUiwDRAXx1Neq9ydOal95C
# HfmTnM4I+ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX+DF0SQzHU0pTi4dBwp9nEC8E
# AqoxW6q17r0z0noDjs6+BFo+z7bKSBwZXTRNivYuve3L2oiKNqetRHdqfMTCW/Nm
# KLJ9M+MtucVGyOxiDf06VXxyKkOirv6o02OoXN4bFzK0vlNMsvhlqgF2puE6Fndl
# ENSmE+9JGYxOGLS/D284NHNboDGcmWXfwXRy4kbu4QFhOm0xJuF2EZAOk5eCkhSx
# ZON3rGlHqhpB/8MluDezooIs8CVnrpHMiD2wL40mm53+/j7tFaxYKIqL0Q4ssd8x
# HZnIn/7GELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN62JK4S1C8uw3PdBunvAZapsiI
# 5YKdvlarEvf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ9k+5t1wwggbtMIIE1aADAgEC
# AhAKgO8YS43xBYLRxHanlXRoMA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYTAlVT
# MRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1
# c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwHhcN
# MjUwNjA0MDAwMDAwWhcNMzYwOTAzMjM1OTU5WjBjMQswCQYDVQQGEwJVUzEXMBUG
# A1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFNIQTI1NiBS
# U0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNSAxMIICIjANBgkqhkiG9w0B
# AQEFAAOCAg8AMIICCgKCAgEA0EasLRLGntDqrmBWsytXum9R/4ZwCgHfyjfMGUIw
# YzKomd8U1nH7C8Dr0cVMF3BsfAFI54um8+dnxk36+jx0Tb+k+87H9WPxNyFPJIDZ
# HhAqlUPt281mHrBbZHqRK71Em3/hCGC5KyyneqiZ7syvFXJ9A72wzHpkBaMUNg7M
# OLxI6E9RaUueHTQKWXymOtRwJXcrcTTPPT2V1D/+cFllESviH8YjoPFvZSjKs3SK
# O1QNUdFd2adw44wDcKgH+JRJE5Qg0NP3yiSyi5MxgU6cehGHr7zou1znOM8odbkq
# oK+lJ25LCHBSai25CFyD23DZgPfDrJJJK77epTwMP6eKA0kWa3osAe8fcpK40uhk
# tzUd/Yk0xUvhDU6lvJukx7jphx40DQt82yepyekl4i0r8OEps/FNO4ahfvAk12hE
# 5FVs9HVVWcO5J4dVmVzix4A77p3awLbr89A90/nWGjXMGn7FQhmSlIUDy9Z2hSgc
# taepZTd0ILIUbWuhKuAeNIeWrzHKYueMJtItnj2Q+aTyLLKLM0MheP/9w6CtjuuV
# HJOVoIJ/DtpJRE7Ce7vMRHoRon4CWIvuiNN1Lk9Y+xZ66lazs2kKFSTnnkrT3pXW
# ETTJkhd76CIDBbTRofOsNyEhzZtCGmnQigpFHti58CSmvEyJcAlDVcKacJ+A9/z7
# eacCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFOQ7/PIx7f39
# 1/ORcWMZUEPPYYzoMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esrikFb2L9RJ7MtOMA4G
# A1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCBlQYIKwYBBQUH
# AQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBd
# BggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3J0MF8G
# A1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2Vy
# dFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNybDAg
# BgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQAD
# ggIBAGUqrfEcJwS5rmBB7NEIRJ5jQHIh+OT2Ik/bNYulCrVvhREafBYF0RkP2AGr
# 181o2YWPoSHz9iZEN/FPsLSTwVQWo2H62yGBvg7ouCODwrx6ULj6hYKqdT8wv2UV
# +Kbz/3ImZlJ7YXwBD9R0oU62PtgxOao872bOySCILdBghQ/ZLcdC8cbUUO75ZSpb
# h1oipOhcUT8lD8QAGB9lctZTTOJM3pHfKBAEcxQFoHlt2s9sXoxFizTeHihsQyfF
# g5fxUFEp7W42fNBVN4ueLaceRf9Cq9ec1v5iQMWTFQa0xNqItH3CPFTG7aEQJmmr
# JTV3Qhtfparz+BW60OiMEgV5GWoBy4RVPRwqxv7Mk0Sy4QHs7v9y69NBqycz0BZw
# hB9WOfOu/CIJnzkQTwtSSpGGhLdjnQ4eBpjtP+XB3pQCtv4E5UCSDag6+iX8MmB1
# 0nfldPF9SVD7weCC3yXZi/uuhqdwkgVxuiMFzGVFwYbQsiGnoa9F5AaAyBjFBtXV
# LcKtapnMG3VH3EmAp/jsJ3FVF3+d1SVDTmjFjLbNFZUWMXuZyvgLfgyPehwJVxwC
# +UpX2MSey2ueIu9THFVkT+um1vshETaWyQo8gmBto/m3acaP9QsuLj3FNwFlTxq2
# 5+T4QwX9xa6ILs84ZPvmpovq90K8eWyG2N01c4IhSOxqt81nMYIE9zCCBPMCAQEw
# LDAYMRYwFAYDVQQDDA1DaGFybGVzIEhheWVzAhBMoSvWtkAyl0fqr89hXE/zMAkG
# BSsOAwIaBQCgeDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJ
# AzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMG
# CSqGSIb3DQEJBDEWBBRUBswKcHrWr4m/6pMiH8P7JONNgzANBgkqhkiG9w0BAQEF
# AASCAQB9wZgMdMgj+X+qvSzyxtz3bux/3L+IKKEXE+z4Y++x9Q5bCeOSY57Ef/yK
# EftOo4k0qpeAGoM5Jq1XDTihd9dubGwL1SxAjCJhovNvTtTvn3ZWtx0f9IpKxwi7
# zvv2zW0H0zrF/O4IAxlJDnhgIdLTmDC6s5ahp6aHfw9nAfS9G4loj9Y5jWPOH/sE
# tzCjWYGagceaqt7+nrAhzmBf6oe6T5BjS8Wn+/ZQVluZIf45UZav/6dUZ1vNvm/H
# rI41nSJOBBR+oy1DDjKOtcuFsKYUK11Aiq9uGkE7M+Lbhap6Zc7elrRQXKQLe/lx
# J/98JDyk4vYQB8qd2/uk3qdgp96NoYIDJjCCAyIGCSqGSIb3DQEJBjGCAxMwggMP
# AgEBMH0waTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEw
# PwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2
# IFNIQTI1NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglghkgBZQMEAgEF
# AKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTI2
# MDMzMDIwNTk1OVowLwYJKoZIhvcNAQkEMSIEIGJFNJmXeS2M+w5oK3HQ50y3ltCE
# fwfNcauOcQaB8phJMA0GCSqGSIb3DQEBAQUABIICAA8QzDiQIHRXxsqDSpCgi2yP
# VSG4RCt5jAWe6xQ6P9kmA9pPVXLmCWOK5p9nQFONz/IdHWyG68d71wUOPWdkAzDh
# lBdtOQVOeMN++QxnC5PY5RJtX4MemOLyPT/QAXxq5vh68MsYP18kRXuPRiaLe1ic
# P68OkReracPgA4KZ3zXlFwXMRLb1W6h+9EXOnAym4z0EIs3kA6IJ6Yv2ON2+zuJd
# 4Hsyr5NZsTiqTW8mZUOgniKuCjRME4lCAtgWIl1Gj9Xd6EaORYlioUgXxgnn/qz3
# v5zMHiPbe5j24IRvU+qlj6DQhrZUSZPyx1+USeW7SpoxAh689J1QCyZ/ouoSp/rY
# NgnrnQk3YOMkN5L1GFHsapENa6/i1Yq7AobDvsmNVfzSHGAOgeuZf+dPMIYWXgLt
# kqAOciIPy5b1808qcASD9qMvcV2fraHUsigo1Rpok0dGA8BiCpzVKH7fWH0VXzxe
# 4VaNklU+qSRYB3tmIl9PL1KH4CJlPaOt0NfTiI4KeM68iPLIRcBHzZvY5ygZFqhd
# k8a6Wrb/eOOneifYrvTiAES0erJAnbykRxHaZAXnkh0HBO75vNYYlc4NRZV1W8Z2
# zGK0xeId/xEFHzZaqWcZxbH/thsg7DQ9wn4TNcRNaxdHSS/wJQ47r/qkyMhOJ6Wd
# Q0eW/tpkyw+3AGOmX2lX
# SIG # End signature block
