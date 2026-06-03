#Requires -Version 3.0
# =============================================================================
# Paladin Domain Connectivity Repair [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
#
# PHASES:
#   Phase 1 -- Diagnose: DNS, DC reachability, secure channel, Netlogon,
#              GP last applied. Exits 0 if healthy, no further action.
#   Phase 2 -- Remediate: Netlogon restart, gpupdate /force, secure channel
#              repair, DNS re-register, re-verify. Exits 0 if resolved.
#   Phase 3 -- Nuclear: Detect logged-on user. If none -> graceful fail,
#              exit 1, ticket fires. If user present -> launch WPF credential
#              prompt via scheduled task. Tech enters domain admin creds live.
#              Unjoin -> rejoin -> reboot prompt. Creds in SecureString only,
#              never logged, zeroed after use.
#
# LOG:    C:\ProgramData\Paladin\DomainRepair\DomainRepair.log
# UDF:    Slot 14 (PALADIN-DOMAINREPAIR)
# EXIT:   0=healthy or repaired, 1=unrecoverable or no user for nuclear
# =============================================================================

param([switch]$GUIMode)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer   = '1.0.0'
$LogDir      = 'C:\ProgramData\Paladin\DomainRepair'
$LogFile     = "$LogDir\DomainRepair.log"
$SelfDest    = "$LogDir\Paladin-DomainRepair-Nuclear.ps1"
$TaskName    = 'Paladin_DomainRepair_Nuclear'
$UDF_SLOT    = 14   # PALADIN-DOMAINREPAIR
$MaxLogMB    = 5

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

function Write-Sep { Write-Log ('=' * 64) }

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

function Get-DomainName {
    try {
        $cs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
        if ($cs -and $cs.Domain -and $cs.Domain -ne 'WORKGROUP') { return $cs.Domain }
    } catch {}
    try {
        $dom = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -EA SilentlyContinue).Domain
        if ($dom) { return $dom }
    } catch {}
    return $null
}

function Get-LoggedOnUser {
    try {
        $cs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
        if ($cs -and $cs.UserName) { return ($cs.UserName -split '\\')[-1] }
    } catch {}
    try {
        $qu = & query user 2>&1
        foreach ($l in $qu) {
            if ($l -match 'Active') { return ($l.Trim() -split '\s+')[0].TrimStart('>') }
        }
    } catch {}
    return $null
}

function Test-Port {
    param([string]$Server, [int]$Port, [int]$TimeoutMs = 2000)
    try {
        $tcp    = New-Object System.Net.Sockets.TcpClient
        $result = $tcp.BeginConnect($Server, $Port, $null, $null)
        $wait   = $result.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $wait) { $tcp.Close(); return $false }
        $tcp.EndConnect($result) | Out-Null
        $tcp.Close()
        return $true
    } catch { return $false }
}

# =============================================================================
# PHASE 1 -- DIAGNOSTICS
# =============================================================================

function Invoke-Diagnose {
    param([string]$Domain)

    $results = @{
        NetlogonRunning = $false
        DnsResolves     = $false
        DCPort389       = $false
        DCPort445       = $false
        SecureChannel   = $false
        NltestOutput    = ''
        DCName          = ''
        GPLastApplied   = ''
        AllHealthy      = $false
    }

    Write-Sep
    Write-Log "PHASE 1: Diagnostics | Domain: $Domain"

    # Netlogon
    try {
        $nl = Get-WmiObject -Class Win32_Service -Filter "Name='Netlogon'" -EA SilentlyContinue
        $results.NetlogonRunning = ($null -ne $nl -and $nl.State -eq 'Running')
        Write-Log "  Netlogon: $($nl.State)"
    } catch { Write-Log "  Netlogon: query failed" }

    # DNS resolution
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses($Domain)
        if ($resolved.Count -gt 0) {
            $results.DnsResolves = $true
            $results.DCName      = $resolved[0].IPAddressToString
            Write-Log "  DNS: resolved $Domain -> $($results.DCName)"
        }
    } catch { Write-Log "  DNS: FAILED to resolve $Domain" -Level 'WARN' }

    # DC port reachability
    if ($results.DnsResolves) {
        $results.DCPort389 = Test-Port -Server $Domain -Port 389
        $results.DCPort445 = Test-Port -Server $Domain -Port 445
        Write-Log "  DC LDAP  (389): $(if ($results.DCPort389) {'OPEN'} else {'CLOSED'})"
        Write-Log "  DC SMB   (445): $(if ($results.DCPort445) {'OPEN'} else {'CLOSED'})"
    } else {
        Write-Log "  DC ports: skipped (DNS failed)" -Level 'WARN'
    }

    # Secure channel via nltest
    try {
        $nlOut = & nltest.exe /sc_verify:$Domain 2>&1
        $results.NltestOutput = ($nlOut -join ' ')
        if ($results.NltestOutput -match '0x0\b|successful|Successful') {
            $results.SecureChannel = $true
            Write-Log "  Secure channel: HEALTHY"
        } else {
            Write-Log "  Secure channel: BROKEN -- $($results.NltestOutput)" -Level 'WARN'
        }
    } catch { Write-Log "  Secure channel: nltest failed: $($_.Exception.Message)" -Level 'WARN' }

    # GP last applied
    try {
        $gpTime = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Extension-List\{00000000-0000-0000-0000-000000000000}' -EA SilentlyContinue).EndTimeLo
        if ($null -ne $gpTime) {
            $results.GPLastApplied = "Registry key present"
            Write-Log "  GP: registry key present"
        }
    } catch {}
    if (-not $results.GPLastApplied) {
        # Fallback: check event log for GP success
        try {
            $ev = Get-WmiObject -Class Win32_NTLogEvent -Filter "Logfile='System' AND EventCode=1502" -EA SilentlyContinue |
                  Sort-Object TimeGenerated -Descending | Select-Object -First 1
            if ($null -ne $ev) {
                $results.GPLastApplied = $ev.TimeGenerated
                Write-Log "  GP last applied (event 1502): $($ev.TimeGenerated)"
            } else {
                Write-Log "  GP: no recent event 1502 found" -Level 'WARN'
            }
        } catch {}
    }

    $results.AllHealthy = $results.NetlogonRunning -and $results.DnsResolves -and
                          $results.DCPort389 -and $results.SecureChannel

    Write-Log "  Diagnostic summary: Netlogon=$($results.NetlogonRunning) DNS=$($results.DnsResolves) LDAP=$($results.DCPort389) SMB=$($results.DCPort445) SecureCh=$($results.SecureChannel)"
    return $results
}

# =============================================================================
# PHASE 2 -- REMEDIATION
# =============================================================================

function Invoke-Remediate {
    param([string]$Domain)

    Write-Sep
    Write-Log "PHASE 2: Remediation"

    # Step 1: Restart Netlogon
    Write-Log "  Step 1: Restarting Netlogon..."
    try {
        & sc.exe stop Netlogon 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        & sc.exe start Netlogon 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        $nl = Get-WmiObject -Class Win32_Service -Filter "Name='Netlogon'" -EA SilentlyContinue
        Write-Log "  Netlogon state after restart: $($nl.State)"
    } catch { Write-Log "  WARN: Netlogon restart failed: $($_.Exception.Message)" }

    # Step 2: gpupdate /force
    Write-Log "  Step 2: gpupdate /force..."
    try {
        $gpOut = & gpupdate.exe /force 2>&1
        $gpOut | ForEach-Object { Write-Log "    $_" }
    } catch { Write-Log "  WARN: gpupdate failed: $($_.Exception.Message)" }

    # Step 3: Secure channel repair
    Write-Log "  Step 3: Secure channel repair (Test-ComputerSecureChannel -Repair)..."
    $scRepaired = $false
    try {
        $scResult = & nltest.exe /sc_reset:$Domain 2>&1
        Write-Log "  nltest sc_reset: $($scResult -join ' ')"
        Start-Sleep -Seconds 3
        $verify = & nltest.exe /sc_verify:$Domain 2>&1
        if (($verify -join ' ') -match '0x0\b|successful|Successful') {
            $scRepaired = $true
            Write-Log "  Secure channel: REPAIRED via nltest"
        }
    } catch { Write-Log "  WARN: nltest sc_reset failed: $($_.Exception.Message)" }

    # Fallback: netdom resetpwd
    if (-not $scRepaired) {
        Write-Log "  Step 3b: Trying netdom resetpwd..."
        try {
            $ndOut = & netdom.exe resetpwd /server:$Domain /userd:$Domain\Administrator /passwordd:* 2>&1
            Write-Log "  netdom: $($ndOut -join ' ')"
        } catch { Write-Log "  WARN: netdom resetpwd failed: $($_.Exception.Message)" }
    }

    # Step 4: DNS re-register
    Write-Log "  Step 4: ipconfig /registerdns..."
    try {
        & ipconfig.exe /flushdns 2>&1 | Out-Null
        & ipconfig.exe /registerdns 2>&1 | Out-Null
        Write-Log "  DNS re-registered"
    } catch { Write-Log "  WARN: DNS re-register failed: $($_.Exception.Message)" }

    Start-Sleep -Seconds 5
}

# =============================================================================
# PHASE 3 -- NUCLEAR LAUNCHER (SYSTEM side)
# =============================================================================

function Invoke-NuclearLauncher {
    param([string]$Domain)

    Write-Sep
    Write-Log "PHASE 3: Nuclear path -- checking for logged-on user"

    $user = Get-LoggedOnUser
    if (-not $user) {
        Write-Log "PHASE 3: No logged-on user detected. Nuclear path requires physical presence." -Level 'WARN'
        Write-Log "PHASE 3: Graceful fail -- technician must be present to enter domain credentials." -Level 'WARN'
        Set-DattoUDF -Slot $UDF_SLOT -Value "NUCLEAR-NOUSER $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Repair failed, rejoin required, no active user session"
        return $false
    }

    Write-Log "PHASE 3: Logged-on user: $user -- launching credential prompt on desktop"

    # Stage self to log dir
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $SelfDest -Force -EA Stop
        Write-Log "  Staged: $SelfDest"
    } catch { Write-Log "ERROR: Could not stage script: $($_.Exception.Message)"; return $false }

    # Store domain name for GUI to pre-fill
    try {
        if (-not (Test-Path 'HKLM:\SOFTWARE\Paladin\DomainRepair')) {
            New-Item -Path 'HKLM:\SOFTWARE\Paladin\DomainRepair' -Force | Out-Null
        }
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Paladin\DomainRepair' `
            -Name 'PendingDomain' -Value $Domain -PropertyType String -Force | Out-Null
    } catch {}

    # Launch GUI as logged-on user
    $psArgs = "-NonInteractive -ExecutionPolicy Bypass -File `"$SelfDest`" -GUIMode"
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    & schtasks.exe /Create /TN $TaskName /TR "PowerShell.exe $psArgs" `
        /SC ONCE /ST 00:00 /RU $user /IT /F /RL HIGHEST 2>&1 | Out-Null
    & schtasks.exe /Run /TN $TaskName 2>&1 | Out-Null
    Write-Log "  Credential prompt launched on $user desktop"
    Start-Sleep -Seconds 5
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null

    Set-DattoUDF -Slot $UDF_SLOT -Value "NUCLEAR-LAUNCHED $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Credential prompt sent to $user desktop"
    return $true
}

# =============================================================================
# GUI MODE -- WPF CREDENTIAL PROMPT (runs as logged-on user)
# =============================================================================

if ($GUIMode) {

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    # Read pending domain from registry
    $pendingDomain = ''
    try {
        $pd = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Paladin\DomainRepair' -Name 'PendingDomain' -EA SilentlyContinue
        if ($pd) { $pendingDomain = $pd.PendingDomain }
    } catch {}

    [xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Paladin Domain Repair"
    Width="460" Height="380"
    WindowStartupLocation="CenterScreen"
    ResizeMode="NoResize"
    Background="#F5F5F5"
    FontFamily="Segoe UI" FontSize="13">
  <Grid Margin="0">
    <Grid.RowDefinitions>
      <RowDefinition Height="60"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="50"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#1A3A5C">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0">
        <TextBlock Text="Paladin" Foreground="#5BA3E0" FontSize="18" FontWeight="Bold"/>
        <TextBlock Text=" Domain Repair" Foreground="White" FontSize="18" FontWeight="Light"/>
      </StackPanel>
    </Border>

    <StackPanel Grid.Row="1" Margin="24,16">
      <TextBlock Text="Domain connectivity repair requires domain administrator credentials." TextWrapping="Wrap" Margin="0,0,0,16" Foreground="#333"/>
      <TextBlock Text="Credentials are used once in memory only and are never saved to disk, log, or registry." TextWrapping="Wrap" Margin="0,0,0,20" Foreground="#555" FontSize="11" FontStyle="Italic"/>

      <TextBlock Text="Domain:" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <TextBox x:Name="TxtDomain" Padding="6,4" Margin="0,0,0,12" FontSize="13"/>

      <TextBlock Text="Domain Admin Username:" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <TextBox x:Name="TxtUser" Padding="6,4" Margin="0,0,0,12" FontSize="13"/>

      <TextBlock Text="Password:" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <PasswordBox x:Name="TxtPass" Padding="6,4" Margin="0,0,0,16" FontSize="13"/>

      <TextBlock x:Name="TxtStatus" Foreground="#C0392B" FontSize="11" TextWrapping="Wrap" Margin="0,0,0,4"/>
    </StackPanel>

    <Border Grid.Row="2" Background="#E8EEF4" Padding="16,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="TxtProgress" Grid.Column="0" VerticalAlignment="Center" Foreground="#555" FontSize="11"/>
        <Button x:Name="BtnRejoin" Grid.Column="1" Content="Rejoin Domain"
                Background="#C0392B" Foreground="White" Padding="14,6"
                BorderThickness="0" Cursor="Hand" Margin="0,0,8,0"/>
        <Button x:Name="BtnCancel" Grid.Column="2" Content="Cancel"
                Background="#7F8C8D" Foreground="White" Padding="14,6"
                BorderThickness="0" Cursor="Hand"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

    $reader  = New-Object System.Xml.XmlNodeReader $xaml
    $window  = [Windows.Markup.XamlReader]::Load($reader)

    $TxtDomain   = $window.FindName('TxtDomain')
    $TxtUser     = $window.FindName('TxtUser')
    $TxtPass     = $window.FindName('TxtPass')
    $TxtStatus   = $window.FindName('TxtStatus')
    $TxtProgress = $window.FindName('TxtProgress')
    $BtnRejoin   = $window.FindName('BtnRejoin')
    $BtnCancel   = $window.FindName('BtnCancel')

    $TxtDomain.Text = $pendingDomain

    $BtnCancel.Add_Click({
        $window.Close()
    })

    $BtnRejoin.Add_Click({
        $domain   = $TxtDomain.Text.Trim()
        $username = $TxtUser.Text.Trim()
        $password = $TxtPass.SecurePassword

        if ([string]::IsNullOrEmpty($domain))   { $TxtStatus.Text = 'Domain is required.'; return }
        if ([string]::IsNullOrEmpty($username)) { $TxtStatus.Text = 'Username is required.'; return }
        if ($password.Length -eq 0)             { $TxtStatus.Text = 'Password is required.'; return }

        $BtnRejoin.IsEnabled = $false
        $BtnCancel.IsEnabled = $false
        $TxtProgress.Text    = 'Working...'
        $TxtStatus.Text      = ''

        try {
            # Build PSCredential -- creds live in memory only
            $fullUser  = if ($username -match '\\|@') { $username } else { "$domain\$username" }
            $cred      = New-Object System.Management.Automation.PSCredential($fullUser, $password)

            $TxtProgress.Text = 'Removing from domain...'
            Remove-Computer -UnjoinDomainCredential $cred -Force -EA Stop

            $TxtProgress.Text = 'Rejoining domain...'
            Add-Computer -DomainName $domain -Credential $cred -Force -EA Stop

            # Zero credential
            $cred = $null
            $password.Dispose()

            # Write result to registry for SYSTEM side to pick up
            try {
                New-ItemProperty -Path 'HKLM:\SOFTWARE\Paladin\DomainRepair' `
                    -Name 'NuclearResult' -Value "PASS $(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
                    -PropertyType String -Force | Out-Null
            } catch {}

            $TxtProgress.Text    = 'Success'
            $TxtStatus.Foreground = '#1A7A3C'
            $TxtStatus.Text      = 'Domain rejoin successful. A reboot is required to complete the process.'
            $BtnRejoin.Content   = 'Done'

            [System.Windows.MessageBox]::Show(
                "Domain rejoin successful.`n`nThis computer must be restarted to complete domain connectivity repair.`n`nPlease save all open work and restart now.",
                'Paladin Domain Repair',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            ) | Out-Null

            $window.Close()

        } catch {
            $cred = $null
            try { $password.Dispose() } catch {}
            $TxtProgress.Text     = ''
            $TxtStatus.Foreground = '#C0392B'
            $TxtStatus.Text       = "Rejoin failed: $($_.Exception.Message)"

            try {
                New-ItemProperty -Path 'HKLM:\SOFTWARE\Paladin\DomainRepair' `
                    -Name 'NuclearResult' -Value "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') $($_.Exception.Message)" `
                    -PropertyType String -Force | Out-Null
            } catch {}

            $BtnRejoin.IsEnabled = $true
            $BtnCancel.IsEnabled = $true
        }
    })

    $window.ShowDialog() | Out-Null
    exit 0
}

# =============================================================================
# SYSTEM MODE -- MAIN ENTRY
# =============================================================================

if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

$siteName = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }

Write-Sep
Write-Log "Paladin Domain Connectivity Repair v$ScriptVer | Site: $siteName | Machine: $env:COMPUTERNAME"
Write-Sep

# Get domain
$domain = Get-DomainName
if (-not $domain) {
    Write-Log "ERROR: Machine does not appear to be domain-joined (domain = WORKGROUP or null)" -Level 'WARN'
    Set-DattoUDF -Slot $UDF_SLOT -Value "ERROR $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Not domain-joined"
    exit 1
}
Write-Log "Domain: $domain"

# Phase 1 -- Diagnose
$diag = Invoke-Diagnose -Domain $domain

if ($diag.AllHealthy) {
    Write-Sep
    Write-Log "RESULT: Domain connectivity HEALTHY -- no remediation required"
    Set-DattoUDF -Slot $UDF_SLOT -Value "PASS $(Get-Date -Format 'yyyy-MM-dd HH:mm') | DNS=OK LDAP=OK SecureCh=OK Netlogon=OK"
    exit 0
}

# Phase 2 -- Remediate
Invoke-Remediate -Domain $domain

# Re-diagnose after remediation
Write-Sep
Write-Log "PHASE 2: Re-verifying after remediation..."
$diag2 = Invoke-Diagnose -Domain $domain

if ($diag2.AllHealthy) {
    Write-Sep
    Write-Log "RESULT: Domain connectivity RESTORED via automated remediation"
    Set-DattoUDF -Slot $UDF_SLOT -Value "FIXED $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Repaired: Netlogon+SecureCh+GP"
    exit 0
}

# Phase 3 -- Nuclear
Write-Log "PHASE 2: Automated remediation insufficient -- escalating to nuclear path"
$launched = Invoke-NuclearLauncher -Domain $domain

if ($launched) {
    Write-Log "PHASE 3: Credential prompt launched. Awaiting technician action."
    Write-Log "NOTE: Check UDF14 and log after technician completes rejoin."
    exit 0
} else {
    Write-Sep
    Write-Log "RESULT: UNRECOVERABLE -- automated repair failed, nuclear path unavailable (no user session)" -Level 'WARN'
    Set-DattoUDF -Slot $UDF_SLOT -Value "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Auto-repair failed, rejoin required, no active session"
    exit 1
}
