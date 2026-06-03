#Requires -Version 3.0
# =============================================================================
# PPM RMM -- Paladin Performance Maximizer (Safe Tier)
# Datto RMM Component: PPM RMM Safe [WIN]
# Version: 9.0.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
# Tier: Safe -- registry + inbox tools only. No installs. No GUI. No tasks.
# One-shot: Undo auto-detected from backup key. No input variables required.
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$siteName = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }
Write-Host "PPM RMM Safe v9.0.0 | Site: $siteName | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# ---- Undo auto-detection ----------------------------------------------------
$BackupRoot  = 'HKLM:\SOFTWARE\Paladin\PPM\RMM\Backup'
$UDFSlotN    = 10
$Undo        = Test-Path $BackupRoot
$action      = if ($Undo) { 'RESTORE' } else { 'APPLY' }
Write-Host "Action: $action (auto-detected from backup key)"

# ---- OS detection -----------------------------------------------------------
$isServer = $false
$isLaptop = $false
try {
    $osType   = (Get-WmiObject Win32_OperatingSystem -EA Stop).ProductType
    $isServer = ($osType -eq 2 -or $osType -eq 3)
} catch {}
try {
    $battery  = Get-WmiObject Win32_Battery -EA SilentlyContinue
    $isLaptop = ($null -ne $battery -and @($battery).Count -gt 0)
} catch {}
Write-Host "Server: $isServer | Laptop: $isLaptop"

# ---- Inbox tool check (no installs) -----------------------------------------
$hasPowercfg = $null -ne (Get-Command powercfg.exe -EA SilentlyContinue)
$hasFsutil   = $null -ne (Get-Command fsutil.exe   -EA SilentlyContinue)

# ---- Helpers ----------------------------------------------------------------
function Set-PPMRMMUDF {
    param([int]$Slot, [string]$Value)
    $v = $Value.Substring(0, [Math]::Min($Value.Length, 255))
    try { New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' -Name "Custom$Slot" -PropertyType String -Value $v -Force -EA Stop | Out-Null }
    catch { Write-Host "WARN: UDF$Slot write failed: $_" }
}

function Ensure-BackupRoot {
    if (-not (Test-Path $BackupRoot)) { New-Item -Path $BackupRoot -Force -EA SilentlyContinue | Out-Null }
}

function Backup-RegValue {
    param([string]$Path, [string]$Name)
    try {
        Ensure-BackupRoot
        $sk  = ($Path + '_' + $Name) -replace '[\\:/]','_'
        $e   = Get-ItemProperty -Path $Path -Name $Name -EA SilentlyContinue
        $val = if ($null -ne $e) { $e.$Name } else { '__NOTEXIST__' }
        New-ItemProperty -Path $BackupRoot -Name $sk -Value $val -Force -EA SilentlyContinue | Out-Null
    } catch {}
}

function Restore-RegValue {
    param([string]$Path, [string]$Name, [string]$Type)
    try {
        $sk     = ($Path + '_' + $Name) -replace '[\\:/]','_'
        $backed = Get-ItemProperty -Path $BackupRoot -Name $sk -EA SilentlyContinue
        if ($null -eq $backed) { return }
        $val = $backed.$sk
        if ($val -eq '__NOTEXIST__') {
            Remove-ItemProperty -Path $Path -Name $Name -EA SilentlyContinue
        } else {
            if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -EA SilentlyContinue | Out-Null }
            New-ItemProperty -Path $Path -Name $Name -Value $val -PropertyType $Type -Force -EA SilentlyContinue | Out-Null
        }
    } catch {}
}

function Set-RegDWord {
    param([string]$Path, [string]$Name, [int]$Value)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -EA SilentlyContinue | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force -EA SilentlyContinue | Out-Null
}

$ok = 0; $warn = 0; $err = 0

# =============================================================================
# 01 -- POWER PLAN
# =============================================================================
Write-Host '-- [01/08] Power Plan (High Performance)'
try {
    if (-not $hasPowercfg) { Write-Host '  SKIP: powercfg.exe missing'; $warn++ }
    elseif (-not $Undo) {
        # GUIDs: Ultimate Performance=e9a42b02-d5df-448d-aa00-03f14749eb61
        #        High Performance=8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
        #        Balanced=381b4222-f694-41f0-9685-ff5bb260df2e
        $upGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
        $hpGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        $allPlans = [string](& powercfg /list 2>&1)

        # Back up current active plan
        $cur = [string](& powercfg /getactivescheme 2>&1 | Select-Object -First 1)
        if ($cur -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
            Ensure-BackupRoot
            New-ItemProperty -Path $BackupRoot -Name 'PowerPlan_Active' -Value $Matches[1] -Force -EA SilentlyContinue | Out-Null
        }

        if ($isLaptop) {
            # Laptop: activate Balanced as base plan, then override AC-only indexes
            # to match High Performance behavior when plugged in
            $balGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
            & powercfg /setactive $balGuid 2>&1 | Out-Null
            # AC: max CPU, no throttle. DC: Windows defaults (untouched)
            & powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>&1 | Out-Null
            & powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 100 2>&1 | Out-Null
            & powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 2>&1 | Out-Null
            & powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5   2>&1 | Out-Null
            & powercfg -setactive SCHEME_CURRENT 2>&1 | Out-Null
            Write-Host "  OK: Laptop -- Balanced plan, AC=max CPU, DC=adaptive"; $ok++
        } else {
            # Desktop: try Ultimate Performance first, fall back to High Performance
            $targetGuid = $null
            if ($allPlans -match [regex]::Escape($upGuid)) { $targetGuid = $upGuid }
            elseif ($allPlans -match [regex]::Escape($hpGuid)) { $targetGuid = $hpGuid }
            else {
                $m = [string](& powercfg /list 2>&1 | Where-Object { $_ -match 'High|Perf|Max|Ultimate' } | Select-Object -First 1)
                if ($m -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $targetGuid = $Matches[1] }
            }
            if ($null -ne $targetGuid) {
                & powercfg /setactive $targetGuid 2>&1 | Out-Null
                Write-Host "  OK: Desktop -- High/Ultimate Performance ($targetGuid)"; $ok++
            } else { Write-Host '  WARN: High Performance plan not found'; $warn++ }
        }
    } else {
        $b = Get-ItemProperty -Path $BackupRoot -Name 'PowerPlan_Active' -EA SilentlyContinue
        if ($null -ne $b) { & powercfg /setactive $b.PowerPlan_Active 2>&1 | Out-Null; Write-Host '  OK: Plan restored'; $ok++ }
        else { Write-Host '  WARN: No backup'; $warn++ }
    }
} catch { Write-Host "  ERROR: PowerPlan -- $($_.Exception.Message)"; $err++ }

# =============================================================================
# 02 -- WIN32 PRIORITY SEPARATION
# =============================================================================
Write-Host '-- [02/08] Win32PrioritySeparation'
try {
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'
    if (-not $Undo) {
        Backup-RegValue -Path $p -Name 'Win32PrioritySeparation'
        Set-RegDWord -Path $p -Name 'Win32PrioritySeparation' -Value 38
        Write-Host '  OK: =38 (foreground boost + short quanta)'; $ok++
    } else { Restore-RegValue -Path $p -Name 'Win32PrioritySeparation' -Type 'DWord'; Write-Host '  OK: Restored'; $ok++ }
} catch { Write-Host "  ERROR: PrioritySep -- $($_.Exception.Message)"; $err++ }

# =============================================================================
# 03 -- VISUAL EFFECTS
# =============================================================================
Write-Host '-- [03/08] Visual Effects (performance mode)'
try {
    $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
    if (-not $Undo) {
        Backup-RegValue -Path $p -Name 'VisualFXSetting'
        Set-RegDWord -Path $p -Name 'VisualFXSetting' -Value 2
        Write-Host '  OK: VisualFXSetting=2 (effective at next login)'; $ok++
    } else { Restore-RegValue -Path $p -Name 'VisualFXSetting' -Type 'DWord'; Write-Host '  OK: Restored'; $ok++ }
} catch { Write-Host "  ERROR: VisualFX -- $($_.Exception.Message)"; $err++ }

# =============================================================================
# 04 -- MMCSS
# =============================================================================
Write-Host '-- [04/08] MMCSS NetworkThrottlingIndex + SystemResponsiveness + Games task'
try {
    $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    if (-not $Undo) {
        Backup-RegValue -Path $mm -Name 'NetworkThrottlingIndex'
        Backup-RegValue -Path $mm -Name 'SystemResponsiveness'
        New-ItemProperty -Path $mm -Name 'NetworkThrottlingIndex' -Value 0xFFFFFFFF -PropertyType DWord -Force -EA SilentlyContinue | Out-Null
        Set-RegDWord -Path $mm -Name 'SystemResponsiveness' -Value 16
        $g = "$mm\Tasks\Games"
        if (-not (Test-Path $g)) { New-Item -Path $g -Force -EA SilentlyContinue | Out-Null }
        Set-RegDWord -Path $g -Name 'GPU Priority' -Value 8
        Set-RegDWord -Path $g -Name 'Priority'     -Value 6
        Set-RegDWord -Path $g -Name 'Scheduling Category' -Value 2
        Set-RegDWord -Path $g -Name 'SFIO Priority' -Value 1
        Write-Host '  OK: NTI=0xFFFFFFFF SR=16 Games task set'; $ok++
    } else {
        Restore-RegValue -Path $mm -Name 'NetworkThrottlingIndex' -Type 'DWord'
        Restore-RegValue -Path $mm -Name 'SystemResponsiveness'   -Type 'DWord'
        Write-Host '  OK: MMCSS restored'; $ok++
    }
} catch { Write-Host "  ERROR: MMCSS -- $($_.Exception.Message)"; $err++ }

# =============================================================================
# 05 -- NTFS OVERHEAD
# =============================================================================
Write-Host '-- [05/08] NTFS overhead (8.3 names, LastAccess, DisablePagingExecutive)'
try {
    $mp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    $np = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
    if (-not $Undo) {
        Backup-RegValue -Path $mp -Name 'DisablePagingExecutive'
        Backup-RegValue -Path $np -Name 'NtfsDisable8dot3NameCreation'
        Backup-RegValue -Path $np -Name 'NtfsDisableLastAccessUpdate'
        if ($hasFsutil) {
            & fsutil behavior set disable8dot3 1    2>&1 | Out-Null
            & fsutil behavior set disablelastaccess 1 2>&1 | Out-Null
        } else {
            Set-RegDWord -Path $np -Name 'NtfsDisable8dot3NameCreation' -Value 1
            Set-RegDWord -Path $np -Name 'NtfsDisableLastAccessUpdate'  -Value 1
            Write-Host '  INFO: Registry fallback (fsutil unavailable)'
        }
        Set-RegDWord -Path $mp -Name 'DisablePagingExecutive' -Value 1
        Write-Host '  OK: 8.3 off, LastAccess off, DPE=1'; $ok++
    } else {
        if ($hasFsutil) {
            & fsutil behavior set disable8dot3 0    2>&1 | Out-Null
            & fsutil behavior set disablelastaccess 0 2>&1 | Out-Null
        } else {
            Restore-RegValue -Path $np -Name 'NtfsDisable8dot3NameCreation' -Type 'DWord'
            Restore-RegValue -Path $np -Name 'NtfsDisableLastAccessUpdate'  -Type 'DWord'
        }
        Restore-RegValue -Path $mp -Name 'DisablePagingExecutive' -Type 'DWord'
        Write-Host '  OK: NTFS restored'; $ok++
    }
} catch { Write-Host "  ERROR: NTFS -- $($_.Exception.Message)"; $err++ }

# =============================================================================
# 06 -- NAGLE / TCPACKFREQUENCY
# =============================================================================
Write-Host '-- [06/08] Nagle disable + TcpAckFrequency (per active NIC)'
try {
    $ifBase = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
    if (Test-Path $ifBase) {
        $nicCount = 0
        foreach ($iface in (Get-ChildItem -Path $ifBase -EA SilentlyContinue)) {
            $ifp = $iface.PSPath; if ($null -eq $ifp) { continue }
            $d = Get-ItemProperty -Path $ifp -Name 'DhcpIPAddress' -EA SilentlyContinue
            $s = Get-ItemProperty -Path $ifp -Name 'IPAddress'     -EA SilentlyContinue
            $hasIP = ($null -ne $d -and $d.DhcpIPAddress -ne '0.0.0.0') -or
                     ($null -ne $s -and $s.IPAddress -ne '0.0.0.0' -and $s.IPAddress -ne '')
            if (-not $hasIP) { continue }
            if (-not $Undo) {
                Backup-RegValue -Path $ifp -Name 'TcpAckFrequency'
                Backup-RegValue -Path $ifp -Name 'TCPNoDelay'
                Set-RegDWord -Path $ifp -Name 'TcpAckFrequency' -Value 1
                Set-RegDWord -Path $ifp -Name 'TCPNoDelay'      -Value 1
            } else {
                Restore-RegValue -Path $ifp -Name 'TcpAckFrequency' -Type 'DWord'
                Restore-RegValue -Path $ifp -Name 'TCPNoDelay'      -Type 'DWord'
            }
            $nicCount++
        }
        Write-Host "  OK: Nagle $(if($Undo){'restored'}else{'applied'}) on $nicCount NIC(s)"; $ok++
    } else { Write-Host '  WARN: Interfaces key not found'; $warn++ }
} catch { Write-Host "  ERROR: Nagle -- $($_.Exception.Message)"; $err++ }

# =============================================================================
# 07 -- IFEO PRIORITY BOOST (Above Normal -- browsers, Office, QB, Autodesk)
# Permanent OS-level priority -- no watcher, no PPM session required.
# =============================================================================
Write-Host '-- [07/08] IFEO Priority Boost (Above Normal -- browsers, Office, QB, Autodesk)'
try {
    $CPU_ABOVE = 5; $IO_HIGH = 3; $SENTINEL = 0xFF
    $ifeoBase  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    $ifeoBack  = "$BackupRoot\IFEO"

    $targetExes = @(
        'chrome.exe','msedge.exe','brave.exe','vivaldi.exe','opera.exe','chromium.exe',
        'firefox.exe','waterfox.exe','librewolf.exe',
        'WINWORD.EXE','EXCEL.EXE','POWERPNT.EXE','OUTLOOK.EXE','ONENOTE.EXE',
        'MSACCESS.EXE','MSPUB.EXE','VISIO.EXE','TEAMS.EXE','ms-teams.exe',
        'QBW32.exe','QBW64.exe','QBDBMgrN.exe','qbupdate.exe',
        'acad.exe','Revit.exe','Inventor.exe','3dsmax.exe','maya.exe',
        'navisworks.exe','fusion360.exe','motionbuilder.exe','mudbox.exe',
        'recap.exe','vred.exe'
    )

    if (-not (Test-Path $ifeoBack)) { New-Item -Path $ifeoBack -Force -EA SilentlyContinue | Out-Null }

    $iok = 0; $ierr = 0
    foreach ($exe in $targetExes) {
        $perfKey = "$ifeoBase\$exe\PerfOptions"
        if (-not $Undo) {
            # Backup existing values (never fails the count)
            $eCpu = (Get-ItemProperty -Path $perfKey -Name 'CpuPriorityClass' -EA SilentlyContinue).CpuPriorityClass
            $eIo  = (Get-ItemProperty -Path $perfKey -Name 'IoPriority'       -EA SilentlyContinue).IoPriority
            New-ItemProperty -Path $ifeoBack -Name "${exe}_Cpu" -Value (if($null -ne $eCpu){$eCpu}else{$SENTINEL}) -Type DWord -Force -EA SilentlyContinue | Out-Null
            New-ItemProperty -Path $ifeoBack -Name "${exe}_Io"  -Value (if($null -ne $eIo){$eIo}else{$SENTINEL})   -Type DWord -Force -EA SilentlyContinue | Out-Null
            # Write via reg.exe -- handles IFEO ACLs under both SYSTEM and interactive admin
            try {
                $regPath = "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$exe\PerfOptions"
                $r1 = & reg.exe add $regPath /v CpuPriorityClass /t REG_DWORD /d $CPU_ABOVE /f 2>&1
                $r2 = & reg.exe add $regPath /v IoPriority       /t REG_DWORD /d $IO_HIGH   /f 2>&1
                $iok++
            } catch { $ierr++ }
        } else {
            try {
                $bCpu = (Get-ItemProperty -Path $ifeoBack -Name "${exe}_Cpu" -EA SilentlyContinue)."${exe}_Cpu"
                $bIo  = (Get-ItemProperty -Path $ifeoBack -Name "${exe}_Io"  -EA SilentlyContinue)."${exe}_Io"
                if (Test-Path $perfKey) {
                    if ($null -eq $bCpu -or $bCpu -eq $SENTINEL) {
                        Remove-Item -Path $perfKey -Recurse -Force -EA SilentlyContinue
                        $parent = Split-Path $perfKey -Parent
                        $kids   = Get-ChildItem -Path $parent -EA SilentlyContinue
                        $propList = @(Get-ItemProperty -Path $parent -EA SilentlyContinue | Get-Member -MemberType NoteProperty -EA SilentlyContinue | Where-Object { $_.Name -notmatch '^PS' })
                        if ((-not $kids) -and ($propList.Count -eq 0)) { Remove-Item -Path $parent -Recurse -Force -EA SilentlyContinue }
                    } else {
                        Set-ItemProperty -Path $perfKey -Name 'CpuPriorityClass' -Value $bCpu -Type DWord -EA SilentlyContinue
                        Set-ItemProperty -Path $perfKey -Name 'IoPriority'       -Value $bIo  -Type DWord -EA SilentlyContinue
                    }
                }
                $iok++
            } catch { $ierr++ }
        }
    }

    if ($Undo) { Remove-Item -Path $ifeoBack -Recurse -Force -EA SilentlyContinue }
    Write-Host "  OK: IFEO $(if($Undo){'restored'}else{'applied'}) -- $iok EXEs | $ierr errors"
    $ok++
} catch { Write-Host "  ERROR: IFEOBoost -- $($_.Exception.Message)"; $err++ }

# =============================================================================
# 08 -- JUNK CLEANUP (no damage to user data -- server-aware)
# =============================================================================
Write-Host '-- [08/08] Junk file cleanup'
if (-not $Undo) {
    try {
        $cleaned = 0

        # Helper: remove contents of a folder, leave folder intact
        function Remove-FolderContents {
            param([string]$Path, [string]$Label, [int]$MinAgeMins = 0)
            if (-not (Test-Path $Path)) { return }
            $cutoff = (Get-Date).AddMinutes(-$MinAgeMins)
            $items  = Get-ChildItem -Path $Path -Force -EA SilentlyContinue
            foreach ($item in $items) {
                if ($MinAgeMins -gt 0 -and $item.LastWriteTime -gt $cutoff) { continue }
                try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -EA Stop } catch {}
            }
        }

        # System temp (age-gated 60 min -- running processes may hold handles)
        Remove-FolderContents -Path "$env:SystemRoot\Temp" -Label 'Windows\Temp' -MinAgeMins 60

        # Windows Update download cache
        Remove-FolderContents -Path "$env:SystemRoot\SoftwareDistribution\Download" -Label 'WU Cache'

        # Windows CBS / DISM logs
        foreach ($logPath in @("$env:SystemRoot\Logs\CBS","$env:SystemRoot\Logs\DISM")) {
            Remove-FolderContents -Path $logPath -Label "Logs\$(Split-Path $logPath -Leaf)"
        }

        # WER crash dumps
        foreach ($p in @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive","$env:ProgramData\Microsoft\Windows\WER\ReportQueue")) {
            Remove-FolderContents -Path $p -Label "WER\$(Split-Path $p -Leaf)"
        }

        # Delivery Optimization cache
        $doPath = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
        Remove-FolderContents -Path $doPath -Label 'DO Cache'
        try {
            $doCmd = Get-Command 'Delete-DeliveryOptimizationCache' -EA SilentlyContinue
            if ($doCmd) { Delete-DeliveryOptimizationCache -Force -EA SilentlyContinue | Out-Null }
        } catch {}

        # Font cache (workstation only -- active RDS sessions can glitch)
        if (-not $isServer) {
            foreach ($p in @("$env:SystemRoot\ServiceProfiles\LocalService\AppData\Local\FontCache","$env:SystemRoot\System32\FNTCACHE.DAT")) {
                if (Test-Path $p) { try { Remove-Item -LiteralPath $p -Recurse -Force -EA SilentlyContinue } catch {} }
            }
        }

        # Per-user temp + thumbnail cache (age-gated 60 min)
        $profileKeys = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -EA SilentlyContinue |
                       Where-Object { $_.PSChildName -match 'S-1-5-21-(\d+-?){4}$|S-1-12-1-(\d+-?){4}$' }
        foreach ($prof in $profileKeys) {
            $profPath = $prof.ProfileImagePath
            if ([string]::IsNullOrEmpty($profPath) -or -not (Test-Path $profPath)) { continue }
            # User temp
            Remove-FolderContents -Path "$profPath\AppData\Local\Temp" -Label 'User\Temp' -MinAgeMins 60
            # Thumbnail cache
            $thumbPath = "$profPath\AppData\Local\Microsoft\Windows\Explorer"
            if (Test-Path $thumbPath) {
                Get-ChildItem -Path $thumbPath -Filter 'thumbcache_*.db' -Force -EA SilentlyContinue |
                    ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -EA SilentlyContinue } catch {} }
            }
            # Per-user WER
            Remove-FolderContents -Path "$profPath\AppData\Local\Microsoft\Windows\WER" -Label 'User\WER'
        }

        # Recycle Bin
        try {
            $rc = Get-Command 'Clear-RecycleBin' -EA SilentlyContinue
            if ($rc) { Clear-RecycleBin -Force -EA SilentlyContinue }
            else {
                $shell = New-Object -ComObject Shell.Application
                $shell.Namespace(0xA).Items() | ForEach-Object { $_.InvokeVerb('delete') }
            }
        } catch {}

        Write-Host "  OK: Junk cleanup complete"; $ok++
    } catch { Write-Host "  ERROR: Cleanup -- $($_.Exception.Message)"; $err++ }
} else {
    Write-Host '  SKIP: Cleanup not reversed (one-directional)'; $ok++
}

# =============================================================================
# RESULT
# =============================================================================
Write-Host ''
Write-Host "=== PPM RMM Safe $action complete: ok=$ok warn=$warn errors=$err ==="

$status = if ($err -gt 0) { "FAIL ok=$ok warn=$warn err=$err $(Get-Date -Format 'yyyy-MM-dd')" } `
          else             { "PASS ok=$ok warn=$warn $(Get-Date -Format 'yyyy-MM-dd')" }
Set-PPMRMMUDF -Slot $UDFSlotN -Value "PPM-Safe $action $status"

# Clean up backup key on successful Undo
if ($Undo -and $err -eq 0) {
    Remove-Item -Path $BackupRoot -Recurse -Force -EA SilentlyContinue
    Write-Host 'Backup key removed -- fully restored.'
}

if ($err -gt 0) { Write-Host "ERROR: $err step(s) failed."; exit 1 }
Write-Host 'SUCCESS: PPM Safe complete. No reboot required.'
exit 0
