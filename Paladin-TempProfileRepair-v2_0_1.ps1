#Requires -Version 3.0
# =============================================================================
# Paladin Temp Profile Repair & Cleanup [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 2.0.1
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
#
# DESCRIPTION:
#   Full detection and cleanup of all temp/orphaned profile debris on a
#   Windows machine. Addresses three distinct problem classes:
#
#   PASS 1 -- Registry corruption:
#     Detects .bak SID keys, corrupt ProfileImagePath values, bad State flags.
#     In Remove mode: renames .bak keys back to clean SID, corrects paths,
#     resets State flag to 0.
#
#   PASS 2 -- Orphaned filesystem folders:
#     Scans C:\Users for folders with NO valid registry entry that match
#     temp profile naming patterns:
#       - Folders named TEMP or starting with TEMP
#       - Folders with numeric suffixes (.000, .001, .002)
#       - Folders named as pure numeric strings
#     These are folders Windows created during failed logins and never
#     cleaned up. Often the source of multi-GB disk consumption.
#     In Remove mode: deletes orphaned folders and their registry debris.
#
#   PASS 3 -- Orphaned registry entries:
#     Detects ProfileList entries whose ProfileImagePath folder no longer
#     exists on disk (folder was manually deleted, key was left behind).
#     These cause future temp profile loops.
#     In Remove mode: removes the dangling registry key.
#
# INPUT VARIABLES:
#   action (String) -- 'Report' = scan only, no changes (default)
#                      'Remove' = fix registry + delete orphaned folders
#
# NEVER TOUCHED (any mode):
#   - Currently active/loaded profiles
#   - Profiles with valid registry entry AND existing folder (healthy)
#   - Built-in SIDs (S-1-5-18/19/20)
#   - Special folders: Public, Default, Default User, All Users
#
# LOG:    C:\ProgramData\Paladin\TempProfileRepair\TempProfileRepair.log
# UDF:    Slot 18 (PALADIN-TEMPPROFILE)
# EXIT:   0 = clean or successfully remediated
#         1 = issues found/remain after attempted remediation
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer     = '2.0.1'
$LogDir        = 'C:\ProgramData\Paladin\TempProfileRepair'
$LogFile       = "$LogDir\TempProfileRepair.log"
$ProfileList   = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$ProfilesBase  = $env:SystemDrive + '\Users'
$UDF_SLOT      = 18   # PALADIN-TEMPPROFILE
$MaxLogMB      = 5

# Built-in SIDs -- never touch
$BuiltinSIDs = @('S-1-5-18','S-1-5-19','S-1-5-20')

# Special folder names -- never touch
$SpecialFolders = @('public','default','default user','all users','defaultuser0','defaultuser1')

# Temp profile folder name patterns
# Folder qualifies as orphaned/temp if it matches ANY of these
$TempNamePatterns = @(
    '^TEMP$',               # exactly TEMP
    '^TEMP\.',              # TEMP.domain, TEMP.001 etc
    '\.\d{3}$',             # username.000, username.001
    '^\d+$'                 # pure numeric folder name
)

# Input variable
$Action = $env:action
if ([string]::IsNullOrEmpty($Action)) { $Action = 'Report' }
if ($Action -notin @('Report','Remove')) {
    Write-Host "Invalid action '$Action'. Must be Report or Remove. Defaulting to Report."
    $Action = 'Report'
}
$RemoveMode = ($Action -eq 'Remove')

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

function Test-IsSpecial {
    param([string]$FolderName)
    return ($SpecialFolders -contains $FolderName.ToLower())
}

function Test-IsBuiltinSID {
    param([string]$SID)
    return ($BuiltinSIDs -contains $SID)
}

function Test-IsTempPattern {
    param([string]$FolderName)
    foreach ($pat in $TempNamePatterns) {
        if ($FolderName -match $pat) { return $true }
    }
    return $false
}

function Test-ProfileLoaded {
    param([string]$SID)
    try {
        $wmi = Get-WmiObject -Class Win32_UserProfile -Filter "SID='$SID'" -EA SilentlyContinue
        if ($null -ne $wmi -and $wmi.Loaded) { return $true }
    } catch {}
    # Also check if HKU hive is loaded for this SID
    try {
        if (Test-Path "HKU:\$SID") { return $true }
    } catch {}
    return $false
}

function Get-ProfileListMap {
    # Returns hashtable: SID -> ProfileImagePath for all ProfileList entries
    $map = @{}
    try {
        $keys = Get-ChildItem -Path $ProfileList -EA SilentlyContinue
        foreach ($key in @($keys)) {
            $sidName = Split-Path $key.Name -Leaf
            $props   = Get-ItemProperty -Path "$ProfileList\$sidName" -EA SilentlyContinue
            if ($null -ne $props -and $props.ProfileImagePath) {
                $map[$sidName] = $props.ProfileImagePath
            }
        }
    } catch {}
    return $map
}

# =============================================================================
# PASS 1 -- REGISTRY CORRUPTION SCAN
# =============================================================================

function Invoke-Pass1RegistryScan {
    Write-Sep
    Write-Log 'PASS 1: Registry corruption scan'
    Write-Sep2

    $issues = @()
    try {
        $allKeys = Get-ChildItem -Path $ProfileList -EA SilentlyContinue
    } catch {
        Write-Log "ERROR: Cannot read ProfileList: $($_.Exception.Message)" 'WARN'
        return $issues
    }

    $cleanSIDs = @{}
    foreach ($key in @($allKeys)) {
        $n = Split-Path $key.Name -Leaf
        if ($n -notmatch '\.bak$' -and $n -notmatch '\.\d{3}$') { $cleanSIDs[$n] = $true }
    }

    foreach ($key in @($allKeys)) {
        $sidName  = Split-Path $key.Name -Leaf
        $keyPath  = "$ProfileList\$sidName"
        $baseSID  = $sidName -replace '\.bak$','' -replace '\.\d{3}$',''

        if (Test-IsBuiltinSID -SID $baseSID) { continue }

        $props       = Get-ItemProperty -Path $keyPath -EA SilentlyContinue
        if ($null -eq $props) { continue }

        $profilePath = $props.ProfileImagePath
        $state       = $props.State
        $username    = Split-Path $profilePath -Leaf

        if (Test-ProfileLoaded -SID $baseSID) {
            Write-Log "  [SKIP-ACTIVE] $username ($baseSID)"
            continue
        }

        $issueType = $null

        if ($sidName -match '\.bak$') {
            $issueType = if ($cleanSIDs.ContainsKey($baseSID)) { 'DuplicateBak' } else { 'OnlyBak' }
        } elseif ($profilePath -match '\.bak$' -or $profilePath -match '\.\d{3}$') {
            $issueType = 'CorruptPath'
        } elseif ($null -ne $state -and ($state -band 0x100) -eq 0x100) {
            $issueType = 'TempState'
        }

        if ($null -ne $issueType) {
            $folderExists = Test-Path ($profilePath -replace '\.bak$','' -replace '\.\d{3}$','')
            Write-Log "  [CORRUPT] $username | $sidName | $issueType | FolderExists:$folderExists" 'WARN'
            $issues += @{
                SIDName     = $sidName
                BaseSID     = $baseSID
                Username    = $username
                Path        = $profilePath
                IssueType   = $issueType
                FolderExists= $folderExists
                KeyPath     = $keyPath
                CleanSID    = $baseSID
            }
        } else {
            Write-Log "  [OK] $username ($sidName)"
        }
    }

    Write-Log "Pass 1 complete: $($issues.Count) registry issue(s) found"
    return $issues
}

# =============================================================================
# PASS 2 -- ORPHANED FILESYSTEM FOLDERS
# =============================================================================

function Invoke-Pass2FilesystemScan {
    param([hashtable]$ProfileMap)

    Write-Sep
    Write-Log 'PASS 2: Orphaned filesystem folder scan'
    Write-Sep2

    $orphans = @()

    if (-not (Test-Path $ProfilesBase)) {
        Write-Log "WARN: Profiles base path not found: $ProfilesBase"
        return $orphans
    }

    # Build reverse map: LocalPath (lowercase) -> SID for quick lookup
    $pathToSID = @{}
    foreach ($sid in $ProfileMap.Keys) {
        $p = $ProfileMap[$sid]
        if ($p) { $pathToSID[$p.ToLower()] = $sid }
    }

    # Explicit scope: ONLY scan C:\Users -- never match folders elsewhere
    $usersPath = $env:SystemDrive + '\Users'
    if (-not (Test-Path $usersPath)) { Write-Log 'WARN: C:\Users not found'; return $orphans }
    $folders = Get-ChildItem -Path $usersPath -Directory -Force -EA SilentlyContinue
    foreach ($folder in @($folders)) {
        $folderName = $folder.Name
        $folderPath = $folder.FullName

        # Skip special folders
        if (Test-IsSpecial -FolderName $folderName) {
            Write-Log "  [SKIP-SPECIAL] $folderName"
            continue
        }

        # Check if this folder has a valid registry entry
        $hasRegistryEntry = $pathToSID.ContainsKey($folderPath.ToLower())

        if ($hasRegistryEntry) {
            # Folder is registered -- check if it's a loaded profile
            $sid = $pathToSID[$folderPath.ToLower()]
            if (Test-ProfileLoaded -SID $sid) {
                Write-Log "  [SKIP-ACTIVE] $folderName (loaded)"
                continue
            }
            # Registered and not active -- healthy, skip
            Write-Log "  [OK] $folderName (registered)"
            continue
        }

        # No registry entry -- could be orphaned temp profile
        # Check if name matches temp patterns
        $isTempName = Test-IsTempPattern -FolderName $folderName

        if ($isTempName) {
            # Definitely orphaned temp -- size it and flag for removal
            Write-Log "  Sizing orphaned temp folder: $folderPath"
            $sizeBytes = Get-FolderSize -Path $folderPath
            Write-Log "  [ORPHANED-TEMP] $folderName | Size: $(Format-Bytes -Bytes $sizeBytes)" 'WARN'
            $orphans += @{
                FolderName  = $folderName
                FolderPath  = $folderPath
                SizeBytes   = $sizeBytes
                SizeDisplay = Format-Bytes -Bytes $sizeBytes
                Reason      = 'NoRegistryEntry+TempNamePattern'
            }
        } else {
            # No registry entry but name doesn't match temp pattern
            # Log for review but do not auto-remove -- could be manually created folder
            Write-Log "  [REVIEW] $folderName -- no registry entry but name not a temp pattern. Manual review recommended."
        }
    }

    Write-Log "Pass 2 complete: $($orphans.Count) orphaned temp folder(s) found"
    return $orphans
}

# =============================================================================
# PASS 3 -- ORPHANED REGISTRY ENTRIES
# =============================================================================

function Invoke-Pass3OrphanedRegistryScan {
    param([hashtable]$ProfileMap)

    Write-Sep
    Write-Log 'PASS 3: Orphaned registry entry scan'
    Write-Sep2

    $orphanedKeys = @()

    foreach ($sidName in $ProfileMap.Keys) {
        $baseSID = $sidName -replace '\.bak$','' -replace '\.\d{3}$',''
        if (Test-IsBuiltinSID -SID $baseSID) { continue }
        if (Test-ProfileLoaded -SID $baseSID) { continue }

        $profilePath = $ProfileMap[$sidName]
        # Normalize path -- strip .bak suffix for folder check
        $cleanPath   = $profilePath -replace '\.bak$','' -replace '\.\d{3}$',''
        $username    = Split-Path $cleanPath -Leaf

        if (-not (Test-Path $cleanPath)) {
            Write-Log "  [ORPHANED-REG] $username | SID: $sidName | Path missing: $cleanPath" 'WARN'
            $orphanedKeys += @{
                SIDName   = $sidName
                Username  = $username
                Path      = $profilePath
                KeyPath   = "$ProfileList\$sidName"
            }
        }
    }

    Write-Log "Pass 3 complete: $($orphanedKeys.Count) orphaned registry entry(s) found"
    return $orphanedKeys
}

# =============================================================================
# REMEDIATION -- PASS 1 REGISTRY FIXES
# =============================================================================

function Invoke-FixRegistry {
    param($Issues)

    $fixed = 0; $failed = 0

    foreach ($issue in $Issues) {
        Write-Sep2
        Write-Log "  Fixing: $($issue.Username) | $($issue.IssueType)"

        try {
            switch ($issue.IssueType) {
                'DuplicateBak' {
                    $bakPath   = "$ProfileList\$($issue.SIDName)"
                    $cleanPath = "$ProfileList\$($issue.CleanSID)"
                    $goodPath  = (Get-ItemProperty -Path $bakPath -EA Stop).ProfileImagePath -replace '\.bak$',''

                    Remove-Item -Path $cleanPath -Recurse -Force -EA Stop
                    $src = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($issue.SIDName)"
                    $dst = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($issue.CleanSID)"
                    & reg.exe copy $src $dst /s /f 2>&1 | Out-Null
                    Remove-Item -Path $bakPath -Recurse -Force -EA SilentlyContinue
                    Set-ItemProperty -Path $cleanPath -Name 'ProfileImagePath' -Value $goodPath -EA Stop
                    Set-ItemProperty -Path $cleanPath -Name 'State' -Value 0 -EA SilentlyContinue
                    $fixed++
                    Write-Log "    [FIXED] DuplicateBak resolved: $($issue.Username)"
                }
                'OnlyBak' {
                    $bakPath   = "$ProfileList\$($issue.SIDName)"
                    $cleanPath = "$ProfileList\$($issue.CleanSID)"
                    $goodPath  = (Get-ItemProperty -Path $bakPath -EA Stop).ProfileImagePath -replace '\.bak$',''
                    $src = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($issue.SIDName)"
                    $dst = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($issue.CleanSID)"
                    & reg.exe copy $src $dst /s /f 2>&1 | Out-Null
                    Set-ItemProperty -Path $cleanPath -Name 'ProfileImagePath' -Value $goodPath -EA Stop
                    Set-ItemProperty -Path $cleanPath -Name 'State' -Value 0 -EA SilentlyContinue
                    Remove-Item -Path $bakPath -Recurse -Force -EA SilentlyContinue
                    $fixed++
                    Write-Log "    [FIXED] OnlyBak resolved: $($issue.Username)"
                }
                'CorruptPath' {
                    $cleanPath2 = $issue.Path -replace '\.bak$','' -replace '\.\d{3}$',''
                    Set-ItemProperty -Path $issue.KeyPath -Name 'ProfileImagePath' -Value $cleanPath2 -EA Stop
                    Set-ItemProperty -Path $issue.KeyPath -Name 'State' -Value 0 -EA SilentlyContinue
                    $fixed++
                    Write-Log "    [FIXED] CorruptPath resolved: $($issue.Username)"
                }
                'TempState' {
                    Set-ItemProperty -Path $issue.KeyPath -Name 'State' -Value 0 -EA Stop
                    $fixed++
                    Write-Log "    [FIXED] TempState cleared: $($issue.Username)"
                }
            }
        } catch {
            $failed++
            Write-Log "    [FAILED] $($issue.Username): $($_.Exception.Message)" 'WARN'
        }
    }

    return @{ Fixed = $fixed; Failed = $failed }
}

# =============================================================================
# REMEDIATION -- PASS 2 DELETE ORPHANED FOLDERS
# =============================================================================

function Remove-FolderFast {
    param([string]$Path)
    # Robocopy MIR: mirror empty dir over target -- wipes contents in one pass.
    # Handles locked ACLs natively. No takeown/icacls overhead.
    # Single pass vs three passes = dramatically faster on large profile trees.
    $emptyDir = "$env:SystemRoot\Temp\PaladinEmpty_$(Get-Random)"
    try {
        New-Item -Path $emptyDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null
        & robocopy.exe $emptyDir $Path /MIR /R:1 /W:0 /NFL /NDL /NJH /NJS /NC /NS 2>&1 | Out-Null
        Remove-Item -LiteralPath $Path -Recurse -Force -EA Stop
        return $true
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $emptyDir -Recurse -Force -EA SilentlyContinue
    }
}

function Invoke-DeleteOrphanedFolders {
    param($Orphans)

    $deleted        = 0
    $failed         = 0
    $reclaimedBytes = 0L

    foreach ($o in $Orphans) {
        Write-Log "  Deleting: $($o.FolderPath) ($($o.SizeDisplay))"
        $ok = Remove-FolderFast -Path $o.FolderPath
        if ($ok) {
            $deleted++
            $reclaimedBytes += $o.SizeBytes
            Write-Log "  [DELETED] $($o.FolderName) -- $($o.SizeDisplay) reclaimed"
        } else {
            $failed++
            Write-Log "  [FAILED] $($o.FolderName)" 'WARN'
        }
    }

    return @{ Deleted = $deleted; Failed = $failed; ReclaimedBytes = $reclaimedBytes }
}

# =============================================================================
# REMEDIATION -- PASS 3 CLEAN ORPHANED REGISTRY KEYS
# =============================================================================

function Invoke-CleanOrphanedRegistry {
    param($OrphanedKeys)

    $cleaned = 0; $failed = 0

    foreach ($ok in $OrphanedKeys) {
        Write-Log "  Removing orphaned key: $($ok.SIDName) ($($ok.Username))"
        try {
            Remove-Item -Path $ok.KeyPath -Recurse -Force -EA Stop
            $cleaned++
            Write-Log "  [CLEANED] $($ok.Username) registry key removed"
        } catch {
            $failed++
            Write-Log "  [FAILED] $($ok.Username): $($_.Exception.Message)" 'WARN'
        }
    }

    return @{ Cleaned = $cleaned; Failed = $failed }
}

# =============================================================================
# MAIN
# =============================================================================

if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

$siteName = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }

Write-Sep
Write-Log "Paladin Temp Profile Repair & Cleanup v$ScriptVer | Site: $siteName | Machine: $env:COMPUTERNAME"
Write-Log "Mode: $Action"
Write-Sep

# Build profile map once -- used by all passes
$profileMap = Get-ProfileListMap
Write-Log "ProfileList entries found: $($profileMap.Count)"

# Run all three passes
$p1Issues      = Invoke-Pass1RegistryScan
$p2Orphans     = Invoke-Pass2FilesystemScan -ProfileMap $profileMap
$p3OrphanedReg = Invoke-Pass3OrphanedRegistryScan -ProfileMap $profileMap

# Summary of findings
Write-Sep
$totalOrphanBytes = 0L
foreach ($o in $p2Orphans) { $totalOrphanBytes += $o.SizeBytes }

Write-Log "SCAN SUMMARY:"
Write-Log "  Pass 1 -- Registry corruption  : $($p1Issues.Count) issue(s)"
Write-Log "  Pass 2 -- Orphaned temp folders : $($p2Orphans.Count) folder(s) | Total size: $(Format-Bytes -Bytes $totalOrphanBytes)"
Write-Log "  Pass 3 -- Orphaned registry keys: $($p3OrphanedReg.Count) key(s)"

if ($p2Orphans.Count -gt 0) {
    Write-Sep2
    Write-Log "ORPHANED TEMP FOLDERS:"
    foreach ($o in ($p2Orphans | Sort-Object SizeBytes -Descending)) {
        Write-Log ("  {0,-40} {1}" -f $o.FolderName, $o.SizeDisplay)
    }
}

$totalIssues = $p1Issues.Count + $p2Orphans.Count + $p3OrphanedReg.Count

if ($totalIssues -eq 0) {
    Write-Sep
    Write-Log "RESULT: Machine is clean. No temp profile debris found."
    Set-DattoUDF -Slot $UDF_SLOT -Value "CLEAN $(Get-Date -Format 'yyyy-MM-dd HH:mm') | No temp profile debris detected"
    exit 0
}

# Report mode -- stop here
if (-not $RemoveMode) {
    Write-Sep
    Write-Log "MODE: Report only -- no changes made."
    Write-Log "Re-run with action=Remove to remediate."
    $udfMsg = "FOUND $(Get-Date -Format 'yyyy-MM-dd HH:mm') | RegCorrupt:$($p1Issues.Count) OrphanFolders:$($p2Orphans.Count)($(Format-Bytes -Bytes $totalOrphanBytes)) OrphanReg:$($p3OrphanedReg.Count)"
    Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg
    exit 1
}

# Remove mode
Write-Sep
Write-Log "MODE: Remove -- remediating all findings"

# Large removal warning
if ($totalOrphanBytes -gt 10GB) {
    Write-Log "WARNING: Orphaned folders total $(Format-Bytes -Bytes $totalOrphanBytes) -- large removal in progress" 'WARN'
}

$p1Result = @{ Fixed = 0; Failed = 0 }
$p2Result = @{ Deleted = 0; Failed = 0; ReclaimedBytes = 0L }
$p3Result = @{ Cleaned = 0; Failed = 0 }

if ($p1Issues.Count -gt 0) {
    Write-Sep2
    Write-Log "Fixing $($p1Issues.Count) registry corruption(s)..."
    $p1Result = Invoke-FixRegistry -Issues $p1Issues
}

if ($p2Orphans.Count -gt 0) {
    Write-Sep2
    Write-Log "Deleting $($p2Orphans.Count) orphaned temp folder(s)..."
    $p2Result = Invoke-DeleteOrphanedFolders -Orphans $p2Orphans
}

if ($p3OrphanedReg.Count -gt 0) {
    Write-Sep2
    Write-Log "Cleaning $($p3OrphanedReg.Count) orphaned registry key(s)..."
    $p3Result = Invoke-CleanOrphanedRegistry -OrphanedKeys $p3OrphanedReg
}

# Final report
Write-Sep
$totalFailed = $p1Result.Failed + $p2Result.Failed + $p3Result.Failed
Write-Log "REMOVAL SUMMARY:"
Write-Log "  Registry fixes  : $($p1Result.Fixed) fixed, $($p1Result.Failed) failed"
Write-Log "  Folders deleted : $($p2Result.Deleted) deleted, $($p2Result.Failed) failed | Reclaimed: $(Format-Bytes -Bytes $p2Result.ReclaimedBytes)"
Write-Log "  Registry cleaned: $($p3Result.Cleaned) cleaned, $($p3Result.Failed) failed"
Write-Log "  Total reclaimed : $(Format-Bytes -Bytes $p2Result.ReclaimedBytes)"
Write-Sep

$udfMsg = "REMOVED $(Get-Date -Format 'yyyy-MM-dd HH:mm') | RegFixed:$($p1Result.Fixed) FoldersDeleted:$($p2Result.Deleted) RegCleaned:$($p3Result.Cleaned) Reclaimed:$(Format-Bytes -Bytes $p2Result.ReclaimedBytes)"
if ($totalFailed -gt 0) {
    $udfMsg += " ERRORS:$totalFailed"
    Write-Log "WARNING: $totalFailed item(s) could not be remediated -- check log" 'WARN'
}
Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg

if ($totalFailed -gt 0) { exit 1 }
exit 0
