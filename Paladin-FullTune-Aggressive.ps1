#Requires -Version 3.0
# =============================================================================
# Paladin Full System Tune -- AGGRESSIVE [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
#
# SEQUENCE (all run in a single Datto job with full live output):
#   Stage 1 -- Browser Reset        (factory reset all browsers, preserve passwords)
#   Stage 2 -- Disk Cleanup Desp.   (desperation mode -- maximum safe space recovery)
#   Stage 3 -- PPM Advanced         (full performance optimization suite)
#   Stage 4 -- Disk Repair          (chkdsk + SFC + DISM + defrag -- reboot at end)
#
# USE WHEN:
#   Systems with heavy browser cruft, critically low disk space (95%+),
#   or machines that need a full aggressive tune from top to bottom.
#
# FILE ATTACHMENTS (upload to component in Datto):
#   Paladin-BrowserReset.ps1              <- v2.0.0 factory reset version
#   Paladin-DiskClean-DesperationMode.ps1
#   Paladin-DiskRepair.ps1
#   PPM-RMM-Advanced.ps1
#
# INPUT VARIABLES: None.
# LOG:  C:\ProgramData\Paladin\FullTune\FullTune-Aggressive.log
# EXIT: 0=Complete, 1=Fatal error
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$TuneDir  = 'C:\ProgramData\Paladin\FullTune'
$LogFile  = "$TuneDir\FullTune-Aggressive.log"
$MaxLogMB = 5

# =============================================================================
# HELPERS
# =============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try {
        if (-not (Test-Path $TuneDir)) {
            New-Item -Path $TuneDir -ItemType Directory -Force -EA Stop | Out-Null
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

function Invoke-Stage {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) {
        Write-Log "ERROR: Script not found: $Path" 'ERROR'
        return 1
    }
    Write-Log "Running: $Label"
    Write-Log "  Path: $Path"
    try {
        & powershell.exe -NonInteractive -ExecutionPolicy Bypass -File $Path 2>&1 |
            ForEach-Object { Write-Log "  [$Label] $_" }
        $code = $LASTEXITCODE
        Write-Log "$Label finished. Exit: $code"
        return $code
    } catch {
        Write-Log "ERROR: $Label exception -- $($_.Exception.Message)" 'ERROR'
        return 1
    }
}

function Stage-Scripts {
    $pkgDir = Split-Path $PSCommandPath -Parent
    Write-Log "Package dir: $pkgDir"

    if (-not (Test-Path $TuneDir)) {
        New-Item -Path $TuneDir -ItemType Directory -Force -EA Stop | Out-Null
    }

    # Map attachment filename -> staged path
    $map = @{
        'Paladin-BrowserReset.ps1'              = "$TuneDir\BrowserReset.ps1"
        'Paladin-DiskClean-DesperationMode.ps1' = "$TuneDir\DiskClean-Desp.ps1"
        'PPM-RMM-Advanced.ps1'                  = "$TuneDir\PPM-RMM.ps1"
        'Paladin-DiskRepair.ps1'                = "$TuneDir\DiskRepair.ps1"
    }

    $missing = @()
    foreach ($fname in $map.Keys) {
        $dest = $map[$fname]
        $src  = Join-Path $pkgDir $fname
        if (Test-Path $src) {
            Copy-Item -LiteralPath $src -Destination $dest -Force -EA SilentlyContinue
            Write-Log "  Staged: $fname"
        } elseif (Test-Path $dest) {
            Write-Log "  Using cached: $dest"
        } else {
            Write-Log "  MISSING: $fname" 'ERROR'
            $missing += $fname
        }
    }
    return $missing
}

# =============================================================================
# STARTUP
# =============================================================================
if (-not (Test-Path $TuneDir)) {
    New-Item -Path $TuneDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null
}

$siteName  = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }
$startTime = Get-Date

Write-Separator
Write-Log "Paladin Full System Tune -- AGGRESSIVE v1.0.0 | Site: $siteName"
Write-Log "Sequence: Browser Reset -> Desperation Cleanup -> PPM Advanced -> Disk Repair"
Write-Log "Log: $LogFile"
Write-Separator

# Stage scripts
Write-Log 'Staging scripts...'
$missing = Stage-Scripts
if ($missing.Count -gt 0) {
    Write-Log "ERROR: Missing required attachments: $($missing -join ', ')" 'ERROR'
    Write-Log 'Upload all four scripts as File Attachments on this component in Datto.'
    exit 1
}

# =============================================================================
# STAGE 1 -- BROWSER RESET
# =============================================================================
Write-Separator
Write-Log 'STAGE 1/4: Browser Factory Reset'
Write-Log 'Resetting Chrome, Edge, Brave, Firefox, Waterfox, LibreWolf, Opera, Vivaldi...'
Write-Log 'Passwords, history, and bookmarks will be preserved.'

$browserExit   = Invoke-Stage -Path "$TuneDir\BrowserReset.ps1"   -Label 'BrowserReset'
$browserResult = if ($browserExit -eq 0) { 'Complete' } else { "Exit $browserExit (non-fatal)" }
Write-Log "Stage 1 result: $browserResult"
Start-Sleep -Seconds 10

# =============================================================================
# STAGE 2 -- DESPERATION MODE DISK CLEANUP
# =============================================================================
Write-Separator
Write-Log 'STAGE 2/4: Disk Cleanup -- Desperation Mode'
Write-Log 'Maximum safe space recovery: temp, WU cache, IIS logs, SQL logs, hiberfil, shadows report...'

$cleanExit   = Invoke-Stage -Path "$TuneDir\DiskClean-Desp.ps1" -Label 'DiskClean-Desp'
$cleanResult = if ($cleanExit -eq 0) { 'Complete' } else { "Exit $cleanExit (non-fatal)" }
Write-Log "Stage 2 result: $cleanResult"
Start-Sleep -Seconds 10

# =============================================================================
# STAGE 3 -- PPM ADVANCED
# =============================================================================
Write-Separator
Write-Log 'STAGE 3/4: PPM Performance Optimization (Advanced Tier)'
Write-Log 'Power plan, CPU tuning, HAGS, RSS, BypassIO, Large Pages, IFEO Boost, TRIM...'

$ppmExit   = Invoke-Stage -Path "$TuneDir\PPM-RMM.ps1" -Label 'PPM-Advanced'
$ppmResult = if ($ppmExit -eq 0) { 'Complete' } else { "Exit $ppmExit (non-fatal)" }
Write-Log "Stage 3 result: $ppmResult"
Start-Sleep -Seconds 10

# =============================================================================
# STAGE 4 -- DISK REPAIR (reboot at end)
# =============================================================================
Write-Separator
Write-Log 'STAGE 4/4: Disk Repair'
Write-Log 'Scheduling chkdsk, SFC, DISM, defrag...'
Write-Log 'NOTE: Machine will reboot at end of this stage.'
Write-Log '      Repair continues automatically post-boot via scheduled task.'
Write-Log "      Repair log: C:\ProgramData\Paladin\DiskRepair\DiskRepair.log"

$repairExit   = Invoke-Stage -Path "$TuneDir\DiskRepair.ps1" -Label 'DiskRepair'
$repairResult = if ($repairExit -eq 0) { 'Scheduled -- rebooting' } else { "Exit $repairExit" }
Write-Log "Stage 4 result: $repairResult"

# =============================================================================
# FINAL SUMMARY
# =============================================================================
$elapsed = [int]((Get-Date) - $startTime).TotalMinutes
Write-Separator
Write-Log 'PALADIN FULL SYSTEM TUNE AGGRESSIVE -- SUMMARY'
Write-Log "Site        : $siteName"
Write-Log "Completed   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Duration    : ${elapsed} minutes"
Write-Separator
Write-Log "Stage 1 -- Browser Reset     : $browserResult"
Write-Log "Stage 2 -- Desperation Clean : $cleanResult"
Write-Log "Stage 3 -- PPM Advanced      : $ppmResult"
Write-Log "Stage 4 -- Disk Repair       : $repairResult"
Write-Separator
Write-Log 'Machine is rebooting for chkdsk.'
Write-Log 'SFC + DISM + defrag complete automatically after reboot.'
Write-Log "Repair log: C:\ProgramData\Paladin\DiskRepair\DiskRepair.log"
Write-Separator

Write-Host ''
Write-Host 'SUCCESS: Paladin Full System Tune Aggressive complete. Rebooting for disk repair.'
exit 0
