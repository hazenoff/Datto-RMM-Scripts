#Requires -Version 3.0
# =============================================================================
# Paladin Firewall Hardener [WIN]
# Datto RMM Component | Script | PowerShell 3.0 | SYSTEM context
# Version: 1.0.2
#
# Downloads and applies IP blocklists as Windows Firewall rules.
# Installs a scheduled task for automatic refresh on a configurable schedule.
# Set it and forget it -- runs as SYSTEM, no user interaction required.
#
# INPUT VARIABLES (Datto):
#   Lists     String   Comma-separated list names, or ALL (default: ALL)
#                      Valid names: see CATALOG below
#   Schedule  String   Daily | Weekly | Monthly | None (default: Daily)
#   Remove    Boolean  true = remove all rules + task and exit (default: false)
#   UDFSlot   String   UDF slot for status summary (default: 30)
#
# REGISTRY:
#   HKLM:\SOFTWARE\Paladin\FirewallHardener
#   -> ActiveLists   (comma-separated names applied)
#   -> LastRun       (datetime)
#   -> LastRunResult (PASS/FAIL + counts)
#   -> Schedule      (current schedule)
#
# SCHEDULED TASK:
#   Name: Paladin_FirewallHardener
#   Calls BAT wrapper -> this script with same inputs
#   Runs as SYSTEM / HighestAvailable
#
# EXIT CODES:
#   0 = success
#   1 = fatal error (no lists matched, firewall blocked, etc.)
# =============================================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer   = '1.0.2'
$BaseDir     = 'C:\ProgramData\Paladin\FirewallHardener'
$LogFile     = "$BaseDir\FirewallHardener.log"
$RegPath     = 'HKLM:\SOFTWARE\Paladin\FirewallHardener'
$TaskName    = 'Paladin_FirewallHardener'
$BatPath     = "$BaseDir\FirewallHardener.bat"
$SelfDest    = "$BaseDir\FirewallHardener.ps1"
$PsExe       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$SiteName    = if ($env:CS_PROFILE_NAME) { $env:CS_PROFILE_NAME } else { 'UNKNOWN' }
$MachineName = $env:COMPUTERNAME
$UDFSlot     = if ($env:UDFSlot -match '^\d+$') { [int]$env:UDFSlot } else { 30 }

# Input variables
$InputLists    = if ($env:Lists)    { $env:Lists.Trim() }    else { 'ALL' }
$InputSchedule = if ($env:Schedule) { $env:Schedule.Trim() } else { 'Daily' }
$InputRemove   = ($env:Remove -eq 'true')

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
    $trimmed = if ($Value.Length -gt 255) { $Value.Substring(0,255) } else { $Value }
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' `
            -Name "Custom$Slot" -PropertyType String -Value $trimmed `
            -Force -EA Stop | Out-Null
    } catch {}
}

function Set-Reg {
    param([string]$Name, [string]$Value)
    try {
        if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force -EA Stop | Out-Null }
        New-ItemProperty -Path $RegPath -Name $Name -PropertyType String -Value $Value -Force -EA Stop | Out-Null
    } catch {}
}

# =============================================================================
# IP LIST CATALOG (mirrors NetWatch HardenCatalog)
# =============================================================================

$Catalog = @(
    @{ Name='Tor Exit Nodes';               URL='https://opendbl.net/lists/tor-exit.list';                                                          Format='plain'    },
    @{ Name='Free Proxies (Firehol)';       URL='https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_anonymous.netset';       Format='netset'   },
    @{ Name='Firehol Level 1';              URL='https://raw.githubusercontent.com/ktsaou/blocklist-ipsets/master/firehol_level1.netset';           Format='netset'   },
    @{ Name='Spamhaus DROP';                URL='https://www.spamhaus.org/drop/drop.txt';                                                           Format='plain'    },
    @{ Name='Firehol Level 2';              URL='https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level2.netset';          Format='netset'   },
    @{ Name='Emerging Threats';             URL='https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt';                                 Format='plain'    },
    @{ Name='DShield Top Attackers';        URL='https://feeds.dshield.org/block.txt';                                                              Format='dshield'  },
    @{ Name='VoIP Blacklist (voipbl.org)';  URL='https://www.voipbl.org/update/';                                                                   Format='plain'    },
    @{ Name='GreenSnow Brute Force';        URL='https://blocklist.greensnow.co/greensnow.txt';                                                     Format='plain'    },
    @{ Name='Blocklist.de SSH Attackers';   URL='https://lists.blocklist.de/lists/ssh.txt';                                                         Format='plain'    },
    @{ Name='Blocklist.de RDP Attackers';   URL='https://lists.blocklist.de/lists/rdp.txt';                                                         Format='plain'    },
    @{ Name='Feodo Tracker C2 (abuse.ch)';  URL='https://feodotracker.abuse.ch/downloads/ipblocklist.txt';                                          Format='plain'    },
    @{ Name='ThreatFox C2 IPs (abuse.ch)';  URL='https://threatfox.abuse.ch/downloads/hostfile/';                                                   Format='hosts-ip' },
    @{ Name='Blocklist.de Port Scanners';   URL='https://lists.blocklist.de/lists/portscan.txt';                                                    Format='plain'    }
)

# =============================================================================
# PARSE-IPLIST (extracted from NetWatch -- no WPF dependency)
# =============================================================================

function Parse-IPList {
    param([string]$Text, [string]$Format)
    $ips   = New-Object System.Collections.Generic.List[string]
    $lines = $Text -replace "`r`n","`n" -replace "`r","`n" -split "`n"
    foreach ($line in $lines) {
        $line = $line.Trim()
        if ([string]::IsNullOrEmpty($line)) { continue }
        if ($line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($Format -eq 'dshield') {
            $cols = $line -split "`t"
            if ($cols.Count -ge 1 -and $cols[0] -match '^(\d+\.\d+\.\d+)\.\d+') {
                $ips.Add("$($Matches[1]).0/24") | Out-Null
            }
        } elseif ($Format -eq 'hosts-ip') {
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
    return $ips
}

# =============================================================================
# APPLY ONE LIST
# =============================================================================

function Apply-List {
    param([string]$Name, [string]$URL, [string]$Format)
    $safe        = $Name -replace '[^a-zA-Z0-9]','_'
    $ruleIn      = "Paladin_Harden_${safe}_in"
    $ruleOut     = "Paladin_Harden_${safe}_out"
    $chunkSize   = 800

    Write-Log "[$Name] Downloading: $URL"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
        $wc   = New-Object System.Net.WebClient
        $text = $wc.DownloadString($URL)
        $ipsRaw = @(Parse-IPList -Text $text -Format $Format)
        $ips    = New-Object System.Collections.Generic.List[string]
        foreach ($ip in $ipsRaw) { $ips.Add([string]$ip) | Out-Null }
        Write-Log "[$Name] Parsed: $($ips.Count) IPs"
        if ($ips.Count -eq 0) { Write-Log "[$Name] WARN: No IPs parsed -- skipping" 'WARN'; return 0 }

        # Remove old rules for this list
        for ($i = -1; $i -le 30; $i++) {
            $rIn  = if ($i -lt 0) { $ruleIn  } else { "${ruleIn}_$i"  }
            $rOut = if ($i -lt 0) { $ruleOut } else { "${ruleOut}_$i" }
            & netsh.exe advfirewall firewall delete rule name="$rIn"  2>&1 | Out-Null
            & netsh.exe advfirewall firewall delete rule name="$rOut" 2>&1 | Out-Null
        }

        # Apply in chunks of 800 CIDRs per rule
        $chunks  = [Math]::Ceiling($ips.Count / $chunkSize)
        $applied = 0
        for ($i = 0; $i -lt $chunks; $i++) {
            $start  = $i * $chunkSize
            $end    = [Math]::Min($chunkSize, $ips.Count - $start)
            $slice  = $ips.GetRange($start, $end)
            $remote = $slice -join ','
            $rIn    = if ($chunks -eq 1) { $ruleIn  } else { "${ruleIn}_$i"  }
            $rOut   = if ($chunks -eq 1) { $ruleOut } else { "${ruleOut}_$i" }

            $outIn  = & netsh.exe advfirewall firewall add rule name="$rIn" `
                dir=in action=block remoteip=$remote protocol=any enable=yes 2>&1
            if ($LASTEXITCODE -eq 0) { $applied++ } else { Write-Log "[$Name] chunk $i IN failed: $($outIn -join ' ')" 'WARN' }

            $outOut = & netsh.exe advfirewall firewall add rule name="$rOut" `
                dir=out action=block remoteip=$remote protocol=any enable=yes 2>&1
            if ($LASTEXITCODE -eq 0) { $applied++ } else { Write-Log "[$Name] chunk $i OUT failed: $($outOut -join ' ')" 'WARN' }
        }

        $total = $chunks * 2
        Write-Log "[$Name] Applied: $applied/$total rules OK ($($ips.Count) IPs)"
        return $ips.Count
    } catch {
        Write-Log "[$Name] ERROR: $($_.Exception.Message)" 'ERROR'
        return -1
    }
}

# =============================================================================
# REMOVE ALL PALADIN_HARDEN_* RULES
# =============================================================================

function Remove-AllHardenRules {
    Write-Log 'Removing all Paladin_Harden_* firewall rules...'
    $removed = 0
    foreach ($item in $Catalog) {
        $safe = $item.Name -replace '[^a-zA-Z0-9]','_'
        for ($i = -1; $i -le 30; $i++) {
            $rIn  = if ($i -lt 0) { "Paladin_Harden_${safe}_in"    } else { "Paladin_Harden_${safe}_in_$i"  }
            $rOut = if ($i -lt 0) { "Paladin_Harden_${safe}_out"   } else { "Paladin_Harden_${safe}_out_$i" }
            $res  = & netsh.exe advfirewall firewall delete rule name="$rIn"  2>&1
            if ($res -notmatch 'No rules match') { $removed++ }
            $res  = & netsh.exe advfirewall firewall delete rule name="$rOut" 2>&1
            if ($res -notmatch 'No rules match') { $removed++ }
        }
    }
    Write-Log "Removed $removed rule(s)"
    return $removed
}

# =============================================================================
# SCHEDULED TASK MANAGEMENT
# KI-103: scheduled tasks call BAT wrappers, never PS1 directly
# =============================================================================

function Install-ScheduledTask {
    param([string]$ListsArg, [string]$ScheduleArg)

    # Write BAT wrapper (KI-103)
    $bat = @"
@echo off
set Lists=$ListsArg
set Schedule=$ScheduleArg
set Remove=false
set UDFSlot=$UDFSlot
"$PsExe" -ExecutionPolicy Bypass -NonInteractive -File "$SelfDest"
"@
    [System.IO.File]::WriteAllText($BatPath, $bat, [System.Text.Encoding]::ASCII)
    Write-Log "BAT wrapper written: $BatPath"

    # Build schtasks trigger
    $triggerArgs = switch ($ScheduleArg) {
        'Weekly'  { '/SC WEEKLY  /D MON /ST 03:00' }
        'Monthly' { '/SC MONTHLY /D 1   /ST 03:00' }
        default   { '/SC DAILY        /ST 03:00' }
    }

    # Remove existing task
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null

    # Register task as SYSTEM / HighestAvailable
    # Build trigger args array for clean quoting
    $triggerParts = $triggerArgs.Trim() -split '\s+' | Where-Object { $_ -ne '' }
    $result = & schtasks.exe /Create /TN "$TaskName" /TR "`"$BatPath`"" `
        /RU SYSTEM /RL HIGHEST /F @triggerParts 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Scheduled task installed: $TaskName ($ScheduleArg at 03:00)"
        return $true
    } else {
        Write-Log "WARN: Scheduled task install failed: $($result -join ' ')" 'WARN'
        return $false
    }
}

function Remove-ScheduledTask {
    $result = & schtasks.exe /Delete /TN $TaskName /F 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Scheduled task removed: $TaskName"
    } else {
        Write-Log "WARN: Task remove: $($result -join ' ')" 'WARN'
    }
    if (Test-Path $BatPath) { Remove-Item $BatPath -Force -EA SilentlyContinue }
}

# =============================================================================
# MAIN
# =============================================================================

if (-not (Test-Path $BaseDir)) { New-Item $BaseDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

Write-Log "Paladin Firewall Hardener v$ScriptVer | Site: $SiteName | Machine: $MachineName"
Write-Log "Lists: $InputLists | Schedule: $InputSchedule | Remove: $InputRemove"

# -- REMOVE MODE --
if ($InputRemove) {
    $removed = Remove-AllHardenRules
    Remove-ScheduledTask
    Set-Reg -Name 'ActiveLists'    -Value 'REMOVED'
    Set-Reg -Name 'LastRun'        -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Set-Reg -Name 'LastRunResult'  -Value "REMOVED: $removed rules deleted"
    Set-DattoUDF -Slot $UDFSlot -Value "REMOVED $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | $removed rules deleted"
    Write-Log 'Remove mode complete'
    exit 0
}

# -- Stage self to BaseDir (so scheduled task has a stable path)
try {
    Copy-Item -LiteralPath $PSCommandPath -Destination $SelfDest -Force -EA Stop
    Write-Log "Staged self: $SelfDest"
} catch {
    Write-Log "ERROR: Could not stage self: $($_.Exception.Message)" 'ERROR'
    Set-DattoUDF -Slot $UDFSlot -Value "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | Stage failed"
    exit 1
}

# -- Resolve work list
if ($InputLists -eq 'ALL') {
    $workList = $Catalog
} else {
    $requested = $InputLists -split ',' | ForEach-Object { $_.Trim() }
    $workList  = @($Catalog | Where-Object { $requested -contains $_.Name })
    $unmatched = @($requested | Where-Object {
        $n = $_
        -not ($Catalog | Where-Object { $_.Name -eq $n })
    })
    if ($unmatched.Count -gt 0) {
        Write-Log "WARN: Unrecognized list names: $($unmatched -join ', ')" 'WARN'
        Write-Log "Valid names: $($Catalog | ForEach-Object { $_.Name } | Sort-Object)"
    }
    if ($workList.Count -eq 0) {
        Write-Log 'ERROR: No valid lists matched -- check Lists input variable' 'ERROR'
        Set-DattoUDF -Slot $UDFSlot -Value "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | No lists matched"
        exit 1
    }
}

Write-Log "Work list ($($workList.Count) lists): $($workList | ForEach-Object { $_.Name } | Sort-Object)"

# -- Apply lists
$totalIPs    = 0
$failedLists = @()
foreach ($item in $workList) {
    $count = Apply-List -Name $item.Name -URL $item.URL -Format $item.Format
    if ($count -lt 0) { $failedLists += $item.Name }
    elseif ($count -gt 0) { $totalIPs += $count }
}

$appliedCount = $workList.Count - $failedLists.Count
Write-Log "Lists applied: $appliedCount/$($workList.Count) | Total IPs blocked: $totalIPs"
if ($failedLists.Count -gt 0) {
    Write-Log "Failed lists: $($failedLists -join ', ')" 'WARN'
}

# -- Install / refresh scheduled task
if ($InputSchedule -ne 'None') {
    $taskOk = Install-ScheduledTask -ListsArg $InputLists -ScheduleArg $InputSchedule
} else {
    Write-Log 'Schedule=None -- skipping task install'
    $taskOk = $false
}

# -- Registry + UDF
$activeNames = ($workList | ForEach-Object { $_.Name }) -join ','
$resultStr   = if ($failedLists.Count -eq 0) { 'PASS' } else { 'WARN' }
$taskStr     = if ($taskOk) { "Task:$InputSchedule" } else { 'Task:None' }
$summary     = "$resultStr $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | $appliedCount lists | $totalIPs IPs | $taskStr"

Set-Reg -Name 'ActiveLists'    -Value $activeNames
Set-Reg -Name 'LastRun'        -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Set-Reg -Name 'LastRunResult'  -Value $summary
Set-Reg -Name 'Schedule'       -Value $InputSchedule
Set-DattoUDF -Slot $UDFSlot -Value $summary

Write-Log "Done: $summary"
exit 0
