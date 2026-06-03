#Requires -Version 3.0
# =============================================================================
# Paladin Storage Clean & Optimize [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.2
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
#
# DESCRIPTION:
#   Complete hands-free storage cleanup and system optimization orchestrator.
#   Runs all Paladin cleanup routines in optimal sequence with free-space
#   checks between each phase. Two modes only: Report or Clean.
#
#   REPORT MODE -- Scans everything, estimates reclaim, no changes.
#   CLEAN MODE  -- Runs full sequence automatically:
#     Phase 1: Temp Profile Cleanup    (orphaned TEMP folders + registry)
#     Phase 2: Inactive Profile Removal (auto-approved, configurable days)
#     Phase 3: PPM Advanced            (optimization + standard junk cleanup)
#     Phase 4: SFC + DISM              (system file integrity repair)
#     Phase 5: CHKDSK                  (scheduled on next reboot if needed)
#     Phase 6: VSS Cleanup + WER Dumps  (shadow copy trim + crash dump removal)
#
# INPUT VARIABLES:
#   action       (String)  -- 'Report' or 'Clean' (default: Report)
#   inactiveDays (String)  -- '30', '60', or '90' for Phase 2 (default: 60)
#   allowReboot  (Boolean) -- true = schedule CHKDSK reboot (default: false)
#   minFreeGB    (String)  -- minimum free GB before each phase (default: 2)
#
# LOG:    C:\ProgramData\Paladin\StorageClean\StorageClean.log
# UDF:    Slot 22 (PALADIN-STORCLEAN)
# EXIT:   0 = completed successfully
#         1 = one or more phases failed
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer      = '1.0.2'
$LogDir         = 'C:\ProgramData\Paladin\StorageClean'
$LogFile        = "$LogDir\StorageClean.log"
$ProfilesBase   = $env:SystemDrive + '\Users'
$ProfileList    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$PPMBackupRoot  = 'HKLM:\SOFTWARE\Paladin\PPM\RMM\Backup'
$UDF_SLOT       = 22   # PALADIN-STORCLEAN
$MaxLogMB       = 10

# Built-in / special exclusions
$BuiltinSIDs    = @('S-1-5-18','S-1-5-19','S-1-5-20')
$SpecialFolders = @('public','default','default user','all users','defaultuser0','defaultuser1')
$TempPatterns   = @('^TEMP$','^TEMP\.','\.\d{3}$','^\d+$')
$ProfileExclusions = @(
    'administrator','default','defaultuser0','defaultuser1',
    'guest','public','systemprofile','networkservice','localservice',
    'wdagutilityaccount','all users','localadmin'
)
$SvcPatterns = @('svc*','_svc*','*-svc','*serviceacct*','*svcacct*')

# Input variables
$Action       = $env:action
$DaysStr      = $env:inactiveDays
$AllowReboot  = ($env:allowReboot -eq 'true')
$MinFreeStr   = $env:minFreeGB

if ([string]::IsNullOrEmpty($Action))    { $Action    = 'Report' }
if ([string]::IsNullOrEmpty($DaysStr))   { $DaysStr   = '60' }
if ([string]::IsNullOrEmpty($MinFreeStr)){ $MinFreeStr = '2' }

if ($Action -notin @('Report','Clean')) {
    Write-Host "Invalid action '$Action'. Must be Report or Clean. Defaulting to Report."
    $Action = 'Report'
}

$InactiveDays = 60
switch ($DaysStr) {
    '30' { $InactiveDays = 30 }
    '60' { $InactiveDays = 60 }
    '90' { $InactiveDays = 90 }
    default { $InactiveDays = 60 }
}

$MinFreeGB = 2
try { $MinFreeGB = [int]$MinFreeStr } catch {}
$CleanMode = ($Action -eq 'Clean')

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

function Get-DriveFreeGB {
    try {
        $disk = Get-WmiObject -Class Win32_LogicalDisk `
            -Filter "DeviceID='$($env:SystemDrive)'" -EA SilentlyContinue
        if ($null -ne $disk) { return [math]::Round($disk.FreeSpace / 1GB, 2) }
    } catch {}
    return 0
}

function Test-DiskGate {
    param([string]$PhaseName)
    $free = Get-DriveFreeGB
    if ($free -lt $MinFreeGB) {
        Write-Log "WARN: $PhaseName skipped -- free space ${free}GB below minimum ${MinFreeGB}GB" 'WARN'
        return $false
    }
    Write-Log "Disk gate OK: ${free}GB free (min ${MinFreeGB}GB)"
    return $true
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

function Test-IsSpecial { param([string]$N) return ($SpecialFolders -contains $N.ToLower()) }
function Test-IsBuiltinSID { param([string]$S) return ($BuiltinSIDs -contains $S) }
function Test-IsTempPattern {
    param([string]$N)
    foreach ($p in $TempPatterns) { if ($N -match $p) { return $true } }
    return $false
}
function Test-IsBuiltinProfile { param([string]$N) return ($ProfileExclusions -contains $N.ToLower()) }
function Test-IsSvcAccount {
    param([string]$N)
    foreach ($p in $SvcPatterns) { if ($N.ToLower() -like $p) { return $true } }
    return $false
}

function Test-ProfileLoaded {
    param([string]$SID)
    try {
        $wmi = Get-WmiObject -Class Win32_UserProfile -Filter "SID='$SID'" -EA SilentlyContinue
        if ($null -ne $wmi -and $wmi.Loaded) { return $true }
    } catch {}
    return $false
}

function Get-ProfileListMap {
    $map = @{}
    try {
        foreach ($key in @(Get-ChildItem -Path $ProfileList -EA SilentlyContinue)) {
            $sidName = Split-Path $key.Name -Leaf
            $props   = Get-ItemProperty -Path "$ProfileList\$sidName" -EA SilentlyContinue
            if ($null -ne $props -and $props.ProfileImagePath) { $map[$sidName] = $props.ProfileImagePath }
        }
    } catch {}
    return $map
}

function Remove-FolderSafe {
    param([string]$Path)
    # Robocopy MIR: mirror empty dir over target -- single pass, handles locked ACLs.
    # Dramatically faster than takeown + icacls + Remove-Item on large trees.
    $emptyDir = "$env:SystemRoot\Temp\PaladinEmpty_$(Get-Random)"
    try {
        New-Item -Path $emptyDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null
        & robocopy.exe $emptyDir $Path /MIR /R:1 /W:0 /NFL /NDL /NJH /NJS /NC /NS 2>&1 | Out-Null
        Remove-Item -LiteralPath $Path -Recurse -Force -EA Stop
        return $true
    } catch { return $false } finally {
        Remove-Item -LiteralPath $emptyDir -Recurse -Force -EA SilentlyContinue
    }
}

function Remove-FolderContents {
    param([string]$Path, [int]$MinAgeMins = 0)
    if (-not (Test-Path $Path)) { return }
    $cutoff = (Get-Date).AddMinutes(-$MinAgeMins)
    foreach ($item in (Get-ChildItem -Path $Path -Force -EA SilentlyContinue)) {
        if ($MinAgeMins -gt 0 -and $item.LastWriteTime -gt $cutoff) { continue }
        try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -EA Stop } catch {}
    }
}

# =============================================================================
# PHASE 1 -- TEMP PROFILE DETECTION / CLEANUP
# =============================================================================

function Get-TempProfileStats {
    $orphans = @()
    $profileMap = Get-ProfileListMap
    $pathToSID  = @{}
    foreach ($sid in $profileMap.Keys) {
        $p = $profileMap[$sid]
        if ($p) { $pathToSID[$p.ToLower()] = $sid }
    }
    $folders = Get-ChildItem -Path $ProfilesBase -Directory -Force -EA SilentlyContinue
    foreach ($folder in @($folders)) {
        if (Test-IsSpecial -N $folder.Name) { continue }
        $hasReg = $pathToSID.ContainsKey($folder.FullName.ToLower())
        if ($hasReg) {
            $sid = $pathToSID[$folder.FullName.ToLower()]
            if (Test-ProfileLoaded -SID $sid) { continue }
            continue  # registered + not active = healthy
        }
        if (Test-IsTempPattern -N $folder.Name) {
            $sizeBytes = Get-FolderSize -Path $folder.FullName
            $orphans += @{ Name = $folder.Name; Path = $folder.FullName; SizeBytes = $sizeBytes }
        }
    }
    return $orphans
}

function Invoke-Phase1TempProfiles {
    Write-Sep
    Write-Log 'PHASE 1: Temp Profile Cleanup'
    $orphans = Get-TempProfileStats
    $totalBytes = 0L
    foreach ($o in $orphans) { $totalBytes += $o.SizeBytes }
    Write-Log "  Found: $($orphans.Count) orphaned temp folder(s) | $(Format-Bytes -Bytes $totalBytes)"

    if (-not $CleanMode) {
        foreach ($o in ($orphans | Sort-Object SizeBytes -Descending)) {
            Write-Log ("  {0,-45} {1}" -f $o.Name, (Format-Bytes -Bytes $o.SizeBytes))
        }
        return @{ Found = $orphans.Count; Bytes = $totalBytes; Deleted = 0; Failed = 0; ReclaimedBytes = 0L }
    }

    $deleted = 0; $failed = 0; $reclaimed = 0L
    foreach ($o in $orphans) {
        Write-Log "  Removing: $($o.Path) ($(Format-Bytes -Bytes $o.SizeBytes))"
        if (Remove-FolderSafe -Path $o.Path) {
            $deleted++; $reclaimed += $o.SizeBytes
            Write-Log "  [DELETED] $($o.Name)"
        } else {
            $failed++
            Write-Log "  [FAILED] $($o.Name)" 'WARN'
        }
    }
    Write-Log "  Phase 1 result: $deleted deleted, $failed failed | Reclaimed: $(Format-Bytes -Bytes $reclaimed)"
    return @{ Found = $orphans.Count; Bytes = $totalBytes; Deleted = $deleted; Failed = $failed; ReclaimedBytes = $reclaimed }
}

# =============================================================================
# PHASE 2 -- INACTIVE PROFILE REMOVAL
# =============================================================================

function Get-InactiveProfileStats {
    $threshold = (Get-Date).AddDays(-$InactiveDays)
    $inactive  = @()
    try {
        $wmiProfiles = Get-WmiObject -Class Win32_UserProfile -EA SilentlyContinue |
            Where-Object { $_.Special -eq $false }
        foreach ($profile in @($wmiProfiles)) {
            if ($profile.Loaded) { continue }
            $username = Split-Path $profile.LocalPath -Leaf
            if (Test-IsBuiltinProfile -N $username) { continue }
            if (Test-IsSvcAccount -N $username) { continue }
            if (-not (Test-Path $profile.LocalPath)) { continue }
            $lastUse = $null
            try {
                if ($profile.LastUseTime) { $lastUse = $profile.ConvertToDateTime($profile.LastUseTime) }
            } catch {}
            if ($null -ne $lastUse -and $lastUse -gt $threshold) { continue }
            $sizeBytes = Get-FolderSize -Path $profile.LocalPath
            $daysOld   = if ($null -ne $lastUse) { [int]((Get-Date) - $lastUse).TotalDays } else { 999 }
            $inactive += @{
                Username   = $username
                LocalPath  = $profile.LocalPath
                LastUse    = if ($null -ne $lastUse) { $lastUse.ToString('yyyy-MM-dd') } else { 'Unknown' }
                DaysOld    = $daysOld
                SizeBytes  = $sizeBytes
                WmiProfile = $profile
            }
        }
    } catch { Write-Log "WARN: Profile enum failed: $($_.Exception.Message)" }
    return $inactive
}

function Invoke-Phase2InactiveProfiles {
    Write-Sep
    Write-Log "PHASE 2: Inactive Profile Removal (>${InactiveDays} days)"
    $inactive   = Get-InactiveProfileStats
    $totalBytes = 0L
    foreach ($p in $inactive) { $totalBytes += $p.SizeBytes }
    Write-Log "  Found: $($inactive.Count) inactive profile(s) | $(Format-Bytes -Bytes $totalBytes)"

    if (-not $CleanMode) {
        foreach ($p in ($inactive | Sort-Object SizeBytes -Descending)) {
            Write-Log ("  {0,-25} Last:{1,-12} Days:{2,-6} {3}" -f $p.Username, $p.LastUse, $p.DaysOld, (Format-Bytes -Bytes $p.SizeBytes))
        }
        return @{ Found = $inactive.Count; Bytes = $totalBytes; Deleted = 0; Failed = 0; ReclaimedBytes = 0L }
    }

    $deleted = 0; $failed = 0; $reclaimed = 0L
    foreach ($p in $inactive) {
        Write-Log "  Removing: $($p.Username) | Last: $($p.LastUse) | $(Format-Bytes -Bytes $p.SizeBytes)"
        try {
            $p.WmiProfile.Delete() | Out-Null
            if (-not (Test-Path $p.LocalPath)) {
                $deleted++; $reclaimed += $p.SizeBytes
                Write-Log "  [DELETED] $($p.Username)"
            } else {
                if (Remove-FolderSafe -Path $p.LocalPath) {
                    $deleted++; $reclaimed += $p.SizeBytes
                    Write-Log "  [DELETED] $($p.Username) (folder fallback)"
                } else { $failed++; Write-Log "  [FAILED] $($p.Username)" 'WARN' }
            }
        } catch {
            $failed++
            Write-Log "  [FAILED] $($p.Username): $($_.Exception.Message)" 'WARN'
        }
    }
    Write-Log "  Phase 2 result: $deleted deleted, $failed failed | Reclaimed: $(Format-Bytes -Bytes $reclaimed)"
    return @{ Found = $inactive.Count; Bytes = $totalBytes; Deleted = $deleted; Failed = $failed; ReclaimedBytes = $reclaimed }
}

# =============================================================================
# PHASE 3 -- PPM ADVANCED (OPTIMIZATION + JUNK CLEANUP)
# =============================================================================

function Get-JunkSizeEstimate {
    $paths = @(
        "$env:SystemRoot\Temp",
        "$env:SystemRoot\SoftwareDistribution\Download",
        "$env:SystemRoot\Logs\CBS",
        "$env:SystemRoot\Logs\DISM",
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
        "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
    )
    $total = 0L
    foreach ($p in $paths) { if (Test-Path $p) { $total += Get-FolderSize -Path $p } }

    # Per-user temp
    try {
        $profKeys = Get-ItemProperty "$ProfileList\*" -EA SilentlyContinue |
            Where-Object { $_.PSChildName -match 'S-1-5-21-(\d+-?){4}$' }
        foreach ($prof in $profKeys) {
            $pp = $prof.ProfileImagePath
            if ($pp -and (Test-Path $pp)) { $total += Get-FolderSize -Path "$pp\AppData\Local\Temp" }
        }
    } catch {}
    return $total
}

function Invoke-Phase3PPMAdvanced {
    Write-Sep
    Write-Log 'PHASE 3: PPM Advanced Optimization + Junk Cleanup'

    $isServer = $false; $isLaptop = $false; $isAMD = $false; $isIntel = $false
    $logCount = 4; $ramMB = 4096; $totalRAMGB = 4
    $build    = [System.Environment]::OSVersion.Version.Build
    $isWin11  = $build -ge 22000

    try {
        $os       = Get-WmiObject Win32_OperatingSystem -EA Stop
        $isServer = ($os.ProductType -eq 2 -or $os.ProductType -eq 3)
        $cpu      = Get-WmiObject Win32_Processor -EA SilentlyContinue | Select-Object -First 1
        $cpuName  = [string]$cpu.Name; $isAMD = $cpuName -match 'AMD'; $isIntel = $cpuName -match 'Intel'
        $cs       = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
        $logCount = if ($null -ne $cs.NumberOfLogicalProcessors) { $cs.NumberOfLogicalProcessors } else { 4 }
        $ramBytes = $cs.TotalPhysicalMemory
        $ramMB      = if ($null -ne $ramBytes) { [math]::Round($ramBytes / 1MB, 0) } else { 4096 }
        $totalRAMGB = if ($null -ne $ramBytes) { [math]::Round($ramBytes / 1GB, 0) } else { 4 }
    } catch {}
    try { $battery = Get-WmiObject Win32_Battery -EA SilentlyContinue; $isLaptop = ($null -ne $battery -and @($battery).Count -gt 0) } catch {}

    $hasPowercfg    = $null -ne (Get-Command powercfg.exe -EA SilentlyContinue)
    $hasFsutil      = $null -ne (Get-Command fsutil.exe   -EA SilentlyContinue)
    $hasSecedit     = $null -ne (Get-Command secedit.exe  -EA SilentlyContinue)
    $hasNetAdapterRss = $false
    try { Get-NetAdapterRss -EA Stop | Out-Null; $hasNetAdapterRss = $true } catch {}
    if (-not $hasNetAdapterRss) { try { Import-Module NetAdapter -EA SilentlyContinue; Get-NetAdapterRss -EA Stop | Out-Null; $hasNetAdapterRss = $true } catch {} }
    $hasOptimizeVol = $false
    try { Get-Command Optimize-Volume -EA Stop | Out-Null; $hasOptimizeVol = $true } catch {}
    if (-not $hasOptimizeVol) { try { Import-Module Storage -EA SilentlyContinue; Get-Command Optimize-Volume -EA Stop | Out-Null; $hasOptimizeVol = $true } catch {} }

    Write-Log "  Hardware: AMD:$isAMD Intel:$isIntel Cores:$logCount RAM:${totalRAMGB}GB Build:$build Server:$isServer Laptop:$isLaptop"

    # Check if PPM already applied -- skip optimization if backup key exists, run cleanup only
    $ppmAlreadyApplied = Test-Path $PPMBackupRoot
    if ($ppmAlreadyApplied) {
        Write-Log '  PPM backup key found -- optimization already applied. Running junk cleanup only.'
    }

    $ok = 0; $warn = 0; $err = 0

    if (-not $ppmAlreadyApplied -and $CleanMode) {
        # --- Optimization tweaks (only if not already applied) ---
        $BackupRoot = $PPMBackupRoot
        function Ensure-BackupRoot { if (-not (Test-Path $BackupRoot)) { New-Item -Path $BackupRoot -Force -EA SilentlyContinue | Out-Null } }
        function Backup-RegValue2 { param([string]$Path,[string]$Name); try { Ensure-BackupRoot; $sk=($Path+'_'+$Name)-replace'[\\:/]','_'; $e=Get-ItemProperty -Path $Path -Name $Name -EA SilentlyContinue; $bv=if($null -ne $e){$e.$Name}else{'__NOTEXIST__'}; New-ItemProperty -Path $BackupRoot -Name $sk -Value $bv -Force -EA SilentlyContinue|Out-Null } catch {} }
        function Set-RegDWord2 { param([string]$Path,[string]$Name,[int]$Value); if(-not(Test-Path $Path)){New-Item -Path $Path -Force -EA SilentlyContinue|Out-Null}; New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force -EA SilentlyContinue|Out-Null }
        function Set-RegString2 { param([string]$Path,[string]$Name,[string]$Value); if(-not(Test-Path $Path)){New-Item -Path $Path -Force -EA SilentlyContinue|Out-Null}; New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force -EA SilentlyContinue|Out-Null }

        # Power plan
        try {
            if ($hasPowercfg) {
                $upGuid='e9a42b02-d5df-448d-aa00-03f14749eb61';$hpGuid='8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
                $allPlans=[string](& powercfg /list 2>&1)
                $cur=[string](& powercfg /getactivescheme 2>&1|Select-Object -First 1)
                if($cur -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'){Ensure-BackupRoot;New-ItemProperty -Path $BackupRoot -Name 'PowerPlan_Active' -Value $Matches[1] -Force -EA SilentlyContinue|Out-Null}
                if($isLaptop){& powercfg /setactive '381b4222-f694-41f0-9685-ff5bb260df2e' 2>&1|Out-Null}
                else{$tg=if($allPlans -match [regex]::Escape($upGuid)){$upGuid}elseif($allPlans -match [regex]::Escape($hpGuid)){$hpGuid}else{$null};if($null -ne $tg){& powercfg /setactive $tg 2>&1|Out-Null}}
                Write-Log '  [01] Power Plan: applied';$ok++
            } else { Write-Log '  [01] Power Plan: skipped (no powercfg)';$warn++ }
        } catch { Write-Log "  [01] Power Plan ERROR: $($_.Exception.Message)";$err++ }

        # Win32PrioritySeparation
        try { $p='HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl';Backup-RegValue2 -Path $p -Name 'Win32PrioritySeparation';Set-RegDWord2 -Path $p -Name 'Win32PrioritySeparation' -Value 38;Write-Log '  [02] PrioritySep: =38';$ok++ } catch { Write-Log "  [02] PrioritySep ERROR: $($_.Exception.Message)";$err++ }

        # Visual Effects
        try { $p='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects';Backup-RegValue2 -Path $p -Name 'VisualFXSetting';Set-RegDWord2 -Path $p -Name 'VisualFXSetting' -Value 2;Write-Log '  [03] VisualFX: =2';$ok++ } catch { Write-Log "  [03] VisualFX ERROR";$err++ }

        # MMCSS
        try { $mm='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile';Backup-RegValue2 -Path $mm -Name 'NetworkThrottlingIndex';Backup-RegValue2 -Path $mm -Name 'SystemResponsiveness';New-ItemProperty -Path $mm -Name 'NetworkThrottlingIndex' -Value 0xFFFFFFFF -PropertyType DWord -Force -EA SilentlyContinue|Out-Null;Set-RegDWord2 -Path $mm -Name 'SystemResponsiveness' -Value 16;Write-Log '  [04] MMCSS: applied';$ok++ } catch { Write-Log "  [04] MMCSS ERROR";$err++ }

        # NTFS
        try { if($hasFsutil){& fsutil behavior set disable8dot3 1 2>&1|Out-Null;& fsutil behavior set disablelastaccess 1 2>&1|Out-Null};Set-RegDWord2 -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'DisablePagingExecutive' -Value 1;Write-Log '  [05] NTFS: applied';$ok++ } catch { Write-Log "  [05] NTFS ERROR";$err++ }

        # Nagle
        try { $ifBase='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces';$nc=0;foreach($iface in (Get-ChildItem -Path $ifBase -EA SilentlyContinue)){$ifp=$iface.PSPath;$d=Get-ItemProperty -Path $ifp -Name 'DhcpIPAddress' -EA SilentlyContinue;$s=Get-ItemProperty -Path $ifp -Name 'IPAddress' -EA SilentlyContinue;if(-not(($null -ne $d -and $d.DhcpIPAddress -ne '0.0.0.0')-or($null -ne $s -and $s.IPAddress -ne '0.0.0.0' -and $s.IPAddress -ne ''))){continue};Set-RegDWord2 -Path $ifp -Name 'TcpAckFrequency' -Value 1;Set-RegDWord2 -Path $ifp -Name 'TCPNoDelay' -Value 1;$nc++};Write-Log "  [06] Nagle: $nc NIC(s)";$ok++ } catch { Write-Log "  [06] Nagle ERROR";$err++ }

        # Core Parking
        try { if($hasPowercfg){& powercfg -setacvalueindex SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 100 2>&1|Out-Null;& powercfg -setactive SCHEME_CURRENT 2>&1|Out-Null;Write-Log '  [07] Core Parking: unparked';$ok++}else{Write-Log '  [07] Core Parking: skipped';$warn++} } catch { Write-Log "  [07] CoreParking ERROR";$err++ }

        # Pagefile
        try { $pfMB=[math]::Min($ramMB,8192);Set-RegString2 -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name 'PagingFiles' -Value "C:\pagefile.sys $pfMB $pfMB";Write-Log "  [08] Pagefile: fixed ${pfMB}MB";$ok++ } catch { Write-Log "  [08] Pagefile ERROR";$err++ }

        # Hibernate
        try { if(-not $isServer -and -not $isLaptop -and $hasPowercfg){& powercfg /h off 2>&1|Out-Null;Write-Log '  [09] Hibernate: disabled (frees hiberfil.sys)';$ok++}else{Write-Log '  [09] Hibernate: skipped (server/laptop)';$warn++} } catch { Write-Log "  [09] Hibernate ERROR";$err++ }

        # C-State
        try { if($hasPowercfg){& powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR IdleDemoteThreshold 0 2>&1|Out-Null;& powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR IdlePromoteThreshold 0 2>&1|Out-Null;& powercfg -setactive SCHEME_CURRENT 2>&1|Out-Null;Write-Log '  [10] C-State: capped at C1';$ok++}else{$warn++} } catch { Write-Log "  [10] C-State ERROR";$err++ }

        # HAGS
        try { Set-RegDWord2 -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 2;Write-Log '  [12] HAGS: enabled';$ok++ } catch { Write-Log "  [12] HAGS ERROR";$err++ }

        Write-Log "  Optimization tweaks: ok=$ok warn=$warn err=$err"
    }

    # --- Junk cleanup (always runs) ---
    if ($CleanMode) {
        Write-Log '  Running junk cleanup...'
        try {
            Remove-FolderContents -Path "$env:SystemRoot\Temp" -MinAgeMins 60
            Remove-FolderContents -Path "$env:SystemRoot\SoftwareDistribution\Download"
            Remove-FolderContents -Path "$env:SystemRoot\Logs\CBS"
            Remove-FolderContents -Path "$env:SystemRoot\Logs\DISM"
            Remove-FolderContents -Path "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"
            Remove-FolderContents -Path "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
            $doPath = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
            Remove-FolderContents -Path $doPath
            try { $doCmd=Get-Command 'Delete-DeliveryOptimizationCache' -EA SilentlyContinue;if($doCmd){Delete-DeliveryOptimizationCache -Force -EA SilentlyContinue|Out-Null} } catch {}

            $profKeys = Get-ItemProperty "$ProfileList\*" -EA SilentlyContinue |
                Where-Object { $_.PSChildName -match 'S-1-5-21-(\d+-?){4}$' }
            foreach ($prof in $profKeys) {
                $pp = $prof.ProfileImagePath
                if ([string]::IsNullOrEmpty($pp) -or -not (Test-Path $pp)) { continue }
                Remove-FolderContents -Path "$pp\AppData\Local\Temp" -MinAgeMins 60
                $tp = "$pp\AppData\Local\Microsoft\Windows\Explorer"
                if (Test-Path $tp) {
                    Get-ChildItem -Path $tp -Filter 'thumbcache_*.db' -Force -EA SilentlyContinue |
                        ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue } catch {} }
                }
                Remove-FolderContents -Path "$pp\AppData\Local\Microsoft\Windows\WER"
            $teamsAge = if ($isServer) { 120 } else { 0 }
            foreach ($tp2 in @(
                "$pp\AppData\Roaming\Microsoft\Teams\Cache",
                "$pp\AppData\Roaming\Microsoft\Teams\blob_storage",
                "$pp\AppData\Roaming\Microsoft\Teams\GPUCache",
                "$pp\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs",
                "$pp\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\tmp"
            )) { Remove-FolderContents -Path $tp2 -MinAgeMins $teamsAge }
            }

            try {
                $rc = Get-Command 'Clear-RecycleBin' -EA SilentlyContinue
                if ($rc) { Clear-RecycleBin -Force -EA SilentlyContinue }
                else { $shell=New-Object -ComObject Shell.Application;$shell.Namespace(0xA).Items()|ForEach-Object{$_.InvokeVerb('delete')} }
            } catch {}

            Write-Log '  Junk cleanup complete'
        } catch { Write-Log "  WARN: Junk cleanup partial: $($_.Exception.Message)" }

        # SSD TRIM
        try {
            $vols = Get-WmiObject Win32_Volume -EA SilentlyContinue |
                Where-Object { $_.DriveType -eq 3 -and $null -ne $_.DriveLetter }
            $trimCount = 0
            foreach ($v in $vols) {
                $drove = $v.DriveLetter.TrimEnd('\')[0]
                if ($hasOptimizeVol) {
                    try { Optimize-Volume -DriveLetter $drove -ReTrim -EA SilentlyContinue; $trimCount++ } catch {}
                } else {
                    $def = Get-Command defrag.exe -EA SilentlyContinue
                    if ($null -ne $def) { & defrag.exe "${drove}:" /X /U 2>&1|Out-Null; $trimCount++ }
                }
            }
            Write-Log "  SSD TRIM: $trimCount volume(s)"
        } catch {}
    }

    return @{ OptOK = $ok; OptWarn = $warn; OptErr = $err; AlreadyApplied = $ppmAlreadyApplied }
}

# =============================================================================
# PHASE 4 -- SFC + DISM
# =============================================================================

function Invoke-Phase4SystemRepair {
    Write-Sep
    Write-Log 'PHASE 4: System File Integrity (SFC + DISM)'

    if (-not $CleanMode) {
        Write-Log '  Report mode: SFC/DISM scan skipped (would run in Clean mode)'
        return @{ SFCRan = $false; DISMRan = $false; Errors = 0 }
    }

    $sfcRan = $false; $dismRan = $false; $errors = 0

    # DISM first -- restores component store so SFC has a clean source
    Write-Log '  Running DISM /RestoreHealth...'
    try {
        $dismOut = & dism.exe /Online /Cleanup-Image /RestoreHealth 2>&1
        $dismRan = $true
        $lastLine = ($dismOut | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
        Write-Log "  DISM result: $lastLine"
    } catch { Write-Log "  WARN: DISM failed: $($_.Exception.Message)"; $errors++ }

    # SFC
    Write-Log '  Running SFC /scannow...'
    try {
        $sfcOut = & sfc.exe /scannow 2>&1
        $sfcRan = $true
        $lastLine = ($sfcOut | Where-Object { $_ -match '\S' } | Select-Object -Last 3) -join ' '
        Write-Log "  SFC result: $lastLine"
    } catch { Write-Log "  WARN: SFC failed: $($_.Exception.Message)"; $errors++ }

    Write-Log "  Phase 4 complete: DISM:$dismRan SFC:$sfcRan Errors:$errors"
    return @{ SFCRan = $sfcRan; DISMRan = $dismRan; Errors = $errors }
}

# =============================================================================
# PHASE 5 -- CHKDSK
# =============================================================================

function Invoke-Phase5CHKDSK {
    Write-Sep
    Write-Log 'PHASE 5: CHKDSK'

    if (-not $CleanMode) {
        Write-Log '  Report mode: CHKDSK schedule skipped'
        return @{ Scheduled = $false }
    }

    if (-not $AllowReboot) {
        Write-Log '  allowReboot=false -- CHKDSK skipped. Set allowReboot=true to enable.'
        return @{ Scheduled = $false }
    }

    try {
        $drive = $env:SystemDrive.TrimEnd(':')
        $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        $current = (Get-ItemProperty -Path $regPath -Name 'BootExecute' -EA SilentlyContinue).BootExecute
        $chkEntry = "autocheck autochk /f /r $drive`:"
        if ($current -notcontains $chkEntry) {
            $newVal = @('autocheck autochk *', $chkEntry)
            New-ItemProperty -Path $regPath -Name 'BootExecute' -Value $newVal `
                -PropertyType MultiString -Force -EA Stop | Out-Null
        }
        Write-Log "  CHKDSK scheduled on $drive`: for next reboot"
        return @{ Scheduled = $true }
    } catch {
        Write-Log "  WARN: CHKDSK schedule failed: $($_.Exception.Message)"
        return @{ Scheduled = $false }
    }
}


# =============================================================================
# PHASE 6 -- VSS CLEANUP + WER CRASH DUMPS
# =============================================================================

function Get-VSSUsageGB {
    try {
        $out = & vssadmin.exe list shadowstorage 2>&1
        $line = $out | Where-Object { $_ -match 'Used Shadow Copy Storage space' } | Select-Object -First 1
        if ($line -match '([\d\.]+)\s*(GB|MB|TB)') {
            $val  = [double]$Matches[1]
            $unit = $Matches[2]
            if ($unit -eq 'MB') { return [math]::Round($val / 1024, 2) }
            if ($unit -eq 'TB') { return [math]::Round($val * 1024, 2) }
            return [math]::Round($val, 2)
        }
    } catch {}
    return 0
}

function Get-WERDumpSize {
    $paths = @(
        "$env:ProgramData\Microsoft\Windows\WER\LocalDumps",
        "$env:SystemRoot\Minidump"
    )
    $profKeys = Get-ItemProperty "$ProfileList\*" -EA SilentlyContinue |
        Where-Object { $_.PSChildName -match 'S-1-5-21-(\d+-?){4}$' }
    foreach ($prof in $profKeys) {
        $pp = $prof.ProfileImagePath
        if ($pp -and (Test-Path $pp)) { $paths += "$pp\AppData\Local\CrashDumps" }
    }
    $total = 0L
    foreach ($p in $paths) { if (Test-Path $p) { $total += Get-FolderSize -Path $p } }
    return $total
}

function Invoke-Phase6VSSAndDumps {
    Write-Sep
    Write-Log 'PHASE 6: VSS Shadow Copy Cleanup + WER Crash Dumps'

    $vssBefore  = Get-VSSUsageGB
    $dumpBytes  = Get-WERDumpSize
    Write-Log "  VSS storage currently used: ${vssBefore}GB"
    Write-Log "  WER/crash dumps: $(Format-Bytes -Bytes $dumpBytes)"

    if (-not $CleanMode) {
        Write-Log '  Report mode: no changes made'
        return @{ VSSBefore = $vssBefore; VSSAfter = $vssBefore; DumpBytes = $dumpBytes; DumpCleared = $false; Errors = 0 }
    }

    $errors = 0

    # VSS -- delete all but most recent restore point
    Write-Log '  Deleting old VSS shadow copies (keeping most recent)...'
    try {
        # Count existing shadows first
        $shadowOut = & vssadmin.exe list shadows /for=C: 2>&1
        $shadowCount = ($shadowOut | Where-Object { $_ -match 'Shadow Copy ID' }).Count
        Write-Log "  Found $shadowCount shadow copy(s)"

        if ($shadowCount -gt 1) {
            # Delete all but newest -- use /oldest repeatedly or /all then recreate
            # Safest: delete oldest shadows one by one, stop when 1 remains
            $deleted = 0
            while ($true) {
                $check = & vssadmin.exe list shadows /for=C: 2>&1
                $count = ($check | Where-Object { $_ -match 'Shadow Copy ID' }).Count
                if ($count -le 1) { break }
                & vssadmin.exe delete shadows /for=C: /oldest /quiet 2>&1 | Out-Null
                $deleted++
                if ($deleted -gt 50) { break }  # safety cap
            }
            Write-Log "  Deleted $deleted old shadow copy(s), kept most recent"
        } elseif ($shadowCount -eq 1) {
            Write-Log '  Only 1 shadow copy present -- keeping it'
        } else {
            Write-Log '  No shadow copies found'
        }

        # Cap VSS storage to 10% of drive going forward
        $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -EA SilentlyContinue
        if ($null -ne $disk) {
            $capGB = [math]::Round($disk.Size / 1GB * 0.10, 0)
            $capGB = [math]::Max($capGB, 2)  # minimum 2GB cap
            & vssadmin.exe resize shadowstorage /for=C: /on=C: /maxsize="${capGB}GB" 2>&1 | Out-Null
            Write-Log "  VSS storage capped at ${capGB}GB (10% of drive)"
        }
    } catch {
        Write-Log "  WARN: VSS cleanup failed: $($_.Exception.Message)" 'WARN'
        $errors++
    }

    $vssAfter = Get-VSSUsageGB
    Write-Log "  VSS storage after: ${vssAfter}GB (was ${vssBefore}GB)"

    # WER crash dumps -- safe to clear entirely
    Write-Log '  Clearing WER crash dumps...'
    $dumpPaths = @(
        "$env:ProgramData\Microsoft\Windows\WER\LocalDumps",
        "$env:SystemRoot\Minidump"
    )
    try {
        $profKeys = Get-ItemProperty "$ProfileList\*" -EA SilentlyContinue |
            Where-Object { $_.PSChildName -match 'S-1-5-21-(\d+-?){4}$' }
        foreach ($prof in $profKeys) {
            $pp = $prof.ProfileImagePath
            if ($pp -and (Test-Path $pp)) { $dumpPaths += "$pp\AppData\Local\CrashDumps" }
        }
    } catch {}

    $dumpCleared = $false
    foreach ($dp in $dumpPaths) {
        if (Test-Path $dp) {
            Remove-FolderContents -Path $dp
            Write-Log "  Cleared: $dp"
            $dumpCleared = $true
        }
    }

    Write-Log "  Phase 6 complete: VSS ${vssBefore}GB -> ${vssAfter}GB | Dumps cleared: $dumpCleared"
    return @{ VSSBefore = $vssBefore; VSSAfter = $vssAfter; DumpBytes = $dumpBytes; DumpCleared = $dumpCleared; Errors = $errors }
}

# =============================================================================
# MAIN
# =============================================================================

if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

$siteName = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }

$freeBefore = Get-DriveFreeGB

Write-Sep
Write-Log "Paladin Storage Clean & Optimize v$ScriptVer | Site: $siteName | Machine: $env:COMPUTERNAME"
Write-Log "Mode: $Action | InactiveDays: $InactiveDays | AllowReboot: $AllowReboot | MinFreeGB: $MinFreeGB"
Write-Log "Disk free at start: ${freeBefore}GB"
Write-Sep

# Report estimates (both modes)
Write-Log 'Pre-scan: estimating cleanup potential...'
$tempOrphans  = Get-TempProfileStats
$inactiveProfs= Get-InactiveProfileStats
$junkEstimate = Get-JunkSizeEstimate
$vssEstimate  = Get-VSSUsageGB
$dumpEstimate = Get-WERDumpSize

$tempBytes    = 0L; foreach ($o in $tempOrphans)   { $tempBytes   += $o.SizeBytes }
$inactBytes   = 0L; foreach ($p in $inactiveProfs) { $inactBytes  += $p.SizeBytes }

Write-Sep2
Write-Log 'ESTIMATED RECLAIM:'
Write-Log ("  Phase 1 -- Temp profile folders : {0,10} ({1} folder(s))" -f (Format-Bytes -Bytes $tempBytes), $tempOrphans.Count)
Write-Log ("  Phase 2 -- Inactive profiles    : {0,10} ({1} profile(s) >$InactiveDays days)" -f (Format-Bytes -Bytes $inactBytes), $inactiveProfs.Count)
Write-Log ("  Phase 3 -- Junk files (estimate): {0,10}" -f (Format-Bytes -Bytes $junkEstimate))
Write-Log ("  Phase 6 -- VSS shadow copies    : {0,10} GB currently used" -f $vssEstimate)
Write-Log ("  Phase 6 -- WER/crash dumps      : {0,10}" -f (Format-Bytes -Bytes $dumpEstimate))
$totalEstimate = $tempBytes + $inactBytes + $junkEstimate + [long]($vssEstimate * 1GB) + $dumpEstimate
Write-Log ("  TOTAL ESTIMATED RECLAIM         : {0,10}" -f (Format-Bytes -Bytes $totalEstimate))
Write-Sep2

if (-not $CleanMode) {
    Write-Log 'MODE: Report only -- no changes made.'
    Write-Log 'Re-run with action=Clean to execute all phases.'
    if ($inactiveProfs.Count -gt 0) {
        Write-Sep2
        Write-Log 'INACTIVE PROFILES DETAIL:'
        foreach ($p in ($inactiveProfs | Sort-Object SizeBytes -Descending)) {
            Write-Log ("  {0,-25} Last:{1,-12} Days:{2,-6} {3}" -f $p.Username, $p.LastUse, $p.DaysOld, (Format-Bytes -Bytes $p.SizeBytes))
        }
    }
    if ($tempOrphans.Count -gt 0) {
        Write-Sep2
        Write-Log 'ORPHANED TEMP FOLDERS DETAIL:'
        foreach ($o in ($tempOrphans | Sort-Object SizeBytes -Descending)) {
            Write-Log ("  {0,-45} {1}" -f $o.Name, (Format-Bytes -Bytes $o.SizeBytes))
        }
    }
    $udfMsg = "REPORT $(Get-Date -Format 'yyyy-MM-dd') | Est:$(Format-Bytes -Bytes $totalEstimate) | TempFolders:$($tempOrphans.Count) Inactive:$($inactiveProfs.Count) | Disk:${freeBefore}GB free"
    Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg
    Write-Sep
    exit 0
}

# Clean mode -- run all phases
Write-Log 'MODE: Clean -- executing all phases'

$totalErrors   = 0
$totalReclaimed = 0L

# Phase 1
$p1 = Invoke-Phase1TempProfiles
$totalReclaimed += $p1.ReclaimedBytes
if ($p1.Failed -gt 0) { $totalErrors++ }
$freeAfterP1 = Get-DriveFreeGB
Write-Log "Disk after Phase 1: ${freeAfterP1}GB free"

# Phase 2
$p2 = Invoke-Phase2InactiveProfiles
$totalReclaimed += $p2.ReclaimedBytes
if ($p2.Failed -gt 0) { $totalErrors++ }
$freeAfterP2 = Get-DriveFreeGB
Write-Log "Disk after Phase 2: ${freeAfterP2}GB free"

# Phase 3 -- disk gate
if (Test-DiskGate -PhaseName 'Phase 3 PPM') {
    $p3 = Invoke-Phase3PPMAdvanced
    if ($p3.OptErr -gt 0) { $totalErrors++ }
} else {
    $p3 = @{ OptOK = 0; OptWarn = 0; OptErr = 0; AlreadyApplied = $false }
}
$freeAfterP3 = Get-DriveFreeGB
Write-Log "Disk after Phase 3: ${freeAfterP3}GB free"

# Phase 4 -- disk gate
if (Test-DiskGate -PhaseName 'Phase 4 SFC/DISM') {
    $p4 = Invoke-Phase4SystemRepair
    if ($p4.Errors -gt 0) { $totalErrors++ }
} else {
    $p4 = @{ SFCRan = $false; DISMRan = $false; Errors = 0 }
}

# Phase 5
$p5 = Invoke-Phase5CHKDSK

# Phase 6 -- VSS + WER dumps
$p6 = Invoke-Phase6VSSAndDumps
if ($p6.Errors -gt 0) { $totalErrors++ }

# Final summary
$freeAfter = Get-DriveFreeGB
$actualReclaim = [math]::Round($freeAfter - $freeBefore, 2)

Write-Sep
Write-Log 'FINAL SUMMARY:'
Write-Log "  Phase 1 -- Temp folders  : $($p1.Deleted) deleted, $($p1.Failed) failed | $(Format-Bytes -Bytes $p1.ReclaimedBytes) reclaimed"
Write-Log "  Phase 2 -- Profiles      : $($p2.Deleted) deleted, $($p2.Failed) failed | $(Format-Bytes -Bytes $p2.ReclaimedBytes) reclaimed"
Write-Log "  Phase 3 -- PPM/Junk      : ok=$($p3.OptOK) warn=$($p3.OptWarn) err=$($p3.OptErr)"
Write-Log "  Phase 4 -- SFC/DISM      : DISM:$($p4.DISMRan) SFC:$($p4.SFCRan)"
Write-Log "  Phase 5 -- CHKDSK        : Scheduled:$($p5.Scheduled)"
Write-Log "  Phase 6 -- VSS/Dumps     : VSS $($p6.VSSBefore)GB->$($p6.VSSAfter)GB | Dumps:$($p6.DumpCleared)"
Write-Log "  Disk before              : ${freeBefore}GB free"
Write-Log "  Disk after               : ${freeAfter}GB free"
Write-Log "  Net reclaimed            : ${actualReclaim}GB"
Write-Log "  Total errors             : $totalErrors"
Write-Sep

$chkNote  = if ($p5.Scheduled) { ' CHKDSK:PENDING-REBOOT' } else { '' }
$udfMsg   = "CLEAN $(Get-Date -Format 'yyyy-MM-dd') | Before:${freeBefore}GB After:${freeAfter}GB Reclaimed:${actualReclaim}GB | TempDel:$($p1.Deleted) ProfDel:$($p2.Deleted) Err:$totalErrors$chkNote"
Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg

if ($totalErrors -gt 0) { exit 1 }
exit 0
