#Requires -Version 3.0
# =============================================================================
# PPM RMM -- Paladin Performance Maximizer (Experimental Tier)
# Datto RMM Component: PPM RMM Experimental [WIN]
# Version: 9.0.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
# Tier: Experimental -- all Safe + Advanced + Anti-AI, WSearch, Kernel Memory.
# One-shot: Undo auto-detected from backup key. No input variables required.
# No installs. No GUI. No scheduled tasks. Registry + inbox tools only.
# Dangerous tweaks (VBS, HPET, MSI Mode, NativeNVMe) excluded.
# Reboot recommended after apply.
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$siteName = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }
Write-Host "PPM RMM Experimental v9.0.0 | Site: $siteName | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host 'Experimental tier. Reboot recommended after apply.'

# ---- Undo auto-detection ----------------------------------------------------
$BackupRoot = 'HKLM:\SOFTWARE\Paladin\PPM\RMM\Backup'
$UDFSlotN   = 10
$Undo       = Test-Path $BackupRoot
$action     = if ($Undo) { 'RESTORE' } else { 'APPLY' }
Write-Host "Action: $action (auto-detected)"

# ---- System detection -------------------------------------------------------
$isServer   = $false
$isLaptop   = $false
$isAMD      = $false
$isIntel    = $false
$logCount   = 4
$ramMB      = 4096
$totalRAMGB = 4
$build      = [System.Environment]::OSVersion.Version.Build
$isWin11    = $build -ge 22000

try {
    $os       = Get-WmiObject Win32_OperatingSystem -EA Stop
    $isServer = ($os.ProductType -eq 2 -or $os.ProductType -eq 3)
    $cpu      = Get-WmiObject Win32_Processor -EA SilentlyContinue | Select-Object -First 1
    $cpuName  = [string]$cpu.Name
    $isAMD    = $cpuName -match 'AMD'
    $isIntel  = $cpuName -match 'Intel'
    $cs       = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
    $logCount   = if ($null -ne $cs.NumberOfLogicalProcessors) { $cs.NumberOfLogicalProcessors } else { 4 }
    $ramBytes   = $cs.TotalPhysicalMemory
    $ramMB      = if ($null -ne $ramBytes) { [math]::Round($ramBytes / 1MB, 0) } else { 4096 }
    $totalRAMGB = if ($null -ne $ramBytes) { [math]::Round($ramBytes / 1GB, 0) } else { 4 }
} catch {}
try {
    $battery  = Get-WmiObject Win32_Battery -EA SilentlyContinue
    $isLaptop = ($null -ne $battery -and @($battery).Count -gt 0)
} catch {}

Write-Host "CPU AMD:$isAMD Intel:$isIntel | Cores:$logCount | RAM:${totalRAMGB}GB | Build:$build | Server:$isServer | Laptop:$isLaptop"

# ---- Inbox tool check (no installs) -----------------------------------------
$hasPowercfg = $null -ne (Get-Command powercfg.exe -EA SilentlyContinue)
$hasFsutil   = $null -ne (Get-Command fsutil.exe   -EA SilentlyContinue)
$hasSecedit  = $null -ne (Get-Command secedit.exe  -EA SilentlyContinue)

$hasNetAdapterRss = $false
try { Get-NetAdapterRss -EA Stop | Out-Null; $hasNetAdapterRss = $true } catch {}
if (-not $hasNetAdapterRss) {
    try { Import-Module NetAdapter -EA SilentlyContinue; Get-NetAdapterRss -EA Stop | Out-Null; $hasNetAdapterRss = $true } catch {}
}

$hasOptimizeVol = $false
try { Get-Command Optimize-Volume -EA Stop | Out-Null; $hasOptimizeVol = $true } catch {}
if (-not $hasOptimizeVol) {
    try { Import-Module Storage -EA SilentlyContinue; Get-Command Optimize-Volume -EA Stop | Out-Null; $hasOptimizeVol = $true } catch {}
}

Write-Host "Tools: powercfg:$hasPowercfg fsutil:$hasFsutil secedit:$hasSecedit NetAdapterRss:$hasNetAdapterRss Optimize-Volume:$hasOptimizeVol"

$lsaSource = @'
using System;using System.Runtime.InteropServices;
public class PPMLsa {
    [DllImport("advapi32.dll",SetLastError=true)] public static extern uint LsaOpenPolicy(IntPtr a,ref LSAOA b,uint c,out IntPtr d);
    [DllImport("advapi32.dll",SetLastError=true)] public static extern uint LsaAddAccountRights(IntPtr a,IntPtr b,LSAUS[] c,uint d);
    [DllImport("advapi32.dll")] public static extern uint LsaClose(IntPtr a);
    [DllImport("advapi32.dll")] public static extern uint LsaNtStatusToWinError(uint s);
    [DllImport("advapi32.dll",SetLastError=true)] public static extern bool ConvertStringSidToSid(string s,out IntPtr p);
    [DllImport("kernel32.dll")] public static extern IntPtr LocalFree(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct LSAOA{public int Length;public IntPtr RootDirectory;public IntPtr ObjectName;public uint Attributes;public IntPtr SecurityDescriptor;public IntPtr SecurityQualityOfService;}
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct LSAUS{public ushort Length;public ushort MaximumLength;[MarshalAs(UnmanagedType.LPWStr)]public string Buffer;}
    public static uint Grant(string sid,string priv){
        LSAOA a=new LSAOA(){Length=Marshal.SizeOf(typeof(LSAOA))};IntPtr pol;
        uint r=LsaOpenPolicy(IntPtr.Zero,ref a,0x00020020,out pol);if(r!=0)return LsaNtStatusToWinError(r);
        IntPtr sp;if(!ConvertStringSidToSid(sid,out sp))return(uint)Marshal.GetLastWin32Error();
        LSAUS[]privs=new LSAUS[]{new LSAUS(){Buffer=priv,Length=(ushort)(priv.Length*2),MaximumLength=(ushort)((priv.Length+1)*2)}};
        r=LsaAddAccountRights(pol,sp,privs,1);LocalFree(sp);LsaClose(pol);return r==0?0:LsaNtStatusToWinError(r);
    }
}
'@

# ---- Helpers ----------------------------------------------------------------
function Set-PPMRMMUDF {
    param([int]$Slot,[string]$Value)
    $v=$Value.Substring(0,[Math]::Min($Value.Length,255))
    try{New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' -Name "Custom$Slot" -PropertyType String -Value $v -Force -EA Stop|Out-Null}
    catch{Write-Host "WARN: UDF$Slot write failed: $_"}
}
function Ensure-BackupRoot { if(-not(Test-Path $BackupRoot)){New-Item -Path $BackupRoot -Force -EA SilentlyContinue|Out-Null} }
function Backup-RegValue {
    param([string]$Path,[string]$Name)
    try{Ensure-BackupRoot;$sk=($Path+'_'+$Name)-replace'[\\:/]','_';$e=Get-ItemProperty -Path $Path -Name $Name -EA SilentlyContinue;New-ItemProperty -Path $BackupRoot -Name $sk -Value(if($null -ne $e){$e.$Name}else{'__NOTEXIST__'})-Force -EA SilentlyContinue|Out-Null}catch{}
}
function Restore-RegValue {
    param([string]$Path,[string]$Name,[string]$Type)
    try{$sk=($Path+'_'+$Name)-replace'[\\:/]','_';$b=Get-ItemProperty -Path $BackupRoot -Name $sk -EA SilentlyContinue;if($null -eq $b){return};$v=$b.$sk;if($v -eq '__NOTEXIST__'){Remove-ItemProperty -Path $Path -Name $Name -EA SilentlyContinue}else{if(-not(Test-Path $Path)){New-Item -Path $Path -Force -EA SilentlyContinue|Out-Null};New-ItemProperty -Path $Path -Name $Name -Value $v -PropertyType $Type -Force -EA SilentlyContinue|Out-Null}}catch{}
}
function Set-RegDWord {
    param([string]$Path,[string]$Name,[int]$Value)
    if(-not(Test-Path $Path)){New-Item -Path $Path -Force -EA SilentlyContinue|Out-Null}
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force -EA SilentlyContinue|Out-Null
}
function Set-RegString {
    param([string]$Path,[string]$Name,[string]$Value)
    if(-not(Test-Path $Path)){New-Item -Path $Path -Force -EA SilentlyContinue|Out-Null}
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force -EA SilentlyContinue|Out-Null
}
function Remove-FolderContents {
    param([string]$Path,[int]$MinAgeMins=0)
    if(-not(Test-Path $Path)){return}
    $cutoff=(Get-Date).AddMinutes(-$MinAgeMins)
    foreach($item in(Get-ChildItem -Path $Path -Force -EA SilentlyContinue)){
        if($MinAgeMins -gt 0 -and $item.LastWriteTime -gt $cutoff){continue}
        try{Remove-Item -LiteralPath $item.FullName -Recurse -Force -EA Stop}catch{}
    }
}

$ok=0;$warn=0;$err=0;$rebootNeeded=$false

# =============================================================================
# ---- SAFE TIER (embedded) ---------------------------------------------------
# =============================================================================

Write-Host '-- [01/20] Power Plan (High Performance)'
try{
    if(-not $hasPowercfg){Write-Host '  SKIP: powercfg missing';$warn++}
    elseif(-not $Undo){
        $upGuid='e9a42b02-d5df-448d-aa00-03f14749eb61';$hpGuid='8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        $allPlans=[string](& powercfg /list 2>&1)
        $cur=[string](& powercfg /getactivescheme 2>&1|Select-Object -First 1)
        if($cur -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'){Ensure-BackupRoot;New-ItemProperty -Path $BackupRoot -Name 'PowerPlan_Active' -Value $Matches[1] -Force -EA SilentlyContinue|Out-Null}
        if($isLaptop){
            & powercfg /setactive '381b4222-f694-41f0-9685-ff5bb260df2e' 2>&1|Out-Null
            & powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>&1|Out-Null
            & powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 2>&1|Out-Null
            & powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>&1|Out-Null
            & powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5   2>&1|Out-Null
            & powercfg -setactive SCHEME_CURRENT 2>&1|Out-Null
            Write-Host '  OK: Laptop -- Balanced plan, AC=max CPU, DC=adaptive';$ok++
        }else{
            $tg=if($allPlans -match [regex]::Escape($upGuid)){$upGuid}elseif($allPlans -match [regex]::Escape($hpGuid)){$hpGuid}else{$null}
            if($null -eq $tg){$m=[string](& powercfg /list 2>&1|Where-Object{$_ -match 'High|Perf|Max|Ultimate'}|Select-Object -First 1);if($m -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'){$tg=$Matches[1]}}
            if($null -ne $tg){& powercfg /setactive $tg 2>&1|Out-Null;Write-Host "  OK: Desktop -- High/Ultimate Performance ($tg)";$ok++}
            else{Write-Host '  WARN: High Performance plan not found';$warn++}
        }
    }else{$b=Get-ItemProperty -Path $BackupRoot -Name 'PowerPlan_Active' -EA SilentlyContinue;if($null -ne $b){& powercfg /setactive $b.PowerPlan_Active 2>&1|Out-Null;Write-Host '  OK: Restored';$ok++}else{Write-Host '  WARN: No backup';$warn++}}
}catch{Write-Host "  ERROR: PowerPlan -- $($_.Exception.Message)";$err++}

Write-Host '-- [02/20] Win32PrioritySeparation'
try{$p='HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl';if(-not $Undo){Backup-RegValue -Path $p -Name 'Win32PrioritySeparation';Set-RegDWord -Path $p -Name 'Win32PrioritySeparation' -Value 38;Write-Host '  OK: =38';$ok++}else{Restore-RegValue -Path $p -Name 'Win32PrioritySeparation' -Type 'DWord';Write-Host '  OK: Restored';$ok++}}catch{Write-Host "  ERROR: PrioritySep -- $($_.Exception.Message)";$err++}

Write-Host '-- [03/20] Visual Effects (performance mode)'
try{$p='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects';if(-not $Undo){Backup-RegValue -Path $p -Name 'VisualFXSetting';Set-RegDWord -Path $p -Name 'VisualFXSetting' -Value 2;Write-Host '  OK: =2';$ok++}else{Restore-RegValue -Path $p -Name 'VisualFXSetting' -Type 'DWord';Write-Host '  OK: Restored';$ok++}}catch{Write-Host "  ERROR: VisualFX -- $($_.Exception.Message)";$err++}

Write-Host '-- [04/20] MMCSS NetworkThrottlingIndex + SystemResponsiveness'
try{
    $mm='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    if(-not $Undo){
        Backup-RegValue -Path $mm -Name 'NetworkThrottlingIndex';Backup-RegValue -Path $mm -Name 'SystemResponsiveness'
        New-ItemProperty -Path $mm -Name 'NetworkThrottlingIndex' -Value 0xFFFFFFFF -PropertyType DWord -Force -EA SilentlyContinue|Out-Null
        Set-RegDWord -Path $mm -Name 'SystemResponsiveness' -Value 16
        $g="$mm\Tasks\Games";if(-not(Test-Path $g)){New-Item -Path $g -Force -EA SilentlyContinue|Out-Null}
        Set-RegDWord -Path $g -Name 'GPU Priority' -Value 8;Set-RegDWord -Path $g -Name 'Priority' -Value 6
        Set-RegDWord -Path $g -Name 'Scheduling Category' -Value 2;Set-RegDWord -Path $g -Name 'SFIO Priority' -Value 1
        Write-Host '  OK: NTI=0xFFFFFFFF SR=16 Games set';$ok++
    }else{Restore-RegValue -Path $mm -Name 'NetworkThrottlingIndex' -Type 'DWord';Restore-RegValue -Path $mm -Name 'SystemResponsiveness' -Type 'DWord';Write-Host '  OK: Restored';$ok++}
}catch{Write-Host "  ERROR: MMCSS -- $($_.Exception.Message)";$err++}

Write-Host '-- [05/20] NTFS overhead'
try{
    $mp='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management';$np='HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    if(-not $Undo){
        Backup-RegValue -Path $mp -Name 'DisablePagingExecutive';Backup-RegValue -Path $np -Name 'NtfsDisable8dot3NameCreation';Backup-RegValue -Path $np -Name 'NtfsDisableLastAccessUpdate'
        if($hasFsutil){& fsutil behavior set disable8dot3 1 2>&1|Out-Null;& fsutil behavior set disablelastaccess 1 2>&1|Out-Null}
        else{Set-RegDWord -Path $np -Name 'NtfsDisable8dot3NameCreation' -Value 1;Set-RegDWord -Path $np -Name 'NtfsDisableLastAccessUpdate' -Value 1}
        Set-RegDWord -Path $mp -Name 'DisablePagingExecutive' -Value 1;Write-Host '  OK: 8.3 off LastAccess off DPE=1';$ok++
    }else{
        if($hasFsutil){& fsutil behavior set disable8dot3 0 2>&1|Out-Null;& fsutil behavior set disablelastaccess 0 2>&1|Out-Null}
        else{Restore-RegValue -Path $np -Name 'NtfsDisable8dot3NameCreation' -Type 'DWord';Restore-RegValue -Path $np -Name 'NtfsDisableLastAccessUpdate' -Type 'DWord'}
        Restore-RegValue -Path $mp -Name 'DisablePagingExecutive' -Type 'DWord';Write-Host '  OK: NTFS restored';$ok++
    }
}catch{Write-Host "  ERROR: NTFS -- $($_.Exception.Message)";$err++}

Write-Host '-- [06/20] Nagle + TcpAckFrequency'
try{
    $ifBase='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    if(Test-Path $ifBase){
        $nc=0;foreach($iface in(Get-ChildItem -Path $ifBase -EA SilentlyContinue)){
            $ifp=$iface.PSPath;if($null -eq $ifp){continue}
            $d=Get-ItemProperty -Path $ifp -Name 'DhcpIPAddress' -EA SilentlyContinue;$s=Get-ItemProperty -Path $ifp -Name 'IPAddress' -EA SilentlyContinue
            if(-not(($null -ne $d -and $d.DhcpIPAddress -ne '0.0.0.0')-or($null -ne $s -and $s.IPAddress -ne '0.0.0.0' -and $s.IPAddress -ne ''))){continue}
            if(-not $Undo){Backup-RegValue -Path $ifp -Name 'TcpAckFrequency';Backup-RegValue -Path $ifp -Name 'TCPNoDelay';Set-RegDWord -Path $ifp -Name 'TcpAckFrequency' -Value 1;Set-RegDWord -Path $ifp -Name 'TCPNoDelay' -Value 1}
            else{Restore-RegValue -Path $ifp -Name 'TcpAckFrequency' -Type 'DWord';Restore-RegValue -Path $ifp -Name 'TCPNoDelay' -Type 'DWord'}
            $nc++
        }
        Write-Host "  OK: Nagle $(if($Undo){'restored'}else{'applied'}) on $nc NIC(s)";$ok++
    }else{Write-Host '  WARN: Interfaces key not found';$warn++}
}catch{Write-Host "  ERROR: Nagle -- $($_.Exception.Message)";$err++}

# =============================================================================
# ---- ADVANCED TIER (embedded) -----------------------------------------------
# =============================================================================

Write-Host '-- [07/20] Core Parking'
try{
    if(-not $hasPowercfg){Write-Host '  SKIP';$warn++}
    elseif(-not $Undo){
        & powercfg -setacvalueindex SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 100 2>&1|Out-Null
        & powercfg -setacvalueindex SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 bc5038f7-23e0-4960-96da-33abaf5935ec 100 2>&1|Out-Null
        if(-not $isLaptop){& powercfg -setdcvalueindex SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 100 2>&1|Out-Null}
        & powercfg -setactive SCHEME_CURRENT 2>&1|Out-Null;Write-Host "  OK: Cores unparked$(if($isLaptop){' (AC only)'})";$ok++
    }else{
        & powercfg -setacvalueindex SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 50 2>&1|Out-Null
        & powercfg -setdcvalueindex SCHEME_CURRENT 54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 50 2>&1|Out-Null
        & powercfg -setactive SCHEME_CURRENT 2>&1|Out-Null;Write-Host '  OK: Core parking restored';$ok++
    }
}catch{Write-Host "  ERROR: CoreParking -- $($_.Exception.Message)";$err++}

Write-Host '-- [08/20] Pagefile (fixed size)'
try{
    $pfMB=[math]::Min($ramMB,8192);$pfP='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    if(-not $Undo){Backup-RegValue -Path $pfP -Name 'PagingFiles';Set-RegString -Path $pfP -Name 'PagingFiles' -Value "C:\pagefile.sys $pfMB $pfMB";Write-Host "  OK: Fixed ${pfMB}MB";$ok++}
    else{Restore-RegValue -Path $pfP -Name 'PagingFiles' -Type 'MultiString';Write-Host '  OK: Restored';$ok++}
}catch{Write-Host "  ERROR: Pagefile -- $($_.Exception.Message)";$err++}

Write-Host '-- [09/20] Hibernate (workstation only)'
try{
    if($isServer){Write-Host '  SKIP: SERVER';$warn++}
    elseif(-not $hasPowercfg){Write-Host '  SKIP: powercfg missing';$warn++}
    elseif($isLaptop){Write-Host '  SKIP: LAPTOP -- hibernate preserved';$warn++}
    elseif(-not $Undo){& powercfg /h off 2>&1|Out-Null;Write-Host '  OK: Disabled';$ok++}
    else{& powercfg /h on 2>&1|Out-Null;Write-Host '  OK: Re-enabled';$ok++}
}catch{Write-Host "  ERROR: Hibernate -- $($_.Exception.Message)";$err++}

Write-Host '-- [10/20] C-State cap at C1'
try{
    if(-not $hasPowercfg){Write-Host '  SKIP';$warn++}
    elseif(-not $Undo){
        & powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR IdleDemoteThreshold 0 2>&1|Out-Null
        & powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR IdlePromoteThreshold 0 2>&1|Out-Null
        if(-not $isLaptop){& powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR IdleDemoteThreshold 0 2>&1|Out-Null;& powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR IdlePromoteThreshold 0 2>&1|Out-Null}
        & powercfg -setactive SCHEME_CURRENT 2>&1|Out-Null;Write-Host "  OK: C1 cap$(if($isLaptop){' (AC only)'})";$ok++
    }else{& powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR IdleDemoteThreshold 40 2>&1|Out-Null;& powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR IdlePromoteThreshold 60 2>&1|Out-Null;& powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR IdleDemoteThreshold 40 2>&1|Out-Null;& powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR IdlePromoteThreshold 60 2>&1|Out-Null;& powercfg -setactive SCHEME_CURRENT 2>&1|Out-Null;Write-Host '  OK: Restored';$ok++}
}catch{Write-Host "  ERROR: CState -- $($_.Exception.Message)";$err++}

Write-Host '-- [11/20] CPU tuning (AMD CPPC / Intel Hybrid)'
try{
    if($isAMD){
        $cp='HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\be337238-0d82-4146-a960-4f3749d470c7'
        $cpp='HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\36687f9e-e3a5-4dbf-b1dc-15eb381c6863'
        if(-not $Undo){if(Test-Path $cp){Backup-RegValue -Path $cp -Name 'ACSettingIndex';Set-RegDWord -Path $cp -Name 'ACSettingIndex' -Value 2};if(Test-Path $cpp){Backup-RegValue -Path $cpp -Name 'ACSettingIndex';Set-RegDWord -Path $cpp -Name 'ACSettingIndex' -Value 1};if($hasPowercfg){& powercfg -setactive SCHEME_CURRENT 2>&1|Out-Null};Write-Host '  OK: AMD CPPC=2';$ok++}
        else{if(Test-Path $cp){Restore-RegValue -Path $cp -Name 'ACSettingIndex' -Type 'DWord'};if(Test-Path $cpp){Restore-RegValue -Path $cpp -Name 'ACSettingIndex' -Type 'DWord'};if($hasPowercfg){& powercfg -setactive SCHEME_CURRENT 2>&1|Out-Null};Write-Host '  OK: Restored';$ok++}
    }elseif($isIntel){
        $hp='HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\2bfc2888-6ea5-4c7b-a0c1-8b41b09da77a'
        if(Test-Path $hp){if(-not $Undo){Backup-RegValue -Path $hp -Name 'ACSettingIndex';Set-RegDWord -Path $hp -Name 'ACSettingIndex' -Value 0;if($hasPowercfg){& powercfg -setactive SCHEME_CURRENT 2>&1|Out-Null};Write-Host '  OK: Intel Heterogeneous=0';$ok++}else{Restore-RegValue -Path $hp -Name 'ACSettingIndex' -Type 'DWord';if($hasPowercfg){& powercfg -setactive SCHEME_CURRENT 2>&1|Out-Null};Write-Host '  OK: Restored';$ok++}}
        else{Write-Host '  SKIP: Non-hybrid Intel';$warn++}
    }else{Write-Host '  SKIP: Unknown CPU';$warn++}
}catch{Write-Host "  ERROR: CPUTuning -- $($_.Exception.Message)";$err++}

Write-Host '-- [12/20] HAGS'
try{$gp='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers';if(-not $Undo){Backup-RegValue -Path $gp -Name 'HwSchMode';Set-RegDWord -Path $gp -Name 'HwSchMode' -Value 2;$rebootNeeded=$true;Write-Host '  OK: HwSchMode=2';$ok++}else{Restore-RegValue -Path $gp -Name 'HwSchMode' -Type 'DWord';Write-Host '  OK: Restored';$ok++}}catch{Write-Host "  ERROR: HAGS -- $($_.Exception.Message)";$err++}

Write-Host '-- [13/20] RSS Core Steering'
try{
    if($logCount -lt 4){Write-Host '  SKIP: <4 cores';$warn++}
    elseif($hasNetAdapterRss){
        $nics=Get-NetAdapter -Physical -EA SilentlyContinue|Where-Object{$_.Status -eq 'Up'};$nc=0
        foreach($nic in $nics){try{$rss=Get-NetAdapterRss -Name $nic.Name -EA SilentlyContinue;if($null -eq $rss){continue};if(-not $Undo){Ensure-BackupRoot;New-ItemProperty -Path $BackupRoot -Name "RSS_$($nic.Name)_BPN" -Value $rss.BaseProcessorNumber -Force -EA SilentlyContinue|Out-Null;Set-NetAdapterRss -Name $nic.Name -BaseProcessorNumber 2 -EA SilentlyContinue}else{$b=Get-ItemProperty -Path $BackupRoot -Name "RSS_$($nic.Name)_BPN" -EA SilentlyContinue;Set-NetAdapterRss -Name $nic.Name -BaseProcessorNumber (if($null -ne $b){$b."RSS_$($nic.Name)_BPN"}else{0}) -EA SilentlyContinue};$nc++}catch{}}
        Write-Host "  OK: RSS cmdlet -- $nc NIC(s)";$ok++
    }else{
        $ndisBase='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}';$nc=0
        foreach($a in(Get-ChildItem -Path $ndisBase -EA SilentlyContinue|Where-Object{$_.PSChildName -match '^\d{4}$'})){
            $desc=(Get-ItemProperty -Path $a.PSPath -Name 'DriverDesc' -EA SilentlyContinue).DriverDesc
            if([string]::IsNullOrEmpty($desc)-or $desc -match 'WAN|Miniport|Loopback|Virtual|Hyper-V|TAP|Tunnel|Npcap|VMware'){continue}
            if(-not $Undo){Backup-RegValue -Path $a.PSPath -Name 'RssBaseProcNumber';Set-RegDWord -Path $a.PSPath -Name 'RssBaseProcNumber' -Value 2}
            else{Restore-RegValue -Path $a.PSPath -Name 'RssBaseProcNumber' -Type 'DWord'}
            $nc++
        }
        Write-Host "  OK: RSS registry fallback -- $nc adapter(s)";$ok++
    }
}catch{Write-Host "  ERROR: RSS -- $($_.Exception.Message)";$err++}

Write-Host '-- [14/20] BypassIO (Win11 22H2+)'
try{
    if(-not $isWin11 -or $build -lt 22621){Write-Host '  SKIP: Win11 22H2+ required';$warn++}
    elseif(-not $hasFsutil){Write-Host '  SKIP: fsutil missing';$warn++}
    else{
        $vols=Get-WmiObject Win32_Volume -EA SilentlyContinue|Where-Object{$_.DriveType -eq 3 -and $null -ne $_.DriveLetter};$dc=0
        foreach($v in $vols){
            $letter=$v.DriveLetter.TrimEnd('\');$bl=$false
            try{$enc=Get-WmiObject -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' -Class Win32_EncryptableVolume -Filter "DriveLetter='$letter'" -EA SilentlyContinue;if($null -ne $enc -and $enc.ProtectionStatus -eq 1){$bl=$true}}catch{$svc=Get-Service -Name 'fvevol' -EA SilentlyContinue;if($null -ne $svc -and $svc.Status -eq 'Running'){$bl=$true}}
            if($bl){Write-Host "  SKIP ${letter}: BitLocker";continue}
            if(-not $Undo){& fsutil bypassio enable $letter 2>&1|Out-Null}else{& fsutil bypassio disable $letter 2>&1|Out-Null}
            $dc++
        }
        Write-Host "  OK: BypassIO $(if($Undo){'off'}else{'on'}) on $dc volume(s)";$ok++
    }
}catch{Write-Host "  ERROR: BypassIO -- $($_.Exception.Message)";$err++}

Write-Host '-- [15/20] Large Pages (SeLockMemoryPrivilege)'
try{
    $admSid='*S-1-5-32-544'
    if($hasSecedit){
        $exe="$env:SystemRoot\System32\secedit.exe";$inf="$env:SystemRoot\Temp\ppm_lp.inf";$db="$env:SystemRoot\Temp\ppm_lp.sdb";$log="$env:SystemRoot\Temp\ppm_lp.log"
        if(-not $Undo){
            & $exe /export /cfg $inf /quiet 2>&1|Out-Null
            if(Test-Path $inf){$c=[System.IO.File]::ReadAllText($inf);$line=[string]($c -split "`n"|Where-Object{$_ -match 'SeLockMemoryPrivilege'}|Select-Object -First 1);Ensure-BackupRoot;New-ItemProperty -Path $BackupRoot -Name 'LargePages_OrigLine' -Value $line -Force -EA SilentlyContinue|Out-Null
                if($line -match [regex]::Escape($admSid)){Write-Host '  SKIP: Already granted';$ok++}
                else{$nl=if([string]::IsNullOrWhiteSpace($line)){"SeLockMemoryPrivilege = $admSid"}else{$line.TrimEnd()+","+$admSid};[System.IO.File]::WriteAllText($inf,($c -replace [regex]::Escape($line),$nl));& $exe /configure /db $db /cfg $inf /log $log /quiet 2>&1|Out-Null;Write-Host '  OK: Granted (secedit)';$ok++}
            }else{Write-Host '  WARN: secedit export failed';$warn++}
        }else{
            & $exe /export /cfg $inf /quiet 2>&1|Out-Null
            if(Test-Path $inf){$backed=Get-ItemProperty -Path $BackupRoot -Name 'LargePages_OrigLine' -EA SilentlyContinue;if($null -ne $backed -and -not [string]::IsNullOrEmpty($backed.LargePages_OrigLine)){$c=[System.IO.File]::ReadAllText($inf);$cur=[string]($c -split "`n"|Where-Object{$_ -match 'SeLockMemoryPrivilege'}|Select-Object -First 1);[System.IO.File]::WriteAllText($inf,($c -replace [regex]::Escape($cur),$backed.LargePages_OrigLine));& $exe /configure /db $db /cfg $inf /log $log /quiet 2>&1|Out-Null;Write-Host '  OK: Restored';$ok++}else{Write-Host '  WARN: No backup';$warn++}}
        }
        Remove-Item $inf,$db,$log -EA SilentlyContinue
    }else{
        if(-not $Undo){try{Add-Type -TypeDefinition $lsaSource -EA Stop;$r=[PPMLsa]::Grant('S-1-5-32-544','SeLockMemoryPrivilege');if($r -eq 0){Write-Host '  OK: Granted (LSA API)';$ok++}else{Write-Host "  WARN: LSA API $r";$warn++}}catch{Write-Host "  WARN: LSA fallback failed";$warn++}}
        else{Write-Host '  INFO: secedit unavailable -- privilege persists';$warn++}
    }
}catch{Write-Host "  ERROR: LargePages -- $($_.Exception.Message)";$err++}

Write-Host '-- [16/20] SSD TRIM'
try{
    if(-not $Undo){
        $vols=Get-WmiObject Win32_Volume -EA SilentlyContinue|Where-Object{$_.DriveType -eq 3 -and $null -ne $_.DriveLetter};$tc=0
        foreach($v in $vols){$drove=$v.DriveLetter.TrimEnd('\')[0];if($hasOptimizeVol){try{Optimize-Volume -DriveLetter $drove -ReTrim -EA SilentlyContinue;$tc++}catch{}}else{$def=Get-Command defrag.exe -EA SilentlyContinue;if($null -ne $def){& defrag.exe "${drove}:" /X /U 2>&1|Out-Null;$tc++}}}
        Write-Host "  OK: TRIM on $tc volume(s)";$ok++
    }else{Write-Host '  SKIP: One-directional';$ok++}
}catch{Write-Host "  ERROR: SSDTrim -- $($_.Exception.Message)";$err++}

# =============================================================================
# ---- EXPERIMENTAL TIER ------------------------------------------------------
# =============================================================================

# 17 -- Anti-AI
Write-Host '-- [17/20] Anti-AI (Copilot, Recall, AI search, advertising ID)'
try{
    $policies=@(
        @{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot';         N='TurnOffWindowsCopilot';     V=1},
        @{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';              N='DisableAIDataAnalysis';     V=1},
        @{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI';              N='TurnOffSavingSnapshots';    V=1},
        @{P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; N='AllowTelemetry';    V=0},
        @{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';         N='AllowTelemetry';            V=0},
        @{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsSearch';          N='AllowSearchHighlights';     V=0},
        @{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsSearch';          N='EnableDynamicContentInWSB'; V=0},
        @{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System';                 N='EnableActivityFeed';        V=0},
        @{P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo';        N='DisabledByGroupPolicy';     V=1}
    )
    if(-not $Undo){foreach($pol in $policies){Backup-RegValue -Path $pol.P -Name $pol.N;Set-RegDWord -Path $pol.P -Name $pol.N -Value $pol.V};Write-Host "  OK: $($policies.Count) Anti-AI keys applied";$ok++}
    else{foreach($pol in $policies){Restore-RegValue -Path $pol.P -Name $pol.N -Type 'DWord'};Write-Host '  OK: Restored';$ok++}
}catch{Write-Host "  ERROR: AntiAI -- $($_.Exception.Message)";$err++}

# 18 -- Windows Search Indexer
Write-Host '-- [18/20] Windows Search Indexer (WSearch) disable'
try{
    if(-not $Undo){
        $svc=Get-Service -Name 'WSearch' -EA SilentlyContinue
        if($null -ne $svc){Ensure-BackupRoot;New-ItemProperty -Path $BackupRoot -Name 'WSearch_StartType' -Value $svc.StartType.value__ -Force -EA SilentlyContinue|Out-Null;Stop-Service -Name 'WSearch' -Force -EA SilentlyContinue;Set-Service -Name 'WSearch' -StartupType Disabled -EA SilentlyContinue;Write-Host '  OK: WSearch stopped + disabled';$ok++}
        else{Write-Host '  SKIP: WSearch not found';$warn++}
    }else{
        $b=Get-ItemProperty -Path $BackupRoot -Name 'WSearch_StartType' -EA SilentlyContinue
        $st=if($null -ne $b){$b.WSearch_StartType}else{2};$smap=@{1='Manual';2='Automatic';3='Disabled';4='AutomaticDelayedStart'};$sn=$smap[[int]$st];if($null -eq $sn){$sn='Automatic'}
        Set-Service -Name 'WSearch' -StartupType $sn -EA SilentlyContinue;Start-Service -Name 'WSearch' -EA SilentlyContinue;Write-Host "  OK: WSearch restored to $sn";$ok++
    }
}catch{Write-Host "  ERROR: WSearch -- $($_.Exception.Message)";$err++}

# 19 -- Kernel Memory Suite
Write-Host '-- [19/20] Kernel memory suite (IoPageLock + SvcHostSplit + LargeSystemCache)'
try{
    $mp='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $sc='HKLM:\SYSTEM\CurrentControlSet\Control'
    if(-not $Undo){
        Backup-RegValue -Path $mp -Name 'IoPageLockLimit';Backup-RegValue -Path $mp -Name 'LargeSystemCache';Backup-RegValue -Path $sc -Name 'SvcHostSplitThresholdInKB'
        $ioMB=[math]::Min([math]::Round($ramMB*0.25,0),2047)
        Set-RegDWord -Path $mp -Name 'IoPageLockLimit' -Value ($ioMB*1MB)
        Set-RegDWord -Path $mp -Name 'LargeSystemCache' -Value 0
        $splitKB=$ramMB*1024
        New-ItemProperty -Path $sc -Name 'SvcHostSplitThresholdInKB' -Value $splitKB -PropertyType QWord -Force -EA SilentlyContinue|Out-Null
        Write-Host "  OK: IoPageLock=${ioMB}MB LargeSystemCache=0 SvcHostSplit=${splitKB}KB";$ok++
    }else{
        Restore-RegValue -Path $mp -Name 'IoPageLockLimit'            -Type 'DWord'
        Restore-RegValue -Path $mp -Name 'LargeSystemCache'           -Type 'DWord'
        Restore-RegValue -Path $sc -Name 'SvcHostSplitThresholdInKB'  -Type 'QWord'
        Write-Host '  OK: Kernel memory restored';$ok++
    }
}catch{Write-Host "  ERROR: KernelMemory -- $($_.Exception.Message)";$err++}

# =============================================================================
# 20 -- IFEO PRIORITY BOOST + JUNK CLEANUP
# =============================================================================
Write-Host '-- [20/20] IFEO Priority Boost + Junk Cleanup'
try{
    $CPU_ABOVE=5;$IO_HIGH=3;$SENTINEL=0xFF
    $ifeoBase='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    $ifeoBack="$BackupRoot\IFEO"
    $targetExes=@(
        'chrome.exe','msedge.exe','brave.exe','vivaldi.exe','opera.exe','chromium.exe',
        'firefox.exe','waterfox.exe','librewolf.exe',
        'WINWORD.EXE','EXCEL.EXE','POWERPNT.EXE','OUTLOOK.EXE','ONENOTE.EXE',
        'MSACCESS.EXE','MSPUB.EXE','VISIO.EXE','TEAMS.EXE','ms-teams.exe',
        'QBW32.exe','QBW64.exe','QBDBMgrN.exe','qbupdate.exe',
        'acad.exe','Revit.exe','Inventor.exe','3dsmax.exe','maya.exe',
        'navisworks.exe','fusion360.exe','motionbuilder.exe','mudbox.exe','recap.exe','vred.exe'
    )
    if(-not(Test-Path $ifeoBack)){New-Item -Path $ifeoBack -Force -EA SilentlyContinue|Out-Null}
    $iok=0;$ierr=0
    foreach($exe in $targetExes){
        $pk="$ifeoBase\$exe\PerfOptions"
        if(-not $Undo){
            $eCpu=(Get-ItemProperty -Path $pk -Name 'CpuPriorityClass' -EA SilentlyContinue).CpuPriorityClass;$eIo=(Get-ItemProperty -Path $pk -Name 'IoPriority' -EA SilentlyContinue).IoPriority
            New-ItemProperty -Path $ifeoBack -Name "${exe}_Cpu" -Value(if($null -ne $eCpu){$eCpu}else{$SENTINEL})-Type DWord -Force -EA SilentlyContinue|Out-Null
            New-ItemProperty -Path $ifeoBack -Name "${exe}_Io"  -Value(if($null -ne $eIo){$eIo}else{$SENTINEL})  -Type DWord -Force -EA SilentlyContinue|Out-Null
            try{$regPath="HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe\PerfOptions";& reg.exe add $regPath /v CpuPriorityClass /t REG_DWORD /d $CPU_ABOVE /f 2>&1|Out-Null;& reg.exe add $regPath /v IoPriority /t REG_DWORD /d $IO_HIGH /f 2>&1|Out-Null;$iok++}catch{$ierr++}
        }else{
            try{$bCpu=(Get-ItemProperty -Path $ifeoBack -Name "${exe}_Cpu" -EA SilentlyContinue)."${exe}_Cpu";$bIo=(Get-ItemProperty -Path $ifeoBack -Name "${exe}_Io" -EA SilentlyContinue)."${exe}_Io";if(Test-Path $pk){if($null -eq $bCpu -or $bCpu -eq $SENTINEL){Remove-Item -Path $pk -Recurse -Force -EA SilentlyContinue;$parent=Split-Path $pk -Parent;$kids=Get-ChildItem -Path $parent -EA SilentlyContinue;$propList=@(Get-ItemProperty -Path $parent -EA SilentlyContinue|Get-Member -MemberType NoteProperty -EA SilentlyContinue|Where-Object{$_.Name -notmatch '^PS'});if((-not $kids)-and($propList.Count -eq 0)){Remove-Item -Path $parent -Recurse -Force -EA SilentlyContinue}}else{Set-ItemProperty -Path $pk -Name 'CpuPriorityClass' -Value $bCpu -Type DWord -EA SilentlyContinue;Set-ItemProperty -Path $pk -Name 'IoPriority' -Value $bIo -Type DWord -EA SilentlyContinue}};$iok++}catch{$ierr++}
        }
    }
    if($Undo){Remove-Item -Path $ifeoBack -Recurse -Force -EA SilentlyContinue}
    Write-Host "  OK: IFEO $(if($Undo){'restored'}else{'applied'}) -- $iok EXEs | $ierr errors";$ok++
}catch{Write-Host "  ERROR: IFEOBoost -- $($_.Exception.Message)";$err++}

if(-not $Undo){
    try{
        Remove-FolderContents -Path "$env:SystemRoot\Temp" -MinAgeMins 60
        Remove-FolderContents -Path "$env:SystemRoot\SoftwareDistribution\Download"
        foreach($lp in @("$env:SystemRoot\Logs\CBS","$env:SystemRoot\Logs\DISM")){Remove-FolderContents -Path $lp}
        foreach($wp in @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive","$env:ProgramData\Microsoft\Windows\WER\ReportQueue")){Remove-FolderContents -Path $wp}
        Remove-FolderContents -Path "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
        try{$doCmd=Get-Command 'Delete-DeliveryOptimizationCache' -EA SilentlyContinue;if($doCmd){Delete-DeliveryOptimizationCache -Force -EA SilentlyContinue|Out-Null}}catch{}
        if(-not $isServer){foreach($p in @("$env:SystemRoot\ServiceProfiles\LocalService\AppData\Local\FontCache","$env:SystemRoot\System32\FNTCACHE.DAT")){if(Test-Path $p){try{Remove-Item -LiteralPath $p -Recurse -Force -EA SilentlyContinue}catch{}}}}
        $profKeys=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -EA SilentlyContinue|Where-Object{$_.PSChildName -match 'S-1-5-21-(\d+-?){4}$|S-1-12-1-(\d+-?){4}$'}
        foreach($prof in $profKeys){
            $pp=$prof.ProfileImagePath;if([string]::IsNullOrEmpty($pp)-or-not(Test-Path $pp)){continue}
            Remove-FolderContents -Path "$pp\AppData\Local\Temp" -MinAgeMins 60
            $tp="$pp\AppData\Local\Microsoft\Windows\Explorer";if(Test-Path $tp){Get-ChildItem -Path $tp -Filter 'thumbcache_*.db' -Force -EA SilentlyContinue|ForEach-Object{try{Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue}catch{}}}
            Remove-FolderContents -Path "$pp\AppData\Local\Microsoft\Windows\WER"
            $ta=if($isServer){120}else{0}
            foreach($tc in @("$pp\AppData\Roaming\Microsoft\Teams\Cache","$pp\AppData\Roaming\Microsoft\Teams\blob_storage","$pp\AppData\Roaming\Microsoft\Teams\GPUCache")){Remove-FolderContents -Path $tc -MinAgeMins $ta}
        }
        try{$rc=Get-Command 'Clear-RecycleBin' -EA SilentlyContinue;if($rc){Clear-RecycleBin -Force -EA SilentlyContinue}else{$shell=New-Object -ComObject Shell.Application;$shell.Namespace(0xA).Items()|ForEach-Object{$_.InvokeVerb('delete')}}}catch{}
        Write-Host '  OK: Junk cleanup complete'
    }catch{Write-Host "  ERROR: Cleanup -- $($_.Exception.Message)";$err++}
}else{Write-Host '  SKIP: Cleanup not reversed'}

# =============================================================================
# RESULT
# =============================================================================
Write-Host ''
Write-Host "=== PPM RMM Experimental $action complete: ok=$ok warn=$warn errors=$err ==="
if($rebootNeeded -and -not $Undo){Write-Host 'NOTE: Reboot required (HAGS, WSearch, kernel memory).'}

$status=if($err -gt 0){"FAIL ok=$ok warn=$warn err=$err $(Get-Date -Format 'yyyy-MM-dd')"}else{"PASS ok=$ok warn=$warn $(Get-Date -Format 'yyyy-MM-dd')"}
Set-PPMRMMUDF -Slot $UDFSlotN -Value "PPM-Exp $action $status"

if($Undo -and $err -eq 0){Remove-Item -Path $BackupRoot -Recurse -Force -EA SilentlyContinue;Write-Host 'Backup key removed.'}
if($err -gt 0){Write-Host "ERROR: $err step(s) failed.";exit 1}
Write-Host 'SUCCESS: PPM Experimental complete. Reboot to finish.'
exit 0
