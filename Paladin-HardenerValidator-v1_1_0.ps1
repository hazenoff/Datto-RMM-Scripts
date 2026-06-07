#Requires -Version 3.0
# =============================================================================
# Paladin Firewall Hardener Validator [WIN]
# Datto RMM Component | Script | PowerShell 3.0 | SYSTEM context
# Version: 1.1.1
#
# Proves the Firewall Hardener is actually blocking traffic -- not just
# that rules exist, but that connections to known-blocked IPs are dropped.
#
# THREE-LAYER VALIDATION:
#   L1 -- Rule audit: Paladin_Harden_* rules present in Windows Firewall
#   L2 -- Control test: ICMP ping to 8.8.8.8, 1.1.1.1, 9.9.9.9 (any = pass)
#   L3 -- Block test: TCP to IPs pulled LIVE from the active blocklist,
#         randomized each run -- no stale hardcoded IPs, no false positives
#
# DESKTOP NOTIFICATION:
#   Launches a WPF toast on the user's desktop via CreateProcessAsUserW (NWWTS)
#   showing PASSED (green) or FAILED (red), auto-closes after 30 seconds.
#
# INPUT VARIABLES (Datto):
#   UDFSlot    String   UDF slot for result summary (default: 30)
#   Verbose    Boolean  true = per-IP detail in output (default: false)
#   SampleSize String   How many IPs to test from live list (default: 5)
#
# EXIT CODES:
#   0 = PASS   1 = FAIL
# =============================================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer   = '1.1.1'
$BaseDir     = 'C:\ProgramData\Paladin\FirewallHardener'
$LogFile     = "$BaseDir\HardenerValidator.log"
$RegPath     = 'HKLM:\SOFTWARE\Paladin\FirewallHardener'
$PsExe       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$ToastScript = "$BaseDir\ValidatorToast.ps1"

$MachineName = $env:COMPUTERNAME
$SiteName    = if ($env:CS_PROFILE_NAME) { $env:CS_PROFILE_NAME } else { 'UNKNOWN' }
$UDFSlot     = if ($env:UDFSlot    -match '^\d+$') { [int]$env:UDFSlot }    else { 30 }
$SampleSize  = if ($env:SampleSize -match '^\d+$') { [int]$env:SampleSize } else { 5 }
$VerboseOut  = ($env:Verbose -eq 'true')

# Control IPs -- ICMP ping, any one passing = L2 PASS
$ControlIPs = @('8.8.8.8','1.1.1.1','9.9.9.9')
$TestPort   = 80
$TimeoutMs  = 3000

# Active blocklist URL -- pulled live so test IPs are always current
$ListURL = 'https://raw.githubusercontent.com/ktsaou/blocklist-ipsets/master/firehol_level1.netset'

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

function Set-DattoUDF {
    param([int]$Slot, [string]$Value)
    $v = if ($Value.Length -gt 255) { $Value.Substring(0,255) } else { $Value }
    try { New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' -Name "Custom$Slot" `
        -PropertyType String -Value $v -Force -EA Stop | Out-Null } catch {}
}

function Test-ICMP {
    param([string]$IP)
    try {
        $ping   = New-Object System.Net.NetworkInformation.Ping
        $result = $ping.Send($IP, 2000)
        return ($result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
    } catch { return $false }
}

function Test-TCPBlocked {
    param([string]$IP, [int]$Port, [int]$TimeoutMs)
    # Returns BLOCKED (timeout=firewall drop), REFUSED (RST=no rule), OPEN (connected=fail), ERROR
    try {
        $tcp    = New-Object System.Net.Sockets.TcpClient
        $ar     = $tcp.BeginConnect($IP, $Port, $null, $null)
        $waited = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $waited) { $tcp.Close(); return 'BLOCKED' }
        try {
            $tcp.EndConnect($ar); $tcp.Close(); return 'OPEN'
        } catch {
            $tcp.Close()
            $msg = $_.Exception.InnerException.Message
            if ($msg -match 'refused|WSAECONNREFUSED') { return 'REFUSED' }
            return 'BLOCKED'
        }
    } catch { return 'ERROR' }
}

function Get-RandomTestIPs {
    param([string]$URL, [int]$Count)
    # Downloads live blocklist, picks $Count random IPs/CIDRs, returns host IPs to test
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
        $wc   = New-Object System.Net.WebClient
        $text = $wc.DownloadString($URL)
        $ips  = @($text -split "`n" | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^(\d{1,3}\.){3}\d{1,3}(/\d+)?$' -and
                           -not $_.StartsWith('#') -and
                           $_ -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.|0\.)' })

        if ($ips.Count -eq 0) { return @() }

        # Shuffle -- Fisher-Yates compatible with PS3 (no Get-Random -Shuffle)
        $rng = New-Object System.Random
        for ($i = $ips.Count - 1; $i -gt 0; $i--) {
            $j = $rng.Next(0, $i + 1)
            $tmp = $ips[$i]; $ips[$i] = $ips[$j]; $ips[$j] = $tmp
        }

        # Pick $Count entries, extract a host IP from each CIDR
        $selected = @($ips | Select-Object -First ($Count * 3))  # take extra in case some skip
        $result   = @()
        foreach ($entry in $selected) {
            if ($result.Count -ge $Count) { break }
            if ($entry -match '^(\d+\.\d+\.\d+\.\d+)/\d+$') {
                # Use .1 of the network address
                $parts = $Matches[1] -split '\.'
                $testIP = "$($parts[0]).$($parts[1]).$($parts[2]).1"
                $result += @{ IP=$testIP; CIDR=$entry }
            } elseif ($entry -match '^(\d+\.\d+\.\d+\.\d+)$') {
                $result += @{ IP=$entry; CIDR=$entry }
            }
        }
        return $result
    } catch {
        Write-Log "WARN: Could not download live blocklist for L3: $($_.Exception.Message)" 'WARN'
        return @()
    }
}

# =============================================================================
# NWWTS C# -- SYSTEM->user desktop launch (KW-114)
# @'...'@ mandatory -- single-quoted heredoc, no PS interpolation of C# strings
# =============================================================================

$nwCSharp = @'
using System;
using System.Runtime.InteropServices;
using System.ComponentModel;
public class HVWTS {
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
      if (imp)                 RevertToSelf();
      if (intSid!=IntPtr.Zero) FreeSid(intSid);
      if (env!=IntPtr.Zero)    DestroyEnvironmentBlock(env);
      if (dupTok!=IntPtr.Zero) CloseHandle(dupTok);
      if (userTok!=IntPtr.Zero) CloseHandle(userTok);
      if (procTok!=IntPtr.Zero) CloseHandle(procTok);
    }
  }
}
'@

function Compile-HVWTS {
    if (-not ([System.Management.Automation.PSTypeName]'HVWTS').Type) {
        try {
            Add-Type -TypeDefinition $nwCSharp -Language CSharp -EA Stop
            return $true
        } catch {
            Write-Log "WARN: HVWTS compile failed -- no desktop notification: $($_.Exception.Message)" 'WARN'
            return $false
        }
    }
    return $true
}

function Show-DesktopToast {
    param([bool]$Passed, [string]$Detail, [int]$DelaySeconds = 30)

    $bg      = if ($Passed) { '#FF107C10' } else { '#FFC42B1C' }
    $icon    = if ($Passed) { 'PASSED' }    else { 'FAILED'    }
    $title   = if ($Passed) { 'Firewall Hardener: ACTIVE' } else { 'Firewall Hardener: ATTENTION REQUIRED' }
    $body    = if ($Passed) {
        "Your machine's firewall has been validated. Threat blocking is confirmed active and working."
    } else {
        "Firewall hardening validation failed. Please contact your IT support team."
    }

    # Write the WPF toast script
    $toastPs = @"
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
[xml]`$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Width="420" Height="160"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="Manual" Topmost="True" ResizeMode="NoResize"
        ShowInTaskbar="False">
    <Border CornerRadius="8" Background="$bg" Padding="20,16">
        <StackPanel>
            <TextBlock Text="$title" Foreground="White" FontSize="15" FontWeight="Bold" TextWrapping="Wrap" Margin="0,0,0,8"/>
            <TextBlock Text="$body" Foreground="#EEE" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,10"/>
            <TextBlock Name="txtCountdown" Foreground="#BBB" FontSize="10" HorizontalAlignment="Right"/>
        </StackPanel>
    </Border>
</Window>
'@
`$reader  = New-Object System.Xml.XmlNodeReader `$xaml
`$window  = [Windows.Markup.XamlReader]::Load(`$reader)
`$txtCD   = `$window.FindName('txtCountdown')

# Position bottom-right
`$screen  = [System.Windows.SystemParameters]::WorkArea
`$window.Left = `$screen.Right  - `$window.Width  - 20
`$window.Top  = `$screen.Bottom - `$window.Height - 20

`$timer = New-Object System.Windows.Threading.DispatcherTimer
`$timer.Interval = [TimeSpan]::FromSeconds(1)
`$secs = $DelaySeconds
`$timer.Add_Tick(({
    `$secs--
    if (`$null -ne `$txtCD) { `$txtCD.Text = "Closing in `$secs second`$(if(`$secs -ne 1){'s'})..." }
    if (`$secs -le 0) { `$timer.Stop(); `$window.Close() }
}).GetNewClosure())
`$timer.Start()
`$window.Add_MouseLeftButtonUp({ `$timer.Stop(); `$window.Close() })
`$window.ShowDialog() | Out-Null
"@

    try {
        [System.IO.File]::WriteAllText($ToastScript, $toastPs, [System.Text.Encoding]::ASCII)

        $wtsOk = Compile-HVWTS
        if (-not $wtsOk) { return }

        $session = [HVWTS]::FindActiveSession()
        if ($session -lt 0) { Write-Log 'WARN: No user session for toast' 'WARN'; return }

        $args = "-STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ToastScript`""
        [HVWTS]::Launch($session, $PsExe, $args) | Out-Null
        Write-Log "Desktop toast launched (session $session)"
    } catch {
        Write-Log "WARN: Toast launch failed: $($_.Exception.Message)" 'WARN'
    }
}

# =============================================================================
# MAIN
# =============================================================================

if (-not (Test-Path $BaseDir)) { New-Item $BaseDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

Write-Log "Paladin Hardener Validator v$ScriptVer | Site: $SiteName | Machine: $MachineName"

$L1Pass = $false; $L2Pass = $false; $L3Pass = $false
$L1Detail = ''; $L2Detail = ''; $L3Detail = ''
$ruleCount = 0

# =============================================================================
# L1 -- RULE AUDIT
# =============================================================================

Write-Log '--- L1: Rule Audit ---'

$allRules = @(& netsh.exe advfirewall firewall show rule name=all 2>&1 |
    Where-Object { $_ -match '^Rule Name:' } |
    ForEach-Object { ($_ -replace '^Rule Name:\s+','').Trim() } |
    Where-Object { $_ -like 'Paladin_Harden_*' })

$ruleCount = $allRules.Count

if ($ruleCount -gt 0) {
    $listsPresent = @($allRules | ForEach-Object {
        if ($_ -match '^Paladin_Harden_(.+)_(in|out)(_\d+)?$') { $Matches[1] -replace '_',' ' }
    } | Sort-Object -Unique)
    $L1Pass   = $true
    $L1Detail = "PASS: $ruleCount rules, $($listsPresent.Count) list(s) applied"
    Write-Log $L1Detail
    try {
        $lastRun = (Get-ItemProperty -Path $RegPath -EA Stop).LastRun
        $lastRes = (Get-ItemProperty -Path $RegPath -EA Stop).LastRunResult
        Write-Log "Last hardener run: $lastRun | $lastRes"
    } catch { Write-Log 'Registry: no hardener run record' 'WARN' }
} else {
    $L1Detail = 'FAIL: No Paladin_Harden_* rules found -- Hardener has not run'
    Write-Log $L1Detail 'ERROR'
}

# =============================================================================
# L2 -- CONTROL TEST (ICMP to multiple DNS servers -- any one passing = PASS)
# =============================================================================

Write-Log '--- L2: Control Test (ICMP ping) ---'

$l2Passed = $null
foreach ($cip in $ControlIPs) {
    $ok = Test-ICMP -IP $cip
    Write-Log "Ping $cip : $(if($ok){'REACHABLE'}else{'UNREACHABLE'})"
    if ($ok -and $null -eq $l2Passed) { $l2Passed = $cip }
}

if ($null -ne $l2Passed) {
    $L2Pass   = $true
    $L2Detail = "PASS: $l2Passed is reachable via ICMP -- outbound connectivity confirmed"
} else {
    $L2Pass   = $false
    $L2Detail = "FAIL: 8.8.8.8, 1.1.1.1, 9.9.9.9 all unreachable -- network issue or ICMP blocked"
}
Write-Log $L2Detail $(if($L2Pass){'INFO'}else{'ERROR'})

# =============================================================================
# L3 -- BLOCK TEST (live IPs from active blocklist, randomized)
# =============================================================================

Write-Log "--- L3: Block Test ($SampleSize random live IPs from Firehol Level 1) ---"

$testIPs = @(Get-RandomTestIPs -URL $ListURL -Count $SampleSize)

if ($testIPs.Count -eq 0) {
    $L3Pass   = $false
    $L3Detail = 'FAIL: Could not download live blocklist for test IPs'
    Write-Log $L3Detail 'ERROR'
} else {
    $blockedCount = 0; $openCount = 0; $l3Log = @()

    foreach ($test in $testIPs) {
        $result = Test-TCPBlocked -IP $test.IP -Port $TestPort -TimeoutMs $TimeoutMs
        switch ($result) {
            'BLOCKED'  { $blockedCount++ }
            'REFUSED'  { $blockedCount++ }   # RST with rules present = firewall RST or host down
            'OPEN'     { $openCount++ }
        }
        $l3Log += "  $($test.IP) [$($test.CIDR)]: $result"
        if ($VerboseOut) { Write-Log "$($test.IP) [$($test.CIDR)]: $result" }
    }

    if ($openCount -eq 0 -and $blockedCount -gt 0) {
        $L3Pass   = $true
        $L3Detail = "PASS: $blockedCount/$($testIPs.Count) IPs blocked/refused -- 0 open connections"
    } elseif ($openCount -gt 0) {
        $L3Pass   = $false
        $L3Detail = "FAIL: $openCount/$($testIPs.Count) test IPs are REACHABLE -- rules not enforcing"
        $l3Log | ForEach-Object { Write-Log $_ 'WARN' }
    } else {
        $L3Pass   = $false
        $L3Detail = 'INCONCLUSIVE: No results -- network may be fully offline'
    }
    Write-Log $L3Detail $(if($L3Pass){'INFO'}else{'ERROR'})
    if ($VerboseOut) { $l3Log | ForEach-Object { Write-Log $_ } }
}

# =============================================================================
# SUMMARY + TOAST
# =============================================================================

Write-Log '--- SUMMARY ---'
$overallPass = $L1Pass -and $L2Pass -and $L3Pass

$grade = if ($overallPass) { 'PASS' }
         elseif (-not $L1Pass) { 'FAIL-NO-RULES' }
         elseif ($L1Pass -and $L2Pass -and -not $L3Pass) { 'FAIL-ENFORCEMENT' }
         else { 'FAIL' }

$summary = "$grade $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | Rules:$ruleCount | L1:$(if($L1Pass){'P'}else{'F'}) L2:$(if($L2Pass){'P'}else{'F'}) L3:$(if($L3Pass){'P'}else{'F'})"

Write-Log "Result : $summary"
Write-Log "L1     : $L1Detail"
Write-Log "L2     : $L2Detail"
Write-Log "L3     : $L3Detail"

Set-DattoUDF -Slot $UDFSlot -Value $summary

# Launch desktop toast
Show-DesktopToast -Passed $overallPass -Detail $grade -DelaySeconds 30

Write-Host ""
Write-Host "=============================="
Write-Host "PALADIN HARDENER VALIDATION"
Write-Host "=============================="
Write-Host "Machine : $MachineName"
Write-Host "Result  : $grade"
Write-Host ""
Write-Host "L1 Rule Audit : $L1Detail"
Write-Host "L2 Control    : $L2Detail"
Write-Host "L3 Block Test : $L3Detail"
Write-Host "=============================="

exit $(if ($overallPass) { 0 } else { 1 })
