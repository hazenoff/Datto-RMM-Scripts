#Requires -Version 3.0
# =============================================================================
# Paladin Update & Reset [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.0
# Context: NT AUTHORITY\SYSTEM (LocalSystem) -- fully headless
#
# SEQUENCE (single Datto job, one reboot at the very end):
#   Stage 1 -- Spooler Reset     clear stuck print jobs, restart spooler
#   Stage 2 -- Browser Reset     factory reset all browsers for all users
#   Stage 3 -- Sync Reset        clear OneDrive + Teams sync state
#   Stage 4 -- App Updater       silent update all non-excluded apps via WinGet
#   Stage 5 -- Windows Update    scan + install all pending updates
#   Stage 6 -- Network Reset     flush DNS, ARP, Winsock/TCP stack reset (LAST -- kills connectivity)
#              (Phase 2 DHCP renew registered as resume task, runs post-boot)
#   Single orchestrator reboot if AllowReboot=true and all stages passed
#
# INPUT VARIABLES:
#   AllowReboot   Boolean  "true" = reboot at end            (default: false)
#   WUAction      String   Report / Install                   (default: Install)
#   UDFSlot       String   UDF slot for final result          (default: 30)
#
# LOG:  C:\ProgramData\Paladin\UpdateReset\UpdateReset.log
# EXIT: 0 = all stages passed  |  1 = one or more stages failed
# =============================================================================

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer  = '1.0.0'
$BaseDir    = 'C:\ProgramData\Paladin\UpdateReset'
$LogFile    = "$BaseDir\UpdateReset.log"
$MaxLogMB   = 10

$ProfileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

# Network Reset resume task constants
$NetResetKey    = 'HKLM:\SOFTWARE\Paladin\NetworkReset'
$NetResetDir    = 'C:\ProgramData\Paladin\NetworkReset'
$NetResetScript = "$NetResetDir\NetworkReset-Resume.ps1"
$NetResetTask   = 'Paladin_NetworkReset_Resume'
$PsExe          = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

# AppUpdater exclusion lists
$HardExclPatterns = @(
    'Intuit.QuickBooks','Intuit.QuickBooksDesktop','Fortinet.FortiClientVPN','Fortinet.FortiClient',
    'Citrix.Workspace','CitrixOnlinePluginPackWeb','Autodesk.','Microsoft.Office','Microsoft.Teams',
    'AnyDeskSoftwareGmbH.','TeamViewer.TeamViewer','RealVNC.','uvnc.','Datto.','CentraStage.',
    'ESET.','Malwarebytes.','SentinelOne.','CrowdStrike.','Sophos.','Symantec.','McAfee.',
    'Norton.','BitDefender.','TrendMicro.','Webroot.','Cylance.','Carbon Black.','Microsoft.OneDrive'
)
$SoftExclPatterns = @(
    'Sage.','Microsoft.SQLServer','Oracle.JavaRuntimeEnvironment','Oracle.JDK','Python.',
    'Microsoft.DotNet','Microsoft.PowerShell','Nvidia.GeForce','Nvidia.CUDA','AMD.Software',
    'AdvancedMicroDevices.','Intel.GraphicsCommandCenter','Intel.Arc','WinFsp.','Elgato.',
    'Corsair.','Logitech.','Razer.','SteelSeries.','Microsoft.VisualStudio.'
)
$DeferredPatterns   = @('Microsoft.VCRedist','Microsoft.DirectX','Microsoft.WebView2')
$SelfUpdatePatterns = @('StartIsBack.StartIsBack','8x8.Work','Slack.Slack','Zoom.Zoom',
    'Spotify.Spotify','Discord.Discord','Grammarly.','Dropbox.Dropbox','Box.Box',
    'LogMeIn.','GoTo.','Webex.','RingCentral.')
$ChocoMap = @{
    'Notepad++.Notepad++'='notepadplusplus';'7zip.7zip'='7zip';'Google.Chrome'='googlechrome';
    'Mozilla.Firefox'='firefox';'VideoLAN.VLC'='vlc';'Adobe.Acrobat.Reader.64-bit'='adobereader';
    'Zoom.Zoom'='zoom';'Microsoft.PowerToys'='powertoys';'WinSCP.WinSCP'='winscp';
    'Git.Git'='git';'Microsoft.VisualStudioCode'='vscode';'SlackTechnologies.Slack'='slack'
}

# =============================================================================
# INPUT VARIABLES
# =============================================================================
$AllowReboot = ($env:AllowReboot -eq 'true')
$UDFSlot     = if ($env:UDFSlot -match '^\d+$') { [int]$env:UDFSlot } else { 30 }
$WUAction    = if ($env:WUAction) { $env:WUAction } else { 'Install' }
$UpdateTimeout = 120   # per-package winget timeout
$SiteName    = if ($env:CS_PROFILE_NAME) { $env:CS_PROFILE_NAME } else { 'UNKNOWN' }
$MachineName = $env:COMPUTERNAME

# =============================================================================
# SHARED HELPERS
# =============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try {
        if (-not (Test-Path $BaseDir)) { New-Item $BaseDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile -EA SilentlyContinue).Length / 1MB) -gt $MaxLogMB) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.bak" -Force -EA SilentlyContinue
        }
        Add-Content -Path $LogFile -Value $line -EA SilentlyContinue
    } catch {}
}

function Write-Sep  { Write-Log ('=' * 64) }
function Write-Sep2 { Write-Log ('-' * 32) }

function Set-DattoUDF {
    param([int]$Slot, [string]$Value)
    $trimmed = if ($Value.Length -gt 255) { $Value.Substring(0,255) } else { $Value }
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' `
            -Name "Custom$Slot" -PropertyType String -Value $trimmed `
            -Force -EA Stop | Out-Null
        Write-Log "UDF$Slot => $trimmed"
    } catch { Write-Log "WARN: UDF$Slot write failed: $($_.Exception.Message)" 'WARN' }
}

function Show-UserMessage {
    param([string]$Message)
    try {
        $sessions = & query session 2>&1 | Where-Object { $_ -match 'Active' }
        if ($sessions) { & msg.exe '*' /TIME:300 "Paladin IT: $Message" 2>&1 | Out-Null }
    } catch {}
}

function Get-UserProfiles {
    $results = @()
    foreach ($p in @('S-1-12-1-(\d+-?){4}$','S-1-5-21-(\d+-?){4}$')) {
        $results += Get-ItemProperty "$ProfileList\*" -EA SilentlyContinue |
            Where-Object { $_.PSChildName -match $p } |
            Select-Object @{Name='SID';Expression={$_.PSChildName}},
                          @{Name='UserName';Expression={Split-Path $_.ProfileImagePath -Leaf}},
                          @{Name='UserHive';Expression={"$($_.ProfileImagePath)\NTuser.dat"}},
                          @{Name='Path';Expression={$_.ProfileImagePath}}
    }
    return $results
}

function Get-PhysicalAdapters {
    Get-WmiObject -Class Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
        Where-Object { $_.IPEnabled -eq $true -and $_.Description -notmatch 'Hyper-V|VMware|VirtualBox|Loopback|Teredo|6to4|ISATAP|Pseudo|WAN Miniport|Bluetooth|TAP-|Miniport' }
}

# =============================================================================
# STAGE 1 -- SPOOLER RESET
# =============================================================================

function Invoke-Stage1Spooler {
    Write-Sep
    Write-Log 'STAGE 1/6: Print Spooler Reset'
    Write-Sep2

    $spoolPath = 'C:\Windows\System32\spool\PRINTERS'
    $cleared   = 0; $errors = 0

    # Count pre-existing jobs
    try { $preJobs = @(Get-WmiObject -Class Win32_PrintJob -EA SilentlyContinue).Count } catch { $preJobs = 0 }
    Write-Log "  Pre-reset: $preJobs job(s) in queue(s)"

    # Stop spooler
    Write-Log '  Stopping Spooler...'
    & sc.exe stop Spooler 2>&1 | Out-Null
    $waited = 0
    while ($waited -lt 15) {
        try { $st = (Get-WmiObject -Class Win32_Service -Filter "Name='Spooler'" -EA SilentlyContinue).State } catch { $st = '' }
        if ($st -ne 'Running') { break }
        Start-Sleep 1; $waited++
    }
    Write-Log "  Spooler state after stop: $st"

    # Clear spool files
    if (Test-Path $spoolPath) {
        foreach ($f in @(Get-ChildItem -Path $spoolPath -Force -EA SilentlyContinue | Where-Object { -not $_.PSIsContainer })) {
            try { Remove-Item -LiteralPath $f.FullName -Force -EA Stop; $cleared++ } catch { $errors++ }
        }
    }
    Write-Log "  Spool files cleared: $cleared | errors: $errors"

    # Start spooler
    Write-Log '  Starting Spooler...'
    & sc.exe start Spooler 2>&1 | Out-Null
    $waited = 0
    while ($waited -lt 20) {
        try { $st = (Get-WmiObject -Class Win32_Service -Filter "Name='Spooler'" -EA SilentlyContinue).State } catch { $st = '' }
        if ($st -eq 'Running') { break }
        Start-Sleep 1; $waited++
    }
    Write-Log "  Spooler final state: $st"

    $pass = ($st -eq 'Running')
    try { $printers = @(Get-WmiObject -Class Win32_Printer -EA SilentlyContinue | Where-Object { $_.Name -notmatch 'Microsoft|OneNote|Fax|PDF|XPS|Send To' }).Count } catch { $printers = 0 }
    Write-Log "  Printers: $printers | Stage 1 $(if ($pass) {'PASS'} else {'FAIL'})"
    return @{ Pass = $pass; Cleared = $cleared; Errors = $errors }
}

# =============================================================================
# STAGE 2 -- BROWSER RESET
# =============================================================================

function Invoke-Stage2BrowserReset {
    Write-Sep
    Write-Log 'STAGE 2/6: Browser Factory Reset'
    Write-Sep2

    $removed = 0; $warned = 0; $preserved = 0

    function RmPath { param([string]$U,[string]$B,[string]$P)
        if(-not(Test-Path $P)){return}
        try{Remove-Item -Path $P -Recurse -Force -EA Stop;$script:removed++;Write-Log "    [REMOVED] $U/$B/$(Split-Path $P -Leaf)"}
        catch{$script:warned++;Write-Log "    [WARN] $U/$B/$(Split-Path $P -Leaf): $($_.Exception.Message)" 'WARN'}
    }
    $script:removed=0; $script:warned=0

    # Kill browser processes
    Write-Log '  Stopping browser processes...'
    foreach ($proc in @('chrome','msedge','firefox','brave','opera','vivaldi','waterfox','librewolf','chromium')) {
        $found = Get-Process -Name $proc -EA SilentlyContinue
        if ($found) { $found | Stop-Process -Force -EA SilentlyContinue | Out-Null; Write-Log "  Stopped: $proc ($($found.Count))" }
    }
    Start-Sleep 2

    # Enumerate profiles + load offline hives
    $allProfiles = Get-UserProfiles
    $loadedHives = @()
    foreach ($u in $allProfiles) {
        if (-not (Test-Path "Registry::HKEY_USERS\$($u.SID)")) {
            $loadedHives += $u.SID
            Start-Process 'cmd.exe' -ArgumentList "/C reg.exe LOAD HKU\$($u.SID) `"$($u.UserHive)`"" -Wait -WindowStyle Hidden 2>&1 | Out-Null
        }
    }
    Write-Log "  Profiles found: $($allProfiles.Count)"

    foreach ($u in $allProfiles) {
        Write-Log "  Processing: $($u.UserName)"

        # Chromium browsers
        foreach ($b in @(
            @{L='Chrome';  P="$($u.Path)\AppData\Local\Google\Chrome\User Data"},
            @{L='Edge';    P="$($u.Path)\AppData\Local\Microsoft\Edge\User Data"},
            @{L='Brave';   P="$($u.Path)\AppData\Local\BraveSoftware\Brave-Browser\User Data"},
            @{L='Vivaldi'; P="$($u.Path)\AppData\Local\Vivaldi\User Data"},
            @{L='Opera';   P="$($u.Path)\AppData\Roaming\Opera Software\Opera Stable"},
            @{L='OperaGX'; P="$($u.Path)\AppData\Roaming\Opera Software\Opera GX Stable"},
            @{L='Chromium';P="$($u.Path)\AppData\Local\Chromium\User Data"}
        )) {
            if (-not (Test-Path $b.P)) { continue }
            $profileDirs = Get-ChildItem -Path $b.P -Directory -EA SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' }
            foreach ($dir in $profileDirs) {
                $base = $dir.FullName
                foreach ($p in @("$base\Preferences","$base\Secure Preferences","$base\Extensions","$base\Extension State","$base\Extension Rules","$base\Cookies","$base\Network\Cookies","$base\Session Storage","$base\Local Storage","$base\IndexedDB","$base\Service Worker","$base\databases","$base\Web Data","$base\Web Data-journal","$base\Cache","$base\Cache2","$base\Code Cache","$base\GPUCache","$base\Media Cache","$base\Top Sites","$base\Visited Links","$base\Shortcuts")) {
                    RmPath $u.UserName $b.L $p
                }
            }
            Write-Log "    [PRESERVED] $($u.UserName)/$($b.L): passwords, bookmarks, history"
            $preserved++
        }

        # Firefox browsers
        foreach ($b in @(
            @{L='Firefox';  R="$($u.Path)\AppData\Roaming\Mozilla\Firefox\Profiles";   Lo="$($u.Path)\AppData\Local\Mozilla\Firefox\Profiles"},
            @{L='Waterfox'; R="$($u.Path)\AppData\Roaming\Waterfox\Profiles";          Lo="$($u.Path)\AppData\Local\Waterfox\Profiles"},
            @{L='LibreWolf';R="$($u.Path)\AppData\Roaming\librewolf\Profiles";          Lo="$($u.Path)\AppData\Local\librewolf\Profiles"}
        )) {
            if (-not (Test-Path $b.R)) { continue }
            foreach ($dir in @(Get-ChildItem -Path $b.R -Directory -EA SilentlyContinue)) {
                $base    = $dir.FullName
                $locBase = Join-Path $b.Lo $dir.Name
                foreach ($p in @("$base\prefs.js","$base\user.js","$base\extensions","$base\extensions.json","$base\extension-preferences.json","$base\cookies.sqlite","$base\webappsstore.sqlite","$base\content-prefs.sqlite","$base\storage\default","$base\IndexedDB","$base\formhistory.sqlite","$locBase\cache2")) {
                    RmPath $u.UserName $b.L $p
                }
                Get-ChildItem -Path $base -Filter 'sessionstore*.jsonlz4' -Force -EA SilentlyContinue |
                    ForEach-Object { try{Remove-Item -LiteralPath $_.FullName -Force -EA Stop;$script:removed++}catch{$script:warned++} }
            }
            Write-Log "    [PRESERVED] $($u.UserName)/$($b.L): passwords, bookmarks, history"
            $preserved++
        }
    }

    # Unload hives
    foreach ($sid in $loadedHives) {
        [gc]::Collect(); Start-Sleep 1
        Start-Process 'cmd.exe' -ArgumentList "/C reg.exe UNLOAD HKU\$sid" -Wait -WindowStyle Hidden 2>&1 | Out-Null
    }

    $removed = $script:removed; $warned = $script:warned
    Write-Log "  Stage 2 complete: removed=$removed warned=$warned preserved=$preserved"
    return @{ Removed = $removed; Warned = $warned; Errors = $warned }
}

# =============================================================================
# STAGE 3 -- SYNC RESET (OneDrive + Teams)
# =============================================================================

function Invoke-Stage3SyncReset {
    Write-Sep
    Write-Log 'STAGE 3/6: OneDrive + Teams Sync Reset'
    Write-Sep2

    $totalErrors = 0

    function StopProc { param([string]$N); Get-Process -Name $N -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue | Out-Null }
    function RmSafe {
        param([string]$Path)
        if (-not (Test-Path $Path)) { return }
        try { Remove-Item -LiteralPath $Path -Recurse -Force -EA Stop } catch {}
    }

    $profiles = Get-UserProfiles

    # OneDrive
    Write-Log '  OneDrive Reset'
    StopProc 'OneDrive'
    StopProc 'FileCoAuth'
    Start-Sleep 2
    $odOK = 0; $odErr = 0
    foreach ($u in $profiles) {
        try {
            $pp = $u.Path
            foreach ($p in @("$pp\AppData\Local\Microsoft\OneDrive\logs","$pp\AppData\Local\Microsoft\OneDrive\setup\logs","$pp\AppData\Local\Microsoft\OneDrive\ListSync","$pp\AppData\Local\Microsoft\OneDrive\StandaloneUpdater","$pp\AppData\Local\Microsoft\OneDrive\settings")) {
                RmSafe $p
            }
            $odOK++
            Write-Log "    [OK] $($u.UserName) -- OneDrive cache cleared"
        } catch { $odErr++; Write-Log "    [WARN] $($u.UserName): $($_.Exception.Message)" 'WARN' }
    }
    $totalErrors += $odErr
    Write-Log "  OneDrive reset: $odOK OK, $odErr errors"

    # Teams
    Write-Log '  Teams Reset'
    foreach ($proc in @('Teams','ms-teams','TeamsMeetingAddin')) { StopProc $proc | Out-Null }
    Start-Sleep 2
    $teOK = 0; $teErr = 0
    foreach ($u in $profiles) {
        try {
            $pp = $u.Path
            foreach ($p in @(
                "$pp\AppData\Roaming\Microsoft\Teams\blob_storage",
                "$pp\AppData\Roaming\Microsoft\Teams\Cache",
                "$pp\AppData\Roaming\Microsoft\Teams\databases",
                "$pp\AppData\Roaming\Microsoft\Teams\Code Cache",
                "$pp\AppData\Roaming\Microsoft\Teams\GPUCache",
                "$pp\AppData\Local\Microsoft\Teams\current\resources\locales",
                "$pp\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs",
                "$pp\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\tmp"
            )) { RmSafe $p }
            $teOK++
            Write-Log "    [OK] $($u.UserName) -- Teams cache cleared"
        } catch { $teErr++; Write-Log "    [WARN] $($u.UserName): $($_.Exception.Message)" 'WARN' }
    }
    $totalErrors += $teErr
    Write-Log "  Teams reset: $teOK OK, $teErr errors"

    Write-Log "  Stage 3 complete: errors=$totalErrors"
    return @{ Errors = $totalErrors }
}

# =============================================================================
# STAGE 4 -- APP UPDATER (SILENT)
# =============================================================================

function Get-ExclTier { param([string]$ID)
    if([string]::IsNullOrEmpty($ID)){return 'None'}
    foreach($p in $HardExclPatterns){if($ID -like "$p*" -or $ID -eq $p){return 'Hard'}}
    foreach($p in $SoftExclPatterns){if($ID -like "$p*" -or $ID -eq $p){return 'Soft'}}
    foreach($p in $DeferredPatterns){if($ID -like "$p*" -or $ID -eq $p){return 'Deferred'}}
    foreach($p in $SelfUpdatePatterns){if($ID -like "$p*" -or $ID -eq $p){return 'SelfUpdate'}}
    return 'None'
}

function Test-WinGet {
    # Get-Command only searches PATH -- SYSTEM context doesn't have WindowsApps in PATH
    # Must glob the actual install location
    if ($null -ne (Get-WinGetExe)) { return $true }
    try { return $null -ne (Get-Command winget.exe -EA SilentlyContinue) } catch { return $false }
}
function Test-Choco  { try{$null -ne (Get-Command choco.exe  -EA SilentlyContinue)}catch{$false} }

function Get-WinGetExe {
    $candidates = @(
        'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe'
        "$env:LocalAppData\Microsoft\WindowsApps\winget.exe"
        "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe"
    )
    foreach ($c in $candidates) {
        $f = Get-Item -Path $c -EA SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

function Install-WinGetIfMissing {
    if (Test-WinGet) { Write-Log '  WinGet: already available'; return $true }
    Write-Log '  WinGet not found -- attempting install via asheroto/winget-install...'

    # Step 1: Re-register existing AppxPackage if present (fastest path)
    try {
        $appx = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -EA SilentlyContinue
        if ($appx) {
            Add-AppxPackage -RegisterByFamilyName -MainPackage $appx.PackageFamilyName -EA SilentlyContinue | Out-Null
            Start-Sleep 3
            if (Test-WinGet) { Write-Log '  WinGet: registered via existing AppxPackage'; return $true }
        }
    } catch {}

    # Step 2: Use asheroto/winget-install -- handles SYSTEM context, installs
    # VCLibs + UI.Xaml dependencies first, then registers winget for SYSTEM use.
    # This is the only reliable pattern for SYSTEM context on Datto/RMM agents.
    try {
        Write-Log '  Downloading winget-install script (asheroto)...'
        [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
        $url    = 'https://raw.githubusercontent.com/asheroto/winget-install/master/winget-install.ps1'
        $script = (New-Object System.Net.WebClient).DownloadString($url)
        Invoke-Expression $script
        Start-Sleep 5
        if (Test-WinGet) { Write-Log '  WinGet: installed successfully via winget-install'; return $true }
    } catch { Write-Log "  WinGet install failed: $($_.Exception.Message)" 'WARN' }

    Write-Log '  WinGet: unavailable -- app updates will be limited to Chocolatey' 'WARN'
    return $false
}

function Install-ChocoIfMissing {
    if (Test-Choco) { Write-Log '  Chocolatey: already available'; return $true }
    Write-Log '  Chocolatey not found -- installing...'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
        $env:chocolateyUseWindowsCompression = 'true'
        $script = (New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1')
        Invoke-Expression $script
        if (Test-Choco) { Write-Log '  Chocolatey: installed successfully'; return $true }
    } catch { Write-Log "  Chocolatey install failed: $($_.Exception.Message)" 'WARN' }
    Write-Log '  Chocolatey: unavailable' 'WARN'
    return $false
}

# =============================================================================
# STAGE 0 -- PREREQUISITES (WinGet + Chocolatey)
# =============================================================================

function Invoke-Stage0Prerequisites {
    Write-Sep
    Write-Log 'STAGE 0: Prerequisites (WinGet + Chocolatey)'
    Write-Sep2

    $wgOK = Install-WinGetIfMissing
    $chOK = Install-ChocoIfMissing

    Write-Log "  WinGet: $(if($wgOK){'OK'}else{'UNAVAILABLE'}) | Chocolatey: $(if($chOK){'OK'}else{'UNAVAILABLE'})"

    if (-not $wgOK -and -not $chOK) {
        Write-Log '  ERROR: Neither WinGet nor Chocolatey available -- App Updater will be skipped' 'WARN'
    }

    return @{ WinGet = $wgOK; Choco = $chOK; Errors = if(-not $wgOK -and -not $chOK){1}else{0} }
}

function Get-AppUpdates {
    if(-not(Test-WinGet)){Write-Log '  WinGet not available -- skipping app update scan' 'WARN';return @()}
    $wgExe = Get-WinGetExe
    if(-not $wgExe){$wgExe = 'winget.exe'}   # fallback to PATH
    try {
        $raw = & $wgExe upgrade 2>&1
        $lines = $raw | Where-Object { $_ -match '\S' }
        $hf=$false;$nE=0;$iE=0;$vE=0;$aE=0;$updates=@()
        foreach($line in $lines){
            if($line -match 'Name\s+Id\s+Version\s+Available'){$hf=$true;$nE=$line.IndexOf('Id');$iE=$line.IndexOf('Version');$vE=$line.IndexOf('Available');$aE=$line.IndexOf('Source');if($aE -lt 0){$aE=$line.Length};continue}
            if(-not $hf){continue};if($line -match '^[-\s]+$'){continue};if($line -match 'upgrade.*available|package.*have'){continue}
            if($line.Length -lt $nE){continue}
            try{
                $n=if($line.Length-ge $nE){$line.Substring(0,$nE).Trim()}else{''}
                $id=if($line.Length-ge $iE){$line.Substring($nE,$iE-$nE).Trim()}else{''}
                $v=if($line.Length-ge $vE){$line.Substring($iE,$vE-$iE).Trim()}else{''}
                $av=if($line.Length-ge $aE){$line.Substring($vE,$aE-$vE).Trim()}else{''}
                if([string]::IsNullOrEmpty($id)-or[string]::IsNullOrEmpty($av)){continue}
                $tier=Get-ExclTier -ID $id
                $updates+=@{Name=$n;WinGetID=$id;Version=$v;Available=$av;Tier=$tier;RebootReq=($tier -eq 'Deferred');ChocoID=if($ChocoMap.ContainsKey($id)){$ChocoMap[$id]}else{''}}
            }catch{continue}
        }
        return $updates
    }catch{Write-Log "  WinGet scan failed: $($_.Exception.Message)" 'WARN';return @()}
}

function Update-App { param([hashtable]$App)
    $id=$App.WinGetID;$name=$App.Name
    Write-Log "    Updating: $name ($($App.Version) -> $($App.Available))"
    $wgExe = Get-WinGetExe; if(-not $wgExe){$wgExe='winget.exe'}
    $ok=$false
    try {
        $job=Start-Job -ScriptBlock{param($wgid,$wg)& $wg upgrade --id $wgid --silent --accept-package-agreements --accept-source-agreements --scope machine 2>&1} -ArgumentList $id,$wgExe
        $result=Wait-Job $job -Timeout $UpdateTimeout
        if($null -eq $result){Stop-Job $job -EA SilentlyContinue;Remove-Job $job -EA SilentlyContinue;Write-Log "    [TIMEOUT] $name" 'WARN';return 'Timeout'}
        $out=Receive-Job $job;Remove-Job $job -EA SilentlyContinue;$outs=($out -join ' ')
        if($LASTEXITCODE -eq 0 -or $outs -match 'Successfully installed|No available upgrade'){Write-Log "    [UPDATED] $name";$ok=$true;return 'Updated'}
        elseif($outs -match 'No applicable upgrade'){Write-Log "    [SKIP] $name";return 'Skipped'}
    }catch{Write-Log "    WinGet failed: $($_.Exception.Message)"}
    if(-not $ok -and (Test-Choco) -and -not [string]::IsNullOrEmpty($App.ChocoID)){
        try{
            $job=Start-Job -ScriptBlock{param($cid)& choco.exe upgrade $cid -y --no-progress --limit-output 2>&1} -ArgumentList $App.ChocoID
            $result=Wait-Job $job -Timeout $UpdateTimeout
            if($null -eq $result){Stop-Job $job -EA SilentlyContinue;Remove-Job $job -EA SilentlyContinue;return 'Timeout'}
            $out=Receive-Job $job;Remove-Job $job -EA SilentlyContinue
            if(($out -join ' ') -match 'upgraded|already installed'){Write-Log "    [UPDATED] $name (choco)";return 'Updated'}
        }catch{}
    }
    Write-Log "    [FAIL] $name" 'WARN';return 'Failed'
}

function Invoke-Stage4AppUpdater {
    Write-Sep
    Write-Log 'STAGE 4/6: App Updater (Silent)'
    Write-Sep2

    $hasWG = Test-WinGet; $hasCh = Test-Choco
    Write-Log "  WinGet: $(if($hasWG){'OK'}else{'Missing'}) | Chocolatey: $(if($hasCh){'OK'}else{'Missing'})"

    if(-not $hasWG -and -not $hasCh){
        Write-Log '  No package manager available -- skipping app updates' 'WARN'
        return @{ Updated=0; Failed=0; Skipped=0; Errors=1 }
    }

    $updates = Get-AppUpdates
    $toUpdate = $updates | Where-Object { $t=$_.Tier; $t -ne 'Hard' -and $t -ne 'Custom' -and $t -ne 'SelfUpdate' }
    Write-Log "  Available: $($updates.Count) | To update: $($toUpdate.Count)"

    $updated=0;$failed=0;$skipped=0
    foreach($app in $toUpdate){
        $r = Update-App -App $app
        switch($r){'Updated'{$updated++}'Skipped'{$skipped++}'Timeout'{$failed++}default{$failed++}}
    }

    Write-Log "  Stage 4 complete: updated=$updated failed=$failed skipped=$skipped"
    return @{ Updated=$updated; Failed=$failed; Skipped=$skipped; Errors=$failed }
}

# =============================================================================
# STAGE 5 -- NETWORK RESET (stack reset only -- DHCP renew via post-boot task)
# =============================================================================

function Invoke-Stage5NetworkReset {
    Write-Sep
    Write-Log 'STAGE 6/6: Network Reset -- Scheduling post-exit tasks'
    Write-Sep2

    if(-not(Test-Path $NetResetDir)){New-Item -Path $NetResetDir -Force -EA SilentlyContinue|Out-Null}

    # Snapshot adapters now -- before connectivity is lost -- for logging
    $adapters    = Get-PhysicalAdapters
    $staticFound = @()
    foreach($a in @($adapters)){
        $ip = if($a.IPAddress){$a.IPAddress -join ','}else{'none'}
        $gw = if($a.DefaultIPGateway){$a.DefaultIPGateway -join ','}else{'none'}
        Write-Log "  $($a.Description) | DHCP:$($a.DHCPEnabled) | IP:$ip | GW:$gw"
        if(-not $a.DHCPEnabled){$staticFound+=$a.Description;Write-Log "  WARN: Static IP -- $($a.Description)" 'WARN'}
    }
    if($staticFound.Count -gt 0){
        Write-Log "  WARNING: $($staticFound.Count) static adapter(s) -- settings will be lost after reset" 'WARN'
    }

    # Write the network reset + reboot script that runs AFTER Datto exits
    $netResetExec = "$NetResetDir\NetworkReset-Exec.ps1"
    $execScript = @"
param()
Set-StrictMode -Off
`$ErrorActionPreference = 'Continue'
`$log = '$NetResetDir\NetworkReset-Exec.log'
function WL { param(`$m); Add-Content -Path `$log -Value "[(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] `$m" -EA SilentlyContinue; Write-Host `$m }

WL 'Network stack reset starting...'

# Flush DNS
& ipconfig.exe /flushdns 2>&1 | Out-Null; WL 'DNS flushed'

# Clear ARP
& netsh.exe interface ip delete arpcache 2>&1 | Out-Null; WL 'ARP cleared'

# Release DHCP
`$adapters = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
    Where-Object { `$_.IPEnabled -and `$_.Description -notmatch 'Hyper-V|VMware|VirtualBox|Loopback|Teredo|6to4|ISATAP|Pseudo|WAN Miniport|Bluetooth|TAP-' }
foreach(`$a in @(`$adapters)){if(`$a.DHCPEnabled){try{`$a.ReleaseDHCPLease()|Out-Null;WL "Released: `$(`$a.Description)"}catch{}}}

# Winsock + TCP/IP stack reset
& netsh.exe winsock reset 2>&1 | Out-Null; WL 'Winsock reset'
& netsh.exe int ip reset '$NetResetDir\netsh-ip-reset.log' 2>&1 | Out-Null; WL 'IPv4 stack reset'
& netsh.exe int ipv6 reset 2>&1 | Out-Null; WL 'IPv6 stack reset'
& netsh.exe advfirewall reset 2>&1 | Out-Null; WL 'Firewall reset'

WL 'Network reset complete -- rebooting in 30 seconds'
& msg.exe '*' /TIME:60 'Paladin IT: Network reset complete. Your PC will restart in 30 seconds. This is expected and normal.' 2>&1 | Out-Null
Start-Sleep -Seconds 30
WL 'Initiating reboot'

# Self-delete task before reboot
try { & schtasks.exe /Delete /TN 'Paladin_NetworkReset_Exec' /F 2>&1 | Out-Null } catch {}
& shutdown.exe /r /t 0 /f /c 'Paladin: Network reset complete. DHCP will renew on startup.' 2>&1 | Out-Null
"@

    # Write the post-boot DHCP renew script
    $resumeScript = @'
param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
Start-Sleep -Seconds 15
$adapters = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
    Where-Object { $_.Description -notmatch 'Hyper-V|VMware|VirtualBox|Loopback|Teredo|6to4|ISATAP|Pseudo|WAN Miniport|Bluetooth|TAP-|Miniport' }
$renewed=0;$failed=0
foreach($a in @($adapters)){
    if($a.DHCPEnabled){
        try{Start-Sleep 2;$r=$a.RenewDHCPLease();if($r.ReturnValue -eq 0){$renewed++}else{$failed++}}catch{$failed++}
    }
}
& ipconfig.exe /registerdns 2>&1|Out-Null
& ipconfig.exe /flushdns    2>&1|Out-Null
$msg="PASS $(Get-Date -Format 'yyyy-MM-dd HH:mm') | NetworkReset+Renew | Renewed:$renewed Failed:$failed"
try{New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' -Name 'Custom8' -Value $msg -PropertyType String -Force -EA SilentlyContinue|Out-Null}catch{}
try{& schtasks.exe /Delete /TN 'Paladin_NetworkReset_Resume' /F 2>&1|Out-Null}catch{}
try{Remove-Item -LiteralPath $PSCommandPath -Force -EA SilentlyContinue}catch{}
try{Remove-Item -Path 'HKLM:\SOFTWARE\Paladin\NetworkReset' -Recurse -Force -EA SilentlyContinue}catch{}
'@

    try {
        # Write exec script
        [System.IO.File]::WriteAllText($netResetExec, $execScript, [System.Text.Encoding]::ASCII)

        # Write resume script
        [System.IO.File]::WriteAllText($NetResetScript, $resumeScript, [System.Text.Encoding]::ASCII)

        # Register exec task -- fires 60s after script exits (ONCE, SYSTEM)
        & schtasks.exe /Delete /TN 'Paladin_NetworkReset_Exec' /F 2>&1 | Out-Null
        $execCmd = "$PsExe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$netResetExec`""
        $runTime = (Get-Date).AddSeconds(60).ToString('HH:mm')
        & schtasks.exe /Create /TN 'Paladin_NetworkReset_Exec' /TR $execCmd /SC ONCE /ST $runTime /RU SYSTEM /RL HIGHEST /F 2>&1 | Out-Null
        Write-Log "  Network Reset task registered: fires at $runTime (60s from now)"

        # Register resume task -- fires 1min after next startup (ONSTART)
        & schtasks.exe /Delete /TN $NetResetTask /F 2>&1 | Out-Null
        $resumeCmd = "$PsExe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$NetResetScript`""
        & schtasks.exe /Create /TN $NetResetTask /TR $resumeCmd /SC ONSTART /RU SYSTEM /RL HIGHEST /DELAY 0001:00 /F 2>&1 | Out-Null
        Write-Log "  DHCP renew task registered: '$NetResetTask' -- fires 1min after reboot"

    } catch { Write-Log "  WARN: Could not register network reset tasks: $($_.Exception.Message)" 'WARN' }

    Write-Log '  Stage 6 scheduled. Script will exit cleanly. Network reset fires 60s post-exit.'
    return @{ Errors = 0; StaticAdapters = $staticFound.Count }
}

# =============================================================================
# STAGE 6 -- WINDOWS UPDATE
# =============================================================================

function Invoke-Stage6WindowsUpdate {
    Write-Sep
    Write-Log "STAGE 5/6: Windows Update ($WUAction)"
    Write-Sep2

    $WUScanTimeout    = 180   # 3 min max for scan
    $WUInstallTimeout = 2700  # 45 min max for download+install

    # Last update date -- quick COM call, wrap in try so it never blocks
    try {
        $s = New-Object -ComObject Microsoft.Update.Searcher -EA Stop
        $hc = $s.GetTotalHistoryCount()
        if ($hc -gt 0) {
            $h = $s.QueryHistory(0, [Math]::Min($hc, 50))
            for ($i = 0; $i -lt $h.Count; $i++) {
                $e = $h.Item($i)
                if ($e.ResultCode -eq 2 -and $null -ne $e.Date) {
                    $days = [int]((Get-Date) - $e.Date).TotalDays
                    Write-Log "  Last update: $($e.Date.ToString('yyyy-MM-dd')) ($days days ago)"
                    break
                }
            }
        }
    } catch {}

    # --- SCAN (job-wrapped with timeout) ---
    Write-Log '  Scanning for pending updates (timeout: 3 min)...'
    $scanJob = Start-Job -ScriptBlock {
        param($action)
        $out = @{ Updates = @(); Error = $null }
        try {
            $session  = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $searcher.ServerSelection = 0
            $result   = $searcher.Search('IsInstalled=0 and IsHidden=0')
            for ($i = 0; $i -lt $result.Updates.Count; $i++) {
                $u    = $result.Updates.Item($i)
                $kbs  = @()
                for ($k = 0; $k -lt $u.KBArticleIDs.Count; $k++) { $kbs += "KB$($u.KBArticleIDs.Item($k))" }
                $out.Updates += @{
                    Title    = $u.Title
                    KBs      = if ($kbs.Count -gt 0) { $kbs -join ',' } else { 'N/A' }
                    SizeMB   = [Math]::Round($u.MaxDownloadSize / 1MB, 1)
                    RebootReq= ($u.InstallationBehavior.RebootBehavior -gt 0)
                }
            }
        } catch { $out.Error = $_.Exception.Message }
        return $out
    } -ArgumentList $WUAction

    $scanResult = Wait-Job $scanJob -Timeout $WUScanTimeout
    if ($null -eq $scanResult) {
        Stop-Job  $scanJob -EA SilentlyContinue
        Remove-Job $scanJob -EA SilentlyContinue
        Write-Log '  WARN: WU scan timed out after 3 min -- skipping (non-fatal)' 'WARN'
        return @{ Pending=0; Installed=0; Failed=0; Errors=0; ScanFailed=$true }
    }

    $scanData = Receive-Job $scanJob
    Remove-Job $scanJob -EA SilentlyContinue

    if ($scanData.Error) {
        Write-Log "  WARN: WU scan error: $($scanData.Error) -- skipping (non-fatal)" 'WARN'
        return @{ Pending=0; Installed=0; Failed=0; Errors=0; ScanFailed=$true }
    }

    $pending = $scanData.Updates
    Write-Log "  Pending updates: $($pending.Count)"
    foreach ($u in $pending) { Write-Log "    $($u.KBs) -- $($u.Title.Substring(0,[Math]::Min($u.Title.Length,70)))" }

    if ($WUAction -eq 'Report' -or $pending.Count -eq 0) {
        Write-Log "  $(if($pending.Count -eq 0){'No updates needed'}else{'Report mode -- scan only'})"
        return @{ Pending=$pending.Count; Installed=0; Failed=0; Errors=0 }
    }

    # --- INSTALL (job-wrapped with timeout) ---
    # COM objects can't cross job boundary -- job does full download+install internally
    Write-Log "  Installing $($pending.Count) update(s) (timeout: 45 min)..."
    $installJob = Start-Job -ScriptBlock {
        param($titles)
        $out = @{ Installed=0; Failed=0; RebootNeeded=$false; Error=$null }
        try {
            $session    = New-Object -ComObject Microsoft.Update.Session
            $searcher   = $session.CreateUpdateSearcher()
            $searcher.ServerSelection = 0
            $result     = $searcher.Search('IsInstalled=0 and IsHidden=0')
            $coll       = New-Object -ComObject Microsoft.Update.UpdateColl
            for ($i = 0; $i -lt $result.Updates.Count; $i++) {
                $u = $result.Updates.Item($i)
                if ($titles -contains $u.Title) { $coll.Add($u) | Out-Null }
            }
            if ($coll.Count -eq 0) { return $out }
            $dl = $session.CreateUpdateDownloader()
            $dl.Updates = $coll
            $dl.Download() | Out-Null
            $inst = $session.CreateUpdateInstaller()
            $inst.Updates = $coll
            $inst.AllowSourcePrompts = $false
            $ir = $inst.Install()
            $out.RebootNeeded = $ir.RebootRequired
            for ($i = 0; $i -lt $coll.Count; $i++) {
                $rc = $ir.GetUpdateResult($i).ResultCode
                if ($rc -eq 2) { $out.Installed++ } else { $out.Failed++ }
            }
        } catch { $out.Error = $_.Exception.Message; $out.Failed = $titles.Count }
        return $out
    } -ArgumentList @(,$pending.Title)

    Write-Log '  Download + install in progress...'
    $installResult = Wait-Job $installJob -Timeout $WUInstallTimeout
    if ($null -eq $installResult) {
        Stop-Job  $installJob -EA SilentlyContinue
        Remove-Job $installJob -EA SilentlyContinue
        Write-Log "  WARN: WU install timed out after 45 min" 'WARN'
        return @{ Pending=$pending.Count; Installed=0; Failed=$pending.Count; Errors=1 }
    }

    $ir = Receive-Job $installJob
    Remove-Job $installJob -EA SilentlyContinue

    if ($ir.Error) { Write-Log "  WARN: Install error: $($ir.Error)" 'WARN' }
    Write-Log "  Stage 5 complete: installed=$($ir.Installed) failed=$($ir.Failed) rebootNeeded=$($ir.RebootNeeded)"
    return @{ Pending=$pending.Count; Installed=$ir.Installed; Failed=$ir.Failed; RebootNeeded=$ir.RebootNeeded; Errors=$ir.Failed }
}

# =============================================================================
# MAIN
# =============================================================================
if(-not(Test-Path $BaseDir)){New-Item $BaseDir -ItemType Directory -Force -EA SilentlyContinue|Out-Null}

$startTime = Get-Date

Write-Sep
Write-Log "Paladin Update & Reset v$ScriptVer | Site: $SiteName | Machine: $MachineName"
Write-Log "AllowReboot: $AllowReboot | WUAction: $WUAction | UDF: $UDFSlot"
Write-Sep

$s0 = Invoke-Stage0Prerequisites; Start-Sleep 3
$s1 = Invoke-Stage1Spooler;       Start-Sleep 3
$s2 = Invoke-Stage2BrowserReset;  Start-Sleep 3
$s3 = Invoke-Stage3SyncReset;     Start-Sleep 3
$s4 = Invoke-Stage4AppUpdater;    Start-Sleep 3
$s5 = Invoke-Stage6WindowsUpdate; Start-Sleep 3
$s6 = Invoke-Stage5NetworkReset

# =============================================================================
# FINAL REPORT
# =============================================================================
$elapsed     = [int]((Get-Date) - $startTime).TotalMinutes
$totalErrors = 0
if($s0.Errors -gt 0){$totalErrors++}
if(-not $s1.Pass)   {$totalErrors++}
if($s2.Errors -gt 0){$totalErrors++}
if($s3.Errors -gt 0){$totalErrors++}
if($s4.Errors -gt 0){$totalErrors++}
if($s5.Errors -gt 0){$totalErrors++}
if($s6.Errors -gt 0){$totalErrors++}

Write-Sep
Write-Log "PALADIN UPDATE & RESET -- FINAL REPORT"
Write-Log "Site     : $SiteName | Machine: $MachineName"
Write-Log "Duration : ${elapsed}m | Errors: $totalErrors"
Write-Sep
Write-Log "Stage 0 -- Prerequisites  : WinGet=$(if($s0.WinGet){'OK'}else{'FAIL'}) Choco=$(if($s0.Choco){'OK'}else{'FAIL'})"
Write-Log "Stage 1 -- Spooler Reset  : $(if($s1.Pass){'PASS'}else{'FAIL'}) | cleared=$($s1.Cleared)"
Write-Log "Stage 2 -- Browser Reset  : removed=$($s2.Removed) warned=$($s2.Warned)"
Write-Log "Stage 3 -- Sync Reset     : errors=$($s3.Errors)"
Write-Log "Stage 4 -- App Updater    : updated=$($s4.Updated) failed=$($s4.Failed) skipped=$($s4.Skipped)"
Write-Log "Stage 5 -- Windows Update : pending=$($s5.Pending) installed=$($s5.Installed) failed=$($s5.Failed)$(if($s5.ScanFailed){' [SCAN FAILED -- non-fatal]'})"
Write-Log "Stage 6 -- Network Reset  : scheduled (fires 60s after script exits)"
if($s6.StaticAdapters -gt 0){Write-Log "           WARNING: $($s6.StaticAdapters) static adapter(s) -- verify IPs after reboot" 'WARN'}
Write-Sep

$ts     = Get-Date -Format 'yyyy-MM-dd HH:mm'
$rebootNote = if($AllowReboot -and $totalErrors -eq 0){' | NetReset+Reboot:scheduled'}else{''}
$udfMsg = "$(if($totalErrors -eq 0){'PASS'}else{'WARN'}) $ts | $MachineName | AppUpd:$($s4.Updated) WU:$($s5.Installed) Err:$totalErrors$rebootNote"
Set-DattoUDF -Slot $UDFSlot -Value $udfMsg

# =============================================================================
# WARN USER + EXIT CLEANLY
# Datto gets a clean exit. Scheduled tasks fire after:
#   T+60s  -- Paladin_NetworkReset_Exec  (reset stack, notify user, reboot)
#   T+boot -- Paladin_NetworkReset_Resume (DHCP renew + DNS re-register)
# =============================================================================
if($AllowReboot -and $totalErrors -eq 0){
    Write-Log 'All stages complete. Network reset and reboot scheduled via task scheduler.'
    Write-Log 'Paladin_NetworkReset_Exec fires in ~60s -- will reset network stack then reboot.'
    Write-Log 'Script exiting cleanly now so Datto records success.'
    Show-UserMessage 'Maintenance complete. Your internet will disconnect briefly in ~60 seconds, then your PC will restart automatically. Please SAVE ALL OPEN WORK now.'
} elseif($AllowReboot -and $totalErrors -gt 0){
    Write-Log "AllowReboot=true but $totalErrors error(s) -- network reset and reboot tasks NOT scheduled." 'WARN'
    Write-Log 'Review errors above before manually rescheduling.'
}

exit $(if($totalErrors -eq 0){0}else{1})
