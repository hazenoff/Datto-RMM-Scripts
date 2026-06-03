#Requires -Version 3.0
<#
.SYNOPSIS
    Paladin Software Installer [WIN]
    Paladin Business Consulting | Datto RMM Component

.DESCRIPTION
    Installs selected software silently via winget (primary) with direct
    download/EXE fallback. HIPAA-compliant audit log on every run.

    INPUT VARIABLES (Boolean checkboxes in Datto job UI):
      InstallChrome      Boolean  false  -- Google Chrome
      InstallTeams       Boolean  false  -- Microsoft Teams
      InstallOffice365   Boolean  false  -- Microsoft 365 Apps (Current channel, ODT install, proxy-aware, sig-verified)
      Install8x8         Boolean  false  -- 8x8 Work for Desktop (EXE, per-user)
      InstallDotNet      Boolean  false  -- .NET Desktop Runtime 6, 8, 9 x64
      InstallVCRedist    Boolean  false  -- VC++ Redistributables x64 (2013, 2015+)
      InstallWinDirStat  Boolean  false  -- WinDirStat
      InstallZoom        Boolean  false  -- Zoom

    AUDIT LOG: C:\ProgramData\Paladin\SoftwareInstall\SoftwareInstall.log
    LOG ACL:   SYSTEM + Administrators only (HIPAA-compliant)
    UDF SLOT:  7

    Paladin Business Consulting | Internal Use Only
    Version: 1.0.0 | Min OS: Windows 10 1809 / Server 2019
#>

param()
Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ===========================================================================
# INPUT VARIABLES
# Datto Boolean injects as string "true"/"false" -- compare with -eq 'true'
# ===========================================================================
function Get-BoolVar {
    param([string]$Name)
    $val = [System.Environment]::GetEnvironmentVariable($Name)
    return ($null -ne $val -and $val.Trim().ToLower() -eq 'true')
}

$DoChrome      = Get-BoolVar 'InstallChrome'
$DoTeams       = Get-BoolVar 'InstallTeams'
$DoOffice365   = Get-BoolVar 'InstallOffice365'
$Do8x8         = Get-BoolVar 'Install8x8'
$DoDotNet      = Get-BoolVar 'InstallDotNet'
$DoVCRedist    = Get-BoolVar 'InstallVCRedist'
$DoWinDirStat  = Get-BoolVar 'InstallWinDirStat'
$DoZoom        = Get-BoolVar 'InstallZoom'

# Build selection list for logging (no credential values logged)
$selections = @()
if ($DoChrome)     { $selections += 'chrome' }
if ($DoTeams)      { $selections += 'teams' }
if ($DoOffice365)  { $selections += 'office365' }
if ($Do8x8)        { $selections += '8x8' }
if ($DoDotNet)     { $selections += 'dotnet' }
if ($DoVCRedist)   { $selections += 'vcredist' }
if ($DoWinDirStat) { $selections += 'windirstat' }
if ($DoZoom)       { $selections += 'zoom' }

if ($selections.Count -eq 0) {
    Write-Host 'ERROR: No software selected. Set at least one Install* variable to true.'
    exit 1
}

# ===========================================================================
# CONSTANTS
# ===========================================================================
$LogDir   = 'C:\ProgramData\Paladin\SoftwareInstall'
$LogFile  = "$LogDir\SoftwareInstall.log"
$TempDir  = 'C:\ProgramData\Paladin\SoftwareInstall\Temp'
$UDFSlot  = 7
$UDFPath  = 'HKLM:\SOFTWARE\CentraStage'
$UDFName  = "Custom$UDFSlot"
$MaxLogMB = 5

$script:Installed = 0
$script:Skipped   = 0
$script:Failed    = 0

# ===========================================================================
# AUDIT / HIPAA LOGGING
# ===========================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -EA SilentlyContinue } catch {}
}

function Write-Sep { Write-Log ('=' * 60) }

function Set-UDF {
    param([string]$Text)
    $v = $Text.Substring(0, [Math]::Min($Text.Length, 255))
    try {
        if (-not (Test-Path $UDFPath)) { New-Item -Path $UDFPath -Force -EA SilentlyContinue | Out-Null }
        New-ItemProperty -Path $UDFPath -Name $UDFName -Value $v -PropertyType String -Force -EA SilentlyContinue | Out-Null
    } catch {}
}

function Initialize-Log {
    foreach ($d in @($LogDir, $TempDir)) {
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force -EA SilentlyContinue | Out-Null }
    }
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile -EA SilentlyContinue).Length / 1MB) -gt $MaxLogMB) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Move-Item -LiteralPath $LogFile -Destination "$LogFile.$stamp.bak" -Force -EA SilentlyContinue
    }
    # HIPAA: ACL -- SYSTEM + Administrators only
    try {
        $acl = Get-Acl -Path $LogDir -EA Stop
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl','ContainerInherit,ObjectInherit','None','Allow')))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators','FullControl','ContainerInherit,ObjectInherit','None','Allow')))
        Set-Acl -Path $LogDir -AclObject $acl -EA Stop
    } catch { Write-Log "WARN: Could not harden log ACL: $($_.Exception.Message)" 'WARN' }
}

# ===========================================================================
# WINGET HELPERS
# ===========================================================================

function Get-WingetPath {
    # winget under SYSTEM requires explicit path -- not in PATH by default
    $candidates = @(
        "$env:LocalAppData\Microsoft\WindowsApps\winget.exe"
        'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe'
        "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe"
    )
    foreach ($c in $candidates) {
        $found = Get-Item -Path $c -EA SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    # Last resort: search WindowsApps
    $wa = Get-ChildItem 'C:\Program Files\WindowsApps' -Filter 'winget.exe' -Recurse -EA SilentlyContinue |
          Sort-Object FullName -Descending | Select-Object -First 1
    if ($wa) { return $wa.FullName }
    return $null
}

function Install-Bootstrap-Winget {
    Write-Log 'winget not found -- attempting bootstrap via Add-AppxPackage'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -EA Stop
        Start-Sleep -Seconds 5
        Write-Log 'winget bootstrap complete'
        return $true
    } catch {
        Write-Log "winget bootstrap failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Invoke-Winget {
    param([string]$WingetPath, [string]$PackageId, [string]$Label, [string]$ExtraArgs = '')
    Write-Log "  [winget] Installing: $Label ($PackageId)"
    $args = "install --id $PackageId -e --silent --accept-package-agreements --accept-source-agreements $ExtraArgs"
    try {
        $proc = Start-Process -FilePath $WingetPath -ArgumentList $args `
                    -Wait -PassThru -WindowStyle Hidden -EA Stop
        if ($proc.ExitCode -eq 0) {
            Write-Log "  [INSTALLED] $Label via winget. Exit: 0"
            $script:Installed++
            return $true
        } elseif ($proc.ExitCode -eq -1978335189) {
            Write-Log "  [SKIPPED] $Label already installed (winget exit -1978335189)"
            $script:Skipped++
            return $true
        } else {
            Write-Log "  [WARN] winget exited $($proc.ExitCode) for $Label" 'WARN'
            return $false
        }
    } catch {
        Write-Log "  [WARN] winget threw exception for $Label : $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Invoke-DirectInstall {
    param([string]$Label, [string]$Url, [string]$FileName, [string]$Args = '')
    Write-Log "  [direct] Downloading $Label from $Url"
    $dest = "$TempDir\$FileName"
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $dest)
        Write-Log "  [direct] Download complete. Installing..."
        # Start-Process -ArgumentList fails on PS3.0 if value is empty -- branch on it
        if ([string]::IsNullOrEmpty($Args)) {
            $proc = Start-Process -FilePath $dest -Wait -PassThru -WindowStyle Hidden -EA Stop
        } else {
            $proc = Start-Process -FilePath $dest -ArgumentList $Args -Wait -PassThru -WindowStyle Hidden -EA Stop
        }
        Remove-Item $dest -Force -EA SilentlyContinue
        if ($proc.ExitCode -in @(0, 3010, 1641)) {
            Write-Log "  [INSTALLED] $Label via direct download. Exit: $($proc.ExitCode)"
            $script:Installed++
            return $true
        } else {
            Write-Log "  [FAILED] $Label direct install exit: $($proc.ExitCode)" 'ERROR'
            $script:Failed++
            return $false
        }
    } catch {
        Write-Log "  [FAILED] $Label direct download/install: $($_.Exception.Message)" 'ERROR'
        $script:Failed++
        return $false
    }
}

# ===========================================================================
# SOFTWARE DEFINITIONS
# ===========================================================================
# Each entry: winget ID, display label, fallback URL, fallback filename, fallback args

function Install-Chrome {
    param([string]$wg)
    Write-Log '[Installing] Google Chrome'
    if ($wg -and (Invoke-Winget $wg 'Google.Chrome' 'Google Chrome')) { return }
    Invoke-DirectInstall 'Google Chrome' `
        'https://dl.google.com/chrome/install/latest/chrome_installer.exe' `
        'ChromeSetup.exe' '/silent /install'
}

function Install-Teams {
    param([string]$wg)
    Write-Log '[Installing] Microsoft Teams'

    # Detection -- check registry and known install paths before attempting install
    $teamsInstalled = $false
    $teamsRegPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Teams',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Teams',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Teams'
    )
    foreach ($rp in $teamsRegPaths) {
        if (Test-Path $rp) { $teamsInstalled = $true; break }
    }

    # Also check per-user profile install paths
    if (-not $teamsInstalled) {
        $profiles = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -EA SilentlyContinue |
                    Where-Object { $_.PSChildName -match 'S-1-5-21-(\d+-?){4}$|S-1-12-1-(\d+-?){4}$' }
        foreach ($prof in $profiles) {
            $pp = $prof.ProfileImagePath
            if (-not $pp) { continue }
            $teamsPaths = @(
                "$pp\AppData\Local\Microsoft\Teams\current\Teams.exe",
                "$pp\AppData\Local\Microsoft\TeamsMeetingAddin",
                "$pp\AppData\Local\Packages\MSTeams_8wekyb3d8bbwe"
            )
            foreach ($tp in $teamsPaths) {
                if (Test-Path $tp) { $teamsInstalled = $true; break }
            }
            if ($teamsInstalled) { break }
        }
    }

    if ($teamsInstalled) {
        Write-Log '  [SKIPPED] Microsoft Teams already installed (detected on disk/registry)'
        $script:Skipped++
        return
    }

    # Not installed -- try winget first, then direct download
    if ($wg -and (Invoke-Winget $wg 'Microsoft.Teams' 'Microsoft Teams')) { return }

    # Force TLS 1.2 -- Teams CDN requires it
    [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
    Invoke-DirectInstall 'Microsoft Teams' `
        'https://statics.teams.cdn.office.net/production-windows-x86/lkg/MSTeamsSetup.exe' `
        'TeamsSetup.exe' ''
}

function Install-Office365 {
    param([string]$wg)
    Write-Log '[Installing] Microsoft 365 Apps (Office) -- Current Channel'
    Write-Log '  Logic ported from Datto ComStore "Microsoft 365 Apps (Office) [WIN]" build 49/seagull'

    # TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)

    $varScriptChannel = 'Current'
    $varArch          = if ([IntPtr]::Size -eq 4) { '32' } else { '64' }
    $varInstallDir    = 'C:\Windows\Temp\OfficeInstall'

    # ── Proxy detection via Datto agent config ───────────────────────────
    $useProxy = $false
    try {
        $configPath = if ([IntPtr]::Size -eq 4) {
            "$env:ProgramFiles\CentraStage\CagService.exe.config"
        } else {
            "${env:ProgramFiles(x86)}\CentraStage\CagService.exe.config"
        }
        [xml]$platXML = Get-Content $configPath -EA Stop
        $settings = $platXML.configuration.applicationSettings.'CentraStage.Cag.Core.AppSettings'.setting
        $proxyLoc  = ($settings | Where-Object { $_.Name -eq 'ProxyIp'   }).value
        $proxyPort = ($settings | Where-Object { $_.Name -eq 'ProxyPort' }).value
        $proxyType = ($settings | Where-Object { $_.Name -eq 'ProxyType' }).value
        if ($proxyType -gt 0 -and $proxyLoc -and $proxyPort) { $useProxy = $true }
    } catch {}

    function Get-OfficeFile {
        param([string]$Url, [string]$Dest)
        $wc = New-Object System.Net.WebClient
        $wc.UseDefaultCredentials = $true
        $wc.Headers.Add('X-FORMS_BASED_AUTH_ACCEPTED', 'f')
        $wc.Headers.Add([System.Net.HttpRequestHeader]::UserAgent,
            'Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.2; .NET CLR 1.0.3705;)')
        if ($useProxy) {
            $wc.Proxy = New-Object System.Net.WebProxy("${proxyLoc}:${proxyPort}", $true)
        }
        $wc.DownloadFile($Url, $Dest)
    }

    # ── Check if Office C2R is already installed ─────────────────────────
    # Use hardcoded paths -- $env:CommonProgramFiles unreliable under SYSTEM
    $c2rPaths = @(
        'C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe'
        'C:\Program Files (x86)\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe'
    )
    $c2rRegKey  = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $c2rRegKey2 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration'

    $c2rClient    = $c2rPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    $c2rRegExists = (Test-Path $c2rRegKey) -or (Test-Path $c2rRegKey2)

    if ($c2rClient -or $c2rRegExists) {
        Write-Log '  Office 365 already installed (C2R detected) -- skipping reinstall'
        $script:Skipped++
        return
    }

    # ── Fresh install via ODT ─────────────────────────────────────────────
    Write-Log '  No existing Office install detected -- performing fresh install via ODT'
    if (-not (Test-Path $varInstallDir)) {
        New-Item $varInstallDir -ItemType Directory -Force | Out-Null
    }

    # Build ODT config XML
    $varEdition     = 'O365ProPlusRetail'
    $varLangID      = 'en-us'
    $varExclusion   = 'Lync,OneDrive,OneNote,Bing'
    $varCompanyName = $env:CS_PROFILE_NAME
    if ([string]::IsNullOrEmpty($varCompanyName)) { $varCompanyName = 'Company' }

    [xml]$varConfig     = New-Object System.Xml.XmlDocument
    $varConfigRoot      = $varConfig.CreateNode('element','Configuration',$null)
    $xAdd               = $varConfig.CreateNode('element','Add',$null)
    $xAdd.SetAttribute('OfficeClientEdition', $varArch)
    $xAdd.SetAttribute('Channel', $varScriptChannel)
    $xAdd.SetAttribute('MigrateArch', 'TRUE')
    $varConfigRoot.AppendChild($xAdd) | Out-Null
    $xProduct           = $varConfig.CreateNode('element','Product',$null)
    $xProduct.SetAttribute('ID', $varEdition)
    $xAdd.AppendChild($xProduct) | Out-Null
    $xLang              = $varConfig.CreateNode('element','Language',$null)
    $xLang.SetAttribute('ID', $varLangID)
    $xProduct.AppendChild($xLang) | Out-Null
    $xLangOS            = $varConfig.CreateNode('element','Language',$null)
    $xLangOS.SetAttribute('ID', 'MatchOS')
    $xProduct.AppendChild($xLangOS) | Out-Null
    foreach ($exc in $varExclusion.Split(',')) {
        $xExc = $varConfig.CreateNode('element','ExcludeApp',$null)
        $xExc.SetAttribute('ID', $exc.Trim())
        $xProduct.AppendChild($xExc) | Out-Null
    }
    foreach ($pair in @('SharedComputerLicensing=0','PinIconsToTaskbar=FALSE','AUTOACTIVATE=0','FORCEAPPSHUTDOWN=FALSE')) {
        $k,$v = $pair -split '='
        $xProp = $varConfig.CreateNode('element','Property',$null)
        $xProp.SetAttribute('Name', $k); $xProp.SetAttribute('Value', $v)
        $varConfigRoot.AppendChild($xProp) | Out-Null
    }
    $xUpdates = $varConfig.CreateNode('element','Updates',$null)
    $xUpdates.SetAttribute('Enabled','TRUE')
    $varConfigRoot.AppendChild($xUpdates) | Out-Null
    $xRemove = $varConfig.CreateNode('element','RemoveMSI',$null)
    $varConfigRoot.AppendChild($xRemove) | Out-Null
    $xDisplay = $varConfig.CreateNode('element','Display',$null)
    $xDisplay.SetAttribute('Level','None'); $xDisplay.SetAttribute('AcceptEULA','TRUE')
    $varConfigRoot.AppendChild($xDisplay) | Out-Null
    $xLog = $varConfig.CreateNode('element','Logging',$null)
    $xLog.SetAttribute('Level','Standard')
    $xLog.SetAttribute('Path', $varInstallDir)
    $varConfigRoot.AppendChild($xLog) | Out-Null
    $varConfig.AppendChild($varConfigRoot) | Out-Null
    $configXmlPath = "$varInstallDir\DRMMConfig.xml"
    $varConfig.Save($configXmlPath)
    Write-Log "  Config XML written: $configXmlPath"

    # Download ODT -- scrape latest URL from Microsoft download page
    try {
        Write-Log '  Downloading Office Deployment Tool...'
        $odtPageDest = "$varInstallDir\ODTLink.html"
        Get-OfficeFile 'https://www.microsoft.com/en-us/download/details.aspx?id=49117' $odtPageDest
        $odtLink = (Get-Content $odtPageDest) -split '"' |
                   Select-String 'exe' | Select-String 'download.microsoft.com' |
                   Select-Object -First 1
        $odtLink = $odtLink.ToString().Trim()
        $odtDest = "$varInstallDir\ODTool.exe"
        Get-OfficeFile $odtLink $odtDest
        Write-Log "  ODT downloaded: $odtDest"
    } catch {
        Write-Log "  [FAILED] ODT download failed: $($_.Exception.Message)" 'ERROR'
        $script:Failed++
        return
    }

    # Verify ODT digital signature
    try {
        $sig = Get-AuthenticodeSignature $odtDest
        if ($sig.Status.value__ -ne 0) {
            Write-Log '  [FAILED] ODT digital signature invalid -- possible tampering' 'ERROR'
            $script:Failed++
            return
        }
        Write-Log '  ODT digital signature verified OK'
    } catch {
        Write-Log "  [WARN] Could not verify ODT signature: $($_.Exception.Message)" 'WARN'
    }

    # Extract ODT
    Start-Process $odtDest -ArgumentList "/extract:`"$varInstallDir`" /quiet /norestart" -Wait -WindowStyle Hidden
    $setupExe = "$varInstallDir\setup.exe"
    if (-not (Test-Path $setupExe)) {
        Write-Log '  [FAILED] ODT extraction did not produce setup.exe' 'ERROR'
        $script:Failed++
        return
    }

    # Run Office setup
    Write-Log '  Running Office setup -- this may take 15-30 minutes...'
    $proc = Start-Process $setupExe -ArgumentList "/configure `"$configXmlPath`"" -Wait -PassThru -WindowStyle Hidden
    if ($proc.ExitCode -in @(0, 3010)) {
        Write-Log "  [INSTALLED] Microsoft 365 Apps. Exit: $($proc.ExitCode)"
        $script:Installed++
    } else {
        Write-Log "  [WARN] Office setup exit: $($proc.ExitCode) -- check $varInstallDir\*.log" 'WARN'
        $script:Skipped++
    }
}


function Install-8x8 {
    param([string]$wg)
    Write-Log '[Installing] 8x8 Work for Desktop (EXE -- per-user via scheduled task)'
    Write-Log '  8x8 EXE installs to %LOCALAPPDATA% -- must run as logged-on user, not SYSTEM'
    Write-Log '  Strategy: SYSTEM downloads EXE, scheduled task runs it as logged-on user'

    # Step 1: Find the logged-on user
    $loggedOnUser = $null

    # Primary: Win32_ComputerSystem.UserName -- most reliable under SYSTEM
    try {
        $cs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
        if ($null -ne $cs -and -not [string]::IsNullOrEmpty($cs.UserName)) {
            $loggedOnUser = ($cs.UserName -split '\\')[-1]
        }
    } catch {}

    # Fallback: query user (shows USERNAME not session name)
    if ([string]::IsNullOrEmpty($loggedOnUser)) {
        try {
            $qResult = & query user 2>&1
            foreach ($line in $qResult) {
                if ($line -match 'Active') {
                    $loggedOnUser = ($line.Trim() -split '\s+')[0].TrimStart('>')
                    break
                }
            }
        } catch {}
    }
    Write-Log "  Logged-on user: $loggedOnUser"

    # Step 2: Resolve latest EXE URL from 8x8 download page
    # Falls back to a known-good URL if scrape fails
    $exeUrl = $null
    try {
        $page = (New-Object System.Net.WebClient).DownloadString('https://support-portal.8x8.com/helpcenter/viewArticle.html?d=8bff4970-6fbf-4daf-842d-8ae9b533153d')
        if ($page -match 'href="(https://work-desktop-assets\.8x8\.com/prod-publish/ga/work-64-exe-[^"]+\.exe)"') {
            $exeUrl = $Matches[1]
            Write-Log "  Resolved latest URL: $exeUrl"
        }
    } catch { Write-Log "  WARN: Could not scrape latest URL -- using fallback" 'WARN' }

    if ([string]::IsNullOrEmpty($exeUrl)) {
        # Fallback: stable latest redirect (may not always exist but worth trying)
        $exeUrl = 'https://work-desktop-assets.8x8.com/prod-publish/ga/work-64-exe-v8.33.2-2.exe'
        Write-Log "  Using fallback URL: $exeUrl"
    }

    # Step 3: Download as SYSTEM to a world-readable temp path
    $exeDest = 'C:\ProgramData\Paladin\SoftwareInstall\Temp\8x8WorkSetup.exe'
    try {
        Write-Log '  Downloading 8x8 Work EXE...'
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($exeUrl, $exeDest)
        Write-Log "  Download complete: $exeDest"
    } catch {
        Write-Log "  [FAILED] 8x8 download: $($_.Exception.Message)" 'ERROR'
        $script:Failed++
        return
    }

    # Step 4: Create scheduled task to run installer as logged-on user
    # Task runs once immediately, then deletes itself
    $taskName = 'Paladin_8x8Install'
    $logPath  = 'C:\ProgramData\Paladin\SoftwareInstall\8x8Install.log'

    try {
        # Remove any stale task
        & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null

        # Create task -- individual args avoid all quoting/splitting issues
        $null = & schtasks.exe /Create /TN $taskName /TR $exeDest /SC ONCE /ST 00:00 /RU $loggedOnUser /IT /F /RL HIGHEST 2>&1

        # Run it now
        & schtasks.exe /Run /TN $taskName 2>&1 | Out-Null
        Write-Log "  Scheduled task launched as user: $loggedOnUser"

        # Wait up to 3 minutes for install to complete
        $waited   = 0
        $maxWait  = 180
        $interval = 10
        $complete = $false

        while ($waited -lt $maxWait) {
            Start-Sleep -Seconds $interval
            $waited += $interval
            # Check if 8x8 is now installed (look for installed EXE in AppData)
            $profiles = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -EA SilentlyContinue |
                        Where-Object { (Split-Path $_.ProfileImagePath -Leaf) -eq $loggedOnUser }
            foreach ($prof in $profiles) {
                $installCheck = "$($prof.ProfileImagePath)\AppData\Local\8x8-Work"
                if (Test-Path $installCheck) {
                    $complete = $true
                    break
                }
            }
            if ($complete) { break }
            Write-Log "  Waiting for 8x8 install... (${waited}s elapsed)"
        }

        # Clean up task and installer
        & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
        Remove-Item $exeDest -Force -EA SilentlyContinue

        if ($complete) {
            Write-Log "  [INSTALLED] 8x8 Work EXE installed for user: $loggedOnUser"
            Write-Log "  Auto-updates enabled -- 8x8 will self-update from here"
            $script:Installed++
        } else {
            Write-Log "  [WARN] 8x8 install task ran but install directory not detected after ${maxWait}s" 'WARN'
            Write-Log "  8x8 may have installed correctly -- verify manually on the machine"
            $script:Skipped++
        }
    } catch {
        Write-Log "  [FAILED] 8x8 scheduled task install: $($_.Exception.Message)" 'ERROR'
        & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
        Remove-Item $exeDest -Force -EA SilentlyContinue
        $script:Failed++
    }
}

function Install-DotNet {
    param([string]$wg)
    Write-Log '[Installing] .NET Runtimes x64 (Desktop Runtime 6, 8, 9)'
    # Install Desktop Runtime for each major supported version
    # Desktop Runtime covers WinForms/WPF apps -- most common client need
    $runtimes = @(
        @{ Id='Microsoft.DotNet.DesktopRuntime.6'; Label='.NET 6 Desktop Runtime x64' },
        @{ Id='Microsoft.DotNet.DesktopRuntime.8'; Label='.NET 8 Desktop Runtime x64' },
        @{ Id='Microsoft.DotNet.DesktopRuntime.9'; Label='.NET 9 Desktop Runtime x64' }
    )
    foreach ($rt in $runtimes) {
        if ($wg) {
            if (-not (Invoke-Winget $wg $rt.Id $rt.Label '--architecture x64')) {
                # Fallback: direct download from Microsoft
                $ver = $rt.Id -replace 'Microsoft.DotNet.DesktopRuntime.',''
                $dlUrl = "https://dotnet.microsoft.com/download/dotnet/$ver"
                Write-Log "  [INFO] winget failed for $($rt.Label) -- visit $dlUrl for manual install"
                $script:Skipped++
            }
        } else {
            Write-Log "  [SKIP] winget unavailable for $($rt.Label) -- no direct fallback URL (version-specific)" 'WARN'
            $script:Skipped++
        }
    }
}

function Install-VCRedist {
    param([string]$wg)
    Write-Log '[Installing] Visual C++ Redistributables x64'
    $redists = @(
        @{ Id='Microsoft.VCRedist.2013.x64';  Label='VC++ 2013 x64';      Url='https://download.microsoft.com/download/2/E/6/2E61CFA4-993B-4DD4-91DA-3737CD5CD6E3/vcredist_x64.exe' },
        @{ Id='Microsoft.VCRedist.2015+.x64'; Label='VC++ 2015-2022 x64'; Url='https://aka.ms/vs/17/release/vc_redist.x64.exe' }
    )
    foreach ($r in $redists) {
        if ($wg) {
            if (Invoke-Winget $wg $r.Id $r.Label) { continue }
        }
        # Direct fallback
        $fname = Split-Path $r.Url -Leaf
        Invoke-DirectInstall $r.Label $r.Url $fname '/install /quiet /norestart'
    }
}

function Install-WinDirStat {
    param([string]$wg)
    Write-Log '[Installing] WinDirStat'
    if ($wg -and (Invoke-Winget $wg 'WinDirStat.WinDirStat' 'WinDirStat')) { return }
    Invoke-DirectInstall 'WinDirStat' `
        'https://github.com/windirstat/windirstat/releases/download/v2.1.0/windirstat2_1_0_setup.exe' `
        'WinDirStatSetup.exe' '/S'
}

function Install-Zoom {
    param([string]$wg)
    Write-Log '[Installing] Zoom'
    if ($wg -and (Invoke-Winget $wg 'Zoom.Zoom' 'Zoom')) { return }
    Invoke-DirectInstall 'Zoom' `
        'https://zoom.us/client/latest/ZoomInstallerFull.exe' `
        'ZoomSetup.exe' '/silent /install'
}


# ===========================================================================
# MAIN
# ===========================================================================

Initialize-Log

$machineName = $env:COMPUTERNAME
$domainName  = $env:USERDOMAIN
$osCaption   = (Get-WmiObject Win32_OperatingSystem -EA SilentlyContinue).Caption
$runAs       = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$siteName    = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }
$startTime   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

Write-Sep
Write-Log 'PALADIN SOFTWARE INSTALLER -- AUDIT LOG'
Write-Log "Script Version : 1.0.0"
Write-Log "Timestamp      : $startTime"
Write-Log "Machine        : $machineName"
Write-Log "Domain         : $domainName"
Write-Log "OS             : $osCaption"
Write-Log "Run As         : $runAs"
Write-Log "Datto Site     : $siteName"
Write-Log "Selection      : $($selections -join ', ')"  # credential vars not logged
Write-Sep

Set-UDF "SoftwareInstall: Running $(($selections -join ',').Substring(0,[Math]::Min(($selections -join ',').Length,40))) | $machineName | $startTime"

# Locate winget
Write-Log '[Setup] Locating winget...'
$wingetPath = Get-WingetPath
if ($null -eq $wingetPath) {
    Write-Log 'winget not found -- attempting bootstrap'
    Install-Bootstrap-Winget | Out-Null
    $wingetPath = Get-WingetPath
}
if ($null -ne $wingetPath) {
    Write-Log "winget found: $wingetPath"
} else {
    Write-Log 'winget unavailable -- will use direct download fallbacks only' 'WARN'
}

# Accept winget source agreements silently (required under SYSTEM)
if ($null -ne $wingetPath) {
    try {
        & $wingetPath source update --disable-interactivity 2>&1 | Out-Null
    } catch {}
}

# Create temp dir
if (-not (Test-Path $TempDir)) { New-Item $TempDir -ItemType Directory -Force | Out-Null }

# Dispatch installs -- driven by Boolean flags
Write-Sep
if ($DoChrome)     { Write-Sep; Install-Chrome     $wingetPath }
if ($DoTeams)      { Write-Sep; Install-Teams      $wingetPath }
if ($DoOffice365)  { Write-Sep; Install-Office365  $wingetPath }
if ($Do8x8)        { Write-Sep; Install-8x8        $wingetPath }
if ($DoDotNet)     { Write-Sep; Install-DotNet     $wingetPath }
if ($DoVCRedist)   { Write-Sep; Install-VCRedist   $wingetPath }
if ($DoWinDirStat) { Write-Sep; Install-WinDirStat $wingetPath }
if ($DoZoom)       { Write-Sep; Install-Zoom       $wingetPath }

# Cleanup temp
Remove-Item $TempDir -Recurse -Force -EA SilentlyContinue

# ===========================================================================
# FINAL AUDIT RECORD
# ===========================================================================
$endTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-Sep
Write-Log 'FINAL AUDIT RECORD'
Write-Log "Machine        : $machineName"
Write-Log "Domain         : $domainName"
Write-Log "Started        : $startTime"
Write-Log "Completed      : $endTime"
Write-Log "Run As         : $runAs"
Write-Log "Requested      : $($selections -join ', ')"
Write-Log "Installed      : $($script:Installed)"
Write-Log "Skipped        : $($script:Skipped) (already installed or unavailable)"
Write-Log "Failed         : $($script:Failed)"
Write-Log "Log            : $LogFile"
Write-Sep

$exitCode = if ($script:Failed -gt 0) { 1 } else { 0 }

if ($exitCode -eq 0) {
    $msg = "SoftwareInstall: OK Installed:$($script:Installed) Skipped:$($script:Skipped) | $machineName | $endTime"
    Write-Log "SUCCESS: $($script:Installed) installed, $($script:Skipped) skipped, $($script:Failed) failed."
} else {
    $msg = "SoftwareInstall: WARN Installed:$($script:Installed) Failed:$($script:Failed) | $machineName | $endTime"
    Write-Log "COMPLETE WITH FAILURES: $($script:Failed) item(s) failed. Review log: $LogFile" 'WARN'
}
Set-UDF $msg
exit $exitCode
