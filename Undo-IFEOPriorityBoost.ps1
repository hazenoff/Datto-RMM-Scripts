#Requires -Version 3.0
<#
.SYNOPSIS
    Undo IFEO Priority Boost -- Run as Administrator
    Paladin Business Consulting

.DESCRIPTION
    Reverses all changes made by Set-IFEOPriorityBoost.ps1.
    Restores original IFEO PerfOptions values, or removes the key
    entirely if it did not exist before the boost was applied.

    Paladin Business Consulting | Version: 1.0.0
#>

#Requires -RunAsAdministrator

$SENTINEL  = 0xFF
$ifeoBase  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$backupKey = 'HKLM:\SOFTWARE\Paladin\IFEOPriorityBoost'

$targetExes = @(
    'chrome.exe', 'msedge.exe', 'brave.exe', 'vivaldi.exe',
    'opera.exe',  'chromium.exe',
    'firefox.exe', 'waterfox.exe', 'librewolf.exe',
    'WINWORD.EXE', 'EXCEL.EXE', 'POWERPNT.EXE', 'OUTLOOK.EXE',
    'ONENOTE.EXE', 'MSACCESS.EXE', 'MSPUB.EXE', 'VISIO.EXE',
    'TEAMS.EXE', 'ms-teams.exe',
    'QBW32.exe', 'QBW64.exe', 'QBDBMgrN.exe', 'qbupdate.exe',
        # Autodesk / AutoCAD suite
        'acad.exe',           # AutoCAD (all verticals)
        'Revit.exe',          # Revit
        'Inventor.exe',       # Inventor / Inventor Professional
        '3dsmax.exe',         # 3ds Max
        'maya.exe',           # Maya
        'navisworks.exe',     # Navisworks Manage / Simulate
        'fusion360.exe',      # Fusion 360
        'motionbuilder.exe',  # MotionBuilder
        'mudbox.exe',         # Mudbox
        'recap.exe',          # ReCap Pro
        'vred.exe'            # VRED Professional / Design
)

$ok = 0; $skip = 0; $errors = 0

Write-Host '======================================================='
Write-Host ' Paladin IFEO Priority Boost -- UNDO'
Write-Host ' Restoring original priority settings'
Write-Host '======================================================='
Write-Host ''

if (-not (Test-Path $backupKey)) {
    Write-Host 'WARN: Backup key not found -- nothing to restore.'
    Write-Host "      ($backupKey)"
    Write-Host ''
    Write-Host 'If Set-IFEOPriorityBoost.ps1 was never run, no action needed.'
    exit 0
}

foreach ($exe in $targetExes) {
    $ifeoPerfKey = "$ifeoBase\$exe\PerfOptions"

    if (-not (Test-Path $ifeoPerfKey)) {
        Write-Host "  [Skip] $exe -- PerfOptions not present"
        $skip++
        continue
    }

    try {
        $backupCpu = (Get-ItemProperty -Path $backupKey -Name "${exe}_Cpu" -EA SilentlyContinue)."${exe}_Cpu"
        $backupIo  = (Get-ItemProperty -Path $backupKey -Name "${exe}_Io"  -EA SilentlyContinue)."${exe}_Io"

        if ($null -eq $backupCpu -or $backupCpu -eq $SENTINEL) {
            # PerfOptions did not exist before -- remove it entirely
            Remove-Item -Path $ifeoPerfKey -Recurse -Force -EA SilentlyContinue

            # Clean up empty IFEO\<exe> parent if we created it
            $parentKey = Split-Path $ifeoPerfKey -Parent
            $children  = Get-ChildItem -Path $parentKey -EA SilentlyContinue
            $props     = Get-ItemProperty -Path $parentKey -EA SilentlyContinue |
                         Get-Member -MemberType NoteProperty |
                         Where-Object { $_.Name -notmatch '^PS' }
            if ((-not $children) -and (-not $props)) {
                Remove-Item -Path $parentKey -Recurse -Force -EA SilentlyContinue
            }
            Write-Host "  [OK] $exe -- PerfOptions removed (Windows default restored)"
        } else {
            Set-ItemProperty -Path $ifeoPerfKey -Name 'CpuPriorityClass' -Value $backupCpu -Type DWord -EA Stop
            Set-ItemProperty -Path $ifeoPerfKey -Name 'IoPriority'       -Value $backupIo  -Type DWord -EA Stop
            Write-Host "  [OK] $exe -- restored (CpuPriority=$backupCpu IoPriority=$backupIo)"
        }
        $ok++
    } catch {
        Write-Host "  [ERROR] $exe -- $($_.Exception.Message)"
        $errors++
    }
}

# Remove backup key if clean
if ($errors -eq 0) {
    Remove-Item -Path $backupKey -Recurse -Force -EA SilentlyContinue
    Write-Host ''
    Write-Host '  Backup key removed.'
}

Write-Host ''
Write-Host '======================================================='
Write-Host "  Restored: $ok    Skipped: $skip    Errors: $errors"
Write-Host '======================================================='

if ($errors -eq 0) {
    Write-Host 'SUCCESS: All IFEO priority settings restored to Windows defaults.'
} else {
    Write-Host "COMPLETED WITH ERRORS: $errors EXE(s) failed. Review output above."
}
