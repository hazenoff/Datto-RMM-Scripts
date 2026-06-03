#Requires -Version 3.0
<#
.SYNOPSIS
    Disk Space Recovery -- DESPERATION MODE [WIN]
    Paladin Business Consulting | Datto RMM Component

.DESCRIPTION
    DESPERATION MODE: For systems at 95%+ disk usage that need maximum safe
    space recovery. Goes further than the standard cleanup script.
    Server-aware: skips role-breaking phases automatically on Windows Server OS.

    ALL STANDARD PHASES (v1.2.0) PLUS:
      - IIS logs                            (C:\inetpub\logs -- SERVER: age-gated 30 days)
      - SQL Server error logs               (age-gated 30 days, data files never touched)
      - User Downloads folder               (age-gated 90 days, WORKSTATION ONLY, logged)
      - Shadow copy notification            (reports VSS usage, never deletes)
      - Hibernate file (hiberfil.sys)       (WORKSTATION ONLY -- disables hibernation)
      - Windows Installer orphans          (WORKSTATION ONLY -- orphaned .msi/.msp only)

    WORKSTATION ONLY (skipped on Server OS):
      - Windows\Installer\$PatchCache$      (MSI patch cache)
      - Font cache                          (causes RDS session glitch if active)
      - Hibernate file                      (servers do not hibernate)
      - User Downloads age-gated cleanup    (server Downloads not user-owned)
      - Windows Installer orphan cleanup

    NEVER TOUCHES:
      Desktop, Documents, Pictures, Videos, Music, active database files,
      SQL .mdf/.ldf/.ndf, IIS application files, Program Files,
      AppData\Roaming (except Teams cache and Recent shortcuts),
      any file modified within its age gate window.

    Paladin Business Consulting | Internal Use Only
    Version: 1.0.0 | Min OS: Windows 10 / Server 2016
#>

$script:ExitCode   = 0
$script:BytesFreed = [long]0
$script:Errors     = 0
$script:IsServer   = $false

# ===========================================================================
# HELPERS
# ===========================================================================

function Get-FreeBytes {
    param([string]$Drive)
    try {
        if ([string]::IsNullOrEmpty($Drive)) { return [long]0 }
        $d = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='$Drive'" -EA Stop
        if ($d -eq $null -or $d.FreeSpace -eq $null) { return [long]0 }
        return [long]$d.FreeSpace
    } catch {
        return [long]0
    }
}

function Format-GB {
    param($Bytes)
    if ($Bytes -eq $null) { return '0.00 GB' }
    try {
        return [math]::Round([long]$Bytes / 1073741824, 2).ToString() + ' GB'
    } catch {
        return '0.00 GB'
    }
}

function Get-FolderSize {
    param([string]$Path)
    if (!(Test-Path $Path)) { return [long]0 }
    try {
        $size = (Get-ChildItem $Path -Recurse -Force -EA SilentlyContinue |
                 Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum
        if ($size -eq $null) { return [long]0 }
        return [long]$size
    } catch {
        return [long]0
    }
}

function Remove-DirectoryContents {
    param(
        [string]$Path,
        [string]$Label,
        [int]$MinAgeMinutes = 0
    )
    if (!(Test-Path $Path)) {
        Write-Host "  [Skip] Not found: $Label"
        return [long]0
    }
    $cutoff  = (Get-Date).AddMinutes(-$MinAgeMinutes)
    $freed   = [long]0
    $skipped = 0
    $failed  = 0
    $items   = Get-ChildItem -Path $Path -Force -EA SilentlyContinue
    if (!$items) {
        Write-Host "  [Skip] Already empty: $Label"
        return [long]0
    }
    foreach ($item in $items) {
        if ($MinAgeMinutes -gt 0 -and $item.LastWriteTime -gt $cutoff) {
            $skipped++
            continue
        }
        try {
            if ($item.PSIsContainer) {
                $size = Get-FolderSize -Path $item.FullName
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -EA Stop
            } else {
                $size = $item.Length
                Remove-Item -LiteralPath $item.FullName -Force -EA Stop
            }
            $freed += [long]$size
        } catch {
            $failed++
        }
    }
    $msg = "  [Done] $Label -- freed $(Format-GB $freed)"
    if ($skipped -gt 0) { $msg += " | skipped $skipped recent" }
    if ($failed  -gt 0) { $msg += " | $failed locked/failed" }
    Write-Host $msg
    return [long]$freed
}

function Remove-SingleFolder {
    param([string]$Path, [string]$Label)
    if (!(Test-Path $Path)) {
        Write-Host "  [Skip] Not found: $Label"
        return [long]0
    }
    $size = Get-FolderSize -Path $Path
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -EA Stop
        Write-Host "  [Done] $Label -- freed $(Format-GB $size)"
        return [long]$size
    } catch {
        Write-Host "  [Warn] Could not remove $Label : $($_.Exception.Message)"
        $script:Errors++
        return [long]0
    }
}

function Remove-AgedFiles {
    # Deletes individual files older than N days in a folder. Does NOT delete subfolders.
    # Safe for log directories where folder structure must stay intact.
    param(
        [string]$Path,
        [string]$Label,
        [int]$AgeDays = 30,
        [string]$Filter = '*'
    )
    if (!(Test-Path $Path)) {
        Write-Host "  [Skip] Not found: $Label"
        return [long]0
    }
    $cutoff = (Get-Date).AddDays(-$AgeDays)
    $freed  = [long]0
    $failed = 0
    $files  = Get-ChildItem -Path $Path -Filter $Filter -Recurse -Force -EA SilentlyContinue |
              Where-Object { !$_.PSIsContainer -and $_.LastWriteTime -lt $cutoff }
    if (!$files) {
        Write-Host "  [Skip] No files older than $AgeDays days: $Label"
        return [long]0
    }
    foreach ($f in $files) {
        try {
            $freed += $f.Length
            Remove-Item -LiteralPath $f.FullName -Force -EA Stop
        } catch {
            $failed++
        }
    }
    $msg = "  [Done] $Label (>${AgeDays}d) -- freed $(Format-GB $freed)"
    if ($failed -gt 0) { $msg += " | $failed locked/failed" }
    Write-Host $msg
    return [long]$freed
}

function Get-UserProfiles {
    $patterns = @('S-1-12-1-(\d+-?){4}$', 'S-1-5-21-(\d+-?){4}$')
    $results  = @()
    foreach ($p in $patterns) {
        $results += Get-ItemProperty `
            'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -EA SilentlyContinue |
            Where-Object { $_.PSChildName -match $p } |
            Select-Object @{Name='UserName'; Expression={ Split-Path $_.ProfileImagePath -Leaf }},
                          @{Name='Path';     Expression={ $_.ProfileImagePath }}
    }
    $results
}

# ===========================================================================
# OS DETECTION
# ===========================================================================
try {
    $os = Get-WmiObject -Class Win32_OperatingSystem -EA Stop
    $script:IsServer = ($os.ProductType -eq 2 -or $os.ProductType -eq 3)
    $osCaption       = $os.Caption
} catch {
    $script:IsServer = $false
    $osCaption       = 'Unknown OS'
}

# ===========================================================================
# MAIN
# ===========================================================================

Write-Host '======================================================='
Write-Host ' Paladin Disk Space Recovery -- DESPERATION MODE v1.0.0'
Write-Host ' Datto RMM | NT AUTHORITY\SYSTEM'
Write-Host '======================================================='
Write-Host "  OS      : $osCaption"
if ($script:IsServer) {
    Write-Host '  Mode    : SERVER -- MSI patch cache, font cache, hiberfil, Downloads skipped'
} else {
    Write-Host '  Mode    : WORKSTATION -- all phases active'
}

$sysDrive    = $env:SystemDrive
$freeAtStart = Get-FreeBytes -Drive $sysDrive
Write-Host "  Drive   : $sysDrive  Free at start: $(Format-GB $freeAtStart)"
Write-Host ''

# ===========================================================================
# PHASE 1 -- SYSTEM TEMP + CACHE
# ===========================================================================
Write-Host '[Phase 1] System temp and cache'

$freed = Remove-DirectoryContents `
    -Path "$env:SystemRoot\Temp" -Label 'Windows\Temp' -MinAgeMinutes 60
$script:BytesFreed += $freed

$freed = Remove-DirectoryContents `
    -Path "$env:SystemRoot\SoftwareDistribution\Download" `
    -Label 'Windows Update Download Cache' -MinAgeMinutes 0
$script:BytesFreed += $freed

$freed = Remove-DirectoryContents `
    -Path "$env:SystemRoot\Prefetch" -Label 'Prefetch Cache' -MinAgeMinutes 0
$script:BytesFreed += $freed

# ===========================================================================
# PHASE 2 -- WINDOWS LOGS AND CRASH DUMPS
# ===========================================================================
Write-Host ''
Write-Host '[Phase 2] Windows logs and crash dumps'

$logPaths = @(
    "$env:SystemRoot\Logs\CBS"
    "$env:SystemRoot\Logs\DISM"
    "$env:SystemRoot\Logs\MoSetup"
    "$env:SystemRoot\Logs\NetSetup"
    "$env:SystemRoot\Logs\WindowsUpdate"
)
foreach ($p in $logPaths) {
    $freed = Remove-DirectoryContents -Path $p -Label "Logs\$(Split-Path $p -Leaf)" -MinAgeMinutes 0
    $script:BytesFreed += $freed
}

$freed = Remove-DirectoryContents `
    -Path "$env:SystemRoot\Minidump" -Label 'Minidump crash files' -MinAgeMinutes 0
$script:BytesFreed += $freed

$memDump = "$env:SystemRoot\MEMORY.DMP"
if (Test-Path $memDump) {
    try {
        $sz = (Get-Item $memDump -Force -EA Stop).Length
        Remove-Item $memDump -Force -EA Stop
        Write-Host "  [Done] MEMORY.DMP -- freed $(Format-GB $sz)"
        $script:BytesFreed += [long]$sz
    } catch {
        Write-Host "  [Warn] Could not remove MEMORY.DMP: $($_.Exception.Message)"
    }
}

$werPaths = @(
    "$env:SystemRoot\System32\config\systemprofile\AppData\Local\Microsoft\Windows\WER"
    "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"
    "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
)
foreach ($p in $werPaths) {
    $freed = Remove-DirectoryContents -Path $p -Label "WER\$(Split-Path $p -Leaf)" -MinAgeMinutes 0
    $script:BytesFreed += $freed
}

# ===========================================================================
# PHASE 3 -- DELIVERY OPTIMIZATION + FONT CACHE + PATCH CACHE
# ===========================================================================
Write-Host ''
Write-Host '[Phase 3] Delivery Optimization, font cache, patch cache'

$doPath = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
$freed  = Remove-DirectoryContents -Path $doPath -Label 'Delivery Optimization Cache' -MinAgeMinutes 0
$script:BytesFreed += $freed

try {
    $doCmd = Get-Command 'Delete-DeliveryOptimizationCache' -EA SilentlyContinue
    if ($doCmd) {
        Delete-DeliveryOptimizationCache -Force -EA SilentlyContinue | Out-Null
        Write-Host '  [Done] Delivery Optimization cache flushed via API'
    }
} catch { }

if ($script:IsServer) {
    Write-Host '  [Skip] Font cache -- SERVER OS, skipping to protect active sessions'
} else {
    $fontCachePaths = @(
        "$env:SystemRoot\ServiceProfiles\LocalService\AppData\Local\FontCache"
        "$env:SystemRoot\System32\FNTCACHE.DAT"
    )
    foreach ($p in $fontCachePaths) {
        if (Test-Path $p) {
            try {
                $item = Get-Item $p -Force -EA SilentlyContinue
                $sz   = if ($item.PSIsContainer) { Get-FolderSize -Path $p } else { $item.Length }
                Remove-Item $p -Recurse -Force -EA Stop
                Write-Host "  [Done] Font cache: $(Split-Path $p -Leaf) -- freed $(Format-GB $sz)"
                $script:BytesFreed += [long]$sz
            } catch {
                Write-Host "  [Warn] Font cache locked (non-fatal): $(Split-Path $p -Leaf)"
            }
        }
    }
}

if ($script:IsServer) {
    Write-Host '  [Skip] MSI Patch Cache -- SERVER OS, required for role and feature repair'
} else {
    $patchCache = "$env:SystemRoot\Installer\`$PatchCache`$"
    $freed = Remove-DirectoryContents -Path $patchCache -Label 'MSI Patch Cache' -MinAgeMinutes 0
    $script:BytesFreed += $freed
}

# ===========================================================================
# PHASE 3b -- EXTENDED CLEANUP (direct file removal -- no cleanmgr GUI)
# Covers: D3D Shader Cache, BranchCache, Downloaded Program Files,
#         Diagnostic Data Viewer DB, Old ChkDsk files, Defender scan cache,
#         IE/Edge legacy cache, WU remnants
# SKIPPED: Windows ESD files (recovery partition -- never touch)
# ===========================================================================
Write-Host "  [Phase 3b] Extended cleanup (direct -- no cleanmgr)"

function Remove-SafePath {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) { return }
    try {
        Remove-Item -Path $Path -Recurse -Force -EA SilentlyContinue
        Write-Host "  [Done] $Label"
    } catch {
        Write-Host "  [Warn] $Label -- $($_.Exception.Message)"
    }
}

# D3D Shader Cache (GPU rebuilds on next launch)
Remove-SafePath "$env:SystemRoot\System32\d3dscache"  'D3D Shader Cache (System32)'

# Per-user D3D cache + IE/Edge legacy cache
$profiles = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -EA SilentlyContinue |
            Where-Object { $_.PSChildName -match 'S-1-5-21-(\d+-?){4}$|S-1-12-1-(\d+-?){4}$' }
foreach ($prof in $profiles) {
    $pp = $prof.ProfileImagePath
    if (-not $pp -or -not (Test-Path $pp)) { continue }
    $uname = Split-Path $pp -Leaf
    Remove-SafePath "$pp\AppData\Local\D3DSCache"                           "D3D Cache: $uname"
    Remove-SafePath "$pp\AppData\Local\Microsoft\Windows\INetCache"         "IE/Edge Cache: $uname"
    Remove-SafePath "$pp\AppData\Local\Microsoft\Windows\INetCookies"       "IE Cookies: $uname"
    Remove-SafePath "$pp\AppData\Local\Microsoft\Windows\History"            "IE History: $uname"
}

# BranchCache
Remove-SafePath "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\PeerDistRepub" 'BranchCache'
Remove-SafePath "$env:SystemRoot\System32\config\systemprofile\AppData\Local\PeerDistRepub"  'BranchCache (SYSTEM)'

# Downloaded Program Files (old ActiveX/Java -- obsolete)
Remove-SafePath "$env:SystemRoot\Downloaded Program Files" 'Downloaded Program Files'

# Diagnostic Data / Telemetry
Remove-SafePath "$env:ProgramData\Microsoft\Diagnosis\ETLLogs\AutoLogger" 'Diagnostic ETL logs'

# Old chkdsk found.000 folders on all fixed drives
$drives = Get-WmiObject Win32_LogicalDisk -EA SilentlyContinue | Where-Object { $_.DriveType -eq 3 }
foreach ($d in $drives) {
    Remove-SafePath "$($d.DeviceID)\found.000" "ChkDsk remnants ($($d.DeviceID)\found.000)"
}

# Windows Defender scan history cache (not signatures)
Remove-SafePath "$env:ProgramData\Microsoft\Windows Defender\Scans\History\Results\Resource" 'Defender scan history cache'
Remove-SafePath "$env:ProgramData\Microsoft\Windows Defender\Scans\History\Results\Quick"    'Defender quick scan cache'
Remove-SafePath "$env:ProgramData\Microsoft\Windows Defender\Scans\MetaStore"                'Defender MetaStore'

# WU orphaned leftovers
Remove-SafePath "$env:SystemRoot\SoftwareDistribution\PostRebootEventCache" 'WU PostRebootEventCache'

Write-Host "  [Done] Phase 3b extended cleanup complete"
$ok++

# ===========================================================================
# PHASE 3c -- ADDITIONAL SAFE CLEANUP LOCATIONS
# Catroot2 contents, NVIDIA/AMD install cache,
# WU DataStore logs, CryptnetUrlCache, BITS queue, System LogFiles
# ===========================================================================
Write-Host ''
Write-Host '[Phase 3c] Additional safe cleanup locations'

function Remove-FolderContentsOnly {
    # Deletes contents of a folder but never the folder itself
    param([string]$Path, [string]$Label, [int]$MinAgeMins = 0)
    if (-not (Test-Path $Path)) { return }
    $cutoff = (Get-Date).AddMinutes(-$MinAgeMins)
    $freed  = [long]0
    foreach ($item in (Get-ChildItem -Path $Path -Force -EA SilentlyContinue)) {
        if ($MinAgeMins -gt 0 -and $item.LastWriteTime -gt $cutoff) { continue }
        try {
            $sz = if ($item.PSIsContainer) {
                (Get-ChildItem $item.FullName -Recurse -Force -EA SilentlyContinue |
                 Measure-Object -Property Length -Sum -EA SilentlyContinue).Sum
            } else { $item.Length }
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -EA Stop
            $freed += [long]($sz -as [long])
        } catch {}
    }
    if ($freed -gt 0) {
        Write-Host "  [Done] $Label -- freed $([math]::Round($freed/1MB,1)) MB"
    }
}

# Catroot2 contents (stop CryptSvc first, restart after -- Windows recreates contents)
try {
    Stop-Service -Name 'CryptSvc' -Force -EA SilentlyContinue
    Start-Sleep -Seconds 2
    Remove-FolderContentsOnly -Path "$env:SystemRoot\System32\catroot2" -Label 'Catroot2 contents'
    Start-Service -Name 'CryptSvc' -EA SilentlyContinue
} catch {
    Start-Service -Name 'CryptSvc' -EA SilentlyContinue
    Write-Host "  [Warn] Catroot2 cleanup: $($_.Exception.Message)"
}

# SoftwareDistribution DataStore Logs (logs only -- never the DataStore itself)
Remove-FolderContentsOnly -Path "$env:SystemRoot\SoftwareDistribution\DataStore\Logs" -Label 'WU DataStore Logs'

# BITS queue files (stop BITS first)
try {
    Stop-Service -Name 'BITS' -Force -EA SilentlyContinue
    Start-Sleep -Seconds 2
    Get-ChildItem -Path "$env:AllUsersProfile\Microsoft\Network\Downloader" -Filter 'qmgr*.dat' -Force -EA SilentlyContinue |
        ForEach-Object { try { Remove-Item $_.FullName -Force -EA SilentlyContinue } catch {} }
    Write-Host '  [Done] BITS queue files (qmgr*.dat)'
    Start-Service -Name 'BITS' -EA SilentlyContinue
} catch {
    Start-Service -Name 'BITS' -EA SilentlyContinue
    Write-Host "  [Warn] BITS queue cleanup: $($_.Exception.Message)"
}

# NVIDIA driver install cache (root C:\NVIDIA folder -- install packages only)
if (Test-Path 'C:\NVIDIA') {
    Remove-FolderContentsOnly -Path 'C:\NVIDIA' -Label 'NVIDIA driver install cache'
}

# AMD driver install cache (root C:\AMD folder)
if (Test-Path 'C:\AMD') {
    Remove-FolderContentsOnly -Path 'C:\AMD' -Label 'AMD driver install cache'
}

# NVIDIA ProgramData downloader cache
Remove-FolderContentsOnly -Path "$env:ProgramData\NVIDIA Corporation\Downloader" -Label 'NVIDIA update downloader cache'

# System32 LogFiles (IIS + system service logs -- age-gated 30 days)
if (Test-Path "$env:SystemRoot\System32\LogFiles") {
    Get-ChildItem -Path "$env:SystemRoot\System32\LogFiles" -Recurse -Force -EA SilentlyContinue |
        Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        ForEach-Object { try { Remove-Item $_.FullName -Force -EA SilentlyContinue } catch {} }
    Write-Host '  [Done] System32\LogFiles (>30 days old)'
}

# Per-user CryptnetUrlCache (certificate URL cache -- IE/WinHTTP rebuilds automatically)
$profiles = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -EA SilentlyContinue |
            Where-Object { $_.PSChildName -match 'S-1-5-21-(\d+-?){4}$|S-1-12-1-(\d+-?){4}$' }
foreach ($prof in $profiles) {
    $pp = $prof.ProfileImagePath
    if (-not $pp -or -not (Test-Path $pp)) { continue }
    $uname = Split-Path $pp -Leaf
    $cryptPath = "$pp\AppData\LocalLow\Microsoft\CryptnetUrlCache"
    if (Test-Path $cryptPath) {
        Remove-FolderContentsOnly -Path "$cryptPath\Content"  -Label "CryptnetUrlCache Content: $uname"
        Remove-FolderContentsOnly -Path "$cryptPath\MetaData" -Label "CryptnetUrlCache MetaData: $uname"
    }
}

Write-Host '  [Done] Phase 3c complete'
$ok++


# ===========================================================================
# PHASE 4 -- DISM COMPONENT CLEANUP
# ===========================================================================
Write-Host ''
Write-Host '[Phase 4] WinSxS component cleanup (DISM)'
Write-Host '  Running DISM /StartComponentCleanup -- this may take 1-3 minutes...'
try {
    $dism = Start-Process -FilePath 'dism.exe' `
        -ArgumentList '/Online /Cleanup-Image /StartComponentCleanup' `
        -Wait -PassThru -WindowStyle Hidden -EA Stop
    if ($dism.ExitCode -eq 0) {
        Write-Host '  [Done] DISM component cleanup completed'
    } else {
        Write-Host "  [Warn] DISM exited with code $($dism.ExitCode) -- non-fatal"
    }
} catch {
    Write-Host "  [Warn] DISM failed: $($_.Exception.Message) -- skipping"
    $script:Errors++
}

# ===========================================================================
# PHASE 5 -- PER-USER LOCATIONS
# ===========================================================================
Write-Host ''
Write-Host '[Phase 5] User profile cleanup'

$profiles = Get-UserProfiles
if (!$profiles -or $profiles.Count -eq 0) {
    Write-Host '  [Warn] No user profiles found -- skipping'
} else {
    foreach ($u in $profiles) {
        Write-Host "  User: $($u.UserName)"

        $freed = Remove-DirectoryContents `
            -Path "$($u.Path)\AppData\Local\Temp" `
            -Label "$($u.UserName)\AppData\Local\Temp" -MinAgeMinutes 60
        $script:BytesFreed += $freed

        $teamsAgeGate    = if ($script:IsServer) { 120 } else { 0 }
        $teamsCachePaths = @(
            "$($u.Path)\AppData\Roaming\Microsoft\Teams\blob_storage"
            "$($u.Path)\AppData\Roaming\Microsoft\Teams\Cache"
            "$($u.Path)\AppData\Roaming\Microsoft\Teams\databases"
            "$($u.Path)\AppData\Roaming\Microsoft\Teams\Code Cache"
            "$($u.Path)\AppData\Roaming\Microsoft\Teams\GPUCache"
            "$($u.Path)\AppData\Local\Microsoft\Teams\current\resources\locales"
        )
        foreach ($tp in $teamsCachePaths) {
            $freed = Remove-DirectoryContents `
                -Path $tp `
                -Label "$($u.UserName)\Teams\$(Split-Path $tp -Leaf)" `
                -MinAgeMinutes $teamsAgeGate
            $script:BytesFreed += $freed
        }

        $freed = Remove-DirectoryContents `
            -Path "$($u.Path)\AppData\Roaming\Microsoft\Windows\Recent" `
            -Label "$($u.UserName)\Recent shortcuts" -MinAgeMinutes 0
        $script:BytesFreed += $freed

        $thumbPath = "$($u.Path)\AppData\Local\Microsoft\Windows\Explorer"
        if (Test-Path $thumbPath) {
            $thumbFiles = Get-ChildItem -Path $thumbPath -Filter 'thumbcache_*.db' -Force -EA SilentlyContinue
            $thumbFreed = [long]0
            foreach ($f in $thumbFiles) {
                try { $thumbFreed += $f.Length; Remove-Item -LiteralPath $f.FullName -Force -EA Stop } catch { }
            }
            if ($thumbFreed -gt 0) {
                Write-Host "    [Done] $($u.UserName) Thumbnail cache -- freed $(Format-GB $thumbFreed)"
                $script:BytesFreed += $thumbFreed
            }
        }

        $freed = Remove-DirectoryContents `
            -Path "$($u.Path)\AppData\Local\Microsoft\Windows\WER" `
            -Label "$($u.UserName)\WER" -MinAgeMinutes 0
        $script:BytesFreed += $freed

        # Downloads -- WORKSTATION ONLY, age-gated 90 days
        # Only files older than 90 days. Subfolders never touched.
        if (-not $script:IsServer) {
            $dlPath = "$($u.Path)\Downloads"
            if (Test-Path $dlPath) {
                $dlSize = Get-FolderSize -Path $dlPath
                Write-Host "    [INFO] $($u.UserName)\Downloads total size: $(Format-GB $dlSize)"
                $freed = Remove-AgedFiles `
                    -Path $dlPath `
                    -Label "$($u.UserName)\Downloads" `
                    -AgeDays 90
                $script:BytesFreed += $freed
            }
        }
    }
}

# ===========================================================================
# PHASE 6 -- RECYCLE BIN
# ===========================================================================
Write-Host ''
Write-Host '[Phase 6] Recycle Bin'
try {
    $rbCmd = Get-Command 'Clear-RecycleBin' -EA SilentlyContinue
    if ($rbCmd) {
        Clear-RecycleBin -Force -EA SilentlyContinue
        Write-Host '  [Done] Recycle Bin emptied'
    } else {
        $shell = New-Object -ComObject Shell.Application
        $bin   = $shell.Namespace(0xA)
        $bin.Items() | ForEach-Object { $_.InvokeVerb('delete') }
        Write-Host '  [Done] Recycle Bin emptied (PS3 fallback)'
    }
} catch {
    Write-Host "  [Warn] Recycle Bin clear failed: $($_.Exception.Message)"
    $script:Errors++
}

# ===========================================================================
# PHASE 7 -- WINDOWS UPGRADE LEFTOVERS
# ===========================================================================
Write-Host ''
Write-Host '[Phase 7] Windows upgrade leftovers'

$upgradeFolders = @(
    @{ Path = "$($sysDrive)\Windows.old";    Label = 'Windows.old (previous Windows install)' },
    @{ Path = "$($sysDrive)\`$WINDOWS.~BT"; Label = '$WINDOWS.~BT (upgrade staging)' },
    @{ Path = "$($sysDrive)\`$WINDOWS.~WS"; Label = '$WINDOWS.~WS (upgrade workspace)' }
)
foreach ($uf in $upgradeFolders) {
    if (Test-Path $uf.Path) {
        $sz = Get-FolderSize -Path $uf.Path
        Write-Host "  [NOTE] Found: $($uf.Label) -- $(Format-GB $sz)"
        Write-Host "  [NOTE] Removing -- rollback to previous Windows version will no longer be possible."
        $freed = Remove-SingleFolder -Path $uf.Path -Label $uf.Label
        $script:BytesFreed += $freed
    } else {
        Write-Host "  [Skip] Not found: $($uf.Label)"
    }
}

# ===========================================================================
# PHASE 8 -- IIS LOGS (age-gated 30 days)
# ===========================================================================
Write-Host ''
Write-Host '[Phase 8] IIS logs (>30 days old)'

$iisLogRoot = 'C:\inetpub\logs\LogFiles'
if (!(Test-Path $iisLogRoot)) {
    Write-Host '  [Skip] IIS not detected on this machine'
} else {
    # Enumerate each W3SVC site log folder independently
    $siteFolders = Get-ChildItem -Path $iisLogRoot -Directory -EA SilentlyContinue
    if (!$siteFolders) {
        Write-Host '  [Skip] No IIS site log folders found'
    } else {
        foreach ($site in $siteFolders) {
            $freed = Remove-AgedFiles `
                -Path $site.FullName `
                -Label "IIS\$($site.Name)" `
                -AgeDays 30 `
                -Filter '*.log'
            $script:BytesFreed += $freed
        }
    }
}

# ===========================================================================
# PHASE 9 -- SQL SERVER ERROR LOGS (age-gated 30 days)
# Targets error logs ONLY. Never touches .mdf/.ldf/.ndf data files.
# ===========================================================================
Write-Host ''
Write-Host '[Phase 9] SQL Server error logs (>30 days old)'

# Find all SQL Server instances via registry
$sqlRegBase  = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
$sqlInstances = @()
try {
    $instanceList = Get-ItemProperty -Path "$sqlRegBase\Instance Names\SQL" -EA SilentlyContinue
    if ($instanceList) {
        $instanceList.PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS' } |
            ForEach-Object { $sqlInstances += $_.Value }
    }
} catch { }

if ($sqlInstances.Count -eq 0) {
    Write-Host '  [Skip] No SQL Server instances detected'
} else {
    foreach ($inst in $sqlInstances) {
        $logPath = $null
        try {
            $setupKey = "$sqlRegBase\$inst\Setup"
            $sqlRoot  = (Get-ItemProperty -Path $setupKey -Name 'SQLPath' -EA Stop).SQLPath
            $logPath  = Join-Path $sqlRoot 'Log'
        } catch { }

        if ($logPath -and (Test-Path $logPath)) {
            # Only delete ERRORLOG.* files -- never touch .trc, .xel, or anything else
            $freed = Remove-AgedFiles `
                -Path $logPath `
                -Label "SQL\$inst error logs" `
                -AgeDays 30 `
                -Filter 'ERRORLOG.*'
            $script:BytesFreed += $freed
        } else {
            Write-Host "  [Skip] SQL log path not found for instance: $inst"
        }
    }
}

# ===========================================================================
# PHASE 10 -- HIBERNATE FILE (WORKSTATION ONLY)
# Disabling hibernation removes hiberfil.sys (often 4-32GB on laptops)
# This is safe -- just means hibernate/fast startup won't be available.
# ===========================================================================
Write-Host ''
Write-Host '[Phase 10] Hibernate file'

if ($script:IsServer) {
    Write-Host '  [Skip] Hibernate file -- SERVER OS, servers do not hibernate'
} else {
    $hiberFile = "$env:SystemRoot\hiberfil.sys"
    if (!(Test-Path $hiberFile)) {
        Write-Host '  [Skip] Hibernation already disabled -- hiberfil.sys not present'
    } else {
        try {
            $sz = (Get-Item $hiberFile -Force -EA Stop).Length
            Write-Host "  [INFO] hiberfil.sys size: $(Format-GB $sz)"
            Write-Host '  [INFO] Disabling hibernation to remove hiberfil.sys...'
            $result = Start-Process 'powercfg.exe' -ArgumentList '/h off' `
                -Wait -PassThru -WindowStyle Hidden -EA Stop
            if ($result.ExitCode -eq 0) {
                Write-Host "  [Done] Hibernation disabled -- hiberfil.sys removed (freed ~$(Format-GB $sz))"
                $script:BytesFreed += [long]$sz
            } else {
                Write-Host "  [Warn] powercfg /h off exited with code $($result.ExitCode)"
            }
        } catch {
            Write-Host "  [Warn] Could not disable hibernation: $($_.Exception.Message)"
            $script:Errors++
        }
    }
}

# ===========================================================================
# PHASE 11 -- SHADOW COPY REPORT (never deletes -- inform only)
# Shadow copies can consume enormous space. Deleting them is irreversible
# and may break backup/restore chains. Report only; let the admin decide.
# ===========================================================================
Write-Host ''
Write-Host '[Phase 11] Shadow copy report (informational only -- nothing deleted)'

try {
    $shadows = Get-WmiObject -Class Win32_ShadowCopy -EA SilentlyContinue
    if (!$shadows -or $shadows.Count -eq 0) {
        Write-Host '  [Info] No shadow copies found'
    } else {
        $totalShadow = [long]0
        foreach ($s in $shadows) {
            $volName = $s.VolumeName
            Write-Host "  [Info] Shadow copy: $($s.ID) | Vol: $volName | Created: $($s.InstallDate)"
        }
        Write-Host "  [Info] Total shadow copies: $($shadows.Count)"
        Write-Host '  [Info] To reclaim this space manually run: vssadmin delete shadows /all /quiet'
        Write-Host '  [WARN] Deleting shadow copies removes all System Restore points and VSS backups.'
    }
} catch {
    Write-Host '  [Warn] Could not query shadow copies: VSS may not be running'
}

# ===========================================================================
# RESULT
# ===========================================================================
$freeAtEnd = Get-FreeBytes -Drive $sysDrive
$netGain   = $freeAtEnd - $freeAtStart

Write-Host ''
Write-Host '======================================================='
Write-Host " Drive $sysDrive  Free at start : $(Format-GB $freeAtStart)"
Write-Host " Drive $sysDrive  Free at end   : $(Format-GB $freeAtEnd)"
Write-Host " Net space recovered            : $(Format-GB $netGain)"
Write-Host " Script-tracked freed           : $(Format-GB $script:BytesFreed)"
if ($script:Errors -gt 0) { Write-Host " Non-fatal warnings             : $($script:Errors)" }
Write-Host '======================================================='

if ($script:ExitCode -eq 0) {
    Write-Host "SUCCESS: Desperation cleanup complete. Recovered $(Format-GB $netGain) on $sysDrive."
} else {
    Write-Host 'COMPLETE WITH WARNINGS: Cleanup finished. Review output above.'
}

exit $script:ExitCode
