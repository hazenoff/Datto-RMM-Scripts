#Requires -Version 3.0
<#
.SYNOPSIS
    IFEO Priority Boost [WIN]
    Paladin Business Consulting | Datto RMM Component

.DESCRIPTION
    Permanently sets Above Normal CPU priority and High I/O priority for
    browsers, Microsoft Office, and QuickBooks via Image File Execution
    Options (IFEO) PerfOptions registry keys.

    Effect applies every time Windows launches the target EXE, regardless
    of how it is started (double-click, shortcut, script, etc).
    No watcher process required. Survives reboots indefinitely.

    Set component variable UndoMode = true to restore all originals.

    WRITES (per target EXE):
      HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\
        Image File Execution Options\<exe>\PerfOptions
          CpuPriorityClass = 5  (Above Normal)
          IoPriority       = 3  (High)

    BACKUP (for Undo):
      HKLM:\SOFTWARE\Paladin\PPM\IFEOPriorityBoost

    TARGET EXEs (26):
      Browsers  : chrome, msedge, brave, vivaldi, opera, chromium,
                  firefox, waterfox, librewolf
      Office    : WINWORD, EXCEL, POWERPNT, OUTLOOK, ONENOTE,
                  MSACCESS, MSPUB, VISIO, TEAMS, ms-teams
      QuickBooks: QBW32, QBW64, QBDBMgrN, qbupdate

    NEVER touches user data, profiles, or application files.

    Paladin Business Consulting | Internal Use Only
    Version: 1.0.0 | Min OS: Windows 10 / Server 2016
#>

# ===========================================================================
# DATTO INPUT VARIABLE
# Set UndoMode = true in the component to remove all IFEO entries and restore
# original values. Default = false (apply boost).
# ===========================================================================
$UndoMode = $false
if ($env:UndoMode -eq 'true' -or $env:UndoMode -eq '1') { $UndoMode = $true }

# ===========================================================================
# CONSTANTS
# ===========================================================================
# CpuPriorityClass: 1=Idle 2=Normal 3=High 5=AboveNormal 6=BelowNormal
$CPU_ABOVE_NORMAL = 5
$IO_HIGH          = 3
$SENTINEL         = 0xFF   # Marks "key did not exist before" in backup

$ifeoBase  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$backupKey = 'HKLM:\SOFTWARE\Paladin\PPM\IFEOPriorityBoost'

$targetExes = @(
    # Chromium-engine browsers
    'chrome.exe',
    'msedge.exe',
    'brave.exe',
    'vivaldi.exe',
    'opera.exe',
    'chromium.exe',
    # Firefox-engine browsers
    'firefox.exe',
    'waterfox.exe',
    'librewolf.exe',
    # Microsoft Office
    'WINWORD.EXE',
    'EXCEL.EXE',
    'POWERPNT.EXE',
    'OUTLOOK.EXE',
    'ONENOTE.EXE',
    'MSACCESS.EXE',
    'MSPUB.EXE',
    'VISIO.EXE',
    'TEAMS.EXE',
    'ms-teams.exe',
    # QuickBooks
    'QBW32.exe',
    'QBW64.exe',
    'QBDBMgrN.exe',
    'qbupdate.exe',
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

# ===========================================================================
# MAIN
# ===========================================================================
$ok     = 0
$skip   = 0
$errors = 0

Write-Host '======================================================='
Write-Host ' Paladin IFEO Priority Boost v1.0.0'
Write-Host ' Datto RMM | NT AUTHORITY\SYSTEM'
Write-Host '======================================================='
Write-Host "  Mode   : $(if ($UndoMode) { 'UNDO -- restoring originals' } else { 'APPLY -- setting Above Normal' })"
Write-Host "  Targets: $($targetExes.Count) EXEs"
Write-Host ''

# Ensure backup key exists
if (-not (Test-Path $backupKey)) {
    try {
        New-Item -Path $backupKey -Force -EA Stop | Out-Null
    } catch {
        Write-Host "ERROR: Could not create backup key: $($_.Exception.Message)"
        exit 1
    }
}

foreach ($exe in $targetExes) {
    $ifeoPerfKey = "$ifeoBase\$exe\PerfOptions"

    if (-not $UndoMode) {
        # ---- APPLY ----
        try {
            # Read and back up existing values before writing
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

            # Create PerfOptions key if needed and write values
            if (-not (Test-Path $ifeoPerfKey)) {
                New-Item -Path $ifeoPerfKey -Force -EA Stop | Out-Null
            }

            Set-ItemProperty -Path $ifeoPerfKey -Name 'CpuPriorityClass' -Value $CPU_ABOVE_NORMAL -Type DWord -EA Stop
            Set-ItemProperty -Path $ifeoPerfKey -Name 'IoPriority'       -Value $IO_HIGH          -Type DWord -EA Stop

            Write-Host "  [OK] $exe -- CpuPriority=AboveNormal IoPriority=High"
            $ok++
        } catch {
            Write-Host "  [ERROR] $exe -- $($_.Exception.Message)"
            $errors++
        }

    } else {
        # ---- UNDO ----
        try {
            $backupCpu = (Get-ItemProperty -Path $backupKey -Name "${exe}_Cpu" -EA SilentlyContinue)."${exe}_Cpu"
            $backupIo  = (Get-ItemProperty -Path $backupKey -Name "${exe}_Io"  -EA SilentlyContinue)."${exe}_Io"

            if (Test-Path $ifeoPerfKey) {
                if ($null -eq $backupCpu -or $backupCpu -eq $SENTINEL) {
                    # PerfOptions did not exist before -- remove it
                    Remove-Item -Path $ifeoPerfKey -Recurse -Force -EA SilentlyContinue

                    # Clean up empty IFEO\<exe> parent key if we created it
                    $parentKey = Split-Path $ifeoPerfKey -Parent
                    $children  = Get-ChildItem -Path $parentKey -EA SilentlyContinue
                    $props     = Get-ItemProperty -Path $parentKey -EA SilentlyContinue |
                                 Get-Member -MemberType NoteProperty |
                                 Where-Object { $_.Name -notmatch '^PS' }
                    if ((-not $children) -and (-not $props)) {
                        Remove-Item -Path $parentKey -Recurse -Force -EA SilentlyContinue
                    }
                    Write-Host "  [OK] $exe -- PerfOptions removed (restored to Windows default)"
                } else {
                    # Restore original values
                    Set-ItemProperty -Path $ifeoPerfKey -Name 'CpuPriorityClass' -Value $backupCpu -Type DWord -EA SilentlyContinue
                    Set-ItemProperty -Path $ifeoPerfKey -Name 'IoPriority'       -Value $backupIo  -Type DWord -EA SilentlyContinue
                    Write-Host "  [OK] $exe -- restored CpuPriority=$backupCpu IoPriority=$backupIo"
                }
            } else {
                Write-Host "  [Skip] $exe -- PerfOptions not present, nothing to restore"
                $skip++
                continue
            }
            $ok++
        } catch {
            Write-Host "  [ERROR] $exe -- $($_.Exception.Message)"
            $errors++
        }
    }
}

# Remove backup key after successful undo
if ($UndoMode -and $errors -eq 0) {
    Remove-Item -Path $backupKey -Recurse -Force -EA SilentlyContinue
    Write-Host ''
    Write-Host '  Backup key removed -- IFEO fully restored.'
}

# ===========================================================================
# RESULT
# ===========================================================================
Write-Host ''
Write-Host '======================================================='
Write-Host "  OK     : $ok"
Write-Host "  Skipped: $skip"
Write-Host "  Errors : $errors"
Write-Host '======================================================='

if ($errors -eq 0) {
    $action = if ($UndoMode) { 'UNDO complete' } else { 'APPLY complete' }
    Write-Host "SUCCESS: $action -- $ok EXEs processed."
    exit 0
} else {
    Write-Host "COMPLETE WITH ERRORS: $errors EXE(s) failed. Review output above."
    exit 1
}
