#Requires -Version 3.0
# =============================================================================
# Paladin Network Stack Reset [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
#
# PHASES (state machine -- resumes automatically after reboot):
#   Phase 1: Snapshot all adapter settings to log (pre-reset safety record)
#            Flush DNS, release DHCP on all adapters, clear ARP cache
#            Run netsh winsock reset, int ip reset, int ipv6 reset
#            Reboot (with user warning + allowReboot gate)
#   Phase 2: Renew DHCP on all adapters, re-register DNS
#            Write final status to UDF, self-delete resume task
#
# LOG:    C:\ProgramData\Paladin\NetworkReset\NetworkReset.log
# SNAP:   C:\ProgramData\Paladin\NetworkReset\PreReset-Snapshot-<ts>.log
# STATE:  HKLM:\SOFTWARE\Paladin\NetworkReset
# TASK:   Paladin_NetworkReset_Resume (auto-created, auto-deleted)
#
# INPUT VARIABLES:
#   allowReboot (Boolean) -- true = reboot automatically after reset
#                            false = reset runs, manual reboot required
#
# UDF: slot configurable via UDF_SLOT constant below (default: 8)
# EXIT CODES: 0=Success or rebooting, 1=Fatal error
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer   = '1.0.0'
$StateKey    = 'HKLM:\SOFTWARE\Paladin\NetworkReset'
$LogDir      = 'C:\ProgramData\Paladin\NetworkReset'
$LogFile     = "$LogDir\NetworkReset.log"
$ScriptDest  = "$LogDir\NetworkReset-Resume.ps1"
$TaskName    = 'Paladin_NetworkReset_Resume'
$UDF_SLOT    = 8
$MaxLogMB    = 5

# Input variable
$AllowReboot = ($env:allowReboot -eq 'true')

# =============================================================================
# HELPERS
# =============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try {
        if (-not (Test-Path $LogDir)) {
            New-Item -Path $LogDir -ItemType Directory -Force -EA Stop | Out-Null
            # ACL: lock to SYSTEM + Administrators only
            $acl = Get-Acl -Path $LogDir
            $acl.SetAccessRuleProtection($true, $false)
            $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
            $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
            $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
            $allow  = [System.Security.AccessControl.AccessControlType]::Allow
            $inh    = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
            $prop   = [System.Security.AccessControl.PropagationFlags]::None
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system,$rights,$inh,$prop,$allow)))
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins,$rights,$inh,$prop,$allow)))
            Set-Acl -Path $LogDir -AclObject $acl -EA SilentlyContinue
        }
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile -EA SilentlyContinue).Length / 1MB) -gt $MaxLogMB) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.bak" -Force -EA SilentlyContinue
        }
        Add-Content -Path $LogFile -Value $line -EA SilentlyContinue
    } catch {}
}

function Write-Sep {
    Write-Log '================================================================'
}

function Set-DattoUDF {
    param([int]$Slot, [string]$Value)
    $trimmed = if ($Value.Length -gt 255) { $Value.Substring(0,255) } else { $Value }
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' `
            -Name "Custom$Slot" -PropertyType String -Value $trimmed `
            -Force -EA Stop | Out-Null
        Write-Log "UDF$Slot updated: $trimmed"
    } catch {
        Write-Log "WARN: UDF$Slot write failed: $($_.Exception.Message)"
    }
}

function Show-UserMessage {
    param([string]$Message)
    try {
        $sessions = & query session 2>&1 | Where-Object { $_ -match 'Active' }
        if ($sessions) {
            & msg.exe '*' /TIME:300 "Paladin IT: $Message" 2>&1 | Out-Null
            Write-Log "User notified: $Message"
        } else {
            Write-Log "No active user session -- skipping popup"
        }
    } catch {
        Write-Log "WARN: Could not send user message: $($_.Exception.Message)"
    }
}

function Get-State {
    try {
        $s = Get-ItemProperty -Path $StateKey -EA SilentlyContinue
        if ($null -eq $s) { return 1 }
        return [int]$s.Phase
    } catch { return 1 }
}

function Set-State {
    param([int]$Phase, [string]$Note = '')
    try {
        if (-not (Test-Path $StateKey)) {
            New-Item -Path $StateKey -Force -EA SilentlyContinue | Out-Null
        }
        New-ItemProperty -Path $StateKey -Name 'Phase'     -Value $Phase -PropertyType DWord  -Force -EA SilentlyContinue | Out-Null
        New-ItemProperty -Path $StateKey -Name 'UpdatedAt' -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -PropertyType String -Force -EA SilentlyContinue | Out-Null
        if ($Note) {
            New-ItemProperty -Path $StateKey -Name 'Note' -Value $Note -PropertyType String -Force -EA SilentlyContinue | Out-Null
        }
    } catch {}
}

function Clear-State {
    try { Remove-Item -Path $StateKey -Recurse -Force -EA SilentlyContinue } catch {}
}

function Register-ResumeTask {
    try {
        if (-not (Test-Path $LogDir)) {
            New-Item -Path $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null
        }
        Copy-Item -LiteralPath $PSCommandPath -Destination $ScriptDest -Force -EA Stop
        Write-Log "Script copied to: $ScriptDest"
        & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
        $cmd = "PowerShell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptDest`""
        & schtasks.exe /Create /TN $TaskName /TR $cmd /SC ONSTART /RU SYSTEM /RL HIGHEST /DELAY 0001:00 /F 2>&1 | Out-Null
        Write-Log "Resume task registered: '$TaskName' -- fires 1 min after next startup"
    } catch {
        Write-Log "ERROR: Could not register resume task: $($_.Exception.Message)"
    }
}

function Remove-ResumeTask {
    try {
        & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
        Remove-Item -LiteralPath $ScriptDest -Force -EA SilentlyContinue
        Write-Log 'Resume task and script copy removed'
    } catch {}
}

function Get-PhysicalAdapters {
    # Returns all physical (non-virtual, non-loopback, non-tunnel) adapters via WMI
    # Works PS 3.0 -- no Get-NetAdapter
    $adapters = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
        Where-Object {
            $_.IPEnabled -eq $true -and
            $_.Description -notmatch 'Hyper-V|VMware|VirtualBox|Loopback|Teredo|6to4|ISATAP|Pseudo|WAN Miniport|Bluetooth|TAP-|Miniport'
        }
    return $adapters
}

function Get-AllAdapters {
    # Returns ALL IPEnabled adapters including DHCP-disabled for renew attempt
    $adapters = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
        Where-Object {
            $_.Description -notmatch 'Hyper-V|VMware|VirtualBox|Loopback|Teredo|6to4|ISATAP|Pseudo|WAN Miniport|Bluetooth|TAP-|Miniport'
        }
    return $adapters
}

# =============================================================================
# PHASE 1 FUNCTIONS
# =============================================================================

function Write-AdapterSnapshot {
    $ts          = Get-Date -Format 'yyyyMMdd-HHmmss'
    $snapFile    = "$LogDir\PreReset-Snapshot-$ts.log"
    $staticFound = @()

    Write-Log "Writing pre-reset adapter snapshot to: $snapFile"

    $lines = @()
    $lines += '================================================================'
    $lines += "Paladin Network Stack Reset -- Pre-Reset Adapter Snapshot"
    $lines += "Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "Machine   : $env:COMPUTERNAME"
    $lines += "Site      : $($env:CS_PROFILE_NAME)"
    $lines += '================================================================'
    $lines += ''

    $adapters = Get-AllAdapters
    if ($null -eq $adapters -or @($adapters).Count -eq 0) {
        $lines += 'WARNING: No network adapters detected.'
        Write-Log 'WARN: No adapters found for snapshot'
    } else {
        foreach ($a in @($adapters)) {
            $dhcpLabel = if ($a.DHCPEnabled) { 'DHCP (automatic)' } else { '[STATIC - MANUAL REVERT REQUIRED]' }
            $ipList    = if ($a.IPAddress)   { $a.IPAddress   -join ', ' } else { '(none)' }
            $snList    = if ($a.IPSubnet)    { $a.IPSubnet    -join ', ' } else { '(none)' }
            $gwList    = if ($a.DefaultIPGateway) { $a.DefaultIPGateway -join ', ' } else { '(none)' }
            $dnsList   = if ($a.DNSServerSearchOrder) { $a.DNSServerSearchOrder -join ', ' } else { '(none)' }

            $lines += "Adapter   : $($a.Description)"
            $lines += "Index     : $($a.Index)"
            $lines += "MAC       : $($a.MACAddress)"
            $lines += "IP Config : $dhcpLabel"
            $lines += "IP(s)     : $ipList"
            $lines += "Subnet(s) : $snList"
            $lines += "Gateway   : $gwList"
            $lines += "DNS       : $dnsList"
            $lines += "DNS Suffix: $($a.DNSDomainSuffixSearchOrder -join ', ')"
            $lines += "WINS Prim : $($a.WINSPrimaryServer)"
            $lines += "WINS Sec  : $($a.WINSSecondaryServer)"
            $lines += ''

            if (-not $a.DHCPEnabled) {
                $staticFound += $a.Description
                Write-Log "WARNING: Static IP detected on adapter: $($a.Description) | IP: $ipList | GW: $gwList" -Level 'WARN'
            } else {
                Write-Log "Adapter snapshot: $($a.Description) | DHCP | IP: $ipList"
            }
        }
    }

    $lines += '================================================================'
    $lines += 'END OF SNAPSHOT'
    $lines += '================================================================'

    [System.IO.File]::WriteAllLines($snapFile, $lines, [System.Text.Encoding]::ASCII)
    Write-Log "Snapshot written: $snapFile"

    if ($staticFound.Count -gt 0) {
        Write-Log '================================================================' -Level 'WARN'
        Write-Log 'STATIC IP ADAPTERS DETECTED -- MANUAL REVERT MAY BE REQUIRED:' -Level 'WARN'
        foreach ($s in $staticFound) {
            Write-Log "  >> $s" -Level 'WARN'
        }
        Write-Log "Snapshot saved at: $snapFile" -Level 'WARN'
        Write-Log 'Review snapshot BEFORE completing this job if static IPs must be preserved.' -Level 'WARN'
        Write-Log '================================================================' -Level 'WARN'
    }

    return $staticFound
}

function Invoke-PreRebootReset {
    Write-Sep
    Write-Log 'PHASE 1a: Flushing DNS cache'
    try {
        & ipconfig.exe /flushdns 2>&1 | ForEach-Object { Write-Log "  $_" }
    } catch { Write-Log "WARN: DNS flush error: $($_.Exception.Message)" }

    Write-Sep
    Write-Log 'PHASE 1b: Clearing ARP cache'
    try {
        & netsh.exe interface ip delete arpcache 2>&1 | ForEach-Object { Write-Log "  $_" }
    } catch { Write-Log "WARN: ARP clear error: $($_.Exception.Message)" }

    Write-Sep
    Write-Log 'PHASE 1c: Releasing DHCP leases on all adapters'
    $adapters = Get-PhysicalAdapters
    if ($null -ne $adapters) {
        foreach ($a in @($adapters)) {
            if ($a.DHCPEnabled) {
                try {
                    $result = $a.ReleaseDHCPLease()
                    Write-Log "  Released: $($a.Description) (return: $($result.ReturnValue))"
                } catch {
                    Write-Log "  WARN: Release failed on $($a.Description): $($_.Exception.Message)"
                }
            } else {
                Write-Log "  Skipped (static): $($a.Description)"
            }
        }
    } else {
        Write-Log '  WARN: No DHCP adapters found to release'
    }

    Write-Sep
    Write-Log 'PHASE 1d: Resetting Winsock catalog'
    try {
        $out = & netsh.exe winsock reset 2>&1
        $out | ForEach-Object { Write-Log "  $_" }
    } catch { Write-Log "ERROR: Winsock reset failed: $($_.Exception.Message)" }

    Write-Sep
    Write-Log 'PHASE 1e: Resetting IPv4 TCP/IP stack'
    $ipResetLog = "$LogDir\netsh-ip-reset.log"
    try {
        $out = & netsh.exe int ip reset $ipResetLog 2>&1
        $out | ForEach-Object { Write-Log "  $_" }
    } catch { Write-Log "ERROR: IPv4 stack reset failed: $($_.Exception.Message)" }

    Write-Sep
    Write-Log 'PHASE 1f: Resetting IPv6 TCP/IP stack'
    try {
        $out = & netsh.exe int ipv6 reset 2>&1
        $out | ForEach-Object { Write-Log "  $_" }
    } catch { Write-Log "ERROR: IPv6 stack reset failed: $($_.Exception.Message)" }

    Write-Sep
    Write-Log 'PHASE 1g: Resetting IPv4 interface settings'
    try {
        $out = & netsh.exe int ip reset all 2>&1
        $out | ForEach-Object { Write-Log "  $_" }
    } catch { Write-Log "WARN: int ip reset all failed: $($_.Exception.Message)" }

    Write-Sep
    Write-Log 'PHASE 1h: Resetting firewall to default'
    try {
        $out = & netsh.exe advfirewall reset 2>&1
        $out | ForEach-Object { Write-Log "  $_" }
    } catch { Write-Log "WARN: Firewall reset failed (non-fatal): $($_.Exception.Message)" }
}

# =============================================================================
# PHASE 2 FUNCTIONS
# =============================================================================

function Invoke-PostRebootRenew {
    Write-Sep
    Write-Log 'PHASE 2a: Renewing DHCP leases on all adapters'
    $adapters = Get-PhysicalAdapters
    $renewed  = 0
    $failed   = 0

    if ($null -ne $adapters) {
        foreach ($a in @($adapters)) {
            if ($a.DHCPEnabled) {
                try {
                    # Give adapter time to initialize after reboot
                    Start-Sleep -Seconds 3
                    $result = $a.RenewDHCPLease()
                    if ($result.ReturnValue -eq 0) {
                        $renewed++
                        Write-Log "  Renewed: $($a.Description)"
                    } else {
                        $failed++
                        Write-Log "  WARN: Renew returned $($result.ReturnValue) on $($a.Description)"
                    }
                } catch {
                    $failed++
                    Write-Log "  WARN: Renew failed on $($a.Description): $($_.Exception.Message)"
                }
            } else {
                Write-Log "  Skipped (static): $($a.Description)"
            }
        }
    } else {
        Write-Log '  WARN: No adapters found for DHCP renew'
        $failed++
    }

    Write-Log "  DHCP renew summary: $renewed renewed, $failed failed/skipped"

    Write-Sep
    Write-Log 'PHASE 2b: Re-registering DNS'
    try {
        $out = & ipconfig.exe /registerdns 2>&1
        $out | ForEach-Object { Write-Log "  $_" }
    } catch { Write-Log "WARN: DNS registration failed: $($_.Exception.Message)" }

    Write-Sep
    Write-Log 'PHASE 2c: Flushing DNS cache post-renew'
    try {
        & ipconfig.exe /flushdns 2>&1 | ForEach-Object { Write-Log "  $_" }
    } catch {}

    Write-Sep
    Write-Log 'PHASE 2d: Reading final adapter state'
    $finalAdapters = Get-PhysicalAdapters
    if ($null -ne $finalAdapters) {
        foreach ($a in @($finalAdapters)) {
            $ipList = if ($a.IPAddress) { $a.IPAddress -join ', ' } else { '(no IP yet)' }
            $gw     = if ($a.DefaultIPGateway) { $a.DefaultIPGateway -join ', ' } else { '(none)' }
            Write-Log "  $($a.Description) | IP: $ipList | GW: $gw | DHCP: $($a.DHCPEnabled)"
        }
    }

    return $failed
}

# =============================================================================
# STARTUP
# =============================================================================

if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null
}

$siteName = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }

$currentPhase = Get-State

Write-Sep
Write-Log "Paladin Network Stack Reset v$ScriptVer | Site: $siteName"
Write-Log "Phase: $currentPhase | AllowReboot: $AllowReboot | Log: $LogFile"
Write-Sep

# =============================================================================
# PHASE 1 -- SNAPSHOT + RESET + REBOOT
# =============================================================================

if ($currentPhase -eq 1) {

    Write-Sep
    Write-Log 'PHASE 1: Pre-reset adapter snapshot'
    $staticAdapters = Write-AdapterSnapshot

    if ($staticAdapters.Count -gt 0) {
        Write-Host ''
        Write-Host '================================================================'
        Write-Host 'WARNING: STATIC IP ADAPTERS DETECTED'
        Write-Host 'The following adapters have manually configured IP addresses.'
        Write-Host 'After the network stack reset, these settings will be LOST.'
        Write-Host 'They are documented in the pre-reset snapshot log.'
        Write-Host ''
        foreach ($s in $staticAdapters) {
            Write-Host "  >> $s"
        }
        Write-Host ''
        Write-Host "Snapshot location: $LogDir\PreReset-Snapshot-*.log"
        Write-Host '================================================================'
        Write-Host ''
    }

    Write-Sep
    Write-Log 'PHASE 1: Running pre-reboot network resets'
    Invoke-PreRebootReset

    Set-State -Phase 2 -Note 'Stack reset complete. Awaiting reboot.'
    Register-ResumeTask

    if ($AllowReboot) {
        Show-UserMessage -Message 'Your PC will restart in 2 minutes for network maintenance. Please save all open work now.'
        Write-Log 'Waiting 90 seconds before reboot...'
        Start-Sleep -Seconds 90
        Show-UserMessage -Message 'Your PC will restart in 30 seconds for network maintenance.'
        Write-Log 'Final 30s warning sent. Rebooting now...'
        Start-Sleep -Seconds 30
        Write-Log 'Initiating reboot. Phase 2 (DHCP renew + DNS re-register) will run automatically after restart.'
        Set-DattoUDF -Slot $UDF_SLOT -Value "REBOOTING $(Get-Date -Format 'yyyy-MM-dd HH:mm') - Phase 2 pending"
        Write-Sep
        & shutdown.exe /r /t 0 /c "Paladin IT: Network maintenance. Do not power off." /f 2>&1 | Out-Null
        exit 0
    } else {
        Write-Log 'AllowReboot=false -- stack reset complete. MANUAL REBOOT REQUIRED to complete Phase 2 (DHCP renew + DNS re-register).'
        Write-Log "After reboot, resume task '$TaskName' will complete Phase 2 automatically."
        Set-DattoUDF -Slot $UDF_SLOT -Value "REBOOT REQUIRED $(Get-Date -Format 'yyyy-MM-dd HH:mm') - stack reset done, renew pending"
        Write-Host ''
        Write-Host '================================================================'
        Write-Host 'REBOOT REQUIRED'
        Write-Host 'Network stack reset is complete. A reboot is required to'
        Write-Host 'activate the new stack and renew DHCP leases.'
        Write-Host 'Phase 2 (DHCP renew + DNS re-register) will run automatically'
        Write-Host "after the next reboot via scheduled task '$TaskName'."
        Write-Host '================================================================'
        exit 0
    }
}

# =============================================================================
# PHASE 2 -- POST-REBOOT: DHCP RENEW + DNS RE-REGISTER
# =============================================================================

if ($currentPhase -eq 2) {

    Write-Sep
    Write-Log 'PHASE 2: Post-reboot DHCP renew + DNS re-register'

    $failCount = Invoke-PostRebootRenew

    # Final report
    Write-Sep
    if ($failCount -eq 0) {
        $udfMsg = "PASS $(Get-Date -Format 'yyyy-MM-dd HH:mm') - Stack reset + DHCP renew OK"
        Write-Log 'Network stack reset COMPLETE. All adapters renewed successfully.'
        Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg
    } else {
        $udfMsg = "WARN $(Get-Date -Format 'yyyy-MM-dd HH:mm') - Stack reset OK, $failCount adapter(s) failed renew"
        Write-Log "Network stack reset COMPLETE with warnings. $failCount adapter(s) failed DHCP renew -- check log."
        Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg
    }

    Show-UserMessage -Message 'Network maintenance is complete. Your connection has been restored. If you experience any issues please contact IT support.'

    # Cleanup
    Clear-State
    Remove-ResumeTask

    Write-Sep
    Write-Log "Full log: $LogFile"
    Write-Log "Pre-reset snapshot: $LogDir\PreReset-Snapshot-*.log"
    Write-Sep

    if ($failCount -eq 0) { exit 0 } else { exit 0 }
}

# Unexpected phase -- clear and exit
Write-Log "ERROR: Unexpected phase value '$currentPhase'. Clearing state."
Clear-State
exit 1
