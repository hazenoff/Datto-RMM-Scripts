#Requires -Version 3.0
<#
.SYNOPSIS
    Paladin Network Pro [WIN]
    Paladin Business Consulting | Datto RMM Component | Single-File
    Version: 3.1.0

.DESCRIPTION
    Full-featured network diagnostics GUI for field technicians.
    Tabs: Overview, Speed Test, Multi-Ping, DNS/WHOIS, Port Scan,
    Actions, Repair, WLAN Report, LAN Report, Portable Tools.
    SMTP email for scheduled reports.

    SYSTEM MODE (Datto entry point):
      Detects logged-on user, copies self to staging path,
      launches GUI as logged-on user via scheduled task.

    GUI MODE (-GUIMode):
      Full WinForms GUI -- all diagnostics run in user context.

    STAGING: C:\ProgramData\Paladin\NetworkPro\
    LOG:     C:\ProgramData\Paladin\NetworkPro\NetworkPro.log
    CONFIG:  C:\ProgramData\Paladin\NetworkPro\NetworkPro.cfg

    Paladin Business Consulting | Internal Use Only
#>

param(
    [switch]$GUIMode,
    [string]$SiteName = '',
    [switch]$ReportMode   # headless report generation (existing feature)
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ===========================================================================
# SHARED CONSTANTS
# ===========================================================================
$PaladinBase = 'C:\ProgramData\Paladin\NetworkPro'
$SelfDest    = "$PaladinBase\Paladin-NetworkPro.ps1"
$TaskName    = 'Paladin_NetworkPro_GUI'

# ===========================================================================
# DATTO SYSTEM LAUNCHER
# Runs when Datto fires the component as SYSTEM
# ===========================================================================
if (-not $GUIMode -and -not $ReportMode) {

    function Write-SysLog { param([string]$M) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $M" }

    Write-SysLog 'Paladin Network Pro v3.1.0 -- SYSTEM launcher'

    # Create staging dir
    if (-not (Test-Path $PaladinBase)) {
        New-Item $PaladinBase -ItemType Directory -Force | Out-Null
    }

    # Stage self
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $SelfDest -Force -EA Stop
        Write-SysLog "Staged: $SelfDest"
    } catch {
        Write-SysLog "ERROR staging: $($_.Exception.Message)"
        exit 1
    }

    # Get logged-on user
    $loggedOnUser = $null
    try {
        $cs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
        if ($cs -and $cs.UserName) { $loggedOnUser = ($cs.UserName -split '\\')[-1] }
    } catch {}
    if (-not $loggedOnUser) {
        try {
            $qu = & query user 2>&1
            foreach ($l in $qu) {
                if ($l -match 'Active') { $loggedOnUser = ($l.Trim() -split '\s+')[0].TrimStart('>'); break }
            }
        } catch {}
    }
    if (-not $loggedOnUser) {
        Write-SysLog 'ERROR: No logged-on user found. A user must be logged in.'
        exit 1
    }
    Write-SysLog "User: $loggedOnUser"

    $site = $env:CS_PROFILE_NAME
    if (-not $site) { $site = 'Paladin' }
    Write-SysLog "Site: $site"

    # Launch GUI as logged-on user
    $psArgs = "-NonInteractive -ExecutionPolicy Bypass -File `"$SelfDest`" -GUIMode -SiteName `"$site`""
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    $null = & schtasks.exe /Create /TN $TaskName /TR "PowerShell.exe $psArgs" `
        /SC ONCE /ST 00:00 /RU $loggedOnUser /IT /F /RL HIGHEST 2>&1
    & schtasks.exe /Run /TN $TaskName 2>&1 | Out-Null

    Write-SysLog "Network Pro GUI launched as $loggedOnUser for site: $site"
    Start-Sleep -Seconds 5
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    exit 0
}

# ===========================================================================
# GUI MODE -- everything below runs as the logged-on user
# ===========================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

# -- PORTABLE ROOT ------------------------------------------------------------
if ($PSScriptRoot) {
    $script:Root = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $script:Root = [System.AppDomain]::CurrentDomain.BaseDirectory.TrimEnd('\')
}

# Paths -- always use ProgramData so SYSTEM-staged script and user GUI share same files
$PaladinBase         = 'C:\ProgramData\Paladin\NetworkPro'
if (-not (Test-Path $PaladinBase)) { New-Item $PaladinBase -ItemType Directory -Force | Out-Null }
$script:LogFile      = "$PaladinBase\NetworkPro.log"
$script:ConfigFile   = "$PaladinBase\NetworkPro.cfg"
$script:PingTargets  = New-Object System.Collections.ArrayList
$script:PingTimer    = $null
$script:PingActive   = $false
$script:ExternalIP   = "Checking..."
$script:InitTimer    = $null
$script:InitSync     = $null
$script:ReportSource = "$env:ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html"
$script:TaskName     = 'PaladinNetworkProReport'
$script:SessionSmtpPass = $null

# -- DARK THEME CONSTANTS -----------------------------------------------------
$script:C_BG        = [System.Drawing.Color]::FromArgb(26, 26, 46)
$script:C_BG2       = [System.Drawing.Color]::FromArgb(22, 33, 62)
$script:C_ACCENT    = [System.Drawing.Color]::FromArgb(233, 69, 96)
$script:C_BLUE      = [System.Drawing.Color]::FromArgb(15, 52, 96)
$script:C_TEXT      = [System.Drawing.Color]::FromArgb(220, 220, 220)
$script:C_SUBTEXT   = [System.Drawing.Color]::FromArgb(170, 170, 200)
$script:C_GREEN     = [System.Drawing.Color]::FromArgb(0, 230, 118)
$script:C_YELLOW    = [System.Drawing.Color]::FromArgb(255, 214, 0)
$script:C_RED       = [System.Drawing.Color]::FromArgb(255, 80, 80)
$script:C_CONSOLE   = [System.Drawing.Color]::FromArgb(13, 27, 42)
$script:FONT_UI     = New-Object System.Drawing.Font("Segoe UI", 9)
$script:FONT_BOLD   = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$script:FONT_H      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$script:FONT_CON    = New-Object System.Drawing.Font("Consolas", 9)

# -- HELPERS: THEMED CONTROLS -------------------------------------------------
function Set-TextBoxPlaceholder {
    # WinForms TextBox on .NET Framework 4.x has no PlaceholderText property.
    # Use Win32 EM_SETCUEBANNER (0x1501) via SendMessage instead.
    param([System.Windows.Forms.TextBox]$TextBox, [string]$Placeholder)
    if (-not ([Management.Automation.PSTypeName]'NetProWin32').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NetProWin32 {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);
}
'@ -ErrorAction SilentlyContinue
    }
    # EM_SETCUEBANNER = 0x1501; wParam 1 = show even when focused
    [NetProWin32]::SendMessage($TextBox.Handle, 0x1501, [IntPtr]1, $Placeholder) | Out-Null
}

function New-ThemedButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 130, [int]$H = 30, [bool]$Accent = $false)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size = New-Object System.Drawing.Size($W, $H)
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = if ($Accent) { $script:C_ACCENT } else { $script:C_BLUE }
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font = $script:FONT_UI
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

function New-ThemedTextBox {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [bool]$Multi = $false, [bool]$Console = $false)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point($X, $Y)
    $tb.Size = New-Object System.Drawing.Size($W, $H)
    $tb.BackColor = if ($Console) { $script:C_CONSOLE } else { $script:C_BG2 }
    $tb.ForeColor = if ($Console) { $script:C_GREEN } else { $script:C_TEXT }
    $tb.BorderStyle = 'FixedSingle'
    $tb.Font = if ($Console) { $script:FONT_CON } else { $script:FONT_UI }
    if ($Multi) {
        $tb.Multiline = $true
        $tb.ScrollBars = 'Vertical'
    }
    return $tb
}

function New-ThemedLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H = 20, [bool]$Bold = $false)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size = New-Object System.Drawing.Size($W, $H)
    $lbl.ForeColor = $script:C_SUBTEXT
    $lbl.Font = if ($Bold) { $script:FONT_BOLD } else { $script:FONT_UI }
    $lbl.BackColor = [System.Drawing.Color]::Transparent
    return $lbl
}

function New-ThemedCombo {
    param([int]$X, [int]$Y, [int]$W)
    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.Location = New-Object System.Drawing.Point($X, $Y)
    $cb.Size = New-Object System.Drawing.Size($W, 24)
    $cb.BackColor = $script:C_BG2
    $cb.ForeColor = $script:C_TEXT
    $cb.FlatStyle = 'Flat'
    $cb.Font = $script:FONT_UI
    $cb.DropDownStyle = 'DropDownList'
    return $cb
}

function New-ThemedGrid {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Location = New-Object System.Drawing.Point($X, $Y)
    $g.Size = New-Object System.Drawing.Size($W, $H)
    $g.ReadOnly = $true
    $g.AllowUserToAddRows = $false
    $g.SelectionMode = 'FullRowSelect'
    $g.AutoSizeColumnsMode = 'Fill'
    $g.BackgroundColor = $script:C_BG2
    $g.GridColor = $script:C_BLUE
    $g.DefaultCellStyle.BackColor = $script:C_BG2
    $g.DefaultCellStyle.ForeColor = $script:C_TEXT
    $g.DefaultCellStyle.Font = $script:FONT_UI
    $g.DefaultCellStyle.SelectionBackColor = $script:C_ACCENT
    $g.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $g.ColumnHeadersDefaultCellStyle.BackColor = $script:C_BLUE
    $g.ColumnHeadersDefaultCellStyle.ForeColor = $script:C_TEXT
    $g.ColumnHeadersDefaultCellStyle.Font = $script:FONT_BOLD
    $g.ColumnHeadersBorderStyle = 'None'
    $g.EnableHeadersVisualStyles = $false
    $g.RowHeadersVisible = $false
    $g.BorderStyle = 'None'
    return $g
}

function New-ThemedPanel {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [bool]$Dark2 = $false)
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($X, $Y)
    $p.Size = New-Object System.Drawing.Size($W, $H)
    $p.BackColor = if ($Dark2) { $script:C_BG2 } else { $script:C_BLUE }
    return $p
}

function Apply-ThemedTab {
    param([System.Windows.Forms.TabPage]$Tab)
    $Tab.BackColor = $script:C_BG
    $Tab.ForeColor = $script:C_TEXT
}

# -- CORE FUNCTIONS -----------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Type = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts][$Type] $Message"
    try { Add-Content -Path $script:LogFile -Value $entry -Encoding UTF8 -ErrorAction Stop } catch {}
}

function Get-NetworkAdapters {
    try {
        $adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" })
        if (-not $adapters) { return @() }
        $result = @()
        foreach ($adapter in $adapters) {
            # Avoid Get-NetIPConfiguration entirely -- it calls Get-NetIPInterface
            # internally which throws a terminating CimJobException for adapters
            # with no TCP/IP stack (VPN tunnels, Hyper-V vSwitch, etc.) that
            # bypasses try/catch in PS 5.1. Use Get-NetIPAddress / Get-NetRoute
            # directly -- they return empty results instead of throwing.
            try {
                $ipv4Obj = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
                $ipv6Obj = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                           Where-Object { $_.PrefixOrigin -ne "WellKnown" } | Select-Object -First 1
                $gwObj   = Get-NetRoute    -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1
                $dnsRaw  = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
                $ipv4    = if ($ipv4Obj) { $ipv4Obj.IPAddress }    else { $null }
                $ipv6    = if ($ipv6Obj) { $ipv6Obj.IPAddress }    else { $null }
                $gateway = if ($gwObj)   { $gwObj.NextHop }        else { $null }
                $subnet  = if ($ipv4Obj) { $ipv4Obj.PrefixLength } else { $null }
                $dns     = if ($dnsRaw)  { $dnsRaw -join ", " }    else { $null }
                $result += [PSCustomObject]@{
                    Name    = $adapter.Name
                    IPv4    = if ($ipv4)    { $ipv4 }    else { "N/A" }
                    IPv6    = if ($ipv6)    { $ipv6 }    else { "N/A" }
                    MAC     = $adapter.MacAddress
                    Gateway = if ($gateway) { $gateway } else { "N/A" }
                    Subnet  = if ($subnet)  { "/$subnet" } else { "N/A" }
                    DNS     = if ($dns)     { $dns }     else { "N/A" }
                    Type    = $adapter.MediaType
                    Speed   = if ($adapter.LinkSpeed) { $adapter.LinkSpeed } else { "N/A" }
                }
            } catch {}
        }
        return $result
    } catch { return @() }
}

function Test-InternetConnectivity {
    $result = @{ DNS = $false; ICMP = $false; HTTP = $false }
    try { $null = Resolve-DnsName -Name "google.com" -ErrorAction Stop; $result.DNS = $true } catch {}
    try { $result.ICMP = Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction Stop } catch {}
    try {
        $http = Invoke-WebRequest -Uri "http://www.msftconnecttest.com/connecttest.txt" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $result.HTTP = ($http.StatusCode -eq 200)
    } catch {}
    return $result
}

function Get-ExternalIP {
    $endpoints = @('https://api.ipify.org','https://icanhazip.com','https://ifconfig.me/ip')
    foreach ($uri in $endpoints) {
        try {
            $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            $ip = $response.Content.Trim()
            if ($ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $ip }
        } catch {
            Write-Log "External IP endpoint failed ($uri): $($_.Exception.Message)" "WARN"
        }
    }
    Write-Log "All external IP endpoints failed" "ERROR"
    return "Unable to detect"
}

function Get-ToolPath {
    param([string]$ToolName)
    $paths = @(
        "C:\ProgramData\chocolatey\bin\$ToolName.exe",
        "C:\Program Files\$ToolName\$ToolName.exe",
        "C:\Program Files (x86)\$ToolName\$ToolName.exe",
        "C:\Windows\System32\$ToolName.exe"
    )
    if ($ToolName -match "wireshark") { $paths += @("C:\Program Files\Wireshark\Wireshark.exe","C:\Program Files (x86)\Wireshark\Wireshark.exe") }
    elseif ($ToolName -match "zenmap") { $paths += @("C:\Program Files (x86)\Nmap\zenmap.exe","C:\Program Files\Nmap\zenmap.exe","C:\Program Files (x86)\Nmap\Zenmap.exe","C:\Program Files\Nmap\Zenmap.exe") }
    elseif ($ToolName -match "nmap")   { $paths += @("C:\Program Files (x86)\Nmap\nmap.exe","C:\Program Files\Nmap\nmap.exe","C:\ProgramData\chocolatey\bin\nmap.exe") }
    elseif ($ToolName -match "iperf")  { $paths += @("C:\ProgramData\chocolatey\bin\iperf3.exe","$env:LOCALAPPDATA\Microsoft\WinGet\Packages\ar51an.iPerf3_Microsoft.Winget.Source_8wekyb3d8bbwe\iperf3.exe") }
    elseif ($ToolName -match "putty")  { $paths += @("C:\Program Files\PuTTY\putty.exe","C:\Program Files (x86)\PuTTY\putty.exe") }
    elseif ($ToolName -match "winscp") { $paths += @("C:\Program Files\WinSCP\WinSCP.exe","C:\Program Files (x86)\WinSCP\WinSCP.exe") }
    elseif ($ToolName -match "nc$|netcat")    { $paths += "C:\ProgramData\chocolatey\bin\nc.exe" }
    elseif ($ToolName -match "mremoteng")     { $paths += @("C:\Program Files\mRemoteNG\mRemoteNG.exe","C:\Program Files (x86)\mRemoteNG\mRemoteNG.exe") }
    elseif ($ToolName -match "mitmproxy|mitmdump|mitmweb") { $paths += @("C:\Program Files\mitmproxy\mitmweb.exe","C:\ProgramData\chocolatey\bin\mitmweb.exe") }
    elseif ($ToolName -match "^ssh$")       { $paths += "C:\Windows\System32\OpenSSH\ssh.exe" }
    elseif ($ToolName -match "speedtest")   {
        $paths += @(
            "C:\Program Files\Ookla\Speedtest CLI\speedtest.exe",
            "C:\ProgramData\chocolatey\bin\speedtest.exe",
            "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Ookla.Speedtest.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\speedtest.exe"
        )
    }
    elseif ($ToolName -match "tcping")      { $paths += @("C:\ProgramData\chocolatey\bin\tcping.exe","C:\ProgramData\chocolatey\lib\tcping\tools\tcping.exe") }
    elseif ($ToolName -match "^curl$")      { $paths += @("C:\ProgramData\chocolatey\bin\curl.exe","C:\Windows\System32\curl.exe") }
    elseif ($ToolName -match "^wget$")      { $paths += "C:\ProgramData\chocolatey\bin\wget.exe" }
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue) { return $path }
    }
    $envPath = (Get-Command $ToolName -ErrorAction SilentlyContinue).Source
    if ($envPath) { return $envPath }
    return $null
}

# -- EMAIL FUNCTIONS (internal SMTP -- no Outlook dependency) ----------------
function Send-NetworkProEmail {
    param(
        [string]$SmtpServer,
        [int]$SmtpPort = 587,
        [string]$FromAddress,
        [string]$ToAddress,
        [string]$Username,
        [string]$Password,
        [bool]$UseTls = $true,
        [string]$Subject,
        [string]$Body,
        [string]$AttachmentPath = ""
    )
    # System.Net.Mail.SmtpClient -- works at any integrity level, no COM needed
    $client = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
    $client.EnableSsl = $UseTls
    $client.DeliveryMethod = [System.Net.Mail.SmtpDeliveryMethod]::Network
    if (-not [string]::IsNullOrWhiteSpace($Username)) {
        $client.Credentials = New-Object System.Net.NetworkCredential($Username, $Password)
    } else {
        $client.UseDefaultCredentials = $false
    }
    $msg = New-Object System.Net.Mail.MailMessage
    $msg.From = $FromAddress
    $msg.To.Add($ToAddress)
    $msg.Subject = $Subject
    $msg.Body = $Body
    $msg.IsBodyHtml = $true

    $disposeAttach = $false
    if (-not [string]::IsNullOrWhiteSpace($AttachmentPath) -and (Test-Path -LiteralPath $AttachmentPath -ErrorAction SilentlyContinue)) {
        $att = New-Object System.Net.Mail.Attachment($AttachmentPath)
        $msg.Attachments.Add($att)
        $disposeAttach = $true
    }
    try {
        $client.Send($msg)
        Write-Log "Email sent to $ToAddress via $SmtpServer"
    } finally {
        if ($disposeAttach) { $att.Dispose() }
        $msg.Dispose()
        $client.Dispose()
    }
}

# -- PORTABLE EMAIL CONFIG: AES-256-CBC + PBKDF2 --------------------------------
# Key derived from user passphrase via PBKDF2-SHA1 (100,000 iterations).
# Machine-independent -- config file travels with the script on USB/share.
# Plaintext fields stored in JSON; only the SMTP password is encrypted.
# Format: Base64( Salt(16) + IV(16) + CipherText )
# -------------------------------------------------------------------------

function Protect-ConfigPassword {
    param([string]$PlainText, [string]$Passphrase)
    $salt = New-Object byte[] 16
    $rng  = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $rng.GetBytes($salt)
    $rng.Dispose()
    $deriv = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Passphrase, $salt, 100000)
    $key   = $deriv.GetBytes(32)
    $iv    = $deriv.GetBytes(16)
    $deriv.Dispose()
    $aes           = [System.Security.Cryptography.Aes]::Create()
    $aes.Key       = $key
    $aes.IV        = $iv
    $aes.Mode      = 'CBC'
    $aes.Padding   = 'PKCS7'
    $enc    = $aes.CreateEncryptor()
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $cipher = $enc.TransformFinalBlock($bytes, 0, $bytes.Length)
    $enc.Dispose(); $aes.Dispose()
    $blob = New-Object byte[] (16 + 16 + $cipher.Length)
    [Array]::Copy($salt,   0, $blob,  0, 16)
    [Array]::Copy($iv,     0, $blob, 16, 16)
    [Array]::Copy($cipher, 0, $blob, 32, $cipher.Length)
    return [Convert]::ToBase64String($blob)
}

function Unprotect-ConfigPassword {
    param([string]$Base64Blob, [string]$Passphrase)
    try {
        $blob  = [Convert]::FromBase64String($Base64Blob)
        $salt  = $blob[0..15]
        $iv    = $blob[16..31]
        $cipher = $blob[32..($blob.Length - 1)]
        $deriv = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Passphrase, $salt, 100000)
        $key   = $deriv.GetBytes(32)
        $deriv.Dispose()
        $aes           = [System.Security.Cryptography.Aes]::Create()
        $aes.Key       = $key
        $aes.IV        = $iv
        $aes.Mode      = 'CBC'
        $aes.Padding   = 'PKCS7'
        $dec   = $aes.CreateDecryptor()
        $plain = $dec.TransformFinalBlock($cipher, 0, $cipher.Length)
        $dec.Dispose(); $aes.Dispose()
        return [System.Text.Encoding]::UTF8.GetString($plain)
    } catch {
        return $null
    }
}

function Get-ConfigPassphrase {
    param([string]$PromptText)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Config Passphrase'
    $dlg.Size = New-Object System.Drawing.Size(360, 150)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $script:C_BG2
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $PromptText
    $lbl.Location = New-Object System.Drawing.Point(10, 12)
    $lbl.Size = New-Object System.Drawing.Size(330, 36)
    $lbl.ForeColor = $script:C_TEXT
    $lbl.Font = $script:FONT_UI
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.PasswordChar = '*'
    $tb.Location = New-Object System.Drawing.Point(10, 54)
    $tb.Size = New-Object System.Drawing.Size(325, 22)
    $tb.BackColor = $script:C_BG2
    $tb.ForeColor = $script:C_TEXT
    $btnOk = New-ThemedButton 'OK' 125 86 80 26 $true
    $btnOk.DialogResult = 'OK'
    $dlg.Controls.AddRange(@($lbl, $tb, $btnOk))
    $dlg.AcceptButton = $btnOk
    if ($dlg.ShowDialog() -eq 'OK' -and $tb.Text.Length -gt 0) { return $tb.Text }
    return $null
}

function Save-EmailConfig {
    $pass = Get-ConfigPassphrase 'Enter a passphrase to encrypt the config (you will need this to load it on another machine):'
    if ($null -eq $pass) { return }
    $smtpPass = Get-SmtpPassword
    if ($null -eq $smtpPass) { return }
    $encPass = if ($smtpPass.Length -gt 0) { Protect-ConfigPassword $smtpPass $pass } else { '' }
    $cfg = [ordered]@{
        SmtpServer   = $txtWlanSmtpServer.Text
        SmtpPort     = $txtWlanSmtpPort.Text
        TlsEnabled   = $chkWlanTls.Checked
        FromAddress  = $txtWlanFrom.Text
        SmtpUser     = $txtWlanSmtpUser.Text
        ToAddress    = $txtWlanTo.Text
        EncPassword  = $encPass
        ProviderIdx  = $cboWlanProvider.SelectedIndex
    }
    try {
        $json = $cfg | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText($script:ConfigFile, $json, [System.Text.Encoding]::UTF8)
        Write-Log "Email config saved to $script:ConfigFile"
        [System.Windows.Forms.MessageBox]::Show("Config saved.`n$script:ConfigFile", 'Saved', 'OK', 'Information')
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Save failed: $_", 'Error', 'OK', 'Error')
    }
}

function Load-EmailConfig {
    if (-not [System.IO.File]::Exists($script:ConfigFile)) {
        [System.Windows.Forms.MessageBox]::Show("No config file found at:`n$script:ConfigFile", 'Not Found', 'OK', 'Warning')
        return
    }
    $pass = Get-ConfigPassphrase 'Enter the passphrase used when saving this config:'
    if ($null -eq $pass) { return }
    try {
        $json = [System.IO.File]::ReadAllText($script:ConfigFile, [System.Text.Encoding]::UTF8)
        $cfg  = $json | ConvertFrom-Json
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to read config: $_", 'Error', 'OK', 'Error')
        return
    }
    # Decrypt password
    $plainPass = ''
    if ($cfg.EncPassword -and $cfg.EncPassword.Length -gt 0) {
        $plainPass = Unprotect-ConfigPassword $cfg.EncPassword $pass
        if ($null -eq $plainPass) {
            [System.Windows.Forms.MessageBox]::Show("Wrong passphrase or corrupted config.", 'Error', 'OK', 'Error')
            return
        }
    }
    # Populate WLAN fields
    $txtWlanSmtpServer.Text  = $cfg.SmtpServer
    $txtWlanSmtpPort.Text    = $cfg.SmtpPort
    $chkWlanTls.Checked      = [bool]$cfg.TlsEnabled
    $txtWlanFrom.Text        = $cfg.FromAddress
    $txtWlanSmtpUser.Text    = $cfg.SmtpUser
    $txtWlanTo.Text          = $cfg.ToAddress
    if ($cfg.ProviderIdx -ge 0 -and $cfg.ProviderIdx -lt $cboWlanProvider.Items.Count) {
        $cboWlanProvider.SelectedIndex = $cfg.ProviderIdx
    }
    # Populate LAN fields (same SMTP settings)
    $txtLanSmtpServer.Text   = $cfg.SmtpServer
    $txtLanSmtpPort.Text     = $cfg.SmtpPort
    $chkLanTls.Checked       = [bool]$cfg.TlsEnabled
    $txtLanFrom.Text         = $cfg.FromAddress
    $txtLanSmtpUser.Text     = $cfg.SmtpUser
    $txtLanTo.Text           = $cfg.ToAddress
    if ($cfg.ProviderIdx -ge 0 -and $cfg.ProviderIdx -lt $cboLanProvider.Items.Count) {
        $cboLanProvider.SelectedIndex = $cfg.ProviderIdx
    }
    # Store decrypted password in session for Send operations
    $script:SessionSmtpPass = $plainPass
    Write-Log "Email config loaded from $script:ConfigFile"
    [System.Windows.Forms.MessageBox]::Show("Config loaded successfully.", 'Loaded', 'OK', 'Information')
}

# -------------------------------------------------------------------------

function Get-SmtpPassword {
    # Return cached session password if loaded from config
    if ($null -ne $script:SessionSmtpPass) { return $script:SessionSmtpPass }
    # Simple modal password dialog
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'SMTP Password'
    $dlg.Size = New-Object System.Drawing.Size(340, 140)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $script:C_BG2
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'SMTP password (leave blank for unauthenticated relay):'
    $lbl.Location = New-Object System.Drawing.Point(10, 12)
    $lbl.Size = New-Object System.Drawing.Size(310, 32)
    $lbl.ForeColor = $script:C_TEXT
    $lbl.Font = $script:FONT_UI

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.PasswordChar = '*'
    $tb.Location = New-Object System.Drawing.Point(10, 50)
    $tb.Size = New-Object System.Drawing.Size(305, 22)
    $tb.BackColor = $script:C_BG2
    $tb.ForeColor = $script:C_TEXT

    $btnOk = New-ThemedButton "OK" 115 80 80 26 $true
    $btnOk.DialogResult = 'OK'
    $dlg.Controls.AddRange(@($lbl, $tb, $btnOk))
    $dlg.AcceptButton = $btnOk
    if ($dlg.ShowDialog() -eq 'OK') { return $tb.Text }
    return $null
}
# ---------------------------------------------------------------------------

# -- MAIN FORM ----------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Paladin Network Pro v3.1 | $env:COMPUTERNAME"
$form.Size = New-Object System.Drawing.Size(1240, 740)
$form.MinimumSize = New-Object System.Drawing.Size(1200, 700)
$form.StartPosition = "CenterScreen"
$form.BackColor = $script:C_BG
$form.ForeColor = $script:C_TEXT
$form.Font = $script:FONT_UI

# Header strip
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Location = New-Object System.Drawing.Point(0, 0)
$pnlHeader.Size = New-Object System.Drawing.Size(1240, 45)
$pnlHeader.BackColor = $script:C_BLUE
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$siteDisplay = if ($SiteName) { $SiteName } else { $env:CS_PROFILE_NAME }
if (-not $siteDisplay) { $siteDisplay = $env:COMPUTERNAME }
$lblTitle.Text = "  Network Pro  |  $siteDisplay  |  $env:COMPUTERNAME"
$lblTitle.Location = New-Object System.Drawing.Point(0, 0)
$lblTitle.Size = New-Object System.Drawing.Size(800, 45)
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$lblTitle.TextAlign = 'MiddleLeft'
$pnlHeader.Controls.Add($lblTitle)

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = "v3.1  |  Paladin Business Consulting"
$lblVersion.Location = New-Object System.Drawing.Point(810, 0)
$lblVersion.Size = New-Object System.Drawing.Size(400, 45)
$lblVersion.ForeColor = $script:C_SUBTEXT
$lblVersion.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$lblVersion.TextAlign = 'MiddleRight'
$pnlHeader.Controls.Add($lblVersion)

# Tab Control
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Location = New-Object System.Drawing.Point(10, 52)
$tabControl.Size = New-Object System.Drawing.Size(1210, 660)
$tabControl.Appearance = 'Normal'
$tabControl.DrawMode = 'Normal'
$tabControl.BackColor = $script:C_BG
$tabControl.Font = $script:FONT_UI
$form.Controls.Add($tabControl)

# ============================================================
# TAB: OVERVIEW
# ============================================================
$tabOverview = New-Object System.Windows.Forms.TabPage
$tabOverview.Text = "Overview"
Apply-ThemedTab $tabOverview
$tabControl.Controls.Add($tabOverview)

$lblStatus = New-ThemedLabel "Initializing..." 10 10 900 24 $true
$lblStatus.ForeColor = $script:C_GREEN
$tabOverview.Controls.Add($lblStatus)

$btnRefreshOverview = New-ThemedButton "Refresh" 1000 8 90 28 $false
$tabOverview.Controls.Add($btnRefreshOverview)

$lblAdapterInfo = New-ThemedLabel "" 10 40 1050 20
$tabOverview.Controls.Add($lblAdapterInfo)

$pnlIPBar = New-Object System.Windows.Forms.Panel
$pnlIPBar.Location = New-Object System.Drawing.Point(10, 65)
$pnlIPBar.Size = New-Object System.Drawing.Size(1185, 32)
$pnlIPBar.BackColor = $script:C_BLUE
$tabOverview.Controls.Add($pnlIPBar)

$lblExternalIP = New-Object System.Windows.Forms.Label
$lblExternalIP.Location = New-Object System.Drawing.Point(6, 0)
$lblExternalIP.Size = New-Object System.Drawing.Size(750, 32)
$lblExternalIP.ForeColor = $script:C_GREEN
$lblExternalIP.Font = $script:FONT_BOLD
$lblExternalIP.Text = "External IP: Checking..."
$lblExternalIP.TextAlign = 'MiddleLeft'
$pnlIPBar.Controls.Add($lblExternalIP)

$btnRefreshIP = New-ThemedButton "Refresh IP" 760 4 90 24
$pnlIPBar.Controls.Add($btnRefreshIP)

$btnCopyIP = New-ThemedButton "Copy" 858 4 60 24 $true
$pnlIPBar.Controls.Add($btnCopyIP)

$gridAdapters = New-ThemedGrid 10 104 1185 490
[void]$gridAdapters.Columns.Add("Name",    "Adapter")
[void]$gridAdapters.Columns.Add("Type",    "Type")
[void]$gridAdapters.Columns.Add("Speed",   "Speed")
[void]$gridAdapters.Columns.Add("IPv4",    "IPv4")
[void]$gridAdapters.Columns.Add("IPv6",    "IPv6")
[void]$gridAdapters.Columns.Add("MAC",     "MAC")
[void]$gridAdapters.Columns.Add("Gateway", "Gateway")
[void]$gridAdapters.Columns.Add("Subnet",  "Subnet")
[void]$gridAdapters.Columns.Add("DNS",     "DNS")
$tabOverview.Controls.Add($gridAdapters)

# ============================================================
# TAB: SPEED TEST
# ============================================================
$tabSpeedTest = New-Object System.Windows.Forms.TabPage
$tabSpeedTest.Text = "Speed Test"
Apply-ThemedTab $tabSpeedTest
$tabControl.Controls.Add($tabSpeedTest)

$lblSpeedTestInfo = New-ThemedLabel "Internet Speed Test - Powered by Ookla Speedtest" 10 10 600 28 $true
$lblSpeedTestInfo.ForeColor = $script:C_TEXT
$tabSpeedTest.Controls.Add($lblSpeedTestInfo)

$btnRunSpeedtest    = New-ThemedButton "Run Speed Test (CLI)" 10 45 180 38 $true
$btnWebSpeedtest    = New-ThemedButton "Open Speedtest.net"   200 45 160 38
$btnInstallSpeedtest = New-ThemedButton "Install CLI"         370 45 110 38
$tabSpeedTest.Controls.Add($btnRunSpeedtest)
$tabSpeedTest.Controls.Add($btnWebSpeedtest)
$tabSpeedTest.Controls.Add($btnInstallSpeedtest)

$lblSpeedtestStatus = New-ThemedLabel "" 490 52 600 24
$tabSpeedTest.Controls.Add($lblSpeedtestStatus)

$pnlSpeedResults = New-Object System.Windows.Forms.Panel
$pnlSpeedResults.Location = New-Object System.Drawing.Point(10, 95)
$pnlSpeedResults.Size = New-Object System.Drawing.Size(1185, 165)
$pnlSpeedResults.BackColor = $script:C_BG2
$tabSpeedTest.Controls.Add($pnlSpeedResults)

$lblDLLabel = New-ThemedLabel "DOWNLOAD" 20 12 150 16
$lblDLLabel.ForeColor = $script:C_SUBTEXT
$pnlSpeedResults.Controls.Add($lblDLLabel)

$lblDownloadSpeed = New-Object System.Windows.Forms.Label
$lblDownloadSpeed.Text = "--"
$lblDownloadSpeed.Location = New-Object System.Drawing.Point(20, 28)
$lblDownloadSpeed.Size = New-Object System.Drawing.Size(280, 45)
$lblDownloadSpeed.Font = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Bold)
$lblDownloadSpeed.ForeColor = $script:C_GREEN
$pnlSpeedResults.Controls.Add($lblDownloadSpeed)

$lblULLabel = New-ThemedLabel "UPLOAD" 20 80 150 16
$lblULLabel.ForeColor = $script:C_SUBTEXT
$pnlSpeedResults.Controls.Add($lblULLabel)

$lblUploadSpeed = New-Object System.Windows.Forms.Label
$lblUploadSpeed.Text = "--"
$lblUploadSpeed.Location = New-Object System.Drawing.Point(20, 96)
$lblUploadSpeed.Size = New-Object System.Drawing.Size(280, 45)
$lblUploadSpeed.Font = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Bold)
$lblUploadSpeed.ForeColor = [System.Drawing.Color]::FromArgb(100, 180, 255)
$pnlSpeedResults.Controls.Add($lblUploadSpeed)

$lblPingLabel = New-ThemedLabel "LATENCY" 320 12 150 16
$lblPingLabel.ForeColor = $script:C_SUBTEXT
$pnlSpeedResults.Controls.Add($lblPingLabel)

$lblPing = New-Object System.Windows.Forms.Label
$lblPing.Text = "--"
$lblPing.Location = New-Object System.Drawing.Point(320, 28)
$lblPing.Size = New-Object System.Drawing.Size(200, 45)
$lblPing.Font = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Bold)
$lblPing.ForeColor = $script:C_YELLOW
$pnlSpeedResults.Controls.Add($lblPing)

$lblServer = New-ThemedLabel "Server: --"   580 20 480 20
$lblISP    = New-ThemedLabel "ISP: --"      580 45 480 20
$lblIP     = New-ThemedLabel "IP: --"       580 70 480 20
$pnlSpeedResults.Controls.Add($lblServer)
$pnlSpeedResults.Controls.Add($lblISP)
$pnlSpeedResults.Controls.Add($lblIP)

$txtSpeedTestOutput = New-ThemedTextBox 10 270 1185 345 $true $true
$tabSpeedTest.Controls.Add($txtSpeedTestOutput)

# ============================================================
# TAB: MULTI-PING
# ============================================================
$tabMultiPing = New-Object System.Windows.Forms.TabPage
$tabMultiPing.Text = "Multi-Ping"
Apply-ThemedTab $tabMultiPing
$tabControl.Controls.Add($tabMultiPing)

$lblTargetList = New-ThemedLabel "Targets (one per line):" 10 10 180 20
$tabMultiPing.Controls.Add($lblTargetList)

$txtTargets = New-ThemedTextBox 10 35 200 150 $true
$txtTargets.Text = "8.8.8.8`r`n1.1.1.1`r`ngoogle.com`r`ncloudflare.com"
$tabMultiPing.Controls.Add($txtTargets)

$btnAddTargets   = New-ThemedButton "Load Targets"    10 195  95 28
$btnClearTargets = New-ThemedButton "Clear"          115 195  95 28 $true
$tabMultiPing.Controls.Add($btnAddTargets)
$tabMultiPing.Controls.Add($btnClearTargets)

$lblPingInterval = New-ThemedLabel "Interval (sec):" 10 236 95 20
$tabMultiPing.Controls.Add($lblPingInterval)

$numPingInterval = New-Object System.Windows.Forms.NumericUpDown
$numPingInterval.Location = New-Object System.Drawing.Point(105, 234)
$numPingInterval.Size = New-Object System.Drawing.Size(60, 22)
$numPingInterval.Minimum = 1
$numPingInterval.Maximum = 300
$numPingInterval.Value = 5
$numPingInterval.BackColor = $script:C_BG2
$numPingInterval.ForeColor = $script:C_TEXT
$tabMultiPing.Controls.Add($numPingInterval)

$chkContinuous = New-Object System.Windows.Forms.CheckBox
$chkContinuous.Text = "Continuous"
$chkContinuous.Location = New-Object System.Drawing.Point(10, 264)
$chkContinuous.Size = New-Object System.Drawing.Size(150, 20)
$chkContinuous.Checked = $true
$chkContinuous.ForeColor = $script:C_TEXT
$tabMultiPing.Controls.Add($chkContinuous)

$btnStartPing = New-ThemedButton "Start Multi-Ping" 10 295 200 35 $true
$btnExportCSV = New-ThemedButton "Export to CSV"    10 340 200 28
$tabMultiPing.Controls.Add($btnStartPing)
$tabMultiPing.Controls.Add($btnExportCSV)

$gridPingResults = New-ThemedGrid 220 10 875 600
[void]$gridPingResults.Columns.Add("Target",       "Target")
[void]$gridPingResults.Columns.Add("Status",        "Status")
[void]$gridPingResults.Columns.Add("ResponseTime",  "Response (ms)")
[void]$gridPingResults.Columns.Add("PacketsSent",   "Sent")
[void]$gridPingResults.Columns.Add("PacketsRecv",   "Received")
[void]$gridPingResults.Columns.Add("PacketLoss",    "Loss %")
[void]$gridPingResults.Columns.Add("LastUpdate",    "Last Update")
$tabMultiPing.Controls.Add($gridPingResults)

# ============================================================
# TAB: DNS & WHOIS
# ============================================================
$tabDNS = New-Object System.Windows.Forms.TabPage
$tabDNS.Text = "DNS & WHOIS"
Apply-ThemedTab $tabDNS
$tabControl.Controls.Add($tabDNS)

$lblDomain = New-ThemedLabel "Domain/IP:" 10 14 70 20
$tabDNS.Controls.Add($lblDomain)

$txtDomain = New-ThemedTextBox 85 12 220 22
$txtDomain.Text = "google.com"
$tabDNS.Controls.Add($txtDomain)

$btnDNSLookup = New-ThemedButton "DNS Lookup"  315 10 110 25
$btnWHOIS     = New-ThemedButton "WHOIS"       435 10 90  25
$btnMXRecords = New-ThemedButton "MX Records"  535 10 110 25
$btnSSLCert   = New-ThemedButton "SSL Cert"    655 10 90  25
$btnFlushDNS  = New-ThemedButton "Flush DNS"   755 10 95  25 $true
$tabDNS.Controls.Add($btnDNSLookup)
$tabDNS.Controls.Add($btnWHOIS)
$tabDNS.Controls.Add($btnMXRecords)
$tabDNS.Controls.Add($btnSSLCert)
$tabDNS.Controls.Add($btnFlushDNS)

$txtDNSResults = New-ThemedTextBox 10 44 1185 575 $true $true
$tabDNS.Controls.Add($txtDNSResults)

# ============================================================
# TAB: PORT SCAN & TRACEROUTE
# ============================================================
$tabScan = New-Object System.Windows.Forms.TabPage
$tabScan.Text = "Scan & Trace"
Apply-ThemedTab $tabScan
$tabControl.Controls.Add($tabScan)

$lblScanTarget = New-ThemedLabel "Target:" 10 14 50 20
$tabScan.Controls.Add($lblScanTarget)

$txtScanTarget = New-ThemedTextBox 65 12 220 22
$txtScanTarget.Text = "google.com"
$tabScan.Controls.Add($txtScanTarget)

$lblPorts = New-ThemedLabel "Ports:" 295 14 40 20
$tabScan.Controls.Add($lblPorts)

$txtPorts = New-ThemedTextBox 340 12 160 22
$txtPorts.Text = "80,443,22,3389"
$tabScan.Controls.Add($txtPorts)

$btnQuickScan  = New-ThemedButton "Quick Scan"  510 10 110 25
$btnTraceroute = New-ThemedButton "Traceroute"  630 10 110 25
$btnPathPing   = New-ThemedButton "PathPing"    750 10 100 25 $true
$tabScan.Controls.Add($btnQuickScan)
$tabScan.Controls.Add($btnTraceroute)
$tabScan.Controls.Add($btnPathPing)

$txtScanResults = New-ThemedTextBox 10 44 1185 575 $true $true
$tabScan.Controls.Add($txtScanResults)

# ============================================================
# TAB: NETWORK ACTIONS
# ============================================================
$tabActions = New-Object System.Windows.Forms.TabPage
$tabActions.Text = "Net Actions"
Apply-ThemedTab $tabActions
$tabControl.Controls.Add($tabActions)

$btnARPTable     = New-ThemedButton "ARP Table"      10 10 110 30
$btnNetstat      = New-ThemedButton "Netstat -ano"  130 10 120 30
$btnRouteTable   = New-ThemedButton "Route Print"   260 10 110 30
$btnIPConfig     = New-ThemedButton "IPConfig /all" 380 10 110 30
$btnReleaseRenew = New-ThemedButton "Release/Renew" 500 10 120 30
$btnResetWinsock = New-ThemedButton "Reset Winsock" 630 10 120 30
$btnResetIP      = New-ThemedButton "Reset IP Stack" 760 10 120 30 $true
$tabActions.Controls.Add($btnARPTable)
$tabActions.Controls.Add($btnNetstat)
$tabActions.Controls.Add($btnRouteTable)
$tabActions.Controls.Add($btnIPConfig)
$tabActions.Controls.Add($btnReleaseRenew)
$tabActions.Controls.Add($btnResetWinsock)
$tabActions.Controls.Add($btnResetIP)

$txtActionsResults = New-ThemedTextBox 10 50 1185 575 $true $true
$tabActions.Controls.Add($txtActionsResults)

# ============================================================
# TAB: INTERNET REPAIR
# ============================================================
$tabRepair = New-Object System.Windows.Forms.TabPage
$tabRepair.Text = "Net Repair"
Apply-ThemedTab $tabRepair
$tabControl.Controls.Add($tabRepair)

$lblRepairInfo = New-ThemedLabel "Complete Internet Repair - Fix common network and connectivity issues" 10 10 1050 22 $true
$lblRepairInfo.ForeColor = $script:C_YELLOW
$tabRepair.Controls.Add($lblRepairInfo)

$btnRepairWinsock   = New-ThemedButton "Reset Winsock"         10 40 155 34
$btnRepairTCPIP     = New-ThemedButton "Reset TCP/IP"         175 40 155 34
$btnRepairFlushDNS  = New-ThemedButton "Flush DNS"            340 40 140 34
$btnRepairRenewIP   = New-ThemedButton "Release/Renew IP"     490 40 155 34
$btnRepairProxy     = New-ThemedButton "Reset Proxy"          655 40 140 34
$btnRepairFirewall  = New-ThemedButton "Reset Firewall"        10 85 155 34
$btnRepairHosts     = New-ThemedButton "Restore Hosts File"   175 85 170 34
$btnRepairARP       = New-ThemedButton "Clear ARP Cache"      355 85 140 34
$btnRepairNetBIOS   = New-ThemedButton "Reset NetBIOS"        505 85 140 34
$btnRepairIE        = New-ThemedButton "Reset IE/Edge"        655 85 140 34
$tabRepair.Controls.Add($btnRepairWinsock)
$tabRepair.Controls.Add($btnRepairTCPIP)
$tabRepair.Controls.Add($btnRepairFlushDNS)
$tabRepair.Controls.Add($btnRepairRenewIP)
$tabRepair.Controls.Add($btnRepairProxy)
$tabRepair.Controls.Add($btnRepairFirewall)
$tabRepair.Controls.Add($btnRepairHosts)
$tabRepair.Controls.Add($btnRepairARP)
$tabRepair.Controls.Add($btnRepairNetBIOS)
$tabRepair.Controls.Add($btnRepairIE)

$btnCompleteRepair = New-ThemedButton "COMPLETE INTERNET REPAIR (Run All)" 10 130 800 42 $true
$tabRepair.Controls.Add($btnCompleteRepair)

$txtRepairResults = New-ThemedTextBox 10 183 1185 440 $true $true
$tabRepair.Controls.Add($txtRepairResults)

# ============================================================
# TAB: WLAN REPORT
# ============================================================
$tabWlan = New-Object System.Windows.Forms.TabPage
$tabWlan.Text = "WLAN Report"
Apply-ThemedTab $tabWlan
$tabControl.Controls.Add($tabWlan)

$lblWlanInfo = New-ThemedLabel "Windows Wireless Network Report  |  netsh wlan show wlanreport" 10 10 800 22 $true
$lblWlanInfo.ForeColor = $script:C_YELLOW
$tabWlan.Controls.Add($lblWlanInfo)

# Action buttons row
$btnWlanGenerate  = New-ThemedButton "Generate Report"   10 40 150 34 $true
$btnWlanOpen      = New-ThemedButton "Open in Browser"  170 40 140 34
$btnWlanSave      = New-ThemedButton "Save Report"      320 40 120 34
$btnWlanExport    = New-ThemedButton "Export Report"    450 40 120 34
$btnWlanViewLog   = New-ThemedButton "View Log"         580 40 90  34
$btnWlanOpen.Enabled    = $false
$btnWlanSave.Enabled    = $false
$btnWlanExport.Enabled  = $false
$tabWlan.Controls.Add($btnWlanGenerate)
$tabWlan.Controls.Add($btnWlanOpen)
$tabWlan.Controls.Add($btnWlanSave)
$tabWlan.Controls.Add($btnWlanExport)
$tabWlan.Controls.Add($btnWlanViewLog)

# Email section
# Email panel -- SMTP (no Outlook dependency)
$pnlWlanEmail = New-Object System.Windows.Forms.Panel
$pnlWlanEmail.Location = New-Object System.Drawing.Point(10, 84)
$pnlWlanEmail.Size = New-Object System.Drawing.Size(1185, 90)
$pnlWlanEmail.BackColor = $script:C_BG2
$tabWlan.Controls.Add($pnlWlanEmail)

$lblWlanEmailHdr = New-Object System.Windows.Forms.Label
$lblWlanEmailHdr.Text = "  Email Report Settings (SMTP)"
$lblWlanEmailHdr.Location = New-Object System.Drawing.Point(0, 0)
$lblWlanEmailHdr.Size = New-Object System.Drawing.Size(1185, 24)
$lblWlanEmailHdr.ForeColor = $script:C_SUBTEXT
$lblWlanEmailHdr.Font = $script:FONT_BOLD
$lblWlanEmailHdr.BackColor = $script:C_BLUE
$pnlWlanEmail.Controls.Add($lblWlanEmailHdr)

# Row 1: SMTP Server / Port / TLS / From / Provider preset
$lblWlanSmtp    = New-ThemedLabel "SMTP:"   6 30 40 20
$txtWlanSmtpServer = New-ThemedTextBox 50 28 200 22
$txtWlanSmtpServer.Text = ""
Set-TextBoxPlaceholder $txtWlanSmtpServer "smtp.office365.com"
$lblWlanPort    = New-ThemedLabel "Port:" 258 30 35 20
$txtWlanSmtpPort = New-ThemedTextBox 296 28 55 22
$txtWlanSmtpPort.Text = "587"
$chkWlanTls = New-Object System.Windows.Forms.CheckBox
$chkWlanTls.Text = "TLS"; $chkWlanTls.Checked = $true
$chkWlanTls.Location = New-Object System.Drawing.Point(358, 30)
$chkWlanTls.Size = New-Object System.Drawing.Size(52, 20)
$chkWlanTls.ForeColor = $script:C_TEXT
$lblWlanFrom    = New-ThemedLabel "From:" 416 30 40 20
$txtWlanFrom    = New-ThemedTextBox 458 28 230 22
Set-TextBoxPlaceholder $txtWlanFrom "sender@domain.com"

# Provider preset dropdown -- populates SMTP/Port/TLS automatically
$lblWlanProvider = New-ThemedLabel "Provider:" 695 30 62 20
$cboWlanProvider = New-ThemedCombo 760 28 175
$cboWlanProvider.Items.AddRange(@(
    "-- Select Provider --",
    "Gmail (smtp.gmail.com)",
    "Outlook / Office 365",
    "Yahoo Mail",
    "Hotmail / Live",
    "iCloud Mail",
    "Zoho Mail",
    "SendGrid",
    "Mailgun (SMTP)",
    "Custom / Manual"
))
$cboWlanProvider.SelectedIndex = 0

# SMTP provider presets: {Server, Port, TLS}
$script:WlanSmtpPresets = @{
    "Gmail (smtp.gmail.com)"   = @("smtp.gmail.com",      "587", $true)
    "Outlook / Office 365"     = @("smtp.office365.com",  "587", $true)
    "Yahoo Mail"               = @("smtp.mail.yahoo.com", "587", $true)
    "Hotmail / Live"           = @("smtp.live.com",       "587", $true)
    "iCloud Mail"              = @("smtp.mail.me.com",    "587", $true)
    "Zoho Mail"                = @("smtp.zoho.com",       "587", $true)
    "SendGrid"                 = @("smtp.sendgrid.net",   "587", $true)
    "Mailgun (SMTP)"           = @("smtp.mailgun.org",    "587", $true)
    "Custom / Manual"          = @("",                    "587", $true)
}

$cboWlanProvider.Add_SelectedIndexChanged({
    $sel = $cboWlanProvider.SelectedItem
    if ($script:WlanSmtpPresets.ContainsKey($sel)) {
        $p = $script:WlanSmtpPresets[$sel]
        if ($p[0]) { $txtWlanSmtpServer.Text = $p[0] } else { $txtWlanSmtpServer.Text = "" }
        $txtWlanSmtpPort.Text = $p[1]
        $chkWlanTls.Checked  = $p[2]
    }
})

$pnlWlanEmail.Controls.AddRange(@($lblWlanSmtp,$txtWlanSmtpServer,$lblWlanPort,$txtWlanSmtpPort,$chkWlanTls,$lblWlanFrom,$txtWlanFrom,$lblWlanProvider,$cboWlanProvider))

# Row 2: User / To / Schedule / buttons
$lblWlanUser    = New-ThemedLabel "User:"  6 58 38 20
$txtWlanSmtpUser = New-ThemedTextBox 46 56 180 22
Set-TextBoxPlaceholder $txtWlanSmtpUser "(blank = relay)"
$lblWlanTo      = New-ThemedLabel "To:"   232 58 24 20
$txtWlanTo      = New-ThemedTextBox 258 56 230 22
Set-TextBoxPlaceholder $txtWlanTo "tech@domain.com"

$lblWlanSchedule = New-ThemedLabel "Schedule:" 494 58 68 20
$cboWlanSchedule = New-ThemedCombo 565 56 190
$cboWlanSchedule.Items.AddRange(@("Daily - 6:00 AM","Daily - 8:00 AM","Weekly - Monday 6 AM","Every 4 Hours","Every 12 Hours","On System Startup"))
$cboWlanSchedule.SelectedIndex = 0

$btnWlanSendNow    = New-ThemedButton "Send Now"      762 54  90 26 $true
$btnWlanSchedule   = New-ThemedButton "Register Task" 858 54 120 26
$btnWlanSaveCfg    = New-ThemedButton "Save Config"   984 54  90 26
$btnWlanLoadCfg    = New-ThemedButton "Load Config"  1078 54  90 26
$pnlWlanEmail.Controls.AddRange(@($lblWlanUser,$txtWlanSmtpUser,$lblWlanTo,$txtWlanTo,$lblWlanSchedule,$cboWlanSchedule,$btnWlanSendNow,$btnWlanSchedule,$btnWlanSaveCfg,$btnWlanLoadCfg))

$lblWlanStatus = New-ThemedLabel "Ready." 10 200 900 20
$lblWlanStatus.ForeColor = $script:C_SUBTEXT
$tabWlan.Controls.Add($lblWlanStatus)

$txtWlanLog = New-ThemedTextBox 10 224 1185 400 $true $true
$tabWlan.Controls.Add($txtWlanLog)

# ============================================================
# TAB: LAN REPORT
# ============================================================
$tabLan = New-Object System.Windows.Forms.TabPage
$tabLan.Text = "LAN Report"
Apply-ThemedTab $tabLan
$tabControl.Controls.Add($tabLan)

$lblLanInfo = New-ThemedLabel "Wired LAN Diagnostic Report  |  Built-in PS data collection (no netsh lanreport equivalent exists in Windows)" 10 10 1050 22 $true
$lblLanInfo.ForeColor = $script:C_YELLOW
$tabLan.Controls.Add($lblLanInfo)

# Action buttons
$btnLanGenerate = New-ThemedButton "Generate LAN Report" 10 40 175 34 $true
$btnLanOpen     = New-ThemedButton "Open HTML Report"   195 40 150 34
$btnLanSave     = New-ThemedButton "Save Report"        355 40 120 34
$btnLanExport   = New-ThemedButton "Export Report"      485 40 120 34
$btnLanViewLog  = New-ThemedButton "View Log"           615 40 90  34
$btnLanOpen.Enabled   = $false
$btnLanSave.Enabled   = $false
$btnLanExport.Enabled = $false
$tabLan.Controls.Add($btnLanGenerate)
$tabLan.Controls.Add($btnLanOpen)
$tabLan.Controls.Add($btnLanSave)
$tabLan.Controls.Add($btnLanExport)
$tabLan.Controls.Add($btnLanViewLog)

# Email section (same structure as WLAN)
# Email panel -- SMTP
$pnlLanEmail = New-Object System.Windows.Forms.Panel
$pnlLanEmail.Location = New-Object System.Drawing.Point(10, 84)
$pnlLanEmail.Size = New-Object System.Drawing.Size(1185, 90)
$pnlLanEmail.BackColor = $script:C_BG2
$tabLan.Controls.Add($pnlLanEmail)

$lblLanEmailHdr = New-Object System.Windows.Forms.Label
$lblLanEmailHdr.Text = "  Email Report Settings (SMTP)"
$lblLanEmailHdr.Location = New-Object System.Drawing.Point(0, 0)
$lblLanEmailHdr.Size = New-Object System.Drawing.Size(1185, 24)
$lblLanEmailHdr.ForeColor = $script:C_SUBTEXT
$lblLanEmailHdr.Font = $script:FONT_BOLD
$lblLanEmailHdr.BackColor = $script:C_BLUE
$pnlLanEmail.Controls.Add($lblLanEmailHdr)

$lblLanSmtp     = New-ThemedLabel "SMTP:"   6 30 40 20
$txtLanSmtpServer = New-ThemedTextBox 50 28 200 22
Set-TextBoxPlaceholder $txtLanSmtpServer "smtp.office365.com"
$lblLanPort     = New-ThemedLabel "Port:" 258 30 35 20
$txtLanSmtpPort  = New-ThemedTextBox 296 28 55 22
$txtLanSmtpPort.Text = "587"
$chkLanTls = New-Object System.Windows.Forms.CheckBox
$chkLanTls.Text = "TLS"; $chkLanTls.Checked = $true
$chkLanTls.Location = New-Object System.Drawing.Point(358, 30)
$chkLanTls.Size = New-Object System.Drawing.Size(52, 20)
$chkLanTls.ForeColor = $script:C_TEXT
$lblLanFrom     = New-ThemedLabel "From:" 416 30 40 20
$txtLanFrom     = New-ThemedTextBox 458 28 230 22
Set-TextBoxPlaceholder $txtLanFrom "sender@domain.com"

# Provider preset dropdown -- populates SMTP/Port/TLS automatically
$lblLanProvider = New-ThemedLabel "Provider:" 695 30 62 20
$cboLanProvider = New-ThemedCombo 760 28 175
$cboLanProvider.Items.AddRange(@(
    "-- Select Provider --",
    "Gmail (smtp.gmail.com)",
    "Outlook / Office 365",
    "Yahoo Mail",
    "Hotmail / Live",
    "iCloud Mail",
    "Zoho Mail",
    "SendGrid",
    "Mailgun (SMTP)",
    "Custom / Manual"
))
$cboLanProvider.SelectedIndex = 0

$cboLanProvider.Add_SelectedIndexChanged({
    $sel = $cboLanProvider.SelectedItem
    if ($script:WlanSmtpPresets.ContainsKey($sel)) {
        $p = $script:WlanSmtpPresets[$sel]
        if ($p[0]) { $txtLanSmtpServer.Text = $p[0] } else { $txtLanSmtpServer.Text = "" }
        $txtLanSmtpPort.Text = $p[1]
        $chkLanTls.Checked  = $p[2]
    }
})

$pnlLanEmail.Controls.AddRange(@($lblLanSmtp,$txtLanSmtpServer,$lblLanPort,$txtLanSmtpPort,$chkLanTls,$lblLanFrom,$txtLanFrom,$lblLanProvider,$cboLanProvider))

$lblLanUser     = New-ThemedLabel "User:"   6 58 38 20
$txtLanSmtpUser  = New-ThemedTextBox 46 56 180 22
Set-TextBoxPlaceholder $txtLanSmtpUser "(blank = relay)"
$lblLanTo       = New-ThemedLabel "To:"   232 58 24 20
$txtLanTo       = New-ThemedTextBox 258 56 280 22
Set-TextBoxPlaceholder $txtLanTo "tech@domain.com"
$btnLanSendNow   = New-ThemedButton "Send Now"      545 54  90 26 $true
$btnLanSchedule  = New-ThemedButton "Register Task" 641 54 120 26
$btnLanSaveCfg   = New-ThemedButton "Save Config"   767 54  90 26
$btnLanLoadCfg   = New-ThemedButton "Load Config"   861 54  90 26
$pnlLanEmail.Controls.AddRange(@($lblLanUser,$txtLanSmtpUser,$lblLanTo,$txtLanTo,$btnLanSendNow,$btnLanSchedule,$btnLanSaveCfg,$btnLanLoadCfg))

$lblLanStatus = New-ThemedLabel "Ready." 10 200 900 20
$lblLanStatus.ForeColor = $script:C_SUBTEXT
$tabLan.Controls.Add($lblLanStatus)

$txtLanLog = New-ThemedTextBox 10 224 1185 400 $true $true
$tabLan.Controls.Add($txtLanLog)

# Hidden: store last LAN report HTML path
$script:LanReportPath = ""

# ============================================================
# TAB: PORTABLE TOOLS
# ============================================================
$tabTools = New-Object System.Windows.Forms.TabPage
$tabTools.Text = "Portable Tools"
Apply-ThemedTab $tabTools
$tabControl.Controls.Add($tabTools)

$gridTools = New-ThemedGrid 10 10 1185 560
[void]$gridTools.Columns.Add("Tool",   "Tool")
[void]$gridTools.Columns.Add("Status", "Status")
[void]$gridTools.Columns.Add("Path",   "Path")
$tabTools.Controls.Add($gridTools)

$btnLaunchTool   = New-ThemedButton "Launch Selected"     10 580 140 34 $true
$btnRefreshTools = New-ThemedButton "Refresh List"        160 580 120 34
$btnInstallTools = New-ThemedButton "Install All Tools"   290 580 145 34
$btnInstallNmap  = New-ThemedButton "Install NMAP + Zenmap" 445 580 175 34
$tabTools.Controls.Add($btnLaunchTool)
$tabTools.Controls.Add($btnRefreshTools)
$tabTools.Controls.Add($btnInstallTools)
$tabTools.Controls.Add($btnInstallNmap)

# ============================================================
# EVENT HANDLERS - OVERVIEW
# ============================================================
$btnRefreshIP.Add_Click({
    $lblExternalIP.Text      = "External IP: Checking..."
    $lblExternalIP.ForeColor = $script:C_YELLOW
    $btnRefreshIP.Enabled    = $false

    $ipSync = [Hashtable]::Synchronized(@{ IP = $null; Done = $false })
    $psIP = [System.Management.Automation.PowerShell]::Create(
        [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2())
    $null = $psIP.AddScript({
        param($sync)
        $ep = @('https://api.ipify.org','https://icanhazip.com','https://ifconfig.me/ip')
        foreach ($uri in $ep) {
            try {
                $r = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
                $ip = $r.Content.Trim()
                if ($ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { $sync.IP = $ip; break }
            } catch {}
        }
        if (-not $sync.IP) { $sync.IP = 'Unable to detect' }
        $sync.Done = $true
    }).AddParameters(@{ sync = $ipSync }) | Out-Null
    $psIP.BeginInvoke() | Out-Null

    $ipTimer = New-Object System.Windows.Forms.Timer
    $ipTimer.Interval = 300
    $ipTimer.Add_Tick({
        if (-not $ipSync.Done) { return }
        $ipTimer.Stop()
        $script:ExternalIP = $ipSync.IP
        $lblExternalIP.Text      = "External IP: $($ipSync.IP)"
        $lblExternalIP.ForeColor = if ($ipSync.IP -match '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}') { $script:C_GREEN } else { $script:C_RED }
        $btnRefreshIP.Enabled    = $true
        try { $psIP.Dispose() } catch {}
        Write-Log "External IP refreshed: $($ipSync.IP)"
    })
    $ipTimer.Start()
})

$btnCopyIP.Add_Click({
    if ($script:ExternalIP -match '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}') {
        [System.Windows.Forms.Clipboard]::SetText($script:ExternalIP)
        [System.Windows.Forms.MessageBox]::Show("Copied: $($script:ExternalIP)", "Copied")
    } else {
        [System.Windows.Forms.MessageBox]::Show("No valid IP to copy.", "Error")
    }
})

# ============================================================
# EVENT HANDLERS - SPEED TEST
# ============================================================
$btnRunSpeedtest.Add_Click({
    $speedtestPath = Get-ToolPath "speedtest"
    if (-not $speedtestPath) {
        $res = [System.Windows.Forms.MessageBox]::Show(
            "Speedtest CLI not found.`r`n`r`nYES - Install via package manager`r`nNO - Open speedtest.net in browser",
            "Speedtest Not Found","YesNoCancel","Question")
        if ($res -eq "Yes")  { $btnInstallSpeedtest.PerformClick() }
        elseif ($res -eq "No") { $btnWebSpeedtest.PerformClick() }
        return
    }
    $lblSpeedtestStatus.Text = "Running... (~30-60 sec)"
    $lblSpeedtestStatus.ForeColor = $script:C_YELLOW
    $txtSpeedTestOutput.Clear()
    $txtSpeedTestOutput.AppendText("Starting Ookla Speedtest CLI...`r`n`r`n")
    $btnRunSpeedtest.Enabled = $false
    $form.Refresh()
    try {
        # --progress=no suppresses the animated progress bar (frequent console writes
        # captured by 2>&1 add measurable overhead on slower connections).
        # Priority bump: start a background job to find and elevate speedtest.exe
        # immediately after the call operator spawns it. Fires once, then exits.
        $exeName = [System.IO.Path]::GetFileNameWithoutExtension($speedtestPath)
        $priJob = Start-Job -ScriptBlock {
            param($n)
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline) {
                $p = Get-Process -Name $n -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($p) {
                    try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch {}
                    break
                }
                Start-Sleep -Milliseconds 100
            }
        } -ArgumentList $exeName
        $output = & $speedtestPath --accept-license --accept-gdpr --progress=no 2>&1
        $null = $priJob | Wait-Job -Timeout 2 | Remove-Job -Force -ErrorAction SilentlyContinue
        $txtSpeedTestOutput.AppendText(($output | Out-String))
        $dlMatch  = $output | Select-String "Download:\s+(\d+\.?\d*)\s+Mbps"
        $ulMatch  = $output | Select-String "Upload:\s+(\d+\.?\d*)\s+Mbps"
        $pgMatch  = $output | Select-String "Latency:\s+(\d+\.?\d*)\s+ms"
        $svMatch  = $output | Select-String "Server:\s+(.+?)(?:\s+\(|$)"
        $ispMatch = $output | Select-String "ISP:\s+(.+?)$"
        $ipMatch  = $output | Select-String "IP Address:\s+(.+?)$"
        if ($dlMatch)  { $lblDownloadSpeed.Text = "$($dlMatch.Matches[0].Groups[1].Value) Mbps" }
        if ($ulMatch)  { $lblUploadSpeed.Text   = "$($ulMatch.Matches[0].Groups[1].Value) Mbps" }
        if ($pgMatch)  { $lblPing.Text          = "$($pgMatch.Matches[0].Groups[1].Value) ms" }
        if ($svMatch)  { $lblServer.Text = "Server: $($svMatch.Matches[0].Groups[1].Value.Trim())" }
        if ($ispMatch) { $lblISP.Text   = "ISP: $($ispMatch.Matches[0].Groups[1].Value.Trim())" }
        if ($ipMatch)  { $lblIP.Text    = "IP: $($ipMatch.Matches[0].Groups[1].Value.Trim())" }
        $lblSpeedtestStatus.Text = "Complete!"
        $lblSpeedtestStatus.ForeColor = $script:C_GREEN
        Write-Log "Speedtest completed"
    } catch {
        $txtSpeedTestOutput.AppendText("`r`nError: $($_.Exception.Message)")
        $lblSpeedtestStatus.Text = "Speed test failed."
        $lblSpeedtestStatus.ForeColor = $script:C_RED
        Write-Log "Speedtest failed: $($_.Exception.Message)" "ERROR"
    }
    $btnRunSpeedtest.Enabled = $true
})

$btnWebSpeedtest.Add_Click({ Start-Process "https://www.speedtest.net"; Write-Log "Opened speedtest.net" })

$btnInstallSpeedtest.Add_Click({
    $installScript = @'
$useWinget = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
$useChoco  = $null -ne (Get-Command choco  -ErrorAction SilentlyContinue)
if ($useWinget) {
    Write-Host "Installing Speedtest CLI via winget (Ookla.Speedtest.CLI)..." -ForegroundColor Cyan
    winget install --id Ookla.Speedtest.CLI --silent --accept-package-agreements --accept-source-agreements
} elseif ($useChoco) {
    Write-Host "Installing Speedtest CLI via Chocolatey..." -ForegroundColor Cyan
    choco install speedtest -y
} else {
    Write-Host "No package manager found. Downloading directly from Ookla..." -ForegroundColor Yellow
    $dest = "C:\Program Files\Ookla\Speedtest CLI"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $zip = "$env:TEMP\speedtest-cli.zip"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent','Mozilla/5.0')
        $wc.DownloadFile('https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip', $zip)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Write-Host "Installed to: $dest\speedtest.exe" -ForegroundColor Green
    } catch { Write-Host "Direct download failed: $($_.Exception.Message)" -ForegroundColor Red }
}
Write-Host "Done. Press any key to close..." -ForegroundColor Green
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
'@
    $tempScript = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "netpro_speedtest_$([System.IO.Path]::GetRandomFileName()).ps1")
    try {
        [System.IO.File]::WriteAllText($tempScript, $installScript, [System.Text.Encoding]::UTF8)
        Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$tempScript`"" -Verb RunAs
        [System.Windows.Forms.MessageBox]::Show("Installation started. Wait for the elevated window to finish, then click Refresh List.", "Installing")
        Write-Log "Started Speedtest CLI installation"
    } catch { [System.Windows.Forms.MessageBox]::Show("Failed: $($_.Exception.Message)", "Error") }
    $t = New-Object System.Windows.Forms.Timer; $t.Interval = 300000
    $t.Add_Tick({ try { if (Test-Path -LiteralPath $tempScript) { Remove-Item -LiteralPath $tempScript -Force -ErrorAction Stop } } catch {}; $t.Stop(); $t.Dispose() })
    $t.Start()
})

# ============================================================
# EVENT HANDLERS - MULTI-PING
# ============================================================
$btnAddTargets.Add_Click({
    $script:PingTargets.Clear()
    $gridPingResults.Rows.Clear()
    $targets = $txtTargets.Text -split "`r`n" | Where-Object { $_.Trim() -ne "" }
    foreach ($target in $targets) {
        $target = $target.Trim()
        if ($target) {
            [void]$script:PingTargets.Add(@{ Target = $target; Sent = 0; Received = 0; LastStatus = "Unknown"; LastTime = 0 })
            $idx = $gridPingResults.Rows.Add()
            $gridPingResults.Rows[$idx].Cells[0].Value = $target
            $gridPingResults.Rows[$idx].Cells[1].Value = "Ready"
            $gridPingResults.Rows[$idx].Cells[2].Value = "-"
            $gridPingResults.Rows[$idx].Cells[3].Value = 0
            $gridPingResults.Rows[$idx].Cells[4].Value = 0
            $gridPingResults.Rows[$idx].Cells[5].Value = "0%"
            $gridPingResults.Rows[$idx].Cells[6].Value = "-"
        }
    }
    Write-Log "Loaded $($script:PingTargets.Count) ping targets"
})

$btnClearTargets.Add_Click({
    $script:PingTargets.Clear(); $gridPingResults.Rows.Clear(); $txtTargets.Clear()
})

$btnStartPing.Add_Click({
    if (-not $script:PingActive) {
        if ($script:PingTargets.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Load targets first.", "No Targets"); return
        }
        $script:PingActive = $true
        $btnStartPing.Text = "Stop Multi-Ping"
        $btnStartPing.BackColor = $script:C_ACCENT
        $script:PingTimer = New-Object System.Windows.Forms.Timer
        $script:PingTimer.Interval = $numPingInterval.Value * 1000
        $script:PingTimer.Add_Tick({
            $pingSender = New-Object System.Net.NetworkInformation.Ping
            for ($i = 0; $i -lt $script:PingTargets.Count; $i++) {
                $ti = $script:PingTargets[$i]
                try {
                    $reply = $pingSender.Send($ti.Target, 1000)
                    $ti.Sent++
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $ti.Received++; $ti.LastStatus = "Online"; $ti.LastTime = $reply.RoundtripTime
                        $gridPingResults.Rows[$i].Cells[1].Value = "Online"
                        $gridPingResults.Rows[$i].Cells[2].Value = $reply.RoundtripTime
                        $gridPingResults.Rows[$i].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(20, 60, 30)
                        $gridPingResults.Rows[$i].DefaultCellStyle.ForeColor = $script:C_GREEN
                    } else {
                        $ti.LastStatus = "Offline"; $ti.LastTime = 0
                        $gridPingResults.Rows[$i].Cells[1].Value = "Offline"
                        $gridPingResults.Rows[$i].Cells[2].Value = "Timeout"
                        $gridPingResults.Rows[$i].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(60, 20, 20)
                        $gridPingResults.Rows[$i].DefaultCellStyle.ForeColor = $script:C_RED
                    }
                } catch {
                    $ti.Sent++; $ti.LastStatus = "Error"; $ti.LastTime = 0
                    $gridPingResults.Rows[$i].Cells[1].Value = "Error"
                    $gridPingResults.Rows[$i].Cells[2].Value = "Error"
                    $gridPingResults.Rows[$i].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(60, 20, 20)
                    $gridPingResults.Rows[$i].DefaultCellStyle.ForeColor = $script:C_RED
                }
                $loss = if ($ti.Sent -gt 0) { [math]::Round((($ti.Sent - $ti.Received) / $ti.Sent) * 100, 2) } else { 0 }
                $gridPingResults.Rows[$i].Cells[3].Value = $ti.Sent
                $gridPingResults.Rows[$i].Cells[4].Value = $ti.Received
                $gridPingResults.Rows[$i].Cells[5].Value = "$loss%"
                $gridPingResults.Rows[$i].Cells[6].Value = Get-Date -Format "HH:mm:ss"
            }
            try { $pingSender.Dispose() } catch {}
        })
        $script:PingTimer.Start()
        Write-Log "Multi-ping started for $($script:PingTargets.Count) targets"
    } else {
        if ($script:PingTimer) { $script:PingTimer.Stop() }
        $script:PingActive = $false
        $btnStartPing.Text = "Start Multi-Ping"
        $btnStartPing.BackColor = $script:C_BLUE
        Write-Log "Multi-ping stopped"
    }
})

$btnExportCSV.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "CSV files (*.csv)|*.csv"
    $dlg.FileName = "ping_results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    if ($dlg.ShowDialog() -eq "OK") {
        $csv = "Target,Status,ResponseTime,Sent,Received,Loss,LastUpdate`r`n"
        for ($i = 0; $i -lt $gridPingResults.Rows.Count; $i++) {
            $row = $gridPingResults.Rows[$i]
            $csv += "$($row.Cells[0].Value),$($row.Cells[1].Value),$($row.Cells[2].Value),$($row.Cells[3].Value),$($row.Cells[4].Value),$($row.Cells[5].Value),$($row.Cells[6].Value)`r`n"
        }
        [System.IO.File]::WriteAllText($dlg.FileName, $csv, [System.Text.Encoding]::UTF8)
        [System.Windows.Forms.MessageBox]::Show("Exported to: $($dlg.FileName)", "Done")
        Write-Log "Exported ping results: $($dlg.FileName)"
    }
})

# ============================================================
# EVENT HANDLERS - DNS & WHOIS
# ============================================================
$btnDNSLookup.Add_Click({
    try {
        $domain = $txtDomain.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($domain) -or $domain -notmatch '^[a-zA-Z0-9.\-]+$') { $txtDNSResults.Text = "Invalid domain."; return }
        $txtDNSResults.Text = "DNS Lookup: $domain`r`n$("=" * 50)`r`n"
        $result = Resolve-DnsName -Name $domain -ErrorAction Stop
        foreach ($r in $result) {
            $txtDNSResults.AppendText("Type: $($r.Type) | Name: $($r.Name)")
            if ($r.IPAddress) { $txtDNSResults.AppendText(" | IP: $($r.IPAddress)") }
            if ($r.NameHost)  { $txtDNSResults.AppendText(" | Host: $($r.NameHost)") }
            $txtDNSResults.AppendText("`r`n")
        }
    } catch { $txtDNSResults.Text = "DNS Lookup failed: $($_.Exception.Message)" }
})

$btnWHOIS.Add_Click({
    $domain = $txtDomain.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($domain) -or $domain -notmatch '^[a-zA-Z0-9.\-]+$') { $txtDNSResults.Text = "Invalid domain."; return }
    $client = $stream = $writer = $reader = $null
    try {
        $txtDNSResults.Text = "WHOIS: $domain`r`n$("=" * 50)`r`n"
        $whoisServer = "whois.iana.org"
        if ($domain -match "\.(com|net|org|info|biz)$") { $whoisServer = "whois.verisign-grs.com" }
        elseif ($domain -match "\.io$")     { $whoisServer = "whois.nic.io" }
        elseif ($domain -match "\.co\.uk$") { $whoisServer = "whois.nic.uk" }
        $txtDNSResults.AppendText("Querying $whoisServer...`r`n`r`n")
        $client = New-Object System.Net.Sockets.TcpClient($whoisServer, 43)
        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $reader = New-Object System.IO.StreamReader($stream)
        $writer.WriteLine($domain); $writer.Flush()
        $txtDNSResults.AppendText($reader.ReadToEnd())
        Write-Log "WHOIS: $domain"
    } catch {
        $txtDNSResults.Text = "WHOIS failed: $($_.Exception.Message)`r`n`r`nVisit: https://www.whois.com/whois/$domain"
    } finally {
        if ($reader) { try { $reader.Close() } catch {} }
        if ($writer) { try { $writer.Close() } catch {} }
        if ($stream) { try { $stream.Close() } catch {} }
        if ($client) { try { $client.Close() } catch {} }
    }
})

$btnMXRecords.Add_Click({
    try {
        $domain = $txtDomain.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($domain) -or $domain -notmatch '^[a-zA-Z0-9.\-]+$') { $txtDNSResults.Text = "Invalid domain."; return }
        $txtDNSResults.Text = "MX Records: $domain`r`n$("=" * 50)`r`n"
        $mx = Resolve-DnsName -Name $domain -Type MX -ErrorAction Stop
        foreach ($r in $mx) { $txtDNSResults.AppendText("Priority: $($r.Preference) | Server: $($r.NameExchange)`r`n") }
    } catch { $txtDNSResults.Text = "MX lookup failed: $($_.Exception.Message)" }
})

$btnSSLCert.Add_Click({
    $domain = $txtDomain.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($domain) -or $domain -notmatch '^[a-zA-Z0-9.\-]+$') { $txtDNSResults.Text = "Invalid domain."; return }
    try {
        $txtDNSResults.Text = "SSL Certificate: $domain`r`n$("=" * 50)`r`n"
        $req = [System.Net.HttpWebRequest]::Create("https://$domain")
        $req.AllowAutoRedirect = $false
        $req.Timeout = 10000
        $null = $req.GetResponse()
        $cert = $req.ServicePoint.Certificate
        if ($cert) {
            $txtDNSResults.AppendText("Subject:      $($cert.Subject)`r`n")
            $txtDNSResults.AppendText("Issuer:       $($cert.Issuer)`r`n")
            $txtDNSResults.AppendText("Valid From:   $($cert.GetEffectiveDateString())`r`n")
            $txtDNSResults.AppendText("Valid To:     $($cert.GetExpirationDateString())`r`n")
            $txtDNSResults.AppendText("Thumbprint:   $($cert.GetCertHashString())`r`n")
        }
    } catch {
        $txtDNSResults.AppendText("SSL check failed: $($_.Exception.Message)`r`n")
    }
})

$btnFlushDNS.Add_Click({
    try {
        $result = ipconfig /flushdns
        $txtDNSResults.Text = $result -join "`r`n"
        Write-Log "DNS cache flushed"
    } catch { $txtDNSResults.Text = "Flush failed: $($_.Exception.Message)" }
})

# ============================================================
# EVENT HANDLERS - PORT SCAN & TRACEROUTE
# ============================================================
$btnQuickScan.Add_Click({
    $target = $txtScanTarget.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($target) -or $target -notmatch '^[a-zA-Z0-9.\-]+$') { $txtScanResults.Text = "Invalid target."; return }
    $ports = $txtPorts.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' }
    if (-not $ports) { $txtScanResults.Text = "No valid ports specified."; return }

    $txtScanResults.Text = "Port Scan: $target  ($($ports.Count) ports)`r`n$("=" * 50)`r`nScanning in parallel...`r`n`r`n"
    $btnQuickScan.Enabled   = $false
    $btnTraceroute.Enabled  = $false
    $btnPathPing.Enabled    = $false

    $psSync = [Hashtable]::Synchronized(@{ Results = [System.Collections.ArrayList]::new(); Done = 0; Total = $ports.Count })

    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, [Math]::Min($ports.Count, 50))
    $pool.Open()

    $jobs = [System.Collections.ArrayList]::new()
    foreach ($port in $ports) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript({
            param($sync, $tgt, $prt)
            $tcp = $null; $open = $false
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $conn = $tcp.BeginConnect($tgt, [int]$prt, $null, $null)
                $wait = $conn.AsyncWaitHandle.WaitOne(1000, $false)
                if ($wait -and $tcp.Connected) { $open = $true; $tcp.EndConnect($conn) }
            } catch {} finally { if ($tcp) { try { $tcp.Close() } catch {} } }
            $null = $sync.Results.Add([PSCustomObject]@{ Port = [int]$prt; Open = $open })
            $sync.Done++
        }).AddParameters(@{ sync = $psSync; tgt = $target; prt = $port }) | Out-Null
        $null = $jobs.Add([PSCustomObject]@{ PS = $ps; Async = $ps.BeginInvoke() })
    }

    $scanTimer = New-Object System.Windows.Forms.Timer
    $scanTimer.Interval = 300
    $scanTimer.Add_Tick({
        $pct = if ($psSync.Total -gt 0) { [int](($psSync.Done / $psSync.Total) * 100) } else { 100 }
        $txtScanResults.Lines[2] = "Scanning in parallel... $pct% ($($psSync.Done)/$($psSync.Total))"
        if ($psSync.Done -lt $psSync.Total) { return }
        $scanTimer.Stop()
        $pool.Close(); $pool.Dispose()
        foreach ($j in $jobs) { try { $j.PS.Dispose() } catch {} }

        $sorted = $psSync.Results | Sort-Object Port
        $sb = [System.Text.StringBuilder]::new()
        $null = $sb.AppendLine("Port Scan: $target  ($($ports.Count) ports)")
        $null = $sb.AppendLine("=" * 50)
        $open = @($sorted | Where-Object Open)
        if ($open) {
            $null = $sb.AppendLine("OPEN PORTS ($($open.Count)):")
            foreach ($r in $open) { $null = $sb.AppendLine("  Port $($r.Port) : OPEN") }
            $null = $sb.AppendLine("")
        }
        $null = $sb.AppendLine("CLOSED/FILTERED ($($sorted.Count - $open.Count)):")
        foreach ($r in ($sorted | Where-Object { -not $_.Open })) { $null = $sb.AppendLine("  Port $($r.Port) : CLOSED") }
        $txtScanResults.Text = $sb.ToString()
        $btnQuickScan.Enabled = $true; $btnTraceroute.Enabled = $true; $btnPathPing.Enabled = $true
        Write-Log "Port scan complete: $target - $($open.Count) open of $($ports.Count)"
    })
    $scanTimer.Start()
})

$btnTraceroute.Add_Click({
    $target = $txtScanTarget.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($target) -or $target -notmatch '^[a-zA-Z0-9.\-]+$') { $txtScanResults.Text = "Invalid target."; return }
    $txtScanResults.Text = "Traceroute: $target`r`n$("=" * 50)`r`n(Running -- results stream as hops respond...)`r`n`r`n"
    $btnTraceroute.Enabled  = $false
    $btnPathPing.Enabled    = $false
    $btnQuickScan.Enabled   = $false

    $trSync = [Hashtable]::Synchronized(@{ Output = $null; Done = $false })
    $psT = [System.Management.Automation.PowerShell]::Create(
        [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2())
    $null = $psT.AddScript({
        param($sync, $tgt)
        $sync.Output = (tracert $tgt) -join "`r`n"
        $sync.Done   = $true
    }).AddParameters(@{ sync = $trSync; tgt = $target }) | Out-Null
    $psT.BeginInvoke() | Out-Null

    $trTimer = New-Object System.Windows.Forms.Timer
    $trTimer.Interval = 500
    $trTimer.Add_Tick({
        if (-not $trSync.Done) { return }
        $trTimer.Stop()
        $txtScanResults.Text = "Traceroute: $target`r`n$("=" * 50)`r`n$($trSync.Output)"
        $btnTraceroute.Enabled = $true; $btnPathPing.Enabled = $true; $btnQuickScan.Enabled = $true
        try { $psT.Dispose() } catch {}
        Write-Log "Traceroute completed: $target"
    })
    $trTimer.Start()
})

$btnPathPing.Add_Click({
    $target = $txtScanTarget.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($target) -or $target -notmatch '^[a-zA-Z0-9.\-]+$') { $txtScanResults.Text = "Invalid target."; return }
    $txtScanResults.Text = "PathPing: $target (may take ~2 min...)`r`n$("=" * 50)`r`n(Running -- PathPing collects 100 samples per hop, please wait...)`r`n"
    $btnTraceroute.Enabled  = $false
    $btnPathPing.Enabled    = $false
    $btnQuickScan.Enabled   = $false

    $ppSync = [Hashtable]::Synchronized(@{ Output = $null; Done = $false })
    $psPP = [System.Management.Automation.PowerShell]::Create(
        [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2())
    $null = $psPP.AddScript({
        param($sync, $tgt)
        $sync.Output = (pathping $tgt) -join "`r`n"
        $sync.Done   = $true
    }).AddParameters(@{ sync = $ppSync; tgt = $target }) | Out-Null
    $psPP.BeginInvoke() | Out-Null

    $ppTimer = New-Object System.Windows.Forms.Timer
    $ppTimer.Interval = 500
    $ppTimer.Add_Tick({
        if (-not $ppSync.Done) { return }
        $ppTimer.Stop()
        $txtScanResults.Text = "PathPing: $target`r`n$("=" * 50)`r`n$($ppSync.Output)"
        $btnTraceroute.Enabled = $true; $btnPathPing.Enabled = $true; $btnQuickScan.Enabled = $true
        try { $psPP.Dispose() } catch {}
        Write-Log "PathPing completed: $target"
    })
    $ppTimer.Start()
})

# ============================================================
# EVENT HANDLERS - NETWORK ACTIONS
# ============================================================
$btnARPTable.Add_Click({     $txtActionsResults.Text = (arp -a) -join "`r`n" })
$btnNetstat.Add_Click({      $txtActionsResults.Text = (netstat -ano) -join "`r`n" })
$btnRouteTable.Add_Click({   $txtActionsResults.Text = (route print) -join "`r`n" })
$btnIPConfig.Add_Click({     $txtActionsResults.Text = (ipconfig /all) -join "`r`n" })
$btnReleaseRenew.Add_Click({
    $txtActionsResults.Text = "Releasing...`r`n"
    $txtActionsResults.AppendText(((ipconfig /release) -join "`r`n") + "`r`n`r`nRenewing...`r`n")
    $txtActionsResults.AppendText((ipconfig /renew) -join "`r`n")
})
$btnResetWinsock.Add_Click({
    $txtActionsResults.Text = ((netsh winsock reset) -join "`r`n") + "`r`n`r`nRestart required."
})
$btnResetIP.Add_Click({
    $txtActionsResults.Text = ((netsh int ip reset) -join "`r`n") + "`r`n`r`nRestart required."
})

# ============================================================
# EVENT HANDLERS - INTERNET REPAIR
# ============================================================
$btnRepairWinsock.Add_Click({
    $txtRepairResults.AppendText("[$(Get-Date -Format 'HH:mm:ss')] Resetting Winsock...`r`n")
    $txtRepairResults.AppendText(((netsh winsock reset) -join "`r`n") + "`r`n[DONE]`r`n`r`n")
    Write-Log "Winsock reset"
})
$btnRepairTCPIP.Add_Click({
    $txtRepairResults.AppendText("[$(Get-Date -Format 'HH:mm:ss')] Resetting TCP/IP...`r`n")
    $txtRepairResults.AppendText(((netsh int ip reset) -join "`r`n") + "`r`n[DONE]`r`n`r`n")
    Write-Log "TCP/IP reset"
})
$btnRepairFlushDNS.Add_Click({
    $txtRepairResults.AppendText("[$(Get-Date -Format 'HH:mm:ss')] Flushing DNS...`r`n")
    $txtRepairResults.AppendText(((ipconfig /flushdns) -join "`r`n") + "`r`n[DONE]`r`n`r`n")
    Write-Log "DNS flushed"
})
$btnRepairRenewIP.Add_Click({
    $txtRepairResults.AppendText("[$(Get-Date -Format 'HH:mm:ss')] Releasing IP...`r`n")
    $txtRepairResults.AppendText(((ipconfig /release) -join "`r`n") + "`r`n")
    $txtRepairResults.AppendText("[$(Get-Date -Format 'HH:mm:ss')] Renewing IP...`r`n")
    $txtRepairResults.AppendText(((ipconfig /renew) -join "`r`n") + "`r`n[DONE]`r`n`r`n")
    Write-Log "IP released/renewed"
})
$btnRepairProxy.Add_Click({
    $txtRepairResults.AppendText("[$(Get-Date -Format 'HH:mm:ss')] Resetting Proxy...`r`n")
    $txtRepairResults.AppendText(((netsh winhttp reset proxy) -join "`r`n") + "`r`n[DONE]`r`n`r`n")
    Write-Log "Proxy reset"
})
$btnRepairFirewall.Add_Click({
    $txtRepairResults.AppendText("[$(Get-Date -Format 'HH:mm:ss')] Resetting Firewall...`r`n")
    $txtRepairResults.AppendText(((netsh advfirewall reset) -join "`r`n") + "`r`n[DONE]`r`n`r`n")
    Write-Log "Firewall reset"
})
$btnRepairHosts.Add_Click({
    $txtRepairResults.AppendText("[$(Get-Date -Format 'HH:mm:ss')] Restoring HOSTS file...`r`n")
    try {
        $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
        $default = "# Copyright (c) 1993-2009 Microsoft Corp.`r`n127.0.0.1       localhost`r`n::1             localhost"
        [System.IO.File]::WriteAllText($hostsPath, $default, [System.Text.Encoding]::ASCII)
        $txtRepairResults.AppendText("HOSTS restored`r`n[DONE]`r`n`r`n")
        Write-Log "HOSTS file restored"
    } catch { $txtRepairResults.AppendText("ERROR: Run as Administrator.`r`n`r`n") }
})
$btnRepairARP.Add_Click({
    $txtRepairResults.AppendText("[$(Get-Date -Format 'HH:mm:ss')] Clearing ARP...`r`n")
    arp -d | Out-Null
    $txtRepairResults.AppendText("ARP cleared`r`n[DONE]`r`n`r`n")
    Write-Log "ARP cleared"
})
$btnRepairNetBIOS.Add_Click({
    $txtRepairResults.AppendText("[$(Get-Date -Format 'HH:mm:ss')] Resetting NetBIOS...`r`n")
    $txtRepairResults.AppendText(((nbtstat -R) -join "`r`n") + ((nbtstat -RR) -join "`r`n") + "`r`n[DONE]`r`n`r`n")
    Write-Log "NetBIOS reset"
})
$btnRepairIE.Add_Click({
    $txtRepairResults.AppendText("[$(Get-Date -Format 'HH:mm:ss')] Resetting IE/Edge...`r`n")
    try { RunDll32.exe InetCpl.cpl,ResetIEtoDefaults; $txtRepairResults.AppendText("Reset initiated`r`n[DONE]`r`n`r`n") }
    catch { $txtRepairResults.AppendText("Manual reset required via Internet Options`r`n`r`n") }
    Write-Log "IE/Edge reset"
})
$btnCompleteRepair.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "This runs ALL repair operations.`r`nA restart is recommended after completion.`r`n`r`nContinue?",
        "Complete Internet Repair","YesNo","Warning")
    if ($confirm -ne "Yes") { return }
    $txtRepairResults.Clear()
    $txtRepairResults.AppendText("==============================`r`nCOMPLETE INTERNET REPAIR`r`n==============================`r`n`r`n")
    $steps = @("[1/9] Winsock","[2/9] TCP/IP","[3/9] DNS","[4/9] Release IP","[5/9] Renew IP","[6/9] Proxy","[7/9] Firewall","[8/9] ARP","[9/9] NetBIOS")
    $cmds  = @({netsh winsock reset},{netsh int ip reset},{ipconfig /flushdns},{ipconfig /release},{ipconfig /renew},{netsh winhttp reset proxy},{netsh advfirewall reset},{arp -d},{nbtstat -R; nbtstat -RR})
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $txtRepairResults.AppendText("$($steps[$i])...`r`n")
        try { & $cmds[$i] | Out-Null } catch {}
        $txtRepairResults.AppendText("  Done`r`n`r`n")
    }
    $txtRepairResults.AppendText("==============================`r`nFINISHED - PLEASE RESTART`r`n==============================`r`n")
    Write-Log "Complete Internet Repair performed"
    [System.Windows.Forms.MessageBox]::Show("Complete! Please restart your computer.", "Repair Done","OK","Information")
})

# ============================================================
# EVENT HANDLERS - WLAN REPORT
# ============================================================
function Write-WlanLog {
    param([string]$Msg, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $txtWlanLog.AppendText("[$ts][$Level] $Msg`r`n")
    $txtWlanLog.SelectionStart = $txtWlanLog.Text.Length
    $txtWlanLog.ScrollToCaret()
    Write-Log "WLAN: $Msg" $Level
}

$btnWlanGenerate.Add_Click({
    $lblWlanStatus.Text = "Generating WLAN report (UAC prompt required)..."
    $btnWlanGenerate.Enabled = $false
    $form.Refresh()
    Write-WlanLog "Spawning elevated child for: netsh wlan show wlanreport"
    try {
        # netsh wlan show wlanreport requires admin to write to %ProgramData%.
        # Main process runs at medium IL (Outlook COM compat), so we spawn an
        # elevated child that runs the command and exits. We poll for the result.
        $psExe  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $netshCmd = "netsh wlan show wlanreport | Out-Null"
        Start-Process -FilePath $psExe `
            -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$netshCmd`"" `
            -Verb RunAs -WindowStyle Hidden -Wait
        if (Test-Path -LiteralPath $script:ReportSource -ErrorAction SilentlyContinue) {
            Write-WlanLog "Report generated: $script:ReportSource"
            $lblWlanStatus.Text = "Report generated. Opening in browser..."
            $btnWlanOpen.Enabled   = $true
            $btnWlanSave.Enabled   = $true
            $btnWlanExport.Enabled = $true
            Start-Process $script:ReportSource
        } else {
            Write-WlanLog "Report not found after elevated run." "WARN"
            $lblWlanStatus.Text = "Report not found -- UAC may have been declined."
        }
    } catch {
        Write-WlanLog "Error: $_" "ERROR"
        $lblWlanStatus.Text = "Error (UAC declined?): $_"
    }
    $btnWlanGenerate.Enabled = $true
})

$btnWlanOpen.Add_Click({
    if (Test-Path -LiteralPath $script:ReportSource -ErrorAction SilentlyContinue) {
        Start-Process $script:ReportSource
        Write-WlanLog "Opened report in browser"
    } else {
        Write-WlanLog "No report found. Generate first." "WARN"
    }
})

$btnWlanSave.Add_Click({
    if (-not (Test-Path -LiteralPath $script:ReportSource -ErrorAction SilentlyContinue)) { Write-WlanLog "No report to save." "WARN"; return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "HTML Report (*.html)|*.html|All Files (*.*)|*.*"
    $dlg.FileName = "WLAN-Report-$(Get-Date -Format 'yyyy-MM-dd_HHmm').html"
    $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dlg.ShowDialog() -eq "OK") {
        try {
            Copy-Item -LiteralPath $script:ReportSource -Destination $dlg.FileName -Force -ErrorAction Stop
            Write-WlanLog "Saved to: $($dlg.FileName)"
            $lblWlanStatus.Text = "Saved: $($dlg.FileName)"
        } catch { Write-WlanLog "Save failed: $_" "ERROR" }
    }
})

$btnWlanExport.Add_Click({
    if (-not (Test-Path -LiteralPath $script:ReportSource -ErrorAction SilentlyContinue)) { Write-WlanLog "No report to export." "WARN"; return }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select export folder"
    if ($dlg.ShowDialog() -eq "OK") {
        $stamp    = Get-Date -Format 'yyyy-MM-dd_HHmm'
        $destHtml = Join-Path $dlg.SelectedPath "WLAN-Report-$stamp.html"
        $reportDir = Join-Path ([System.IO.Path]::GetDirectoryName($script:ReportSource)) 'wlanreport'
        try {
            Copy-Item -LiteralPath $script:ReportSource -Destination $destHtml -Force -ErrorAction Stop
            Write-WlanLog "Exported HTML: $destHtml"
            if (Test-Path -LiteralPath $reportDir -ErrorAction SilentlyContinue) {
                try {
                    Copy-Item -LiteralPath $reportDir -Destination (Join-Path $dlg.SelectedPath "wlanreport-$stamp") -Recurse -Force -ErrorAction Stop
                    Write-WlanLog "Exported assets folder"
                } catch { Write-WlanLog "Asset copy skipped: $_" "WARN" }
            }
            $lblWlanStatus.Text = "Exported to: $($dlg.SelectedPath)"
        } catch { Write-WlanLog "Export failed: $_" "ERROR" }
    }
})

$btnWlanViewLog.Add_Click({ Start-Process notepad.exe -ArgumentList $script:LogFile })

function Invoke-WlanSend {
    param([bool]$IsScheduled = $false)
    $toAddr   = $txtWlanTo.Text.Trim()
    $smtp     = $txtWlanSmtpServer.Text.Trim()
    $port     = $txtWlanSmtpPort.Text.Trim()
    $fromAddr = $txtWlanFrom.Text.Trim()
    $user     = $txtWlanSmtpUser.Text.Trim()
    $useTls   = $chkWlanTls.Checked

    if ([string]::IsNullOrWhiteSpace($toAddr)) {
        [System.Windows.Forms.MessageBox]::Show("Enter a recipient email address.", "Missing Recipient", "OK", "Warning"); return $false
    }
    foreach ($f in @(@("SMTP Server",$smtp),@("From address",$fromAddr))) {
        if ([string]::IsNullOrWhiteSpace($f[1])) {
            [System.Windows.Forms.MessageBox]::Show("$($f[0]) is required.", "Validation", "OK", "Warning"); return $false
        }
    }

    # Generate fresh report (netsh wlan show wlanreport runs fine when elevated)
    Write-WlanLog "Generating WLAN report for email..."
    $lblWlanStatus.Text = "Generating report..."
    $form.Refresh()
    try {
        $rawOut = & netsh wlan show wlanreport 2>&1
        Write-WlanLog ($rawOut -join " | ")
    } catch { Write-WlanLog "netsh warning: $_" "WARN" }

    if (-not (Test-Path -LiteralPath $script:ReportSource -ErrorAction SilentlyContinue)) {
        Write-WlanLog "Report file not found. Ensure you have admin rights and WLAN service is running." "ERROR"
        [System.Windows.Forms.MessageBox]::Show("WLAN report file not found.`r`nRun as administrator and ensure Wireless service is running.","Report Missing","OK","Error")
        return $false
    }

    $subject = "WLAN Report - $($env:COMPUTERNAME) - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $body    = "<p>Automated WLAN Network Report from <b>$($env:COMPUTERNAME)</b></p><p>Generated: $(Get-Date)</p><p>Report attached.</p>"

    $pass = $null
    if (-not [string]::IsNullOrWhiteSpace($user)) {
        $pass = Get-SmtpPassword
        if ($null -eq $pass) { return $false }   # user cancelled
    }

    try {
        Send-NetworkProEmail `
            -SmtpServer   $smtp `
            -SmtpPort     ([int]$port) `
            -FromAddress  $fromAddr `
            -ToAddress    $toAddr `
            -Username     $user `
            -Password     $pass `
            -UseTls       $useTls `
            -Subject      $subject `
            -Body         $body `
            -AttachmentPath $script:ReportSource
        Write-WlanLog "Email sent via SMTP to: $toAddr"
        return $true
    } catch {
        Write-WlanLog "SMTP send failed: $_" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("SMTP send failed:`r`n$_","Error","OK","Error")
        return $false
    }
}

$btnWlanSendNow.Add_Click({
    $ok = Invoke-WlanSend
    if ($ok) { [System.Windows.Forms.MessageBox]::Show("Report emailed successfully.", "Sent", "OK", "Information") }
})

$btnWlanSchedule.Add_Click({
    $toAddr   = $txtWlanTo.Text.Trim()
    $smtp     = $txtWlanSmtpServer.Text.Trim()
    $port     = $txtWlanSmtpPort.Text.Trim()
    $fromAddr = $txtWlanFrom.Text.Trim()
    $user     = $txtWlanSmtpUser.Text.Trim()
    $useTls   = $chkWlanTls.Checked

    if ([string]::IsNullOrWhiteSpace($toAddr)) {
        [System.Windows.Forms.MessageBox]::Show("Enter a recipient email address.", "Missing Recipient", "OK", "Warning"); return
    }
    foreach ($f in @(@("SMTP Server",$smtp),@("From address",$fromAddr))) {
        if ([string]::IsNullOrWhiteSpace($f[1])) {
            [System.Windows.Forms.MessageBox]::Show("$($f[0]) is required.", "Validation", "OK", "Warning"); return
        }
    }

    $sel       = $cboWlanSchedule.SelectedItem
    $schedLabel = if ($sel) { $sel } else { "Daily - 6:00 AM" }
    $schedIdx  = $cboWlanSchedule.SelectedIndex
    $payDir    = "$env:ProgramData\Paladin\NetworkPro"
    $payPath   = "$payDir\Send-WlanReport.ps1"
    $useTlsStr = if ($useTls) { '$true' } else { '$false' }

    # Prompt for SMTP password now and embed in payload.
    # Password stored in the payload file -- secure the file with NTFS ACLs if needed.
    $pass = ""
    if (-not [string]::IsNullOrWhiteSpace($user)) {
        $pass = Get-SmtpPassword
        if ($null -eq $pass) { return }
    }

    $payload = @"
#Requires -Version 5.1
`$ErrorActionPreference = 'Stop'
`$reportSource = "`$env:ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html"
`$null = netsh wlan show wlanreport 2>&1
if (-not (Test-Path -LiteralPath `$reportSource)) { Write-Error "Report not found."; exit 1 }
`$subject = "WLAN Report - `$(`$env:COMPUTERNAME) - `$(Get-Date -Format 'yyyy-MM-dd')"
`$body    = "<p>Automated WLAN Report from <b>`$(`$env:COMPUTERNAME)</b> - `$(Get-Date)</p>"
`$params  = @{ SmtpServer='$smtp'; Port=$port; From='$fromAddr'; To='$toAddr'; Subject=`$subject; Body=`$body; BodyAsHtml=`$true; Attachments=`$reportSource; UseSsl=$useTlsStr }
if (-not [string]::IsNullOrWhiteSpace('$user')) {
    `$secPass = ConvertTo-SecureString '$pass' -AsPlainText -Force
    `$params.Credential = New-Object System.Management.Automation.PSCredential('$user', `$secPass)
}
Send-MailMessage @params -ErrorAction Stop
Write-Output "Sent via SMTP at `$(Get-Date)"
"@

    try {
        if (-not (Test-Path -LiteralPath $payDir -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $payDir -Force -ErrorAction Stop | Out-Null
        }
        [System.IO.File]::WriteAllText($payPath, $payload, [System.Text.Encoding]::UTF8)
    } catch {
        Write-WlanLog "Failed to write payload: $_" "ERROR"; return
    }

    # Register scheduled task -- use staged ProgramData path so it works post-Datto-deploy
    $SelfDest = 'C:\ProgramData\Paladin\NetworkPro\Paladin-NetworkPro.ps1'
    # Register scheduled task (requires admin -- prompt via -Verb RunAs)
    $psExeForTask = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $taskArg      = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$payPath`""
    $taskResult   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "netpro_task_$([System.IO.Path]::GetRandomFileName()).txt")
    $taskScript   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "netpro_task_$([System.IO.Path]::GetRandomFileName()).ps1")

    $taskHelperCode = @"
`$ErrorActionPreference = 'Stop'
try {
    `$existing = schtasks /Query /TN '$script:TaskName' /FO LIST 2>&1
    if (`$LASTEXITCODE -eq 0) { schtasks /Delete /TN '$script:TaskName' /F | Out-Null }
    switch ($schedIdx) {
        0 { schtasks /Create /TN '$script:TaskName' /TR '"$psExeForTask" $taskArg' /SC DAILY /ST 06:00 /RL HIGHEST /F | Out-Null }
        1 { schtasks /Create /TN '$script:TaskName' /TR '"$psExeForTask" $taskArg' /SC DAILY /ST 08:00 /RL HIGHEST /F | Out-Null }
        2 { schtasks /Create /TN '$script:TaskName' /TR '"$psExeForTask" $taskArg' /SC WEEKLY /D MON /ST 06:00 /RL HIGHEST /F | Out-Null }
        3 { schtasks /Create /TN '$script:TaskName' /TR '"$psExeForTask" $taskArg' /SC HOURLY /MO 4 /RL HIGHEST /F | Out-Null }
        4 { schtasks /Create /TN '$script:TaskName' /TR '"$psExeForTask" $taskArg' /SC HOURLY /MO 12 /RL HIGHEST /F | Out-Null }
        5 { schtasks /Create /TN '$script:TaskName' /TR '"$psExeForTask" $taskArg' /SC ONSTART /RL HIGHEST /F | Out-Null }
        default { schtasks /Create /TN '$script:TaskName' /TR '"$psExeForTask" $taskArg' /SC DAILY /ST 06:00 /RL HIGHEST /F | Out-Null }
    }
    'OK' | Out-File -FilePath '$taskResult' -Encoding UTF8 -Force
} catch {
    "ERROR: `$_" | Out-File -FilePath '$taskResult' -Encoding UTF8 -Force
}
"@

    try {
        [System.IO.File]::WriteAllText($taskScript, $taskHelperCode, [System.Text.Encoding]::UTF8)
        $psAdmin = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        Start-Process -FilePath $psAdmin `
            -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$taskScript`"" `
            -Verb RunAs -WindowStyle Hidden -Wait
        Start-Sleep -Milliseconds 500

        if (Test-Path -LiteralPath $taskResult -ErrorAction SilentlyContinue) {
            $taskOut = [System.IO.File]::ReadAllText($taskResult, [System.Text.Encoding]::UTF8).Trim()
            if ($taskOut.StartsWith("ERROR:")) { throw $taskOut.Substring(6).Trim() }
            Write-WlanLog "Scheduled task registered: $script:TaskName ($schedLabel)"
            $lblWlanStatus.Text = "Task '$script:TaskName' registered: $schedLabel"
            [System.Windows.Forms.MessageBox]::Show("Task registered: $($script:TaskName)`r`nSchedule: $schedLabel", "Task Registered", "OK", "Information")
        } else {
            Write-WlanLog "Task registration: no result (UAC declined?)" "WARN"
            [System.Windows.Forms.MessageBox]::Show("Task may not have registered. UAC may have been declined.", "Warning", "OK", "Warning")
        }
    } catch {
        Write-WlanLog "Task registration failed: $_" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Failed:`r`n$_", "Error", "OK", "Error")
    } finally {
        try { if (Test-Path -LiteralPath $taskScript -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $taskScript -Force -ErrorAction Stop } } catch {}
        try { if (Test-Path -LiteralPath $taskResult -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $taskResult -Force -ErrorAction Stop } } catch {}
    }
})

$btnWlanSaveCfg.Add_Click({ Save-EmailConfig })
$btnWlanLoadCfg.Add_Click({ Load-EmailConfig })

# ============================================================
# EVENT HANDLERS - LAN REPORT
# ============================================================
function Write-LanLog {
    param([string]$Msg, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $txtLanLog.AppendText("[$ts][$Level] $Msg`r`n")
    $txtLanLog.SelectionStart = $txtLanLog.Text.Length
    $txtLanLog.ScrollToCaret()
    Write-Log "LAN: $Msg" $Level
}

function Build-LanReportHtml {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $host_name = $env:COMPUTERNAME
    $sb = New-Object System.Text.StringBuilder

    [void]$sb.Append(@"
<!DOCTYPE html>
<html>
<head>
<meta charset='utf-8'>
<title>LAN Report - $host_name</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; background:#1a1a2e; color:#ddd; margin:20px; }
h1 { color:#e94560; border-bottom:2px solid #0f3460; padding-bottom:8px; }
h2 { color:#64b5f6; margin-top:24px; }
table { border-collapse:collapse; width:100%; margin-bottom:16px; }
th { background:#0f3460; color:#fff; padding:8px 12px; text-align:left; }
td { padding:6px 12px; border-bottom:1px solid #333; }
tr:nth-child(even) td { background:#16213e; }
.ok { color:#00e676; font-weight:bold; }
.warn { color:#ffd600; font-weight:bold; }
.fail { color:#ff5252; font-weight:bold; }
pre { background:#0d1b2a; padding:10px; border-radius:4px; font-size:12px; overflow-x:auto; color:#aaffaa; }
.badge { display:inline-block; padding:2px 10px; border-radius:12px; font-size:12px; font-weight:bold; }
.badge-up { background:#1b5e20; color:#a5d6a7; }
.badge-down { background:#b71c1c; color:#ef9a9a; }
</style>
</head>
<body>
<h1>LAN Diagnostic Report</h1>
<p><b>Host:</b> $host_name &nbsp;&nbsp; <b>Generated:</b> $ts</p>
"@)

    # Section 1: Adapters
    [void]$sb.Append("<h2>Network Adapters</h2><table><tr><th>Name</th><th>Status</th><th>Type</th><th>Speed</th><th>MAC</th><th>IPv4</th><th>Gateway</th><th>DNS</th></tr>")
    try {
        $adapters = @(Get-NetAdapter | Sort-Object Status)
        foreach ($a in $adapters) {
            $status = if ($a.Status -eq "Up") { "<span class='badge badge-up'>Up</span>" } else { "<span class='badge badge-down'>$($a.Status)</span>" }
            # Use Get-NetIPAddress/Get-NetRoute directly to avoid Get-NetIPConfiguration
            # which calls Get-NetIPInterface internally and throws a terminating
            # CimJobException that escapes try/catch on PS 5.1 for adapters with
            # no TCP/IP stack. These cmdlets return empty, never throw.
            $ipv4Obj = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
            $gwObj   = Get-NetRoute    -InterfaceIndex $a.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1
            $dnsRaw  = (Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
            $ipv4 = if ($ipv4Obj) { $ipv4Obj.IPAddress } else { $null }
            $gw   = if ($gwObj)   { $gwObj.NextHop }     else { $null }
            $dns  = if ($dnsRaw)  { $dnsRaw -join ", " } else { $null }
            [void]$sb.Append("<tr><td>$($a.Name)</td><td>$status</td><td>$($a.MediaType)</td><td>$($a.LinkSpeed)</td><td>$($a.MacAddress)</td><td>$(if($ipv4){$ipv4}else{'N/A'})</td><td>$(if($gw){$gw}else{'N/A'})</td><td>$(if($dns){$dns}else{'N/A'})</td></tr>")
        }
    } catch { [void]$sb.Append("<tr><td colspan='8'>Error: $_</td></tr>") }
    [void]$sb.Append("</table>")

    # Section 2: IP Configuration summary
    [void]$sb.Append("<h2>IP Configuration (ipconfig /all)</h2><pre>")
    try { [void]$sb.Append([System.Web.HttpUtility]::HtmlEncode((ipconfig /all | Out-String))) } catch { [void]$sb.Append("Error: $_") }
    [void]$sb.Append("</pre>")

    # Section 3: ARP Table
    [void]$sb.Append("<h2>ARP Table</h2><pre>")
    try { [void]$sb.Append([System.Web.HttpUtility]::HtmlEncode((arp -a | Out-String))) } catch { [void]$sb.Append("Error: $_") }
    [void]$sb.Append("</pre>")

    # Section 4: Route Table
    [void]$sb.Append("<h2>Routing Table</h2><pre>")
    try { [void]$sb.Append([System.Web.HttpUtility]::HtmlEncode((route print | Out-String))) } catch { [void]$sb.Append("Error: $_") }
    [void]$sb.Append("</pre>")

    # Section 5: Connectivity check
    [void]$sb.Append("<h2>Connectivity Tests</h2><table><tr><th>Test</th><th>Result</th></tr>")
    $conn = Test-InternetConnectivity
    [void]$sb.Append("<tr><td>DNS Resolution (google.com)</td><td class='$(if($conn.DNS){"ok"}else{"fail"})'>$(if($conn.DNS){"PASS"}else{"FAIL"})</td></tr>")
    [void]$sb.Append("<tr><td>ICMP Ping (8.8.8.8)</td><td class='$(if($conn.ICMP){"ok"}else{"fail"})'>$(if($conn.ICMP){"PASS"}else{"FAIL"})</td></tr>")
    [void]$sb.Append("<tr><td>HTTP (msftconnecttest.com)</td><td class='$(if($conn.HTTP){"ok"}else{"fail"})'>$(if($conn.HTTP){"PASS"}else{"FAIL"})</td></tr>")
    [void]$sb.Append("</table>")

    # Section 6: netsh lan show interfaces
    [void]$sb.Append("<h2>LAN Interfaces (netsh lan show interfaces)</h2><pre>")
    try { [void]$sb.Append([System.Web.HttpUtility]::HtmlEncode((netsh lan show interfaces | Out-String))) } catch { [void]$sb.Append("Not available (may require admin or Wired AutoConfig service).") }
    [void]$sb.Append("</pre>")

    # Section 7: netsh lan show profiles
    [void]$sb.Append("<h2>LAN Profiles (netsh lan show profiles)</h2><pre>")
    try { [void]$sb.Append([System.Web.HttpUtility]::HtmlEncode((netsh lan show profiles | Out-String))) } catch { [void]$sb.Append("Not available.") }
    [void]$sb.Append("</pre>")

    # Section 8: Active TCP connections
    [void]$sb.Append("<h2>Active Connections (netstat -ano)</h2><pre>")
    try { [void]$sb.Append([System.Web.HttpUtility]::HtmlEncode((netstat -ano | Out-String))) } catch { [void]$sb.Append("Error: $_") }
    [void]$sb.Append("</pre>")

    [void]$sb.Append("</body></html>")
    return $sb.ToString()
}

$btnLanGenerate.Add_Click({
    $lblLanStatus.Text = "Collecting LAN data..."
    $btnLanGenerate.Enabled = $false
    $form.Refresh()
    Write-LanLog "Building LAN diagnostic report..."
    try {
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
        $html = Build-LanReportHtml
        $reportDir = "$env:ProgramData\Paladin\NetworkPro"
        if (-not (Test-Path -LiteralPath $reportDir -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $reportDir -Force -ErrorAction Stop | Out-Null
        }
        $script:LanReportPath = "$reportDir\lan-report-latest.html"
        [System.IO.File]::WriteAllText($script:LanReportPath, $html, [System.Text.Encoding]::UTF8)
        Write-LanLog "Report saved: $script:LanReportPath"
        $lblLanStatus.Text = "LAN report generated. Opening in browser..."
        $btnLanOpen.Enabled   = $true
        $btnLanSave.Enabled   = $true
        $btnLanExport.Enabled = $true
        Start-Process $script:LanReportPath
    } catch {
        Write-LanLog "Error: $_" "ERROR"
        $lblLanStatus.Text = "Error: $_"
    }
    $btnLanGenerate.Enabled = $true
})

$btnLanOpen.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($script:LanReportPath) -and (Test-Path -LiteralPath $script:LanReportPath -ErrorAction SilentlyContinue)) {
        Start-Process $script:LanReportPath
    } else { Write-LanLog "No report. Generate first." "WARN" }
})

$btnLanSave.Add_Click({
    if ([string]::IsNullOrWhiteSpace($script:LanReportPath) -or -not (Test-Path -LiteralPath $script:LanReportPath -ErrorAction SilentlyContinue)) { Write-LanLog "No report to save." "WARN"; return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "HTML Report (*.html)|*.html"
    $dlg.FileName = "LAN-Report-$(Get-Date -Format 'yyyy-MM-dd_HHmm').html"
    $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dlg.ShowDialog() -eq "OK") {
        try {
            Copy-Item -LiteralPath $script:LanReportPath -Destination $dlg.FileName -Force -ErrorAction Stop
            Write-LanLog "Saved to: $($dlg.FileName)"
            $lblLanStatus.Text = "Saved: $($dlg.FileName)"
        } catch { Write-LanLog "Save failed: $_" "ERROR" }
    }
})

$btnLanExport.Add_Click({
    if ([string]::IsNullOrWhiteSpace($script:LanReportPath) -or -not (Test-Path -LiteralPath $script:LanReportPath -ErrorAction SilentlyContinue)) { Write-LanLog "No report to export." "WARN"; return }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select export folder"
    if ($dlg.ShowDialog() -eq "OK") {
        $dest = Join-Path $dlg.SelectedPath "LAN-Report-$(Get-Date -Format 'yyyy-MM-dd_HHmm').html"
        try {
            Copy-Item -LiteralPath $script:LanReportPath -Destination $dest -Force -ErrorAction Stop
            Write-LanLog "Exported: $dest"
            $lblLanStatus.Text = "Exported to: $dest"
        } catch { Write-LanLog "Export failed: $_" "ERROR" }
    }
})

$btnLanViewLog.Add_Click({ Start-Process notepad.exe -ArgumentList $script:LogFile })

$btnLanSendNow.Add_Click({
    $toAddr   = $txtLanTo.Text.Trim()
    $smtp     = $txtLanSmtpServer.Text.Trim()
    $port     = $txtLanSmtpPort.Text.Trim()
    $fromAddr = $txtLanFrom.Text.Trim()
    $user     = $txtLanSmtpUser.Text.Trim()
    $useTls   = $chkLanTls.Checked

    if ([string]::IsNullOrWhiteSpace($toAddr)) {
        [System.Windows.Forms.MessageBox]::Show("Enter a recipient email address.", "Missing Recipient", "OK", "Warning"); return
    }
    foreach ($f in @(@("SMTP Server",$smtp),@("From address",$fromAddr))) {
        if ([string]::IsNullOrWhiteSpace($f[1])) {
            [System.Windows.Forms.MessageBox]::Show("$($f[0]) is required.", "Validation", "OK", "Warning"); return
        }
    }
    if ([string]::IsNullOrWhiteSpace($script:LanReportPath) -or -not (Test-Path -LiteralPath $script:LanReportPath -ErrorAction SilentlyContinue)) {
        Write-LanLog "No report. Generate LAN Report first." "WARN"
        [System.Windows.Forms.MessageBox]::Show("Generate a LAN report first.", "No Report", "OK", "Warning"); return
    }

    $subject = "LAN Report - $($env:COMPUTERNAME) - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $body    = "<p>Automated LAN Diagnostic Report from <b>$($env:COMPUTERNAME)</b></p><p>Generated: $(Get-Date)</p><p>Report attached.</p>"

    $pass = $null
    if (-not [string]::IsNullOrWhiteSpace($user)) {
        $pass = Get-SmtpPassword
        if ($null -eq $pass) { return }   # user cancelled
    }

    try {
        Send-NetworkProEmail `
            -SmtpServer   $smtp `
            -SmtpPort     ([int]$port) `
            -FromAddress  $fromAddr `
            -ToAddress    $toAddr `
            -Username     $user `
            -Password     $pass `
            -UseTls       $useTls `
            -Subject      $subject `
            -Body         $body `
            -AttachmentPath $script:LanReportPath
        Write-LanLog "Email sent via SMTP to: $toAddr"
        [System.Windows.Forms.MessageBox]::Show("LAN report emailed successfully.", "Sent", "OK", "Information")
    } catch {
        Write-LanLog "SMTP send failed: $_" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("SMTP send failed:`r`n$_","Error","OK","Error")
    }
})

$btnLanSchedule.Add_Click({
    $toAddr   = $txtLanTo.Text.Trim()
    $smtp     = $txtLanSmtpServer.Text.Trim()
    $port     = $txtLanSmtpPort.Text.Trim()
    $fromAddr = $txtLanFrom.Text.Trim()
    $user     = $txtLanSmtpUser.Text.Trim()
    $useTls   = $chkLanTls.Checked

    foreach ($f in @(@("Recipient",$toAddr),@("SMTP Server",$smtp),@("From address",$fromAddr))) {
        if ([string]::IsNullOrWhiteSpace($f[1])) {
            [System.Windows.Forms.MessageBox]::Show("$($f[0]) is required.", "Validation", "OK", "Warning"); return
        }
    }

    $lanTaskName = 'PaladinNetworkProLANReport'
    $useTlsStr   = if ($useTls) { '$true' } else { '$false' }
    $pass = ""
    if (-not [string]::IsNullOrWhiteSpace($user)) {
        $pass = Get-SmtpPassword
        if ($null -eq $pass) { return }
    }

    $payDir  = "$env:ProgramData\Paladin\NetworkPro"
    $payPath = "$payDir\Send-LanReport.ps1"
    $payload = @"
#Requires -Version 5.1
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
`$reportDir  = "`$env:ProgramData\Paladin\NetworkPro"
`$reportPath = "`$reportDir\lan-report-latest.html"
if (-not (Test-Path -LiteralPath `$reportPath)) { Write-Error "LAN report not found. Run Generate first."; exit 1 }
`$subject = "LAN Report - `$(`$env:COMPUTERNAME) - `$(Get-Date -Format 'yyyy-MM-dd')"
`$body    = "<p>Automated LAN Report from <b>`$(`$env:COMPUTERNAME)</b> - `$(Get-Date)</p>"
`$params  = @{ SmtpServer='$smtp'; Port=$port; From='$fromAddr'; To='$toAddr'; Subject=`$subject; Body=`$body; BodyAsHtml=`$true; Attachments=`$reportPath; UseSsl=$useTlsStr }
if (-not [string]::IsNullOrWhiteSpace('$user')) {
    `$secPass = ConvertTo-SecureString '$pass' -AsPlainText -Force
    `$params.Credential = New-Object System.Management.Automation.PSCredential('$user', `$secPass)
}
Send-MailMessage @params -ErrorAction Stop
Write-Output "LAN report sent via SMTP at `$(Get-Date)"
"@

    try {
        if (-not (Test-Path -LiteralPath $payDir -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $payDir -Force -ErrorAction Stop | Out-Null
        }
        [System.IO.File]::WriteAllText($payPath, $payload, [System.Text.Encoding]::UTF8)
    } catch { Write-LanLog "Failed to write payload: $_" "ERROR"; return }

    $psExeForTask = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $taskArg      = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$payPath`""
    $taskResult   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "netpro_lantask_$([System.IO.Path]::GetRandomFileName()).txt")
    $taskScript   = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "netpro_lantask_$([System.IO.Path]::GetRandomFileName()).ps1")

    $taskHelperCode = @"
`$ErrorActionPreference = 'Stop'
try {
    `$ex = schtasks /Query /TN '$lanTaskName' /FO LIST 2>&1
    if (`$LASTEXITCODE -eq 0) { schtasks /Delete /TN '$lanTaskName' /F | Out-Null }
    schtasks /Create /TN '$lanTaskName' /TR '"$psExeForTask" $taskArg' /SC DAILY /ST 07:00 /RL HIGHEST /F | Out-Null
    'OK' | Out-File -FilePath '$taskResult' -Encoding UTF8 -Force
} catch {
    "ERROR: `$_" | Out-File -FilePath '$taskResult' -Encoding UTF8 -Force
}
"@

    try {
        [System.IO.File]::WriteAllText($taskScript, $taskHelperCode, [System.Text.Encoding]::UTF8)
        $psAdmin = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        Start-Process -FilePath $psAdmin `
            -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$taskScript`"" `
            -Verb RunAs -WindowStyle Hidden -Wait
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $taskResult -ErrorAction SilentlyContinue) {
            $out = [System.IO.File]::ReadAllText($taskResult, [System.Text.Encoding]::UTF8).Trim()
            if ($out.StartsWith("ERROR:")) { throw $out.Substring(6).Trim() }
            Write-LanLog "LAN scheduled task registered: $lanTaskName (Daily 7:00 AM)"
            $lblLanStatus.Text = "Task '$lanTaskName' registered (Daily 7:00 AM)"
            [System.Windows.Forms.MessageBox]::Show("Task registered: $lanTaskName`r`nSchedule: Daily 7:00 AM", "Task Registered", "OK", "Information")
        } else {
            Write-LanLog "Task registration: no result (UAC declined?)" "WARN"
            [System.Windows.Forms.MessageBox]::Show("Task may not have registered. UAC may have been declined.", "Warning", "OK", "Warning")
        }
    } catch {
        Write-LanLog "Task registration failed: $_" "ERROR"
        [System.Windows.Forms.MessageBox]::Show("Failed:`r`n$_", "Error", "OK", "Error")
    } finally {
        try { if (Test-Path -LiteralPath $taskScript -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $taskScript -Force -ErrorAction Stop } } catch {}
        try { if (Test-Path -LiteralPath $taskResult -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $taskResult -Force -ErrorAction Stop } } catch {}
    }
})

$btnLanSaveCfg.Add_Click({ Save-EmailConfig })
$btnLanLoadCfg.Add_Click({ Load-EmailConfig })

# ============================================================
# EVENT HANDLERS - TOOLS
# ============================================================
function Refresh-ToolsGridAsync {
    # Async rewrite: tool discovery runs in background runspace, posts results via WinForms Timer
    $gridTools.Rows.Clear()
    $btnRefreshTools.Enabled = $false
    $btnRefreshTools.Text    = "Refreshing..."

    $tgSync = [Hashtable]::Synchronized(@{ Tools = $null; Done = $false })
    $psTG = [System.Management.Automation.PowerShell]::Create(
        [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2())
    $null = $psTG.AddScript({
        param($sync)
        $tools = @(
            @{Name='Wireshark';            Exe='Wireshark';  WingetId='WiresharkFoundation.Wireshark'; ChocoId='wireshark';
              Paths=@('C:\Program Files\Wireshark\Wireshark.exe','C:\Program Files (x86)\Wireshark\Wireshark.exe','C:\ProgramData\chocolatey\bin\Wireshark.exe')}
            @{Name='Nmap (CLI)';           Exe='nmap';       WingetId='Insecure.Nmap';   ChocoId='nmap';
              Paths=@('C:\Program Files (x86)\Nmap\nmap.exe','C:\Program Files\Nmap\nmap.exe','C:\ProgramData\chocolatey\bin\nmap.exe')}
            @{Name='Zenmap (Nmap GUI)';    Exe='zenmap';     WingetId='Insecure.Nmap';   ChocoId='nmap';
              Paths=@('C:\Program Files (x86)\Nmap\zenmap.exe','C:\Program Files\Nmap\zenmap.exe','C:\Program Files (x86)\Nmap\Zenmap.exe')}
            @{Name='iperf3';               Exe='iperf3';     WingetId='ar51an.iPerf3';   ChocoId='iperf3';
              Paths=@('C:\ProgramData\chocolatey\bin\iperf3.exe',"$env:LOCALAPPDATA\Microsoft\WinGet\Packages\ar51an.iPerf3_Microsoft.Winget.Source_8wekyb3d8bbwe\iperf3.exe")}
            @{Name='PuTTY';                Exe='putty';      WingetId='PuTTY.PuTTY';     ChocoId='putty';
              Paths=@('C:\Program Files\PuTTY\putty.exe','C:\Program Files (x86)\PuTTY\putty.exe','C:\ProgramData\chocolatey\bin\putty.exe')}
            @{Name='WinSCP';               Exe='winscp';     WingetId='WinSCP.WinSCP';   ChocoId='winscp';
              Paths=@('C:\Program Files\WinSCP\WinSCP.exe','C:\Program Files (x86)\WinSCP\WinSCP.exe')}
            @{Name='curl';                 Exe='curl';       WingetId='cURL.cURL';        ChocoId='curl';
              Paths=@('C:\ProgramData\chocolatey\bin\curl.exe','C:\Windows\System32\curl.exe')}
            @{Name='wget';                 Exe='wget';       WingetId='';                 ChocoId='wget';
              Paths=@('C:\ProgramData\chocolatey\bin\wget.exe')}
            @{Name='TCPing';               Exe='tcping';     WingetId='';                 ChocoId='tcping';
              Paths=@('C:\ProgramData\chocolatey\bin\tcping.exe','C:\ProgramData\chocolatey\lib\tcping\tools\tcping.exe')}
            @{Name='Speedtest CLI';        Exe='speedtest';  WingetId='Ookla.Speedtest.CLI'; ChocoId='speedtest';
              Paths=@('C:\Program Files\Ookla\Speedtest CLI\speedtest.exe','C:\ProgramData\chocolatey\bin\speedtest.exe',"$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Ookla.Speedtest.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\speedtest.exe")}
            @{Name='OpenSSH';              Exe='ssh';        WingetId='Microsoft.OpenSSH.Beta'; ChocoId='openssh';
              Paths=@('C:\Windows\System32\OpenSSH\ssh.exe','C:\ProgramData\chocolatey\bin\ssh.exe')}
            @{Name='mRemoteNG';            Exe='mremoteng';  WingetId='mRemoteNG.mRemoteNG'; ChocoId='mremoteng';
              Paths=@('C:\Program Files\mRemoteNG\mRemoteNG.exe','C:\Program Files (x86)\mRemoteNG\mRemoteNG.exe')}
            @{Name='mitmproxy (web proxy)';Exe='mitmweb';    WingetId='mitmproxy.mitmproxy'; ChocoId='mitmproxy';
              Paths=@('C:\Program Files\mitmproxy\mitmweb.exe','C:\ProgramData\chocolatey\bin\mitmweb.exe')}
        )
        $rows = [System.Collections.ArrayList]::new()
        foreach ($t in $tools) {
            $found = $null
            foreach ($p in $t.Paths) {
                if ([System.IO.File]::Exists($p)) { $found = $p; break }
            }
            if (-not $found) {
                $cmd = Get-Command $t.Exe -ErrorAction SilentlyContinue
                if ($cmd) { $found = $cmd.Source }
            }
            $null = $rows.Add(@{
                Name     = $t.Name;  Status   = if ($found) { 'Installed' } else { 'Not Found' }
                Path     = if ($found) { $found } else { "winget: $($t.WingetId)" }
                WingetId = $t.WingetId; ChocoId = $t.ChocoId; Installed = [bool]$found
            })
        }
        $sync.Tools = $rows
        $sync.Done  = $true
    }).AddParameters(@{ sync = $tgSync }) | Out-Null
    $psTG.BeginInvoke() | Out-Null

    $tgTimer = New-Object System.Windows.Forms.Timer
    $tgTimer.Interval = 300
    $tgTimer.Add_Tick({
        if (-not $tgSync.Done) { return }
        $tgTimer.Stop()
        $gridTools.Rows.Clear()
        foreach ($t in $tgSync.Tools) {
            $idx = $gridTools.Rows.Add()
            $gridTools.Rows[$idx].Cells[0].Value = $t.Name
            $gridTools.Rows[$idx].Cells[1].Value = $t.Status
            $gridTools.Rows[$idx].Cells[2].Value = $t.Path
            $gridTools.Rows[$idx].DefaultCellStyle.BackColor = if ($t.Installed) { [System.Drawing.Color]::FromArgb(20, 60, 25) } else { $script:C_BG2 }
            $gridTools.Rows[$idx].DefaultCellStyle.ForeColor = if ($t.Installed) { $script:C_GREEN } else { $script:C_SUBTEXT }
            $gridTools.Rows[$idx].Tag = @{ WingetId = $t.WingetId; ChocoId = $t.ChocoId }
        }
        $btnRefreshTools.Enabled = $true
        $btnRefreshTools.Text    = "Refresh List"
        try { $psTG.Dispose() } catch {}
        Write-Log "Tools grid refreshed (async)"
    })
    $tgTimer.Start()
}

# Keep old name as alias so install callbacks still work
function Refresh-ToolsGrid { Refresh-ToolsGridAsync }

$btnRefreshTools.Add_Click({ Refresh-ToolsGridAsync })

$btnLaunchTool.Add_Click({
    if ($gridTools.SelectedRows.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Select a tool.", "No Selection"); return }
    $toolName = $gridTools.SelectedRows[0].Cells[0].Value
    $tagData  = $gridTools.SelectedRows[0].Tag
    $wingetId = if ($tagData -and $tagData.WingetId) { $tagData.WingetId } else { "" }
    $baseToolName = $toolName -replace " \(.*\)$","" -replace " - .*$",""
    if ($toolName -match "Zenmap") { $baseToolName = "zenmap" }
    if ($toolName -match "mitmproxy") { $baseToolName = "mitmweb" }
    $actualPath = Get-ToolPath $baseToolName
    if (-not $actualPath) {
        $installMsg = if ($wingetId) { "winget install $wingetId" } else { "choco install $($tagData.ChocoId)" }
        $res = [System.Windows.Forms.MessageBox]::Show("$toolName not installed.`r`n`r`nInstall: $installMsg`r`n`r`nInstall now?", "Not Found","YesNo","Question")
        if ($res -eq "Yes") { $btnInstallTools.PerformClick() }
        return
    }
    if (-not (Test-Path -LiteralPath $actualPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show("Path no longer valid: $actualPath","Launch Error"); return
    }
    try { Start-Process -FilePath $actualPath; Write-Log "Launched $toolName" }
    catch { [System.Windows.Forms.MessageBox]::Show("Failed: $($_.Exception.Message)","Error","OK","Error") }
})

$btnInstallTools.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show(
        "Install network tools via winget/Chocolatey?`r`n(Wireshark, Nmap, iperf3, PuTTY, WinSCP, curl, Speedtest, mRemoteNG, mitmproxy)`r`n`r`nRequires admin. Continue?",
        "Install Tools","YesNo","Question") -ne "Yes") { return }
    $installScript = @'
$ErrorActionPreference = 'Continue'
$useWinget = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
$useChoco  = $null -ne (Get-Command choco  -ErrorAction SilentlyContinue)
function Install-Tool { param([string]$WingetId,[string]$ChocoId,[string]$Name)
    Write-Host "Installing $Name..." -ForegroundColor Yellow
    if ($useWinget -and $WingetId) { winget install --id $WingetId --silent --accept-package-agreements --accept-source-agreements }
    elseif ($useChoco -and $ChocoId) { choco install $ChocoId -y }
    else { Write-Host "SKIP: no package manager for $Name" -ForegroundColor Red }
}
Install-Tool "WiresharkFoundation.Wireshark" "wireshark"  "Wireshark"
Install-Tool "Insecure.Nmap"                 "nmap"        "Nmap+Zenmap"
Install-Tool "ar51an.iPerf3"                 "iperf3"      "iperf3"
Install-Tool "PuTTY.PuTTY"                   "putty"       "PuTTY"
Install-Tool "WinSCP.WinSCP"                 "winscp"      "WinSCP"
Install-Tool "cURL.cURL"                     "curl"        "curl"
Install-Tool "Ookla.Speedtest.CLI"           "speedtest"   "Speedtest CLI"
Install-Tool "mRemoteNG.mRemoteNG"           "mremoteng"   "mRemoteNG"
Install-Tool "mitmproxy.mitmproxy"           "mitmproxy"   "mitmproxy"
Write-Host "`nDone! Press any key to close..." -ForegroundColor Green
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
'@
    $tempScript = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "netpro_install_$([System.IO.Path]::GetRandomFileName()).ps1")
    try {
        [System.IO.File]::WriteAllText($tempScript, $installScript, [System.Text.Encoding]::UTF8)
        Start-Process -FilePath powershell.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$tempScript`"" -Verb RunAs
        [System.Windows.Forms.MessageBox]::Show("Installation started. Wait for the elevated window to finish, then Refresh List.", "Installing")
        Write-Log "Started tools installation"
    } catch { [System.Windows.Forms.MessageBox]::Show("Failed: $($_.Exception.Message)","Error") }
    $t = New-Object System.Windows.Forms.Timer; $t.Interval = 300000
    $t.Add_Tick({ try { if (Test-Path -LiteralPath $tempScript) { Remove-Item -LiteralPath $tempScript -Force -ErrorAction Stop } } catch {}; $t.Stop(); $t.Dispose() })
    $t.Start()
})

$btnInstallNmap.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show(
        "Download NMAP 7.98 (~35 MB) from nmap.org?`r`nIncludes Zenmap GUI.`r`n`r`nContinue?",
        "Install NMAP","YesNo","Question") -ne "Yes") { return }
    $tmpPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "nmap-7.98-setup.exe")
    $dlForm = New-Object System.Windows.Forms.Form
    $dlForm.Text = "Downloading NMAP..."; $dlForm.Size = New-Object System.Drawing.Size(400, 100)
    $dlForm.StartPosition = "CenterScreen"; $dlForm.BackColor = $script:C_BG2; $dlForm.FormBorderStyle = "FixedDialog"
    $dlLbl = New-Object System.Windows.Forms.Label; $dlLbl.Text = "Downloading from nmap.org..."
    $dlLbl.Location = New-Object System.Drawing.Point(10,10); $dlLbl.Size = New-Object System.Drawing.Size(370,20); $dlLbl.ForeColor = $script:C_TEXT
    $dlPb = New-Object System.Windows.Forms.ProgressBar; $dlPb.Style = "Marquee"; $dlPb.MarqueeAnimationSpeed = 30
    $dlPb.Location = New-Object System.Drawing.Point(10,35); $dlPb.Size = New-Object System.Drawing.Size(370,25)
    $dlForm.Controls.AddRange(@($dlLbl,$dlPb)); $dlForm.Show(); $dlForm.Refresh()
    try {
        Invoke-WebRequest -Uri "https://nmap.org/dist/nmap-7.98-setup.exe" -OutFile $tmpPath -UseBasicParsing -ErrorAction Stop
        $dlForm.Close()
        if (-not (Test-Path -LiteralPath $tmpPath -PathType Leaf)) { throw "Download incomplete." }
        [System.Windows.Forms.MessageBox]::Show("NMAP downloaded. The installer will launch.`r`nEnsure 'Zenmap GUI' is checked.", "Ready to Install")
        Start-Process -FilePath $tmpPath -Wait
        [System.Windows.Forms.MessageBox]::Show("Installation complete! Click Refresh List.", "Done")
        Write-Log "NMAP 7.98 installed"
        Refresh-ToolsGrid
    } catch {
        $dlForm.Close()
        [System.Windows.Forms.MessageBox]::Show("Failed:`r`n$($_.Exception.Message)`r`n`r`nDownload manually: https://nmap.org/download.html","Error","OK","Error")
        Write-Log "NMAP install failed: $($_.Exception.Message)" "ERROR"
    } finally {
        try { if (Test-Path -LiteralPath $tmpPath -ErrorAction SilentlyContinue) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction Stop } } catch {}
    }
})

# ============================================================
# INITIALIZATION -- ASYNC (3 parallel runspaces, non-blocking)
# ============================================================

# Shared sync hashtable for runspace -> UI communication
$script:InitSync = [Hashtable]::Synchronized(@{
    Adapters   = $null   # array of PSCustomObject
    Conn       = $null   # hashtable {DNS,ICMP,HTTP}
    ExternalIP = $null   # string
    Tools      = $null   # array of hashtable rows
    Done       = 0       # count of completed runspaces (3 = all done)
})

function Start-AsyncInit {
    $script:InitSync.Adapters   = $null
    $script:InitSync.Conn       = $null
    $script:InitSync.ExternalIP = $null
    $script:InitSync.Tools      = $null
    $script:InitSync.Done       = 0

    $lblStatus.Text      = "Loading..."
    $lblStatus.ForeColor = $script:C_YELLOW
    $lblExternalIP.Text  = "External IP: Checking..."
    $lblExternalIP.ForeColor = $script:C_YELLOW
    $gridAdapters.Rows.Clear()
    $btnRefreshOverview.Enabled = $false

    # Helper: create a ready-to-use PS runspace
    $mkRS = {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
        $ps  = [System.Management.Automation.PowerShell]::Create($iss)
        $ps
    }

    # ---- RUNSPACE A: Network Adapters ----------------------------------------
    $psA = & $mkRS
    $null = $psA.AddScript({
        param($sync, $logFile)
        try {
            $adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
            $result = [System.Collections.ArrayList]::new()
            foreach ($adapter in $adapters) {
                try {
                    $ipv4Obj = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
                    $ipv6Obj = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                               Where-Object { $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
                    $gwObj   = Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
                    $dnsRaw  = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
                    $null = $result.Add([PSCustomObject]@{
                        Name    = $adapter.Name
                        Type    = $adapter.MediaType
                        Speed   = if ($adapter.LinkSpeed) { $adapter.LinkSpeed } else { 'N/A' }
                        IPv4    = if ($ipv4Obj) { $ipv4Obj.IPAddress }    else { 'N/A' }
                        IPv6    = if ($ipv6Obj) { $ipv6Obj.IPAddress }    else { 'N/A' }
                        MAC     = $adapter.MacAddress
                        Gateway = if ($gwObj)   { $gwObj.NextHop }        else { 'N/A' }
                        Subnet  = if ($ipv4Obj) { "/$($ipv4Obj.PrefixLength)" } else { 'N/A' }
                        DNS     = if ($dnsRaw)  { $dnsRaw -join ', ' }    else { 'N/A' }
                    })
                } catch {}
            }
            $sync.Adapters = $result
        } catch {}
        $sync.Done++
        try { Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][INFO] Async adapter load complete" -Encoding UTF8 -EA Stop } catch {}
    }).AddParameters(@{ sync = $script:InitSync; logFile = $script:LogFile }) | Out-Null

    # ---- RUNSPACE B: Connectivity + External IP ------------------------------
    $psB = & $mkRS
    $null = $psB.AddScript({
        param($sync, $logFile)
        try {
            $conn = @{ DNS = $false; ICMP = $false; HTTP = $false }
            try { $null = Resolve-DnsName -Name 'google.com' -ErrorAction Stop; $conn.DNS = $true } catch {}
            try { $conn.ICMP = [bool](Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction Stop) } catch {}
            try {
                $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
                $conn.HTTP = ($r.StatusCode -eq 200)
            } catch {}
            $sync.Conn = $conn
        } catch {}
        # External IP
        try {
            $ep = @('https://api.ipify.org','https://icanhazip.com','https://ifconfig.me/ip')
            foreach ($uri in $ep) {
                try {
                    $r = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
                    $ip = $r.Content.Trim()
                    if ($ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { $sync.ExternalIP = $ip; break }
                } catch {}
            }
            if (-not $sync.ExternalIP) { $sync.ExternalIP = 'Unable to detect' }
        } catch { $sync.ExternalIP = 'Unable to detect' }
        $sync.Done++
        try { Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][INFO] Async connectivity+IP load complete" -Encoding UTF8 -EA Stop } catch {}
    }).AddParameters(@{ sync = $script:InitSync; logFile = $script:LogFile }) | Out-Null

    # ---- RUNSPACE C: Tools Grid (Get-Command is slow, run off-thread) --------
    $psC = & $mkRS
    $null = $psC.AddScript({
        param($sync, $logFile)
        $tools = @(
            @{Name='Wireshark';            Exe='Wireshark';  WingetId='WiresharkFoundation.Wireshark'; ChocoId='wireshark';
              Paths=@('C:\Program Files\Wireshark\Wireshark.exe','C:\Program Files (x86)\Wireshark\Wireshark.exe','C:\ProgramData\chocolatey\bin\Wireshark.exe')}
            @{Name='Nmap (CLI)';           Exe='nmap';       WingetId='Insecure.Nmap';   ChocoId='nmap';
              Paths=@('C:\Program Files (x86)\Nmap\nmap.exe','C:\Program Files\Nmap\nmap.exe','C:\ProgramData\chocolatey\bin\nmap.exe')}
            @{Name='Zenmap (Nmap GUI)';    Exe='zenmap';     WingetId='Insecure.Nmap';   ChocoId='nmap';
              Paths=@('C:\Program Files (x86)\Nmap\zenmap.exe','C:\Program Files\Nmap\zenmap.exe','C:\Program Files (x86)\Nmap\Zenmap.exe')}
            @{Name='iperf3';               Exe='iperf3';     WingetId='ar51an.iPerf3';   ChocoId='iperf3';
              Paths=@('C:\ProgramData\chocolatey\bin\iperf3.exe',"$env:LOCALAPPDATA\Microsoft\WinGet\Packages\ar51an.iPerf3_Microsoft.Winget.Source_8wekyb3d8bbwe\iperf3.exe")}
            @{Name='PuTTY';                Exe='putty';      WingetId='PuTTY.PuTTY';     ChocoId='putty';
              Paths=@('C:\Program Files\PuTTY\putty.exe','C:\Program Files (x86)\PuTTY\putty.exe','C:\ProgramData\chocolatey\bin\putty.exe')}
            @{Name='WinSCP';               Exe='winscp';     WingetId='WinSCP.WinSCP';   ChocoId='winscp';
              Paths=@('C:\Program Files\WinSCP\WinSCP.exe','C:\Program Files (x86)\WinSCP\WinSCP.exe')}
            @{Name='curl';                 Exe='curl';       WingetId='cURL.cURL';        ChocoId='curl';
              Paths=@('C:\ProgramData\chocolatey\bin\curl.exe','C:\Windows\System32\curl.exe')}
            @{Name='wget';                 Exe='wget';       WingetId='';                 ChocoId='wget';
              Paths=@('C:\ProgramData\chocolatey\bin\wget.exe')}
            @{Name='TCPing';               Exe='tcping';     WingetId='';                 ChocoId='tcping';
              Paths=@('C:\ProgramData\chocolatey\bin\tcping.exe','C:\ProgramData\chocolatey\lib\tcping\tools\tcping.exe')}
            @{Name='Speedtest CLI';        Exe='speedtest';  WingetId='Ookla.Speedtest.CLI'; ChocoId='speedtest';
              Paths=@('C:\Program Files\Ookla\Speedtest CLI\speedtest.exe','C:\ProgramData\chocolatey\bin\speedtest.exe',"$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Ookla.Speedtest.CLI_Microsoft.Winget.Source_8wekyb3d8bbwe\speedtest.exe")}
            @{Name='OpenSSH';              Exe='ssh';        WingetId='Microsoft.OpenSSH.Beta'; ChocoId='openssh';
              Paths=@('C:\Windows\System32\OpenSSH\ssh.exe','C:\ProgramData\chocolatey\bin\ssh.exe')}
            @{Name='mRemoteNG';            Exe='mremoteng';  WingetId='mRemoteNG.mRemoteNG'; ChocoId='mremoteng';
              Paths=@('C:\Program Files\mRemoteNG\mRemoteNG.exe','C:\Program Files (x86)\mRemoteNG\mRemoteNG.exe')}
            @{Name='mitmproxy (web proxy)';Exe='mitmweb';    WingetId='mitmproxy.mitmproxy'; ChocoId='mitmproxy';
              Paths=@('C:\Program Files\mitmproxy\mitmweb.exe','C:\ProgramData\chocolatey\bin\mitmweb.exe')}
        )
        $rows = [System.Collections.ArrayList]::new()
        foreach ($t in $tools) {
            $found = $null
            foreach ($p in $t.Paths) {
                if ([System.IO.File]::Exists($p)) { $found = $p; break }
            }
            if (-not $found) {
                # Fallback: PATH lookup (slow, but only reached if static paths miss)
                $cmd = Get-Command $t.Exe -ErrorAction SilentlyContinue
                if ($cmd) { $found = $cmd.Source }
            }
            $null = $rows.Add(@{
                Name      = $t.Name
                Status    = if ($found) { 'Installed' } else { 'Not Found' }
                Path      = if ($found) { $found } else { "winget: $($t.WingetId)" }
                WingetId  = $t.WingetId
                ChocoId   = $t.ChocoId
                Installed = [bool]$found
            })
        }
        $sync.Tools = $rows
        $sync.Done++
        try { Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][INFO] Async tools grid load complete" -Encoding UTF8 -EA Stop } catch {}
    }).AddParameters(@{ sync = $script:InitSync; logFile = $script:LogFile }) | Out-Null

    # Fire all three
    $asyncA = $psA.BeginInvoke()
    $asyncB = $psB.BeginInvoke()
    $asyncC = $psC.BeginInvoke()

    # Poll on UI thread via WinForms Timer -- fires every 300ms, safe
    $script:InitTimer = New-Object System.Windows.Forms.Timer
    $script:InitTimer.Interval = 300
    $script:InitTimer.Add_Tick({
        $s    = $script:InitSync
        $done = $s.Done

        # Apply adapters the moment RS-A completes
        if ($null -ne $s.Adapters -and $gridAdapters.Rows.Count -eq 0) {
            $gridAdapters.Rows.Clear()
            foreach ($a in $s.Adapters) {
                $idx = $gridAdapters.Rows.Add()
                $gridAdapters.Rows[$idx].Cells[0].Value = $a.Name
                $gridAdapters.Rows[$idx].Cells[1].Value = $a.Type
                $gridAdapters.Rows[$idx].Cells[2].Value = $a.Speed
                $gridAdapters.Rows[$idx].Cells[3].Value = $a.IPv4
                $gridAdapters.Rows[$idx].Cells[4].Value = $a.IPv6
                $gridAdapters.Rows[$idx].Cells[5].Value = $a.MAC
                $gridAdapters.Rows[$idx].Cells[6].Value = $a.Gateway
                $gridAdapters.Rows[$idx].Cells[7].Value = $a.Subnet
                $gridAdapters.Rows[$idx].Cells[8].Value = $a.DNS
            }
            if ($s.Adapters.Count -gt 0) {
                $p = $s.Adapters[0]
                $lblAdapterInfo.Text = "Primary: $($p.Name)  |  IPv4: $($p.IPv4)  |  Gateway: $($p.Gateway)  |  DNS: $($p.DNS)"
            }
        }

        # Apply connectivity + IP the moment RS-B completes
        if ($null -ne $s.Conn -and $null -ne $s.ExternalIP) {
            $ok = $s.Conn.DNS -and $s.Conn.ICMP
            $lblStatus.Text = "Internet: DNS=$($s.Conn.DNS)  |  ICMP=$($s.Conn.ICMP)  |  HTTP=$($s.Conn.HTTP)  |  $env:COMPUTERNAME"
            $lblStatus.ForeColor = if ($ok) { $script:C_GREEN } else { $script:C_RED }
            $script:ExternalIP = $s.ExternalIP
            $lblExternalIP.Text = "External IP: $($s.ExternalIP)"
            $lblExternalIP.ForeColor = if ($s.ExternalIP -match '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}') { $script:C_GREEN } else { $script:C_RED }
        }

        # Apply tools grid the moment RS-C completes
        if ($null -ne $s.Tools -and $gridTools.Rows.Count -eq 0) {
            $gridTools.Rows.Clear()
            foreach ($t in $s.Tools) {
                $idx = $gridTools.Rows.Add()
                $gridTools.Rows[$idx].Cells[0].Value = $t.Name
                $gridTools.Rows[$idx].Cells[1].Value = $t.Status
                $gridTools.Rows[$idx].Cells[2].Value = $t.Path
                $gridTools.Rows[$idx].DefaultCellStyle.BackColor = if ($t.Installed) { [System.Drawing.Color]::FromArgb(20, 60, 25) } else { $script:C_BG2 }
                $gridTools.Rows[$idx].DefaultCellStyle.ForeColor = if ($t.Installed) { $script:C_GREEN } else { $script:C_SUBTEXT }
                $gridTools.Rows[$idx].Tag = @{ WingetId = $t.WingetId; ChocoId = $t.ChocoId }
            }
        }

        # All 3 done
        if ($done -ge 3) {
            $script:InitTimer.Stop()
            $btnRefreshOverview.Enabled = $true
            try { $psA.Dispose() } catch {}
            try { $psB.Dispose() } catch {}
            try { $psC.Dispose() } catch {}
            Write-Log "Paladin Network Pro v3.1.0 initialized | Site: $SiteName | Machine: $env:COMPUTERNAME"
        }
    })
    $script:InitTimer.Start()
}

$form.Add_Shown({ Start-AsyncInit })
$btnRefreshOverview.Add_Click({
    if ($null -ne $script:InitTimer -and $script:InitTimer.Enabled) { return }  # already loading
    # Reset tool/adapter rows so the tick handler re-applies them
    $gridTools.Rows.Clear()
    $gridAdapters.Rows.Clear()
    Start-AsyncInit
})
$form.Add_FormClosing({
    if ($script:PingTimer) { $script:PingTimer.Stop() }
    if ($script:InitTimer) { $script:InitTimer.Stop() }
})

[void]$form.ShowDialog()

