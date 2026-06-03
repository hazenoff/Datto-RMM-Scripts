#Requires -Version 3.0
# =============================================================================
# Paladin Disk Repair Suite [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.1.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
#
# PHASES (state machine -- resumes automatically across reboots):
#   Phase 1: Schedule chkdsk /f /r /x on C: + notify user + reboot
#            Script copies itself to fixed path + registers ONSTART task
#            so Phases 2-5 run automatically after reboot as SYSTEM.
#   Phase 2: Read chkdsk result from event log + SFC /scannow
#   Phase 3: DISM /Online /Cleanup-Image /RestoreHealth
#   Phase 4: Defrag C: (retrim SSD / full defrag HDD)
#   Phase 5: Final report to stdout + log file + cleanup
#
# LOG:    C:\ProgramData\Paladin\DiskRepair\DiskRepair.log
# STATE:  HKLM:\SOFTWARE\Paladin\DiskRepair
# TASK:   Paladin_DiskRepair_Resume (auto-created, auto-deleted)
#
# NOTE:   Phase 1 stdout appears in Datto job log.
#         Phases 2-5 run via scheduled task -- output goes to log file.
#         Read C:\ProgramData\Paladin\DiskRepair\DiskRepair.log for full detail.
#
# INPUT VARIABLES: None.
# EXIT CODES: 0=Success or rebooting, 1=Fatal error
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$StateKey   = 'HKLM:\SOFTWARE\Paladin\DiskRepair'
$LogDir     = 'C:\ProgramData\Paladin\DiskRepair'
$LogFile    = "$LogDir\DiskRepair.log"
$ScriptDest = "$LogDir\DiskRepair-Resume.ps1"
$TaskName   = 'Paladin_DiskRepair_Resume'
$Drive      = 'C'
$DrivePath  = 'C:'
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
        if (-not (Test-Path $LogDir)) {
            New-Item -Path $LogDir -ItemType Directory -Force -EA Stop | Out-Null
        }
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile -EA SilentlyContinue).Length / 1MB) -gt $MaxLogMB) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.bak" -Force -EA SilentlyContinue
        }
        Add-Content -Path $LogFile -Value $line -EA SilentlyContinue
    } catch {}
}

function Write-Separator {
    Write-Log '============================================================'
}

function Show-UserMessage {
    param([string]$Message, [string]$Title = 'Paladin IT Maintenance')
    try {
        $sessions = & query session 2>&1 | Where-Object { $_ -match 'console|rdp-tcp' -and $_ -match 'Active' }
        if ($sessions) {
            & msg.exe '*' /TIME:300 "${Title}: $Message" 2>&1 | Out-Null
            Write-Log "User notified: $Message"
        } else {
            Write-Log "No active user session -- skipping popup: $Message"
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

function Get-DriveType {
    try {
        $pd = Get-WmiObject -Namespace 'root\Microsoft\Windows\Storage' -Class 'MSFT_PhysicalDisk' -EA SilentlyContinue |
              Select-Object -First 1
        if ($null -ne $pd) {
            if ($pd.MediaType -eq 4) { return 'SSD' }
            if ($pd.MediaType -eq 3) { return 'HDD' }
        }
        $disk = Get-WmiObject -Query "SELECT * FROM Win32_DiskDrive" -EA SilentlyContinue | Select-Object -First 1
        if ($null -ne $disk -and $disk.MediaType -match 'SSD|Solid') { return 'SSD' }
    } catch {}
    return 'Unknown'
}

function Register-ResumeTask {
    try {
        if (-not (Test-Path $LogDir)) {
            New-Item -Path $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null
        }
        # Copy script to fixed location -- Datto package cache path changes per job
        Copy-Item -LiteralPath $PSCommandPath -Destination $ScriptDest -Force -EA Stop
        Write-Log "Script copied to: $ScriptDest"

        # Remove any stale resume task
        & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null

        # Register ONSTART task -- fires as SYSTEM after reboot, runs Phases 2-5
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

# =============================================================================
# STARTUP
# =============================================================================
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null
}

$currentPhase = Get-State
$driveType    = Get-DriveType
$siteName     = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }

Write-Separator
Write-Log "Paladin Disk Repair Suite v1.1.0 | Site: $siteName"
Write-Log "Drive: $DrivePath | Type: $driveType | Phase: $currentPhase/5"
Write-Log "Log: $LogFile"
Write-Separator

# Domain Controller guard
try {
    $osRole = (Get-WmiObject Win32_OperatingSystem -EA SilentlyContinue).ProductType
    if ($osRole -eq 2) {
        Write-Log 'ERROR: Domain Controller detected. Forced reboot on a DC requires coordination. Aborting.'
        exit 1
    }
} catch {}

# =============================================================================
# PHASE 1 -- SCHEDULE CHKDSK + REBOOT
# =============================================================================
if ($currentPhase -eq 1) {
    Write-Separator
    Write-Log 'PHASE 1: Scheduling chkdsk /f /r /x on C: then rebooting'

    # Check if already scheduled
    $chkReg   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $bootExec = (Get-ItemProperty -Path $chkReg -Name 'BootExecute' -EA SilentlyContinue).BootExecute

    Write-Log 'Scheduling chkdsk via chkntfs + fsutil dirty flag...'
    & chkntfs /X $DrivePath 2>&1 | Out-Null   # clear exclusions
    & chkntfs /C $DrivePath 2>&1 | Out-Null   # schedule check
    & fsutil dirty set $DrivePath 2>&1 | Out-Null
    Write-Log 'Volume marked dirty -- chkdsk /f /r will run at next boot'

    # Advance state before reboot
    Set-State -Phase 2 -Note 'Chkdsk scheduled. Rebooting.'

    # Register auto-resume task
    Write-Log 'Registering auto-resume scheduled task...'
    Register-ResumeTask

    # Notify user -- 2 minute warning
    Show-UserMessage -Message 'IMPORTANT: Your PC will restart in 2 minutes for scheduled disk maintenance. Please SAVE ALL OPEN WORK now. Do NOT power off your PC during this process -- disk repair may take up to 2 hours.'
    Write-Log 'Waiting 90 seconds before reboot...'
    Start-Sleep -Seconds 90

    # 30 second final warning
    Show-UserMessage -Message 'Your PC will restart in 30 seconds. Disk repair will run automatically. Do NOT power off your PC.'
    Write-Log 'Final 30s warning sent. Rebooting now...'
    Start-Sleep -Seconds 30

    Write-Log 'Initiating reboot. Phases 2-5 will run automatically after restart.'
    Write-Log "Full output will be in: $LogFile"
    Write-Separator

    & shutdown.exe /r /t 0 /c "Paladin IT: Disk maintenance in progress. Do not power off." /f 2>&1 | Out-Null
    exit 0
}

# =============================================================================
# PHASE 2 -- READ CHKDSK RESULT + SFC /SCANNOW
# =============================================================================
if ($currentPhase -eq 2) {
    Write-Separator
    Write-Log 'PHASE 2: Reading chkdsk result + running SFC /scannow'

    # Notify user repair is underway
    Show-UserMessage -Message 'Disk maintenance is now running in the background. This may take up to 60 minutes. Please do NOT power off or restart your PC until you receive a completion notice.'

    # Read chkdsk result from event log -- search multiple sources
    Write-Log 'Reading chkdsk result from event log...'
    $chkMsg    = ''
    $chkSource = ''

    $logSources = @(
        @{ Log='Microsoft-Windows-Chkdsk/Operational'; Ids=@(26226,26228,26210,26212) },
        @{ Log='Application';                          Ids=@(26226,1001) }
    )

    foreach ($src in $logSources) {
        if ($chkMsg) { break }
        try {
            $evts = Get-WinEvent -LogName $src.Log -EA SilentlyContinue |
                    Where-Object { $_.Id -in $src.Ids } |
                    Sort-Object TimeCreated -Descending |
                    Select-Object -First 1
            if ($null -ne $evts) {
                $chkMsg    = ($evts.Message -replace "`r`n",' ' -replace "`n",' ').Trim()
                $chkSource = "$($src.Log) Event $($evts.Id) at $($evts.TimeCreated)"
            }
        } catch {}
    }

    # Also check NTFS operational log
    if (-not $chkMsg) {
        try {
            $ntfsEvts = Get-WinEvent -LogName 'Microsoft-Windows-NTFS/Operational' -EA SilentlyContinue |
                        Where-Object { $_.Id -in @(98,130) } |
                        Sort-Object TimeCreated -Descending |
                        Select-Object -First 1
            if ($null -ne $ntfsEvts) {
                $chkMsg    = ($ntfsEvts.Message -replace "`r`n",' ').Trim()
                $chkSource = "NTFS/Operational Event $($ntfsEvts.Id)"
            }
        } catch {}
    }

    if ($chkMsg) {
        Write-Log "chkdsk result ($chkSource):"
        $chkSummary = if ($chkMsg.Length -gt 500) { $chkMsg.Substring(0,500) + '...' } else { $chkMsg }
        Write-Log "  $chkSummary"
        New-ItemProperty -Path $StateKey -Name 'ChkdskResult' -Value $chkSummary -PropertyType String -Force -EA SilentlyContinue | Out-Null
    } else {
        Write-Log 'WARN: No chkdsk event found -- check Event Viewer > Application > Chkdsk manually if needed'
        New-ItemProperty -Path $StateKey -Name 'ChkdskResult' -Value 'No event log entry found' -PropertyType String -Force -EA SilentlyContinue | Out-Null
    }

    # SFC /scannow
    Write-Log 'Running SFC /scannow (may take 10-20 min)...'
    $sfcStart = Get-Date
    $sfcOut   = & sfc /scannow 2>&1
    $sfcSec   = [int]((Get-Date) - $sfcStart).TotalSeconds
    Write-Log "SFC completed in ${sfcSec}s"

    # Parse via CBS.log (reliable plain text) then fall back to stdout
    $sfcResult = 'Unknown'
    $cbsLog    = "$env:SystemRoot\Logs\CBS\CBS.log"
    if (Test-Path $cbsLog) {
        try {
            $cbsText = [string]((Get-Content $cbsLog -EA SilentlyContinue | Select-Object -Last 200) -join ' ')
            if ($cbsText -match 'Did not find any integrity violations') { $sfcResult = 'No violations found' }
            elseif ($cbsText -match 'successfully repaired')             { $sfcResult = 'Corrupt files repaired' }
            elseif ($cbsText -match 'found corrupt files but was unable') { $sfcResult = 'Corrupt files found -- unable to repair (DISM will assist)' }
            elseif ($cbsText -match 'Cannot repair member file')          { $sfcResult = 'Some files could not be repaired -- check CBS.log' }
        } catch {}
    }
    if ($sfcResult -eq 'Unknown') {
        $sfcClean = ($sfcOut -join ' ') -replace '[^\x20-\x7E]',''
        if ($sfcClean -match 'no integrity violations')  { $sfcResult = 'No violations found' }
        elseif ($sfcClean -match 'successfully repaired') { $sfcResult = 'Corrupt files repaired' }
        elseif ($sfcClean -match 'unable to fix')         { $sfcResult = 'Corrupt files found -- unable to repair' }
        elseif ($sfcClean -match 'could not perform')     { $sfcResult = 'SFC could not run -- pending reboot required' }
    }

    Write-Log "SFC result: $sfcResult"
    New-ItemProperty -Path $StateKey -Name 'SFCResult' -Value $sfcResult -PropertyType String -Force -EA SilentlyContinue | Out-Null
    Set-State -Phase 3 -Note "SFC: $sfcResult"
    Write-Log 'Phase 2 complete. Advancing to Phase 3.'
}

# =============================================================================
# PHASE 3 -- DISM /RESTOREHEALTH
# =============================================================================
$currentPhase = Get-State
if ($currentPhase -eq 3) {
    Write-Separator
    Write-Log 'PHASE 3: DISM /Online /Cleanup-Image /RestoreHealth (may take 15-30 min)'
    Show-UserMessage -Message 'Disk repair Phase 3 of 5: Windows component repair (DISM) is now running. This may take 15-30 minutes. Please do NOT power off your PC.'

    $dismStart = Get-Date
    $dismLog   = "$LogDir\DISM.log"
    $lastPct   = -1

    $psi                        = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'dism.exe'
    $psi.Arguments              = "/Online /Cleanup-Image /RestoreHealth /LogPath:`"$dismLog`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $dismExit = -1

    try {
        $proc.Start() | Out-Null
        while (-not $proc.StandardOutput.EndOfStream) {
            $line = $proc.StandardOutput.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            Write-Log "  DISM: $line"
            if ($line -match '(\d+\.?\d*)%') {
                $pct = [int][double]$Matches[1]
                if ($pct -ne $lastPct -and ($pct % 10 -eq 0)) {
                    $elapsed = [int]((Get-Date) - $dismStart).TotalMinutes
                    Write-Log "  DISM progress: ${pct}% (${elapsed}m elapsed)"
                    $lastPct = $pct
                }
            }
        }
        $proc.WaitForExit()
        $dismExit = $proc.ExitCode
    } catch {
        Write-Log "ERROR: DISM process failed: $($_.Exception.Message)"
    }

    $dismSec    = [int]((Get-Date) - $dismStart).TotalSeconds
    $dismResult = switch ($dismExit) {
        0           { 'Success' }
        3017        { 'Success -- reboot required to complete repairs' }
        87          { 'Invalid parameter' }
        -2146498530 { 'Source files not found -- Windows Update may be needed' }
        -2146498528 { 'Component store corrupted -- manual repair needed' }
        740         { 'Elevation required' }
        default     { "Exit code $dismExit" }
    }

    Write-Log "DISM completed in ${dismSec}s. Result: $dismResult"
    New-ItemProperty -Path $StateKey -Name 'DISMResult' -Value $dismResult -PropertyType String -Force -EA SilentlyContinue | Out-Null
    Set-State -Phase 4 -Note "DISM: $dismResult"
    Write-Log 'Phase 3 complete. Advancing to Phase 4.'
}

# =============================================================================
# PHASE 4 -- DEFRAG / RETRIM
# =============================================================================
$currentPhase = Get-State
if ($currentPhase -eq 4) {
    Write-Separator
    Write-Log "PHASE 4: Drive optimization ($driveType)"
    Show-UserMessage -Message 'Disk repair Phase 4 of 5: Drive optimization is now running. Almost done! Please do NOT power off your PC.'

    $defragStart  = Get-Date
    $defragResult = 'Unknown'

    if ($driveType -eq 'SSD') {
        Write-Log 'SSD detected -- running retrim only (never full defrag on SSD)'
        try {
            $hasOptVol = $null -ne (Get-Command Optimize-Volume -EA SilentlyContinue)
            if ($hasOptVol) {
                Optimize-Volume -DriveLetter $Drive -ReTrim -EA SilentlyContinue
                $defragResult = 'SSD retrim complete'
            } else {
                & defrag.exe $DrivePath /X /U 2>&1 | ForEach-Object { if ($_) { Write-Log "  defrag: $_" } }
                $defragResult = 'SSD retrim complete (defrag.exe /X)'
            }
        } catch {
            $defragResult = "Retrim failed: $($_.Exception.Message)"
        }
    } else {
        Write-Log 'HDD/Unknown -- running full defrag'
        $psi2                        = New-Object System.Diagnostics.ProcessStartInfo
        $psi2.FileName               = 'defrag.exe'
        $psi2.Arguments              = "$DrivePath /U /V"
        $psi2.RedirectStandardOutput = $true
        $psi2.RedirectStandardError  = $true
        $psi2.UseShellExecute        = $false
        $psi2.CreateNoWindow         = $true

        $proc2 = New-Object System.Diagnostics.Process
        $proc2.StartInfo = $psi2
        $lastDefragPct   = -1

        try {
            $proc2.Start() | Out-Null
            while (-not $proc2.StandardOutput.EndOfStream) {
                $line = $proc2.StandardOutput.ReadLine()
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                Write-Log "  defrag: $line"
                if ($line -match 'Pass (\d+)') {
                    Write-Log "  Defrag pass $($Matches[1]) running..."
                } elseif ($line -match '(\d+)%') {
                    $pct = [int]$Matches[1]
                    if ($pct -ne $lastDefragPct -and ($pct % 20 -eq 0)) {
                        $elapsed = [int]((Get-Date) - $defragStart).TotalMinutes
                        Write-Log "  Defrag: ${pct}% (${elapsed}m elapsed)"
                        $lastDefragPct = $pct
                    }
                }
            }
            $proc2.WaitForExit()
            $defragResult = if ($proc2.ExitCode -eq 0) { 'Defrag complete' } else { "Defrag exit code $($proc2.ExitCode)" }
        } catch {
            $defragResult = "Defrag failed: $($_.Exception.Message)"
        }
    }

    $defragSec = [int]((Get-Date) - $defragStart).TotalSeconds
    Write-Log "Defrag/Retrim completed in ${defragSec}s. Result: $defragResult"
    New-ItemProperty -Path $StateKey -Name 'DefragResult' -Value $defragResult -PropertyType String -Force -EA SilentlyContinue | Out-Null
    Set-State -Phase 5 -Note "Defrag: $defragResult"
    Write-Log 'Phase 4 complete. Advancing to Phase 5.'
}

# =============================================================================
# PHASE 5 -- FINAL REPORT
# =============================================================================
$currentPhase = Get-State
if ($currentPhase -eq 5) {
    Write-Separator
    Write-Log 'PHASE 5: Final report'

    $sp           = Get-ItemProperty -Path $StateKey -EA SilentlyContinue
    $chkResult    = if ($null -ne $sp -and $sp.ChkdskResult) { $sp.ChkdskResult } else { 'N/A' }
    $sfcResult    = if ($null -ne $sp -and $sp.SFCResult)    { $sp.SFCResult    } else { 'N/A' }
    $dismResult   = if ($null -ne $sp -and $sp.DISMResult)   { $sp.DISMResult   } else { 'N/A' }
    $defragResult = if ($null -ne $sp -and $sp.DefragResult) { $sp.DefragResult } else { 'N/A' }

    Write-Separator
    Write-Log 'PALADIN DISK REPAIR SUITE -- FINAL REPORT'
    Write-Log "Drive       : $DrivePath ($driveType)"
    Write-Log "Completed   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log "Site        : $siteName"
    Write-Separator
    Write-Log "Chkdsk      : $chkResult"
    Write-Log "SFC         : $sfcResult"
    Write-Log "DISM        : $dismResult"
    Write-Log "Defrag/Trim : $defragResult"
    Write-Separator
    Write-Log "Full log    : $LogFile"
    Write-Separator

    # Remove resume task + script copy
    Remove-ResumeTask

    # Notify user complete
    Show-UserMessage -Message 'Disk maintenance is COMPLETE. Your PC is operating normally. A full report has been saved to C:\ProgramData\Paladin\DiskRepair\DiskRepair.log'

    # Clear state
    Clear-State
    Write-Log 'State cleared. Disk Repair Suite complete.'
    Write-Host ''
    Write-Host 'SUCCESS: Paladin Disk Repair Suite complete.'
    exit 0
}

# Unknown state -- clear and exit
Write-Log "ERROR: Unknown phase $currentPhase -- clearing state. Re-run to start from Phase 1."
Clear-State
exit 1
