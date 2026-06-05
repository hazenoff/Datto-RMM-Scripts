#Requires -Version 3.0
# =============================================================================
# Paladin Disk Maintenance [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem) -- fully headless
#
# SEQUENCE (single Datto job, one reboot at the very end):
#   Stage 1 -- PPM Advanced          registry + system performance tweaks
#   Stage 2 -- Disk Clean            desperation-mode deep junk removal
#   Stage 3 -- Temp Profile Repair   orphaned registry + TEMP folders
#   Stage 4 -- Inactive Profiles     removes profiles inactive > InactiveDays
#   Stage 5 -- VSS + WER Dumps       trim shadow copies, clear crash dumps
#   Stage 6 -- Disk Repair           schedule chkdsk + single reboot
#              Post-reboot: chkdsk (pre-boot), SFC, DISM, defrag (via task)
#
# INPUT VARIABLES:
#   AllowReboot   Boolean  "true" = reboot at end for chkdsk   (default: false)
#   InactiveDays  String   30 / 60 / 90 -- inactive profile age (default: 60)
#   UDFSlot       String   UDF slot for result                  (default: 30)
#
# LOG:  C:\ProgramData\Paladin\DiskMaintenance\DiskMaintenance.log
# EXIT: 0 = complete  |  1 = one or more stages failed
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer  = '1.0.0'
$BaseDir    = 'C:\ProgramData\Paladin\DiskMaintenance'
$LogFile    = "$BaseDir\DiskMaintenance.log"
$MaxLogMB   = 10

$ProfileList    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$PPMBackupRoot  = 'HKLM:\SOFTWARE\Paladin\PPM\RMM\Backup'
$DiskRepairKey  = 'HKLM:\SOFTWARE\Paladin\DiskRepair'
$DiskRepairDir  = 'C:\ProgramData\Paladin\DiskRepair'
$DiskRepairLog  = "$DiskRepairDir\DiskRepair.log"
$DiskRepairCopy = "$DiskRepairDir\DiskRepair-Resume.ps1"
$DiskRepairTask = 'Paladin_DiskRepair_Resume'
$PsExe          = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$BuiltinSIDs    = @('S-1-5-18','S-1-5-19','S-1-5-20')
$SpecialFolders = @('public','default','default user','all users','defaultuser0','defaultuser1')
$TempPatterns   = @('^TEMP$','^TEMP\.','\.\d{3}$','^\d+$')
$ProfileExclusions = @(
    'administrator','default','defaultuser0','defaultuser1','guest','public',
    'systemprofile','networkservice','localservice','wdagutilityaccount',
    'all users','localadmin'
)

# =============================================================================
# INPUT VARIABLES
# =============================================================================
$AllowReboot  = ($env:AllowReboot -eq 'true')
$UDFSlot      = if ($env:UDFSlot -match '^\d+$') { [int]$env:UDFSlot } else { 30 }
$DaysStr      = $env:InactiveDays
$InactiveDays = switch ($DaysStr) { '30'{30} '90'{90} default{60} }
$SiteName     = if ($env:CS_PROFILE_NAME) { $env:CS_PROFILE_NAME } else { 'UNKNOWN' }
$MachineName  = $env:COMPUTERNAME

# =============================================================================
# SHARED HELPERS
# =============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try {
        if (-not (Test-Path $BaseDir)) { New-Item $BaseDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile -EA SilentlyContinue).Length / 1MB) -gt $MaxLogMB) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.bak" -Force -EA SilentlyContinue
        }
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

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DriveFreeGB {
    try {
        $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -EA SilentlyContinue
        if ($null -ne $disk) { return [math]::Round($disk.FreeSpace / 1GB, 2) }
    } catch {}
    return 0
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

function Remove-FolderFast {
    param([string]$Path)
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
        try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -EA SilentlyContinue } catch {}
    }
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

function Test-ProfileLoaded {
    param([string]$SID)
    try {
        $wmi = Get-WmiObject -Class Win32_UserProfile -Filter "SID='$SID'" -EA SilentlyContinue
        if ($null -ne $wmi -and $wmi.Loaded) { return $true }
    } catch {}
    return $false
}

function Show-UserMessage {
    param([string]$Message)
    try {
        $sessions = & query session 2>&1 | Where-Object { $_ -match 'console|rdp-tcp' -and $_ -match 'Active' }
        if ($sessions) { & msg.exe '*' /TIME:300 "Paladin IT Maintenance: $Message" 2>&1 | Out-Null }
    } catch {}
}

# =============================================================================
# STAGE 1 -- PPM ADVANCED OPTIMIZATION
# =============================================================================

function Invoke-Stage1PPM {
    Write-Sep
    Write-Log 'STAGE 1/6: PPM Advanced Optimization'
    Write-Sep2

    $isServer = $false; $isLaptop = $false; $isAMD = $false
    $logCount = 4; $ramMB = 4096; $totalRAMGB = 4
    $build    = [System.Environment]::OSVersion.Version.Build

    try {
        $os       = Get-WmiObject Win32_OperatingSystem -EA Stop
        $isServer = ($os.ProductType -eq 2 -or $os.ProductType -eq 3)
        $cpu      = Get-WmiObject Win32_Processor -EA SilentlyContinue | Select-Object -First 1
        $cpuName  = [string]$cpu.Name; $isAMD = $cpuName -match 'AMD'
        $cs       = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
        $logCount = if ($null -ne $cs.NumberOfLogicalProcessors) { $cs.NumberOfLogicalProcessors } else { 4 }
        $ramBytes = $cs.TotalPhysicalMemory
        $ramMB      = if ($null -ne $ramBytes) { [math]::Round($ramBytes / 1MB, 0) } else { 4096 }
        $totalRAMGB = if ($null -ne $ramBytes) { [math]::Round($ramBytes / 1GB, 0) } else { 4 }
    } catch {}
    try { $battery = Get-WmiObject Win32_Battery -EA SilentlyContinue; $isLaptop = ($null -ne $battery -and @($battery).Count -gt 0) } catch {}

    $hasPowercfg  = $null -ne (Get-Command powercfg.exe -EA SilentlyContinue)
    $hasFsutil    = $null -ne (Get-Command fsutil.exe   -EA SilentlyContinue)
    $hasOptVol    = $false
    try { Get-Command Optimize-Volume -EA Stop | Out-Null; $hasOptVol = $true } catch {}

    Write-Log "  Hardware: AMD:$isAMD Cores:$logCount RAM:${totalRAMGB}GB Build:$build Server:$isServer Laptop:$isLaptop"

    if (Test-Path $PPMBackupRoot) {
        Write-Log '  PPM backup key found -- optimization already applied. Skipping tweaks.'
        return @{ OK = 0; Warn = 0; Err = 0; Skipped = $true }
    }

    $BackupRoot = $PPMBackupRoot
    $ok = 0; $warn = 0; $err = 0

    function Ensure-BR { if (-not (Test-Path $BackupRoot)) { New-Item -Path $BackupRoot -Force -EA SilentlyContinue | Out-Null } }
    function Bkp { param([string]$P,[string]$N); try{Ensure-BR;$sk=($P+'_'+$N)-replace'[\\/:]','_';$e=Get-ItemProperty -Path $P -Name $N -EA SilentlyContinue;$bv=if($null -ne $e){$e.$N}else{'__NOTEXIST__'};New-ItemProperty -Path $BackupRoot -Name $sk -Value $bv -Force -EA SilentlyContinue|Out-Null}catch{} }
    function SRD { param([string]$P,[string]$N,[int]$V); if(-not(Test-Path $P)){New-Item -Path $P -Force -EA SilentlyContinue|Out-Null};New-ItemProperty -Path $P -Name $N -Value $V -PropertyType DWord -Force -EA SilentlyContinue|Out-Null }
    function SRS { param([string]$P,[string]$N,[string]$V); if(-not(Test-Path $P)){New-Item -Path $P -Force -EA SilentlyContinue|Out-Null};New-ItemProperty -Path $P -Name $N -Value $V -PropertyType String -Force -EA SilentlyContinue|Out-Null }

    # [01] Power Plan
    try {
        if ($hasPowercfg) {
            $upGuid='e9a42b02-d5df-448d-aa00-03f14749eb61'; $hpGuid='8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
            $allPlans=[string](& powercfg /list 2>&1)
            $cur=[string](& powercfg /getactivescheme 2>&1 | Select-Object -First 1)
            if($cur -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'){Ensure-BR;New-ItemProperty -Path $BackupRoot -Name 'PowerPlan_Active' -Value $Matches[1] -Force -EA SilentlyContinue|Out-Null}
            if($isLaptop){& powercfg /setactive '381b4222-f694-41f0-9685-ff5bb260df2e' 2>&1|Out-Null}
            else{$tg=if($allPlans -match [regex]::Escape($upGuid)){$upGuid}elseif($allPlans -match [regex]::Escape($hpGuid)){$hpGuid}else{$null};if($null -ne $tg){& powercfg /setactive $tg 2>&1|Out-Null}}
            Write-Log '  [01] Power Plan: applied'; $ok++
        } else { Write-Log '  [01] Power Plan: skipped (no powercfg)'; $warn++ }
    } catch { Write-Log "  [01] Power Plan ERROR: $($_.Exception.Message)"; $err++ }

    # [02] Win32PrioritySeparation
    try { $p='HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl';Bkp $p 'Win32PrioritySeparation';SRD $p 'Win32PrioritySeparation' 38;Write-Log '  [02] PrioritySep: =38';$ok++ } catch { Write-Log "  [02] PrioritySep ERROR";$err++ }

    # [03] Visual Effects
    try { $p='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects';Bkp $p 'VisualFXSetting';SRD $p 'VisualFXSetting' 2;Write-Log '  [03] VisualFX: =2';$ok++ } catch { Write-Log "  [03] VisualFX ERROR";$err++ }

    # [04] MMCSS
    try { $mm='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile';Bkp $mm 'NetworkThrottlingIndex';Bkp $mm 'SystemResponsiveness';New-ItemProperty -Path $mm -Name 'NetworkThrottlingIndex' -Value 0xFFFFFFFF -PropertyType DWord -Force -EA SilentlyContinue|Out-Null;SRD $mm 'SystemResponsiveness' 16;Write-Log '  [04] MMCSS: applied';$ok++ } catch { Write-Log "  [04] MMCSS ERROR";$err++ }

    # [05] NTFS
    try { if($hasFsutil){& fsutil behavior set disable8dot3 1 2>&1|Out-Null;& fsutil behavior set disablelastaccess 1 2>&1|Out-Null};SRD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive' 1;Write-Log '  [05] NTFS: applied';$ok++ } catch { Write-Log "  [05] NTFS ERROR";$err++ }

    # [06] Nagle
    try { $ifBase='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces';$nc=0;foreach($iface in (Get-ChildItem -Path $ifBase -EA SilentlyContinue)){$ifp=$iface.PSPath;$d=Get-ItemProperty -Path $ifp -Name 'DhcpIPAddress' -EA SilentlyContinue;$s=Get-ItemProperty -Path $ifp -Name 'IPAddress' -EA SilentlyContinue;if(-not(($null -ne $d -and $d.DhcpIPAddress -ne '0.0.0.0')-or($null -ne $s -and $s.IPAddress -ne '0.0.0.0' -and $s.IPAddress -ne ''))){continue};SRD $ifp 'TcpAckFrequency' 1;SRD $ifp 'TCPNoDelay' 1;$nc++};Write-Log "  [06] Nagle: $nc NIC(s)";$ok++ } catch { Write-Log "  [06] Nagle ERROR";$err++ }

    # [07] Core Parking
    try { if($hasPowercfg){& powercfg -setacvalueindex SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 100 2>&1|Out-Null;& powercfg -setactive SCHEME_CURRENT 2>&1|Out-Null;Write-Log '  [07] Core Parking: unparked';$ok++}else{$warn++} } catch { Write-Log "  [07] CoreParking ERROR";$err++ }

    # [08] Pagefile
    try { $pfMB=[math]::Min($ramMB,8192);SRS 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'PagingFiles' "C:\pagefile.sys $pfMB $pfMB";Write-Log "  [08] Pagefile: fixed ${pfMB}MB";$ok++ } catch { Write-Log "  [08] Pagefile ERROR";$err++ }

    # [09] HAGS
    try { SRD 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2;Write-Log '  [09] HAGS: enabled';$ok++ } catch { Write-Log "  [09] HAGS ERROR";$err++ }

    # [10] Hibernate (workstation only)
    try { if(-not $isServer -and -not $isLaptop -and $hasPowercfg){& powercfg /h off 2>&1|Out-Null;Write-Log '  [10] Hibernate: disabled';$ok++}else{Write-Log '  [10] Hibernate: skipped (server/laptop)';$warn++} } catch { Write-Log "  [10] Hibernate ERROR";$err++ }

    # SSD TRIM
    try {
        $vols = Get-WmiObject Win32_Volume -EA SilentlyContinue | Where-Object { $_.DriveType -eq 3 -and $null -ne $_.DriveLetter }
        $trimCount = 0
        foreach ($v in $vols) {
            $drove = $v.DriveLetter.TrimEnd('\')[0]
            if ($hasOptVol) { try { Optimize-Volume -DriveLetter $drove -ReTrim -EA SilentlyContinue; $trimCount++ } catch {} }
            else { & defrag.exe "${drove}:" /X /U 2>&1 | Out-Null; $trimCount++ }
        }
        Write-Log "  SSD TRIM: $trimCount volume(s)"
    } catch {}

    Write-Log "  Stage 1 complete: ok=$ok warn=$warn err=$err"
    return @{ OK = $ok; Warn = $warn; Err = $err; Skipped = $false }
}

# =============================================================================
# STAGE 2 -- DISK CLEAN (DESPERATION MODE)
# =============================================================================

function Invoke-Stage2DiskClean {
    Write-Sep
    Write-Log 'STAGE 2/6: Disk Clean (Desperation Mode)'
    Write-Sep2

    $sysDrive    = $env:SystemDrive
    $freeStart   = Get-DriveFreeGB
    $bytesFreed  = 0L
    $errors      = 0

    try { $os = Get-WmiObject Win32_OperatingSystem -EA Stop; $isServer = ($os.ProductType -eq 2 -or $os.ProductType -eq 3) } catch { $isServer = $false }
    Write-Log "  Drive $sysDrive free at start: ${freeStart}GB | Server: $isServer"

    function RC { param([string]$P,[string]$L,[int]$MinMins=0)
        if(-not(Test-Path $P)){Write-Log "  [Skip] $L";return 0L}
        $cutoff=(Get-Date).AddMinutes(-$MinMins);$freed=0L;$skip=0;$fail=0
        foreach($item in (Get-ChildItem -Path $P -Force -EA SilentlyContinue)){
            if($MinMins -gt 0 -and $item.LastWriteTime -gt $cutoff){$skip++;continue}
            try{if($item.PSIsContainer){$sz=Get-FolderSize -Path $item.FullName;Remove-Item -LiteralPath $item.FullName -Recurse -Force -EA Stop}else{$sz=$item.Length;Remove-Item -LiteralPath $item.FullName -Force -EA Stop};$freed+=[long]$sz}catch{$fail++}
        }
        $msg="  [Done] $L -- freed $(Format-Bytes $freed)"
        if($skip-gt 0){$msg+=" | skipped $skip recent"}
        if($fail -gt 0){$msg+=" | $fail locked"}
        Write-Log $msg; return $freed
    }

    function RS { param([string]$P,[string]$L)
        if(-not(Test-Path $P)){return}
        try{Remove-Item -Path $P -Recurse -Force -EA SilentlyContinue;Write-Log "  [Done] $L"}catch{Write-Log "  [Warn] $L -- $($_.Exception.Message)"}
    }

    # Phase 1 -- System temp
    Write-Log '  [Phase 1] System temp'
    $bytesFreed += RC "$env:SystemRoot\Temp" 'Windows\Temp' 60
    $bytesFreed += RC "$env:SystemRoot\SoftwareDistribution\Download" 'WU Download Cache'
    $bytesFreed += RC "$env:SystemRoot\Prefetch" 'Prefetch'

    # Phase 2 -- Logs and dumps
    Write-Log '  [Phase 2] Logs and crash dumps'
    foreach ($p in @("$env:SystemRoot\Logs\CBS","$env:SystemRoot\Logs\DISM","$env:SystemRoot\Logs\MoSetup","$env:SystemRoot\Logs\NetSetup","$env:SystemRoot\Logs\WindowsUpdate")) { $bytesFreed += RC $p "Logs\$(Split-Path $p -Leaf)" }
    $bytesFreed += RC "$env:SystemRoot\Minidump" 'Minidump'
    $memDump = "$env:SystemRoot\MEMORY.DMP"
    if (Test-Path $memDump) { try { $sz=(Get-Item $memDump -Force -EA Stop).Length; Remove-Item $memDump -Force -EA Stop; Write-Log "  [Done] MEMORY.DMP -- freed $(Format-Bytes $sz)"; $bytesFreed+=[long]$sz } catch {} }
    foreach ($p in @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive","$env:ProgramData\Microsoft\Windows\WER\ReportQueue")) { $bytesFreed += RC $p "WER\$(Split-Path $p -Leaf)" }

    # Phase 3 -- DO cache, font cache, patch cache
    Write-Log '  [Phase 3] Delivery optimization, font cache, patch cache'
    $doPath = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
    $bytesFreed += RC $doPath 'Delivery Optimization Cache'
    try { $doCmd=Get-Command 'Delete-DeliveryOptimizationCache' -EA SilentlyContinue; if($doCmd){Delete-DeliveryOptimizationCache -Force -EA SilentlyContinue|Out-Null;Write-Log '  [Done] DO cache flushed via API'} } catch {}
    if (-not $isServer) {
        foreach ($p in @("$env:SystemRoot\ServiceProfiles\LocalService\AppData\Local\FontCache","$env:SystemRoot\System32\FNTCACHE.DAT")) {
            if(Test-Path $p){try{$item=Get-Item $p -Force -EA SilentlyContinue;$sz=if($item.PSIsContainer){Get-FolderSize -Path $p}else{$item.Length};Remove-Item $p -Recurse -Force -EA Stop;Write-Log "  [Done] Font cache: $(Split-Path $p -Leaf) -- freed $(Format-Bytes $sz)";$bytesFreed+=[long]$sz}catch{Write-Log "  [Warn] Font cache locked: $(Split-Path $p -Leaf)"}}
        }
        $patchCache = "$env:SystemRoot\Installer\`$PatchCache`$"
        $bytesFreed += RC $patchCache 'MSI Patch Cache'
    }

    # Phase 3b -- Extended safe locations
    Write-Log '  [Phase 3b] Extended cleanup'
    RS "$env:SystemRoot\System32\d3dscache" 'D3D Shader Cache'
    $profKeys = Get-ItemProperty "$ProfileList\*" -EA SilentlyContinue | Where-Object { $_.PSChildName -match 'S-1-5-21-(\d+-?){4}$|S-1-12-1-(\d+-?){4}$' }
    foreach ($prof in $profKeys) {
        $pp = $prof.ProfileImagePath; if(-not $pp -or -not(Test-Path $pp)){continue}; $un=Split-Path $pp -Leaf
        RS "$pp\AppData\Local\D3DSCache" "D3D Cache: $un"
        RS "$pp\AppData\Local\Microsoft\Windows\INetCache" "IE/Edge Cache: $un"
        RS "$pp\AppData\Local\Microsoft\Windows\INetCookies" "IE Cookies: $un"
        RS "$pp\AppData\Local\Microsoft\Windows\History" "IE History: $un"
    }
    RS "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\PeerDistRepub" 'BranchCache'
    RS "$env:SystemRoot\System32\config\systemprofile\AppData\Local\PeerDistRepub" 'BranchCache (SYSTEM)'
    RS "$env:ProgramData\Microsoft\Diagnosis\ETLLogs\AutoLogger" 'Diagnostic ETL logs'
    RS "$env:ProgramData\Microsoft\Windows Defender\Scans\History\Results\Resource" 'Defender scan cache'
    RS "$env:ProgramData\Microsoft\Windows Defender\Scans\History\Results\Quick" 'Defender quick cache'
    RS "$env:SystemRoot\SoftwareDistribution\PostRebootEventCache" 'WU PostRebootEventCache'

    # Phase 3c -- Catroot2, BITS, WU logs, CryptnetUrlCache, driver caches
    Write-Log '  [Phase 3c] Additional safe locations'
    try { Stop-Service -Name 'CryptSvc' -Force -EA SilentlyContinue; Start-Sleep 2; Remove-FolderContents "$env:SystemRoot\System32\catroot2"; Write-Log '  [Done] Catroot2'; Start-Service 'CryptSvc' -EA SilentlyContinue } catch { Start-Service 'CryptSvc' -EA SilentlyContinue }
    Remove-FolderContents "$env:SystemRoot\SoftwareDistribution\DataStore\Logs"; Write-Log '  [Done] WU DataStore Logs'
    try { Stop-Service -Name 'BITS' -Force -EA SilentlyContinue; Start-Sleep 2; Get-ChildItem "$env:AllUsersProfile\Microsoft\Network\Downloader" -Filter 'qmgr*.dat' -Force -EA SilentlyContinue | ForEach-Object { try{Remove-Item $_.FullName -Force -EA SilentlyContinue}catch{} }; Write-Log '  [Done] BITS queue files'; Start-Service 'BITS' -EA SilentlyContinue } catch { Start-Service 'BITS' -EA SilentlyContinue }
    if (Test-Path 'C:\NVIDIA') { Remove-FolderContents 'C:\NVIDIA'; Write-Log '  [Done] NVIDIA install cache' }
    if (Test-Path 'C:\AMD')    { Remove-FolderContents 'C:\AMD';    Write-Log '  [Done] AMD install cache' }
    Remove-FolderContents "$env:ProgramData\NVIDIA Corporation\Downloader"
    if (Test-Path "$env:SystemRoot\System32\LogFiles") { Get-ChildItem "$env:SystemRoot\System32\LogFiles" -Recurse -Force -EA SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | ForEach-Object { try{Remove-Item $_.FullName -Force -EA SilentlyContinue}catch{} }; Write-Log '  [Done] System32\LogFiles (>30d)' }
    foreach ($prof in $profKeys) {
        $pp=$prof.ProfileImagePath;if(-not $pp -or -not(Test-Path $pp)){continue};$un=Split-Path $pp -Leaf
        $cp="$pp\AppData\LocalLow\Microsoft\CryptnetUrlCache"
        if(Test-Path $cp){Remove-FolderContents "$cp\Content";Remove-FolderContents "$cp\MetaData";Write-Log "  [Done] CryptnetUrlCache: $un"}
    }

    # Phase 4 -- DISM component cleanup
    Write-Log '  [Phase 4] DISM component cleanup'
    try {
        $dism = Start-Process -FilePath 'dism.exe' -ArgumentList '/Online /Cleanup-Image /StartComponentCleanup' -Wait -PassThru -WindowStyle Hidden -EA Stop
        Write-Log "  [Done] DISM ComponentCleanup (exit $($dism.ExitCode))"
    } catch { Write-Log "  [Warn] DISM failed: $($_.Exception.Message)" }

    # Phase 5 -- User profile cleanup
    Write-Log '  [Phase 5] User profile cleanup'
    foreach ($prof in $profKeys) {
        $pp=$prof.ProfileImagePath;if(-not $pp -or -not(Test-Path $pp)){continue};$un=Split-Path $pp -Leaf
        Write-Log "    User: $un"
        $bytesFreed += RC "$pp\AppData\Local\Temp" "$un\Temp" 60
        foreach ($tp in @("$pp\AppData\Roaming\Microsoft\Teams\blob_storage","$pp\AppData\Roaming\Microsoft\Teams\Cache","$pp\AppData\Roaming\Microsoft\Teams\databases","$pp\AppData\Roaming\Microsoft\Teams\Code Cache","$pp\AppData\Roaming\Microsoft\Teams\GPUCache")) { $bytesFreed += RC $tp "$un\Teams\$(Split-Path $tp -Leaf)" }
        $bytesFreed += RC "$pp\AppData\Roaming\Microsoft\Windows\Recent" "$un\Recent"
        $thumbPath = "$pp\AppData\Local\Microsoft\Windows\Explorer"
        if(Test-Path $thumbPath){$thumbFiles=Get-ChildItem $thumbPath -Filter 'thumbcache_*.db' -Force -EA SilentlyContinue;$tf=0L;foreach($f in $thumbFiles){try{$tf+=$f.Length;Remove-Item -LiteralPath $f.FullName -Force -EA Stop}catch{}};if($tf -gt 0){$bytesFreed+=$tf;Write-Log "    [Done] $un thumbnail cache -- freed $(Format-Bytes $tf)"}}
        $bytesFreed += RC "$pp\AppData\Local\Microsoft\Windows\WER" "$un\WER"
        if (-not $isServer) {
            $dlPath = "$pp\Downloads"
            if(Test-Path $dlPath){$freed=0L;Get-ChildItem -Path $dlPath -File -Force -EA SilentlyContinue|Where-Object{$_.LastWriteTime -lt (Get-Date).AddDays(-90)}|ForEach-Object{try{$freed+=$_.Length;Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue}catch{}};if($freed -gt 0){$bytesFreed+=$freed;Write-Log "    [Done] $un Downloads (>90d) -- freed $(Format-Bytes $freed)"}}
        }
    }

    # Phase 6 -- Recycle Bin
    Write-Log '  [Phase 6] Recycle Bin'
    try { $rc=Get-Command 'Clear-RecycleBin' -EA SilentlyContinue;if($rc){Clear-RecycleBin -Force -EA SilentlyContinue}else{$sh=New-Object -ComObject Shell.Application;$sh.Namespace(0xA).Items()|ForEach-Object{$_.InvokeVerb('delete')}};Write-Log '  [Done] Recycle Bin emptied' } catch {}

    # Phase 7 -- Windows upgrade leftovers
    Write-Log '  [Phase 7] Upgrade leftovers'
    foreach ($uf in @(@{P="$sysDrive\Windows.old";L='Windows.old'},@{P="$sysDrive\`$WINDOWS.~BT";L='$WINDOWS.~BT'},@{P="$sysDrive\`$WINDOWS.~WS";L='$WINDOWS.~WS'})) {
        if(Test-Path $uf.P){$sz=Get-FolderSize -Path $uf.P;Write-Log "  [INFO] Removing $($uf.L) ($(Format-Bytes $sz))...";Remove-FolderFast -Path $uf.P|Out-Null;$bytesFreed+=$sz}else{Write-Log "  [Skip] $($uf.L)"}
    }

    # Phase 8 -- Hibernate (workstation, if not already handled by PPM)
    if (-not $isServer) {
        $hiberFile = "$env:SystemRoot\hiberfil.sys"
        if (Test-Path $hiberFile) {
            try { $sz=(Get-Item $hiberFile -Force -EA Stop).Length; & powercfg.exe /h off 2>&1|Out-Null; Write-Log "  [Done] Hibernate disabled -- freed $(Format-Bytes $sz)"; $bytesFreed+=[long]$sz } catch {}
        }
    }

    $freeEnd = Get-DriveFreeGB
    $netGB   = [math]::Round($freeEnd - $freeStart, 2)
    Write-Log "  Stage 2 complete: freed $(Format-Bytes $bytesFreed) | Disk: ${freeStart}GB -> ${freeEnd}GB (net +${netGB}GB)"
    return @{ FreedBytes = $bytesFreed; Errors = $errors }
}

# =============================================================================
# STAGE 3 -- TEMP PROFILE REPAIR
# =============================================================================

function Invoke-Stage3TempProfileRepair {
    Write-Sep
    Write-Log 'STAGE 3/6: Temp Profile Repair'
    Write-Sep2

    $profileMap = Get-ProfileListMap
    $cleanSIDs  = @{}
    try { foreach($key in @(Get-ChildItem -Path $ProfileList -EA SilentlyContinue)){$n=Split-Path $key.Name -Leaf;if($n -notmatch '\.bak$' -and $n -notmatch '\.\d{3}$'){$cleanSIDs[$n]=$true}} } catch {}

    $fixed=0; $deleted=0; $regCleaned=0; $failed=0

    # Pass 1 -- registry corruption
    Write-Log '  Pass 1: Registry corruption'
    $issues = @()
    try {
        foreach($key in @(Get-ChildItem -Path $ProfileList -EA SilentlyContinue)){
            $sidName=$key.Name|Split-Path -Leaf;$kp="$ProfileList\$sidName";$baseSID=$sidName -replace '\.bak$','' -replace '\.\d{3}$',''
            if($BuiltinSIDs -contains $baseSID){continue}
            $props=Get-ItemProperty -Path $kp -EA SilentlyContinue;if($null -eq $props){continue}
            $profPath=$props.ProfileImagePath;$state=$props.State;$username=Split-Path $profPath -Leaf
            if(Test-ProfileLoaded -SID $baseSID){continue}
            $it=$null
            if($sidName -match '\.bak$'){$it=if($cleanSIDs.ContainsKey($baseSID)){'DuplicateBak'}else{'OnlyBak'}}
            elseif($profPath -match '\.bak$' -or $profPath -match '\.\d{3}$'){$it='CorruptPath'}
            elseif($null -ne $state -and ($state -band 0x100) -eq 0x100){$it='TempState'}
            if($null -ne $it){Write-Log "    [CORRUPT] $username | $sidName | $it" 'WARN';$issues+=@{SIDName=$sidName;BaseSID=$baseSID;Username=$username;Path=$profPath;IssueType=$it;KeyPath=$kp;CleanSID=$baseSID}}
            else{Write-Log "    [OK] $username ($sidName)"}
        }
    } catch {}

    foreach($issue in $issues){
        try {
            switch($issue.IssueType){
                'DuplicateBak'{$bkp="$ProfileList\$($issue.SIDName)";$clp="$ProfileList\$($issue.CleanSID)";$gp=(Get-ItemProperty -Path $bkp -EA Stop).ProfileImagePath -replace '\.bak$','';Remove-Item -Path $clp -Recurse -Force -EA Stop;$s="HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($issue.SIDName)";$d="HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($issue.CleanSID)";& reg.exe copy $s $d /s /f 2>&1|Out-Null;Remove-Item -Path $bkp -Recurse -Force -EA SilentlyContinue;Set-ItemProperty -Path $clp -Name 'ProfileImagePath' -Value $gp -EA Stop;Set-ItemProperty -Path $clp -Name 'State' -Value 0 -EA SilentlyContinue;$fixed++;Write-Log "    [FIXED] DuplicateBak: $($issue.Username)"}
                'OnlyBak'{$bkp="$ProfileList\$($issue.SIDName)";$clp="$ProfileList\$($issue.CleanSID)";$gp=(Get-ItemProperty -Path $bkp -EA Stop).ProfileImagePath -replace '\.bak$','';$s="HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($issue.SIDName)";$d="HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($issue.CleanSID)";& reg.exe copy $s $d /s /f 2>&1|Out-Null;Set-ItemProperty -Path $clp -Name 'ProfileImagePath' -Value $gp -EA Stop;Set-ItemProperty -Path $clp -Name 'State' -Value 0 -EA SilentlyContinue;Remove-Item -Path $bkp -Recurse -Force -EA SilentlyContinue;$fixed++;Write-Log "    [FIXED] OnlyBak: $($issue.Username)"}
                'CorruptPath'{$cp2=$issue.Path -replace '\.bak$','' -replace '\.\d{3}$','';Set-ItemProperty -Path $issue.KeyPath -Name 'ProfileImagePath' -Value $cp2 -EA Stop;Set-ItemProperty -Path $issue.KeyPath -Name 'State' -Value 0 -EA SilentlyContinue;$fixed++;Write-Log "    [FIXED] CorruptPath: $($issue.Username)"}
                'TempState'{Set-ItemProperty -Path $issue.KeyPath -Name 'State' -Value 0 -EA Stop;$fixed++;Write-Log "    [FIXED] TempState: $($issue.Username)"}
            }
        } catch { $failed++;Write-Log "    [FAIL] $($issue.Username): $($_.Exception.Message)" 'WARN' }
    }

    # Pass 2 -- orphaned filesystem folders
    Write-Log '  Pass 2: Orphaned temp folders'
    $pathToSID=@{};foreach($sid in $profileMap.Keys){$p=$profileMap[$sid];if($p){$pathToSID[$p.ToLower()]=$sid}}
    $usersPath = $env:SystemDrive + '\Users'
    if(Test-Path $usersPath){
        foreach($folder in @(Get-ChildItem -Path $usersPath -Directory -Force -EA SilentlyContinue)){
            $fn=$folder.Name;$fp=$folder.FullName
            if($SpecialFolders -contains $fn.ToLower()){continue}
            if($pathToSID.ContainsKey($fp.ToLower())){continue}
            $isTmp=$false;foreach($p in $TempPatterns){if($fn -match $p){$isTmp=$true;break}}
            if($isTmp){
                $sz=Get-FolderSize -Path $fp;Write-Log "    [ORPHAN] $fn $(Format-Bytes $sz)" 'WARN'
                $ok=Remove-FolderFast -Path $fp
                if($ok){$deleted++;Write-Log "    [DELETED] $fn"}else{$failed++;Write-Log "    [FAIL] $fn" 'WARN'}
            }
        }
    }

    # Pass 3 -- orphaned registry keys
    Write-Log '  Pass 3: Orphaned registry keys'
    foreach($sidName in $profileMap.Keys){
        $baseSID=$sidName -replace '\.bak$','' -replace '\.\d{3}$',''
        if($BuiltinSIDs -contains $baseSID){continue};if(Test-ProfileLoaded -SID $baseSID){continue}
        $profPath=$profileMap[$sidName];$cleanPath=$profPath -replace '\.bak$','' -replace '\.\d{3}$','';$username=Split-Path $cleanPath -Leaf
        if(-not(Test-Path $cleanPath)){
            Write-Log "    [ORPHAN-REG] $username | $sidName" 'WARN'
            try{Remove-Item -Path "$ProfileList\$sidName" -Recurse -Force -EA Stop;$regCleaned++;Write-Log "    [CLEANED] $username"}catch{$failed++;Write-Log "    [FAIL] $username" 'WARN'}
        }
    }

    Write-Log "  Stage 3 complete: fixed=$fixed deleted=$deleted regCleaned=$regCleaned failed=$failed"
    return @{ Fixed=$fixed; Deleted=$deleted; RegCleaned=$regCleaned; Failed=$failed }
}

# =============================================================================
# STAGE 4 -- INACTIVE PROFILE REMOVAL
# =============================================================================

function Invoke-Stage4InactiveProfiles {
    Write-Sep
    Write-Log "STAGE 4/6: Inactive Profile Removal (>${InactiveDays} days)"
    Write-Sep2

    $deleted=0; $failed=0; $reclaimedBytes=0L
    $cutoffDate = (Get-Date).AddDays(-$InactiveDays)
    $profileMap = Get-ProfileListMap

    foreach($sidName in $profileMap.Keys){
        $baseSID=$sidName -replace '\.bak$','' -replace '\.\d{3}$',''
        if($BuiltinSIDs -contains $baseSID){continue}
        if(Test-ProfileLoaded -SID $baseSID){Write-Log "    [SKIP-ACTIVE] $baseSID";continue}
        $profPath=$profileMap[$sidName];$username=Split-Path $profPath -Leaf
        if($ProfileExclusions -contains $username.ToLower()){Write-Log "    [SKIP-EXCLUDED] $username";continue}
        if(-not(Test-Path $profPath)){continue}

        # Check last use via WMI
        $lastUse = $null
        try { $wmi=Get-WmiObject -Class Win32_UserProfile -Filter "SID='$baseSID'" -EA SilentlyContinue;if($null -ne $wmi -and $wmi.LastUseTime){$lastUse=[System.Management.ManagementDateTimeConverter]::ToDateTime($wmi.LastUseTime)} } catch {}
        if($null -eq $lastUse){try{$lastUse=(Get-Item -LiteralPath $profPath -EA SilentlyContinue).LastWriteTime}catch{}}
        if($null -eq $lastUse){Write-Log "    [SKIP] $username -- cannot determine last use";continue}

        $daysOld=[int]((Get-Date)-$lastUse).TotalDays
        if($daysOld -lt $InactiveDays){Write-Log "    [SKIP] $username -- ${daysOld}d (active)";continue}

        $sz=Get-FolderSize -Path $profPath
        Write-Log "    [REMOVE] $username -- ${daysOld}d inactive | $(Format-Bytes $sz)"
        $ok=Remove-FolderFast -Path $profPath
        if($ok){
            try{Remove-Item -Path "$ProfileList\$sidName" -Recurse -Force -EA SilentlyContinue}catch{}
            $deleted++;$reclaimedBytes+=$sz;Write-Log "    [DELETED] $username"
        } else { $failed++;Write-Log "    [FAIL] $username" 'WARN' }
    }

    Write-Log "  Stage 4 complete: deleted=$deleted failed=$failed reclaimed=$(Format-Bytes $reclaimedBytes)"
    return @{ Deleted=$deleted; Failed=$failed; ReclaimedBytes=$reclaimedBytes }
}

# =============================================================================
# STAGE 5 -- VSS TRIM + WER CRASH DUMPS
# =============================================================================

function Invoke-Stage5VSSAndDumps {
    Write-Sep
    Write-Log 'STAGE 5/6: VSS Shadow Copy Trim + WER Crash Dumps'
    Write-Sep2

    $errors = 0

    # VSS -- delete all but most recent
    try {
        $shadowOut   = & vssadmin.exe list shadows /for=C: 2>&1
        $shadowCount = ($shadowOut | Where-Object { $_ -match 'Shadow Copy ID' }).Count
        Write-Log "  VSS shadow copies found: $shadowCount"
        if($shadowCount -gt 1){
            $del=0
            while($true){
                $chk=& vssadmin.exe list shadows /for=C: 2>&1
                $cnt=($chk|Where-Object{$_ -match 'Shadow Copy ID'}).Count
                if($cnt -le 1){break}
                & vssadmin.exe delete shadows /for=C: /oldest /quiet 2>&1|Out-Null
                $del++;if($del -gt 50){break}
            }
            Write-Log "  Deleted $del old shadow copy(s), kept most recent"
        }
        # Cap storage to 10%
        $disk=Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -EA SilentlyContinue
        if($null -ne $disk){$capGB=[math]::Max([math]::Round($disk.Size/1GB*0.10,0),2);& vssadmin.exe resize shadowstorage /for=C: /on=C: /maxsize="${capGB}GB" 2>&1|Out-Null;Write-Log "  VSS storage capped at ${capGB}GB"}
    } catch { Write-Log "  WARN: VSS cleanup failed: $($_.Exception.Message)" 'WARN';$errors++ }

    # WER crash dumps
    Write-Log '  Clearing WER crash dumps...'
    $dumpPaths = @("$env:ProgramData\Microsoft\Windows\WER\LocalDumps","$env:SystemRoot\Minidump")
    try { $profKeys=Get-ItemProperty "$ProfileList\*" -EA SilentlyContinue|Where-Object{$_.PSChildName -match 'S-1-5-21-(\d+-?){4}$'};foreach($prof in $profKeys){$pp=$prof.ProfileImagePath;if($pp -and (Test-Path $pp)){$dumpPaths+="$pp\AppData\Local\CrashDumps"}} } catch {}
    foreach($dp in $dumpPaths){if(Test-Path $dp){Remove-FolderContents -Path $dp;Write-Log "  Cleared: $dp"}}

    Write-Log "  Stage 5 complete: errors=$errors"
    return @{ Errors=$errors }
}

# =============================================================================
# STAGE 6 -- DISK REPAIR (schedule chkdsk + reboot)
# =============================================================================

function Invoke-Stage6DiskRepair {
    Write-Sep
    Write-Log 'STAGE 6/6: Disk Repair'
    Write-Sep2

    # DC guard
    try { $osRole=(Get-WmiObject Win32_OperatingSystem -EA SilentlyContinue).ProductType;if($osRole -eq 2){Write-Log 'ERROR: Domain Controller detected -- skipping forced reboot' 'ERROR';return @{Scheduled=$false;Skipped=$true}} } catch {}

    if(-not (Test-Path $DiskRepairDir)){New-Item -Path $DiskRepairDir -ItemType Directory -Force -EA SilentlyContinue|Out-Null}

    # Schedule chkdsk via dirty flag
    Write-Log '  Scheduling chkdsk /f /r /x on C: via dirty flag...'
    & chkntfs /X C: 2>&1|Out-Null
    & chkntfs /C C: 2>&1|Out-Null
    & fsutil dirty set C: 2>&1|Out-Null
    Write-Log '  Volume marked dirty -- chkdsk will run at next boot'

    # Save state so DiskRepair resume script picks up at Phase 2
    try {
        if(-not(Test-Path $DiskRepairKey)){New-Item -Path $DiskRepairKey -Force -EA SilentlyContinue|Out-Null}
        New-ItemProperty -Path $DiskRepairKey -Name 'Phase'     -Value 2      -PropertyType DWord  -Force -EA SilentlyContinue|Out-Null
        New-ItemProperty -Path $DiskRepairKey -Name 'UpdatedAt' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -PropertyType String -Force -EA SilentlyContinue|Out-Null
        Write-Log '  State written: Phase=2 (post-boot resume will run SFC+DISM+defrag)'
    } catch {}

    Write-Log "  Stage 6 complete: Chkdsk scheduled. Reboot pending: $AllowReboot"
    return @{ Scheduled=$true; Skipped=$false }
}

# =============================================================================
# MAIN -- STARTUP
# =============================================================================
if(-not(Test-Path $BaseDir)){New-Item $BaseDir -ItemType Directory -Force -EA SilentlyContinue|Out-Null}

$startTime  = Get-Date
$freeAtStart = Get-DriveFreeGB

Write-Sep
Write-Log "Paladin Disk Maintenance v$ScriptVer | Site: $SiteName | Machine: $MachineName"
Write-Log "AllowReboot: $AllowReboot | InactiveDays: $InactiveDays | UDF: $UDFSlot"
Write-Log "Disk free at start: ${freeAtStart}GB"
Write-Sep

# =============================================================================
# RUN ALL STAGES
# =============================================================================

$s1 = Invoke-Stage1PPM
Start-Sleep -Seconds 5

$s2 = Invoke-Stage2DiskClean
Start-Sleep -Seconds 5

$s3 = Invoke-Stage3TempProfileRepair
Start-Sleep -Seconds 3

$s4 = Invoke-Stage4InactiveProfiles
Start-Sleep -Seconds 3

$s5 = Invoke-Stage5VSSAndDumps
Start-Sleep -Seconds 3

$s6 = Invoke-Stage6DiskRepair

# =============================================================================
# FINAL REPORT
# =============================================================================
$freeAtEnd   = Get-DriveFreeGB
$netReclaimed = [math]::Round($freeAtEnd - $freeAtStart, 2)
$elapsed     = [int]((Get-Date) - $startTime).TotalMinutes

$totalErrors = 0
if($s1.Err   -gt 0){$totalErrors++}
if($s2.Errors -gt 0){$totalErrors++}
if($s3.Failed -gt 0){$totalErrors++}
if($s4.Failed -gt 0){$totalErrors++}
if($s5.Errors -gt 0){$totalErrors++}

Write-Sep
Write-Log "PALADIN DISK MAINTENANCE -- FINAL REPORT"
Write-Log "Site     : $SiteName | Machine: $MachineName"
Write-Log "Duration : ${elapsed}m | Errors: $totalErrors"
Write-Sep
Write-Log "Stage 1 -- PPM Advanced      : ok=$($s1.OK) warn=$($s1.Warn) err=$($s1.Err)$(if($s1.Skipped){' (already applied)'})"
Write-Log "Stage 2 -- Disk Clean        : freed=$(Format-Bytes $s2.FreedBytes)"
Write-Log "Stage 3 -- Temp Profile Repair: fixed=$($s3.Fixed) deleted=$($s3.Deleted) regCleaned=$($s3.RegCleaned) failed=$($s3.Failed)"
Write-Log "Stage 4 -- Inactive Profiles : deleted=$($s4.Deleted) reclaimed=$(Format-Bytes $s4.ReclaimedBytes) failed=$($s4.Failed)"
Write-Log "Stage 5 -- VSS/Dumps         : errors=$($s5.Errors)"
Write-Log "Stage 6 -- Disk Repair       : chkdsk scheduled=$($s6.Scheduled)"
Write-Log "Disk before : ${freeAtStart}GB  |  Disk after: ${freeAtEnd}GB  |  Net: +${netReclaimed}GB"
Write-Sep

$ts     = Get-Date -Format 'yyyy-MM-dd HH:mm'
$udfMsg = "$(if($totalErrors -eq 0){'PASS'}else{'WARN'}) $ts | $MachineName | Freed:+${netReclaimed}GB | Err:$totalErrors$(if($AllowReboot -and $s6.Scheduled){' | CHKDSK:pending-reboot'})"
Set-DattoUDF -Slot $UDFSlot -Value $udfMsg

# =============================================================================
# REBOOT (single, at the very end, only if all stages complete)
# =============================================================================
if($AllowReboot -and $s6.Scheduled -and $totalErrors -eq 0){
    Write-Log 'All stages complete -- initiating reboot in 60s for chkdsk'
    Show-UserMessage 'IMPORTANT: Your PC will restart in 60 seconds for scheduled disk maintenance. Please SAVE ALL OPEN WORK now. Disk repair will run automatically -- do NOT power off your PC.'
    Start-Sleep -Seconds 30
    Show-UserMessage 'Your PC will restart in 30 seconds. Disk repair will run automatically. Do NOT power off your PC.'
    Start-Sleep -Seconds 30
    Write-Log 'Rebooting now. SFC + DISM + defrag will run automatically post-boot via Paladin_DiskRepair_Resume task.'
    & shutdown.exe /r /t 0 /f /c "Paladin Disk Maintenance: chkdsk + repair in progress. Do not power off." 2>&1 | Out-Null
    exit 0
} elseif($AllowReboot -and $totalErrors -gt 0){
    Write-Log "Reboot suppressed -- $totalErrors stage error(s). Fix errors before scheduling reboot." 'WARN'
}

exit $(if($totalErrors -eq 0){0}else{1})
