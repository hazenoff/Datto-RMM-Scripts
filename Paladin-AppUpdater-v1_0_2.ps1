#Requires -Version 3.0
# =============================================================================
# Paladin Application Updater [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.2
# Context: NT AUTHORITY\SYSTEM (Datto entry) -> user session (GUI mode)
#
# MODES:
#   Inventory -- Scan all installed apps, report available updates. No changes.
#   Silent    -- Auto-update all non-excluded apps. No user interaction.
#   GUI       -- Launch WPF tech interface on logged-on user desktop.
#                Tech reviews and selects updates before applying.
#
# EXCLUSION TIERS:
#   Hard (Tier 1) -- Never updated. No override. Remote access, AV, RMM agents,
#                    LOB software known to break on silent update.
#   Soft (Tier 2) -- Excluded by default. Override with allowSoftExclusions=true.
#                    Version-sensitive apps, GPU drivers, kernel components.
#   Deferred (T3) -- Updated but reboot deferred unless allowReboot=true.
#
# INPUT VARIABLES:
#   mode                (String)  -- Inventory | Silent | GUI (default: Inventory)
#   allowSoftExclusions (Boolean) -- true = also update Tier 2 apps (default: false)
#   customExclusions    (String)  -- comma-separated WinGet IDs to also exclude
#   allowReboot         (Boolean) -- true = reboot after reboot-required updates
#   updateTimeoutSec    (String)  -- per-package timeout seconds (default: 120)
#   includeUnknown      (Boolean) -- true = include apps with unknown version
#
# LOG:  C:\ProgramData\Paladin\AppUpdater\AppUpdater.log
# UDF:  Slot 16 (PALADIN-APPUPDATE)
# EXIT: 0 = success or inventory complete, 1 = one or more updates failed
# =============================================================================

param([switch]$GUIMode)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer      = '1.0.2'
$LogDir         = 'C:\ProgramData\Paladin\AppUpdater'
$LogFile        = "$LogDir\AppUpdater.log"
$SelfDest       = "$LogDir\Paladin-AppUpdater-GUI.ps1"
$TaskName       = 'Paladin_AppUpdater_GUI'
$UDF_SLOT       = 16   # PALADIN-APPUPDATE
$MaxLogMB       = 10
$DefaultTimeout = 120

# Input variables
$Mode               = $env:mode
$AllowSoftExcl      = ($env:allowSoftExclusions -eq 'true')
$CustomExclStr      = $env:customExclusions
$AllowReboot        = ($env:allowReboot -eq 'true')
$TimeoutStr         = $env:updateTimeoutSec
$IncludeUnknown     = ($env:includeUnknown -eq 'true')

if ([string]::IsNullOrEmpty($Mode)) { $Mode = 'Inventory' }
if ($Mode -notin @('Inventory','Silent','GUI')) {
    Write-Host "Invalid mode '$Mode'. Must be Inventory, Silent, or GUI. Defaulting to Inventory."
    $Mode = 'Inventory'
}
$UpdateTimeout = $DefaultTimeout
try { if ($TimeoutStr) { $UpdateTimeout = [int]$TimeoutStr } } catch {}

$CustomExclusions = @()
if (-not [string]::IsNullOrEmpty($CustomExclStr)) {
    $CustomExclusions = $CustomExclStr -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

# =============================================================================
# EXCLUSION LISTS
# =============================================================================

# TIER 1 -- Hard exclusions. Never touched. No override.
$HardExclPatterns = @(
    'Intuit.QuickBooks',        # QuickBooks -- reboot loops, breaks multi-user
    'Intuit.QuickBooksDesktop', # QB variant
    'Fortinet.FortiClientVPN',  # Replaces itself with different product
    'Fortinet.FortiClient',     # FortiClient variants
    'Citrix.Workspace',         # Exit 3010 on every upgrade, UI prompts
    'CitrixOnlinePluginPackWeb',# Citrix alternate ID
    'Autodesk.',                # AutoCAD/Autodesk -- license-tied, no silent
    'Microsoft.Office',         # Managed by Click-to-Run
    'Microsoft.Teams',          # Own updater, WinGet causes profile corruption
    'AnyDeskSoftwareGmbH.',     # Kills active remote session
    'TeamViewer.TeamViewer',    # Kills active remote session
    'RealVNC.',                 # Kills active remote session
    'uvnc.',                    # UltraVNC -- kills remote session
    'Datto.',                   # Never touch RMM agent from RMM
    'CentraStage.',             # Never touch RMM agent from RMM
    'ESET.',                    # AV -- managed upgrade only
    'Malwarebytes.',            # AV -- managed upgrade only
    'SentinelOne.',             # EDR -- requires console token
    'CrowdStrike.',             # EDR -- requires console token
    'Sophos.',                  # AV -- managed upgrade only
    'Symantec.',                # AV -- managed upgrade only
    'McAfee.',                  # AV -- managed upgrade only
    'Norton.',                  # AV -- managed upgrade only
    'BitDefender.',             # AV -- managed upgrade only
    'TrendMicro.',              # AV -- managed upgrade only
    'Webroot.',                 # AV -- managed upgrade only
    'Cylance.',                 # EDR -- managed upgrade only
    'Carbon Black.',            # EDR -- managed upgrade only
    'Microsoft.OneDrive'        # Managed by own updater
)

# TIER 2 -- Soft exclusions. Excluded by default, allowSoftExclusions=true overrides.
$SoftExclPatterns = @(
    'Sage.',                            # Payroll version-locked
    'Microsoft.SQLServer',              # DB version upgrades are migrations
    'Oracle.JavaRuntimeEnvironment',    # LOB dependencies
    'Oracle.JDK',                       # Java dev kit
    'Python.',                          # Breaks virtualenvs
    'Microsoft.DotNet',                 # Multiple versions intentional
    'Microsoft.PowerShell',             # Installer mismatch, WinGet skips anyway
    'Nvidia.GeForce',                   # GPU driver -- reboot required
    'Nvidia.CUDA',                      # CUDA toolkit
    'AMD.Software',                     # GPU driver -- reboot required
    'AdvancedMicroDevices.',            # AMD variants
    'Intel.GraphicsCommandCenter',      # GPU driver -- reboot required
    'Intel.Arc',                        # Intel Arc GPU
    'WinFsp.',                          # Kernel driver -- reboot required
    'Elgato.',                          # USB driver chain -- reboot required
    'Corsair.',                         # USB/HID driver -- reboot
    'Logitech.',                        # USB/HID driver -- reboot
    'Razer.',                           # USB/HID driver -- reboot
    'SteelSeries.',                     # USB/HID driver -- reboot
    'Microsoft.VisualStudio.'           # VS IDE -- major installs, version sensitive
)

# TIER 3 -- Reboot-deferred. Updated but reboot flagged unless allowReboot=true.
$DeferredPatterns = @(
    'Microsoft.VCRedist',               # Visual C++ redistributables
    'Microsoft.DirectX',                # DirectX runtime
    'Microsoft.WebView2'                # WebView2 runtime
)

# SELF-UPDATE patterns -- apps with embedded updaters where WinGet version
# detection is unreliable after update. Shown in GUI with SELF-UPD badge,
# unchecked by default. WinGet may still report them as needing update even
# after a successful install due to version string mismatch.
$SelfUpdatePatterns = @(
    'StartIsBack.StartIsBack',          # Shell extension, own update channel
    '8x8.Work',                         # Embedded auto-updater
    'Slack.Slack',                      # Slack updates itself
    'Zoom.Zoom',                        # Zoom has own updater
    'Spotify.Spotify',                  # Own updater
    'Discord.Discord',                  # Own updater
    'Grammarly.',                       # Own updater
    'Dropbox.Dropbox',                  # Own updater
    'Box.Box',                          # Own updater
    'LogMeIn.',                         # Own updater
    'GoTo.',                            # GoTo products own updater
    'Webex.',                           # Cisco Webex own updater
    'RingCentral.'                      # Own updater
)

# WinGet -> Chocolatey ID mapping for common mismatches
$ChocoMap = @{
    'Notepad++.Notepad++'              = 'notepadplusplus'
    '7zip.7zip'                        = '7zip'
    'Google.Chrome'                    = 'googlechrome'
    'Mozilla.Firefox'                  = 'firefox'
    'VideoLAN.VLC'                     = 'vlc'
    'Adobe.Acrobat.Reader.64-bit'      = 'adobereader'
    'Adobe.Acrobat.Reader.32-bit'      = 'adobereader'
    'Zoom.Zoom'                        = 'zoom'
    'Microsoft.PowerToys'              = 'powertoys'
    'WinSCP.WinSCP'                    = 'winscp'
    'PuTTY.PuTTY'                      = 'putty'
    'Greenshot.Greenshot'              = 'greenshot'
    'SumatraPDF.SumatraPDF'            = 'sumatrapdf'
    'KeePass.KeePass'                  = 'keepass'
    'Git.Git'                          = 'git'
    'Microsoft.VisualStudioCode'       = 'vscode'
    'Malwarebytes.Malwarebytes'        = 'malwarebytes'
    'SlackTechnologies.Slack'          = 'slack'
    'Discord.Discord'                  = 'discord'
    'Spotify.Spotify'                  = 'spotify'
}

# =============================================================================
# HELPERS
# =============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try {
        if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force -EA Stop | Out-Null }
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile -EA SilentlyContinue).Length / 1MB) -gt $MaxLogMB) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.bak" -Force -EA SilentlyContinue
        }
        Add-Content -Path $LogFile -Value $line -EA SilentlyContinue
    } catch {}
}

function Write-Sep  { Write-Log ('=' * 64) }
function Write-Sep2 { Write-Log ('-' * 64) }

function Set-DattoUDF {
    param([int]$Slot, [string]$Value)
    $trimmed = if ($Value.Length -gt 255) { $Value.Substring(0,255) } else { $Value }
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' `
            -Name "Custom$Slot" -PropertyType String -Value $trimmed `
            -Force -EA Stop | Out-Null
        Write-Log "UDF$Slot => $trimmed"
    } catch { Write-Log "WARN: UDF$Slot write failed: $($_.Exception.Message)" }
}

function Get-LoggedOnUser {
    try {
        $cs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
        if ($cs -and $cs.UserName) { return ($cs.UserName -split '\\')[-1] }
    } catch {}
    try {
        $qu = & query user 2>&1
        foreach ($l in $qu) {
            if ($l -match 'Active') { return ($l.Trim() -split '\s+')[0].TrimStart('>') }
        }
    } catch {}
    return $null
}

function Get-ExclusionTier {
    param([string]$WinGetID)
    if ([string]::IsNullOrEmpty($WinGetID)) { return 'None' }
    $id = $WinGetID

    # Check custom exclusions first
    foreach ($cx in $CustomExclusions) {
        if ($id -like "*$cx*") { return 'Custom' }
    }
    # Hard tier
    foreach ($p in $HardExclPatterns) {
        if ($id -like "$p*" -or $id -eq $p) { return 'Hard' }
    }
    # Soft tier
    foreach ($p in $SoftExclPatterns) {
        if ($id -like "$p*" -or $id -eq $p) { return 'Soft' }
    }
    # Deferred tier
    foreach ($p in $DeferredPatterns) {
        if ($id -like "$p*" -or $id -eq $p) { return 'Deferred' }
    }
    # Self-update tier -- own embedded updater, WinGet version detection unreliable
    foreach ($p in $SelfUpdatePatterns) {
        if ($id -like "$p*" -or $id -eq $p) { return 'SelfUpdate' }
    }
    return 'None'
}

function Test-WinGet {
    try { $wg = Get-Command winget.exe -EA SilentlyContinue; return ($null -ne $wg) } catch { return $false }
}

function Test-Chocolatey {
    try { $ch = Get-Command choco.exe -EA SilentlyContinue; return ($null -ne $ch) } catch { return $false }
}

function Install-WinGet {
    # Note: SYSTEM cannot install MSIX packages -- this will fail on Datto agents.
    # Attempt anyway; if WinGet is already present user-side it will be found after.
    try {
        $url     = 'https://aka.ms/getwinget'
        $outPath = "$env:TEMP\AppInstaller.msixbundle"
        (New-Object System.Net.WebClient).DownloadFile($url, $outPath)
        & Add-AppxPackage -Path $outPath -EA Stop
        Start-Sleep -Seconds 5
        if (Test-WinGet) { Write-Log 'WinGet installed successfully'; return $true }
    } catch {
        # Suppress SYSTEM/MSIX restriction error -- check if WinGet already available
        if (Test-WinGet) {
            Write-Log 'WinGet already available (MSIX install skipped -- SYSTEM context)'
            return $true
        }
        Write-Log "WARN: WinGet install failed: $($_.Exception.Message)" 'WARN'
    }
    return $false
}

# =============================================================================
# INVENTORY -- GET AVAILABLE UPDATES
# =============================================================================

function Get-AvailableUpdates {
    Write-Log 'Scanning for available updates via WinGet...'
    $updates = @()

    if (-not (Test-WinGet)) {
        Write-Log 'WinGet not available. Attempting install...'
        if (-not (Install-WinGet)) {
            Write-Log 'ERROR: WinGet unavailable and could not be installed.' 'WARN'
            return $updates
        }
    }

    try {
        # winget upgrade lists all apps with available updates
        $rawArgs = @('upgrade', '--include-unknown')
        if ($IncludeUnknown) { $rawArgs += '--include-unknown' }
        $raw = & winget.exe upgrade 2>&1
        $lines = $raw | Where-Object { $_ -match '\S' }

        # Parse the winget table output
        # Format: Name   Id   Version   Available   Source
        $headerFound = $false
        $headerLine  = ''
        $nameEnd = 0; $idEnd = 0; $verEnd = 0; $availEnd = 0

        foreach ($line in $lines) {
            # Find the header line
            if ($line -match 'Name\s+Id\s+Version\s+Available') {
                $headerFound = $true
                $headerLine  = $line
                $nameEnd     = $line.IndexOf('Id')
                $idEnd       = $line.IndexOf('Version')
                $verEnd      = $line.IndexOf('Available')
                $availEnd    = $line.IndexOf('Source')
                if ($availEnd -lt 0) { $availEnd = $line.Length }
                continue
            }
            if (-not $headerFound) { continue }
            # Skip separator lines
            if ($line -match '^[-\s]+$') { continue }
            # Skip summary lines
            if ($line -match 'upgrade(s)? available|package(s)? have') { continue }
            # Parse data line
            if ($line.Length -lt $nameEnd) { continue }
            try {
                $name      = if ($line.Length -ge $nameEnd) { $line.Substring(0, $nameEnd).Trim() } else { '' }
                $id        = if ($line.Length -ge $idEnd)   { $line.Substring($nameEnd, $idEnd - $nameEnd).Trim() } else { '' }
                $version   = if ($line.Length -ge $verEnd)  { $line.Substring($idEnd, $verEnd - $idEnd).Trim() } else { '' }
                $available = if ($line.Length -ge $availEnd){ $line.Substring($verEnd, $availEnd - $verEnd).Trim() } else { '' }

                if ([string]::IsNullOrEmpty($id) -or [string]::IsNullOrEmpty($available)) { continue }
                if ($available -eq 'Unknown' -and -not $IncludeUnknown) { continue }

                $tier = Get-ExclusionTier -WinGetID $id
                $chocoID = if ($ChocoMap.ContainsKey($id)) { $ChocoMap[$id] } else { '' }

                $updates += @{
                    Name        = $name
                    WinGetID    = $id
                    Version     = $version
                    Available   = $available
                    Source      = 'WinGet'
                    Tier        = $tier
                    ChocoID     = $chocoID
                    RebootReq   = ($tier -eq 'Deferred')
                }
            } catch { continue }
        }
    } catch {
        Write-Log "ERROR: winget upgrade scan failed: $($_.Exception.Message)" 'WARN'
    }

    Write-Log "Scan complete: $($updates.Count) update(s) found"
    return $updates
}

# =============================================================================
# UPDATE ENGINE
# =============================================================================

function Invoke-UpdatePackage {
    param([hashtable]$App)

    $id   = $App.WinGetID
    $name = $App.Name
    Write-Log "  Updating: $name ($id) -- $($App.Version) -> $($App.Available)"

    # Attempt WinGet
    $wingetOk = $false
    try {
        $job = Start-Job -ScriptBlock {
            param($wgid)
            & winget.exe upgrade --id $wgid --silent --accept-package-agreements `
                --accept-source-agreements --scope machine 2>&1
        } -ArgumentList $id

        $result = Wait-Job $job -Timeout $UpdateTimeout
        if ($null -eq $result) {
            Stop-Job $job -EA SilentlyContinue
            Remove-Job $job -EA SilentlyContinue
            Write-Log "  [TIMEOUT] $name -- installer did not complete in ${UpdateTimeout}s. Skipped." 'WARN'
            return 'Timeout'
        }

        $output = Receive-Job $job
        Remove-Job $job -EA SilentlyContinue
        $outputStr = ($output -join ' ')

        if ($LASTEXITCODE -eq 0 -or $outputStr -match 'Successfully installed' -or $outputStr -match 'No available upgrade') {
            Write-Log "  [UPDATED] $name via WinGet"
            $wingetOk = $true
            return 'Updated'
        } elseif ($outputStr -match 'No applicable upgrade') {
            Write-Log "  [SKIP] $name -- no applicable upgrade found (scope/arch mismatch)"
            return 'Skipped'
        } else {
            Write-Log "  WinGet result: $outputStr"
        }
    } catch {
        Write-Log "  WinGet attempt failed: $($_.Exception.Message)"
    }

    # Fallback: Chocolatey
    if (-not $wingetOk -and (Test-Chocolatey)) {
        $chocoID = $App.ChocoID
        if ([string]::IsNullOrEmpty($chocoID)) {
            Write-Log "  [FAIL] $name -- WinGet failed, no Chocolatey mapping"
            return 'Failed'
        }
        try {
            Write-Log "  Trying Chocolatey fallback: $chocoID"
            $job = Start-Job -ScriptBlock {
                param($cid)
                & choco.exe upgrade $cid -y --no-progress --limit-output 2>&1
            } -ArgumentList $chocoID

            $result = Wait-Job $job -Timeout $UpdateTimeout
            if ($null -eq $result) {
                Stop-Job $job -EA SilentlyContinue
                Remove-Job $job -EA SilentlyContinue
                Write-Log "  [TIMEOUT] $name (Chocolatey) -- skipped." 'WARN'
                return 'Timeout'
            }
            $output = Receive-Job $job
            Remove-Job $job -EA SilentlyContinue
            if (($output -join ' ') -match 'upgraded|already installed') {
                Write-Log "  [UPDATED] $name via Chocolatey"
                return 'UpdatedChoco'
            }
        } catch { Write-Log "  Chocolatey fallback failed: $($_.Exception.Message)" }
    }

    Write-Log "  [FAILED] $name -- all update attempts failed" 'WARN'
    return 'Failed'
}

# =============================================================================
# SYSTEM LAUNCHER (non-GUI modes)
# =============================================================================

if (-not $GUIMode) {

    if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

    $siteName = $env:CS_PROFILE_NAME
    if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }

    Write-Sep
    Write-Log "Paladin Application Updater v$ScriptVer | Site: $siteName | Machine: $env:COMPUTERNAME"
    Write-Log "Mode: $Mode | SoftExcl: $AllowSoftExcl | AllowReboot: $AllowReboot | Timeout: ${UpdateTimeout}s"
    if ($CustomExclusions.Count -gt 0) { Write-Log "Custom exclusions: $($CustomExclusions -join ', ')" }
    Write-Sep

    $hasWinGet = Test-WinGet
    $hasChoco  = Test-Chocolatey
    Write-Log "WinGet: $(if ($hasWinGet) {'Available'} else {'Not found'}) | Chocolatey: $(if ($hasChoco) {'Available'} else {'Not found'})"

    if (-not $hasWinGet) {
        Write-Log 'Attempting WinGet installation...'
        $hasWinGet = Install-WinGet
    }

    if (-not $hasWinGet -and -not $hasChoco) {
        Write-Log 'ERROR: Neither WinGet nor Chocolatey available. Cannot proceed.' 'WARN'
        Set-DattoUDF -Slot $UDF_SLOT -Value "ERROR $(Get-Date -Format 'yyyy-MM-dd') | No package manager available"
        exit 1
    }

    # --- INVENTORY MODE ---
    if ($Mode -eq 'Inventory') {
        $updates = Get-AvailableUpdates

        $safeCount = 0; $hardCount = 0; $softCount = 0; $deferCount = 0; $customCount = 0; $selfUpdCount = 0
        foreach ($u in $updates) {
            switch ($u.Tier) {
                'Hard'       { $hardCount++ }
                'Soft'       { $softCount++ }
                'Deferred'   { $deferCount++ }
                'Custom'     { $customCount++ }
                'SelfUpdate' { $selfUpdCount++ }
                default      { $safeCount++ }
            }
        }

        Write-Sep2
        Write-Log "INVENTORY RESULTS: $($updates.Count) update(s) available"
        Write-Log ("  {0,-5} Safe to update silently" -f $safeCount)
        Write-Log ("  {0,-5} Hard excluded (will not be updated)" -f $hardCount)
        Write-Log ("  {0,-5} Soft excluded (update with allowSoftExclusions=true)" -f $softCount)
        Write-Log ("  {0,-5} Reboot-deferred" -f $deferCount)
        Write-Log ("  {0,-5} Self-updating apps (own updater)" -f $selfUpdCount)
        Write-Log ("  {0,-5} Custom excluded" -f $customCount)

        if ($updates.Count -gt 0) {
            Write-Sep2
            Write-Log ("  {0,-45} {1,-15} {2,-15} {3}" -f 'Name','Current','Available','Status')
            Write-Log ("  {0,-45} {1,-15} {2,-15} {3}" -f ('-'*44),('-'*14),('-'*14),('-'*10))
            foreach ($u in ($updates | Sort-Object { $_.Tier } )) {
                $status = switch ($u.Tier) {
                    'Hard'     { 'HARD-EXCL' }
                    'Soft'     { 'SOFT-EXCL' }
                    'Deferred' { 'REBOOT-DEF' }
                    'Custom'   { 'CUSTOM-EXCL' }
                    'SelfUpdate' { 'SELF-UPD' }
                    default    { 'SAFE' }
                }
                $title = if ($u.Name.Length -gt 44) { $u.Name.Substring(0,41)+'...' } else { $u.Name }
                Write-Log ("  {0,-45} {1,-15} {2,-15} {3}" -f $title, $u.Version, $u.Available, $status)
            }
        }

        Write-Sep
        $topSafe = ($updates | Where-Object { $_.Tier -eq 'None' } | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ','
        $udfMsg  = "INV $(Get-Date -Format 'yyyy-MM-dd') | Updates:$($updates.Count) Safe:$safeCount HardExcl:$hardCount SoftExcl:$softCount | $topSafe"
        Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg
        exit 0
    }

    # --- GUI MODE -- launch on user desktop ---
    if ($Mode -eq 'GUI') {
        $user = Get-LoggedOnUser
        if (-not $user) {
            Write-Log 'GUI mode requested but no logged-on user found. Falling back to Silent mode.' 'WARN'
            $Mode = 'Silent'
        } else {
            Write-Log "GUI mode: launching on $user desktop"
            try {
                Copy-Item -LiteralPath $PSCommandPath -Destination $SelfDest -Force -EA Stop
                # Store config for GUI to read
                if (-not (Test-Path 'HKLM:\SOFTWARE\Paladin\AppUpdater')) {
                    New-Item -Path 'HKLM:\SOFTWARE\Paladin\AppUpdater' -Force | Out-Null
                }
                New-ItemProperty -Path 'HKLM:\SOFTWARE\Paladin\AppUpdater' -Name 'SiteName'          -Value $siteName -PropertyType String -Force | Out-Null
                New-ItemProperty -Path 'HKLM:\SOFTWARE\Paladin\AppUpdater' -Name 'AllowSoftExcl'     -Value ([int]$AllowSoftExcl) -PropertyType DWord  -Force | Out-Null
                New-ItemProperty -Path 'HKLM:\SOFTWARE\Paladin\AppUpdater' -Name 'AllowReboot'       -Value ([int]$AllowReboot)   -PropertyType DWord  -Force | Out-Null
                New-ItemProperty -Path 'HKLM:\SOFTWARE\Paladin\AppUpdater' -Name 'UpdateTimeout'     -Value $UpdateTimeout -PropertyType DWord  -Force | Out-Null
                New-ItemProperty -Path 'HKLM:\SOFTWARE\Paladin\AppUpdater' -Name 'CustomExclusions'  -Value $CustomExclStr -PropertyType String -Force | Out-Null

                $psArgs = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfDest`" -GUIMode"
                & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
                & schtasks.exe /Create /TN $TaskName /TR "PowerShell.exe $psArgs" `
                    /SC ONCE /ST 00:00 /RU $user /IT /F /RL HIGHEST 2>&1 | Out-Null
                & schtasks.exe /Run /TN $TaskName 2>&1 | Out-Null
                Write-Log "GUI launched on $user desktop"
                Start-Sleep -Seconds 5
                & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
                Set-DattoUDF -Slot $UDF_SLOT -Value "GUI-LAUNCHED $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Tech interface sent to $user"
                exit 0
            } catch {
                Write-Log "ERROR launching GUI: $($_.Exception.Message) -- falling back to Silent mode" 'WARN'
                $Mode = 'Silent'
            }
        }
    }

    # --- SILENT MODE ---
    $updates = Get-AvailableUpdates

    $toUpdate = $updates | Where-Object {
        $tier = $_.Tier
        if ($tier -eq 'Hard' -or $tier -eq 'Custom') { return $false }
        if ($tier -eq 'Soft' -and -not $AllowSoftExcl) { return $false }
        return $true
    }

    Write-Sep
    Write-Log "SILENT UPDATE: $($toUpdate.Count) package(s) to update (of $($updates.Count) available)"
    Write-Sep2

    $updated = 0; $failed = 0; $skipped = 0; $timedOut = 0; $rebootNeeded = $false
    $failedNames = @()

    foreach ($app in $toUpdate) {
        $result = Invoke-UpdatePackage -App $app
        switch ($result) {
            'Updated'      { $updated++ }
            'UpdatedChoco' { $updated++ }
            'Skipped'      { $skipped++ }
            'Timeout'      { $timedOut++; $failed++ }
            'Failed'       { $failed++; $failedNames += $app.Name }
        }
        if ($app.RebootReq) { $rebootNeeded = $true }
    }

    # Reboot handling
    if ($rebootNeeded -and $AllowReboot) {
        Write-Log 'Reboot-required updates installed. Rebooting in 60 seconds...'
        & msg.exe '*' /TIME:60 'Paladin IT: System updates installed. Rebooting in 60 seconds. Please save your work.' 2>&1 | Out-Null
        Start-Sleep -Seconds 60
        & shutdown.exe /r /t 0 /c 'Paladin IT: Restarting to complete application updates.' /f
        exit 0
    } elseif ($rebootNeeded) {
        Write-Log 'Reboot-required updates installed. Reboot deferred (allowReboot=false).'
    }

    Write-Sep
    Write-Log "SILENT UPDATE COMPLETE: Updated=$updated Failed=$failed Skipped=$skipped Timeout=$timedOut"

    $rebootNote = if ($rebootNeeded) { ' REBOOT-PENDING' } else { '' }
    $udfMsg = "UPDATED $(Get-Date -Format 'yyyy-MM-dd') | Updated:$updated Failed:$failed Skipped:$skipped$rebootNote"
    if ($failedNames.Count -gt 0) { $udfMsg += " | Failures: $($failedNames -join ',')" }
    Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg

    if ($failed -gt 0) { exit 1 }
    exit 0
}

# =============================================================================
# GUI MODE -- WPF TECH INTERFACE (runs as logged-on user)
# =============================================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Win32 ShowWindow API -- used to toggle console visibility
Add-Type -Name ConsoleUtils -Namespace Paladin -MemberDefinition @"
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
"@

$script:ConsoleVisible = $false
function Toggle-Console {
    $hwnd = [Paladin.ConsoleUtils]::GetConsoleWindow()
    if ($hwnd -ne [IntPtr]::Zero) {
        if ($script:ConsoleVisible) {
            [Paladin.ConsoleUtils]::ShowWindow($hwnd, 0) | Out-Null  # SW_HIDE
            $script:ConsoleVisible = $false
        } else {
            [Paladin.ConsoleUtils]::ShowWindow($hwnd, 5) | Out-Null  # SW_SHOW
            $script:ConsoleVisible = $true
        }
    }
}

# Read config from registry
$siteName    = 'UNKNOWN'
$allowSoftGui= $false
$allowRebootGui = $false
$updateTimeoutGui = 120
$customExclGui = ''
try {
    $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Paladin\AppUpdater' -EA SilentlyContinue
    if ($reg) {
        if ($reg.SiteName)         { $siteName         = $reg.SiteName }
        if ($reg.AllowSoftExcl)    { $allowSoftGui     = ($reg.AllowSoftExcl -eq 1) }
        if ($reg.AllowReboot)      { $allowRebootGui   = ($reg.AllowReboot -eq 1) }
        if ($reg.UpdateTimeout)    { $updateTimeoutGui = $reg.UpdateTimeout }
        if ($reg.CustomExclusions) { $customExclGui    = $reg.CustomExclusions }
    }
} catch {}

$script:AppRows      = @()
$script:AllUpdates   = @()
$script:SortColumn   = 'Tier'
$script:SortAsc      = $true
$script:IsUpdating   = $false

[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Paladin Application Updater"
    Width="920" MinWidth="700" MinHeight="500"
    WindowStartupLocation="CenterScreen"
    ResizeMode="CanResizeWithGrip"
    Background="#F5F5F5"
    FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style x:Key="HdrBtn" TargetType="Button">
      <Setter Property="Background" Value="#2E6DA4"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="54"/>
      <RowDefinition Height="36"/>
      <RowDefinition Height="28"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="38"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#1A3A5C">
      <Grid Margin="16,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="Paladin" Foreground="#5BA3E0" FontSize="18" FontWeight="Bold"/>
          <TextBlock Text=" Application Updater" Foreground="White" FontSize="18" FontWeight="Light"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnSelectSafe"  Content="Select All Safe" Style="{StaticResource HdrBtn}" Margin="4,0" Background="#1A7A3C"/>
          <Button x:Name="BtnDeselectAll" Content="Deselect All"    Style="{StaticResource HdrBtn}" Margin="4,0" Background="#7F8C8D"/>
          <Button x:Name="BtnRefresh"     Content="Refresh"         Style="{StaticResource HdrBtn}" Margin="4,0"/>
          <Button x:Name="BtnApply"       Content="Apply Selected"  Style="{StaticResource HdrBtn}" Margin="4,0" Background="#C0392B"/>
          <Button x:Name="BtnViewLog"     Content="View Log"        Style="{StaticResource HdrBtn}" Margin="4,0" Background="#555"/>
          <Button x:Name="BtnToggleConsole" Content="Show Console"    Style="{StaticResource HdrBtn}" Margin="4,0" Background="#444"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Filter bar -->
    <Border Grid.Row="1" Background="#2E6DA4" Padding="12,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="180"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="Filter:" Foreground="White" VerticalAlignment="Center" Margin="0,0,6,0"/>
        <TextBox x:Name="TxtFilter" Grid.Column="1" Padding="4,2" FontSize="12" VerticalAlignment="Center"/>
        <CheckBox x:Name="ChkUpdatesOnly" Grid.Column="2" Content="Updates only" Foreground="White"
                  IsChecked="True" VerticalAlignment="Center" Margin="12,0,0,0"/>
        <CheckBox x:Name="ChkShowExcluded" Grid.Column="3" Content="Show excluded" Foreground="White"
                  VerticalAlignment="Center" Margin="12,0,0,0"/>
        <TextBlock x:Name="TxtSelectedCount" Grid.Column="5" Foreground="White"
                   VerticalAlignment="Center" HorizontalAlignment="Right" FontSize="11" Margin="0,0,4,0"/>
      </Grid>
    </Border>

    <!-- Column headers -->
    <Border Grid.Row="2" Background="#345D8A" Padding="8,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="24"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="120"/>
          <ColumnDefinition Width="120"/>
          <ColumnDefinition Width="70"/>
          <ColumnDefinition Width="100"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Foreground="White" FontSize="11" VerticalAlignment="Center"/>
        <Button x:Name="BtnSortName"      Grid.Column="1" Content="Application"     Background="Transparent" Foreground="White" BorderThickness="0" HorizontalAlignment="Left"  VerticalAlignment="Center" FontWeight="SemiBold" FontSize="12" Cursor="Hand" Padding="4,0"/>
        <Button x:Name="BtnSortVersion"   Grid.Column="2" Content="Installed"       Background="Transparent" Foreground="White" BorderThickness="0" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold" FontSize="12" Cursor="Hand" Padding="4,0"/>
        <Button x:Name="BtnSortAvailable" Grid.Column="3" Content="Available"       Background="Transparent" Foreground="White" BorderThickness="0" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold" FontSize="12" Cursor="Hand" Padding="4,0"/>
        <Button x:Name="BtnSortSource"    Grid.Column="4" Content="Source"          Background="Transparent" Foreground="White" BorderThickness="0" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold" FontSize="12" Cursor="Hand" Padding="4,0"/>
        <Button x:Name="BtnSortStatus"    Grid.Column="5" Content="Status"          Background="Transparent" Foreground="White" BorderThickness="0" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold" FontSize="12" Cursor="Hand" Padding="4,0"/>
      </Grid>
    </Border>

    <!-- App list -->
    <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel x:Name="AppPanel" Background="White"/>
    </ScrollViewer>

    <!-- Progress area -->
    <Border Grid.Row="4" x:Name="ProgressBorder" Background="#EBF5FB" Padding="12,8"
            BorderBrush="#AED6F1" BorderThickness="0,1,0,1" Visibility="Collapsed">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock x:Name="TxtProgressLabel" Grid.Row="0" Margin="0,0,0,4" FontSize="11" Foreground="#1A5276"/>
        <ProgressBar x:Name="ProgBar" Grid.Row="1" Height="12" Minimum="0" Maximum="100" Value="0"
                     Background="#D6EAF8" Foreground="#2E6DA4"/>
      </Grid>
    </Border>

    <!-- Status bar -->
    <Border Grid.Row="5" Background="#1A3A5C" Padding="12,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="TxtStatus" Foreground="#AAC8E8" VerticalAlignment="Center" FontSize="11"/>
        <TextBlock Grid.Column="1" Text="Paladin Application Updater v1.0.0"
                   Foreground="#556B82" VerticalAlignment="Center" FontSize="11"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader  = New-Object System.Xml.XmlNodeReader $xaml
$window  = [Windows.Markup.XamlReader]::Load($reader)

$BtnSelectSafe  = $window.FindName('BtnSelectSafe')
$BtnDeselectAll = $window.FindName('BtnDeselectAll')
$BtnRefresh     = $window.FindName('BtnRefresh')
$BtnApply       = $window.FindName('BtnApply')
$BtnViewLog     = $window.FindName('BtnViewLog')
$BtnToggleConsole = $window.FindName('BtnToggleConsole')
$BtnSortName    = $window.FindName('BtnSortName')
$BtnSortVersion = $window.FindName('BtnSortVersion')
$BtnSortAvailable=$window.FindName('BtnSortAvailable')
$BtnSortSource  = $window.FindName('BtnSortSource')
$BtnSortStatus  = $window.FindName('BtnSortStatus')
$TxtFilter      = $window.FindName('TxtFilter')
$ChkUpdatesOnly = $window.FindName('ChkUpdatesOnly')
$ChkShowExcluded= $window.FindName('ChkShowExcluded')
$TxtSelectedCount=$window.FindName('TxtSelectedCount')
$AppPanel       = $window.FindName('AppPanel')
$ProgressBorder = $window.FindName('ProgressBorder')
$TxtProgressLabel=$window.FindName('TxtProgressLabel')
$ProgBar        = $window.FindName('ProgBar')
$TxtStatus      = $window.FindName('TxtStatus')

# Status badge colors
$TierColors = @{
    'None'       = '#1A7A3C'   # Green -- safe
    'Deferred'   = '#E67E22'   # Orange -- reboot required
    'Soft'       = '#F39C12'   # Yellow -- caution
    'Hard'       = '#C0392B'   # Red -- locked
    'Custom'     = '#8E44AD'   # Purple -- custom excluded
    'SelfUpdate' = '#2471A3'   # Blue -- own updater
    'Updated'    = '#27AE60'   # Green confirmed
    'Failed'     = '#C0392B'   # Red failed
    'Skipped'    = '#7F8C8D'   # Grey skipped
}

$TierLabels = @{
    'None'       = 'SAFE'
    'Deferred'   = 'REBOOT'
    'Soft'       = 'CAUTION'
    'Hard'       = 'EXCLUDED'
    'Custom'     = 'CUSTOM-EXCL'
    'SelfUpdate' = 'SELF-UPD'
}

function New-AppRow {
    param($App, [bool]$Alternate)

    $bg   = if ($Alternate) { '#F0F4F8' } else { '#FFFFFF' }
    $tier = $App.Tier

    $row                 = New-Object System.Windows.Controls.Border
    $row.Background      = $bg
    $row.BorderBrush     = '#E0E0E0'
    $row.BorderThickness = '0,0,0,1'
    $row.Padding         = '8,4'

    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in @(24, [double]::NaN, 120, 120, 70, 100)) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        if ([double]::IsNaN($w)) {
            $col.Width = New-Object System.Windows.GridLength(1,[System.Windows.GridUnitType]::Star)
        } else {
            $col.Width = New-Object System.Windows.GridLength($w)
        }
        $grid.ColumnDefinitions.Add($col) | Out-Null
    }

    # Checkbox
    $chk                     = New-Object System.Windows.Controls.CheckBox
    $chk.HorizontalAlignment = 'Center'
    $chk.VerticalAlignment   = 'Center'
    $chk.IsEnabled           = ($tier -eq 'None' -or $tier -eq 'Deferred' -or ($tier -eq 'SelfUpdate') -or ($tier -eq 'Soft' -and $allowSoftGui))
    $chk.IsChecked           = ($tier -eq 'None')  # pre-select safe items only; SelfUpdate unchecked
    $chk.ToolTip             = if (-not $chk.IsEnabled) { "Cannot select: $tier exclusion" } elseif ($tier -eq 'SelfUpdate') { "App has own updater -- WinGet version detection may be unreliable after update" } else { 'Include in update' }
    [System.Windows.Controls.Grid]::SetColumn($chk, 0)
    $grid.Children.Add($chk) | Out-Null

    # App name
    $nameBlock                   = New-Object System.Windows.Controls.TextBlock
    $nameBlock.Text              = $App.Name
    $nameBlock.VerticalAlignment = 'Center'
    $nameBlock.FontSize          = 12
    $nameBlock.Margin            = '4,0'
    $nameBlock.TextTrimming      = 'CharacterEllipsis'
    $nameBlock.ToolTip           = "$($App.Name) ($($App.WinGetID))"
    [System.Windows.Controls.Grid]::SetColumn($nameBlock, 1)
    $grid.Children.Add($nameBlock) | Out-Null

    # Current version
    $verBlock                    = New-Object System.Windows.Controls.TextBlock
    $verBlock.Text               = $App.Version
    $verBlock.VerticalAlignment  = 'Center'
    $verBlock.HorizontalAlignment= 'Center'
    $verBlock.FontSize           = 11
    $verBlock.Foreground         = '#555'
    [System.Windows.Controls.Grid]::SetColumn($verBlock, 2)
    $grid.Children.Add($verBlock) | Out-Null

    # Available version
    $availBlock                    = New-Object System.Windows.Controls.TextBlock
    $availBlock.Text               = $App.Available
    $availBlock.VerticalAlignment  = 'Center'
    $availBlock.HorizontalAlignment= 'Center'
    $availBlock.FontSize           = 11
    $availBlock.FontWeight         = 'SemiBold'
    $availBlock.Foreground         = '#1A7A3C'
    [System.Windows.Controls.Grid]::SetColumn($availBlock, 3)
    $grid.Children.Add($availBlock) | Out-Null

    # Source badge
    $srcBlock                    = New-Object System.Windows.Controls.TextBlock
    $srcBlock.Text               = $App.Source
    $srcBlock.VerticalAlignment  = 'Center'
    $srcBlock.HorizontalAlignment= 'Center'
    $srcBlock.FontSize           = 10
    $srcBlock.Foreground         = '#2E6DA4'
    [System.Windows.Controls.Grid]::SetColumn($srcBlock, 4)
    $grid.Children.Add($srcBlock) | Out-Null

    # Status badge
    $statusBorder                = New-Object System.Windows.Controls.Border
    $statusBorder.Background     = $TierColors[$tier]
    $statusBorder.CornerRadius   = '3'
    $statusBorder.Padding        = '6,2'
    $statusBorder.Margin         = '4,2'
    $statusBorder.HorizontalAlignment = 'Center'
    $statusBorder.VerticalAlignment   = 'Center'
    $statusText                  = New-Object System.Windows.Controls.TextBlock
    $statusText.Text             = $TierLabels[$tier]
    $statusText.Foreground       = 'White'
    $statusText.FontSize         = 10
    $statusText.FontWeight       = 'SemiBold'
    $statusBorder.Child          = $statusText
    [System.Windows.Controls.Grid]::SetColumn($statusBorder, 5)
    $grid.Children.Add($statusBorder) | Out-Null

    $row.Child = $grid

    $script:AppRows += @{
        App        = $App
        Checkbox   = $chk
        StatusBorder = $statusBorder
        StatusText = $statusText
        Row        = $row
    }
    return $row
}

function Update-SelectedCount {
    $selected = ($script:AppRows | Where-Object { $_.Checkbox.IsChecked -eq $true }).Count
    $total    = $script:AppRows.Count
    $TxtSelectedCount.Text = "$selected of $total selected"
}

function Invoke-Sort { param([string]$Col) if ($script:SortColumn -eq $Col) { $script:SortAsc = -not $script:SortAsc } else { $script:SortColumn=$Col; $script:SortAsc=$true }; Invoke-PopulateGrid }

function Invoke-PopulateGrid {
    $script:AppRows = @()
    $AppPanel.Children.Clear()

    $filter       = $TxtFilter.Text.Trim().ToLower()
    $updatesOnly  = ($ChkUpdatesOnly.IsChecked -eq $true)
    $showExcluded = ($ChkShowExcluded.IsChecked -eq $true)

    $filtered = $script:AllUpdates | Where-Object {
        $ok = $true
        if ($filter)       { $ok = $ok -and ($_.Name.ToLower() -like "*$filter*" -or $_.WinGetID.ToLower() -like "*$filter*") }
        if ($updatesOnly)  { $ok = $ok -and (-not [string]::IsNullOrEmpty($_.Available)) }
        if (-not $showExcluded) { $ok = $ok -and ($_.Tier -eq 'None' -or $_.Tier -eq 'Deferred' -or $_.Tier -eq 'SelfUpdate' -or ($_.Tier -eq 'Soft' -and $allowSoftGui)) }
        $ok
    }

    $sorted = switch ($script:SortColumn) {
        'Name'      { if ($script:SortAsc) { $filtered | Sort-Object Name }      else { $filtered | Sort-Object Name -Descending } }
        'Version'   { if ($script:SortAsc) { $filtered | Sort-Object Version }   else { $filtered | Sort-Object Version -Descending } }
        'Available' { if ($script:SortAsc) { $filtered | Sort-Object Available } else { $filtered | Sort-Object Available -Descending } }
        'Source'    { if ($script:SortAsc) { $filtered | Sort-Object Source }    else { $filtered | Sort-Object Source -Descending } }
        default     { if ($script:SortAsc) { $filtered | Sort-Object { @{'None'=0;'Deferred'=1;'Soft'=2;'Custom'=3;'Hard'=4}[$_.Tier] } } else { $filtered | Sort-Object { @{'None'=0;'Deferred'=1;'Soft'=2;'Custom'=3;'Hard'=4}[$_.Tier] } -Descending } }
    }

    $i = 0
    foreach ($app in $sorted) {
        $r = New-AppRow -App $app -Alternate (($i % 2) -eq 1)

        # Wire checkbox change to update count
        $localChk = $r.Child.Children | Where-Object { $_ -is [System.Windows.Controls.CheckBox] } | Select-Object -First 1
        if ($null -ne $localChk) {
            $cb = { Update-SelectedCount }.GetNewClosure()
            $localChk.Add_Checked($cb)
            $localChk.Add_Unchecked($cb)
        }

        $AppPanel.Children.Add($r) | Out-Null
        $i++
    }

    $safe     = ($script:AllUpdates | Where-Object { $_.Tier -eq 'None' }).Count
    $selfUpd  = ($script:AllUpdates | Where-Object { $_.Tier -eq 'SelfUpdate' }).Count
    if ($script:AllUpdates.Count -eq 0) {
        $TxtStatus.Text       = 'Congratulations! All applications are up to date.'
        $TxtStatus.Foreground = '#90EE90'
    } else {
        $TxtStatus.Text       = "Site: $siteName | $($script:AllUpdates.Count) update(s) found | $safe safe | $selfUpd self-update | Sorted: $($script:SortColumn)"
        $TxtStatus.Foreground = '#AAC8E8'
    }
    $TxtStatus.Foreground = '#AAC8E8'
    Update-SelectedCount
}

function Invoke-LoadUpdates {
    $TxtStatus.Text       = 'Scanning for available updates...'
    $TxtStatus.Foreground = '#AAC8E8'
    $window.Dispatcher.Invoke([action]{}, 'Background')

    $script:AllUpdates = @(Get-AvailableUpdates)
    Invoke-PopulateGrid

    # Show congratulations message if nothing to update
    $actionable = $script:AllUpdates | Where-Object { $_.Tier -eq 'None' -or $_.Tier -eq 'Deferred' -or $_.Tier -eq 'SelfUpdate' }
    if ($script:AllUpdates.Count -eq 0 -or $actionable.Count -eq 0) {
        $TxtStatus.Text       = 'All applications are up to date. No updates available at this time.'
        $TxtStatus.Foreground = '#90EE90'
    }
}

function Invoke-Apply {
    $toUpdate = $script:AppRows | Where-Object { $_.Checkbox.IsChecked -eq $true }
    if ($toUpdate.Count -eq 0) {
        $TxtStatus.Text       = 'No applications selected. Check the boxes for apps to update.'
        $TxtStatus.Foreground = '#E67E22'
        return
    }

    $confirm = [System.Windows.MessageBox]::Show(
        "Update $($toUpdate.Count) application(s)?`n`nThis may take several minutes. Applications will be updated silently.",
        'Paladin Application Updater',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($confirm -ne 'Yes') { return }

    $script:IsUpdating  = $true
    $BtnApply.IsEnabled = $false
    $ProgressBorder.Visibility = 'Visible'
    $ProgBar.Maximum    = $toUpdate.Count
    $ProgBar.Value      = 0

    $updatedCount = 0; $failedCount = 0; $rebootNeeded = $false
    $i = 0

    foreach ($entry in $toUpdate) {
        $app = $entry.App
        $i++
        $TxtProgressLabel.Text = "Updating $i of $($toUpdate.Count): $($app.Name)..."
        $ProgBar.Value         = $i
        $window.Dispatcher.Invoke([action]{}, 'Background')

        $result = Invoke-UpdatePackage -App $app

        # Update row badge
        $color = switch ($result) {
            'Updated'      { '#27AE60' }
            'UpdatedChoco' { '#27AE60' }
            'Skipped'      { '#7F8C8D' }
            'Timeout'      { '#C0392B' }
            'Failed'       { '#C0392B' }
            default        { '#7F8C8D' }
        }
        $label = switch ($result) {
            'Updated'      { 'UPDATED' }
            'UpdatedChoco' { 'UPDATED' }
            'Skipped'      { 'SKIPPED' }
            'Timeout'      { 'TIMEOUT' }
            'Failed'       { 'FAILED' }
            default        { $result.ToUpper() }
        }
        $entry.StatusBorder.Background = $color
        $entry.StatusText.Text         = $label
        $entry.Checkbox.IsEnabled      = $false

        if ($result -eq 'Updated' -or $result -eq 'UpdatedChoco') { $updatedCount++ }
        else { $failedCount++ }
        if ($app.RebootReq) { $rebootNeeded = $true }
    }

    $ProgressBorder.Visibility = 'Collapsed'
    $BtnApply.IsEnabled        = $true
    $script:IsUpdating         = $false

    # Write UDF result
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' `
            -Name "Custom$UDF_SLOT" -PropertyType String `
            -Value "GUI $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Updated:$updatedCount Failed:$failedCount" `
            -Force -EA SilentlyContinue | Out-Null
    } catch {}

    $summary = "Done: $updatedCount updated, $failedCount failed."
    if ($rebootNeeded -and $allowRebootGui) {
        $summary += ' Reboot required.'
        [System.Windows.MessageBox]::Show(
            "Updates complete.`n$updatedCount updated, $failedCount failed.`n`nA reboot is required. Please save your work. The system will restart in 60 seconds.",
            'Paladin Application Updater',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        & shutdown.exe /r /t 60 /c 'Paladin IT: Restarting to complete application updates.' /f
    } elseif ($rebootNeeded) {
        $summary += ' Reboot pending (deferred).'
        [System.Windows.MessageBox]::Show(
            "Updates complete.`n$updatedCount updated, $failedCount failed.`n`nSome updates require a reboot. Please schedule a restart at your convenience.",
            'Paladin Application Updater',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    } else {
        [System.Windows.MessageBox]::Show(
            "Updates complete.`n$updatedCount updated, $failedCount failed.",
            'Paladin Application Updater',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    }

    $TxtStatus.Text       = $summary
    $TxtStatus.Foreground = if ($failedCount -gt 0) { '#FF6B6B' } else { '#90EE90' }
}

# Event wiring
$BtnRefresh.Add_Click({     Invoke-LoadUpdates })
$BtnApply.Add_Click({       Invoke-Apply })
$BtnViewLog.Add_Click({
    if (Test-Path $LogFile) { Start-Process notepad.exe -ArgumentList $LogFile }
    else { [System.Windows.MessageBox]::Show('No log file found yet.','Paladin') }
})
$localToggleBtn = $BtnToggleConsole
$BtnToggleConsole.Add_Click({
    Toggle-Console
    if ($script:ConsoleVisible) {
        $localToggleBtn.Content    = 'Hide Console'
        $localToggleBtn.Background = '#1A5276'
    } else {
        $localToggleBtn.Content    = 'Show Console'
        $localToggleBtn.Background = '#444'
    }
}.GetNewClosure())
$BtnSelectSafe.Add_Click({
    foreach ($entry in $script:AppRows) {
        if ($entry.App.Tier -eq 'None') { $entry.Checkbox.IsChecked = $true }
        # SelfUpdate items: never auto-select, tech must explicitly choose
    }
    Update-SelectedCount
})
$BtnDeselectAll.Add_Click({
    foreach ($entry in $script:AppRows) { $entry.Checkbox.IsChecked = $false }
    Update-SelectedCount
})
$TxtFilter.Add_TextChanged({ Invoke-PopulateGrid })
$ChkUpdatesOnly.Add_Checked({   Invoke-PopulateGrid })
$ChkUpdatesOnly.Add_Unchecked({ Invoke-PopulateGrid })
$ChkShowExcluded.Add_Checked({   Invoke-PopulateGrid })
$ChkShowExcluded.Add_Unchecked({ Invoke-PopulateGrid })

# Sort buttons use GetNewClosure to avoid KI-120
$localSortName = 'Name'; $BtnSortName.Add_Click({ Invoke-Sort -Col $localSortName }.GetNewClosure())
$localSortVer = 'Version'; $BtnSortVersion.Add_Click({ Invoke-Sort -Col $localSortVer }.GetNewClosure())
$localSortAvail = 'Available'; $BtnSortAvailable.Add_Click({ Invoke-Sort -Col $localSortAvail }.GetNewClosure())
$localSortSrc = 'Source'; $BtnSortSource.Add_Click({ Invoke-Sort -Col $localSortSrc }.GetNewClosure())
$localSortStatus = 'Status'; $BtnSortStatus.Add_Click({ Invoke-Sort -Col $localSortStatus }.GetNewClosure())

# Launch
Invoke-LoadUpdates
$window.ShowDialog() | Out-Null
exit 0
