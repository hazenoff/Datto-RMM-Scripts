#Requires -Version 3.0
# =============================================================================
# Paladin Windows Update Force + Report [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
#
# DESCRIPTION:
#   Forces a Windows Update scan and optionally installs all available updates.
#   Reports pending and installed KB numbers, last update date, and overall
#   patch status to the Datto job log and UDF.
#
#   Two modes:
#   Report  -- Scan for available updates, report findings. No installs.
#   Install -- Scan and install all available updates. Reboot deferred unless
#              allowReboot=true.
#
#   Uses native Windows Update COM API (WUApiLib) -- no external modules,
#   no PSWindowsUpdate dependency, works in PS3.0 / SYSTEM context.
#
# INPUT VARIABLES:
#   action      (String)  -- 'Report' or 'Install' (default: Report)
#   allowReboot (Boolean) -- true = reboot if required after install
#                            false = install only, defer reboot (default: false)
#
# LOG:    C:\ProgramData\Paladin\WindowsUpdate\WindowsUpdate.log
# UDF:    Slot 20 (PALADIN-WUPDATE)
# EXIT:   0 = up to date or updates installed successfully
#         1 = error during scan or install
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer  = '1.0.0'
$LogDir     = 'C:\ProgramData\Paladin\WindowsUpdate'
$LogFile    = "$LogDir\WindowsUpdate.log"
$UDF_SLOT   = 20   # PALADIN-WUPDATE
$MaxLogMB   = 5
$Staledays  = 30   # flag as stale if no updates in this many days

# Input variables
$Action     = $env:action
$AllowReboot= ($env:allowReboot -eq 'true')
if ([string]::IsNullOrEmpty($Action)) { $Action = 'Report' }
if ($Action -notin @('Report','Install')) {
    Write-Host "Invalid action '$Action'. Defaulting to Report."
    $Action = 'Report'
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

function Get-LastUpdateDate {
    # Read last successful update install time from WU history
    try {
        $searcher = New-Object -ComObject Microsoft.Update.Searcher -EA Stop
        $histCount = $searcher.GetTotalHistoryCount()
        if ($histCount -gt 0) {
            $history = $searcher.QueryHistory(0, [Math]::Min($histCount, 50))
            for ($i = 0; $i -lt $history.Count; $i++) {
                $entry = $history.Item($i)
                # ResultCode 2 = Succeeded
                if ($entry.ResultCode -eq 2 -and $null -ne $entry.Date) {
                    return $entry.Date
                }
            }
        }
    } catch {}
    return $null
}

function Get-PendingUpdates {
    Write-Log "  Connecting to Windows Update service..."
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session -EA Stop
        $searcher = $session.CreateUpdateSearcher()
        $searcher.ServerSelection = 0   # Default (WSUS or WU)

        Write-Log "  Searching for pending updates (this may take a few minutes)..."
        $result   = $searcher.Search("IsInstalled=0 and IsHidden=0")

        $updates = @()
        for ($i = 0; $i -lt $result.Updates.Count; $i++) {
            $u    = $result.Updates.Item($i)
            $kbs  = @()
            for ($k = 0; $k -lt $u.KBArticleIDs.Count; $k++) {
                $kbs += "KB$($u.KBArticleIDs.Item($k))"
            }
            $updates += New-Object PSObject -Property @{
                Title       = $u.Title
                KBs         = if ($kbs.Count -gt 0) { $kbs -join ',' } else { 'N/A' }
                SizeMB      = [Math]::Round($u.MaxDownloadSize / 1MB, 1)
                RebootReq   = $u.InstallationBehavior.RebootBehavior -gt 0
                UpdateObj   = $u
            }
        }
        return $updates
    } catch {
        Write-Log "  ERROR: Update search failed: $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Install-Updates {
    param($Updates)

    Write-Sep2
    Write-Log "Installing $($Updates.Count) update(s)..."

    $installed  = 0
    $failed     = 0
    $rebootNeeded = $false

    try {
        $session    = New-Object -ComObject Microsoft.Update.Session -EA Stop
        $downloader = $session.CreateUpdateDownloader()
        $installer  = $session.CreateUpdateInstaller()

        # Download all updates first
        Write-Log "  Downloading updates..."
        $updateColl = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $Updates) { $updateColl.Add($u.UpdateObj) | Out-Null }

        $downloader.Updates = $updateColl
        $dlResult = $downloader.Download()
        Write-Log "  Download result code: $($dlResult.ResultCode)"

        # Install
        Write-Log "  Installing updates..."
        $installer.Updates = $updateColl
        $installer.AllowSourcePrompts = $false
        $instResult = $installer.Install()

        Write-Log "  Install result code: $($instResult.ResultCode)"
        $rebootNeeded = $instResult.RebootRequired

        # Count results per update
        for ($i = 0; $i -lt $updateColl.Count; $i++) {
            $u   = $updateColl.Item($i)
            $rc  = $instResult.GetUpdateResult($i).ResultCode
            if ($rc -eq 2) {
                $installed++
                Write-Log "  [OK] $($u.Title)"
            } else {
                $failed++
                Write-Log "  [FAIL] $($u.Title) -- ResultCode: $rc" 'WARN'
            }
        }
    } catch {
        Write-Log "  ERROR: Install process failed: $($_.Exception.Message)" 'WARN'
        $failed = $Updates.Count
    }

    return @{ Installed = $installed; Failed = $failed; RebootNeeded = $rebootNeeded }
}

# =============================================================================
# MAIN
# =============================================================================

if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

$siteName = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }

Write-Sep
Write-Log "Paladin Windows Update Force + Report v$ScriptVer | Site: $siteName | Machine: $env:COMPUTERNAME"
Write-Log "Mode: $Action | AllowReboot: $AllowReboot"
Write-Sep

# Get last update date
$lastUpdate   = Get-LastUpdateDate
$lastUpdateStr = if ($null -ne $lastUpdate) { $lastUpdate.ToString('yyyy-MM-dd') } else { 'Unknown' }
$daysSince    = if ($null -ne $lastUpdate) { [int]((Get-Date) - $lastUpdate).TotalDays } else { 999 }
$isStale      = $daysSince -ge $Staledays

Write-Log "Last successful update: $lastUpdateStr ($daysSince days ago)"
if ($isStale) { Write-Log "WARNING: Machine has not been updated in $daysSince days" 'WARN' }

# Scan for pending updates
Write-Sep2
Write-Log "Scanning for pending updates..."
$pending = Get-PendingUpdates

if ($null -eq $pending) {
    Set-DattoUDF -Slot $UDF_SLOT -Value "ERROR $(Get-Date -Format 'yyyy-MM-dd') | WU scan failed -- check log"
    exit 1
}

Write-Log "Pending updates found: $($pending.Count)"

# Report
Write-Sep2
if ($pending.Count -eq 0) {
    Write-Log "STATUS: Machine is fully up to date."
    Write-Log "Last update: $lastUpdateStr ($daysSince days ago)"
} else {
    $totalSizeMB = ($pending | Measure-Object -Property SizeMB -Sum).Sum
    Write-Log "PENDING UPDATES: $($pending.Count) update(s) | Total size: $([Math]::Round($totalSizeMB,1)) MB"
    Write-Sep2
    Write-Log ("  {0,-60} {1,-12} {2,-8} {3}" -f 'Title','KB','Size MB','Reboot')
    Write-Log ("  {0,-60} {1,-12} {2,-8} {3}" -f ('-'*59),('-'*11),('-'*7),('-'*6))
    foreach ($u in $pending) {
        $title = if ($u.Title.Length -gt 59) { $u.Title.Substring(0,56) + '...' } else { $u.Title }
        Write-Log ("  {0,-60} {1,-12} {2,-8} {3}" -f $title, $u.KBs, $u.SizeMB, $u.RebootReq)
    }
}

# Report mode -- stop here
if ($Action -eq 'Report') {
    Write-Sep
    $staleFlag = if ($isStale) { " STALE($daysSince days)" } else { '' }
    if ($pending.Count -eq 0) {
        Set-DattoUDF -Slot $UDF_SLOT -Value "CURRENT $(Get-Date -Format 'yyyy-MM-dd') | LastUpdate:$lastUpdateStr | No pending updates$staleFlag"
    } else {
        $kbList = ($pending | Select-Object -First 5 | ForEach-Object { $_.KBs }) -join ' '
        Set-DattoUDF -Slot $UDF_SLOT -Value "PENDING $(Get-Date -Format 'yyyy-MM-dd') | $($pending.Count) updates | LastUpdate:$lastUpdateStr$staleFlag | $kbList"
    }
    exit 0
}

# Install mode
if ($pending.Count -eq 0) {
    Write-Log "No updates to install. Machine is current."
    Set-DattoUDF -Slot $UDF_SLOT -Value "CURRENT $(Get-Date -Format 'yyyy-MM-dd') | No updates needed | LastUpdate:$lastUpdateStr"
    exit 0
}

Write-Sep
Write-Log "MODE: Install -- proceeding with $($pending.Count) update(s)"
$instResult = Install-Updates -Updates $pending

Write-Sep
Write-Log "INSTALL COMPLETE: Installed=$($instResult.Installed) Failed=$($instResult.Failed) RebootNeeded=$($instResult.RebootNeeded)"

$udfBase = "INSTALLED $(Get-Date -Format 'yyyy-MM-dd') | Done:$($instResult.Installed) Failed:$($instResult.Failed)"

if ($instResult.RebootNeeded) {
    Write-Log "A reboot is required to complete update installation."
    if ($AllowReboot) {
        Write-Log "AllowReboot=true -- rebooting in 60 seconds"
        Set-DattoUDF -Slot $UDF_SLOT -Value "$udfBase | REBOOTING"
        & msg.exe '*' /TIME:60 "Paladin IT: Windows Updates installed. Your PC will restart in 60 seconds. Please save your work." 2>&1 | Out-Null
        Start-Sleep -Seconds 60
        & shutdown.exe /r /t 0 /c "Paladin IT: Restarting to complete Windows Update installation." /f
        exit 0
    } else {
        Write-Log "AllowReboot=false -- reboot deferred. Please schedule a maintenance reboot."
        Set-DattoUDF -Slot $UDF_SLOT -Value "$udfBase | REBOOT-REQUIRED"
    }
} else {
    Set-DattoUDF -Slot $UDF_SLOT -Value $udfBase
}

if ($instResult.Failed -gt 0) { exit 1 }
exit 0
