#Requires -Version 3.0
<#
.SYNOPSIS
    Set IFEO Priority Boost -- Run as Administrator
    Paladin Business Consulting

.DESCRIPTION
    Permanently sets Above Normal CPU priority and High I/O priority for
    browsers, Microsoft Office, and QuickBooks via Windows Image File
    Execution Options (IFEO) PerfOptions registry keys.

    Effect applies every time Windows launches a target EXE, regardless
    of how it is started. Survives reboots. No background process required.

    Run Undo-IFEOPriorityBoost.ps1 to fully reverse all changes.

    Paladin Business Consulting | Version: 1.0.0
#>

#Requires -RunAsAdministrator

$CPU_ABOVE_NORMAL = 5
$IO_HIGH          = 3
$SENTINEL         = 0xFF

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
Write-Host ' Paladin IFEO Priority Boost -- APPLY'
Write-Host ' Sets Above Normal priority for browsers, Office, QB'
Write-Host '======================================================='
Write-Host ''

if (-not (Test-Path $backupKey)) {
    New-Item -Path $backupKey -Force -EA Stop | Out-Null
}

foreach ($exe in $targetExes) {
    $ifeoPerfKey = "$ifeoBase\$exe\PerfOptions"
    try {
        $existingCpu = $null
        $existingIo  = $null
        if (Test-Path $ifeoPerfKey) {
            $existingCpu = (Get-ItemProperty -Path $ifeoPerfKey -Name 'CpuPriorityClass' -EA SilentlyContinue).CpuPriorityClass
            $existingIo  = (Get-ItemProperty -Path $ifeoPerfKey -Name 'IoPriority'       -EA SilentlyContinue).IoPriority
        }

        $backupCpu = if ($null -ne $existingCpu) { $existingCpu } else { $SENTINEL }
        $backupIo  = if ($null -ne $existingIo)  { $existingIo  } else { $SENTINEL }

        Set-ItemProperty -Path $backupKey -Name "${exe}_Cpu" -Value $backupCpu -Type DWord -EA SilentlyContinue
        Set-ItemProperty -Path $backupKey -Name "${exe}_Io"  -Value $backupIo  -Type DWord -EA SilentlyContinue

        if (-not (Test-Path $ifeoPerfKey)) {
            New-Item -Path $ifeoPerfKey -Force -EA Stop | Out-Null
        }

        Set-ItemProperty -Path $ifeoPerfKey -Name 'CpuPriorityClass' -Value $CPU_ABOVE_NORMAL -Type DWord -EA Stop
        Set-ItemProperty -Path $ifeoPerfKey -Name 'IoPriority'       -Value $IO_HIGH          -Type DWord -EA Stop

        Write-Host "  [OK] $exe"
        $ok++
    } catch {
        Write-Host "  [ERROR] $exe -- $($_.Exception.Message)"
        $errors++
    }
}

Write-Host ''
Write-Host '======================================================='
Write-Host "  Applied : $ok    Errors: $errors"
Write-Host '======================================================='

if ($errors -eq 0) {
    Write-Host 'SUCCESS: Above Normal priority set for all target EXEs.'
    Write-Host 'Changes are permanent and survive reboots.'
    Write-Host 'Run Undo-IFEOPriorityBoost.ps1 to reverse.'
} else {
    Write-Host "COMPLETED WITH ERRORS: $errors EXE(s) failed. Review output above."
}
