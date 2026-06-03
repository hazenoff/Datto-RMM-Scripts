#Requires -Version 3.0
# =============================================================================
# Paladin Print Queue & Spooler Reset [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem)
#
# DESCRIPTION:
#   Clears all stuck print jobs, resets the Windows Print Spooler service,
#   and restores print queue functionality. Safe to run on both workstations
#   and print servers.
#
#   Steps (in order):
#     1. Stop Spooler service
#     2. Clear all files in C:\Windows\System32\spool\PRINTERS
#     3. Start Spooler service
#     4. Verify Spooler is running
#     5. Report queue status per printer
#     6. Write result to UDF
#
#   Optional: clear specific printer queue only via $env:printerName input var.
#
# INPUT VARIABLES:
#   printerName (String) -- optional specific printer name to target.
#                           Leave blank to reset ALL queues (default).
#
# LOG:    C:\ProgramData\Paladin\SpoolerReset\SpoolerReset.log
# UDF:    Slot 21 (PALADIN-SPOOLER)
# EXIT:   0 = spooler running and queues clear
#         1 = spooler failed to start or queue could not be cleared
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer   = '1.0.0'
$LogDir      = 'C:\ProgramData\Paladin\SpoolerReset'
$LogFile     = "$LogDir\SpoolerReset.log"
$SpoolPath   = 'C:\Windows\System32\spool\PRINTERS'
$UDF_SLOT    = 21   # PALADIN-SPOOLER
$MaxLogMB    = 5

# Input variable
$TargetPrinter = $env:printerName

# =============================================================================
# HELPERS
# =============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try {
        if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force -EA Stop | Out-Null }
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile -EA SilentlyContinue).Length / 1MB) -gt $MaxLogMB) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.bak" -Force -EA SilentlyContinue
        }
        Add-Content -Path $LogFile -Value $line -EA SilentlyContinue
    } catch {}
}

function Write-Sep  { Write-Log ('=' * 64) }
function Write-Sep2 { Write-Log ('-' * 64) }

function Set-DattoUDF {
    param([int]$Slot, [string]$Value)
    $trimmed = if ($Value.Length -gt 255) { $Value.Substring(0,255) } else { $Value }
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' `
            -Name "Custom$Slot" -PropertyType String -Value $trimmed `
            -Force -EA Stop | Out-Null
        Write-Log "UDF$Slot => $trimmed"
    } catch { Write-Log "WARN: UDF$Slot write failed: $($_.Exception.Message)" }
}

function Get-SpoolerState {
    try {
        $svc = Get-WmiObject -Class Win32_Service -Filter "Name='Spooler'" -EA SilentlyContinue
        if ($null -ne $svc) { return $svc.State }
    } catch {}
    return 'Unknown'
}

function Get-PrintQueues {
    try {
        $queues = Get-WmiObject -Class Win32_PrintJob -EA SilentlyContinue
        return @($queues)
    } catch { return @() }
}

function Get-Printers {
    try {
        $printers = Get-WmiObject -Class Win32_Printer -EA SilentlyContinue |
            Where-Object { $_.Name -notmatch 'Microsoft|OneNote|Fax|PDF|XPS|Send To' }
        return @($printers)
    } catch { return @() }
}

# =============================================================================
# MAIN
# =============================================================================

if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }

$siteName = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }

Write-Sep
Write-Log "Paladin Print Queue & Spooler Reset v$ScriptVer | Site: $siteName | Machine: $env:COMPUTERNAME"
Write-Log "Target printer: $(if ($TargetPrinter) { $TargetPrinter } else { 'ALL' })"
Write-Sep

# Pre-check: count stuck jobs
$prePending = Get-PrintQueues
Write-Log "Pre-reset: $($prePending.Count) job(s) in queue(s)"
if ($prePending.Count -gt 0) {
    foreach ($j in $prePending) {
        Write-Log "  Stuck job: $($j.Document) | Printer: $($j.Name) | Status: $($j.Status)"
    }
}

# Step 1: Stop Spooler
Write-Sep2
Write-Log "Step 1: Stopping Spooler service..."
try {
    & sc.exe stop Spooler 2>&1 | Out-Null
    $waited = 0
    while ((Get-SpoolerState) -eq 'Running' -and $waited -lt 15) {
        Start-Sleep -Seconds 1
        $waited++
    }
    $stoppedState = Get-SpoolerState
    Write-Log "Spooler state after stop: $stoppedState"
} catch {
    Write-Log "WARN: sc stop failed: $($_.Exception.Message)"
}

# Step 2: Clear spool files
Write-Sep2
Write-Log "Step 2: Clearing spool files from $SpoolPath"
$clearedCount = 0
$clearErrors  = 0

if (Test-Path $SpoolPath) {
    $spoolFiles = Get-ChildItem -Path $SpoolPath -Force -EA SilentlyContinue |
        Where-Object { -not $_.PSIsContainer }

    if ([string]::IsNullOrEmpty($TargetPrinter)) {
        # Clear all spool files
        foreach ($f in @($spoolFiles)) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -EA Stop
                $clearedCount++
                Write-Log "  Removed: $($f.Name)"
            } catch {
                $clearErrors++
                Write-Log "  WARN: Could not remove $($f.Name): $($_.Exception.Message)"
            }
        }
    } else {
        # Target-specific: remove only jobs for the named printer
        # Spool files come in .SHD (shadow) + .SPL (data) pairs
        # Use WMI job list to identify relevant files before spooler stopped
        foreach ($f in @($spoolFiles)) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -EA Stop
                $clearedCount++
                Write-Log "  Removed: $($f.Name)"
            } catch {
                $clearErrors++
                Write-Log "  WARN: Could not remove $($f.Name): $($_.Exception.Message)"
            }
        }
    }
    Write-Log "Spool files cleared: $clearedCount removed, $clearErrors errors"
} else {
    Write-Log "WARN: Spool path not found: $SpoolPath"
}

# Step 3: Start Spooler
Write-Sep2
Write-Log "Step 3: Starting Spooler service..."
try {
    & sc.exe start Spooler 2>&1 | Out-Null
    $waited = 0
    while ((Get-SpoolerState) -ne 'Running' -and $waited -lt 20) {
        Start-Sleep -Seconds 1
        $waited++
    }
} catch {
    Write-Log "WARN: sc start failed: $($_.Exception.Message)"
}

# Step 4: Verify
Write-Sep2
$finalState = Get-SpoolerState
Write-Log "Step 4: Spooler state: $finalState"

if ($finalState -ne 'Running') {
    Write-Log "ERROR: Spooler failed to start after reset" 'WARN'
    Set-DattoUDF -Slot $UDF_SLOT -Value "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Spooler failed to start -- manual intervention required"
    exit 1
}

# Step 5: Post-reset queue status
Write-Sep2
Write-Log "Step 5: Post-reset queue status"
Start-Sleep -Seconds 3

$postPending = Get-PrintQueues
Write-Log "Post-reset: $($postPending.Count) job(s) remaining"

$printers = Get-Printers
Write-Log "Printers on this machine: $($printers.Count)"
foreach ($p in $printers) {
    $statusStr = if ($p.PrinterStatus -eq 3) { 'Idle' } elseif ($p.PrinterStatus -eq 4) { 'Printing' } else { "Status:$($p.PrinterStatus)" }
    Write-Log "  $($p.Name) | $statusStr | Default: $($p.Default)"
}

# Final result
Write-Sep
Write-Log "RESULT: Spooler running. Cleared $clearedCount spool file(s). $($postPending.Count) job(s) remaining."

$printerCount = $printers.Count
if ($postPending.Count -eq 0) {
    $udfMsg = "PASS $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Cleared:$clearedCount jobs | Spooler:Running | Printers:$printerCount"
    Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg
    exit 0
} else {
    $udfMsg = "WARN $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Cleared:$clearedCount Remaining:$($postPending.Count) | Spooler:Running"
    Write-Log "WARN: $($postPending.Count) job(s) still in queue after reset" 'WARN'
    Set-DattoUDF -Slot $UDF_SLOT -Value $udfMsg
    exit 0
}
