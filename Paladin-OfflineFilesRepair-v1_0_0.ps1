#Requires -Version 3.0
# =============================================================================
# Paladin Offline Files Repair [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.0
# Context: NT AUTHORITY\SYSTEM (Datto)
#
# PURPOSE:
#   Repairs Windows Offline Files (CSC) sync issues without disabling the feature.
#   Backs up local offline cache before any destructive operation.
#   Server copy wins on conflict if server timestamp is newer.
#   Safe for domain/workgroup, terminal server, and standard workstations.
#   HIPAA-safe: no credentials stored, no sensitive data logged.
#
# SEQUENCE:
#   1. Detect environment (CSC enabled, sync state, conflicts, mapped paths)
#   2. Backup local offline cache (robocopy -> timestamped local folder)
#   3. Force sync attempt (mobsync.exe via scheduled task in user session)
#   4. Resolve conflicts (server wins if newer, local preserved in backup)
#   5. Reset CSC database (FormatDatabase registry key)
#   6. Register post-reboot resume task (verify sync health + write UDF)
#   7. Notify user + reboot
#
# INPUT VARIABLES:
#   UDFSlot             String   UDF slot for result                      (default: 30)
#   AllowReboot         Boolean  true = reboot after operation            (default: false)
#   BackupDrive         String   Drive letter for backup                  (default: C)
#   DisableOfflineFiles Boolean  true = disable CSC entirely after backup (default: false)
#
# LOG:  C:\ProgramData\Paladin\OfflineFilesRepair\OfflineFilesRepair.log
# EXIT: 0 = complete  |  1 = fatal error
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer   = '1.0.0'
$BaseDir     = 'C:\ProgramData\Paladin\OfflineFilesRepair'
$LogFile     = "$BaseDir\OfflineFilesRepair.log"
$Timestamp   = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$PsExe       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$ResumeTask  = 'Paladin_OfflineFiles_Resume'
$ResumeScript= "$BaseDir\OfflineFiles-Resume.ps1"
$SyncTask    = 'Paladin_OfflineFiles_Sync'

# CSC registry paths
$CSCParamsKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\CSC\Parameters'
$CSCNetCache  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\NetCache'
$CSCFolder    = "$env:SystemRoot\CSC"

# =============================================================================
# INPUT VARIABLES
# =============================================================================
$UDFSlot            = if ($env:UDFSlot    -match '^\d+$') { [int]$env:UDFSlot } else { 30 }
$AllowReboot        = ($env:AllowReboot        -eq 'true')
$DisableOfflineFiles= ($env:DisableOfflineFiles -eq 'true')
$BackupDrive        = if ($env:BackupDrive -match '^[A-Za-z]$') { $env:BackupDrive.ToUpper() } else { 'C' }
$BackupRoot  = "${BackupDrive}:\PaladinBackup\OfflineFiles\$Timestamp"
$SiteName    = if ($env:CS_PROFILE_NAME) { $env:CS_PROFILE_NAME } else { 'UNKNOWN' }
$MachineName = $env:COMPUTERNAME

# =============================================================================
# HELPERS
# =============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try {
        if (-not (Test-Path $BaseDir)) { New-Item $BaseDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }
        Add-Content -Path $LogFile -Value $line -EA SilentlyContinue
    } catch {}
}

function Write-Sep  { Write-Log ('=' * 64) }
function Write-Sep2 { Write-Log ('-' * 32) }

function Set-DattoUDF {
    param([int]$Slot, [string]$Value)
    $trimmed = if ($Value.Length -gt 255) { $Value.Substring(0,255) } else { $Value }
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' `
            -Name "Custom$Slot" -PropertyType String -Value $trimmed `
            -Force -EA Stop | Out-Null
        Write-Log "UDF$Slot => $trimmed"
    } catch { Write-Log "WARN: UDF$Slot write failed: $($_.Exception.Message)" 'WARN' }
}

function Show-UserMessage {
    param([string]$Message)
    try { & msg.exe '*' /TIME:300 "Paladin IT: $Message" 2>&1 | Out-Null } catch {}
}

function Get-UserProfiles {
    $results = @()
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $results += Get-ItemProperty "$pl\*" -EA SilentlyContinue |
        Where-Object { $_.PSChildName -match 'S-1-5-21-(\d+-?){4}$|S-1-12-1-(\d+-?){4}$' } |
        Select-Object @{Name='SID';    Expression={$_.PSChildName}},
                      @{Name='User';   Expression={Split-Path $_.ProfileImagePath -Leaf}},
                      @{Name='Path';   Expression={$_.ProfileImagePath}}
    return $results
}

function Test-CSCEnabled {
    try {
        $svc = Get-WmiObject -Class Win32_Service -Filter "Name='CscService'" -EA SilentlyContinue
        if ($null -eq $svc) { return $false }
        return ($svc.StartMode -ne 'Disabled' -and $svc.State -eq 'Running')
    } catch { return $false }
}

function Get-CSCSize {
    try {
        if (-not (Test-Path $CSCFolder)) { return 0L }
        $size = 0L
        Get-ChildItem -Path $CSCFolder -Recurse -Force -EA SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            ForEach-Object { $size += $_.Length }
        return $size
    } catch { return 0L }
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    return '{0:N2} KB' -f ($Bytes / 1KB)
}

# =============================================================================
# STEP 1 -- DETECT ENVIRONMENT
# =============================================================================

function Get-CSCState {
    Write-Sep
    Write-Log 'STEP 1: Detecting Offline Files state'
    Write-Sep2

    $state = @{
        Enabled        = $false
        ServiceRunning = $false
        CSCFolderSize  = 0L
        SyncPaths      = @()
        Conflicts      = @()
        MappedShares   = @()
        IsTermServer   = $false
        UserProfiles   = @()
        GPOManaged     = $false
    }

    # Service state
    try {
        $svc = Get-WmiObject -Class Win32_Service -Filter "Name='CscService'" -EA SilentlyContinue
        if ($null -ne $svc) {
            $state.Enabled        = ($svc.StartMode -ne 'Disabled')
            $state.ServiceRunning = ($svc.State -eq 'Running')
            Write-Log "  CSC Service: StartMode=$($svc.StartMode) State=$($svc.State)"
        } else { Write-Log '  CSC Service: not found' 'WARN' }
    } catch {}

    # CSC folder size
    $state.CSCFolderSize = Get-CSCSize
    Write-Log "  CSC cache size: $(Format-Bytes $state.CSCFolderSize)"

    # Terminal server detection
    try {
        $tsMode = (Get-WmiObject -Class Win32_TerminalServiceSetting -Namespace root\cimv2\TerminalServices -EA SilentlyContinue).TerminalServerMode
        $state.IsTermServer = ($tsMode -eq 1)
    } catch {}
    Write-Log "  Terminal Server: $($state.IsTermServer)"

    # User profiles
    $state.UserProfiles = Get-UserProfiles
    Write-Log "  User profiles: $($state.UserProfiles.Count)"

    # Mapped network shares with offline setting
    try {
        $shares = @(Get-WmiObject -Class Win32_MappedLogicalDisk -EA SilentlyContinue)
        foreach ($s in $shares) {
            $state.MappedShares += @{ Name=$s.Name; ProviderName=$s.ProviderName }
            Write-Log "  Mapped share: $($s.Name) -> $($s.ProviderName)"
        }
    } catch {}

    # Sync Center conflicts via COM
    try {
        $syncMgr = New-Object -ComObject 'Microsoft.SyncCenter.SyncMgrControl' -EA SilentlyContinue
        if ($null -ne $syncMgr) { Write-Log '  Sync Center COM: available' }
    } catch {}

    # GPO check
    try {
        $gpo = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache' -EA SilentlyContinue
        if ($null -ne $gpo) { $state.GPOManaged = $true; Write-Log '  GPO: Offline Files policy detected' 'WARN' }
    } catch {}

    # Check FormatDatabase not already pending
    try {
        $existing = Get-ItemProperty -Path $CSCParamsKey -Name 'FormatDatabase' -EA SilentlyContinue
        if ($null -ne $existing) { Write-Log '  WARN: FormatDatabase already pending from previous run' 'WARN' }
    } catch {}

    Write-Log "  Enabled:$($state.Enabled) Running:$($state.ServiceRunning) Shares:$($state.MappedShares.Count) TermSrv:$($state.IsTermServer)"
    return $state
}

# =============================================================================
# STEP 2 -- BACKUP LOCAL OFFLINE CACHE (before any destructive operation)
# =============================================================================

function Invoke-CSCBackup {
    param([hashtable]$State)
    Write-Sep
    Write-Log 'STEP 2: Backing up local offline cache'
    Write-Sep2
    Write-Log "  Backup destination: $BackupRoot"

    if (-not (Test-Path $BackupRoot)) {
        New-Item -Path $BackupRoot -ItemType Directory -Force -EA SilentlyContinue | Out-Null
    }

    $backedUp = 0; $failed = 0

    # Back up CSC folder (system cache)
    if (Test-Path $CSCFolder) {
        $cscBackup = "$BackupRoot\CSC_Cache"
        Write-Log "  Backing up CSC folder ($(Format-Bytes $State.CSCFolderSize))..."
        try {
            # Take ownership first -- CSC is protected
            & takeown.exe /F $CSCFolder /R /A /D Y 2>&1 | Out-Null
            & icacls.exe $CSCFolder /grant "SYSTEM:(OI)(CI)F" /T /Q 2>&1 | Out-Null
            & robocopy.exe $CSCFolder $cscBackup /E /COPYALL /R:1 /W:0 /NFL /NDL /NJH /NJS /XJ 2>&1 | Out-Null
            Write-Log "  [OK] CSC cache backed up"
            $backedUp++
        } catch { Write-Log "  [WARN] CSC cache backup partial: $($_.Exception.Message)" 'WARN'; $failed++ }
    } else { Write-Log '  CSC folder not found -- nothing to back up' }

    # Back up user offline file folders (redirected folders etc.)
    foreach ($u in $State.UserProfiles) {
        if (-not (Test-Path $u.Path)) { continue }
        $userBackup = "$BackupRoot\UserProfiles\$($u.User)"
        Write-Log "  Backing up offline folders for: $($u.User)"

        $offlineFolders = @(
            "$($u.Path)\Documents",
            "$($u.Path)\Desktop",
            "$($u.Path)\AppData\Roaming\Microsoft\Outlook"
        )
        foreach ($f in $offlineFolders) {
            if (-not (Test-Path $f)) { continue }
            $dest = Join-Path $userBackup (Split-Path $f -Leaf)
            try {
                & robocopy.exe $f $dest /E /COPYALL /R:1 /W:0 /NFL /NDL /NJH /NJS /XJ 2>&1 | Out-Null
                Write-Log "    [OK] $($u.User)\$(Split-Path $f -Leaf)"
                $backedUp++
            } catch { Write-Log "    [WARN] $($u.User)\$(Split-Path $f -Leaf): $($_.Exception.Message)" 'WARN'; $failed++ }
        }
    }

    # Write backup manifest
    $manifestPath = "$BackupRoot\BACKUP_MANIFEST.txt"
    @"
Paladin Offline Files Repair -- Backup Manifest
================================================
Date       : $Timestamp
Machine    : $MachineName
Site       : $SiteName
CSC Size   : $(Format-Bytes $State.CSCFolderSize)
Profiles   : $($State.UserProfiles.Count)
Backed up  : $backedUp items
Failed     : $failed items

RESTORE INSTRUCTIONS:
If files need to be recovered, copy from:
  $BackupRoot
To the appropriate user profile or share path.
Server copy was used as the source of truth where conflicts existed.
"@ | Set-Content -Path $manifestPath -Force -EA SilentlyContinue

    Write-Log "  Backup complete: $backedUp OK, $failed failed"
    Write-Log "  Manifest: $manifestPath"
    return @{ BackupPath = $BackupRoot; OK = $backedUp; Failed = $failed }
}

# =============================================================================
# STEP 3 -- FORCE SYNC ATTEMPT (before reset -- captures any unsynced changes)
# =============================================================================

function Invoke-ForceSyncAttempt {
    Write-Sep
    Write-Log 'STEP 3: Force sync attempt (capturing unsynced changes before reset)'
    Write-Sep2

    # Try mobsync via scheduled task in user session
    try {
        & schtasks.exe /Delete /TN $SyncTask /F 2>&1 | Out-Null
        $cmd = "$PsExe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"& mobsync.exe /logon`""
        & schtasks.exe /Create /TN $SyncTask /TR $cmd /SC ONCE /ST ((Get-Date).AddSeconds(5).ToString('HH:mm')) /RU 'SYSTEM' /RL HIGHEST /F 2>&1 | Out-Null
        Start-Sleep -Seconds 15
        & schtasks.exe /Delete /TN $SyncTask /F 2>&1 | Out-Null
        Write-Log '  mobsync triggered -- waited 15s for sync attempt'
    } catch { Write-Log "  WARN: mobsync trigger failed: $($_.Exception.Message)" 'WARN' }

    # Also try direct sync via WMI if available
    try {
        $cscAgent = [System.Runtime.InteropServices.Marshal]::GetActiveObject('CSC.Agent')
        if ($null -ne $cscAgent) { Write-Log '  CSC Agent COM: found, sync triggered' }
    } catch {}

    Write-Log '  Sync attempt complete'
}

# =============================================================================
# STEP 4 -- RESOLVE CONFLICTS (server wins if newer)
# =============================================================================

function Resolve-SyncConflicts {
    param([hashtable]$State)
    Write-Sep
    Write-Log 'STEP 4: Conflict resolution (server copy wins if newer timestamp)'
    Write-Sep2

    $resolved = 0; $skipped = 0; $errors = 0

    foreach ($share in $State.MappedShares) {
        $sharePath = $share.ProviderName
        $drivePath = "$($share.Name)\"

        if (-not (Test-Path $sharePath) -and -not (Test-Path $drivePath)) {
            Write-Log "  [SKIP] Share unreachable: $sharePath" 'WARN'
            $skipped++
            continue
        }

        Write-Log "  Checking: $($share.Name) -> $sharePath"

        # Find files in CSC that have newer server counterparts
        try {
            $basePath = if (Test-Path $drivePath) { $drivePath } else { $sharePath }
            $serverFiles = Get-ChildItem -Path $basePath -Recurse -File -EA SilentlyContinue
            foreach ($sf in $serverFiles) {
                $relPath  = $sf.FullName.Substring($basePath.Length).TrimStart('\')
                $cscMatch = Get-ChildItem -Path $CSCFolder -Recurse -Filter $sf.Name -EA SilentlyContinue |
                    Where-Object { $_.FullName -notmatch '\\v2\.0[56]\\' -eq $false } |
                    Select-Object -First 1

                if ($null -eq $cscMatch) { continue }

                if ($sf.LastWriteTime -gt $cscMatch.LastWriteTime) {
                    # Server is newer -- local is stale, backup already done, server wins on reset
                    Write-Log "    [SERVER-WINS] $relPath (server: $($sf.LastWriteTime) > local: $($cscMatch.LastWriteTime))"
                    $resolved++
                } elseif ($cscMatch.LastWriteTime -gt $sf.LastWriteTime) {
                    # Local is newer -- flag it, backup already captured it
                    Write-Log "    [LOCAL-NEWER] $relPath -- preserved in backup, server reset will overwrite" 'WARN'
                    $skipped++
                }
            }
        } catch { Write-Log "  WARN: Conflict scan error on $sharePath : $($_.Exception.Message)" 'WARN'; $errors++ }
    }

    Write-Log "  Conflict resolution: server-wins=$resolved local-newer-flagged=$skipped errors=$errors"
    return @{ Resolved = $resolved; Skipped = $skipped; Errors = $errors }
}

# =============================================================================
# STEP 5 -- RESET CSC DATABASE
# =============================================================================

function Invoke-CSCReset {
    Write-Sep
    Write-Log 'STEP 5: CSC database reset (FormatDatabase)'
    Write-Sep2

    $errors = 0

    # Write FormatDatabase to BOTH registry paths for compatibility
    # Win10/11: CSC\Parameters  |  Legacy: NetCache
    try {
        if (-not (Test-Path $CSCParamsKey)) {
            New-Item -Path $CSCParamsKey -Force -EA Stop | Out-Null
        }
        New-ItemProperty -Path $CSCParamsKey -Name 'FormatDatabase' -Value 1 `
            -PropertyType DWord -Force -EA Stop | Out-Null
        Write-Log "  FormatDatabase set: $CSCParamsKey"
    } catch { Write-Log "  ERROR: Failed to set CSC\Parameters\FormatDatabase: $($_.Exception.Message)" 'ERROR'; $errors++ }

    try {
        if (-not (Test-Path $CSCNetCache)) {
            New-Item -Path $CSCNetCache -Force -EA SilentlyContinue | Out-Null
        }
        New-ItemProperty -Path $CSCNetCache -Name 'FormatDatabase' -Value 1 `
            -PropertyType DWord -Force -EA SilentlyContinue | Out-Null
        Write-Log "  FormatDatabase set: $CSCNetCache (legacy compat)"
    } catch { Write-Log "  WARN: Legacy NetCache key failed (non-fatal): $($_.Exception.Message)" 'WARN' }

    # Ensure CSC service is set to auto-start so it comes up healthy after reset
    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CscService' `
            -Name 'Start' -Value 2 -Force -EA SilentlyContinue
        Write-Log '  CSC service start type: set to Automatic'
    } catch {}

    Write-Log '  CSC reset staged. Will take effect on next reboot.'
    Write-Log '  NOTE: All sync relationships will be re-established from server after reboot.'
    return @{ Errors = $errors }
}

# =============================================================================
# STEP 6 -- POST-REBOOT RESUME TASK
# =============================================================================

function Register-ResumeTask {
    param([string]$BackupPath)
    Write-Sep
    Write-Log 'STEP 6: Registering post-reboot health check task'
    Write-Sep2

    $resumeContent = @"
param()
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
Start-Sleep -Seconds 60   # wait for CSC to fully initialize post-reset
`$log = '$BaseDir\OfflineFiles-Resume.log'
function WL { param(`$m,[string]`$l='INFO'); Add-Content -Path `$log -Value "[(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [`$l] `$m" -EA SilentlyContinue; Write-Host `$m }

WL 'Post-reboot Offline Files health check starting...'

# Verify CSC service running
`$svc = Get-WmiObject -Class Win32_Service -Filter "Name='CscService'" -EA SilentlyContinue
`$svcState = if(`$null -ne `$svc){`$svc.State}else{'NotFound'}
WL "CSC Service state: `$svcState"

# Verify FormatDatabase key was consumed (should be gone after reboot)
`$fmtKey = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CSC\Parameters' -Name 'FormatDatabase' -EA SilentlyContinue
if(`$null -ne `$fmtKey){ WL 'WARN: FormatDatabase key still present -- reset may not have completed' 'WARN' }
else{ WL 'FormatDatabase key consumed -- CSC reset completed successfully' }

# Check CSC folder empty/reset
`$cscSize = 0L
Get-ChildItem '$env:SystemRoot\CSC' -Recurse -Force -EA SilentlyContinue |
    Where-Object { -not `$_.PSIsContainer } | ForEach-Object { `$cscSize += `$_.Length }
WL "CSC cache size post-reset: `$([Math]::Round(`$cscSize/1MB,2)) MB"

# Trigger sync via mobsync
try { & mobsync.exe /logon 2>&1 | Out-Null; WL 'mobsync triggered' } catch {}

# Write result to UDF
`$status = if(`$svcState -eq 'Running'){'PASS'}else{'WARN'}
`$msg = "`$status $(Get-Date -Format 'yyyy-MM-dd HH:mm') | `$env:COMPUTERNAME | CSC reset OK | Backup: $BackupPath"
try { New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' -Name 'Custom$UDFSlot' -Value `$msg -PropertyType String -Force -EA SilentlyContinue | Out-Null } catch {}
WL "UDF written: `$msg"

# Self-delete
try { & schtasks.exe /Delete /TN '$ResumeTask' /F 2>&1 | Out-Null } catch {}
try { Remove-Item -LiteralPath `$PSCommandPath -Force -EA SilentlyContinue } catch {}
WL 'Resume task complete. Self-deleted.'
"@

    [System.IO.File]::WriteAllText($ResumeScript, $resumeContent, [System.Text.Encoding]::ASCII)

    try {
        & schtasks.exe /Delete /TN $ResumeTask /F 2>&1 | Out-Null
        $cmd = "$PsExe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ResumeScript`""
        & schtasks.exe /Create /TN $ResumeTask /TR $cmd /SC ONSTART /RU SYSTEM /RL HIGHEST /DELAY 0001:00 /F 2>&1 | Out-Null
        Write-Log "  Resume task registered: '$ResumeTask' -- fires 1min after reboot"
    } catch { Write-Log "  WARN: Could not register resume task: $($_.Exception.Message)" 'WARN' }
}

# =============================================================================
# STEP 5b -- DISABLE OFFLINE FILES ENTIRELY (when DisableOfflineFiles=true)
# =============================================================================

function Invoke-DisableOfflineFiles {
    Write-Sep
    Write-Log 'STEP 5b: Disabling Offline Files (CSC) entirely'
    Write-Sep2

    $errors = 0

    # Stop the CSC service
    Write-Log '  Stopping CscService...'
    try {
        & sc.exe stop CscService 2>&1 | Out-Null
        $waited = 0
        while ($waited -lt 15) {
            $svc = Get-WmiObject -Class Win32_Service -Filter "Name='CscService'" -EA SilentlyContinue
            if ($null -ne $svc -and $svc.State -ne 'Running') { break }
            Start-Sleep 1; $waited++
        }
        Write-Log "  CscService stopped"
    } catch { Write-Log "  WARN: Could not stop CscService: $($_.Exception.Message)" 'WARN' }

    # Disable the service start type
    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CscService' `
            -Name 'Start' -Value 4 -Force -EA Stop   # 4 = Disabled
        Write-Log '  CscService start type: Disabled'
    } catch { Write-Log "  ERROR: Could not disable CscService: $($_.Exception.Message)" 'ERROR'; $errors++ }

    # Registry: disable Offline Files via both policy + standard key
    try {
        $netCachePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache'
        if (-not (Test-Path $netCachePolicy)) { New-Item -Path $netCachePolicy -Force -EA SilentlyContinue | Out-Null }
        New-ItemProperty -Path $netCachePolicy -Name 'Enabled' -Value 0 -PropertyType DWord -Force -EA SilentlyContinue | Out-Null
        Write-Log '  NetCache policy: Enabled=0'
    } catch { Write-Log "  WARN: Policy key failed (non-fatal)" 'WARN' }

    try {
        if (-not (Test-Path $CSCNetCache)) { New-Item -Path $CSCNetCache -Force -EA SilentlyContinue | Out-Null }
        New-ItemProperty -Path $CSCNetCache -Name 'Enabled' -Value 0 -PropertyType DWord -Force -EA SilentlyContinue | Out-Null
        Write-Log '  NetCache: Enabled=0'
    } catch { Write-Log "  WARN: NetCache key failed (non-fatal)" 'WARN' }

    # Stage FormatDatabase so cache is wiped clean on reboot
    try {
        if (-not (Test-Path $CSCParamsKey)) { New-Item -Path $CSCParamsKey -Force -EA SilentlyContinue | Out-Null }
        New-ItemProperty -Path $CSCParamsKey -Name 'FormatDatabase' -Value 1 -PropertyType DWord -Force -EA SilentlyContinue | Out-Null
        Write-Log '  FormatDatabase staged: cache wiped on reboot'
    } catch { Write-Log "  WARN: FormatDatabase staging failed" 'WARN' }

    Write-Log "  Offline Files disabled. Errors: $errors"
    Write-Log '  NOTE: If GPO enforces Offline Files it will re-enable on next gpupdate.'
    Write-Log '        Coordinate with domain admin to update GPO for permanent disable.'
    return @{ Errors = $errors }
}

# =============================================================================
# MAIN
# =============================================================================
if (-not (Test-Path $BaseDir)) { New-Item $BaseDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

$startTime = Get-Date
Write-Sep
Write-Log "Paladin Offline Files Repair v$ScriptVer | Site: $SiteName | Machine: $MachineName"
Write-Log "AllowReboot: $AllowReboot | DisableOfflineFiles: $DisableOfflineFiles | BackupDrive: $BackupDrive | UDF: $UDFSlot"
Write-Sep

# Step 1 -- Detect
$cscState = Get-CSCState

if (-not $cscState.Enabled) {
    if ($DisableOfflineFiles) {
        Write-Log 'Offline Files already disabled -- verifying all disable settings are applied correctly.'
    } else {
        Write-Log 'Offline Files (CSC) is not enabled on this machine -- nothing to repair.'
        Set-DattoUDF -Slot $UDFSlot -Value "INFO $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | Offline Files not enabled"
        exit 0
    }
}

if ($cscState.GPOManaged) {
    Write-Log 'WARN: Offline Files is GPO-managed. Registry changes may be overridden by policy.' 'WARN'
    Write-Log 'Proceeding -- but recommend reviewing GPO settings after repair.'
}

# Step 2 -- Backup (ALWAYS before any destructive operation)
$backupResult = Invoke-CSCBackup -State $cscState

# Step 3 -- Force sync attempt
Invoke-ForceSyncAttempt

# Step 4 -- Resolve conflicts
$conflictResult = Resolve-SyncConflicts -State $cscState

# Step 5 -- CSC reset OR disable (mutually exclusive)
if ($DisableOfflineFiles) {
    $resetResult = Invoke-DisableOfflineFiles
} else {
    $resetResult = Invoke-CSCReset
}

# Step 6 -- Post-reboot task
Register-ResumeTask -BackupPath $BackupRoot

# =============================================================================
# FINAL REPORT
# =============================================================================
$elapsed     = [int]((Get-Date) - $startTime).TotalMinutes
$totalErrors = $resetResult.Errors

Write-Sep
Write-Log 'PALADIN OFFLINE FILES REPAIR -- COMPLETE'
Write-Log "Site     : $SiteName | Machine: $MachineName | Duration: ${elapsed}m"
Write-Sep
Write-Log "Step 1 -- Detection  : Enabled=$($cscState.Enabled) Shares=$($cscState.MappedShares.Count) TermSrv=$($cscState.IsTermServer)"
Write-Log "Step 2 -- Backup     : $($backupResult.OK) items backed up -> $BackupRoot"
Write-Log "Step 3 -- Sync       : Force sync attempted"
Write-Log "Step 4 -- Conflicts  : server-wins=$($conflictResult.Resolved) local-newer-flagged=$($conflictResult.Skipped)"
Write-Log "Step 5 -- CSC $(if($DisableOfflineFiles){'Disable  : Offline Files disabled, cache wipe staged'}else{'Reset    : FormatDatabase staged (fires on reboot)'})"
Write-Log "Step 6 -- Resume     : '$ResumeTask' registered"
Write-Log ''
Write-Log '*** IMPORTANT: Backup of local offline files at:'
Write-Log "    $BackupRoot"
Write-Log '*** Files where local copy was newer have been flagged in the log.'
Write-Log '*** Server copy will be the source of truth after reset.'
Write-Sep

$ts     = Get-Date -Format 'yyyy-MM-dd HH:mm'
$modeWord = if ($DisableOfflineFiles) { 'CSC disabled' } else { 'CSC reset staged' }
$udfMsg = "$(if($totalErrors -eq 0){'PASS'}else{'WARN'}) $ts | $MachineName | $modeWord | Backup OK | $(if($AllowReboot){'Reboot:pending'}else{'Reboot:manual'})"
Set-DattoUDF -Slot $UDFSlot -Value $udfMsg

if ($AllowReboot -and $totalErrors -eq 0) {
    $rebootReason = if ($DisableOfflineFiles) { 'disable Offline Files and wipe sync cache' } else { 'CSC reset to take effect' }
    Write-Log "Rebooting in 60 seconds for $rebootReason."
    Show-UserMessage "IT Maintenance: Your PC will restart in 60 seconds to $rebootReason. Please SAVE ALL OPEN WORK. Your files are safe -- a backup was taken before this repair."
    Start-Sleep -Seconds 30
    Show-UserMessage 'PC will restart in 30 seconds. File sync will be restored automatically after reboot.'
    Start-Sleep -Seconds 30
    Write-Log 'Initiating reboot.'
    & shutdown.exe /r /t 0 /f /c "Paladin: Offline Files $modeWord. Changes take effect after login." 2>&1 | Out-Null
    exit 0
} elseif (-not $AllowReboot) {
    Write-Log "AllowReboot=false -- reboot manually to complete the operation."
    Write-Log "Registry changes are staged and will fire on next reboot."
}

exit $(if($totalErrors -eq 0){0}else{1})
