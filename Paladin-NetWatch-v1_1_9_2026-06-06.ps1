#Requires -Version 3.0
param([switch]$GUIMode)
# =============================================================================
# Paladin NetWatch [WIN]
# Datto RMM Component | Script | PowerShell 5.1 | WPF
# Version: 1.1.9
#
# Real-time network diagnostics dashboard.
# Runs locally or via Datto RMM on a client machine.
#
# DUAL LAUNCH:
#   Local : powershell.exe -STA -File Paladin-NetWatch-v1_0_0.ps1
#   Datto : Deploy as component -- launches GUI on user desktop via APM v3 (CreateProcessAsUserW)
#
# TABS:
#   Overview     -- Adapters, IP, gateway, DNS, bytes/sec, health badges
#   Connections  -- Live TCP table with process name, state, remote IP
#   DNS Cache    -- Local DNS cache, TTL, suspicious flags
#   Firewall     -- Profile state, rule counts, recent blocks
#   Diagnostics  -- On-demand ping/DNS/HTTP/tracert probes
#
# INPUT VARIABLES (Datto):
#   UDFSlot  String  UDF slot for exit summary (default: 31)
#
# KI/KW ENFORCED:
#   KI-139/KW-061 : -STA mandatory
#   KI-140/KW-071 : $local capture + .GetNewClosure() in all loops
#   KI-141        : .GetNewClosure() on all DispatcherTimer Add_Tick
#   KI-142/KW-106 : $env:SystemRoot resolved on UI thread, passed via $sync
#   KI-144/KW-107 : | Out-Null all uncaptured bool-return calls
#   KW-036        : null-check every FindName immediately
#   KW-033        : cast WMI properties on first access
#   KW-089        : no XML comments in XAML
# =============================================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer   = '1.1.9'
$BaseDir     = 'C:\ProgramData\Paladin\NetWatch'
$LogFile     = "$BaseDir\NetWatch.log"
$PsExe       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$UDFSlot     = if ($env:UDFSlot -match '^\d+$') { [int]$env:UDFSlot } else { 31 }
$SiteName    = if ($env:CS_PROFILE_NAME) { $env:CS_PROFILE_NAME } else { 'UNKNOWN' }
$MachineName = $env:COMPUTERNAME

# CrowdSec CTI
$CTIBase    = 'https://cti.api.crowdsec.net/v2/smoke'
$CTIKeyReg  = 'HKLM:\SOFTWARE\Paladin\NetWatch'
$CTIKeyName = 'CTIKey'
$CTICache   = [hashtable]::Synchronized(@{})  # IP -> @{Time; Data} -- 1hr TTL

# Suspicious port ranges (outbound to non-standard ports)
$SuspiciousPorts = @(4444,4445,1337,31337,8080,8888,9001,9030,6667,6668,6669)
$TrustedPorts    = @(80,443,53,123,67,68,3389,445,139,135,5985,5986,25,587,465,143,993,110,995)

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
        Add-Content -Path $LogFile -Value $line -EA SilentlyContinue
    } catch {}
}

function Set-DattoUDF {
    param([int]$Slot, [string]$Value)
    $trimmed = if ($Value.Length -gt 255) { $Value.Substring(0,255) } else { $Value }
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' `
            -Name "Custom$Slot" -PropertyType String -Value $trimmed `
            -Force -EA Stop | Out-Null
    } catch {}
}

# =============================================================================
# SYSTEM LAUNCH (Datto SYSTEM context -> APM v3 CreateProcessAsUserW -> user desktop)
# =============================================================================

if (-not $GUIMode) {

    if (-not (Test-Path $BaseDir)) { New-Item $BaseDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = $identity.IsSystem
    Write-Log "Paladin NetWatch v$ScriptVer | Site: $SiteName | Machine: $MachineName"
    Write-Log "Context: $($identity.Name) | IsSystem: $isSystem"

    # -------------------------------------------------------------------------
    # NPCAP PREREQUISITE CHECK + INSTALL
    # -------------------------------------------------------------------------
    $npcapDLL  = 'C:\Windows\System32\Npcap\wpcap.dll'
    $npcapKey  = 'HKLM:\SOFTWARE\Npcap'
    $npcapURL  = 'https://npcap.com/dist/npcap-1.88.exe'
    $npcapDest = "$BaseDir\npcap-installer.exe"
    $npcapInstalled = (Test-Path $npcapDLL) -or (Test-Path $npcapKey)

    if (-not $npcapInstalled) {
        Write-Log 'Npcap not detected -- attempting silent install via winget/choco...'

        # Try winget (silent, no UI, runs fine as SYSTEM on Win10 1709+)
        $npcapViaPkg = $false
        try {
            $wg = Get-Command winget.exe -EA SilentlyContinue
            if ($null -ne $wg) {
                Write-Log 'Trying winget install npcap...'
                $wgResult = & winget.exe install --id Npcap.Npcap --silent --accept-source-agreements --accept-package-agreements 2>&1
                Write-Log "winget result: $($wgResult -join ' ')"
                Start-Sleep 5
                if ((Test-Path $npcapDLL) -or (Test-Path $npcapKey)) {
                    Write-Log 'Npcap installed via winget'
                    $npcapInstalled = $true; $npcapViaPkg = $true
                }
            }
        } catch { Write-Log "winget attempt failed: $($_.Exception.Message)" 'WARN' }

        # Try chocolatey if winget failed and choco is present
        if (-not $npcapViaPkg) {
            try {
                $choco = Get-Command choco.exe -EA SilentlyContinue
                if ($null -ne $choco) {
                    Write-Log 'Trying choco install npcap...'
                    $chocoResult = & choco.exe install npcap -y --no-progress 2>&1
                    Write-Log "choco result: $($chocoResult -join ' ')"
                    Start-Sleep 5
                    if ((Test-Path $npcapDLL) -or (Test-Path $npcapKey)) {
                        Write-Log 'Npcap installed via chocolatey'
                        $npcapInstalled = $true; $npcapViaPkg = $true
                    }
                }
            } catch { Write-Log "choco attempt failed: $($_.Exception.Message)" 'WARN' }
        }

        # Fallback: download installer and launch on user desktop
        if (-not $npcapViaPkg) {
            Write-Log 'Package managers unavailable or failed -- downloading for user-side install...'
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
                (New-Object System.Net.WebClient).DownloadFile($npcapURL, $npcapDest)
                Write-Log "Npcap installer downloaded: $npcapDest"
            } catch {
                Write-Log "WARN: Npcap download failed: $($_.Exception.Message) -- packet capture features will be unavailable" 'WARN'
                $npcapDest = $null
            }
        } else {
            $npcapDest = $null  # no interactive install needed
        }
    } else {
        # Check version
        try {
            $ver = (Get-ItemProperty $npcapKey -EA SilentlyContinue).Version
            Write-Log "Npcap already installed: version $ver"
        } catch { Write-Log 'Npcap already installed' }
    }
    # Pass Npcap status to GUI via a marker file
    $npcapFlag = "$BaseDir\npcap.present"
    if ($npcapInstalled -or (Test-Path $npcapDLL) -or (Test-Path $npcapKey)) {
        [System.IO.File]::WriteAllText($npcapFlag, '1', [System.Text.Encoding]::ASCII)
    } else {
        Remove-Item $npcapFlag -Force -EA SilentlyContinue
    }

    $selfDest = "$BaseDir\Paladin-NetWatch.ps1"
    try { Copy-Item -LiteralPath $PSCommandPath -Destination $selfDest -Force -EA Stop }
    catch { Write-Log "ERROR staging self: $($_.Exception.Message)" 'ERROR'; exit 1 }

    $psArgs = "-STA -ExecutionPolicy Bypass -File `"$selfDest`" -GUIMode"

    if ($isSystem) {
        # SYSTEM launcher -- exact Orchestrator v1.0.22 pattern (production-confirmed Datto)
        # PSTypeName guard prevents re-compile hang; high integrity token required for WPF
        if (-not ([System.Management.Automation.PSTypeName]'NWWTS').Type) {
            $nwCSharp = @'
using System;
using System.Runtime.InteropServices;
using System.ComponentModel;
public class NWWTS {
  const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
  const uint TOKEN_QUERY             = 0x0008;
  const uint TOKEN_DUPLICATE         = 0x0002;
  const uint TOKEN_ALL_ACCESS        = 0x000F01FF;
  const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
  const uint NORMAL_PRIORITY_CLASS      = 0x00000020;
  const int  SE_PRIVILEGE_ENABLED       = 2;
  const int  TokenIntegrityLevel        = 25;
  const int  SECURITY_MANDATORY_HIGH_RID = 0x3000;
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
  public struct SI {
    public int cb; public string lpReserved,lpDesktop,lpTitle;
    public uint dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags;
    public short wShowWindow,cbReserved2;
    public IntPtr lpReserved2,hStdInput,hStdOutput,hStdError;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct PI { public IntPtr hp,ht; public uint pid,tid; }
  [StructLayout(LayoutKind.Sequential)] struct WSI { public uint sid; public IntPtr wsn; public int st; }
  [StructLayout(LayoutKind.Sequential)] struct LUID { public uint lo; public int hi; }
  [StructLayout(LayoutKind.Sequential)] struct LUIDA { public LUID luid; public uint attr; }
  [StructLayout(LayoutKind.Sequential)] struct TOKPRIVS { public uint count; public LUIDA priv; }
  [StructLayout(LayoutKind.Sequential)] struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }
  [StructLayout(LayoutKind.Sequential)] struct TOKEN_MANDATORY_LABEL { public SID_AND_ATTRIBUTES Label; }
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr h,uint acc,out IntPtr t);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr t,bool d,ref TOKPRIVS n,uint l,IntPtr p,IntPtr r);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool LookupPrivilegeValue(string s,string n,out LUID l);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool DuplicateTokenEx(IntPtr h,uint acc,IntPtr a,int imp,int type,out IntPtr nt);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool ImpersonateLoggedOnUser(IntPtr t);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool RevertToSelf();
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool SetTokenInformation(IntPtr t,int cls,IntPtr info,uint len);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool AllocateAndInitializeSid(IntPtr auth,byte cnt,uint s0,uint s1,uint s2,uint s3,uint s4,uint s5,uint s6,uint s7,out IntPtr sid);
  [DllImport("advapi32.dll")] static extern IntPtr FreeSid(IntPtr sid);
  [DllImport("advapi32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool CreateProcessAsUserW(IntPtr t,string app,string cmd,IntPtr pa,IntPtr ta,bool ih,uint fl,IntPtr env,string dir,ref SI si,out PI pi);
  [DllImport("wtsapi32.dll",SetLastError=true)] static extern bool WTSEnumerateSessions(IntPtr h,int r,int v,ref IntPtr pp,ref int pc);
  [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr p);
  [DllImport("wtsapi32.dll",SetLastError=true)] static extern bool WTSQueryUserToken(uint s,out IntPtr t);
  [DllImport("userenv.dll",SetLastError=true)] static extern bool CreateEnvironmentBlock(ref IntPtr e,IntPtr t,bool i);
  [DllImport("userenv.dll",SetLastError=true)] static extern bool DestroyEnvironmentBlock(IntPtr e);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll",SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  static bool EnablePriv(IntPtr tok,string name) {
    LUID l; if (!LookupPrivilegeValue(null,name,out l)) return false;
    var tp=new TOKPRIVS(); tp.count=1; tp.priv.luid=l; tp.priv.attr=(uint)SE_PRIVILEGE_ENABLED;
    return AdjustTokenPrivileges(tok,false,ref tp,0,IntPtr.Zero,IntPtr.Zero);
  }
  public static int FindActiveSession() {
    IntPtr p=IntPtr.Zero; int c=0,best=-1;
    int sz=Marshal.SizeOf(typeof(WSI));
    if (!WTSEnumerateSessions(IntPtr.Zero,0,1,ref p,ref c)) return -1;
    try {
      IntPtr cur=p;
      for (int i=0;i<c;i++) {
        var s=(WSI)Marshal.PtrToStructure(cur,typeof(WSI));
        if (s.st==0 && s.sid>0) { best=(int)s.sid; break; }
        cur=new IntPtr(cur.ToInt64()+sz);
      }
    } finally { WTSFreeMemory(p); }
    return best;
  }
  public static int Launch(int sid,string exe,string args) {
    IntPtr procTok=IntPtr.Zero,userTok=IntPtr.Zero,dupTok=IntPtr.Zero;
    IntPtr env=IntPtr.Zero,intSid=IntPtr.Zero;
    bool imp=false;
    try {
      if (OpenProcessToken(GetCurrentProcess(),TOKEN_ADJUST_PRIVILEGES|TOKEN_QUERY,out procTok)) {
        EnablePriv(procTok,"SeTcbPrivilege"); CloseHandle(procTok); procTok=IntPtr.Zero;
      }
      if (!WTSQueryUserToken((uint)sid,out userTok))
        throw new Win32Exception(Marshal.GetLastWin32Error(),"WTSQueryUserToken");
      if (!DuplicateTokenEx(userTok,TOKEN_ALL_ACCESS,IntPtr.Zero,2,1,out dupTok))
        throw new Win32Exception(Marshal.GetLastWin32Error(),"DuplicateTokenEx");
      byte[] ntAuth=new byte[]{0,0,0,0,0,16};
      IntPtr ntAuthPtr=Marshal.AllocHGlobal(6); Marshal.Copy(ntAuth,0,ntAuthPtr,6);
      try {
        if (AllocateAndInitializeSid(ntAuthPtr,1,(uint)SECURITY_MANDATORY_HIGH_RID,0,0,0,0,0,0,0,out intSid)) {
          var ml=new TOKEN_MANDATORY_LABEL(); ml.Label.Sid=intSid; ml.Label.Attributes=0x00000020;
          int mlSz=Marshal.SizeOf(typeof(TOKEN_MANDATORY_LABEL));
          IntPtr mlPtr=Marshal.AllocHGlobal(mlSz);
          try { Marshal.StructureToPtr(ml,mlPtr,false); SetTokenInformation(dupTok,TokenIntegrityLevel,mlPtr,(uint)(mlSz+12)); }
          finally { Marshal.FreeHGlobal(mlPtr); }
        }
      } finally { Marshal.FreeHGlobal(ntAuthPtr); }
      string[] privs=new string[]{"SeDebugPrivilege","SeBackupPrivilege","SeRestorePrivilege",
        "SeTakeOwnershipPrivilege","SeSecurityPrivilege","SeLoadDriverPrivilege"};
      foreach (string priv in privs) EnablePriv(dupTok,priv);
      if (!ImpersonateLoggedOnUser(dupTok))
        throw new Win32Exception(Marshal.GetLastWin32Error(),"ImpersonateLoggedOnUser");
      imp=true;
      CreateEnvironmentBlock(ref env,dupTok,false);
      var si=new SI(); si.cb=Marshal.SizeOf(typeof(SI));
      si.lpDesktop="winsta0\\default"; si.dwFlags=1; si.wShowWindow=5;
      string cmd=string.IsNullOrEmpty(args)?"\""+exe+"\"":"\""+exe+"\" "+args;
      PI pi;
      if (!CreateProcessAsUserW(dupTok,null,cmd,IntPtr.Zero,IntPtr.Zero,false,
            CREATE_UNICODE_ENVIRONMENT|NORMAL_PRIORITY_CLASS,env,null,ref si,out pi))
        throw new Win32Exception(Marshal.GetLastWin32Error(),"CreateProcessAsUserW");
      CloseHandle(pi.hp); CloseHandle(pi.ht);
      return (int)pi.pid;
    } finally {
      if (imp)              RevertToSelf();
      if (intSid!=IntPtr.Zero) FreeSid(intSid);
      if (env!=IntPtr.Zero) DestroyEnvironmentBlock(env);
      if (dupTok!=IntPtr.Zero) CloseHandle(dupTok);
      if (userTok!=IntPtr.Zero) CloseHandle(userTok);
      if (procTok!=IntPtr.Zero) CloseHandle(procTok);
    }
  }
}
'@
            try {
                Add-Type -TypeDefinition $nwCSharp -Language CSharp -EA Stop
            } catch {
                Write-Log "ERROR: Add-Type failed: $($_.Exception.Message)" 'ERROR'
                Set-DattoUDF -Slot $UDFSlot -Value "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | Add-Type failed"
                exit 1
            }
        }

        $session = [NWWTS]::FindActiveSession()
        if ($session -lt 0) {
            Write-Log 'ERROR: No active user session found' 'ERROR'
            Set-DattoUDF -Slot $UDFSlot -Value "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | No user session"
            exit 1
        }
        Write-Log "Active session: $session"

        # If npcap was downloaded but not installed, launch installer on user desktop and wait
        if (-not $npcapInstalled -and -not [string]::IsNullOrEmpty($npcapDest) -and (Test-Path $npcapDest)) {
            Write-Log 'Launching Npcap installer on user desktop -- waiting for user to complete install...'
            try {
                [NWWTS]::Launch($session, $npcapDest, '') | Out-Null
            } catch {
                Write-Log "WARN: Could not launch Npcap installer on desktop: $($_.Exception.Message)" 'WARN'
            }
            # Poll up to 5 minutes for npcap to be installed
            $npcapWait = 0
            while ($npcapWait -lt 300) {
                Start-Sleep 5; $npcapWait += 5
                if ((Test-Path $npcapDLL) -or (Test-Path $npcapKey)) {
                    Write-Log 'Npcap install detected -- continuing'
                    $npcapInstalled = $true
                    [System.IO.File]::WriteAllText($npcapFlag, '1', [System.Text.Encoding]::ASCII)
                    break
                }
            }
            if (-not $npcapInstalled) {
                Write-Log 'WARN: Npcap install not detected after 5 min -- continuing anyway' 'WARN'
            }
            Remove-Item $npcapDest -Force -EA SilentlyContinue
        }

        Write-Log "Launching GUI via CreateProcessAsUserW on session $session"
        try {
            $pid2 = [NWWTS]::Launch($session, $PsExe, $psArgs)
            Write-Log "GUI launched OK: PID=$pid2 session=$session"
            exit 0
        } catch {
            Write-Log "ERROR: Launch failed: $($_.Exception.Message)" 'ERROR'
            Set-DattoUDF -Slot $UDFSlot -Value "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | $($_.Exception.Message)"
            exit 1
        }
    } else {
        # Running as elevated local admin (via BAT RunAs) -- run GUI in-process.
        # Spawning a child process via Start-Process loses elevation on the child.
        # Instead just re-dot-source this script with -GUIMode in the current elevated process.
        Write-Log "Running as elevated user -- launching GUI in current process"
        & $PsExe -STA -ExecutionPolicy Bypass -File $selfDest -GUIMode
        exit 0
    }

} # end if (-not $GUIMode)

# =============================================================================
# GUI MODE -- WPF dashboard, runs as logged-on user with -STA
# =============================================================================

if ($GUIMode) {

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms   # for Clipboard

if (-not (Test-Path $BaseDir)) { New-Item $BaseDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

# =============================================================================
# SYNC HASHTABLE (KW pattern -- UI thread owns WPF, runspace writes plain data)
# =============================================================================
$sync = [hashtable]::Synchronized(@{
    Running         = $true
    # Overview data
    Adapters        = @()
    AdapterStats    = @()
    # Connections
    Connections     = @()
    ConnLastUpdate  = ''
    # DNS
    DNSCache        = @()
    DNSLastUpdate   = ''
    # Firewall
    FWProfiles      = @()
    FWLastUpdate    = ''
    # Diagnostics results
    DiagResults     = ''
    DiagRunning     = $false
    # Status
    StatusMsg       = 'Starting...'
    LastRefresh     = ''
    ErrorMsg        = ''
    # Resolved on UI thread (KI-142)
    PsExe           = $PsExe
    BaseDir         = $BaseDir
    MachineName     = $MachineName
    SuspiciousPorts = $SuspiciousPorts
    TrustedPorts    = $TrustedPorts
    FlagCount       = 0
    NpcapAvailable  = $false
    Threats         = @()
    ThreatCount     = 0
    # Connection history for beaconing/portscan detection (ring buffer)
    ConnHistory     = [System.Collections.Generic.List[object]]::new()
})

# =============================================================================
# XAML (no XML comments -- KW-089)
# =============================================================================
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Paladin NetWatch" Width="1050" Height="680"
        WindowStartupLocation="CenterScreen" Background="#1E1E1E">
    <Window.Resources>
        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="#CCC"/>
            <Setter Property="Background" Value="#2D2D2D"/>
            <Setter Property="Padding" Value="12,4"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="#CCC"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#CCC"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#0078D4"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Padding" Value="12,5"/>
            <Setter Property="MinWidth" Value="100"/>
            <Setter Property="Margin" Value="4,2"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="#252526"/>
            <Setter Property="Foreground" Value="#CCC"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#333"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="RowBackground" Value="#252526"/>
            <Setter Property="AlternatingRowBackground" Value="#2A2A2A"/>
            <Setter Property="AutoGenerateColumns" Value="False"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="SelectionMode" Value="Single"/>
            <Setter Property="CanUserSortColumns" Value="True"/>
            <Setter Property="CanUserResizeColumns" Value="True"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#333"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style x:Key="NeonComboItemStyle" TargetType="ComboBoxItem"
               xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
            <Setter Property="Background" Value="#E8E8E8"/>
            <Setter Property="Foreground" Value="Black"/>
            <Setter Property="Padding"    Value="8,4"/>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="#C8C8C8"/>
                    <Setter Property="Foreground" Value="Black"/>
                </Trigger>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#D0D0D0"/>
                    <Setter Property="Foreground" Value="Black"/>
                    <Setter Property="FontWeight" Value="SemiBold"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground"         Value="Black"/>
            <Setter Property="BorderBrush"        Value="#999"/>
            <Setter Property="BorderThickness"    Value="1"/>
            <Setter Property="Padding"            Value="4,2"/>
            <Setter Property="ItemContainerStyle" Value="{StaticResource NeonComboItemStyle}"/>
        </Style>
        <Style TargetType="ComboBoxItem" BasedOn="{StaticResource NeonComboItemStyle}"/>
        <Style TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="4,2"/>
        </Style>
    </Window.Resources>
    <DockPanel>
        <Border DockPanel.Dock="Top" Background="#007ACC" Padding="12,6">
            <DockPanel>
                <TextBlock Text="Paladin NetWatch" FontSize="16" FontWeight="Bold"
                           Foreground="White" VerticalAlignment="Center"/>
                <TextBlock Name="txtMachine" FontSize="13" Foreground="#CCE" Margin="16,0,0,0"
                           VerticalAlignment="Center"/>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" HorizontalAlignment="Right">
                    <TextBlock Name="txtNpcap" Foreground="#AAA" FontSize="11"
                           VerticalAlignment="Center" Margin="0,0,12,0"/>
                <TextBlock Name="txtFlagCount" Foreground="#FF6B6B" FontWeight="Bold"
                               VerticalAlignment="Center" Margin="0,0,12,0"/>
                    <TextBlock Name="txtLastRefresh" Foreground="#AAA" FontSize="11"
                               VerticalAlignment="Center" Margin="0,0,12,0"/>
                    <Button Name="btnRefresh" Content="Refresh Now" MinWidth="90"/>
                    <Button Name="btnExport" Content="Export Log" Background="#555" MinWidth="90"/>
                </StackPanel>
            </DockPanel>
        </Border>
        <Border DockPanel.Dock="Bottom" Background="#252526" Padding="8,4">
            <TextBlock Name="txtStatus" Foreground="#AAA" FontSize="11"/>
        </Border>
        <TabControl Name="tabs" Background="#1E1E1E" BorderThickness="0" Margin="4">
            <TabItem Header="Overview" Name="tabOverview">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#1E1E1E">
                    <StackPanel Name="panOverview" Margin="12"/>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Connections" Name="tabConnections">
                <DockPanel Background="#1E1E1E" Margin="4">
                    <DockPanel DockPanel.Dock="Top" Margin="4,4,4,6">
                        <TextBlock Text="Filter:" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <TextBox Name="txtConnFilter" Width="200" Background="#333" Foreground="#CCC"
                                 BorderBrush="#555" Padding="4,3" VerticalAlignment="Center"/>
                        <CheckBox Name="chkEstablished" Content="Established only" Foreground="#CCC"
                                  Margin="12,0,0,0" VerticalAlignment="Center" IsChecked="True"/>
                        <CheckBox Name="chkFlagged" Content="Flagged only" Foreground="#FF6B6B"
                                  Margin="12,0,0,0" VerticalAlignment="Center"/>
                        <TextBlock Name="txtConnCount" Foreground="#AAA" Margin="16,0,0,0"
                                   VerticalAlignment="Center"/>
                    </DockPanel>
                    <DataGrid Name="dgConnections">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="PID"        Width="55"  Binding="{Binding PID}"/>
                            <DataGridTextColumn Header="Process"    Width="130" Binding="{Binding Process}"/>
                            <DataGridTextColumn Header="Local"      Width="155" Binding="{Binding Local}"/>
                            <DataGridTextColumn Header="Remote"     Width="155" Binding="{Binding Remote}"/>
                            <DataGridTextColumn Header="State"      Width="100" Binding="{Binding State}"/>
                            <DataGridTextColumn Header="Proto"      Width="55"  Binding="{Binding Proto}"/>
                            <DataGridTextColumn Header="Flag"       Width="60"  Binding="{Binding Flag}"/>
                            <DataGridTextColumn Header="Note"       Width="200" Binding="{Binding Note}"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </TabItem>
            <TabItem Header="DNS Cache" Name="tabDNS">
                <DockPanel Background="#1E1E1E" Margin="4">
                    <DockPanel DockPanel.Dock="Top" Margin="4,4,4,6">
                        <TextBlock Text="Filter:" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <TextBox Name="txtDNSFilter" Width="200" Background="#333" Foreground="#CCC"
                                 BorderBrush="#555" Padding="4,3" VerticalAlignment="Center"/>
                        <CheckBox Name="chkDNSSuspect" Content="Suspicious only" Foreground="#FF6B6B"
                                  Margin="12,0,0,0" VerticalAlignment="Center"/>
                        <Button Name="btnFlushDNS" Content="Flush DNS" Background="#555"
                                Margin="12,0,0,0" MinWidth="80"/>
                        <TextBlock Name="txtDNSCount" Foreground="#AAA" Margin="16,0,0,0"
                                   VerticalAlignment="Center"/>
                    </DockPanel>
                    <DataGrid Name="dgDNS">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Name"    Width="230" Binding="{Binding Name}"/>
                            <DataGridTextColumn Header="Type"    Width="60"  Binding="{Binding Type}"/>
                            <DataGridTextColumn Header="Data"    Width="200" Binding="{Binding Data}"/>
                            <DataGridTextColumn Header="TTL"     Width="65"  Binding="{Binding TTL}"/>
                            <DataGridTextColumn Header="Section" Width="80"  Binding="{Binding Section}"/>
                            <DataGridTextColumn Header="Flag"    Width="80"  Binding="{Binding Flag}"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </TabItem>
            <TabItem Header="Firewall" Name="tabFirewall">
                <DockPanel Background="#1E1E1E" Margin="4">
                    <StackPanel DockPanel.Dock="Top" Margin="8" Orientation="Horizontal">
                        <Button Name="btnFWDomain"  MinWidth="110" Margin="4" Padding="10,8">
                            <StackPanel>
                                <TextBlock Text="Domain" Foreground="White" FontSize="11" HorizontalAlignment="Center"/>
                                <TextBlock Name="txtFWDomain" Text="..." FontSize="14" FontWeight="Bold" HorizontalAlignment="Center"/>
                            </StackPanel>
                        </Button>
                        <Button Name="btnFWPrivate" MinWidth="110" Margin="4" Padding="10,8">
                            <StackPanel>
                                <TextBlock Text="Private" Foreground="White" FontSize="11" HorizontalAlignment="Center"/>
                                <TextBlock Name="txtFWPrivate" Text="..." FontSize="14" FontWeight="Bold" HorizontalAlignment="Center"/>
                            </StackPanel>
                        </Button>
                        <Button Name="btnFWPublic"  MinWidth="110" Margin="4" Padding="10,8">
                            <StackPanel>
                                <TextBlock Text="Public" Foreground="White" FontSize="11" HorizontalAlignment="Center"/>
                                <TextBlock Name="txtFWPublic" Text="..." FontSize="14" FontWeight="Bold" HorizontalAlignment="Center"/>
                            </StackPanel>
                        </Button>
                        <Border Background="#333" CornerRadius="4" Padding="12,6" Margin="4">
                            <StackPanel>
                                <TextBlock Text="Inbound Rules" Foreground="#AAA" FontSize="11"/>
                                <TextBlock Name="txtFWInbound" Text="..." FontSize="14" FontWeight="Bold"/>
                            </StackPanel>
                        </Border>
                        <Border Background="#333" CornerRadius="4" Padding="12,6" Margin="4">
                            <StackPanel>
                                <TextBlock Text="Outbound Rules" Foreground="#AAA" FontSize="11"/>
                                <TextBlock Name="txtFWOutbound" Text="..." FontSize="14" FontWeight="Bold"/>
                            </StackPanel>
                        </Border>
                        <StackPanel Margin="16,0,0,0" VerticalAlignment="Center" Orientation="Horizontal">
                            <Button Name="btnFWEnableAll"  Content="Enable All"  Background="#107C10" MinWidth="100"/>
                            <Button Name="btnFWDisableAll" Content="Disable All" Background="#C42B1C" MinWidth="100"/>
                        </StackPanel>
                    </StackPanel>
                    <GroupBox DockPanel.Dock="Top" Header="Add Firewall Rule" Foreground="#CCC"
                              Margin="8,4,8,4" Padding="8">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="160"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="80"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="90"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="90"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <Label Grid.Column="0"  Content="Name:"      Foreground="#CCC"/>
                            <TextBox Grid.Column="1"  Name="txtRuleName"    Background="#333" Foreground="#CCC" BorderBrush="#555" Padding="4,3" Margin="0,4,8,4"/>
                            <Label Grid.Column="2"  Content="Port:"      Foreground="#CCC"/>
                            <TextBox Grid.Column="3"  Name="txtRulePort"    Background="#333" Foreground="#CCC" BorderBrush="#555" Padding="4,3" Margin="0,4,8,4"/>
                            <Label Grid.Column="4"  Content="Protocol:"  Foreground="#CCC"/>
                            <ComboBox Grid.Column="5" Name="cmbRuleProto"   Background="#E0E0E0" Foreground="Black" Margin="0,4,8,4">
                                <ComboBoxItem Content="TCP" IsSelected="True"/>
                                <ComboBoxItem Content="UDP"/>
                                <ComboBoxItem Content="Any"/>
                            </ComboBox>
                            <Label Grid.Column="6"  Content="Direction:" Foreground="#CCC"/>
                            <ComboBox Grid.Column="7" Name="cmbRuleDir"     Background="#E0E0E0" Foreground="Black" Margin="0,4,8,4">
                                <ComboBoxItem Content="Inbound"  IsSelected="True"/>
                                <ComboBoxItem Content="Outbound"/>
                            </ComboBox>
                            <Label Grid.Column="8"  Content="Action:"    Foreground="#CCC"/>
                            <ComboBox Grid.Column="9" Name="cmbRuleAction"  Background="#E0E0E0" Foreground="Black" Margin="0,4,8,4">
                                <ComboBoxItem Content="Allow" IsSelected="True"/>
                                <ComboBoxItem Content="Block"/>
                            </ComboBox>
                            <Button Grid.Column="10" Name="btnAddRule"   Content="Add Rule" Background="#0078D4" Margin="0,4,0,4"/>
                        </Grid>
                    </GroupBox>
                    <TextBlock DockPanel.Dock="Top" Text="Recent Firewall Blocks (Event Log)" Foreground="#AAA"
                               Margin="12,4,8,4" FontSize="12"/>
                    <DataGrid Name="dgFirewall" DockPanel.Dock="Top" MaxHeight="180">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Time"       Width="130" Binding="{Binding Time}"/>
                            <DataGridTextColumn Header="Direction"  Width="80"  Binding="{Binding Direction}"/>
                            <DataGridTextColumn Header="Protocol"   Width="70"  Binding="{Binding Protocol}"/>
                            <DataGridTextColumn Header="Src IP"     Width="130" Binding="{Binding SrcIP}"/>
                            <DataGridTextColumn Header="Dst IP"     Width="130" Binding="{Binding DstIP}"/>
                            <DataGridTextColumn Header="Dst Port"   Width="80"  Binding="{Binding DstPort}"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </TabItem>
            <TabItem Header="Threats" Name="tabThreats">
                <DockPanel Background="#1E1E1E" Margin="4">
                    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="4,4,4,6">
                        <Button Name="btnSnapshot" Content="Flight Recorder Snapshot" Background="#555" MinWidth="180"/>
                        <TextBlock Name="txtThreatSummary" Foreground="#FF6B6B" FontWeight="Bold"
                                   VerticalAlignment="Center" Margin="16,0,0,0"/>
                    </StackPanel>
                    <DataGrid Name="dgThreats">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Severity"  Width="75"  Binding="{Binding Severity}"/>
                            <DataGridTextColumn Header="Type"      Width="130" Binding="{Binding Type}"/>
                            <DataGridTextColumn Header="Process"   Width="120" Binding="{Binding Process}"/>
                            <DataGridTextColumn Header="Detail"    Width="300" Binding="{Binding Detail}"/>
                            <DataGridTextColumn Header="Remote"    Width="150" Binding="{Binding Remote}"/>
                            <DataGridTextColumn Header="First Seen" Width="80" Binding="{Binding FirstSeen}"/>
                            <DataGridTextColumn Header="Count"     Width="55"  Binding="{Binding Count}"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </TabItem>

            <TabItem Header="Block List" Name="tabBlocklist">
                <DockPanel Background="#1E1E1E" Margin="4">
                    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="4,4,4,6">
                        <Button Name="btnBlockAdd"    Content="Block Selected IP"    Background="#C42B1C" MinWidth="140"/>
                        <Button Name="btnBlockAllow"  Content="Allow Selected IP"    Background="#107C10" MinWidth="140"/>
                        <Button Name="btnBlockRemove" Content="Remove Rule"          Background="#555"    MinWidth="110"/>
                        <Button Name="btnBlockApply"  Content="Apply All Rules"      Background="#0078D4" MinWidth="120"/>
                        <Button Name="btnBlockExport" Content="Export Deployer"      Background="#555"    MinWidth="120"/>
                        <TextBlock Name="txtBlockStatus" Foreground="#AAA" FontSize="11"
                                   VerticalAlignment="Center" Margin="16,0,0,0"/>
                    </StackPanel>
                    <DockPanel DockPanel.Dock="Top" Margin="4,0,4,6">
                        <Label Content="IP/Range:" Foreground="#CCC" VerticalAlignment="Center"/>
                        <TextBox Name="txtBlockIP" Width="160" Background="#333" Foreground="#CCC"
                                 BorderBrush="#555" Padding="4,3" Margin="0,0,6,0" VerticalAlignment="Center"/>
                        <Label Content="Note:" Foreground="#CCC" VerticalAlignment="Center"/>
                        <TextBox Name="txtBlockNote" Width="200" Background="#333" Foreground="#CCC"
                                 BorderBrush="#555" Padding="4,3" Margin="0,0,6,0" VerticalAlignment="Center"/>
                        <Label Content="Direction:" Foreground="#CCC" VerticalAlignment="Center"/>
                        <ComboBox Name="cmbBlockDir" Width="100" Background="#E0E0E0" Foreground="Black"
                                  Margin="0,0,6,0" VerticalAlignment="Center">
                            <ComboBoxItem Content="Both"     IsSelected="True"/>
                            <ComboBoxItem Content="Inbound"/>
                            <ComboBoxItem Content="Outbound"/>
                        </ComboBox>
                        <Button Name="btnBlockAddManual" Content="Add" MinWidth="60"/>
                    </DockPanel>
                    <DataGrid Name="dgBlocklist" SelectionMode="Single">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Action"     Width="70"  Binding="{Binding Action}"/>
                            <DataGridTextColumn Header="IP/Range"   Width="150" Binding="{Binding IP}"/>
                            <DataGridTextColumn Header="Direction"  Width="80"  Binding="{Binding Direction}"/>
                            <DataGridTextColumn Header="Note"       Width="220" Binding="{Binding Note}"/>
                            <DataGridTextColumn Header="Rule Name"  Width="200" Binding="{Binding RuleName}"/>
                            <DataGridTextColumn Header="Added"      Width="130" Binding="{Binding Added}"/>
                            <DataGridTextColumn Header="Status"     Width="80"  Binding="{Binding Status}"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </TabItem>

            <TabItem Header="CrowdSec CTI" Name="tabCTI">
                <DockPanel Background="#1E1E1E" Margin="4">
                    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="4,4,4,6">
                        <Button Name="btnCTIScanAll"   Content="Scan All Connections" Background="#0078D4" MinWidth="160"/>
                        <Button Name="btnCTIClear"     Content="Clear Results"        Background="#555"    MinWidth="100"/>
                        <Button Name="btnCTISetKey"    Content="Set API Key"          Background="#555"    MinWidth="100"/>
                        <TextBlock Name="txtCTIStatus" Foreground="#AAA" FontSize="11"
                                   VerticalAlignment="Center" Margin="16,0,0,0"/>
                    </StackPanel>
                    <DockPanel DockPanel.Dock="Top" Margin="4,0,4,6">
                        <Label Content="Lookup IP:" Foreground="#CCC" VerticalAlignment="Center"/>
                        <TextBox Name="txtCTIInput" Width="180" Background="#333" Foreground="#CCC"
                                 BorderBrush="#555" Padding="4,3" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <Button Name="btnCTILookup" Content="Lookup" MinWidth="80"/>
                    </DockPanel>
                    <DataGrid Name="dgCTI">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="IP"           Width="130" Binding="{Binding IP}"/>
                            <DataGridTextColumn Header="Reputation"   Width="90"  Binding="{Binding Reputation}"/>
                            <DataGridTextColumn Header="Score"        Width="60"  Binding="{Binding Score}"/>
                            <DataGridTextColumn Header="Behaviors"    Width="220" Binding="{Binding Behaviors}"/>
                            <DataGridTextColumn Header="Country"      Width="80"  Binding="{Binding Country}"/>
                            <DataGridTextColumn Header="AS"           Width="180" Binding="{Binding AS}"/>
                            <DataGridTextColumn Header="Blocklists"   Width="120" Binding="{Binding Blocklists}"/>
                            <DataGridTextColumn Header="Last Seen"    Width="90"  Binding="{Binding LastSeen}"/>
                            <DataGridTextColumn Header="Cached"       Width="55"  Binding="{Binding Cached}"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </DockPanel>
            </TabItem>

            <TabItem Header="Hardening" Name="tabHardening">
                <DockPanel Background="#1E1E1E" Margin="4">
                    <Border DockPanel.Dock="Top" Background="#252526" Padding="8,6" Margin="0,0,0,4">
                        <DockPanel>
                            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                                <Button Name="btnHardenApply"   Content="Apply Selected"   Background="#C42B1C" MinWidth="130"/>
                                <Button Name="btnHardenRefresh" Content="Refresh Counts"   Background="#555"   MinWidth="120"/>
                                <Button Name="btnHardenClear"   Content="Remove All Rules" Background="#555"   MinWidth="120"/>
                            </StackPanel>
                            <TextBlock Name="txtHardenStatus" Foreground="#AAA" FontSize="11"
                                       VerticalAlignment="Center" TextWrapping="Wrap"/>
                        </DockPanel>
                    </Border>
                    <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#1E1E1E">
                        <StackPanel Name="panHardening" Margin="8"/>
                    </ScrollViewer>
                </DockPanel>
            </TabItem>

            <TabItem Header="Diagnostics" Name="tabDiag">
                <DockPanel Background="#1E1E1E" Margin="8">
                    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
                        <Button Name="btnPingGW"      Content="Ping Gateway"/>
                        <Button Name="btnPingDNS"     Content="Ping DNS"/>
                        <Button Name="btnPingInternet" Content="Ping Internet"/>
                        <Button Name="btnDNSTest"     Content="DNS Resolve"/>
                        <Button Name="btnHTTPTest"    Content="HTTP Test"/>
                        <Button Name="btnTracert"     Content="Tracert"/>
                        <Button Name="btnClearDiag"   Content="Clear" Background="#555"/>
                    </StackPanel>
                    <TextBox Name="txtDiagInput" DockPanel.Dock="Top" Background="#333" Foreground="#CCC"
                             BorderBrush="#555" Padding="6" Margin="0,0,0,6" Height="28"
                             Text="8.8.8.8" ToolTip="Target for DNS/HTTP/Tracert tests"/>
                    <Border DockPanel.Dock="Top" Background="#1A1A1A" BorderBrush="#444"
                            BorderThickness="1" Margin="0,0,0,4" Padding="2">
                        <TextBlock Name="txtDiagStatus" Foreground="#AAA" FontSize="11" Padding="4,2"/>
                    </Border>
                    <TextBox Name="txtDiagOutput" Background="#0D0D0D" Foreground="#0CF"
                             FontFamily="Consolas" FontSize="12" IsReadOnly="True"
                             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                             TextWrapping="NoWrap" AcceptsReturn="True" BorderThickness="0"/>
                </DockPanel>
            </TabItem>
        </TabControl>
    </DockPanel>
</Window>
'@

# =============================================================================
# LOAD WINDOW + FIND CONTROLS (KW-036: null-check immediately)
# =============================================================================
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
if ($null -eq $window) { Write-Log 'ERROR: XAML load failed' 'ERROR'; exit 1 }

# Overview (dynamic -- built in code)
$panOverview    = $window.FindName('panOverview');    if ($null -eq $panOverview)    { Write-Log 'WARN: panOverview null' 'WARN' }
# Header
$txtNpcap       = $window.FindName('txtNpcap');       if ($null -eq $txtNpcap)       { Write-Log 'WARN: txtNpcap null' 'WARN' }
$txtMachine     = $window.FindName('txtMachine');     if ($null -eq $txtMachine)     { Write-Log 'WARN: txtMachine null' 'WARN' }
$txtFlagCount   = $window.FindName('txtFlagCount');   if ($null -eq $txtFlagCount)   { Write-Log 'WARN: txtFlagCount null' 'WARN' }
$txtLastRefresh = $window.FindName('txtLastRefresh'); if ($null -eq $txtLastRefresh) { Write-Log 'WARN: txtLastRefresh null' 'WARN' }
$txtStatus      = $window.FindName('txtStatus');      if ($null -eq $txtStatus)      { Write-Log 'WARN: txtStatus null' 'WARN' }
$btnRefresh     = $window.FindName('btnRefresh');     if ($null -eq $btnRefresh)     { Write-Log 'WARN: btnRefresh null' 'WARN' }
$btnExport      = $window.FindName('btnExport');      if ($null -eq $btnExport)      { Write-Log 'WARN: btnExport null' 'WARN' }
# Connections
$dgConnections  = $window.FindName('dgConnections');  if ($null -eq $dgConnections)  { Write-Log 'WARN: dgConnections null' 'WARN' }
$txtConnFilter  = $window.FindName('txtConnFilter');  if ($null -eq $txtConnFilter)  { Write-Log 'WARN: txtConnFilter null' 'WARN' }
$chkEstablished = $window.FindName('chkEstablished'); if ($null -eq $chkEstablished) { Write-Log 'WARN: chkEstablished null' 'WARN' }
$chkFlagged     = $window.FindName('chkFlagged');     if ($null -eq $chkFlagged)     { Write-Log 'WARN: chkFlagged null' 'WARN' }
$txtConnCount   = $window.FindName('txtConnCount');   if ($null -eq $txtConnCount)   { Write-Log 'WARN: txtConnCount null' 'WARN' }
# DNS
$dgDNS          = $window.FindName('dgDNS');          if ($null -eq $dgDNS)          { Write-Log 'WARN: dgDNS null' 'WARN' }
$txtDNSFilter   = $window.FindName('txtDNSFilter');   if ($null -eq $txtDNSFilter)   { Write-Log 'WARN: txtDNSFilter null' 'WARN' }
$chkDNSSuspect  = $window.FindName('chkDNSSuspect');  if ($null -eq $chkDNSSuspect)  { Write-Log 'WARN: chkDNSSuspect null' 'WARN' }
$btnFlushDNS    = $window.FindName('btnFlushDNS');    if ($null -eq $btnFlushDNS)    { Write-Log 'WARN: btnFlushDNS null' 'WARN' }
$txtDNSCount    = $window.FindName('txtDNSCount');    if ($null -eq $txtDNSCount)    { Write-Log 'WARN: txtDNSCount null' 'WARN' }
# Firewall
$dgFirewall     = $window.FindName('dgFirewall');     if ($null -eq $dgFirewall)     { Write-Log 'WARN: dgFirewall null' 'WARN' }
$txtFWDomain    = $window.FindName('txtFWDomain');    if ($null -eq $txtFWDomain)    { Write-Log 'WARN: txtFWDomain null' 'WARN' }
$txtFWPrivate   = $window.FindName('txtFWPrivate');   if ($null -eq $txtFWPrivate)   { Write-Log 'WARN: txtFWPrivate null' 'WARN' }
$txtFWPublic    = $window.FindName('txtFWPublic');    if ($null -eq $txtFWPublic)    { Write-Log 'WARN: txtFWPublic null' 'WARN' }
$txtFWInbound   = $window.FindName('txtFWInbound');   if ($null -eq $txtFWInbound)   { Write-Log 'WARN: txtFWInbound null' 'WARN' }
$txtFWOutbound  = $window.FindName('txtFWOutbound');  if ($null -eq $txtFWOutbound)  { Write-Log 'WARN: txtFWOutbound null' 'WARN' }
$bdrFWDomain    = $null; $bdrFWPrivate = $null; $bdrFWPublic = $null
# Profile toggle buttons
$btnFWDomain    = $window.FindName('btnFWDomain');     if ($null -eq $btnFWDomain)     { Write-Log 'WARN: btnFWDomain null' 'WARN' }
$btnFWPrivate   = $window.FindName('btnFWPrivate');    if ($null -eq $btnFWPrivate)    { Write-Log 'WARN: btnFWPrivate null' 'WARN' }
$btnFWPublic    = $window.FindName('btnFWPublic');     if ($null -eq $btnFWPublic)     { Write-Log 'WARN: btnFWPublic null' 'WARN' }
# Firewall management
$btnFWEnableAll = $window.FindName('btnFWEnableAll');  if ($null -eq $btnFWEnableAll)  { Write-Log 'WARN: btnFWEnableAll null' 'WARN' }
$btnFWDisableAll= $window.FindName('btnFWDisableAll'); if ($null -eq $btnFWDisableAll) { Write-Log 'WARN: btnFWDisableAll null' 'WARN' }
$btnAddRule     = $window.FindName('btnAddRule');       if ($null -eq $btnAddRule)      { Write-Log 'WARN: btnAddRule null' 'WARN' }
$txtRuleName    = $window.FindName('txtRuleName');      if ($null -eq $txtRuleName)     { Write-Log 'WARN: txtRuleName null' 'WARN' }
$txtRulePort    = $window.FindName('txtRulePort');      if ($null -eq $txtRulePort)     { Write-Log 'WARN: txtRulePort null' 'WARN' }
$cmbRuleProto   = $window.FindName('cmbRuleProto');     if ($null -eq $cmbRuleProto)    { Write-Log 'WARN: cmbRuleProto null' 'WARN' }
$cmbRuleDir     = $window.FindName('cmbRuleDir');       if ($null -eq $cmbRuleDir)      { Write-Log 'WARN: cmbRuleDir null' 'WARN' }
$cmbRuleAction  = $window.FindName('cmbRuleAction');    if ($null -eq $cmbRuleAction)   { Write-Log 'WARN: cmbRuleAction null' 'WARN' }
# Threats
$dgThreats       = $window.FindName('dgThreats');       if ($null -eq $dgThreats)       { Write-Log 'WARN: dgThreats null' 'WARN' }
$txtThreatSummary= $window.FindName('txtThreatSummary'); if ($null -eq $txtThreatSummary) { Write-Log 'WARN: txtThreatSummary null' 'WARN' }
$btnSnapshot     = $window.FindName('btnSnapshot');      if ($null -eq $btnSnapshot)     { Write-Log 'WARN: btnSnapshot null' 'WARN' }
# CTI
$dgCTI          = $window.FindName('dgCTI');          if ($null -eq $dgCTI)          { Write-Log 'WARN: dgCTI null' 'WARN' }
$txtCTIStatus   = $window.FindName('txtCTIStatus');   if ($null -eq $txtCTIStatus)   { Write-Log 'WARN: txtCTIStatus null' 'WARN' }
$txtCTIInput    = $window.FindName('txtCTIInput');    if ($null -eq $txtCTIInput)    { Write-Log 'WARN: txtCTIInput null' 'WARN' }
$btnCTILookup   = $window.FindName('btnCTILookup');   if ($null -eq $btnCTILookup)   { Write-Log 'WARN: btnCTILookup null' 'WARN' }
$btnCTIScanAll  = $window.FindName('btnCTIScanAll');  if ($null -eq $btnCTIScanAll)  { Write-Log 'WARN: btnCTIScanAll null' 'WARN' }
$btnCTIClear    = $window.FindName('btnCTIClear');    if ($null -eq $btnCTIClear)    { Write-Log 'WARN: btnCTIClear null' 'WARN' }
$btnCTISetKey   = $window.FindName('btnCTISetKey');   if ($null -eq $btnCTISetKey)   { Write-Log 'WARN: btnCTISetKey null' 'WARN' }
# Blocklist
$dgBlocklist     = $window.FindName('dgBlocklist');     if ($null -eq $dgBlocklist)     { Write-Log 'WARN: dgBlocklist null' 'WARN' }
$txtBlockStatus  = $window.FindName('txtBlockStatus');  if ($null -eq $txtBlockStatus)  { Write-Log 'WARN: txtBlockStatus null' 'WARN' }
$txtBlockIP      = $window.FindName('txtBlockIP');      if ($null -eq $txtBlockIP)      { Write-Log 'WARN: txtBlockIP null' 'WARN' }
$txtBlockNote    = $window.FindName('txtBlockNote');    if ($null -eq $txtBlockNote)    { Write-Log 'WARN: txtBlockNote null' 'WARN' }
$cmbBlockDir     = $window.FindName('cmbBlockDir');     if ($null -eq $cmbBlockDir)     { Write-Log 'WARN: cmbBlockDir null' 'WARN' }
$btnBlockAdd     = $window.FindName('btnBlockAdd');     if ($null -eq $btnBlockAdd)     { Write-Log 'WARN: btnBlockAdd null' 'WARN' }
$btnBlockAllow   = $window.FindName('btnBlockAllow');   if ($null -eq $btnBlockAllow)   { Write-Log 'WARN: btnBlockAllow null' 'WARN' }
$btnBlockRemove  = $window.FindName('btnBlockRemove');  if ($null -eq $btnBlockRemove)  { Write-Log 'WARN: btnBlockRemove null' 'WARN' }
$btnBlockApply   = $window.FindName('btnBlockApply');   if ($null -eq $btnBlockApply)   { Write-Log 'WARN: btnBlockApply null' 'WARN' }
$btnBlockExport  = $window.FindName('btnBlockExport');  if ($null -eq $btnBlockExport)  { Write-Log 'WARN: btnBlockExport null' 'WARN' }
$btnBlockAddManual=$window.FindName('btnBlockAddManual');if($null -eq $btnBlockAddManual){ Write-Log 'WARN: btnBlockAddManual null' 'WARN' }

# Blocklist persistence file
$BlocklistFile = "$BaseDir\Blocklist.json"

# Load or init blocklist ObservableCollection
$blocklistItems = New-Object System.Collections.ObjectModel.ObservableCollection[object]
if (Test-Path $BlocklistFile) {
    try {
        $serBL = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $saved  = $serBL.Deserialize((Get-Content $BlocklistFile -Raw), [System.Collections.ArrayList])
        foreach ($item in $saved) {
            # Reset status to Pending -- will be re-applied immediately below
            $item.Status = 'Pending'
            $blocklistItems.Add([PSCustomObject]$item) | Out-Null
        }
        Write-Log "Blocklist loaded: $($blocklistItems.Count) rules -- auto-applying..."
    } catch { Write-Log "WARN: Blocklist load failed: $($_.Exception.Message)" 'WARN' }
}
if ($null -ne $dgBlocklist) { $dgBlocklist.ItemsSource = $blocklistItems }

# Auto-apply blocklist rules on startup so firewall is always in sync with saved list
if ($blocklistItems.Count -gt 0) {
    $applied = 0; $failed = 0
    foreach ($item in $blocklistItems) {
        $dirs = if ($item.Direction -eq 'Both') { @('in','out') }
                elseif ($item.Direction -eq 'Inbound') { @('in') } else { @('out') }
        $fwAction = if ($item.Action -eq 'BLOCK') { 'block' } else { 'allow' }
        foreach ($dir in $dirs) {
            $rn = "$($item.RuleName)_$dir"
            & netsh.exe advfirewall firewall delete rule name=$rn 2>&1 | Out-Null
            & netsh.exe advfirewall firewall add rule name=$rn `
                dir=$dir action=$fwAction remoteip=$($item.IP) protocol=any enable=yes 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $applied++ } else { $failed++ }
        }
        $item.Status = if ($failed -eq 0) { 'Active' } else { 'Error' }
    }
    Write-Log "Blocklist auto-applied: $applied rules active, $failed failed"
}

# Hardening tab
$panHardening    = $window.FindName('panHardening');    if ($null -eq $panHardening)    { Write-Log 'WARN: panHardening null' 'WARN' }
$btnHardenApply  = $window.FindName('btnHardenApply');  if ($null -eq $btnHardenApply)  { Write-Log 'WARN: btnHardenApply null' 'WARN' }
$btnHardenRefresh= $window.FindName('btnHardenRefresh'); if ($null -eq $btnHardenRefresh){ Write-Log 'WARN: btnHardenRefresh null' 'WARN' }
$btnHardenClear  = $window.FindName('btnHardenClear');  if ($null -eq $btnHardenClear)  { Write-Log 'WARN: btnHardenClear null' 'WARN' }
$txtHardenStatus = $window.FindName('txtHardenStatus'); if ($null -eq $txtHardenStatus) { Write-Log 'WARN: txtHardenStatus null' 'WARN' }

# =============================================================================
# HARDENING BLOCKLIST CATALOG
# Each entry: Name, Category, Description, URL, Format, IpCount (approx), Checked
# Format: 'netset' = one IP/CIDR per line with # comments
#         'plain'  = one IP per line with # comments
#         'dshield' = DShield format (tab-separated, first column = /24 block)
# =============================================================================
$HardenCatalog = @(
    @{
        Category = 'Anonymization'
        Name     = 'Tor Exit Nodes'
        Desc     = 'IP addresses of Tor exit nodes -- traffic from these IPs exits the Tor anonymity network. Block to prevent anonymous access or exfiltration via Tor.'
        URL      = 'https://opendbl.net/lists/tor-exit.list'
        Format   = 'plain'
        IpCount  = '~1,200'
        Risky    = $false
    },
    @{
        Category = 'Anonymization'
        Name     = 'Free Proxies (Firehol)'
        Desc     = 'Known free proxy servers used to mask origin IPs. Sourced from Firehol proxies list.'
        URL      = 'https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_anonymous.netset'
        Format   = 'netset'
        IpCount  = '~10,000'
        Risky    = $false
    },
    @{
        Category = 'Threat Intel - Conservative'
        Name     = 'Firehol Level 1'
        Desc     = 'Maximum protection, minimum false positives. Composed from DShield, Feodo C2, Spamhaus DROP, and ransomware IPs. Recommended baseline for all machines.'
        URL      = 'https://raw.githubusercontent.com/ktsaou/blocklist-ipsets/master/firehol_level1.netset'
        Format   = 'netset'
        IpCount  = '~50,000'
        Risky    = $false
    },
    @{
        Category = 'Threat Intel - Conservative'
        Name     = 'Spamhaus DROP'
        Desc     = 'Do-Not-Route Or Peer list. IPs allocated to spammers and cybercriminals -- hijacked netblocks with no legitimate traffic. Very low false positive rate.'
        URL      = 'https://www.spamhaus.org/drop/drop.txt'
        Format   = 'plain'
        IpCount  = '~1,000'
        Risky    = $false
    },
    @{
        Category = 'Threat Intel - Aggressive'
        Name     = 'Firehol Level 2'
        Desc     = 'Attack IPs from the last 48 hours. Includes blocklist.de, DShield 1-day, and GreenSnow. Higher coverage, small risk of false positives.'
        URL      = 'https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level2.netset'
        Format   = 'netset'
        IpCount  = '~36,000'
        Risky    = $false
    },
    @{
        Category = 'Threat Intel - Aggressive'
        Name     = 'Emerging Threats'
        Desc     = 'Proofpoint Emerging Threats block list -- actively attacking IPs. Updated daily. Well respected in the industry.'
        URL      = 'https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt'
        Format   = 'plain'
        IpCount  = '~30,000'
        Risky    = $false
    },
    @{
        Category = 'Threat Intel - Aggressive'
        Name     = 'DShield Top Attackers'
        Desc     = 'SANS DShield top 20 attacking /24 netblocks. Small but extremely high-confidence -- these are the worst offenders on the internet right now.'
        URL      = 'https://feeds.dshield.org/block.txt'
        Format   = 'dshield'
        IpCount  = '~20 /24 blocks'
        Risky    = $false
    },
    @{
        Category = 'VoIP Fraud'
        Name     = 'VoIP Blacklist (voipbl.org)'
        Desc     = 'Distributed VoIP blacklist. IPs known for SIP scanning, toll fraud, and PBX attacks. Essential if the client has any phone system.'
        URL      = 'https://www.voipbl.org/update/'
        Format   = 'plain'
        IpCount  = '~60,000'
        Risky    = $false
    },
    @{
        Category = 'Brute Force'
        Name     = 'GreenSnow Brute Force'
        Desc     = 'IPs conducting brute force attacks on SSH, RDP, FTP, SMTP and other services. Continuously updated.'
        URL      = 'https://blocklist.greensnow.co/greensnow.txt'
        Format   = 'plain'
        IpCount  = '~100,000'
        Risky    = $true
    },
    @{
        Category = 'Brute Force'
        Name     = 'Blocklist.de SSH Attackers'
        Desc     = 'IPs reported for SSH brute-force attacks in the last 48 hours via fail2ban reports.'
        URL      = 'https://lists.blocklist.de/lists/ssh.txt'
        Format   = 'plain'
        IpCount  = '~30,000'
        Risky    = $false
    },
    @{
        Category = 'Brute Force'
        Name     = 'Blocklist.de RDP Attackers'
        Desc     = 'IPs reported for RDP brute-force attacks. High relevance for Windows environments.'
        URL      = 'https://lists.blocklist.de/lists/rdp.txt'
        Format   = 'plain'
        IpCount  = '~10,000'
        Risky    = $false
    },
    @{
        Category = 'Malware / C2'
        Name     = 'Feodo Tracker C2 (abuse.ch)'
        Desc     = 'Command and Control servers for Dridex, Emotet, TrickBot, QakBot. Very focused list -- high confidence, low false positives.'
        URL      = 'https://feodotracker.abuse.ch/downloads/ipblocklist.txt'
        Format   = 'plain'
        IpCount  = '~100'
        Risky    = $false
    },
    @{
        Category = 'Malware / C2'
        Name     = 'ThreatFox C2 IPs (abuse.ch)'
        Desc     = 'Active C2 server IPs from abuse.ch ThreatFox -- malware families including Cobalt Strike, Metasploit, and RATs.'
        URL      = 'https://threatfox.abuse.ch/downloads/hostfile/'
        Format   = 'hosts-ip'
        IpCount  = '~5,000'
        Risky    = $false
    },
    @{
        Category = 'Scanners'
        Name     = 'Blocklist.de Port Scanners'
        Desc     = 'IPs conducting port scans reported via fail2ban. Good for detecting reconnaissance activity.'
        URL      = 'https://lists.blocklist.de/lists/portscan.txt'
        Format   = 'plain'
        IpCount  = '~5,000'
        Risky    = $false
    }
)

# Checked state per list name (persisted to registry)
$HardenChecked = [hashtable]::Synchronized(@{})
$HardenRegPath = 'HKLM:\SOFTWARE\Paladin\NetWatch\Hardening'
try {
    if (Test-Path $HardenRegPath) {
        $vals = Get-ItemProperty -Path $HardenRegPath -EA Stop
        foreach ($cat in $HardenCatalog) {
            $safe = $cat.Name -replace '[^a-zA-Z0-9]','_'
            if ($null -ne $vals.$safe) { $HardenChecked[$cat.Name] = ($vals.$safe -eq '1') }
            else { $HardenChecked[$cat.Name] = $false }
        }
    }
} catch {}
foreach ($cat in $HardenCatalog) {
    if (-not $HardenChecked.ContainsKey($cat.Name)) { $HardenChecked[$cat.Name] = $false }
}

# CTI results list (ObservableCollection for live updates)
$ctiResults = New-Object System.Collections.ObjectModel.ObservableCollection[object]
if ($null -ne $dgCTI) { $dgCTI.ItemsSource = $ctiResults }
# Diagnostics
$txtDiagOutput  = $window.FindName('txtDiagOutput');  if ($null -eq $txtDiagOutput)  { Write-Log 'WARN: txtDiagOutput null' 'WARN' }
$txtDiagInput   = $window.FindName('txtDiagInput');   if ($null -eq $txtDiagInput)   { Write-Log 'WARN: txtDiagInput null' 'WARN' }
$txtDiagStatus  = $window.FindName('txtDiagStatus');  if ($null -eq $txtDiagStatus)  { Write-Log 'WARN: txtDiagStatus null' 'WARN' }
$btnPingGW      = $window.FindName('btnPingGW');      $btnPingDNS      = $window.FindName('btnPingDNS')
$btnPingInternet= $window.FindName('btnPingInternet');$btnDNSTest      = $window.FindName('btnDNSTest')
$btnHTTPTest    = $window.FindName('btnHTTPTest');    $btnTracert      = $window.FindName('btnTracert')
$btnClearDiag   = $window.FindName('btnClearDiag')

# Init header
if ($null -ne $txtMachine) { $txtMachine.Text = " | $MachineName | $SiteName" }

# Npcap status -- set by pre-launch block via marker file
$npcapAvailable = (Test-Path 'C:\Windows\System32\Npcap\wpcap.dll') -or
                  (Test-Path 'HKLM:\SOFTWARE\Npcap') -or
                  (Test-Path "$BaseDir\npcap.present")
$sync.NpcapAvailable = $npcapAvailable
Write-Log "Npcap available: $npcapAvailable"
if ($null -ne $txtNpcap) {
    if ($npcapAvailable) {
        $txtNpcap.Text = 'Npcap: OK'
        $txtNpcap.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString('#4CAF50'))
    } else {
        $txtNpcap.Text = 'Npcap: NOT INSTALLED (click to download)'
        $txtNpcap.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString('#FF6B6B'))
        $txtNpcap.Cursor = [System.Windows.Input.Cursors]::Hand
        $txtNpcap.ToolTip = 'Click to download Npcap 1.88 installer'
        $txtNpcap.Add_MouseLeftButtonUp(({
            Start-Process 'https://npcap.com/dist/npcap-1.88.exe'
        }).GetNewClosure())
    }
}

# =============================================================================
# OVERVIEW BUILDER -- creates adapter cards dynamically on UI thread
# =============================================================================

function New-OverviewCard {
    param([string]$AdapterName,[string]$IP,[string]$Gateway,[string]$DNS,
          [string]$Speed,[string]$Sent,[string]$Recv,[string]$Health,[string]$DHCP)

    $healthColor = switch ($Health) {
        'OK'   { '#4CAF50' }
        'WARN' { '#FF9800' }
        'FAIL' { '#F44336' }
        default{ '#888' }
    }

    $border = New-Object System.Windows.Controls.Border
    $border.Background    = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#2D2D2D'))
    $border.CornerRadius  = New-Object System.Windows.CornerRadius(6)
    $border.Margin        = New-Object System.Windows.Thickness(0,0,0,10)
    $border.Padding       = New-Object System.Windows.Thickness(14,10,14,10)

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness(0,6,0,0)
    for ($c = 0; $c -lt 4; $c++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $grid.ColumnDefinitions.Add($cd) | Out-Null
    }
    # Two rows: row 0 = IP/GW/DNS/Speed, row 1 = Sent/Recv/DHCP/blank
    for ($r = 0; $r -lt 2; $r++) {
        $rd = New-Object System.Windows.Controls.RowDefinition
        $rd.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Auto)
        $grid.RowDefinitions.Add($rd) | Out-Null
    }

    function New-Cell {
        param([string]$Label,[string]$Value,[int]$Col,[int]$Row,[string]$VColor='#CCC')
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Margin = New-Object System.Windows.Thickness(0,4,8,4)
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text       = $Label
        $lbl.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#888'))
        $lbl.FontSize   = 10
        $val = New-Object System.Windows.Controls.TextBlock
        $val.Text        = $Value
        $val.Foreground  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($VColor))
        $val.FontSize    = 13
        $val.TextWrapping= [System.Windows.TextWrapping]::Wrap
        $sp.Children.Add($lbl) | Out-Null
        $sp.Children.Add($val) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($sp, $Col)
        [System.Windows.Controls.Grid]::SetRow($sp, $Row)
        return $sp
    }

    $c0 = New-Cell 'IP Address'     $IP      0 0
    $c1 = New-Cell 'Gateway'        $Gateway 1 0
    $c2 = New-Cell 'DNS Servers'    $DNS     2 0
    $c3 = New-Cell 'Speed'          $Speed   3 0
    $c4 = New-Cell 'Sent/sec'       $Sent    0 1 '#4CAF50'
    $c5 = New-Cell 'Recv/sec'       $Recv    1 1 '#2196F3'
    $c6 = New-Cell 'DHCP'           $DHCP    2 1

    $grid.Children.Add($c0) | Out-Null
    $grid.Children.Add($c1) | Out-Null
    $grid.Children.Add($c2) | Out-Null
    $grid.Children.Add($c3) | Out-Null
    $grid.Children.Add($c4) | Out-Null
    $grid.Children.Add($c5) | Out-Null
    $grid.Children.Add($c6) | Out-Null

    # Header: adapter name + health badge
    $headerSP = New-Object System.Windows.Controls.StackPanel
    $headerSP.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $headerSP.Margin = New-Object System.Windows.Thickness(0,0,0,4)
    $adName = New-Object System.Windows.Controls.TextBlock
    $adName.Text       = $AdapterName
    $adName.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('White'))
    $adName.FontWeight = [System.Windows.FontWeights]::SemiBold
    $adName.FontSize   = 14
    $badge = New-Object System.Windows.Controls.Border
    $badge.Background   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($healthColor))
    $badge.CornerRadius = New-Object System.Windows.CornerRadius(3)
    $badge.Padding      = New-Object System.Windows.Thickness(8,2,8,2)
    $badge.Margin       = New-Object System.Windows.Thickness(10,0,0,0)
    $badge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $badgeTxt = New-Object System.Windows.Controls.TextBlock
    $badgeTxt.Text       = $Health
    $badgeTxt.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('White'))
    $badgeTxt.FontSize   = 11
    $badgeTxt.FontWeight = [System.Windows.FontWeights]::Bold
    $badge.Child = $badgeTxt
    $headerSP.Children.Add($adName) | Out-Null
    $headerSP.Children.Add($badge)  | Out-Null

    $outer = New-Object System.Windows.Controls.StackPanel
    $outer.Children.Add($headerSP) | Out-Null
    $outer.Children.Add($grid)     | Out-Null
    $border.Child = $outer
    return $border
}

# =============================================================================
# DATA COLLECTION RUNSPACE
# =============================================================================

$rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$rs.ApartmentState = 'STA'
$rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $sync)

$collectScript = {
    param($sync)

    $ErrorActionPreference = 'Continue'

    function Get-FriendlyBytes {
        param([long]$B)
        if ($B -ge 1GB) { return '{0:N1} GB/s' -f ($B/1GB) }
        if ($B -ge 1MB) { return '{0:N1} MB/s' -f ($B/1MB) }
        if ($B -ge 1KB) { return '{0:N1} KB/s' -f ($B/1KB) }
        return "$B B/s"
    }

    while ($sync.Running) {
        try {
            # --- ADAPTERS (Overview) ---
            $adapters   = @()
            # ipconfig /all parser -- zero permissions required, works on any token/VM/PS3+
            $ipcfgRaw  = & ipconfig.exe /all 2>&1
            $curName   = ''; $curIP = ''; $curGW = ''; $curDNS = ''; $curDHCP = 'Static'

            function Add-ParsedAdapter {
                param($n,$ip,$gw,$dns,$dhcp)
                if ([string]::IsNullOrEmpty($ip)) { return }
                if ($n -match 'Loopback|Npcap|Tunnel|Teredo|isatap') { return }
                $h = if ([string]::IsNullOrEmpty($gw)) { 'WARN' } else { 'OK' }
                $script:adapters += @{
                    Name=''; IP=$ip; Gateway=$gw; DNS=$dns; DHCP=$dhcp
                    Speed='N/A'; Sent='0 B/s'; Recv='0 B/s'; Health=$h
                }
                $script:adapters[-1]['Name'] = $n
            }

            foreach ($ln in $ipcfgRaw) {
                if ($ln -match '^[^\s].+:$') {
                    Add-ParsedAdapter $curName $curIP $curGW $curDNS $curDHCP
                    $curName = ($ln -replace ':$','').Trim()
                    $curIP=''; $curGW=''; $curDNS=''; $curDHCP='Static'
                    continue
                }
                if ($ln -match 'IPv4 Address[\. ]+:\s*([\d\.]+)')        { $curIP   = $Matches[1] -replace '\s|\(Preferred\)','' }
                if ($ln -match 'Default Gateway[\. ]+:\s*([\d\.]+)')     { $curGW   = $Matches[1].Trim() }
                if ($ln -match 'DNS Servers[\. ]+:\s*([\d\.]+)') {
                    if ([string]::IsNullOrEmpty($curDNS)) { $curDNS = $Matches[1].Trim() }
                    else { $curDNS += ', ' + $Matches[1].Trim() }
                }
                if ($ln -match 'DHCP Enabled[\. ]+:\s*Yes')              { $curDHCP = 'DHCP' }
            }
            Add-ParsedAdapter $curName $curIP $curGW $curDNS $curDHCP
            $sync.Adapters = $adapters

            # --- CONNECTIONS ---
            $conns = @()
            $flagCount = 0
            try {
                # Build process map PID -> name
                $procMap = @{}
                Get-Process -EA SilentlyContinue | ForEach-Object { $procMap[[string]$_.Id] = $_.Name }

                $tcpRows = @()
                # Try Get-NetTCPConnection (PS4+)
                try {
                    $tcpRows = @(Get-NetTCPConnection -EA Stop)
                    foreach ($r in $tcpRows) {
                        $pid1    = [string]$r.OwningProcess
                        $proc    = if ($procMap.ContainsKey($pid1)) { $procMap[$pid1] } else { '?' }
                        $local   = "$($r.LocalAddress):$($r.LocalPort)"
                        $remote  = if ($r.RemoteAddress -ne '0.0.0.0' -and $r.RemoteAddress -ne '::') {
                                       "$($r.RemoteAddress):$($r.RemotePort)" } else { '-' }
                        $state   = [string]$r.State
                        $flag    = ''
                        $note    = ''
                        # Flag suspicious outbound
                        if ($r.State -eq 'Established' -and $r.RemotePort -gt 0) {
                            if ($sync.SuspiciousPorts -contains $r.RemotePort) {
                                $flag = 'SUSPECT'; $note = "Suspicious port $($r.RemotePort)"; $flagCount++
                            } elseif ($r.RemotePort -notin $sync.TrustedPorts -and $r.RemotePort -lt 1024) {
                                $flag = 'WATCH'; $note = "Uncommon port $($r.RemotePort)"
                            }
                        }
                        $conns += [PSCustomObject]@{
                            PID     = $pid1
                            Process = $proc
                            Local   = $local
                            Remote  = $remote
                            State   = $state
                            Proto   = 'TCP'
                            Flag    = $flag
                            Note    = $note
                        }
                    }
                } catch {
                    # Fallback: netstat
                    $ns = & netstat.exe -ano 2>&1 | Where-Object { $_ -match 'TCP|UDP' }
                    foreach ($line in $ns) {
                        if ($line -match '^\s*(TCP|UDP)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)') {
                            $pid1 = $Matches[5]; $proc = if ($procMap.ContainsKey($pid1)) { $procMap[$pid1] } else { '?' }
                            $conns += [PSCustomObject]@{
                                PID=$pid1; Process=$proc; Local=$Matches[2]; Remote=$Matches[3]
                                State=$Matches[4]; Proto=$Matches[1]; Flag=''; Note=''
                            }
                        }
                    }
                }
            } catch {}
            $sync.Connections = $conns
            $sync.ConnLastUpdate = (Get-Date -Format 'HH:mm:ss')
            $sync.FlagCount = $flagCount

            # --- THREAT DETECTION ---
            $threats = @()
            $now = Get-Date

            # Store snapshot in history (keep last 60 entries ~5min at 5s interval)
            $snapshot = @{ Time=$now; Conns=$conns }
            $sync.ConnHistory.Add($snapshot) | Out-Null
            if ($sync.ConnHistory.Count -gt 60) { $sync.ConnHistory.RemoveAt(0) }

            # 1. BEACONING: same process+remote appearing at regular intervals (>=5 times)
            $groups = $conns | Where-Object { -not [string]::IsNullOrEmpty($_.Remote) -and $_.Remote -ne '-' } |
                Group-Object { "$($_.Process)|$($_.Remote)" }
            foreach ($g in $groups) {
                if ($null -eq $g -or $g.Count -lt 1) { continue }
                $histCount = 0
                foreach ($snap in $sync.ConnHistory) {
                    $match = $snap.Conns | Where-Object { "$($_.Process)|$($_.Remote)" -eq $g.Name }
                    if ($null -ne $match) { $histCount++ }
                }
                if ($histCount -ge 5) {
                    $parts = $g.Name -split '\|'
                    $threats += [PSCustomObject]@{
                        Severity  = 'WARN'
                        Type      = 'Beaconing'
                        Process   = $parts[0]
                        Detail    = "Seen in $histCount/$($sync.ConnHistory.Count) snapshots (~$(($histCount*5))s)"
                        Remote    = if ($parts.Count -gt 1) { $parts[1] } else { '' }
                        FirstSeen = (Get-Date -Format 'HH:mm:ss')
                        Count     = $histCount
                    }
                }
            }

            # 2. PORT SCAN: one process connecting to many different remote IPs (>8 unique)
            $procGroups = $conns | Where-Object { $_.State -eq 'Established' } | Group-Object Process
            foreach ($pg in $procGroups) {
                if ($null -eq $pg) { continue }
                $uniqueRemoteIPs = @($pg.Group | ForEach-Object { ($_.Remote -split ':')[0] } | Sort-Object -Unique)
                if ($uniqueRemoteIPs.Count -gt 8) {
                    $trustedProcs = @('svchost','System','lsass','services','wininit','MsMpEng','SearchHost')
                    if ($trustedProcs -notcontains $pg.Name) {
                        $threats += [PSCustomObject]@{
                            Severity  = 'HIGH'
                            Type      = 'Port Scan / Mass Connect'
                            Process   = [string]$pg.Name
                            Detail    = "$($uniqueRemoteIPs.Count) unique remote IPs"
                            Remote    = ($uniqueRemoteIPs | Select-Object -First 3) -join ', '
                            FirstSeen = (Get-Date -Format 'HH:mm:ss')
                            Count     = $uniqueRemoteIPs.Count
                        }
                    }
                }
            }

            # 3. SUSPICIOUS PROCESS making outbound on non-standard port
            $suspiciousProcs = @('powershell','cmd','wscript','cscript','mshta','regsvr32',
                                  'rundll32','certutil','bitsadmin','wmic','msiexec')
            foreach ($conn in $conns) {
                if ($conn.State -ne 'Established') { continue }
                $procLower = [string]$conn.Process.ToLower()
                if ($suspiciousProcs | Where-Object { $procLower -eq $_ }) {
                    $remotePort = 0
                    if ($conn.Remote -match ':(\d+)$') { $remotePort = [int]$Matches[1] }
                    if ($remotePort -gt 0 -and $sync.TrustedPorts -notcontains $remotePort) {
                        $threats += [PSCustomObject]@{
                            Severity  = 'HIGH'
                            Type      = 'Suspicious Process Outbound'
                            Process   = [string]$conn.Process
                            Detail    = "Outbound on port $remotePort (unusual for this process)"
                            Remote    = [string]$conn.Remote
                            FirstSeen = (Get-Date -Format 'HH:mm:ss')
                            Count     = 1
                        }
                    }
                }
            }

            # 4. DNS TUNNEL HEURISTICS: very long hostnames or high-entropy subdomains
            foreach ($entry in $sync.DNSCache) {
                $name = [string]$entry.Name
                if ($name.Length -gt 50) {
                    $threats += [PSCustomObject]@{
                        Severity  = 'WARN'
                        Type      = 'DNS Tunnel (Long Hostname)'
                        Process   = '-'
                        Detail    = "Hostname length $($name.Length) chars: $($name.Substring(0,[Math]::Min(60,$name.Length)))"
                        Remote    = [string]$entry.Data
                        FirstSeen = (Get-Date -Format 'HH:mm:ss')
                        Count     = 1
                    }
                }
                # High subdomain count (>4 labels)
                $labels = $name -split '\.'
                if ($labels.Count -gt 5) {
                    $threats += [PSCustomObject]@{
                        Severity  = 'WARN'
                        Type      = 'DNS Tunnel (Deep Subdomain)'
                        Process   = '-'
                        Detail    = "$($labels.Count) DNS labels: $($name.Substring(0,[Math]::Min(60,$name.Length)))"
                        Remote    = [string]$entry.Data
                        FirstSeen = (Get-Date -Format 'HH:mm:ss')
                        Count     = 1
                    }
                }
            }

            $sync.Threats    = $threats
            $sync.ThreatCount= $threats.Count

            # --- DNS CACHE ---
            $dnsRows = @()
            try {
                $cache = @(Get-DnsClientCache -EA Stop)
                foreach ($e in $cache) {
                    $flag = ''
                    $ttl  = [int]$e.TimeToLive
                    if ($ttl -lt 30 -and $ttl -gt 0) { $flag = 'SHORT-TTL' }
                    if ([string]$e.Name -match '\d{4,}\.') { $flag = 'SUSPECT' }
                    $dnsRows += [PSCustomObject]@{
                        Name    = [string]$e.Entry
                        Type    = [string]$e.Type
                        Data    = [string]$e.Data
                        TTL     = $ttl
                        Section = [string]$e.Section
                        Flag    = $flag
                    }
                }
            } catch {
                # Fallback: ipconfig /displaydns
                $ipc = & ipconfig.exe /displaydns 2>&1
                $cur = @{}
                foreach ($line in $ipc) {
                    if ($line -match 'Record Name\.*:\s+(.+)')     { $cur.Name = $Matches[1].Trim() }
                    if ($line -match 'Record Type\.*:\s+(.+)')     { $cur.Type = $Matches[1].Trim() }
                    if ($line -match 'Time To Live\.*:\s+(\d+)')   { $cur.TTL  = [int]$Matches[1] }
                    if ($line -match 'Data Length\.*:\s+')         { }
                    if ($line -match 'A \(Host\) Record\.*:\s+(.+)') {
                        $cur.Data = $Matches[1].Trim()
                        $dnsRows += [PSCustomObject]@{Name=$cur.Name;Type=$cur.Type;Data=$cur.Data;TTL=$cur.TTL;Section='Answer';Flag=''}
                        $cur = @{}
                    }
                }
            }
            $sync.DNSCache = $dnsRows
            $sync.DNSLastUpdate = (Get-Date -Format 'HH:mm:ss')

            # --- FIREWALL ---
            $fwProfiles = @()
            try {
                $profiles = & netsh.exe advfirewall show allprofiles state 2>&1
                foreach ($line in $profiles) {
                    if ($line -match '(Domain|Private|Public)\s+Profile\s+Settings') { $cur = $Matches[1] }
                    if ($line -match 'State\s+(ON|OFF)' -and $null -ne $cur) {
                        $fwProfiles += @{ Profile=$cur; State=$Matches[1] }
                    }
                }
                # Rule counts
                try {
                    $inCount  = @(Get-NetFirewallRule -Direction Inbound  -EA Stop).Count
                    $outCount = @(Get-NetFirewallRule -Direction Outbound -EA Stop).Count
                    $sync.FWInbound  = [string]$inCount
                    $sync.FWOutbound = [string]$outCount
                } catch { $sync.FWInbound='N/A'; $sync.FWOutbound='N/A' }

                # Recent blocks from Security event log (EventID 5152)
                $fwBlocks = @()
                try {
                    $events = @(Get-WinEvent -FilterHashtable @{LogName='Security';Id=5152} `
                                -MaxEvents 50 -EA Stop)
                    foreach ($ev in $events) {
                        $xml  = [xml]$ev.ToXml()
                        $data = $xml.Event.EventData.Data
                        $fwBlocks += [PSCustomObject]@{
                            Time      = $ev.TimeCreated.ToString('MM/dd HH:mm:ss')
                            Direction = ([string]($data | Where-Object {$_.Name -eq 'Direction'}).'#text')
                            Protocol  = ([string]($data | Where-Object {$_.Name -eq 'Protocol'}).'#text')
                            SrcIP     = ([string]($data | Where-Object {$_.Name -eq 'SourceAddress'}).'#text')
                            DstIP     = ([string]($data | Where-Object {$_.Name -eq 'DestAddress'}).'#text')
                            DstPort   = ([string]($data | Where-Object {$_.Name -eq 'DestPort'}).'#text')
                        }
                    }
                } catch {}
                $sync.FWBlocks  = $fwBlocks
            } catch {}
            $sync.FWProfiles    = $fwProfiles
            $sync.FWLastUpdate  = (Get-Date -Format 'HH:mm:ss')
            $sync.StatusMsg     = "Last refresh: $(Get-Date -Format 'HH:mm:ss')"
            $sync.LastRefresh   = (Get-Date -Format 'HH:mm:ss')

        } catch { $sync.ErrorMsg = $_.Exception.Message }

        # Wait 5 seconds between polls, checking Running every 500ms
        $waited = 0
        while ($waited -lt 5000 -and $sync.Running) { Start-Sleep -Milliseconds 500; $waited += 500 }
    }
}

$ps = [System.Management.Automation.PowerShell]::Create()
$ps.Runspace = $rs
$ps.AddScript($collectScript).AddArgument($sync) | Out-Null
$asyncResult = $ps.BeginInvoke()

# =============================================================================
# UI UPDATE FUNCTIONS (called from DispatcherTimer on UI thread)
# =============================================================================

function Update-Overview {
    if ($null -eq $panOverview) { return }
    $panOverview.Children.Clear()
    $adapters = $sync.Adapters
    if ($null -eq $adapters -or $adapters.Count -eq 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = 'No active adapters found.'
        $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#888'))
        $panOverview.Children.Add($tb) | Out-Null
        return
    }
    foreach ($a in $adapters) {
        $card = New-OverviewCard -AdapterName $a.Name -IP $a.IP -Gateway $a.Gateway `
            -DNS $a.DNS -Speed $a.Speed -Sent $a.Sent -Recv $a.Recv `
            -Health $a.Health -DHCP $a.DHCP
        $panOverview.Children.Add($card) | Out-Null
    }
}

function Apply-ConnectionFilter {
    $all      = $sync.Connections
    $filter   = if ($null -ne $txtConnFilter)  { [string]$txtConnFilter.Text.Trim() }  else { '' }
    $estOnly  = if ($null -ne $chkEstablished -and $chkEstablished.IsChecked -eq $true) { $true } else { $false }
    $flagOnly = if ($null -ne $chkFlagged     -and $chkFlagged.IsChecked     -eq $true) { $true } else { $false }

    $filtered = @($all | Where-Object {
        if ($null -eq $_) { return $false }
        $row = $_
        if ($estOnly  -and [string]$row.State -ne 'Established') { return $false }
        if ($flagOnly -and [string]::IsNullOrEmpty([string]$row.Flag)) { return $false }
        if (-not [string]::IsNullOrEmpty($filter)) {
            $esc = [regex]::Escape($filter)
            if ([string]$row.Process -notmatch $esc -and
                [string]$row.Remote  -notmatch $esc -and
                [string]$row.Local   -notmatch $esc) { return $false }
        }
        return $true
    })
    if ($null -ne $dgConnections) {
        $dgConnections.ItemsSource = $filtered
        if ($null -ne $txtConnCount) { $txtConnCount.Text = "$($filtered.Count) connections" }
    }
}

function Apply-DNSFilter {
    $all        = $sync.DNSCache
    $filter     = if ($null -ne $txtDNSFilter)  { $txtDNSFilter.Text.Trim() }  else { '' }
    $suspectOnly= if ($null -ne $chkDNSSuspect) { $chkDNSSuspect.IsChecked }   else { $false }

    $filtered = $all | Where-Object {
        $row = $_
        $ok  = $true
        if ($suspectOnly -and [string]::IsNullOrEmpty($row.Flag)) { $ok = $false }
        if ($filter -and $row.Name -notmatch [regex]::Escape($filter) -and
            $row.Data -notmatch [regex]::Escape($filter)) { $ok = $false }
        $ok
    }
    if ($null -ne $dgDNS) {
        $dgDNS.ItemsSource = $filtered
        if ($null -ne $txtDNSCount) { $txtDNSCount.Text = "$($filtered.Count) entries" }
    }
}

function Update-Firewall {
    $fwGreen = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#107C10'))
    $fwRed   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#C42B1C'))

    # Always re-read live state from netsh so UI is accurate on demand
    $liveProfiles = @()
    try {
        $raw = & netsh.exe advfirewall show allprofiles state 2>&1
        $rc  = $null
        foreach ($line in $raw) {
            if ($line -match '(Domain|Private|Public)\s+Profile\s+Settings') { $rc = $Matches[1] }
            if ($line -match 'State\s+(ON|OFF)' -and $null -ne $rc) {
                $liveProfiles += @{ Profile=$rc; State=$Matches[1] }
                $rc = $null
            }
        }
        if ($liveProfiles.Count -gt 0) { $sync.FWProfiles = $liveProfiles }
    } catch {}

    $profiles = if ($liveProfiles.Count -gt 0) { $liveProfiles } else { $sync.FWProfiles }

    if ($null -ne $profiles) {
        foreach ($p in $profiles) {
            $brush = if ($p.State -eq 'ON') { $fwGreen } else { $fwRed }
            switch ($p.Profile) {
                'Domain'  {
                    if ($null -ne $btnFWDomain)  { $btnFWDomain.Background  = $brush }
                    if ($null -ne $txtFWDomain)  { $txtFWDomain.Text  = $p.State }
                }
                'Private' {
                    if ($null -ne $btnFWPrivate) { $btnFWPrivate.Background = $brush }
                    if ($null -ne $txtFWPrivate) { $txtFWPrivate.Text = $p.State }
                }
                'Public'  {
                    if ($null -ne $btnFWPublic)  { $btnFWPublic.Background  = $brush }
                    if ($null -ne $txtFWPublic)  { $txtFWPublic.Text  = $p.State }
                }
            }
        }
    }
    if ($null -ne $txtFWInbound  -and $sync.ContainsKey('FWInbound'))  { $txtFWInbound.Text  = $sync.FWInbound }
    if ($null -ne $txtFWOutbound -and $sync.ContainsKey('FWOutbound')) { $txtFWOutbound.Text = $sync.FWOutbound }
    if ($null -ne $dgFirewall    -and $sync.ContainsKey('FWBlocks'))   { $dgFirewall.ItemsSource = $sync.FWBlocks }
}

function Update-Threats {
    $threats = $sync.Threats
    if ($null -eq $threats) { $threats = @() }
    if ($null -ne $dgThreats) { $dgThreats.ItemsSource = $threats }
    $tc = [int]$sync.ThreatCount
    if ($null -ne $txtThreatSummary) {
        $txtThreatSummary.Text = if ($tc -gt 0) { "! $tc threat$(if($tc -ne 1){'s'}) detected" } else { 'No threats detected' }
        $col = if ($tc -gt 0) { '#FF6B6B' } else { '#4CAF50' }
        $txtThreatSummary.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString($col))
    }
}

# =============================================================================
# CROWDSEC CTI FUNCTIONS
# =============================================================================

function Get-CTIKey {
    try {
        $val = (Get-ItemProperty -Path $CTIKeyReg -Name $CTIKeyName -EA Stop).$CTIKeyName
        return [string]$val.Trim()
    } catch { return $null }
}

function Set-CTIKey { param([string]$Key)
    try {
        if (-not (Test-Path $CTIKeyReg)) { New-Item -Path $CTIKeyReg -Force -EA SilentlyContinue | Out-Null }
        New-ItemProperty -Path $CTIKeyReg -Name $CTIKeyName `
            -Value $Key.Trim() -PropertyType String -Force -EA Stop | Out-Null
        return $true
    } catch { return $false }
}

function Invoke-CTILookup {
    param([string]$IP, [string]$APIKey)
    # Return cached result if < 1 hour old
    if ($CTICache.ContainsKey($IP)) {
        $cached = $CTICache[$IP]
        if (((Get-Date) - $cached.Time).TotalHours -lt 1) {
            $cached.Data.Cached = 'Yes'
            return $cached.Data
        }
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
        $headers = @{ 'x-api-key' = $APIKey; 'User-Agent' = 'PaladinNetWatch/1.0' }
        $data = Invoke-RestMethod -Uri "$CTIBase/$IP" -Headers $headers -Method Get -EA Stop

        # Parse behaviors
        $behaviorList = ''
        if ($null -ne $data.behaviors) {
            $behaviorList = ($data.behaviors | ForEach-Object { $_.label }) -join ', '
        }

        # Parse blocklists
        $blocklistNames = ''
        if ($null -ne $data.references) {
            $blocklistNames = ($data.references | ForEach-Object { $_.name }) -join ', '
        }

        # Reputation score (0-100 if available)
        $score = ''
        if ($null -ne $data.scores -and $null -ne $data.scores.overall) {
            $score = [string][int]$data.scores.overall.aggressiveness
        }

        $lsDt1 = try { ([datetime]$data.history.last_seen).ToString('MM/dd HH:mm') } catch { '' }
        $result = [PSCustomObject]@{
            IP         = $IP
            Reputation = [string]$data.ip_range_score
            Score      = $score
            Behaviors  = $behaviorList
            Country    = [string]$data.location.country
            AS         = [string]$data.as_name
            Blocklists = $blocklistNames
            LastSeen   = $lsDt1
            Cached     = 'No'
            RawRep     = [string]$data.ip_range_score
        }
        $CTICache[$IP] = @{ Time = Get-Date; Data = $result }
        return $result
    } catch {
        $errMsg = $_.Exception.Message
        # 404 = IP not in CTI database (clean)
        $rep = if ($errMsg -match '404') { 'clean' } else { "error: $errMsg" }
        return [PSCustomObject]@{
            IP=$IP; Reputation=$rep; Score=''; Behaviors=''; Country=''; AS='';
            Blocklists=''; LastSeen=''; Cached='No'; RawRep=$rep
        }
    }
}

function Add-CTIResult { param($Result)
    if ($null -eq $Result) { return }
    # Remove existing entry for same IP then add new
    $existing = $ctiResults | Where-Object { $_.IP -eq $Result.IP }
    if ($null -ne $existing) { $ctiResults.Remove($existing) | Out-Null }
    $ctiResults.Insert(0, $Result) | Out-Null
}

function Get-RepColor { param([string]$Rep)
    switch ($Rep.ToLower()) {
        'malicious'  { return '#F44336' }
        'suspicious' { return '#FF9800' }
        'known'      { return '#2196F3' }
        'clean'      { return '#4CAF50' }
        default      { return '#888888' }
    }
}

# =============================================================================
# DISPATCHER TIMER -- polls $sync, updates UI (KI-141: GetNewClosure required)
# =============================================================================
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(3)

$lSync          = $sync
$lTxtStatus     = $txtStatus
$lTxtLastRefresh= $txtLastRefresh
$lTxtFlagCount  = $txtFlagCount

$timer.Add_Tick(({
    try {
        Update-Overview
        Apply-ConnectionFilter
        Apply-DNSFilter
        Update-Firewall
        Update-Threats
        if ($null -ne $lTxtStatus -and -not [string]::IsNullOrEmpty($lSync.StatusMsg)) {
            $lTxtStatus.Text = $lSync.StatusMsg
        }
        if ($null -ne $lTxtLastRefresh -and -not [string]::IsNullOrEmpty($lSync.LastRefresh)) {
            $lTxtLastRefresh.Text = "Last refresh: $($lSync.LastRefresh)"
        }
        if ($null -ne $lTxtFlagCount) {
            $fc = [int]$lSync.FlagCount
            $lTxtFlagCount.Text = if ($fc -gt 0) { "! $fc flag$(if($fc-ne 1){'s'})" } else { '' }
        }
    } catch { }
}).GetNewClosure())   # KI-141: mandatory

$timer.Start()

# =============================================================================
# BUTTON HANDLERS
# =============================================================================

# Refresh Now
$lSync2 = $sync
if ($null -ne $btnRefresh) {
    $btnRefresh.Add_Click(({
        $lSync2.StatusMsg = 'Manual refresh triggered...'
    }).GetNewClosure())
}

# Export Log
$lBaseDir = $BaseDir
$lMachine = $MachineName
if ($null -ne $btnExport) {
    $btnExport.Add_Click(({
        $exportPath = "$lBaseDir\NetWatch-Export-$(Get-Date -Format 'yyyy-MM-dd_HH-mm').txt"
        try {
            $lines = @("Paladin NetWatch Export -- $(Get-Date) -- $lMachine", ('=' * 60))
            [System.IO.File]::WriteAllLines($exportPath, $lines, [System.Text.Encoding]::ASCII)
            Start-Process notepad.exe $exportPath
        } catch {}
    }).GetNewClosure())
}

# Flight Recorder Snapshot
$lSnapBase = $BaseDir
$lSnapSync = $sync
$lSnapMach = $MachineName
if ($null -ne $btnSnapshot) {
    $btnSnapshot.Add_Click(({
        $ts      = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
        $snapDir = "$lSnapBase\FlightRecorder\$ts"
        try {
            New-Item $snapDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null
            # Connections
            $lSnapSync.Connections | ForEach-Object { "$($_.PID)`t$($_.Process)`t$($_.Local)`t$($_.Remote)`t$($_.State)`t$($_.Flag)`t$($_.Note)" } |
                Set-Content "$snapDir\connections.tsv" -EA SilentlyContinue
            # DNS Cache
            $lSnapSync.DNSCache | ForEach-Object { "$($_.Name)`t$($_.Type)`t$($_.Data)`t$($_.TTL)`t$($_.Flag)" } |
                Set-Content "$snapDir\dns-cache.tsv" -EA SilentlyContinue
            # Threats
            $lSnapSync.Threats | ForEach-Object { "$($_.Severity)`t$($_.Type)`t$($_.Process)`t$($_.Detail)`t$($_.Remote)" } |
                Set-Content "$snapDir\threats.tsv" -EA SilentlyContinue
            # Adapters
            $lSnapSync.Adapters | ForEach-Object { "$($_.Name)`t$($_.IP)`t$($_.Gateway)`t$($_.Health)`t$($_.Sent)`t$($_.Recv)" } |
                Set-Content "$snapDir\adapters.tsv" -EA SilentlyContinue
            # Summary
            @(
                "Paladin NetWatch Flight Recorder Snapshot",
                "Machine  : $lSnapMach",
                "Time     : $(Get-Date)",
                "Connections: $($lSnapSync.Connections.Count)",
                "Threats  : $($lSnapSync.ThreatCount)",
                "DNS Entries: $($lSnapSync.DNSCache.Count)"
            ) | Set-Content "$snapDir\summary.txt" -EA SilentlyContinue
            Start-Process explorer.exe $snapDir
        } catch { }
    }).GetNewClosure())
}

# Flush DNS
if ($null -ne $btnFlushDNS) {
    $btnFlushDNS.Add_Click(({
        try { & ipconfig.exe /flushdns 2>&1 | Out-Null } catch {}
    }).GetNewClosure())
}

# Connection filters -- direct function calls (no Invoke-Expression)
if ($null -ne $txtConnFilter) {
    $txtConnFilter.Add_TextChanged(({ Apply-ConnectionFilter }).GetNewClosure())
}
if ($null -ne $chkEstablished) {
    $chkEstablished.Add_Checked(({   Apply-ConnectionFilter }).GetNewClosure())
    $chkEstablished.Add_Unchecked(({ Apply-ConnectionFilter }).GetNewClosure())
}
if ($null -ne $chkFlagged) {
    $chkFlagged.Add_Checked(({   Apply-ConnectionFilter }).GetNewClosure())
    $chkFlagged.Add_Unchecked(({ Apply-ConnectionFilter }).GetNewClosure())
}

# DNS filter -- direct function calls
if ($null -ne $txtDNSFilter) {
    $txtDNSFilter.Add_TextChanged(({ Apply-DNSFilter }).GetNewClosure())
}
if ($null -ne $chkDNSSuspect) {
    $chkDNSSuspect.Add_Checked(({   Apply-DNSFilter }).GetNewClosure())
    $chkDNSSuspect.Add_Unchecked(({ Apply-DNSFilter }).GetNewClosure())
}

# =============================================================================
# DIAGNOSTICS HANDLERS -- run probes in background jobs, output to textbox
# =============================================================================

function Invoke-DiagProbe {
    param([string]$Label, [string]$Target, [scriptblock]$Probe)
    if ($null -ne $txtDiagStatus) { $txtDiagStatus.Text = "Running: $Label..." }
    $lOut    = $txtDiagOutput
    $lStatus = $txtDiagStatus
    $lLabel  = $Label
    $job = Start-Job -ScriptBlock $Probe -ArgumentList $Target
    $diag_timer = New-Object System.Windows.Threading.DispatcherTimer
    $diag_timer.Interval = [TimeSpan]::FromSeconds(1)
    $lDTimer = $diag_timer
    $lJob    = $job
    $diag_timer.Add_Tick(({
        if ($null -eq $lJob -or $lJob.State -ne 'Running') {
            $lDTimer.Stop()
            if ($null -ne $lJob) {
                $result = Receive-Job $lJob -EA SilentlyContinue
                Remove-Job $lJob -Force -EA SilentlyContinue
                $out = ($result -join "`n").Trim()
                if ($null -ne $lOut) {
                    $lOut.AppendText("`n--- $lLabel ($(Get-Date -Format 'HH:mm:ss')) ---`n$out`n")
                    $lOut.ScrollToEnd()
                }
            }
            if ($null -ne $lStatus) { $lStatus.Text = "$lLabel complete" }
        }
    }).GetNewClosure())
    $diag_timer.Start()
}

# Gather gateway + DNS server for probe buttons
$gwIP  = ''
$dnsIP = ''
try {
    try {
        $ipcfgGW = & ipconfig.exe 2>&1
        foreach ($ln in $ipcfgGW) {
            if ($ln -match 'Default Gateway.+?:\s*([\d\.]+)' -and [string]::IsNullOrEmpty($gwIP)) { $gwIP = $Matches[1].Trim() }
            if ($ln -match 'DNS Servers.+?:\s*([\d\.]+)' -and [string]::IsNullOrEmpty($dnsIP))  { $dnsIP = $Matches[1].Trim() }
        }
    } catch {}
} catch {}

$lGW  = $gwIP
$lDNS = $dnsIP

if ($null -ne $btnPingGW) {
    $btnPingGW.Add_Click(({
        $target = $lGW; if ([string]::IsNullOrEmpty($target)) { $target = '192.168.1.1' }
        Invoke-DiagProbe "Ping Gateway ($target)" $target { param($t) & ping.exe -n 4 $t 2>&1 }
    }).GetNewClosure())
}

if ($null -ne $btnPingDNS) {
    $btnPingDNS.Add_Click(({
        $target = $lDNS; if ([string]::IsNullOrEmpty($target)) { $target = '8.8.8.8' }
        Invoke-DiagProbe "Ping DNS ($target)" $target { param($t) & ping.exe -n 4 $t 2>&1 }
    }).GetNewClosure())
}

if ($null -ne $btnPingInternet) {
    $btnPingInternet.Add_Click(({
        Invoke-DiagProbe 'Ping Internet (8.8.8.8)' '8.8.8.8' { param($t) & ping.exe -n 4 $t 2>&1 }
    }).GetNewClosure())
}

if ($null -ne $btnDNSTest) {
    $lInput = $txtDiagInput
    $btnDNSTest.Add_Click(({
        $target = if ($null -ne $lInput -and -not [string]::IsNullOrEmpty($lInput.Text)) { $lInput.Text.Trim() } else { 'google.com' }
        Invoke-DiagProbe "DNS Resolve ($target)" $target { param($t) & nslookup.exe $t 2>&1 }
    }).GetNewClosure())
}

if ($null -ne $btnHTTPTest) {
    $lInput2 = $txtDiagInput
    $btnHTTPTest.Add_Click(({
        $target = if ($null -ne $lInput2 -and -not [string]::IsNullOrEmpty($lInput2.Text)) { $lInput2.Text.Trim() } else { 'https://google.com' }
        if ($target -notmatch '^https?://') { $target = "https://$target" }
        Invoke-DiagProbe "HTTP Test ($target)" $target {
            param($t)
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $r  = Invoke-WebRequest -Uri $t -TimeoutSec 10 -UseBasicParsing -EA Stop
                $sw.Stop()
                "Status  : $([int]$r.StatusCode) $($r.StatusDescription)`nTime    : $($sw.ElapsedMilliseconds)ms`nSize    : $($r.RawContentLength) bytes"
            } catch { "FAILED: $($_.Exception.Message)" }
        }
    }).GetNewClosure())
}

if ($null -ne $btnTracert) {
    $lInput3 = $txtDiagInput
    $btnTracert.Add_Click(({
        $target = if ($null -ne $lInput3 -and -not [string]::IsNullOrEmpty($lInput3.Text)) { $lInput3.Text.Trim() } else { '8.8.8.8' }
        Invoke-DiagProbe "Tracert ($target)" $target { param($t) & tracert.exe -d -w 1000 $t 2>&1 }
    }).GetNewClosure())
}

if ($null -ne $btnClearDiag) {
    $lDiagOut = $txtDiagOutput
    $btnClearDiag.Add_Click(({
        if ($null -ne $lDiagOut) { $lDiagOut.Clear() }
    }).GetNewClosure())
}

# =============================================================================
# FIREWALL MANAGEMENT HANDLERS
# =============================================================================

if ($null -ne $btnFWEnableAll) {
    $btnFWEnableAll.Add_Click(({
        try {
            & netsh.exe advfirewall set allprofiles state on 2>&1 | Out-Null
            # Force immediate visual refresh on all three buttons
            Update-Firewall
            if ($null -ne $txtStatus) { $txtStatus.Text = 'All firewall profiles enabled' }
        } catch {}
    }).GetNewClosure())
}

if ($null -ne $btnFWDisableAll) {
    $btnFWDisableAll.Add_Click(({
        $confirm = [System.Windows.MessageBox]::Show(
            'WARNING: Disabling the firewall on all profiles reduces security. Continue?',
            'NetWatch - Confirm','YesNo','Warning')
        if ($confirm -eq 'Yes') {
            try {
                & netsh.exe advfirewall set allprofiles state off 2>&1 | Out-Null
                Update-Firewall
                if ($null -ne $txtStatus) { $txtStatus.Text = 'All firewall profiles disabled' }
            } catch {}
        }
    }).GetNewClosure())
}

# Per-profile toggle buttons -- run netsh elevated (requires admin)
# KI-140 avoided: no foreach loop, each handler has literals baked in
# Firewall profile toggle helpers -- read state from TextBlock, run netsh, update button immediately
$fwGreenBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#107C10'))
$fwRedBrush   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#C42B1C'))

function Toggle-FWProfile {
    param(
        [string]$Profile,
        [System.Windows.Controls.Button]$Btn,
        [System.Windows.Controls.TextBlock]$StateTxt,
        [System.Windows.Controls.TextBlock]$StatusBar,
        [System.Windows.Media.SolidColorBrush]$GreenBrush,
        [System.Windows.Media.SolidColorBrush]$RedBrush
    )
    # Read current state from TextBlock (already showing ON/OFF from last poll)
    $curState = if ($null -ne $StateTxt) { [string]$StateTxt.Text } else { 'OFF' }
    $newState = if ($curState -eq 'ON') { 'off' } else { 'on' }

    # Correct netsh profile keyword -- domain/private/public -> domainprofile/privateprofile/publicprofile
    $profileArg = switch ($Profile.ToLower()) {
        'domain'  { 'domainprofile'  }
        'private' { 'privateprofile' }
        'public'  { 'publicprofile'  }
        default   { "${Profile}profile" }
    }

    if ($null -ne $StatusBar) { $StatusBar.Text = "Firewall $Profile -> $newState ..." }

    $out = & netsh.exe advfirewall set $profileArg state $newState 2>&1
    $ok  = ($LASTEXITCODE -eq 0)

    if ($ok) {
        # Update UI immediately -- don't wait for next runspace poll
        if ($null -ne $StateTxt) { $StateTxt.Text = $newState.ToUpper() }
        if ($null -ne $Btn) {
            $Btn.Background = if ($newState -eq 'on') { $GreenBrush } else { $RedBrush }
        }
        if ($null -ne $StatusBar) { $StatusBar.Text = "Firewall $Profile set $($newState.ToUpper())" }

        # Force-refresh FWProfiles in sync so runspace picks up new state immediately
        $refreshed = @()
        $raw = & netsh.exe advfirewall show allprofiles state 2>&1
        $rc  = $null
        foreach ($line in $raw) {
            if ($line -match '(Domain|Private|Public)\s+Profile\s+Settings') { $rc = $Matches[1] }
            if ($line -match 'State\s+(ON|OFF)' -and $null -ne $rc) {
                $refreshed += @{ Profile=$rc; State=$Matches[1] }
                $rc = $null
            }
        }
        if ($refreshed.Count -gt 0) { $sync.FWProfiles = $refreshed }
    } else {
        $msg = ($out -join ' ').Trim()
        if ($null -ne $StatusBar) { $StatusBar.Text = "WARN: $Profile toggle failed -- $msg" }
    }
}

# Capture references as locals (KI-140 -- no foreach loop)
$lBtnD    = $btnFWDomain;  $lTxtD  = $txtFWDomain;  $lStatBar = $txtStatus
$lBtnPr   = $btnFWPrivate; $lTxtPr = $txtFWPrivate
$lBtnPu   = $btnFWPublic;  $lTxtPu = $txtFWPublic
$lGreen   = $fwGreenBrush; $lRed   = $fwRedBrush

if ($null -ne $lBtnD) {
    $lBtnD.Add_Click(({
        Toggle-FWProfile 'domain'  $lBtnD  $lTxtD  $lStatBar $lGreen $lRed
    }).GetNewClosure())
}
if ($null -ne $lBtnPr) {
    $lBtnPr.Add_Click(({
        Toggle-FWProfile 'private' $lBtnPr $lTxtPr $lStatBar $lGreen $lRed
    }).GetNewClosure())
}
if ($null -ne $lBtnPu) {
    $lBtnPu.Add_Click(({
        Toggle-FWProfile 'public'  $lBtnPu $lTxtPu $lStatBar $lGreen $lRed
    }).GetNewClosure())
}

if ($null -ne $btnAddRule) {
    $lRuleName   = $txtRuleName
    $lRulePort   = $txtRulePort
    $lRuleProto  = $cmbRuleProto
    $lRuleDir    = $cmbRuleDir
    $lRuleAction = $cmbRuleAction
    $btnAddRule.Add_Click(({
        $name   = if ($null -ne $lRuleName   -and -not [string]::IsNullOrEmpty($lRuleName.Text))   { $lRuleName.Text.Trim() }   else { 'Paladin-Rule' }
        $port   = if ($null -ne $lRulePort   -and -not [string]::IsNullOrEmpty($lRulePort.Text))   { $lRulePort.Text.Trim() }   else { '' }
        $proto  = if ($null -ne $lRuleProto  -and $null -ne $lRuleProto.SelectedItem)  { $lRuleProto.SelectedItem.Content }  else { 'TCP' }
        $dir    = if ($null -ne $lRuleDir    -and $null -ne $lRuleDir.SelectedItem)    { $lRuleDir.SelectedItem.Content }    else { 'Inbound' }
        $action = if ($null -ne $lRuleAction -and $null -ne $lRuleAction.SelectedItem) { $lRuleAction.SelectedItem.Content } else { 'Allow' }

        if ([string]::IsNullOrEmpty($port)) {
            [System.Windows.MessageBox]::Show('Port is required.','NetWatch','OK','Warning') | Out-Null; return
        }
        if ($port -notmatch '^\d+(-\d+)?$') {
            [System.Windows.MessageBox]::Show('Port must be a number or range (e.g. 8080 or 8080-8090).','NetWatch','OK','Warning') | Out-Null; return
        }

        try {
            $dirArg    = if ($dir -eq 'Inbound') { 'in' } else { 'out' }
            $actionArg = $action.ToLower()
            $protoArg  = if ($proto -eq 'Any') { 'any' } else { $proto.ToLower() }

            $result = & netsh.exe advfirewall firewall add rule `
                name=$name dir=$dirArg action=$actionArg protocol=$protoArg localport=$port 2>&1

            if ($LASTEXITCODE -eq 0) {
                [System.Windows.MessageBox]::Show("Rule added:`n$name`n$dir | $proto | Port $port | $action",'NetWatch','OK','Information') | Out-Null
                if ($null -ne $lRuleName) { $lRuleName.Text = '' }
                if ($null -ne $lRulePort) { $lRulePort.Text = '' }
            } else {
                [System.Windows.MessageBox]::Show("Failed to add rule:`n$($result -join ' ')",'NetWatch','OK','Error') | Out-Null
            }
        } catch { [System.Windows.MessageBox]::Show("Error: $($_.Exception.Message)",'NetWatch','OK','Error') | Out-Null }
    }).GetNewClosure())
}


$lSync3    = $sync
$lTimer    = $timer
$lPS       = $ps
$lRS       = $rs
$lBaseDir2 = $BaseDir
$lUDF      = $UDFSlot
$lMachine2 = $MachineName

$window.Add_Closed(({
    $lSync3.Running = $false
    $lTimer.Stop()
    try { $lPS.EndInvoke($lPS.BeginInvoke()) } catch {}
    try { $lRS.Close() } catch {}
    # Signal file for Datto SYSTEM process
    try { [System.IO.File]::WriteAllText("$lBaseDir2\gui.closed", (Get-Date -Format 'o'), [System.Text.Encoding]::ASCII) } catch {}
    # UDF summary
    $fc  = [int]$lSync3.FlagCount
    $cc  = if ($null -ne $lSync3.Connections) { $lSync3.Connections.Count } else { 0 }
    $msg = "PASS $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $lMachine2 | Connections:$cc | Flags:$fc"
    Set-DattoUDF -Slot $lUDF -Value $msg
}).GetNewClosure())

# =============================================================================
# CTI BUTTON HANDLERS
# =============================================================================

$lCTIResults  = $ctiResults
$lCTIStatus   = $txtCTIStatus
$lCTIInput    = $txtCTIInput
$lSync5       = $sync

# Set API Key
if ($null -ne $btnCTISetKey) {
    $lStat0 = $txtCTIStatus
    $btnCTISetKey.Add_Click(({
        $keyWin = New-Object System.Windows.Window
        $keyWin.Title  = 'CrowdSec CTI API Key'
        $keyWin.Width  = 420; $keyWin.Height = 160
        $keyWin.WindowStartupLocation = 'CenterScreen'
        $keyWin.ResizeMode = 'NoResize'
        $keyWin.Background = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString('#2D2D2D'))
        $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '16,16,16,16'
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = 'Enter your CrowdSec CTI API key:'
        $lbl.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString('White'))
        $lbl.Margin = '0,0,0,8'
        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Background = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString('#3C3C3C'))
        $tb.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString('White'))
        $tb.Padding = '6,4'; $tb.Margin = '0,0,0,12'
        $existing = Get-CTIKey
        if (-not [string]::IsNullOrEmpty($existing)) { $tb.Text = $existing }
        $btnOK = New-Object System.Windows.Controls.Button
        $btnOK.Content = 'Save'
        $btnOK.HorizontalAlignment = 'Right'
        $btnOK.Background = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString('#0078D4'))
        $btnOK.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString('White'))
        $btnOK.Padding = '16,5'; $btnOK.MinWidth = 80
        $lkw = $keyWin
        $btnOK.Add_Click(({ $lkw.DialogResult = $true; $lkw.Close() }).GetNewClosure())
        $sp.Children.Add($lbl)   | Out-Null
        $sp.Children.Add($tb)    | Out-Null
        $sp.Children.Add($btnOK) | Out-Null
        $keyWin.Content = $sp
        if ($keyWin.ShowDialog() -eq $true -and -not [string]::IsNullOrEmpty($tb.Text)) {
            $ok = Set-CTIKey $tb.Text.Trim()
            if ($null -ne $lStat0) {
                $lStat0.Text = if ($ok) { 'API key saved' } else { 'ERROR: Could not save key' }
            }
        }
    }).GetNewClosure())
}

# Single IP Lookup
if ($null -ne $btnCTILookup) {
    $lInput  = $txtCTIInput
    $lStat1  = $txtCTIStatus
    $lRes    = $ctiResults
    $lCache  = $CTICache
    $lBase   = $CTIBase
    $btnCTILookup.Add_Click(({
        $ip = if ($null -ne $lInput -and -not [string]::IsNullOrEmpty($lInput.Text)) { $lInput.Text.Trim() } else { '' }
        if ([string]::IsNullOrEmpty($ip)) { if ($null -ne $lStat1) { $lStat1.Text = 'Enter an IP first' }; return }
        $key = Get-CTIKey
        if ([string]::IsNullOrEmpty($key)) { if ($null -ne $lStat1) { $lStat1.Text = 'Set API Key first' }; return }
        # Check cache
        if ($lCache.ContainsKey($ip)) {
            $c = $lCache[$ip]
            if (((Get-Date) - $c.Time).TotalHours -lt 1) {
                $c.Data.Cached = 'Yes'
                $ex = $lRes | Where-Object { $_.IP -eq $ip }
                if ($null -ne $ex) { $lRes.Remove($ex) | Out-Null }
                $lRes.Insert(0, $c.Data) | Out-Null
                if ($null -ne $lStat1) { $lStat1.Text = "Cached result: $ip -> $($c.Data.Reputation)" }
                return
            }
        }
        $kprev = if ($key.Length -gt 8) { $key.Substring(0,8) + "..." } else { "(short)" }
        if ($null -ne $lStat1) { $lStat1.Text = "Looking up $ip (key: $kprev)..." }
        $lIp2 = $ip; $lKey2 = $key; $lBase2 = $lBase
        $job = Start-Job -ScriptBlock {
            param($ip,$key,$base)
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
                $headers = @{ 'x-api-key' = $key; 'User-Agent' = 'PaladinNetWatch/1.0' }
                $resp = Invoke-RestMethod -Uri "$base/$ip" -Headers $headers -Method Get -EA Stop
                $json = $resp | ConvertTo-Json -Depth 10
                return @{ IP=$ip; JSON=$json; Err='' }
            } catch {
                $msg = $_.Exception.Message
                if ($_.Exception.Response) {
                    try { $msg = "HTTP $([int]$_.Exception.Response.StatusCode): $($_.Exception.Response.StatusDescription)" } catch {}
                }
                return @{ IP=$ip; JSON=''; Err=$msg }
            }
        } -ArgumentList $lIp2,$lKey2,$lBase2
        $lt = New-Object System.Windows.Threading.DispatcherTimer
        $lt.Interval = [TimeSpan]::FromSeconds(1)
        $lLt = $lt; $lLj = $job
        $lt.Add_Tick(({
            if ($lLj.State -ne 'Running') {
                $lLt.Stop()
                $d = Receive-Job $lLj -EA SilentlyContinue; Remove-Job $lLj -Force -EA SilentlyContinue
                if ($null -ne $d) {
                    if (-not [string]::IsNullOrEmpty($d.Err)) {
                        $errMsg = $d.Err
                        if ($null -ne $lStat1) { $lStat1.Text = "Error ($ip): $errMsg" }
                    } else {
                        try {
                            $j = $d.JSON | ConvertFrom-Json
                            $beh = if ($null -ne $j.behaviors) { ($j.behaviors | ForEach-Object { $_.label }) -join ', ' } else { '' }
                            $bl  = if ($null -ne $j.references) { ($j.references | ForEach-Object { $_.name }) -join ', ' } else { '' }
                            $sc  = try { [string][int]$j.scores.overall.aggressiveness } catch { '' }
                            $lsDtL = try { ([datetime]$j.history.last_seen).ToString('MM/dd HH:mm') } catch { '' }
                            $r = [PSCustomObject]@{
                                IP=$d.IP; Reputation=[string]$j.ip_range_score; Score=$sc
                                Behaviors=$beh; Country=[string]$j.location.country
                                AS=[string]$j.as_name; Blocklists=$bl
                                LastSeen=$lsDtL; Cached='No'; RawRep=[string]$j.ip_range_score
                            }
                            $lCache[$d.IP] = @{ Time=Get-Date; Data=$r }
                            $ex = $lRes | Where-Object { $_.IP -eq $r.IP }
                            if ($null -ne $ex) { $lRes.Remove($ex) | Out-Null }
                            $lRes.Insert(0, $r) | Out-Null
                            if ($null -ne $lStat1) { $lStat1.Text = "$($d.IP) -> $($r.Reputation)" }
                        } catch { if ($null -ne $lStat1) { $lStat1.Text = "Parse error: $($_.Exception.Message)" } }
                    }
                }
            }
        }).GetNewClosure())
        $lt.Start()
    }).GetNewClosure())
}

# Scan All
if ($null -ne $btnCTIScanAll) {
    $lStat2  = $txtCTIStatus
    $lRes2   = $ctiResults
    $lCache2 = $CTICache
    $lBase3  = $CTIBase
    $lSync6  = $sync
    $btnCTIScanAll.Add_Click(({
        $key = Get-CTIKey
        if ([string]::IsNullOrEmpty($key)) { if ($null -ne $lStat2) { $lStat2.Text = 'Set API Key first' }; return }
        $conns = $lSync6.Connections
        if ($null -eq $conns) { return }
        $ips = @($conns | Where-Object {
            $_.State -eq 'Established' -and -not [string]::IsNullOrEmpty($_.Remote) -and $_.Remote -ne '-'
        } | ForEach-Object { ($_.Remote -split ':')[0] } |
        Where-Object { $_ -notmatch '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.|::1|0\.0\.0\.0)' } |
        Sort-Object -Unique)
        if ($ips.Count -eq 0) { if ($null -ne $lStat2) { $lStat2.Text = 'No public IPs to scan' }; return }
        if ($null -ne $lStat2) { $lStat2.Text = "Scanning $($ips.Count) IPs..." }
        $lIps2 = $ips; $lKey3 = $key; $lBase4 = $lBase3
        $job = Start-Job -ScriptBlock {
            param($ips,$key,$base)
            $out = @()
            foreach ($ip in $ips) {
                Start-Sleep -Milliseconds 200
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
                    $headers = @{ 'x-api-key' = $key; 'User-Agent' = 'PaladinNetWatch/1.0' }
                    $resp = Invoke-RestMethod -Uri "$base/$ip" -Headers $headers -Method Get -EA Stop
                    $out += @{ IP=$ip; JSON=($resp | ConvertTo-Json -Depth 10); Err='' }
                } catch {
                    $msg = $_.Exception.Message
                    if ($_.Exception.Response) {
                        try { $msg = "HTTP $([int]$_.Exception.Response.StatusCode)" } catch {}
                    }
                    $out += @{ IP=$ip; JSON=''; Err=$msg; Rep=if($msg -match '404'){'clean'}else{'error'} }
                }
            }
            return $out
        } -ArgumentList $lIps2,$lKey3,$lBase4
        $st = New-Object System.Windows.Threading.DispatcherTimer; $st.Interval = [TimeSpan]::FromSeconds(2)
        $lSt = $st; $lSj = $job
        $st.Add_Tick(({
            if ($lSj.State -ne 'Running') {
                $lSt.Stop()
                $arr = @(Receive-Job $lSj -EA SilentlyContinue); Remove-Job $lSj -Force -EA SilentlyContinue
                $mal = 0
                foreach ($d in $arr) {
                    if (-not [string]::IsNullOrEmpty($d.JSON)) {
                        try {
                            $j = $d.JSON | ConvertFrom-Json
                            $beh = if ($null -ne $j.behaviors) { ($j.behaviors | ForEach-Object { $_.label }) -join ', ' } else { '' }
                            $bl  = if ($null -ne $j.references) { ($j.references | ForEach-Object { $_.name }) -join ', ' } else { '' }
                            $sc  = try { [string][int]$j.scores.overall.aggressiveness } catch { '' }
                            $rep = [string]$j.ip_range_score
                            $lsDtS = try { ([datetime]$j.history.last_seen).ToString('MM/dd HH:mm') } catch { '' }
                            $r = [PSCustomObject]@{
                                IP=$d.IP; Reputation=$rep; Score=$sc; Behaviors=$beh
                                Country=[string]$j.location.country; AS=[string]$j.as_name
                                Blocklists=$bl; LastSeen=$lsDtS; Cached='No'; RawRep=$rep
                            }
                            $lCache2[$d.IP] = @{ Time=Get-Date; Data=$r }
                            $ex = $lRes2 | Where-Object { $_.IP -eq $r.IP }
                            if ($null -ne $ex) { $lRes2.Remove($ex) | Out-Null }
                            $lRes2.Insert(0, $r) | Out-Null
                            if ($rep -eq 'malicious') { $mal++ }
                        } catch {}
                    } else {
                        $rep = if ($null -ne $d.Rep) { $d.Rep } else { 'error' }
                        $r = [PSCustomObject]@{ IP=$d.IP; Reputation=$rep; Score=''; Behaviors=''; Country=''; AS=''; Blocklists=''; LastSeen=''; Cached='No'; RawRep=$rep }
                        $ex = $lRes2 | Where-Object { $_.IP -eq $r.IP }
                        if ($null -ne $ex) { $lRes2.Remove($ex) | Out-Null }
                        $lRes2.Insert(0, $r) | Out-Null
                    }
                }
                if ($null -ne $lStat2) { $lStat2.Text = "Scan done: $($arr.Count) IPs | $mal malicious" }
            }
        }).GetNewClosure())
        $st.Start()
    }).GetNewClosure())
}

# Clear CTI
if ($null -ne $btnCTIClear) {
    $lRes3 = $ctiResults
    $btnCTIClear.Add_Click(({ $lRes3.Clear() }).GetNewClosure())
}

# =============================================================================
# BLOCKLIST HANDLERS
# =============================================================================

$lBLItems  = $blocklistItems
$lBLFile   = $BlocklistFile
$lBLStatus = $txtBlockStatus

function Save-Blocklist {
    try {
        $serBL2 = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $arr = New-Object System.Collections.ArrayList
        foreach ($i in $lBLItems) { $arr.Add($i) | Out-Null }
        [System.IO.File]::WriteAllText($lBLFile, $serBL2.Serialize($arr), [System.Text.Encoding]::ASCII)
    } catch { Write-Log "WARN: Blocklist save failed: $($_.Exception.Message)" 'WARN' }
}

function Add-BlockRule {
    param([string]$IP, [string]$Action, [string]$Direction, [string]$Note)
    if ([string]::IsNullOrEmpty($IP)) { return }
    $dirLabel = if ([string]::IsNullOrEmpty($Direction)) { 'Both' } else { $Direction }

    # Build unique rule name
    $safeName = "Paladin_$Action_$($IP -replace '[\.:/]','_')"

    $item = [PSCustomObject]@{
        Action    = $Action.ToUpper()
        IP        = $IP
        Direction = $dirLabel
        Note      = $Note
        RuleName  = $safeName
        Added     = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        Status    = 'Pending'
    }
    $existing = $lBLItems | Where-Object { $_.IP -eq $IP -and $_.Action -eq $Action.ToUpper() }
    if ($null -ne $existing) { $lBLItems.Remove($existing) | Out-Null }
    $lBLItems.Insert(0, $item) | Out-Null
    Save-Blocklist
    if ($null -ne $lBLStatus) { $lBLStatus.Text = "$Action rule added for $IP (click Apply to enforce)" }
}

function Apply-BlocklistRules {
    $applied = 0; $failed = 0
    foreach ($item in $lBLItems) {
        $dirs = if ($item.Direction -eq 'Both') { @('in','out') }
                elseif ($item.Direction -eq 'Inbound') { @('in') }
                else { @('out') }
        $fwAction = if ($item.Action -eq 'BLOCK') { 'block' } else { 'allow' }

        foreach ($dir in $dirs) {
            $rn = "$($item.RuleName)_$dir"
            # Remove existing rule first
            & netsh.exe advfirewall firewall delete rule name=$rn 2>&1 | Out-Null
            $out = & netsh.exe advfirewall firewall add rule name=$rn `
                dir=$dir action=$fwAction remoteip=$($item.IP) protocol=any enable=yes 2>&1
            if ($LASTEXITCODE -eq 0) { $applied++ }
            else { $failed++; Write-Log "WARN: Rule failed $rn : $($out -join ' ')" 'WARN' }
        }
        $item.Status = if ($failed -eq 0) { 'Active' } else { 'Error' }
    }
    $lBLItems | ForEach-Object { } # trigger refresh
    if ($null -ne $dgBlocklist) { $dgBlocklist.Items.Refresh() }
    Save-Blocklist
    if ($null -ne $lBLStatus) { $lBLStatus.Text = "Applied: $applied rules | Failed: $failed" }
}

# Block Selected (from Threats or CTI tab via selected IP in txtBlockIP)
if ($null -ne $btnBlockAdd) {
    $lTxtBIP = $txtBlockIP; $lTxtBNote = $txtBlockNote; $lCmbBDir = $cmbBlockDir
    $btnBlockAdd.Add_Click(({
        $ip  = if ($null -ne $lTxtBIP   -and -not [string]::IsNullOrEmpty($lTxtBIP.Text))   { $lTxtBIP.Text.Trim() }   else { '' }
        $note= if ($null -ne $lTxtBNote -and -not [string]::IsNullOrEmpty($lTxtBNote.Text)) { $lTxtBNote.Text.Trim() } else { 'Manual block' }
        $dir = if ($null -ne $lCmbBDir  -and $null -ne $lCmbBDir.SelectedItem) { $lCmbBDir.SelectedItem.Content } else { 'Both' }
        if ([string]::IsNullOrEmpty($ip)) { if ($null -ne $lBLStatus) { $lBLStatus.Text = 'Enter an IP first' }; return }
        Add-BlockRule $ip 'BLOCK' $dir $note
    }).GetNewClosure())
}

if ($null -ne $btnBlockAllow) {
    $lTxtBIP2 = $txtBlockIP; $lTxtBNote2 = $txtBlockNote; $lCmbBDir2 = $cmbBlockDir
    $btnBlockAllow.Add_Click(({
        $ip  = if ($null -ne $lTxtBIP2   -and -not [string]::IsNullOrEmpty($lTxtBIP2.Text))   { $lTxtBIP2.Text.Trim() }   else { '' }
        $note= if ($null -ne $lTxtBNote2 -and -not [string]::IsNullOrEmpty($lTxtBNote2.Text)) { $lTxtBNote2.Text.Trim() } else { 'Manual allow' }
        $dir = if ($null -ne $lCmbBDir2  -and $null -ne $lCmbBDir2.SelectedItem) { $lCmbBDir2.SelectedItem.Content } else { 'Both' }
        if ([string]::IsNullOrEmpty($ip)) { if ($null -ne $lBLStatus) { $lBLStatus.Text = 'Enter an IP first' }; return }
        Add-BlockRule $ip 'ALLOW' $dir $note
    }).GetNewClosure())
}

if ($null -ne $btnBlockAddManual) {
    $lTxtBIP3 = $txtBlockIP; $lTxtBNote3 = $txtBlockNote; $lCmbBDir3 = $cmbBlockDir
    $btnBlockAddManual.Add_Click(({
        $ip  = if ($null -ne $lTxtBIP3   -and -not [string]::IsNullOrEmpty($lTxtBIP3.Text))   { $lTxtBIP3.Text.Trim() }   else { '' }
        $note= if ($null -ne $lTxtBNote3 -and -not [string]::IsNullOrEmpty($lTxtBNote3.Text)) { $lTxtBNote3.Text.Trim() } else { 'Manual entry' }
        $dir = if ($null -ne $lCmbBDir3  -and $null -ne $lCmbBDir3.SelectedItem) { $lCmbBDir3.SelectedItem.Content } else { 'Both' }
        if ([string]::IsNullOrEmpty($ip)) { if ($null -ne $lBLStatus) { $lBLStatus.Text = 'Enter an IP first' }; return }
        Add-BlockRule $ip 'BLOCK' $dir $note
    }).GetNewClosure())
}

if ($null -ne $btnBlockRemove) {
    $lDGBL = $dgBlocklist
    $btnBlockRemove.Add_Click(({
        $sel = if ($null -ne $lDGBL) { $lDGBL.SelectedItem } else { $null }
        if ($null -eq $sel) { if ($null -ne $lBLStatus) { $lBLStatus.Text = 'Select a rule to remove' }; return }
        # Remove firewall rules
        foreach ($d in @('in','out')) {
            & netsh.exe advfirewall firewall delete rule name="$($sel.RuleName)_$d" 2>&1 | Out-Null
        }
        $lBLItems.Remove($sel) | Out-Null
        Save-Blocklist
        if ($null -ne $lBLStatus) { $lBLStatus.Text = "Rule removed: $($sel.IP)" }
    }).GetNewClosure())
}

if ($null -ne $btnBlockApply) {
    $btnBlockApply.Add_Click(({ Apply-BlocklistRules }).GetNewClosure())
}

# Export Deployer -- generates a standalone Datto-deployable PS1
if ($null -ne $btnBlockExport) {
    $lBLItems2  = $blocklistItems
    $lBLStatus2 = $txtBlockStatus
    $lBaseDir2  = $BaseDir
    $btnBlockExport.Add_Click(({
        if ($lBLItems2.Count -eq 0) {
            if ($null -ne $lBLStatus2) { $lBLStatus2.Text = 'No rules to export' }; return
        }

        # Build the deployer script content
        $lines = @()
        $lines += '#Requires -Version 3.0'
        $lines += '# Paladin Blocklist Deployer -- generated by Paladin NetWatch'
        $lines += "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Machine: $env:COMPUTERNAME"
        $lines += "# Rules: $($lBLItems2.Count)"
        $lines += '# Deploy via Datto RMM as a PowerShell component -- runs as SYSTEM, no input required.'
        $lines += '# =============================================================='
        $lines += 'param()'
        $lines += 'Set-StrictMode -Off'
        $lines += '$ErrorActionPreference = ''Continue'''
        $lines += '$applied = 0; $failed = 0; $skipped = 0'
        $lines += 'Write-Host "Paladin Blocklist Deployer starting -- $((Get-Date -Format ''yyyy-MM-dd HH:mm:ss''))"'
        $lines += ''

        foreach ($item in $lBLItems2) {
            $dirs = if ($item.Direction -eq 'Both') { @('in','out') }
                    elseif ($item.Direction -eq 'Inbound') { @('in') } else { @('out') }
            $fwAction = if ($item.Action -eq 'BLOCK') { 'block' } else { 'allow' }
            $safeNote = [string]$item.Note -replace "'","''"
            $lines += "# $($item.Action) $($item.IP) -- $safeNote"
            foreach ($dir in $dirs) {
                $rn = "$($item.RuleName)_$dir"
                $lines += "& netsh.exe advfirewall firewall delete rule name='$rn' 2>&1 | Out-Null"
                $lines += "& netsh.exe advfirewall firewall add rule name='$rn' dir=$dir action=$fwAction remoteip='$($item.IP)' protocol=any enable=yes 2>&1 | Out-Null"
                $lines += 'if ($LASTEXITCODE -eq 0) { $applied++; Write-Host "  [OK] ' + "$rn" + '" } else { $failed++; Write-Host "  [FAIL] ' + "$rn" + '" }'
            }
            $lines += ''
        }

        $lines += 'Write-Host "Blocklist Deployer complete: applied=$applied failed=$failed"'
        $lines += '$ts  = Get-Date -Format ''yyyy-MM-dd HH:mm'''
        $lines += '$msg = "PASS $ts | $env:COMPUTERNAME | BlocklistDeployer: applied=$applied failed=$failed rules=$($applied+$failed)"'
        $lines += 'try { New-ItemProperty -Path ''HKLM:\SOFTWARE\CentraStage'' -Name ''Custom31'' -Value $msg -PropertyType String -Force -EA SilentlyContinue | Out-Null } catch {}'
        $lines += 'exit $(if ($failed -eq 0) { 0 } else { 1 })'

        $exportPath = "$lBaseDir2\Paladin-BlocklistDeployer.ps1"
        try {
            [System.IO.File]::WriteAllLines($exportPath, $lines, [System.Text.Encoding]::ASCII)
            if ($null -ne $lBLStatus2) { $lBLStatus2.Text = "Exported: $exportPath" }
            Start-Process notepad.exe $exportPath
        } catch {
            if ($null -ne $lBLStatus2) { $lBLStatus2.Text = "Export failed: $($_.Exception.Message)" }
        }
    }).GetNewClosure())
}

# Right-click on Threats grid -> populate block IP field
if ($null -ne $dgThreats -and $null -ne $txtBlockIP) {
    $lTxtFill = $txtBlockIP
    $lTabs    = $window.FindName('tabs')
    $lTabBL   = $window.FindName('tabBlocklist')
    $dgThreats.Add_MouseRightButtonUp(({
        $sel = $dgThreats.SelectedItem
        if ($null -ne $sel -and -not [string]::IsNullOrEmpty([string]$sel.Remote)) {
            $remIP = ([string]$sel.Remote -split ':')[0]
            if ($null -ne $lTxtFill) { $lTxtFill.Text = $remIP }
            # Switch to Block List tab
            if ($null -ne $lTabs -and $null -ne $lTabBL) { $lTabBL.IsSelected = $true }
        }
    }).GetNewClosure())
}

# Right-click on CTI grid -> populate block IP field
if ($null -ne $dgCTI -and $null -ne $txtBlockIP) {
    $lTxtFill2 = $txtBlockIP
    $lTabBL2   = $window.FindName('tabBlocklist')
    $lTabs2    = $window.FindName('tabs')
    $dgCTI.Add_MouseRightButtonUp(({
        $sel = $dgCTI.SelectedItem
        if ($null -ne $sel -and -not [string]::IsNullOrEmpty([string]$sel.IP)) {
            if ($null -ne $lTxtFill2) { $lTxtFill2.Text = [string]$sel.IP }
            if ($null -ne $lTabs2 -and $null -ne $lTabBL2) { $lTabBL2.IsSelected = $true }
        }
    }).GetNewClosure())
}

# =============================================================================
# HARDENING TAB -- BUILD UI + HANDLERS
# =============================================================================

function Build-HardeningPanel {
    if ($null -eq $panHardening) { return }
    $panHardening.Children.Clear()

    # Group by category
    $categories = $HardenCatalog | ForEach-Object { $_.Category } | Select-Object -Unique

    foreach ($cat in $categories) {
        $catItems = @($HardenCatalog | Where-Object { $_.Category -eq $cat })

        # Category header
        $catBorder = New-Object System.Windows.Controls.Border
        $catBorder.Background  = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString('#007ACC'))
        $catBorder.CornerRadius= New-Object System.Windows.CornerRadius(4)
        $catBorder.Margin      = New-Object System.Windows.Thickness(0,8,0,2)
        $catBorder.Padding     = New-Object System.Windows.Thickness(10,4,10,4)
        $catTxt = New-Object System.Windows.Controls.TextBlock
        $catTxt.Text       = $cat
        $catTxt.Foreground = New-Object System.Windows.Media.SolidColorBrush (
            [System.Windows.Media.ColorConverter]::ConvertFromString('White'))
        $catTxt.FontWeight = [System.Windows.FontWeights]::Bold
        $catTxt.FontSize   = 13
        $catBorder.Child   = $catTxt
        $panHardening.Children.Add($catBorder) | Out-Null

        foreach ($item in $catItems) {
            $localItem = $item   # KI-140 capture

            # Row border
            $rowBorder = New-Object System.Windows.Controls.Border
            $rowBorder.Background = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.ColorConverter]::ConvertFromString('#252526'))
            $rowBorder.CornerRadius = New-Object System.Windows.CornerRadius(4)
            $rowBorder.Margin       = New-Object System.Windows.Thickness(0,2,0,2)
            $rowBorder.Padding      = New-Object System.Windows.Thickness(10,8,10,8)

            $rowGrid = New-Object System.Windows.Controls.Grid
            $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::Auto
            $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = New-Object System.Windows.GridLength(1,[System.Windows.GridUnitType]::Star)
            $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = [System.Windows.GridLength]::Auto
            $rowGrid.ColumnDefinitions.Add($c1) | Out-Null
            $rowGrid.ColumnDefinitions.Add($c2) | Out-Null
            $rowGrid.ColumnDefinitions.Add($c3) | Out-Null

            # Checkbox
            $chk = New-Object System.Windows.Controls.CheckBox
            $chk.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $chk.Margin = New-Object System.Windows.Thickness(0,0,12,0)
            $chk.IsChecked = $HardenChecked[$localItem.Name]
            $chk.Tag = $localItem.Name
            [System.Windows.Controls.Grid]::SetColumn($chk, 0)

            # Save check state on change
            $lHC = $HardenChecked; $lReg = $HardenRegPath
            $chk.Add_Checked(({
                $n = $this.Tag
                $lHC[$n] = $true
                $safe = $n -replace '[^a-zA-Z0-9]','_'
                try {
                    if (-not (Test-Path $lReg)) { New-Item -Path $lReg -Force -EA SilentlyContinue | Out-Null }
                    New-ItemProperty -Path $lReg -Name $safe -Value '1' -PropertyType String -Force -EA SilentlyContinue | Out-Null
                } catch {}
            }).GetNewClosure())
            $chk.Add_Unchecked(({
                $n = $this.Tag
                $lHC[$n] = $false
                $safe = $n -replace '[^a-zA-Z0-9]','_'
                try {
                    New-ItemProperty -Path $lReg -Name $safe -Value '0' -PropertyType String -Force -EA SilentlyContinue | Out-Null
                } catch {}
            }).GetNewClosure())

            # Name + description
            $infoSP = New-Object System.Windows.Controls.StackPanel
            $nameLine = New-Object System.Windows.Controls.StackPanel
            $nameLine.Orientation = [System.Windows.Controls.Orientation]::Horizontal

            $nameTxt = New-Object System.Windows.Controls.TextBlock
            $nameTxt.Text       = $localItem.Name
            $nameTxt.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.ColorConverter]::ConvertFromString('White'))
            $nameTxt.FontWeight = [System.Windows.FontWeights]::SemiBold
            $nameTxt.FontSize   = 13

            $countTxt = New-Object System.Windows.Controls.TextBlock
            $countTxt.Text       = "  ($($localItem.IpCount) IPs)"
            $countTxt.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.ColorConverter]::ConvertFromString('#AAA'))
            $countTxt.FontSize   = 11
            $countTxt.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
            $countTxt.Margin = New-Object System.Windows.Thickness(0,0,0,1)

            $nameLine.Children.Add($nameTxt)  | Out-Null
            $nameLine.Children.Add($countTxt) | Out-Null

            if ($localItem.Risky) {
                $warnTxt = New-Object System.Windows.Controls.TextBlock
                $warnTxt.Text       = '  ⚠ Large list -- may impact firewall performance'
                $warnTxt.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                    [System.Windows.Media.ColorConverter]::ConvertFromString('#FF9800'))
                $warnTxt.FontSize   = 11
                $warnTxt.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
                $warnTxt.Margin = New-Object System.Windows.Thickness(0,0,0,1)
                $nameLine.Children.Add($warnTxt) | Out-Null
            }

            $descTxt = New-Object System.Windows.Controls.TextBlock
            $descTxt.Text        = $localItem.Desc
            $descTxt.Foreground  = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.ColorConverter]::ConvertFromString('#CCC'))
            $descTxt.FontSize    = 11
            $descTxt.TextWrapping= [System.Windows.TextWrapping]::Wrap
            $descTxt.Margin      = New-Object System.Windows.Thickness(0,2,0,0)

            $infoSP.Children.Add($nameLine) | Out-Null
            $infoSP.Children.Add($descTxt)  | Out-Null
            [System.Windows.Controls.Grid]::SetColumn($infoSP, 1)

            # Status label (updated after download)
            $statTxt = New-Object System.Windows.Controls.TextBlock
            $statTxt.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.ColorConverter]::ConvertFromString('#888'))
            $statTxt.FontSize   = 11
            $statTxt.Margin     = New-Object System.Windows.Thickness(12,0,0,0)
            $statTxt.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $statTxt.Name       = 'stat_' + ($localItem.Name -replace '[^a-zA-Z0-9]','_')
            [System.Windows.Controls.Grid]::SetColumn($statTxt, 2)

            $rowGrid.Children.Add($chk)     | Out-Null
            $rowGrid.Children.Add($infoSP)  | Out-Null
            $rowGrid.Children.Add($statTxt) | Out-Null
            $rowBorder.Child = $rowGrid
            $panHardening.Children.Add($rowBorder) | Out-Null
        }
    }
}

# Build the panel
if ($null -ne $panHardening) { Build-HardeningPanel }

# Helper: parse raw IP list text into array of clean IPs/CIDRs
function Parse-IPList {
    param([string]$Text, [string]$Format)
    $ips = [System.Collections.Generic.List[string]]::new()
    # Normalize line endings -- handle both CRLF and LF
    $lines = $Text -replace "`r`n","`n" -replace "`r","`n" -split "`n"
    foreach ($line in $lines) {
        $line = $line.Trim()
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($Format -eq 'dshield') {
            # DShield: tab-separated cols: StartIP EndIP Prefix Count AS Country Email
            # Extract first column (start of /24 block) -> build /24 CIDR
            $cols = $line -split '	'
            if ($cols.Count -ge 1 -and $cols[0] -match '^(\d+\.\d+\.\d+)\.\d+') {
                $ips.Add("$($Matches[1]).0/24") | Out-Null
            }
        } elseif ($Format -eq 'hosts') {
            # Standard hosts: "127.0.0.1 hostname" -- take col 0 if it's a routable IP
            $parts = $line -split '\s+'
            if ($parts.Count -ge 1 -and $parts[0] -match '^\d+\.\d+\.\d+\.\d+') {
                $ip = $parts[0]
                if ($ip -notmatch '^(127\.|0\.|255\.|::1)') { $ips.Add($ip) | Out-Null }
            }
        } elseif ($Format -eq 'hosts-ip') {
            # ThreatFox hostfile: "IP hostname" -- IP is col 0, skip loopback/broadcast
            $parts = $line -split '\s+'
            if ($parts.Count -ge 2 -and $parts[0] -match '^\d+\.\d+\.\d+\.\d+') {
                $ip = $parts[0]
                if ($ip -notmatch '^(127\.|0\.|255\.)') { $ips.Add($ip) | Out-Null }
            }
        } else {
            # plain / netset: one IP or CIDR per line, ignore anything after whitespace
            if ($line -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(/\d{1,2})?)') {
                $ips.Add($Matches[1]) | Out-Null
            }
        }
    }
    return $ips
}

# Apply a single list as one firewall rule with comma-separated remoteip
function Apply-HardenList {
    param([string]$Name, [string]$URL, [string]$Format,
          [System.Windows.Controls.TextBlock]$StatLabel)

    $safeName = $Name -replace '[^a-zA-Z0-9]','_'
    $inRuleName  = "Paladin_Harden_${safeName}_in"
    $outRuleName = "Paladin_Harden_${safeName}_out"

    if ($null -ne $StatLabel) { $StatLabel.Text = 'Downloading...' }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
        $resp = Invoke-WebRequest -Uri $URL -UseBasicParsing -TimeoutSec 60 -EA Stop
        $text = $resp.Content
        $ips  = Parse-IPList -Text $text -Format $Format

        if ($ips.Count -eq 0) {
            if ($null -ne $StatLabel) { $StatLabel.Text = 'No IPs parsed' }
            return $false
        }

        # Remove old rules
        & netsh.exe advfirewall firewall delete rule name=$inRuleName  2>&1 | Out-Null
        & netsh.exe advfirewall firewall delete rule name=$outRuleName 2>&1 | Out-Null

        # Windows Firewall supports up to ~1000 CIDRs per rule reliably.
        # Chunk into batches to stay within limits.
        $chunkSize = 800
        $chunks    = [Math]::Ceiling($ips.Count / $chunkSize)
        $okCount   = 0

        for ($i = 0; $i -lt $chunks; $i++) {
            $start  = $i * $chunkSize
            $slice  = $ips.GetRange($start, [Math]::Min($chunkSize, $ips.Count - $start))
            $remote = $slice -join ','
            $rIn    = if ($chunks -eq 1) { $inRuleName  } else { "${inRuleName}_$i"  }
            $rOut   = if ($chunks -eq 1) { $outRuleName } else { "${outRuleName}_$i" }

            & netsh.exe advfirewall firewall add rule name=$rIn `
                dir=in action=block remoteip=$remote protocol=any enable=yes 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $okCount++ }

            & netsh.exe advfirewall firewall add rule name=$rOut `
                dir=out action=block remoteip=$remote protocol=any enable=yes 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $okCount++ }
        }

        $totalRules = $chunks * 2
        if ($null -ne $StatLabel) {
            $StatLabel.Text = "$($ips.Count) IPs | $okCount/$totalRules rules OK"
            $col = if ($okCount -eq $totalRules) { '#4CAF50' } else { '#FF9800' }
            $StatLabel.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.ColorConverter]::ConvertFromString($col))
        }
        Write-Log "Hardening: $Name -- $($ips.Count) IPs, $okCount/$totalRules rules applied"
        return $true
    } catch {
        if ($null -ne $StatLabel) {
            $StatLabel.Text = "Error: $($_.Exception.Message.Substring(0,[Math]::Min(60,$_.Exception.Message.Length)))"
            $StatLabel.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                [System.Windows.Media.ColorConverter]::ConvertFromString('#F44336'))
        }
        Write-Log "Hardening: $Name FAILED: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# Remove all Paladin_Harden_* rules
function Remove-HardenRules {
    $existing = & netsh.exe advfirewall firewall show rule name=all 2>&1 |
        Where-Object { $_ -match 'Rule Name:.*Paladin_Harden_' } |
        ForEach-Object { ($_ -replace 'Rule Name:\s+','').Trim() }
    $count = 0
    foreach ($rn in $existing) {
        & netsh.exe advfirewall firewall delete rule name=$rn 2>&1 | Out-Null
        $count++
    }
    return $count
}

# Apply Selected button
if ($null -ne $btnHardenApply) {
    $lHC2    = $HardenChecked
    $lCat2   = $HardenCatalog
    $lPan2   = $panHardening
    $lStat2  = $txtHardenStatus
    $btnHardenApply.Add_Click(({
        $selected = @($lCat2 | Where-Object { $lHC2[$_.Name] -eq $true })
        if ($selected.Count -eq 0) {
            if ($null -ne $lStat2) { $lStat2.Text = 'Check at least one list first' }; return
        }
        if ($null -ne $lStat2) { $lStat2.Text = "Applying $($selected.Count) list(s)... (may take 1-2 min)" }

        # Run in background job -- one list at a time so UI can update
        $lSel3 = $selected; $lPan3 = $lPan2; $lStat3 = $lStat2
        # Convert hashtables to PSCustomObject so they serialize cleanly through Start-Job
        $serializable = $lSel3 | ForEach-Object {
            [PSCustomObject]@{
                Name   = [string]$_.Name
                URL    = [string]$_.URL
                Format = [string]$_.Format
            }
        }
        $job = Start-Job -ScriptBlock {
            param($items)
            $results = @()
            foreach ($item in $items) {
                try {
                    [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
                    $resp = Invoke-WebRequest -Uri $item.URL -UseBasicParsing -TimeoutSec 60 -EA Stop
                    $text = $resp.Content
                    # Parse
                    $ips = [System.Collections.Generic.List[string]]::new()
                    $lines2 = $text -replace "`r`n","`n" -replace "`r","`n" -split "`n"
                    foreach ($line in $lines2) {
                        $line = $line.Trim()
                        if ([string]::IsNullOrEmpty($line) -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
                        if ($item.Format -eq 'dshield') {
                            $cols = $line -split "`t"
                            if ($cols.Count -ge 1 -and $cols[0] -match '^(\d+\.\d+\.\d+)\.\d+') {
                                $ips.Add("$($Matches[1]).0/24") | Out-Null
                            }
                        } elseif ($item.Format -eq 'hosts') {
                            $parts = $line -split '\s+'
                            if ($parts.Count -ge 1 -and $parts[0] -match '^\d+\.\d+\.\d+\.\d+') {
                                $ip = $parts[0]
                                if ($ip -notmatch '^(127\.|0\.|255\.)') { $ips.Add($ip) | Out-Null }
                            }
                        } elseif ($item.Format -eq 'hosts-ip') {
                            $parts = $line -split '\s+'
                            if ($parts.Count -ge 2 -and $parts[0] -match '^\d+\.\d+\.\d+\.\d+') {
                                $ip = $parts[0]
                                if ($ip -notmatch '^(127\.|0\.|255\.)') { $ips.Add($ip) | Out-Null }
                            }
                        } else {
                            if ($line -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(/\d{1,2})?)') {
                                $ips.Add($Matches[1]) | Out-Null
                            }
                        }
                    }
                    $results += @{ Name=$item.Name; IPs=$ips.ToArray(); Error='' }
                } catch { $results += @{ Name=$item.Name; IPs=@(); Error=$_.Exception.Message } }
            }
            return $results
        } -ArgumentList (,$serializable)

        $ht = New-Object System.Windows.Threading.DispatcherTimer
        $ht.Interval = [TimeSpan]::FromSeconds(2)
        $lHt = $ht; $lHj = $job
        $ht.Add_Tick(({
            if ($lHj.State -ne 'Running') {
                $lHt.Stop()
                $results = @(Receive-Job $lHj -EA SilentlyContinue)
                Remove-Job $lHj -Force -EA SilentlyContinue
                $totalIPs   = 0; $totalRules = 0; $failed = 0

                foreach ($r in $results) {
                    $safeName    = $r.Name -replace '[^a-zA-Z0-9]','_'
                    $inRuleName  = "Paladin_Harden_${safeName}_in"
                    $outRuleName = "Paladin_Harden_${safeName}_out"

                    # Find the stat label for this list
                    $statLabel = $null
                    if ($null -ne $lPan3) {
                        foreach ($child in $lPan3.Children) {
                            $grid = $child.Child
                            if ($null -ne $grid) {
                                foreach ($gc in $grid.Children) {
                                    if ($gc -is [System.Windows.Controls.TextBlock] -and
                                        $gc.Name -eq ('stat_' + $safeName)) {
                                        $statLabel = $gc; break
                                    }
                                }
                            }
                            if ($null -ne $statLabel) { break }
                        }
                    }

                    if (-not [string]::IsNullOrEmpty($r.Error)) {
                        if ($null -ne $statLabel) { $statLabel.Text = "Error: download failed" }
                        $failed++; continue
                    }

                    $ips = [System.Collections.Generic.List[string]]::new()
                    $ips.AddRange([string[]]@($r.IPs))
                    $totalIPs += $ips.Count

                    & netsh.exe advfirewall firewall delete rule name=$inRuleName  2>&1 | Out-Null
                    & netsh.exe advfirewall firewall delete rule name=$outRuleName 2>&1 | Out-Null

                    $chunkSize = 800
                    $chunks    = [Math]::Ceiling($ips.Count / $chunkSize)
                    $okRules   = 0

                    for ($i = 0; $i -lt $chunks; $i++) {
                        $start  = $i * $chunkSize
                        $slice  = $ips.GetRange($start, [Math]::Min($chunkSize, $ips.Count - $start))
                        $remote = $slice -join ','
                        $rIn    = if ($chunks -eq 1) { $inRuleName  } else { "${inRuleName}_$i"  }
                        $rOut   = if ($chunks -eq 1) { $outRuleName } else { "${outRuleName}_$i" }
                        & netsh.exe advfirewall firewall add rule name=$rIn  dir=in  action=block remoteip=$remote protocol=any enable=yes 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) { $okRules++ }
                        & netsh.exe advfirewall firewall add rule name=$rOut dir=out action=block remoteip=$remote protocol=any enable=yes 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) { $okRules++ }
                        $totalRules += 2
                    }

                    if ($null -ne $statLabel) {
                        $col = if ($okRules -eq ($chunks*2)) { '#4CAF50' } else { '#FF9800' }
                        $statLabel.Text = "$($ips.Count) IPs blocked"
                        $statLabel.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                            [System.Windows.Media.ColorConverter]::ConvertFromString($col))
                    }
                }

                if ($null -ne $lStat3) {
                    $lStat3.Text = "Done: $totalIPs IPs blocked across $totalRules firewall rules | $failed list(s) failed"
                }
            }
        }).GetNewClosure())
        $ht.Start()
    }).GetNewClosure())
}

# Refresh Counts button -- re-reads live rule counts from Windows Firewall
if ($null -ne $btnHardenRefresh) {
    $lCat3 = $HardenCatalog; $lPan4 = $panHardening; $lStat4 = $txtHardenStatus
    $btnHardenRefresh.Add_Click(({
        if ($null -ne $lStat4) { $lStat4.Text = 'Checking firewall rules...' }
        $rules = & netsh.exe advfirewall firewall show rule name=all 2>&1 |
            Where-Object { $_ -match 'Rule Name:' } |
            ForEach-Object { ($_ -replace 'Rule Name:\s+','').Trim() }
        $found = 0
        foreach ($item in $lCat3) {
            $safeName = $item.Name -replace '[^a-zA-Z0-9]','_'
            $prefix   = "Paladin_Harden_${safeName}"
            $count    = @($rules | Where-Object { $_ -like "$prefix*" }).Count
            if ($count -gt 0) {
                $found++
                # Update stat label
                if ($null -ne $lPan4) {
                    foreach ($child in $lPan4.Children) {
                        $grid = try { $child.Child } catch { $null }
                        if ($null -ne $grid) {
                            foreach ($gc in $grid.Children) {
                                if ($gc -is [System.Windows.Controls.TextBlock] -and
                                    $gc.Name -eq ('stat_' + $safeName)) {
                                    $gc.Text = "$count rule(s) active"
                                    $gc.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#4CAF50'))
                                }
                            }
                        }
                    }
                }
            }
        }
        if ($null -ne $lStat4) { $lStat4.Text = "$found hardening list(s) active in Windows Firewall" }
    }).GetNewClosure())
}

# Remove All Rules button
if ($null -ne $btnHardenClear) {
    $lStat5 = $txtHardenStatus; $lPan5 = $panHardening; $lCat5 = $HardenCatalog
    $btnHardenClear.Add_Click(({
        $confirm = [System.Windows.MessageBox]::Show(
            'Remove ALL Paladin hardening firewall rules?',
            'NetWatch','YesNo','Warning')
        if ($confirm -ne 'Yes') { return }
        if ($null -ne $lStat5) { $lStat5.Text = 'Removing rules...' }
        $count = Remove-HardenRules
        # Clear all stat labels
        if ($null -ne $lPan5) {
            foreach ($child in $lPan5.Children) {
                $grid = try { $child.Child } catch { $null }
                if ($null -ne $grid) {
                    foreach ($gc in $grid.Children) {
                        if ($gc -is [System.Windows.Controls.TextBlock] -and $gc.Name -like 'stat_*') {
                            $gc.Text = ''; $gc.Foreground = New-Object System.Windows.Media.SolidColorBrush (
                                [System.Windows.Media.ColorConverter]::ConvertFromString('#888'))
                        }
                    }
                }
            }
        }
        if ($null -ne $lStat5) { $lStat5.Text = "Removed $count Paladin hardening rules" }
    }).GetNewClosure())
}

# =============================================================================
# SHOW WINDOW
# =============================================================================
$window.ShowDialog() | Out-Null

} # end if ($GUIMode)

exit 0
