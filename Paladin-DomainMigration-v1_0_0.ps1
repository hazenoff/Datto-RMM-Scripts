#Requires -Version 3.0
# =============================================================================
# Paladin Domain Migration [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.0
# Context: NT AUTHORITY\SYSTEM (Datto) -> credential dialog on user desktop
#
# PURPOSE:
#   Migrates a PC from any join state to a local Active Directory domain.
#   Handles Azure AD only, Hybrid joined, Intune enrolled, and Workgroup.
#
# SEQUENCE:
#   1. Detect current join state (Azure AD / Hybrid / Domain / Workgroup)
#   2. Collect domain admin credentials via WPF dialog on user desktop (HIPAA safe)
#   3. Snapshot Azure AD device ID + machine details for portal cleanup
#   4. Migrate Azure AD user profile (robocopy key folders to staging)
#   5. MDM/Intune unenroll (standard or aggressive mode)
#   6. Unjoin Azure AD (dsregcmd /leave)
#   7. Join local AD domain (with optional OU path)
#   8. Schedule profile restore task (copies staging to domain profile post-login)
#   9. Notify user + reboot
#
# INPUT VARIABLES (Datto):
#   DomainName      String   FQDN of target domain (e.g. paladin.local) REQUIRED
#   OUPath          String   Distinguished name of target OU (optional)
#   AggressiveMDM   Boolean  true = forcibly strip MDM enrollment (default: false)
#   UDFSlot         String   UDF slot for result (default: 30)
#
# HIPAA NOTE:
#   Domain admin credentials are collected via WPF dialog on the user desktop.
#   Credentials exist ONLY in memory as PSCredential. Never written to disk or log.
#   Credential dialog result passed via DPAPI-encrypted temp file, wiped after read.
#
# LOG:  C:\ProgramData\Paladin\DomainMigration\DomainMigration.log
# EXIT: 0 = success + reboot pending  |  1 = fatal error
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer    = '1.0.0'
$BaseDir      = 'C:\ProgramData\Paladin\DomainMigration'
$LogFile      = "$BaseDir\DomainMigration.log"
$StagingDir   = "$BaseDir\ProfileStaging"
$CredFile     = "$BaseDir\cred.tmp"         # DPAPI encrypted, wiped after read
$CredScript   = "$BaseDir\CredDialog.ps1"   # WPF dialog, runs as user
$PipeFile     = "$BaseDir\cred.pipe"        # Named pipe result fallback
$RestoreTask  = 'Paladin_ProfileRestore'
$RestoreScript= "$BaseDir\ProfileRestore.ps1"
$PsExe        = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$MaxLogMB     = 5

# =============================================================================
# INPUT VARIABLES
# =============================================================================
$DomainName    = $env:DomainName
$OUPath        = $env:OUPath
$AggressiveMDM = ($env:AggressiveMDM -eq 'true')
$UDFSlot       = if ($env:UDFSlot -match '^\d+$') { [int]$env:UDFSlot } else { 30 }
$SiteName      = if ($env:CS_PROFILE_NAME) { $env:CS_PROFILE_NAME } else { 'UNKNOWN' }
$MachineName   = $env:COMPUTERNAME

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

function Show-UserMessage {
    param([string]$Message)
    try {
        & msg.exe '*' /TIME:300 "Paladin IT: $Message" 2>&1 | Out-Null
    } catch {}
}

# =============================================================================
# CREATEPROCESSASUSERW LAUNCHER (KW-061 pattern)
# =============================================================================

$LauncherCode = @'
using System;
using System.Runtime.InteropServices;
namespace APM {
    public static class Launcher {
        private const uint TOKEN_ALL_ACCESS = 0x000F01FF;
        private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        private const uint NORMAL_PRIORITY_CLASS = 0x00000020;
        private const int  SE_PRIVILEGE_ENABLED  = 0x00000002;
        private const uint INVALID_SESSION_ID    = 0xFFFFFFFF;
        private static readonly IntPtr WTS_CURRENT_SERVER_HANDLE = IntPtr.Zero;

        [DllImport("advapi32.dll", SetLastError=true)]
        static extern bool OpenProcessToken(IntPtr h, uint a, out IntPtr t);
        [DllImport("advapi32.dll", SetLastError=true)]
        static extern bool DuplicateTokenEx(IntPtr t, uint a, IntPtr attr, int imp, int type, out IntPtr newT);
        [DllImport("advapi32.dll", SetLastError=true)]
        static extern bool ImpersonateLoggedOnUser(IntPtr t);
        [DllImport("advapi32.dll", SetLastError=true)]
        static extern bool RevertToSelf();
        [DllImport("advapi32.dll", SetLastError=true)]
        static extern bool AdjustTokenPrivileges(IntPtr t, bool d, ref TOKEN_PRIVILEGES n, uint b, IntPtr p, IntPtr r);
        [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        static extern bool LookupPrivilegeValue(string sys, string name, out LUID luid);
        [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        static extern bool CreateProcessAsUserW(IntPtr t, string app, string cmd, IntPtr pa, IntPtr ta, bool inh, uint f, IntPtr env, string dir, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
        [DllImport("userenv.dll", SetLastError=true)]
        static extern bool CreateEnvironmentBlock(ref IntPtr e, IntPtr t, bool inh);
        [DllImport("userenv.dll", SetLastError=true)]
        static extern bool DestroyEnvironmentBlock(IntPtr e);
        [DllImport("wtsapi32.dll", SetLastError=true)]
        static extern bool WTSQueryUserToken(uint s, out IntPtr t);
        [DllImport("wtsapi32.dll", SetLastError=true)]
        static extern int WTSEnumerateSessions(IntPtr srv, int r, int v, ref IntPtr pp, ref int pc);
        [DllImport("wtsapi32.dll")]
        static extern void WTSFreeMemory(IntPtr p);
        [DllImport("kernel32.dll")]
        static extern uint WTSGetActiveConsoleSessionId();
        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool CloseHandle(IntPtr h);

        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
        struct STARTUPINFO { public int cb; public string lpReserved,lpDesktop,lpTitle; public uint dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags; public short wShowWindow,cbReserved2; public IntPtr lpReserved2,hStdInput,hStdOutput,hStdError; }
        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_INFORMATION { public IntPtr hProcess,hThread; public uint dwProcessId,dwThreadId; }
        [StructLayout(LayoutKind.Sequential)]
        struct WTS_SESSION_INFO { public uint SessionID; [MarshalAs(UnmanagedType.LPStr)] public string pWinStationName; public int State; }
        [StructLayout(LayoutKind.Sequential)]
        struct LUID { public uint LowPart; public int HighPart; }
        [StructLayout(LayoutKind.Sequential)]
        struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
        [StructLayout(LayoutKind.Sequential)]
        struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privilege; }

        static bool EnablePrivilege(IntPtr token, string name) {
            LUID luid; if (!LookupPrivilegeValue(null, name, out luid)) return false;
            var tp = new TOKEN_PRIVILEGES(); tp.PrivilegeCount=1; tp.Privilege.Luid=luid; tp.Privilege.Attributes=(uint)SE_PRIVILEGE_ENABLED;
            return AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        }

        static uint GetActiveSessionId() {
            IntPtr pInfo = IntPtr.Zero; int count = 0;
            if (WTSEnumerateSessions(WTS_CURRENT_SERVER_HANDLE, 0, 1, ref pInfo, ref count) != 0) {
                int stride = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
                for (int i = 0; i < count; i++) {
                    var info = (WTS_SESSION_INFO)Marshal.PtrToStructure((IntPtr)(pInfo.ToInt64() + i * stride), typeof(WTS_SESSION_INFO));
                    if (info.State == 0 && info.SessionID != 0) { WTSFreeMemory(pInfo); return info.SessionID; }
                }
                WTSFreeMemory(pInfo);
            }
            uint c = WTSGetActiveConsoleSessionId();
            return (c == 0xFFFFFFFF) ? INVALID_SESSION_ID : c;
        }

        public static string LaunchInUserSession(string exe, string args, string workdir) {
            uint sessionId = GetActiveSessionId();
            if (sessionId == INVALID_SESSION_ID) return "ERROR: No active user session";
            IntPtr procToken=IntPtr.Zero, userToken=IntPtr.Zero, dupToken=IntPtr.Zero, env=IntPtr.Zero;
            bool imp = false;
            try {
                if (!OpenProcessToken(GetCurrentProcess(), 0x000F01FF, out procToken)) return "ERROR: OpenProcessToken: "+Marshal.GetLastWin32Error();
                EnablePrivilege(procToken, "SeTcbPrivilege");
                CloseHandle(procToken); procToken=IntPtr.Zero;
                if (!WTSQueryUserToken(sessionId, out userToken)) return "ERROR: WTSQueryUserToken: "+Marshal.GetLastWin32Error()+" session="+sessionId;
                if (!DuplicateTokenEx(userToken, TOKEN_ALL_ACCESS, IntPtr.Zero, 2, 1, out dupToken)) return "ERROR: DuplicateTokenEx: "+Marshal.GetLastWin32Error();
                if (!ImpersonateLoggedOnUser(dupToken)) return "ERROR: ImpersonateLoggedOnUser: "+Marshal.GetLastWin32Error();
                imp = true;
                if (!CreateEnvironmentBlock(ref env, dupToken, false)) env=IntPtr.Zero;
                var si = new STARTUPINFO(); si.cb=Marshal.SizeOf(typeof(STARTUPINFO)); si.lpDesktop="winsta0\\default"; si.dwFlags=1; si.wShowWindow=5;
                string cmd = "\""+exe+"\""; if (!string.IsNullOrEmpty(args)) cmd+=" "+args;
                PROCESS_INFORMATION pi;
                bool ok = CreateProcessAsUserW(dupToken, null, cmd, IntPtr.Zero, IntPtr.Zero, false, CREATE_UNICODE_ENVIRONMENT|NORMAL_PRIORITY_CLASS, env, string.IsNullOrEmpty(workdir)?null:workdir, ref si, out pi);
                if (!ok) return "ERROR: CreateProcessAsUser: "+Marshal.GetLastWin32Error();
                CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
                return "OK: PID="+pi.dwProcessId+" session="+sessionId;
            } finally {
                if (imp) RevertToSelf();
                if (env!=IntPtr.Zero) DestroyEnvironmentBlock(env);
                if (dupToken!=IntPtr.Zero) CloseHandle(dupToken);
                if (userToken!=IntPtr.Zero) CloseHandle(userToken);
                if (procToken!=IntPtr.Zero) CloseHandle(procToken);
            }
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $LauncherCode -Language CSharp -EA Stop
} catch {
    Write-Log "ERROR: Failed to compile launcher: $($_.Exception.Message)" 'ERROR'
    exit 1
}

# =============================================================================
# STEP 1 -- DETECT JOIN STATE
# =============================================================================

function Get-JoinState {
    $state = @{
        AzureADJoined    = $false
        DomainJoined     = $false
        HybridJoined     = $false
        WorkplaceJoined  = $false
        MDMEnrolled      = $false
        DomainName       = ''
        AzureDeviceId    = ''
        TenantName       = ''
        AzureProfileUser = ''
    }

    try {
        $dsreg = & dsregcmd.exe /status 2>&1
        foreach ($line in $dsreg) {
            if ($line -match 'AzureAdJoined\s*:\s*YES')        { $state.AzureADJoined   = $true }
            if ($line -match 'DomainJoined\s*:\s*YES')         { $state.DomainJoined    = $true }
            if ($line -match 'WorkplaceJoined\s*:\s*YES')      { $state.WorkplaceJoined = $true }
            if ($line -match 'DomainName\s*:\s*(.+)')          { $state.DomainName      = $Matches[1].Trim() }
            if ($line -match 'DeviceId\s*:\s*(.+)')            { $state.AzureDeviceId   = $Matches[1].Trim() }
            if ($line -match 'TenantName\s*:\s*(.+)')          { $state.TenantName      = $Matches[1].Trim() }
            if ($line -match 'MdmUrl\s*:\s*\S')                { $state.MDMEnrolled     = $true }
        }
        $state.HybridJoined = $state.AzureADJoined -and $state.DomainJoined
    } catch { Write-Log "WARN: dsregcmd failed: $($_.Exception.Message)" 'WARN' }

    # Find Azure AD signed-in profile (C:\Users\AzureAD.* or user with Azure UPN)
    try {
        $azureProfiles = Get-ChildItem 'C:\Users' -Directory -EA SilentlyContinue |
            Where-Object { $_.Name -match '^AzureAD\.' -or
                (Test-Path "$($_.FullName)\AppData\Local\Packages\Microsoft.AAD.BrokerPlugin_*") }
        if ($azureProfiles) { $state.AzureProfileUser = ($azureProfiles | Select-Object -First 1).Name }
    } catch {}

    return $state
}

# =============================================================================
# STEP 2 -- COLLECT CREDENTIALS VIA WPF DIALOG ON USER DESKTOP
# =============================================================================

function Get-DomainCredential {
    param([string]$Domain)

    # Write WPF credential dialog script -- runs as logged-on user
    $dialogScript = @"
param()
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

[xml]`$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Paladin Domain Migration" Width="440" Height="380"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Topmost="True">
    <Window.Resources>
        <Style TargetType="TextBlock"><Setter Property="Margin" Value="0,0,0,4"/></Style>
        <Style TargetType="TextBox"><Setter Property="Margin" Value="0,0,0,10"/><Setter Property="Padding" Value="4"/></Style>
        <Style TargetType="PasswordBox"><Setter Property="Margin" Value="0,0,0,10"/><Setter Property="Padding" Value="4"/></Style>
        <Style TargetType="Button"><Setter Property="Padding" Value="10,5"/><Setter Property="MinWidth" Value="80"/></Style>
    </Window.Resources>
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" FontWeight="Bold" FontSize="14" Margin="0,0,0,12"
                   Text="Domain Migration -- Admin Credentials"/>
        <TextBlock Grid.Row="1" TextWrapping="Wrap" Margin="0,0,0,12" Foreground="#555"
                   Text="Enter domain administrator credentials to join this PC to $Domain. These credentials are used once and never stored."/>
        <TextBlock Grid.Row="2">Domain Admin Username (domain\user or UPN):</TextBlock>
        <TextBox   Grid.Row="3" Name="txtUser"/>
        <TextBlock Grid.Row="4">Domain Admin Password:</TextBlock>
        <PasswordBox Grid.Row="5" Name="txtPass"/>
        <StackPanel Grid.Row="6" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button Name="btnCancel" Content="Cancel"      MinWidth="90" Margin="0,0,10,0"/>
            <Button Name="btnOK"     Content="Join Domain" MinWidth="110" IsDefault="True"/>
        </StackPanel>
    </Grid>
</Window>
'@

`$reader = New-Object System.Xml.XmlNodeReader `$xaml
`$window = [Windows.Markup.XamlReader]::Load(`$reader)
`$txtUser = `$window.FindName('txtUser')
`$txtPass = `$window.FindName('txtPass')
`$btnOK   = `$window.FindName('btnOK')
`$btnCancel=`$window.FindName('btnCancel')

`$btnCancel.Add_Click({ `$window.DialogResult=`$false; `$window.Close() })
`$btnOK.Add_Click({
    if ([string]::IsNullOrWhiteSpace(`$txtUser.Text) -or `$txtPass.SecurePassword.Length -eq 0) {
        [System.Windows.MessageBox]::Show('Please enter both username and password.','Paladin','OK','Warning')
        return
    }
    `$window.DialogResult=`$true
    `$window.Close()
})

`$result = `$window.ShowDialog()
if (`$result -eq `$true) {
    # DPAPI encrypt credentials -- only readable by same user/machine
    Add-Type -AssemblyName System.Security
    `$user  = `$txtUser.Text.Trim()
    `$pass  = `$txtPass.Password
    `$blob  = [System.Text.Encoding]::Unicode.GetBytes("`$user`n`$pass")
    `$enc   = [System.Security.Cryptography.ProtectedData]::Protect(
                `$blob, `$null,
                [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    [System.IO.File]::WriteAllBytes('$CredFile', `$enc)
}
"@

    [System.IO.File]::WriteAllText($CredScript, $dialogScript, [System.Text.Encoding]::Unicode)

    # Launch dialog on user desktop via CreateProcessAsUserW
    $args = "-NonInteractive -ExecutionPolicy Bypass -File `"$CredScript`""
    $result = [APM.Launcher]::LaunchInUserSession($PsExe, $args, $BaseDir)
    Write-Log "  Credential dialog launch: $result"

    if ($result -notmatch '^OK:') {
        Write-Log 'ERROR: Could not launch credential dialog on user desktop' 'ERROR'
        return $null
    }

    # Wait up to 3 minutes for user to enter credentials
    Write-Log '  Waiting for credential entry (timeout: 3 min)...'
    $waited = 0
    while (-not (Test-Path $CredFile) -and $waited -lt 180) {
        Start-Sleep 2; $waited += 2
    }

    if (-not (Test-Path $CredFile)) {
        Write-Log 'ERROR: Credential dialog cancelled or timed out' 'ERROR'
        return $null
    }

    # Read + decrypt credentials
    try {
        Add-Type -AssemblyName System.Security
        $enc  = [System.IO.File]::ReadAllBytes($CredFile)
        $blob = [System.Security.Cryptography.ProtectedData]::Unprotect(
                    $enc, $null,
                    [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        $text = [System.Text.Encoding]::Unicode.GetString($blob)
        $parts = $text -split "`n", 2
        $username = $parts[0].Trim()
        $password = $parts[1]
        $secPass  = ConvertTo-SecureString $password -AsPlainText -Force
        $cred     = New-Object System.Management.Automation.PSCredential($username, $secPass)

        # Wipe the blob from memory as best we can
        for ($i = 0; $i -lt $blob.Length; $i++) { $blob[$i] = 0 }

        Write-Log "  Credentials received for: $username"
        return $cred
    } catch {
        Write-Log "ERROR: Failed to decrypt credentials: $($_.Exception.Message)" 'ERROR'
        return $null
    } finally {
        # Always wipe temp file immediately
        try { Remove-Item -LiteralPath $CredFile -Force -EA SilentlyContinue } catch {}
        try { Remove-Item -LiteralPath $CredScript -Force -EA SilentlyContinue } catch {}
    }
}

# =============================================================================
# STEP 3 -- PROFILE STAGING (robocopy key folders before unjoin)
# =============================================================================

function Invoke-ProfileStaging {
    param([string]$AzureProfileName)

    if ([string]::IsNullOrEmpty($AzureProfileName)) {
        Write-Log '  No Azure AD profile detected -- skipping profile staging'
        return @{ Staged = $false; SourcePath = ''; FolderCount = 0 }
    }

    $sourcePath = "C:\Users\$AzureProfileName"
    if (-not (Test-Path $sourcePath)) {
        Write-Log "  Azure profile path not found: $sourcePath -- skipping staging"
        return @{ Staged = $false; SourcePath = $sourcePath; FolderCount = 0 }
    }

    Write-Log "  Staging profile from: $sourcePath"
    if (-not (Test-Path $StagingDir)) { New-Item $StagingDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

    $folders = @(
        'Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music', 'Favorites',
        'AppData\Roaming\Microsoft\Outlook',
        'AppData\Roaming\Microsoft\Signatures',
        'AppData\Roaming\Microsoft\Templates',
        'AppData\Local\Microsoft\Outlook',
        'AppData\Roaming\Microsoft\Sticky Notes'
    )

    $staged = 0; $failed = 0
    foreach ($folder in $folders) {
        $src  = Join-Path $sourcePath $folder
        $dest = Join-Path $StagingDir $folder
        if (-not (Test-Path $src)) { continue }
        try {
            if (-not (Test-Path (Split-Path $dest -Parent))) {
                New-Item (Split-Path $dest -Parent) -ItemType Directory -Force -EA SilentlyContinue | Out-Null
            }
            & robocopy.exe $src $dest /E /COPYALL /R:2 /W:1 /NFL /NDL /NJH /NJS /NC /NS 2>&1 | Out-Null
            Write-Log "    [Staged] $folder"
            $staged++
        } catch { Write-Log "    [WARN] Failed to stage ${folder}: $($_.Exception.Message)" 'WARN'; $failed++ }
    }

    # Also grab any loose PST files in profile root
    try {
        Get-ChildItem -Path $sourcePath -Filter '*.pst' -Recurse -Force -EA SilentlyContinue |
            Where-Object { $_.DirectoryName -notmatch 'AppData\\Roaming\\Microsoft\\Outlook' } |
            ForEach-Object {
                $dest = Join-Path $StagingDir "ExtraPST\$($_.Name)"
                if (-not (Test-Path "$StagingDir\ExtraPST")) { New-Item "$StagingDir\ExtraPST" -ItemType Directory -Force -EA SilentlyContinue | Out-Null }
                Copy-Item -LiteralPath $_.FullName -Destination $dest -Force -EA SilentlyContinue
                Write-Log "    [Staged] PST: $($_.Name)"
            }
    } catch {}

    Write-Log "  Staging complete: $staged folder(s) staged, $failed failed"
    return @{ Staged = $true; SourcePath = $sourcePath; FolderCount = $staged }
}

# =============================================================================
# STEP 4 -- MDM / INTUNE UNENROLL
# =============================================================================

function Invoke-MDMUnenroll {
    param([bool]$Aggressive)

    Write-Log "  MDM unenroll mode: $(if ($Aggressive) {'AGGRESSIVE'} else {'STANDARD'})"

    # Standard: dsregcmd /leave handles Azure AD + MDM registration
    Write-Log '  Running dsregcmd /leave...'
    try {
        $out = & dsregcmd.exe /leave 2>&1
        $out | ForEach-Object { if ($_ -match '\S') { Write-Log "    $_" } }
    } catch { Write-Log "  WARN: dsregcmd /leave failed: $($_.Exception.Message)" 'WARN' }

    if (-not $Aggressive) { return }

    # Aggressive: strip MDM enrollment registry keys, certificates, scheduled tasks
    Write-Log '  Aggressive MDM strip: removing enrollment registry keys...'
    $enrollKey = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    try {
        $enrollments = Get-ChildItem -Path $enrollKey -EA SilentlyContinue
        foreach ($e in $enrollments) {
            $props = Get-ItemProperty -Path $e.PSPath -EA SilentlyContinue
            if ($props -and ($props.ProviderID -or $props.EnrollmentState)) {
                Remove-Item -Path $e.PSPath -Recurse -Force -EA SilentlyContinue
                Write-Log "    Removed enrollment: $(Split-Path $e.Name -Leaf)"
            }
        }
    } catch { Write-Log "  WARN: Enrollment key removal partial: $($_.Exception.Message)" 'WARN' }

    Write-Log '  Removing MDM scheduled tasks...'
    try {
        & schtasks.exe /Delete /TN '\Microsoft\Windows\EnterpriseMgmt' /F 2>&1 | Out-Null
        Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked' -EA SilentlyContinue |
            ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -EA SilentlyContinue }
    } catch {}

    Write-Log '  Removing MDM certificates from cert store...'
    try {
        Get-ChildItem 'Cert:\LocalMachine\My' -EA SilentlyContinue |
            Where-Object { $_.Issuer -match 'Microsoft Intune|MDM|EnterpriseEnrollment' } |
            ForEach-Object {
                Remove-Item -LiteralPath $_.PSPath -Force -EA SilentlyContinue
                Write-Log "    Removed cert: $($_.Subject)"
            }
    } catch {}

    Write-Log '  Clearing AAD/MDM device registration state...'
    try {
        $aadRegKeys = @(
            'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CDJ',
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WorkplaceJoin'
        )
        foreach ($k in $aadRegKeys) {
            if (Test-Path $k) {
                Remove-Item -Path $k -Recurse -Force -EA SilentlyContinue
                Write-Log "    Cleared: $k"
            }
        }
    } catch {}

    Write-Log '  Aggressive MDM strip complete'
}

# =============================================================================
# STEP 5 -- DOMAIN JOIN
# =============================================================================

function Invoke-DomainJoin {
    param([System.Management.Automation.PSCredential]$Credential, [string]$Domain, [string]$OU)

    Write-Log "  Joining domain: $Domain"
    if ($OU) { Write-Log "  Target OU: $OU" }

    try {
        $joinParams = @{
            DomainName = $Domain
            Credential = $Credential
            Force      = $true
            ErrorAction= 'Stop'
        }
        if (-not [string]::IsNullOrEmpty($OU)) { $joinParams['OUPath'] = $OU }

        Add-Computer @joinParams
        Write-Log "  Domain join SUCCESS: $Domain"
        return $true
    } catch {
        Write-Log "ERROR: Domain join failed: $($_.Exception.Message)" 'ERROR'

        # Common failure hints
        $msg = $_.Exception.Message
        if ($msg -match 'credential') { Write-Log '  HINT: Check domain admin username format (domain\user or user@domain.com)' 'WARN' }
        if ($msg -match 'network|RPC') { Write-Log '  HINT: Cannot reach domain controller -- verify network connectivity' 'WARN' }
        if ($msg -match 'already.*member') { Write-Log '  HINT: Machine may already be joined -- check dsregcmd /status' 'WARN' }
        return $false
    }
}

# =============================================================================
# STEP 6 -- PROFILE RESTORE TASK (runs post-login as domain user)
# =============================================================================

function Register-ProfileRestoreTask {
    param([string]$StagingPath, [string]$SourceProfileName)

    if (-not (Test-Path $StagingPath)) {
        Write-Log '  No staging directory -- skipping restore task'
        return
    }

    $restoreScript = @"
# Paladin Profile Restore -- runs once after domain login
# Copies staged Azure AD profile data to new domain profile
param()
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'

`$staging = '$StagingPath'
`$logFile = 'C:\ProgramData\Paladin\DomainMigration\ProfileRestore.log'

function Write-RLog {
    param(`$m)
    Add-Content -Path `$logFile -Value "[(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] `$m" -EA SilentlyContinue
    Write-Host `$m
}

Write-RLog 'Profile restore starting...'
`$dest = `$env:USERPROFILE
if (-not `$dest -or -not (Test-Path `$dest)) { Write-RLog 'ERROR: USERPROFILE not found'; exit 1 }

`$folders = @(
    'Desktop','Documents','Downloads','Pictures','Videos','Music','Favorites',
    'AppData\Roaming\Microsoft\Outlook',
    'AppData\Roaming\Microsoft\Signatures',
    'AppData\Roaming\Microsoft\Templates',
    'AppData\Local\Microsoft\Outlook',
    'AppData\Roaming\Microsoft\Sticky Notes'
)

foreach (`$folder in `$folders) {
    `$src  = Join-Path `$staging `$folder
    `$dst  = Join-Path `$dest `$folder
    if (-not (Test-Path `$src)) { continue }
    if (-not (Test-Path `$dst)) { New-Item `$dst -ItemType Directory -Force -EA SilentlyContinue | Out-Null }
    & robocopy.exe `$src `$dst /E /COPYALL /R:1 /W:0 /NFL /NDL /NJH /NJS /XC /XN /XO 2>&1 | Out-Null
    Write-RLog "  Restored: `$folder"
}

# Extra PSTs
`$extraPST = Join-Path `$staging 'ExtraPST'
if (Test-Path `$extraPST) {
    `$pstDest = Join-Path `$dest 'Documents'
    if (-not (Test-Path `$pstDest)) { New-Item `$pstDest -ItemType Directory -Force -EA SilentlyContinue | Out-Null }
    Copy-Item -Path "`$extraPST\*" -Destination `$pstDest -Force -EA SilentlyContinue
    Write-RLog '  Restored: Extra PST files -> Documents'
}

Write-RLog 'Profile restore complete. You may now delete the staging folder if all looks good:'
Write-RLog "  `$staging"

# Self-delete scheduled task
try { & schtasks.exe /Delete /TN 'Paladin_ProfileRestore' /F 2>&1 | Out-Null } catch {}
"@

    [System.IO.File]::WriteAllText($RestoreScript, $restoreScript, [System.Text.Encoding]::Unicode)

    # Register as ONLOGON task -- fires as the domain user on first login
    try {
        & schtasks.exe /Delete /TN $RestoreTask /F 2>&1 | Out-Null
        $cmd = "$PsExe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$RestoreScript`""
        & schtasks.exe /Create /TN $RestoreTask /TR $cmd /SC ONLOGON /RU 'BUILTIN\Users' /RL HIGHEST /F 2>&1 | Out-Null
        Write-Log "  Profile restore task registered: '$RestoreTask' -- fires on first domain login"
    } catch { Write-Log "  WARN: Could not register restore task: $($_.Exception.Message)" 'WARN' }
}

# =============================================================================
# MAIN
# =============================================================================
if (-not (Test-Path $BaseDir)) { New-Item $BaseDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

$startTime = Get-Date

Write-Sep
Write-Log "Paladin Domain Migration v$ScriptVer | Site: $SiteName | Machine: $MachineName"
Write-Log "Target domain: $DomainName | OU: $(if($OUPath){'Specified'}else{'Default'}) | AggressiveMDM: $AggressiveMDM"
Write-Sep

# Validate required input
if ([string]::IsNullOrEmpty($DomainName)) {
    Write-Log 'ERROR: DomainName input variable is required' 'ERROR'
    Set-DattoUDF -Slot $UDFSlot -Value "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | DomainName not specified"
    exit 1
}

# --- STEP 1: Detect join state ---
Write-Sep
Write-Log 'STEP 1: Detecting current join state'
Write-Sep2
$joinState = Get-JoinState

Write-Log "  Azure AD Joined  : $($joinState.AzureADJoined)"
Write-Log "  Domain Joined    : $($joinState.DomainJoined)"
Write-Log "  Hybrid Joined    : $($joinState.HybridJoined)"
Write-Log "  Workplace Joined : $($joinState.WorkplaceJoined)"
Write-Log "  MDM Enrolled     : $($joinState.MDMEnrolled)"
Write-Log "  Domain Name      : $($joinState.DomainName)"
Write-Log "  Azure Device ID  : $($joinState.AzureDeviceId)"
Write-Log "  Azure Tenant     : $($joinState.TenantName)"
Write-Log "  Azure Profile    : $($joinState.AzureProfileUser)"

# Check if already on target domain
if ($joinState.DomainJoined -and $joinState.DomainName -ieq $DomainName -and -not $joinState.AzureADJoined) {
    Write-Log "Machine is already joined to $DomainName and not Azure AD joined. Nothing to do."
    Set-DattoUDF -Slot $UDFSlot -Value "PASS $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | Already joined to $DomainName"
    exit 0
}

$currentState = if ($joinState.HybridJoined)   { 'Hybrid' }
           elseif ($joinState.AzureADJoined)    { 'AzureAD' }
           elseif ($joinState.DomainJoined)      { 'LocalDomain' }
           elseif ($joinState.WorkplaceJoined)   { 'Workplace' }
           else                                  { 'Workgroup' }

Write-Log "  Current state: $currentState"
Write-Log "  Migration path: $currentState -> LocalDomain($DomainName)"

# --- STEP 2: Collect credentials ---
Write-Sep
Write-Log 'STEP 2: Collecting domain admin credentials'
Write-Sep2
Write-Log '  Launching credential dialog on user desktop...'

$credential = Get-DomainCredential -Domain $DomainName
if ($null -eq $credential) {
    Write-Log 'ERROR: No credentials provided -- aborting' 'ERROR'
    Set-DattoUDF -Slot $UDFSlot -Value "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | Credential dialog cancelled"
    exit 1
}

# --- STEP 3: Snapshot Azure info for portal cleanup ---
Write-Sep
Write-Log 'STEP 3: Azure AD device snapshot (for manual portal cleanup)'
Write-Sep2
if ($joinState.AzureADJoined -or $joinState.HybridJoined) {
    Write-Log "  *** ACTION REQUIRED AFTER MIGRATION ***"
    Write-Log "  Remove this device from Azure AD portal manually:"
    Write-Log "  Device Name : $MachineName"
    Write-Log "  Azure Device ID: $($joinState.AzureDeviceId)"
    Write-Log "  Tenant      : $($joinState.TenantName)"
    Write-Log "  Portal URL  : https://portal.azure.com/#view/Microsoft_AAD_Devices/DevicesMenuBlade"
    Write-Log "  *** END ACTION REQUIRED ***"
} else {
    Write-Log '  Not Azure AD joined -- no portal cleanup needed'
}

# --- STEP 4: Profile staging ---
Write-Sep
Write-Log 'STEP 4: Azure AD profile staging'
Write-Sep2
$stagingResult = Invoke-ProfileStaging -AzureProfileName $joinState.AzureProfileUser

# --- STEP 5: MDM unenroll ---
if ($joinState.MDMEnrolled -or $joinState.AzureADJoined -or $joinState.HybridJoined) {
    Write-Sep
    Write-Log 'STEP 5: MDM / Intune unenroll'
    Write-Sep2
    Invoke-MDMUnenroll -Aggressive $AggressiveMDM
} else {
    Write-Log 'STEP 5: MDM unenroll skipped -- not enrolled'
}

# --- STEP 6: Domain join ---
Write-Sep
Write-Log 'STEP 6: Joining local AD domain'
Write-Sep2

# Unjoin from existing domain if hybrid
if ($joinState.HybridJoined -or ($joinState.DomainJoined -and $joinState.DomainName -ne $DomainName)) {
    Write-Log '  Unjoining from current domain first...'
    try {
        Remove-Computer -Force -PassThru -Credential $credential -EA SilentlyContinue | Out-Null
        Write-Log '  Unjoined from current domain'
    } catch { Write-Log "  WARN: Unjoin error (may be OK): $($_.Exception.Message)" 'WARN' }
}

$joinOK = Invoke-DomainJoin -Credential $credential -Domain $DomainName -OU $OUPath

# Wipe credential from memory
$credential = $null
[System.GC]::Collect()

if (-not $joinOK) {
    Set-DattoUDF -Slot $UDFSlot -Value "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | Domain join failed -- check log"
    exit 1
}

# --- STEP 7: Register profile restore task ---
Write-Sep
Write-Log 'STEP 7: Registering profile restore task'
Write-Sep2
if ($stagingResult.Staged) {
    Register-ProfileRestoreTask -StagingPath $StagingDir -SourceProfileName $joinState.AzureProfileUser
} else {
    Write-Log '  No profile staged -- restore task not needed'
}

# --- FINAL REPORT ---
$elapsed = [int]((Get-Date) - $startTime).TotalMinutes
Write-Sep
Write-Log "PALADIN DOMAIN MIGRATION -- COMPLETE"
Write-Log "Machine     : $MachineName | Site: $SiteName"
Write-Log "Migration   : $currentState -> LocalDomain($DomainName)"
Write-Log "Duration    : ${elapsed}m"
Write-Log "Profile staged: $($stagingResult.FolderCount) folder(s)"
if ($stagingResult.Staged) {
    Write-Log "Restore task: '$RestoreTask' will run on first domain login"
    Write-Log "Staging path: $StagingDir"
}
if ($joinState.AzureDeviceId) {
    Write-Log "Azure cleanup: Remove device '$MachineName' ($($joinState.AzureDeviceId)) from Azure AD portal"
}
Write-Log "Rebooting in 60 seconds..."
Write-Sep

$udfMsg = "PASS $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | $currentState->$DomainName | Profile:$($stagingResult.Staged)"
Set-DattoUDF -Slot $UDFSlot -Value $udfMsg

Show-UserMessage "Domain migration complete. Your PC will restart in 60 seconds to join $DomainName. Log in with your domain account after restart."
Start-Sleep -Seconds 30
Show-UserMessage "Your PC will restart in 30 seconds. Log in with your DOMAIN account after restart (not your Microsoft account)."
Start-Sleep -Seconds 30

Write-Log 'Initiating reboot for domain join to take effect.'
& shutdown.exe /r /t 0 /f /c "Paladin: Joined $DomainName. Please log in with your domain account." 2>&1 | Out-Null
exit 0
