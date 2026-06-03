#Requires -Version 3.0
# =============================================================================
# Paladin OneDrive & Teams Sync Reset [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
#
# DESCRIPTION:
#   Resets OneDrive and/or Microsoft Teams sync state for all user profiles
#   on the machine. Clears cache and sync databases without removing user
#   credentials or account configuration. After reset, the apps re-sync
#   cleanly on next launch.
#
#   Targets:
#     OneDrive -- clears sync databases, telemetry cache, thumbnail cache,
#                 and settings cache. Preserves account credentials and
#                 the actual synced files.
#     Teams    -- clears application cache (blob storage, Cache, GPUCache,
#                 IndexedDB, Local Storage, tmp). Preserves login tokens.
#
# INPUT VARIABLES:
#   target (String) -- 'Both' | 'OneDrive' | 'Teams' (default: Both)
#
# SAFE TO RUN WHILE USER IS LOGGED OUT. If user is logged in, OneDrive and
# Teams processes are stopped first, cache cleared, processes left stopped
# (apps will restart on next user interaction).
#
# LOG:    C:\ProgramData\Paladin\SyncReset\SyncReset.log
# UDF:    Slot 19 (PALADIN-SYNCRESET)
# EXIT:   0 = completed successfully
#         1 = one or more errors during reset
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer  = '1.0.0'
$LogDir     = 'C:\ProgramData\Paladin\SyncReset'
$LogFile    = "$LogDir\SyncReset.log"
$UDF_SLOT   = 19   # PALADIN-SYNCRESET
$MaxLogMB   = 5

# Input variable
$Target = $env:target
if ([string]::IsNullOrEmpty($Target)) { $Target = 'Both' }
if ($Target -notin @('Both','OneDrive','Teams')) {
    Write-Host "Invalid target '$Target'. Must be Both, OneDrive, or Teams. Defaulting to Both."
    $Target = 'Both'
}

$DoOneDrive = ($Target -eq 'Both' -or $Target -eq 'OneDrive')
$DoTeams    = ($Target -eq 'Both' -or $Target -eq 'Teams')

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

function Stop-ProcessSafe {
    param([string]$ProcessName)
    try {
        $procs = Get-WmiObject -Class Win32_Process -Filter "Name='$ProcessName'" -EA SilentlyContinue
        if ($null -ne $procs -and @($procs).Count -gt 0) {
            foreach ($p in @($procs)) {
                $p.Terminate() | Out-Null
            }
            Start-Sleep -Seconds 2
            Write-Log "  Stopped: $ProcessName"
            return $true
        }
    } catch { Write-Log "  WARN: Could not stop $ProcessName : $($_.Exception.Message)" }
    return $false
}

function Remove-ItemSafe {
    param([string]$Path, [switch]$Recurse)
    try {
        if (-not (Test-Path $Path)) { return $true }
        if ($Recurse) {
            Remove-Item -LiteralPath $Path -Recurse -Force -EA Stop
        } else {
            Remove-Item -LiteralPath $Path -Force -EA Stop
        }
        return $true
    } catch {
        Write-Log "  WARN: Could not remove $Path : $($_.Exception.Message)"
        return $false
    }
}

function Get-UserProfiles {
    # Returns all non-system, non-special user profile paths
    $profiles = @()
    try {
        $wmiProfiles = Get-WmiObject -Class Win32_UserProfile -EA SilentlyContinue |
            Where-Object {
                $_.Special   -eq $false -and
                $_.LocalPath -notmatch 'systemprofile|NetworkService|LocalService|Default$|Public$'
            }
        foreach ($p in @($wmiProfiles)) {
            if (Test-Path $p.LocalPath) {
                $profiles += $p.LocalPath
            }
        }
    } catch { Write-Log "WARN: Profile enumeration failed: $($_.Exception.Message)" }
    return $profiles
}

# =============================================================================
# ONEDRIVE RESET
# =============================================================================

function Invoke-OneDriveReset {
    param([string[]]$UserProfiles)

    Write-Sep
    Write-Log "OneDrive Sync Reset"
    Write-Sep2

    # Stop OneDrive processes
    Stop-ProcessSafe -ProcessName 'OneDrive.exe'
    Stop-ProcessSafe -ProcessName 'FileCoAuth.exe'
    Start-Sleep -Seconds 2

    $resetCount = 0
    $errCount   = 0

    foreach ($profilePath in $UserProfiles) {
        $username = Split-Path $profilePath -Leaf
        Write-Log "  Processing: $username"

        # OneDrive cache paths to clear (safe to delete -- no user data, no creds)
        $cachePaths = @(
            # Sync databases and state
            "$profilePath\AppData\Local\Microsoft\OneDrive\logs",
            "$profilePath\AppData\Local\Microsoft\OneDrive\setup\logs",
            "$profilePath\AppData\Local\Microsoft\OneDrive\SyncEngineDatabase.db",
            # Telemetry
            "$profilePath\AppData\Local\Microsoft\OneDrive\telemetry",
            # Thumbnail cache
            "$profilePath\AppData\Local\Microsoft\OneDrive\ListSync",
            # Settings cache (not the settings file itself)
            "$profilePath\AppData\Local\Microsoft\OneDrive\cache"
        )

        $userCleared = 0
        $userErrors  = 0

        foreach ($path in $cachePaths) {
            if (-not (Test-Path $path)) { continue }

            $isDir = (Get-Item $path -EA SilentlyContinue).PSIsContainer
            if ($isDir) {
                $ok = Remove-ItemSafe -Path $path -Recurse
            } else {
                $ok = Remove-ItemSafe -Path $path
            }

            if ($ok) {
                $userCleared++
                Write-Log "    Cleared: $path"
            } else {
                $userErrors++
            }
        }

        # Reset OneDrive sync via registry -- clears "IsSetup" flag so it re-configures
        $odRegPath = "HKLM:\SOFTWARE\Microsoft\OneDrive\Accounts"
        try {
            if (Test-Path $odRegPath) {
                $accts = Get-ChildItem -Path $odRegPath -EA SilentlyContinue
                foreach ($acct in @($accts)) {
                    $acctPath = $acct.PSPath
                    # Clear LastKnownLibraryPath -- forces re-discovery
                    Remove-ItemProperty -Path $acctPath -Name 'LastKnownLibraryPath' -EA SilentlyContinue
                }
            }
        } catch {}

        if ($userErrors -eq 0) {
            $resetCount++
            Write-Log "  [OK] $username -- OneDrive cache cleared ($userCleared items)"
        } else {
            $errCount++
            Write-Log "  [PARTIAL] $username -- cleared $userCleared items, $userErrors errors" 'WARN'
        }
    }

    Write-Log "OneDrive reset complete: $resetCount users OK, $errCount with errors"
    return $errCount
}

# =============================================================================
# TEAMS RESET
# =============================================================================

function Invoke-TeamsReset {
    param([string[]]$UserProfiles)

    Write-Sep
    Write-Log "Teams Sync Reset"
    Write-Sep2

    # Stop Teams processes
    Stop-ProcessSafe -ProcessName 'Teams.exe'
    Stop-ProcessSafe -ProcessName 'ms-teams.exe'
    Stop-ProcessSafe -ProcessName 'TeamsMeetingAddin.exe'
    Start-Sleep -Seconds 2

    $resetCount = 0
    $errCount   = 0

    foreach ($profilePath in $UserProfiles) {
        $username = Split-Path $profilePath -Leaf
        Write-Log "  Processing: $username"

        # Teams cache paths -- safe to clear, do not touch token store
        # Classic Teams (pre-2024)
        $classicCachePaths = @(
            "$profilePath\AppData\Roaming\Microsoft\Teams\blob_storage",
            "$profilePath\AppData\Roaming\Microsoft\Teams\Cache",
            "$profilePath\AppData\Roaming\Microsoft\Teams\databases",
            "$profilePath\AppData\Roaming\Microsoft\Teams\GPUCache",
            "$profilePath\AppData\Roaming\Microsoft\Teams\IndexedDB",
            "$profilePath\AppData\Roaming\Microsoft\Teams\Local Storage",
            "$profilePath\AppData\Roaming\Microsoft\Teams\tmp"
        )

        # New Teams (2024+) -- stored in WindowsApps / LocalCache
        $newTeamsCachePaths = @(
            "$profilePath\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs",
            "$profilePath\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\PerfLogs",
            "$profilePath\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\tmp"
        )

        $allCachePaths = @($classicCachePaths) + @($newTeamsCachePaths)

        $userCleared = 0
        $userErrors  = 0

        foreach ($path in $allCachePaths) {
            if (-not (Test-Path $path)) { continue }
            $ok = Remove-ItemSafe -Path $path -Recurse
            if ($ok) {
                $userCleared++
                Write-Log "    Cleared: $path"
            } else {
                $userErrors++
            }
        }

        if ($userErrors -eq 0) {
            $resetCount++
            Write-Log "  [OK] $username -- Teams cache cleared ($userCleared items)"
        } else {
            $errCount++
            Write-Log "  [PARTIAL] $username -- cleared $userCleared items, $userErrors errors" 'WARN'
        }
    }

    Write-Log "Teams reset complete: $resetCount users OK, $errCount with errors"
    return $errCount
}

# =============================================================================
# MAIN
# =============================================================================

if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

$siteName = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }

Write-Sep
Write-Log "Paladin OneDrive & Teams Sync Reset v$ScriptVer | Site: $siteName | Machine: $env:COMPUTERNAME"
Write-Log "Target: $Target | OneDrive: $DoOneDrive | Teams: $DoTeams"
Write-Sep

$userProfiles = Get-UserProfiles
Write-Log "Found $($userProfiles.Count) user profile(s) to process"

$totalErrors = 0

if ($DoOneDrive) {
    $odErrors    = Invoke-OneDriveReset -UserProfiles $userProfiles
    $totalErrors += $odErrors
}

if ($DoTeams) {
    $teamsErrors  = Invoke-TeamsReset -UserProfiles $userProfiles
    $totalErrors += $teamsErrors
}

Write-Sep
if ($totalErrors -eq 0) {
    $msg = "PASS $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $Target reset OK on $($userProfiles.Count) profile(s) | Apps will re-sync on next launch"
    Write-Log "RESULT: Sync reset completed successfully."
    Write-Log "Apps will re-sync automatically when the user next launches them."
    Set-DattoUDF -Slot $UDF_SLOT -Value $msg
    exit 0
} else {
    $msg = "WARN $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $Target reset completed with $totalErrors error(s) -- check log"
    Write-Log "RESULT: Sync reset completed with $totalErrors error(s). Check log for details." 'WARN'
    Set-DattoUDF -Slot $UDF_SLOT -Value $msg
    exit 1
}
