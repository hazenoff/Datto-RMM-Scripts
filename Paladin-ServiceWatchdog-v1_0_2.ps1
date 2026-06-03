#Requires -Version 3.0
# =============================================================================
# Paladin Service Watchdog [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.2
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
#
# CHANGES FROM v1.0.1:
#   - UDF slot changed from 9 to 13 (PALADIN-SVCWATCH) to avoid collision
#     with named 'Windows Key' field on slot 9
#
# CHANGES FROM v1.0.0:
#   - Reads Excludelist registry key -- skips excluded services entirely
#   - Reads RepairFlags registry key -- per-service auto-repair toggle
#   - Built-in demand-start exclusion pattern (edgeupdate, gupdatem, etc.)
#   - Watch-only mode: logs stopped service but does not attempt restart
#     if RepairFlag for that service is '0'
#
# REGISTRY:
#   HKLM:\SOFTWARE\Paladin\ServiceWatchdog\Watchlist    -- watched services
#   HKLM:\SOFTWARE\Paladin\ServiceWatchdog\Excludelist  -- never touch these
#   HKLM:\SOFTWARE\Paladin\ServiceWatchdog\Pinlist      -- force-watch these
#   HKLM:\SOFTWARE\Paladin\ServiceWatchdog\RepairFlags  -- per-service repair toggle
#   HKLM:\SOFTWARE\Paladin\ServiceWatchdog\Config       -- jitter, meta
#
# INPUT VARIABLES:
#   rebuildWatchlist (Boolean) -- 'true' forces watchlist rebuild
#   svcUser          (String)  -- service account UPN/domain\user (optional)
#   svcPass          (String)  -- service account password (optional)
#
# LOG:    C:\ProgramData\Paladin\ServiceWatchdog\ServiceWatchdog.log
# UDF:    Slot 9
# EXIT:   0 = all OK or recovered, 1 = unrecoverable service(s)
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer      = '1.0.2'
$LogDir         = 'C:\ProgramData\Paladin\ServiceWatchdog'
$LogFile        = "$LogDir\ServiceWatchdog.log"
$RegBase        = 'HKLM:\SOFTWARE\Paladin\ServiceWatchdog'
$RegWatchlist   = "$RegBase\Watchlist"
$RegExcludelist = "$RegBase\Excludelist"
$RegPinlist     = "$RegBase\Pinlist"
$RegRepairFlags = "$RegBase\RepairFlags"
$RegConfig      = "$RegBase\Config"
$UDF_SLOT       = 13
$MaxLogMB       = 5
$JitterMaxSec   = 300

# Demand-start services -- always stopped by design, never watch
$DemandStartExclusions = @(
    'edgeupdate','edgeupdatem','gupdate','gupdatem',
    'GoogleUpdaterService','GoogleUpdaterInternalService',
    'TrustedInstaller','msiserver','wuauserv',
    'BITS','dosvc','UsoSvc','WaaSMedicSvc',
    'ClipSVC','AppXSvc','wscsvc'
)

# Input variables
$RebuildWatchlist = ($env:rebuildWatchlist -eq 'true')
$SvcUser          = $env:svcUser
$SvcPass          = $env:svcPass
$HasCredentials   = (-not [string]::IsNullOrEmpty($SvcUser) -and -not [string]::IsNullOrEmpty($SvcPass))

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
        }
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile -EA SilentlyContinue).Length / 1MB) -gt $MaxLogMB) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.bak" -Force -EA SilentlyContinue
        }
        Add-Content -Path $LogFile -Value $line -EA SilentlyContinue
    } catch {}
}

function Write-Sep { Write-Log '================================================================' }

function Set-DattoUDF {
    param([int]$Slot, [string]$Value)
    $trimmed = if ($Value.Length -gt 255) { $Value.Substring(0,255) } else { $Value }
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' `
            -Name "Custom$Slot" -PropertyType String -Value $trimmed `
            -Force -EA Stop | Out-Null
    } catch { Write-Log "WARN: UDF$Slot write failed: $($_.Exception.Message)" }
}

function Get-MachineType {
    try {
        $pt = (Get-WmiObject Win32_OperatingSystem -EA SilentlyContinue).ProductType
        if ($pt -eq 2) { return 'DomainController' }
        if ($pt -eq 3) { return 'Server' }
    } catch {}
    return 'Workstation'
}

function Get-StartupJitter {
    try {
        $existing = Get-ItemProperty -Path $RegConfig -Name 'JitterSec' -EA SilentlyContinue
        if ($null -ne $existing -and $existing.JitterSec -ge 0) { return [int]$existing.JitterSec }
    } catch {}
    $hash = 0
    foreach ($ch in $env:COMPUTERNAME.ToCharArray()) {
        $hash = ($hash * 31 + [int][char]$ch) -band 0x7FFFFFFF
    }
    $jitter = $hash % ($JitterMaxSec + 1)
    try {
        if (-not (Test-Path $RegConfig)) { New-Item -Path $RegConfig -Force -EA SilentlyContinue | Out-Null }
        New-ItemProperty -Path $RegConfig -Name 'JitterSec' -Value $jitter -PropertyType DWord -Force -EA SilentlyContinue | Out-Null
    } catch {}
    return $jitter
}

function Get-RegHash {
    param([string]$Path)
    $hash = @{}
    try {
        $props = Get-ItemProperty -Path $Path -EA SilentlyContinue
        if ($null -eq $props) { return $hash }
        $props.PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS' } |
            ForEach-Object { $hash[$_.Name.ToLower()] = $_.Value }
    } catch {}
    return $hash
}

function Test-DemandStart {
    param([string]$ServiceName)
    foreach ($ex in $DemandStartExclusions) {
        if ($ServiceName -like "$ex*") { return $true }
    }
    return $false
}

function Get-ServiceBaseline {
    param([string]$MachineType)
    $baseline = @(
        'Spooler','BITS','Wuauserv','CryptSvc','Dnscache',
        'LanmanWorkstation','W32tm','EventLog','RpcSs',
        'SamSs','Schedule','Winmgmt'
    )
    if ($MachineType -eq 'Server' -or $MachineType -eq 'DomainController') {
        $baseline += @('LanmanServer','Netlogon','WinRM','TermService')
    }
    if ($MachineType -eq 'DomainController') {
        $baseline += @('NTDS','DNS','DFSR','kdc','IsmServ','NtFrs')
    }
    $unique = @{}
    foreach ($s in $baseline) { $unique[$s.ToLower()] = $s }
    return $unique.Values
}

function Build-Watchlist {
    param([string]$MachineType)
    Write-Log "Building watchlist -- MachineType: $MachineType"
    $watchlist = @{}

    # Load current excludelist so we respect it even during build
    $excludelist = Get-RegHash -Path $RegExcludelist

    $baseline = Get-ServiceBaseline -MachineType $MachineType
    foreach ($svc in $baseline) {
        if ($excludelist.ContainsKey($svc.ToLower())) { Write-Log "  [EXCLUDED] Skipping baseline: $svc"; continue }
        if (Test-DemandStart -ServiceName $svc) { Write-Log "  [DEMAND-START] Skipping: $svc"; continue }
        $exists = Get-WmiObject -Class Win32_Service -Filter "Name='$svc'" -EA SilentlyContinue
        if ($null -ne $exists) {
            $watchlist[$svc.ToLower()] = $svc
            Write-Log "  [BASELINE] Added: $svc ($($exists.DisplayName))"
        } else {
            Write-Log "  [BASELINE] Skipped (not present): $svc"
        }
    }

    Write-Log "  Discovering Automatic-start Microsoft services..."
    try {
        $autoStopped = Get-WmiObject -Class Win32_Service -EA SilentlyContinue |
            Where-Object {
                $_.StartMode -eq 'Auto' -and
                $_.State     -ne 'Running' -and
                $_.State     -ne 'Disabled' -and
                $_.PathName  -match 'system32|syswow64|Microsoft'
            }
        foreach ($svc in @($autoStopped)) {
            if ($excludelist.ContainsKey($svc.Name.ToLower())) { continue }
            if (Test-DemandStart -ServiceName $svc.Name) {
                Write-Log "  [DEMAND-START] Skipping auto-discovered: $($svc.Name)"
                continue
            }
            if (-not $watchlist.ContainsKey($svc.Name.ToLower())) {
                $watchlist[$svc.Name.ToLower()] = $svc.Name
                Write-Log "  [AUTO-DISCOVERED] Added: $($svc.Name) ($($svc.DisplayName))"
            }
        }
    } catch { Write-Log "WARN: Auto-discovery failed: $($_.Exception.Message)" }

    Write-Log "  Scanning third-party Automatic-start stopped services (review recommended)..."
    try {
        $thirdParty = Get-WmiObject -Class Win32_Service -EA SilentlyContinue |
            Where-Object {
                $_.StartMode -eq 'Auto' -and
                $_.State     -ne 'Running' -and
                $_.State     -ne 'Disabled' -and
                $_.PathName  -notmatch 'system32|syswow64|Microsoft'
            }
        foreach ($svc in @($thirdParty)) {
            Write-Log "  [THIRD-PARTY-REVIEW] Not auto-added: $($svc.Name) ($($svc.DisplayName))"
        }
    } catch {}

    # Also add pinlist entries
    $pinlist = Get-RegHash -Path $RegPinlist
    foreach ($key in $pinlist.Keys) {
        $svcName = $pinlist[$key]
        if (-not $watchlist.ContainsKey($key)) {
            $exists = Get-WmiObject -Class Win32_Service -Filter "Name='$svcName'" -EA SilentlyContinue
            if ($null -ne $exists) {
                $watchlist[$key] = $svcName
                Write-Log "  [PINNED] Added: $svcName ($($exists.DisplayName))"
            }
        }
    }

    # Persist watchlist
    try {
        if (-not (Test-Path $RegWatchlist)) { New-Item -Path $RegWatchlist -Force -EA Stop | Out-Null }
        $existing = Get-Item -Path $RegWatchlist -EA SilentlyContinue
        if ($null -ne $existing) {
            $existing.GetValueNames() | ForEach-Object {
                Remove-ItemProperty -Path $RegWatchlist -Name $_ -EA SilentlyContinue
            }
        }
        foreach ($key in $watchlist.Keys) {
            New-ItemProperty -Path $RegWatchlist -Name $key -Value $watchlist[$key] `
                -PropertyType String -Force -EA SilentlyContinue | Out-Null
        }
        if (-not (Test-Path $RegConfig)) { New-Item -Path $RegConfig -Force -EA SilentlyContinue | Out-Null }
        New-ItemProperty -Path $RegConfig -Name 'WatchlistBuilt' `
            -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -PropertyType String -Force -EA SilentlyContinue | Out-Null
        New-ItemProperty -Path $RegConfig -Name 'MachineType' `
            -Value $MachineType -PropertyType String -Force -EA SilentlyContinue | Out-Null
        Write-Log "Watchlist persisted: $($watchlist.Count) services"
    } catch { Write-Log "ERROR: Failed to persist watchlist: $($_.Exception.Message)" }

    return $watchlist
}

function Get-Watchlist { return (Get-RegHash -Path $RegWatchlist) }

function Get-RepairFlag {
    param([string]$ServiceName)
    # Returns true (repair enabled) unless explicitly set to '0' in RepairFlags
    try {
        $props = Get-ItemProperty -Path $RegRepairFlags -Name $ServiceName.ToLower() -EA SilentlyContinue
        if ($null -ne $props -and $props.($ServiceName.ToLower()) -eq '0') { return $false }
    } catch {}
    return $true
}

function Invoke-ServiceRestart {
    param([string]$ServiceName, [string]$DisplayName)
    Write-Log "  Attempting restart: $ServiceName ($DisplayName)" -Level 'WARN'
    try {
        & sc.exe stop $ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        & sc.exe start $ServiceName 2>&1 | Out-Null
        Start-Sleep -Seconds 5
        $svc = Get-WmiObject -Class Win32_Service -Filter "Name='$ServiceName'" -EA SilentlyContinue
        if ($null -ne $svc -and $svc.State -eq 'Running') {
            Write-Log "  [RECOVERED] $ServiceName restarted successfully (SYSTEM context)"
            return 'Recovered'
        }
        Write-Log "  Restart attempt 1 failed -- state: $($svc.State)"
    } catch { Write-Log "  Restart attempt 1 exception: $($_.Exception.Message)" }

    if ($HasCredentials) {
        Write-Log "  Attempting with service account: $SvcUser"
        try {
            & sc.exe config $ServiceName obj= $SvcUser password= $SvcPass 2>&1 | Out-Null
            & sc.exe start $ServiceName 2>&1 | Out-Null
            Start-Sleep -Seconds 5
            $svc = Get-WmiObject -Class Win32_Service -Filter "Name='$ServiceName'" -EA SilentlyContinue
            if ($null -ne $svc -and $svc.State -eq 'Running') {
                Write-Log "  [RECOVERED] $ServiceName restarted via service account ($SvcUser)"
                return 'RecoveredWithCreds'
            }
            Write-Log "  Restart attempt 2 (service account) failed -- state: $($svc.State)"
            & sc.exe config $ServiceName obj= 'LocalSystem' password= '' 2>&1 | Out-Null
            Write-Log "  Restored LocalSystem on $ServiceName"
        } catch {
            Write-Log "  Restart attempt 2 exception: $($_.Exception.Message)"
            try { & sc.exe config $ServiceName obj= 'LocalSystem' password= '' 2>&1 | Out-Null } catch {}
        }
    }

    Write-Log "  [FAILED] $ServiceName could not be recovered" -Level 'WARN'
    return 'Failed'
}

# =============================================================================
# STARTUP
# =============================================================================

if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

$siteName    = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }
$machineType = Get-MachineType

# Jitter
$jitter = Get-StartupJitter
if ($jitter -gt 0) {
    Write-Host "[$( Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] Startup jitter: ${jitter}s (offset for $env:COMPUTERNAME)"
    Start-Sleep -Seconds $jitter
}

Write-Sep
Write-Log "Paladin Service Watchdog v$ScriptVer | Site: $siteName | Machine: $env:COMPUTERNAME | Type: $machineType"
Write-Log "Credentials: $(if ($HasCredentials) { "Yes ($SvcUser)" } else { 'No' }) | RebuildWatchlist: $RebuildWatchlist"
Write-Sep

# Load excludelist
$excludelist = Get-RegHash -Path $RegExcludelist
if ($excludelist.Count -gt 0) {
    Write-Log "Excludelist: $($excludelist.Count) services excluded -- $($excludelist.Values -join ', ')"
}

# Watchlist
$watchlist = $null
if ($RebuildWatchlist) {
    Write-Log 'Forced watchlist rebuild requested'
    $watchlist = Build-Watchlist -MachineType $machineType
} else {
    $watchlist = Get-Watchlist
    if ($null -eq $watchlist -or $watchlist.Count -eq 0) {
        Write-Log 'No watchlist found -- running initial build'
        $watchlist = Build-Watchlist -MachineType $machineType
    } else {
        Write-Log "Watchlist loaded: $($watchlist.Count) services"
    }
}

if ($null -eq $watchlist -or $watchlist.Count -eq 0) {
    Write-Log 'ERROR: Watchlist is empty -- cannot proceed'
    Set-DattoUDF -Slot $UDF_SLOT -Value "ERROR $(Get-Date -Format 'yyyy-MM-dd HH:mm') - Watchlist empty"
    exit 1
}

# =============================================================================
# HEALTH CHECK + REMEDIATION
# =============================================================================

Write-Sep
Write-Log "Checking $($watchlist.Count) watched services..."

$checked = 0; $healthy = 0; $recovered = 0; $watchOnly = 0; $failed = 0
$failedNames = @()

foreach ($key in $watchlist.Keys) {
    $svcName = $watchlist[$key]

    # Skip if in excludelist (manager may have added since last run)
    if ($excludelist.ContainsKey($key)) {
        Write-Log "  [EXCLUDED] $svcName -- skipping per excludelist"
        continue
    }

    $checked++
    try {
        $svc = Get-WmiObject -Class Win32_Service -Filter "Name='$svcName'" -EA SilentlyContinue
        if ($null -eq $svc) { Write-Log "  [SKIP] $svcName -- not found on machine"; continue }
        if ($svc.State -eq 'Running') { $healthy++; continue }
        if ($svc.StartMode -eq 'Disabled') { Write-Log "  [SKIP] $svcName -- Disabled (intentional)"; continue }

        Write-Log "  [STOPPED] $svcName ($($svc.DisplayName)) -- State: $($svc.State)" -Level 'WARN'

        $repairEnabled = Get-RepairFlag -ServiceName $svcName

        if (-not $repairEnabled) {
            Write-Log "  [WATCH-ONLY] $svcName -- Auto-Repair disabled. Flagging but not restarting." -Level 'WARN'
            $watchOnly++
            $failed++
            $failedNames += "$svcName(watch-only)"
        } else {
            $result = Invoke-ServiceRestart -ServiceName $svcName -DisplayName $svc.DisplayName
            if ($result -eq 'Recovered' -or $result -eq 'RecoveredWithCreds') {
                $recovered++
            } else {
                $failed++
                $failedNames += $svcName
            }
        }
    } catch {
        Write-Log "  [ERROR] $svcName -- check failed: $($_.Exception.Message)" -Level 'WARN'
        $failed++; $failedNames += $svcName
    }
}

# Write last-run stats to registry for Manager GUI to display
try {
    if (-not (Test-Path $RegConfig)) { New-Item -Path $RegConfig -Force -EA SilentlyContinue | Out-Null }
    New-ItemProperty -Path $RegConfig -Name 'LastRun'    -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -PropertyType String -Force -EA SilentlyContinue | Out-Null
    New-ItemProperty -Path $RegConfig -Name 'LastResult' -Value "Checked:$checked OK:$healthy Fixed:$recovered WatchOnly:$watchOnly Failed:$($failed - $watchOnly)" -PropertyType String -Force -EA SilentlyContinue | Out-Null
} catch {}

# =============================================================================
# FINAL REPORT
# =============================================================================

Write-Sep
Write-Log "Results: $checked checked | $healthy healthy | $recovered auto-recovered | $watchOnly watch-only | $($failed - $watchOnly) unrecoverable"

if ($failed -gt 0) {
    $failList = $failedNames -join ', '
    Write-Log "ATTENTION: $failList" -Level 'WARN'
    $udfMsg = "ATTN $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Chk:$checked OK:$healthy Fixed:$recovered WatchOnly:$watchOnly Fail:$($failed-$watchOnly) ($failList)"
    Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg
    Write-Sep
    # Only exit 1 (ticket) if there are truly unrecoverable services, not just watch-only
    if (($failed - $watchOnly) -gt 0) { exit 1 }
    exit 0
}

$udfMsg = if ($recovered -gt 0) {
    "FIXED $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Chk:$checked OK:$healthy AutoFixed:$recovered"
} else {
    "PASS $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Chk:$checked All healthy"
}
Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg
Write-Sep
exit 0
