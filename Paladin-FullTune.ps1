#Requires -Version 3.0
# =============================================================================
# Paladin Full System Tune [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 2.0.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
#
# SEQUENCE (all run in a single Datto job with full live output):
#   Stage 1 -- Disk Cleanup    (temp files, WU cache, junk -- no reboot)
#   Stage 2 -- PPM Optimize    (performance tweaks -- no reboot)
#   Stage 3 -- Disk Repair     (chkdsk scheduled + reboot at the very end)
#              chkdsk runs pre-boot, SFC/DISM/defrag run via resume task
#
# WHY THIS ORDER:
#   Stages 1-2 run fully inside the Datto job with live stdout.
#   Stage 3 ends with a reboot -- no further Datto output after that point.
#   chkdsk + SFC + DISM + defrag complete automatically post-reboot.
#
# INPUT VARIABLES (set in Datto component):
#   PPMTier -- String: Safe | Advanced | Experimental  (default: Safe)
#
# FILE ATTACHMENTS (upload to component in Datto):
#   Paladin-DiskClean.ps1
#   Paladin-DiskRepair.ps1
#   PPM-RMM-Safe.ps1  and/or  PPM-RMM-Advanced.ps1  and/or  PPM-RMM-Experimental.ps1
#
# LOG:  C:\ProgramData\Paladin\FullTune\FullTune.log
# EXIT: 0=Complete, 1=Fatal error
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$TuneDir  = 'C:\ProgramData\Paladin\FullTune'
$LogFile  = "$TuneDir\FullTune.log"
$MaxLogMB = 5

$PPMTier = $env:PPMTier
if ([string]::IsNullOrEmpty($PPMTier))              { $PPMTier = 'Safe' }
if ($PPMTier -notin @('Safe','Advanced','Experimental')) { $PPMTier = 'Safe' }

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
    # Copy all attached scripts from Datto package dir to fixed staging path
    $pkgDir = Split-Path $PSCommandPath -Parent
    Write-Log "Package dir: $pkgDir"

    if (-not (Test-Path $TuneDir)) {
        New-Item -Path $TuneDir -ItemType Directory -Force -EA Stop | Out-Null
    }

    $map = @{
        'Paladin-DiskClean.ps1'  = "$TuneDir\DiskClean.ps1"
        'Paladin-DiskRepair.ps1' = "$TuneDir\DiskRepair.ps1"
    }

    # PPM -- pick the right tier file
    $ppmNames = @("PPM-RMM-$PPMTier.ps1",'PPM-RMM-Safe.ps1','PPM-RMM-Advanced.ps1','PPM-RMM-Experimental.ps1')
    foreach ($pn in $ppmNames) {
        $candidate = Join-Path $pkgDir $pn
        if (Test-Path $candidate) {
            $map[$pn] = "$TuneDir\PPM-RMM.ps1"
            break
        }
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

$siteName = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }
$startTime = Get-Date

Write-Separator
Write-Log "Paladin Full System Tune v2.0.0 | Site: $siteName"
Write-Log "PPM Tier: $PPMTier"
Write-Log "Sequence: Cleanup -> PPM -> Disk Repair (reboot at end)"
Write-Log "Log: $LogFile"
Write-Separator

# Stage scripts from Datto package dir
Write-Log 'Staging scripts...'
$missing = Stage-Scripts
if ($missing.Count -gt 0) {
    Write-Log "ERROR: Missing required scripts: $($missing -join ', ')" 'ERROR'
    Write-Log 'Ensure all scripts are uploaded as File Attachments on this component.'
    exit 1
}

# =============================================================================
# STAGE 1 -- DISK CLEANUP
# =============================================================================
Write-Separator
Write-Log 'STAGE 1/3: Disk Cleanup'
Write-Log 'Removing junk files, temp data, WU cache, recycle bin...'

$cleanExit = Invoke-Stage -Path "$TuneDir\DiskClean.ps1" -Label 'DiskClean'
$cleanResult = if ($cleanExit -eq 0) { 'Complete' } else { "Exit $cleanExit (non-fatal)" }
Write-Log "Stage 1 result: $cleanResult"

# Brief pause between stages
Start-Sleep -Seconds 10

# =============================================================================
# STAGE 2 -- PPM OPTIMIZATION
# =============================================================================
Write-Separator
Write-Log "STAGE 2/3: PPM Performance Optimization (Tier: $PPMTier)"
Write-Log 'Applying registry + system performance tweaks...'

$ppmExit = Invoke-Stage -Path "$TuneDir\PPM-RMM.ps1" -Label "PPM-$PPMTier"
$ppmResult = if ($ppmExit -eq 0) { 'Complete' } else { "Exit $ppmExit (non-fatal)" }
Write-Log "Stage 2 result: $ppmResult"

# Brief pause between stages
Start-Sleep -Seconds 10

# =============================================================================
# STAGE 3 -- DISK REPAIR (reboot at end)
# =============================================================================
Write-Separator
Write-Log 'STAGE 3/3: Disk Repair'
Write-Log 'Scheduling chkdsk, SFC, DISM, defrag...'
Write-Log 'NOTE: This stage ends with a reboot. Repair continues automatically post-boot.'
Write-Log '      chkdsk runs pre-boot, then SFC + DISM + defrag run via scheduled task.'
Write-Log "      Full repair log: C:\ProgramData\Paladin\DiskRepair\DiskRepair.log"

$repairExit = Invoke-Stage -Path "$TuneDir\DiskRepair.ps1" -Label 'DiskRepair'
$repairResult = if ($repairExit -eq 0) { 'Scheduled -- rebooting' } else { "Exit $repairExit" }
Write-Log "Stage 3 result: $repairResult"

# =============================================================================
# FINAL SUMMARY (printed before reboot fires)
# =============================================================================
$elapsed = [int]((Get-Date) - $startTime).TotalMinutes
Write-Separator
Write-Log 'PALADIN FULL SYSTEM TUNE -- SUMMARY'
Write-Log "Site        : $siteName"
Write-Log "PPM Tier    : $PPMTier"
Write-Log "Duration    : ${elapsed} minutes"
Write-Separator
Write-Log "Stage 1 -- Disk Cleanup  : $cleanResult"
Write-Log "Stage 2 -- PPM Optimize  : $ppmResult"
Write-Log "Stage 3 -- Disk Repair   : $repairResult"
Write-Separator
Write-Log 'Machine is rebooting now for chkdsk.'
Write-Log 'SFC + DISM + defrag will complete automatically after reboot.'
Write-Log "Check repair log post-reboot: C:\ProgramData\Paladin\DiskRepair\DiskRepair.log"
Write-Separator

Write-Host ''
Write-Host 'SUCCESS: Stages 1-2 complete. Stage 3 repair running post-reboot.'
exit 0
