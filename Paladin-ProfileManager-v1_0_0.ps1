#Requires -Version 3.0
# =============================================================================
# Paladin Inactive Profile Manager [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
#
# DESCRIPTION:
#   Scans all user profiles on the machine and identifies profiles that have
#   not been used within the configured threshold (30, 60, or 90 days).
#
#   Two modes controlled by input variables:
#
#   Report  -- Scans and reports all inactive profiles to the Datto job log.
#              No changes made to the machine. Use this first on every client
#              to review before approving deletion.
#
#   Delete  -- Deletes all inactive profiles that meet the day threshold.
#              Uses Win32_UserProfile.Delete() for safe WMI-managed removal
#              including registry cleanup. Logs each deletion and total space
#              reclaimed. Exits 1 if any deletion fails.
#
# NEVER TOUCHED (regardless of mode or age):
#   - Currently active / loaded profiles
#   - Built-in accounts: Administrator, Default, DefaultUser, Guest,
#     Public, SYSTEM, NetworkService, LocalService, WDAGUtilityAccount
#   - Profiles under the inactive day threshold
#   - Service accounts matching common patterns (svc*, _svc*)
#
# INPUT VARIABLES:
#   action       (String)  -- 'Report' or 'Delete' (default: Report)
#   inactiveDays (String)  -- '30', '60', or '90'  (default: 60)
#
# LOG:    C:\ProgramData\Paladin\ProfileManager\ProfileManager.log
# UDF:    Slot 17 (PALADIN-PROFILES)
# EXIT:   0 = success or report complete
#         1 = one or more deletions failed (Delete mode only)
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer  = '1.0.0'
$LogDir     = 'C:\ProgramData\Paladin\ProfileManager'
$LogFile    = "$LogDir\ProfileManager.log"
$UDF_SLOT   = 17   # PALADIN-PROFILES
$MaxLogMB   = 5

# Built-in / special accounts -- never touch these
$BuiltinExclusions = @(
    'administrator','default','defaultuser0','defaultuser1',
    'guest','public','systemprofile','networkservice','localservice',
    'wdagutilityaccount','all users','localadmin'
)

# Service account patterns -- never touch
$SvcPatterns = @('svc*','_svc*','*-svc','*service*acct*','*svcacct*')

# Input variables
$Action       = $env:action
$DaysStr      = $env:inactiveDays
if ([string]::IsNullOrEmpty($Action))  { $Action  = 'Report' }
if ([string]::IsNullOrEmpty($DaysStr)) { $DaysStr = '60' }

# Validate action
if ($Action -notin @('Report','Delete')) {
    Write-Host "Invalid action '$Action'. Must be 'Report' or 'Delete'. Defaulting to 'Report'."
    $Action = 'Report'
}

# Validate days
$InactiveDays = 60
switch ($DaysStr) {
    '30' { $InactiveDays = 30 }
    '60' { $InactiveDays = 60 }
    '90' { $InactiveDays = 90 }
    default {
        Write-Host "Invalid inactiveDays '$DaysStr'. Must be 30, 60, or 90. Defaulting to 60."
        $InactiveDays = 60
    }
}

$Threshold = (Get-Date).AddDays(-$InactiveDays)

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

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-FolderSize {
    param([string]$Path)
    try {
        $size = 0L
        Get-ChildItem -LiteralPath $Path -Recurse -Force -EA SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            ForEach-Object { $size += $_.Length }
        return $size
    } catch { return 0L }
}

function Test-IsServiceAccount {
    param([string]$Username)
    $lower = $Username.ToLower()
    foreach ($pat in $SvcPatterns) {
        if ($lower -like $pat) { return $true }
    }
    return $false
}

function Test-IsBuiltin {
    param([string]$Username)
    $lower = $Username.ToLower()
    return $BuiltinExclusions -contains $lower
}

# =============================================================================
# PROFILE SCANNER
# =============================================================================

function Get-InactiveProfiles {
    $results = @()

    try {
        $wmiProfiles = Get-WmiObject -Class Win32_UserProfile -EA SilentlyContinue |
            Where-Object { $_.Special -eq $false }
    } catch {
        Write-Log "ERROR: Failed to enumerate Win32_UserProfile: $($_.Exception.Message)" 'WARN'
        return $results
    }

    foreach ($profile in @($wmiProfiles)) {

        # Skip currently loaded profiles (active session)
        if ($profile.Loaded) {
            Write-Log "  [SKIP-ACTIVE] $($profile.LocalPath) -- currently loaded"
            continue
        }

        # Extract username from LocalPath
        $localPath = $profile.LocalPath
        $username  = Split-Path $localPath -Leaf

        # Skip built-in accounts
        if (Test-IsBuiltin -Username $username) {
            Write-Log "  [SKIP-BUILTIN] $username"
            continue
        }

        # Skip service accounts
        if (Test-IsServiceAccount -Username $username) {
            Write-Log "  [SKIP-SVC] $username -- matches service account pattern"
            continue
        }

        # Skip profiles with no valid path
        if ([string]::IsNullOrEmpty($localPath) -or -not (Test-Path $localPath)) {
            Write-Log "  [SKIP-NOPATH] $username -- profile path not found: $localPath"
            continue
        }

        # Get last use time
        $lastUse     = $null
        $daysInactive = 0
        try {
            if ($profile.LastUseTime) {
                $lastUse      = $profile.ConvertToDateTime($profile.LastUseTime)
                $daysInactive = [int]((Get-Date) - $lastUse).TotalDays
            }
        } catch {}

        # Skip if within threshold
        if ($null -ne $lastUse -and $lastUse -gt $Threshold) {
            Write-Log "  [SKIP-RECENT] $username -- last use: $($lastUse.ToString('yyyy-MM-dd')) ($daysInactive days ago)"
            continue
        }

        # Unknown last use -- flag but include
        $lastUseDisplay = if ($null -ne $lastUse) { $lastUse.ToString('yyyy-MM-dd') } else { 'Unknown' }
        $daysDisplay    = if ($null -ne $lastUse) { "$daysInactive days" } else { 'Unknown' }

        # Get profile size
        Write-Log "  Calculating size: $localPath"
        $sizeBytes = Get-FolderSize -Path $localPath

        $entry = New-Object PSObject -Property @{
            Username      = $username
            LocalPath     = $localPath
            LastUse       = $lastUseDisplay
            DaysInactive  = $daysInactive
            SizeBytes     = $sizeBytes
            SizeDisplay   = Format-Bytes -Bytes $sizeBytes
            WmiProfile    = $profile
        }

        $results += $entry
        Write-Log "  [INACTIVE] $username | Last: $lastUseDisplay ($daysDisplay) | Size: $(Format-Bytes -Bytes $sizeBytes)"
    }

    return $results
}

# =============================================================================
# REPORT MODE
# =============================================================================

function Invoke-Report {
    param($InactiveProfiles)

    Write-Sep
    Write-Log "REPORT: Inactive User Profiles (>$InactiveDays days) on $env:COMPUTERNAME"
    Write-Sep

    if ($InactiveProfiles.Count -eq 0) {
        Write-Log "No inactive profiles found matching criteria."
        Write-Log "All user profiles have been active within the last $InactiveDays days."
        Set-DattoUDF -Slot $UDF_SLOT -Value "REPORT $(Get-Date -Format 'yyyy-MM-dd') | No inactive profiles >$InactiveDays days"
        return
    }

    # Sort by days inactive descending
    $sorted = $InactiveProfiles | Sort-Object DaysInactive -Descending

    $totalSize = 0L
    foreach ($p in $sorted) { $totalSize += $p.SizeBytes }

    Write-Sep2
    Write-Log "INACTIVE PROFILES FOUND: $($sorted.Count) profile(s) | Total size: $(Format-Bytes -Bytes $totalSize)"
    Write-Sep2
    Write-Log ""
    Write-Log ("  {0,-25} {1,-14} {2,-12} {3}" -f 'Username','Last Logon','Days Idle','Size on Disk')
    Write-Log ("  {0,-25} {1,-14} {2,-12} {3}" -f ('-'*24),('-'*13),('-'*11),('-'*12))

    foreach ($p in $sorted) {
        Write-Log ("  {0,-25} {1,-14} {2,-12} {3}" -f $p.Username, $p.LastUse, $p.DaysInactive, $p.SizeDisplay)
    }

    Write-Log ""
    Write-Sep2
    Write-Log "SUMMARY"
    Write-Log "  Machine       : $env:COMPUTERNAME"
    Write-Log "  Site          : $($env:CS_PROFILE_NAME)"
    Write-Log "  Scan date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    Write-Log "  Threshold     : >$InactiveDays days inactive"
    Write-Log "  Profiles found: $($sorted.Count)"
    Write-Log "  Space savings : $(Format-Bytes -Bytes $totalSize) (if all deleted)"
    Write-Sep2
    Write-Log ""
    Write-Log "ACTION REQUIRED: Review the profiles listed above with the client admin."
    Write-Log "Once approved, re-run this component with action=Delete and the same"
    Write-Log "inactiveDays value to remove the inactive profiles."
    Write-Sep

    $udfMsg = "REPORT $(Get-Date -Format 'yyyy-MM-dd') | Found:$($sorted.Count) inactive >$InactiveDays days | Recoverable:$(Format-Bytes -Bytes $totalSize)"
    Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg
}

# =============================================================================
# DELETE MODE
# =============================================================================

function Invoke-Delete {
    param($InactiveProfiles)

    Write-Sep
    Write-Log "DELETE: Removing $($InactiveProfiles.Count) inactive profile(s) on $env:COMPUTERNAME"
    Write-Sep

    if ($InactiveProfiles.Count -eq 0) {
        Write-Log "No inactive profiles found matching criteria. Nothing to delete."
        Set-DattoUDF -Slot $UDF_SLOT -Value "DELETE $(Get-Date -Format 'yyyy-MM-dd') | No profiles to delete >$InactiveDays days"
        exit 0
    }

    $deleted     = 0
    $failed      = 0
    $reclaimedBytes = 0L
    $failedNames = @()

    foreach ($p in $InactiveProfiles) {

        Write-Log "  Deleting: $($p.Username) | $($p.LocalPath) | $($p.SizeDisplay)"

        try {
            # Win32_UserProfile.Delete() -- handles registry cleanup automatically
            $result = $p.WmiProfile.Delete()

            # Verify folder is gone
            if (-not (Test-Path $p.LocalPath)) {
                $deleted++
                $reclaimedBytes += $p.SizeBytes
                Write-Log "  [DELETED] $($p.Username) -- $($p.SizeDisplay) reclaimed"
            } else {
                # Folder still exists -- try direct removal as fallback
                Write-Log "  WMI delete completed but folder remains -- attempting folder removal"
                try {
                    Remove-Item -LiteralPath $p.LocalPath -Recurse -Force -EA Stop
                    $deleted++
                    $reclaimedBytes += $p.SizeBytes
                    Write-Log "  [DELETED] $($p.Username) -- folder removed manually -- $($p.SizeDisplay) reclaimed"
                } catch {
                    $failed++
                    $failedNames += $p.Username
                    Write-Log "  [FAILED] $($p.Username) -- folder removal failed: $($_.Exception.Message)" 'WARN'
                }
            }
        } catch {
            $failed++
            $failedNames += $p.Username
            Write-Log "  [FAILED] $($p.Username) -- WMI delete failed: $($_.Exception.Message)" 'WARN'
        }
    }

    Write-Sep2
    Write-Log "DELETE SUMMARY"
    Write-Log "  Deleted   : $deleted profile(s)"
    Write-Log "  Failed    : $failed profile(s)"
    Write-Log "  Reclaimed : $(Format-Bytes -Bytes $reclaimedBytes)"
    if ($failedNames.Count -gt 0) {
        Write-Log "  Failed profiles: $($failedNames -join ', ')" 'WARN'
    }
    Write-Sep

    if ($failed -gt 0) {
        $udfMsg = "DELETE $(Get-Date -Format 'yyyy-MM-dd') | Removed:$deleted Failed:$failed Reclaimed:$(Format-Bytes -Bytes $reclaimedBytes)"
        Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg
        exit 1
    }

    $udfMsg = "DELETED $(Get-Date -Format 'yyyy-MM-dd') | Removed:$deleted profiles Reclaimed:$(Format-Bytes -Bytes $reclaimedBytes)"
    Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg
    exit 0
}

# =============================================================================
# MAIN
# =============================================================================

if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

$siteName = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }

Write-Sep
Write-Log "Paladin Inactive Profile Manager v$ScriptVer | Site: $siteName | Machine: $env:COMPUTERNAME"
Write-Log "Mode: $Action | Threshold: >$InactiveDays days | Cutoff: $($Threshold.ToString('yyyy-MM-dd'))"
Write-Sep

Write-Log "Scanning profiles..."
$inactiveProfiles = Get-InactiveProfiles

Write-Log "Scan complete. Found $($inactiveProfiles.Count) inactive profile(s)."

if ($Action -eq 'Delete') {
    Invoke-Delete -InactiveProfiles $inactiveProfiles
} else {
    Invoke-Report -InactiveProfiles $inactiveProfiles
    exit 0
}
