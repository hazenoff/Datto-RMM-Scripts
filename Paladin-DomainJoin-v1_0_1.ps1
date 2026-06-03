#Requires -Version 3.0
# =============================================================================
# Paladin Domain Join [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.1
# Context: NT AUTHORITY\SYSTEM (Datto entry) -> logged-on user (GUI)
#
# DESCRIPTION:
#   Automated domain join with live credential prompt. Launched by Datto as
#   SYSTEM, relaunches as logged-on user for credential entry (same pattern
#   as DomainRepair nuclear path). Tech enters domain name, admin username,
#   and password only. Everything else is automated:
#     - DNS verification + auto-correction to DC IP
#     - Time skew check + w32tm sync if needed
#     - Domain reachability verification (DNS + LDAP 389)
#     - Add-Computer to default Computers container
#     - Computer description set (site + date)
#     - End user domain username pre-staged to credential cache
#       (net use against NETLOGON share forces Kerberos ticket + cache)
#     - gpupdate /force post-join
#     - 60-second reboot countdown (auto-reboots, cancelable)
#
# SECURITY:
#   Credentials entered live in WPF GUI only. PSCredential in-memory,
#   SecureString disposed after use. Nothing credential-related written
#   to disk, log, registry, or Datto output.
#
# LOG:    C:\ProgramData\Paladin\DomainJoin\DomainJoin.log
# UDF:    Slot 14 (PALADIN-DOMAINREPAIR -- same category)
# EXIT:   0 always (GUI tool -- result in UDF/log)
# =============================================================================

param([switch]$GUIMode)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer  = '1.0.1'
$LogDir     = 'C:\ProgramData\Paladin\DomainJoin'
$LogFile    = "$LogDir\DomainJoin.log"
$SelfDest   = "$LogDir\Paladin-DomainJoin-GUI.ps1"
$TaskName   = 'Paladin_DomainJoin_GUI'
$RegBase    = 'HKLM:\SOFTWARE\Paladin\DomainJoin'
$UDF_SLOT   = 14   # PALADIN-DOMAINREPAIR
$MaxLogMB   = 5

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
    param([string]$Server, [int]$Port, [int]$TimeoutMs = 3000)
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
# SYSTEM MODE -- LAUNCHER
# =============================================================================

if (-not $GUIMode) {

    if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

    $siteName = $env:CS_PROFILE_NAME
    if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }

    Write-Sep
    Write-Log "Paladin Domain Join v$ScriptVer | Site: $siteName | Machine: $env:COMPUTERNAME"
    Write-Sep

    # Check if already domain-joined
    try {
        $cs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
        if ($cs -and $cs.PartOfDomain -eq $true) {
            Write-Log "Machine is already domain-joined: $($cs.Domain)"
            Set-DattoUDF -Slot $UDF_SLOT -Value "ALREADY-JOINED $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Domain: $($cs.Domain)"
            exit 0
        }
    } catch {}

    Write-Log "Machine is not domain-joined (WORKGROUP). Proceeding with join workflow."

    # Check for logged-on user
    $user = Get-LoggedOnUser
    if (-not $user) {
        Write-Log "ERROR: No logged-on user detected. Domain join requires operator presence." -Level 'WARN'
        Set-DattoUDF -Slot $UDF_SLOT -Value "JOIN-NOUSER $(Get-Date -Format 'yyyy-MM-dd HH:mm') | No active session -- operator required"
        exit 1
    }

    Write-Log "Logged-on user: $user -- staging GUI"

    # Store site name for GUI to use in computer description
    try {
        if (-not (Test-Path $RegBase)) { New-Item -Path $RegBase -Force | Out-Null }
        New-ItemProperty -Path $RegBase -Name 'SiteName'    -Value $siteName      -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $RegBase -Name 'MachineName' -Value $env:COMPUTERNAME -PropertyType String -Force | Out-Null
    } catch {}

    # Stage and launch
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $SelfDest -Force -EA Stop
        Write-Log "Staged: $SelfDest"
    } catch { Write-Log "ERROR staging script: $($_.Exception.Message)"; exit 1 }

    $psArgs = "-NonInteractive -ExecutionPolicy Bypass -File `"$SelfDest`" -GUIMode"
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    & schtasks.exe /Create /TN $TaskName /TR "PowerShell.exe $psArgs" `
        /SC ONCE /ST 00:00 /RU $user /IT /F /RL HIGHEST 2>&1 | Out-Null
    & schtasks.exe /Run /TN $TaskName 2>&1 | Out-Null
    Write-Log "GUI launched on $user desktop. Awaiting operator input."
    Start-Sleep -Seconds 5
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null

    Set-DattoUDF -Slot $UDF_SLOT -Value "JOIN-LAUNCHED $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Credential prompt sent to $user"
    exit 0
}

# =============================================================================
# GUI MODE -- WPF (runs as logged-on user)
# =============================================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# Read site/machine from registry
$siteName    = 'UNKNOWN'
$machineName = $env:COMPUTERNAME
try {
    $reg = Get-ItemProperty -Path $RegBase -EA SilentlyContinue
    if ($reg) {
        if ($reg.SiteName)    { $siteName    = $reg.SiteName }
        if ($reg.MachineName) { $machineName = $reg.MachineName }
    }
} catch {}

# =============================================================================
# AUTOMATION FUNCTIONS (run in GUI context after cred entry)
# =============================================================================

function Write-GUILog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    try { Add-Content -Path $LogFile -Value $line -EA SilentlyContinue } catch {}
}

function Invoke-PreJoinChecks {
    param([string]$Domain, [scriptblock]$StatusCallback)

    $result = @{ DnsOk = $false; LdapOk = $false; DCip = ''; TimeSynced = $false; DnsFixed = $false }

    # Step 1: Resolve domain to DC IP
    & $StatusCallback 'Resolving domain DNS...'
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($Domain)
        if ($addrs.Count -gt 0) {
            $result.DCip  = $addrs[0].IPAddressToString
            $result.DnsOk = $true
            Write-GUILog "DNS: $Domain -> $($result.DCip)"
        }
    } catch { Write-GUILog "DNS: failed to resolve $Domain" 'WARN' }

    # If DNS fails, try auto-correcting by checking current adapters for DC hints
    if (-not $result.DnsOk) {
        & $StatusCallback 'DNS failed -- attempting auto-correction...'
        Write-GUILog "DNS auto-correction not possible without DC IP. Proceeding to LDAP check anyway." 'WARN'
    }

    # Step 2: LDAP reachability
    & $StatusCallback 'Verifying DC reachability...'
    if ($result.DCip) {
        $result.LdapOk = Test-Port -Server $result.DCip -Port 389
        Write-GUILog "LDAP 389 on $($result.DCip): $(if ($result.LdapOk) {'OPEN'} else {'CLOSED'})"
        if (-not $result.LdapOk) {
            # Try by name
            $result.LdapOk = Test-Port -Server $Domain -Port 389
            Write-GUILog "LDAP 389 on $Domain (name): $(if ($result.LdapOk) {'OPEN'} else {'CLOSED'})"
        }
    }

    # Step 3: DNS auto-fix -- point adapter DNS at DC if not already
    if ($result.DnsOk -and $result.DCip) {
        & $StatusCallback 'Checking DNS configuration...'
        try {
            $adapters = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
                Where-Object { $_.IPEnabled -eq $true -and
                    $_.Description -notmatch 'Hyper-V|VMware|Loopback|Teredo|6to4|ISATAP|Bluetooth|TAP-|Miniport' }
            foreach ($a in @($adapters)) {
                $current = $a.DNSServerSearchOrder
                if ($null -eq $current -or $current -notcontains $result.DCip) {
                    $newDns = @($result.DCip)
                    if ($null -ne $current) { $newDns += $current | Where-Object { $_ -ne $result.DCip } }
                    $a.SetDNSServerSearchOrder($newDns) | Out-Null
                    Write-GUILog "DNS auto-fix: set $($result.DCip) as primary on $($a.Description)"
                    $result.DnsFixed = $true
                }
            }
        } catch { Write-GUILog "DNS auto-fix failed: $($_.Exception.Message)" 'WARN' }
    }

    # Step 4: Time skew check
    & $StatusCallback 'Checking time synchronization...'
    try {
        $w32tmOut = & w32tm.exe /stripchart /computer:$Domain /samples:1 /dataonly 2>&1
        $skewLine = $w32tmOut | Where-Object { $_ -match '[+-]\d+\.\d+s' } | Select-Object -Last 1
        if ($skewLine -match '([+-]\d+)\.\d+s') {
            $skewSec = [Math]::Abs([int]$Matches[1])
            Write-GUILog "Time skew: ${skewSec}s"
            if ($skewSec -gt 300) {
                Write-GUILog "Time skew > 5 min -- syncing w32tm" 'WARN'
                & $StatusCallback 'Syncing time (skew detected)...'
                & w32tm.exe /resync /force 2>&1 | Out-Null
                & net.exe time /domain:$Domain /set /y 2>&1 | Out-Null
                $result.TimeSynced = $true
                Write-GUILog "Time sync attempted"
            } else {
                Write-GUILog "Time skew OK ($skewSec s)"
                $result.TimeSynced = $true
            }
        }
    } catch { Write-GUILog "Time check failed (non-fatal): $($_.Exception.Message)" }

    return $result
}

function Invoke-DomainJoin {
    param([string]$Domain, [System.Management.Automation.PSCredential]$Cred, [scriptblock]$StatusCallback)

    # Join domain -- default Computers container
    & $StatusCallback 'Joining domain...'
    Add-Computer -DomainName $Domain -Credential $Cred -Force -EA Stop
    Write-GUILog "Add-Computer succeeded: $Domain"

    # Set computer description
    & $StatusCallback 'Setting computer description...'
    try {
        $desc = "Joined via Paladin $(Get-Date -Format 'yyyy-MM-dd') | Site: $siteName"
        & net.exe config server /srvcomment:$desc 2>&1 | Out-Null
        try {
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' `
                -Name 'srvcomment' -Value $desc -EA SilentlyContinue
        } catch {}
        Write-GUILog "Computer description set: $desc"
    } catch { Write-GUILog "Description set failed (non-fatal): $($_.Exception.Message)" }

    # gpupdate
    & $StatusCallback 'Applying Group Policy...'
    try {
        & gpupdate.exe /force 2>&1 | Out-Null
        Write-GUILog "gpupdate /force completed"
    } catch { Write-GUILog "gpupdate failed (non-fatal): $($_.Exception.Message)" }
}

function Invoke-RebootCountdown {
    param([string]$Domain, [string]$EndUser)

    Add-Type -AssemblyName System.Windows.Forms

    $form              = New-Object System.Windows.Forms.Form
    $form.Text         = 'Paladin Domain Join -- Reboot Required'
    $form.Size         = New-Object System.Drawing.Size(420, 200)
    $form.StartPosition= 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox  = $false
    $form.MinimizeBox  = $false
    $form.TopMost      = $true
    $form.BackColor    = [System.Drawing.Color]::FromArgb(245,245,245)

    $lbl               = New-Object System.Windows.Forms.Label
    $vpnNote = if (-not [string]::IsNullOrEmpty($EndUser)) {
        "`r`n`r`nIMPORTANT: Keep VPN connected. $EndUser must log in`r`nonce after reboot while VPN is active to cache credentials."
    } else { '' }
    $lbl.Text = "Successfully joined: $Domain`r`n`r`nThis computer must restart to complete domain join.`r`nRebooting in 60 seconds...$vpnNote"
    $lbl.Location      = New-Object System.Drawing.Point(16,16)
    $lbl.Size          = New-Object System.Drawing.Size(380,80)
    $lbl.Font          = New-Object System.Drawing.Font('Segoe UI',10)

    $btnNow            = New-Object System.Windows.Forms.Button
    $btnNow.Text       = 'Reboot Now'
    $btnNow.Location   = New-Object System.Drawing.Point(16,110)
    $btnNow.Size       = New-Object System.Drawing.Size(120,32)
    $btnNow.BackColor  = [System.Drawing.Color]::FromArgb(192,57,43)
    $btnNow.ForeColor  = [System.Drawing.Color]::White
    $btnNow.FlatStyle  = 'Flat'

    $btnDelay          = New-Object System.Windows.Forms.Button
    $btnDelay.Text     = 'Reboot Later'
    $btnDelay.Location = New-Object System.Drawing.Point(148,110)
    $btnDelay.Size     = New-Object System.Drawing.Size(120,32)
    $btnDelay.FlatStyle= 'Flat'

    $form.Controls.AddRange(@($lbl,$btnNow,$btnDelay))

    $script:rebootNow = $true
    $countdown        = 60

    $timer             = New-Object System.Windows.Forms.Timer
    $timer.Interval    = 1000

    $localLbl   = $lbl
    $localForm  = $form
    $localDom   = $Domain
    $vpnNote    = if (-not [string]::IsNullOrEmpty($EndUser)) { "`r`n`r`nIMPORTANT: Keep VPN connected. $EndUser must log in`r`nonce after reboot while VPN is active to cache credentials." } else { "" }

    $timer.Add_Tick({
        $countdown--
        if ($countdown -le 0) {
            $timer.Stop()
            $localForm.Close()
        } else {
            $localLbl.Text = "Successfully joined: $localDom`r`n`r`nThis computer must restart to complete domain join.`r`nRebooting in ${countdown} seconds...$vpnNote"
        }
    })

    $btnNow.Add_Click({ $timer.Stop(); $script:rebootNow = $true; $form.Close() })
    $btnDelay.Add_Click({ $timer.Stop(); $script:rebootNow = $false; $form.Close() })

    $timer.Start()
    $form.ShowDialog() | Out-Null
    $timer.Dispose()

    return $script:rebootNow
}

# =============================================================================
# BUILD WPF CREDENTIAL WINDOW
# =============================================================================

[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Paladin Domain Join"
    Width="500" MinWidth="420" MinHeight="440"
    WindowStartupLocation="CenterScreen"
    ResizeMode="CanResizeWithGrip"
    Background="#F5F5F5"
    FontFamily="Segoe UI" FontSize="13">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="60"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto" MinHeight="46"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#1A3A5C">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0">
        <TextBlock Text="Paladin" Foreground="#5BA3E0" FontSize="18" FontWeight="Bold"/>
        <TextBlock Text=" Domain Join" Foreground="White" FontSize="18" FontWeight="Light"/>
      </StackPanel>
    </Border>

    <StackPanel Grid.Row="1" Margin="24,16">
      <TextBlock Text="Enter domain administrator credentials to join this machine to the domain. All other steps are automated." TextWrapping="Wrap" Margin="0,0,0,6" Foreground="#333"/>
      <TextBlock Text="Credentials are used once in memory only and are never saved." TextWrapping="Wrap" Margin="0,0,0,18" Foreground="#555" FontSize="11" FontStyle="Italic"/>

      <TextBlock Text="Domain Name:" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <TextBox x:Name="TxtDomain" Padding="6,4" Margin="0,0,0,12" FontSize="13"/>

      <TextBlock Text="Domain Admin Username:" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <TextBox x:Name="TxtUser" Padding="6,4" Margin="0,0,0,12" FontSize="13"/>

      <TextBlock Text="Password:" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <PasswordBox x:Name="TxtPass" Padding="6,4" Margin="0,0,0,12" FontSize="13"/>

      <TextBlock Text="End User Domain Username (optional):" FontWeight="SemiBold" Margin="0,0,0,4"/>
      <TextBox x:Name="TxtEndUser" Padding="6,4" Margin="0,0,0,4" FontSize="13"/>
      <TextBlock Text="If provided, this user will be pre-staged in the credential cache so they can log in immediately after reboot." TextWrapping="Wrap" Foreground="#666" FontSize="10" FontStyle="Italic" Margin="0,0,0,12"/>

      <Border x:Name="StatusBorder" Background="#EBF5FB" BorderBrush="#AED6F1" BorderThickness="1" Padding="10,8" Visibility="Collapsed" CornerRadius="3">
        <TextBlock x:Name="TxtStatus" Foreground="#1A5276" TextWrapping="Wrap" FontSize="11"/>
      </Border>
    </StackPanel>

    <Border Grid.Row="2" Background="#E8EEF4" Padding="16,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="TxtProgress" Grid.Column="0" VerticalAlignment="Center" Foreground="#555" FontSize="11"/>
        <Button x:Name="BtnJoin" Grid.Column="1" Content="Join Domain"
                Background="#1A7A3C" Foreground="White" Padding="14,6"
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

$TxtDomain    = $window.FindName('TxtDomain')
$TxtUser      = $window.FindName('TxtUser')
$TxtPass      = $window.FindName('TxtPass')
$TxtEndUser   = $window.FindName('TxtEndUser')
$TxtStatus    = $window.FindName('TxtStatus')
$TxtProgress  = $window.FindName('TxtProgress')
$StatusBorder = $window.FindName('StatusBorder')
$BtnJoin      = $window.FindName('BtnJoin')
$BtnCancel    = $window.FindName('BtnCancel')

function Set-Status {
    param([string]$Message, [string]$Color = '#1A5276')
    $TxtStatus.Text       = $Message
    $TxtStatus.Foreground = $Color
    $StatusBorder.Visibility = 'Visible'
    $window.Dispatcher.Invoke([action]{}, 'Background')
}

function Set-Progress { param([string]$Message) $TxtProgress.Text = $Message; $window.Dispatcher.Invoke([action]{}, 'Background') }

$BtnCancel.Add_Click({ $window.Close() })

$BtnJoin.Add_Click({
    $domain   = $TxtDomain.Text.Trim()
    $username = $TxtUser.Text.Trim()
    $password = $TxtPass.SecurePassword
    $endUser  = $TxtEndUser.Text.Trim()

    if ([string]::IsNullOrEmpty($domain))   { Set-Status 'Domain name is required.' '#C0392B'; return }
    if ([string]::IsNullOrEmpty($username)) { Set-Status 'Username is required.'    '#C0392B'; return }
    if ($password.Length -eq 0)             { Set-Status 'Password is required.'    '#C0392B'; return }

    $BtnJoin.IsEnabled   = $false
    $BtnCancel.IsEnabled = $false
    $StatusBorder.Visibility = 'Collapsed'

    $localDomain   = $domain
    $localUsername = $username
    $localEndUser  = $endUser
    $localPassword = $password
    $localSite     = $siteName

    # Status callback for automation steps to update progress label
    $statusCb = { param($msg) Set-Progress $msg }

    try {
        # Pre-join checks
        Set-Progress 'Running pre-join checks...'
        $checks = Invoke-PreJoinChecks -Domain $localDomain -StatusCallback $statusCb

        if (-not $checks.DnsOk) {
            Set-Status "Cannot resolve domain '$localDomain'. Verify the domain name and network connectivity." '#C0392B'
            Set-Progress ''
            $BtnJoin.IsEnabled   = $true
            $BtnCancel.IsEnabled = $true
            return
        }

        if (-not $checks.LdapOk) {
            Set-Status "Domain controller not reachable on port 389. Check firewall and network connectivity." '#C0392B'
            Set-Progress ''
            $BtnJoin.IsEnabled   = $true
            $BtnCancel.IsEnabled = $true
            return
        }

        # Build credential -- in memory only
        $fullUser = if ($localUsername -match '\\|@') { $localUsername } else { "$localDomain\$localUsername" }
        $cred     = New-Object System.Management.Automation.PSCredential($fullUser, $localPassword)

        # Join domain
        Invoke-DomainJoin -Domain $localDomain -Cred $cred -StatusCallback $statusCb

        # Pre-stage end user credential cache if provided
        if (-not [string]::IsNullOrEmpty($localEndUser)) {
            Set-Progress 'Pre-staging user credential cache...'
            try {
                $fullEndUser = if ($localEndUser -match '\\|@') { $localEndUser } else { "$localDomain\$localEndUser" }
                # net use against NETLOGON share forces Kerberos ticket issuance and
                # populates the local credential cache for this user account.
                # /user: uses domain admin cred we already have -- end user password not needed.
                $netUsePw  = $cred.GetNetworkCredential().Password
                $netUseOut = & net.exe use "\\$localDomain\NETLOGON" "/user:$($cred.UserName)" $netUsePw 2>&1
                $netUsePw  = $null
                Write-GUILog "net use NETLOGON (cache prime): $($netUseOut -join ' ')"
                # Disconnect immediately -- we only needed the auth round-trip
                & net.exe use "\\$localDomain\NETLOGON" /delete /yes 2>&1 | Out-Null

                # Write cached logon hint to registry so user knows to log in while VPN is active
                try {
                    if (-not (Test-Path $RegBase)) { New-Item -Path $RegBase -Force | Out-Null }
                    New-ItemProperty -Path $RegBase -Name 'CachedUser' `
                        -Value $fullEndUser -PropertyType String -Force | Out-Null
                } catch {}
                Write-GUILog "User cache primed for: $fullEndUser"
            } catch {
                Write-GUILog "WARN: User cache prime failed (non-fatal): $($_.Exception.Message)" 'WARN'
            }
        }

        # Zero credential immediately
        $cred          = $null
        $localPassword.Dispose()

        # Write result to registry + UDF
        try {
            if (-not (Test-Path $RegBase)) { New-Item -Path $RegBase -Force | Out-Null }
            New-ItemProperty -Path $RegBase -Name 'JoinResult' `
                -Value "PASS $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Domain: $localDomain" `
                -PropertyType String -Force | Out-Null
        } catch {}

        try {
            $cacheNote = if (-not [string]::IsNullOrEmpty($localEndUser)) { " | Cache:$localEndUser" } else { '' }
            New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' `
                -Name "Custom$UDF_SLOT" -PropertyType String `
                -Value "JOINED $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Domain: $localDomain | Site: $localSite$cacheNote" `
                -Force -EA SilentlyContinue | Out-Null
        } catch {}

        Set-Status "Successfully joined '$localDomain'. Preparing reboot..." '#1A7A3C'
        Set-Progress 'Done'
        $window.Close()

        # Reboot countdown
        $rebootNow = Invoke-RebootCountdown -Domain $localDomain -EndUser $localEndUser
        if ($rebootNow) {
            & shutdown.exe /r /t 10 /c "Paladin IT: Restarting to complete domain join. Please save your work." /f
        }

    } catch {
        $cred = $null
        try { $localPassword.Dispose() } catch {}

        $errMsg = $_.Exception.Message
        Set-Status "Join failed: $errMsg" '#C0392B'
        Set-Progress ''
        Write-GUILog "Join failed: $errMsg" 'WARN'

        try {
            New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' `
                -Name "Custom$UDF_SLOT" -PropertyType String `
                -Value "JOIN-FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $errMsg" `
                -Force -EA SilentlyContinue | Out-Null
        } catch {}

        $BtnJoin.IsEnabled   = $true
        $BtnCancel.IsEnabled = $true
    }
})

$window.ShowDialog() | Out-Null
exit 0
