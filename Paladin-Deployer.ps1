#Requires -Version 3.0
<#
.SYNOPSIS
    Paladin Software Deployer [WIN]
    Paladin Business Consulting | Datto RMM Component | Single-File

.DESCRIPTION
    Self-contained software deployment GUI for Datto RMM.
    
    When run as SYSTEM (Datto context): detects logged-on user, copies
    self to staging path, launches self as user via scheduled task.
    
    When run as user (-GUIMode): presents WPF GUI with full app catalog,
    template management, and installation engine.

    INSTALL SOURCES (in priority order):
      1. Winget    -- 60,000+ packages, always latest
      2. Chocolatey -- fallback for anything winget misses
      3. Custom    -- our own install logic for 8x8, Office, Teams, etc.
      4. EXE/MSI   -- manual upload or URL via the custom install panel

    TEMPLATES: Saved per-site to C:\ProgramData\Paladin\Deployer\Templates\
               Site name auto-populated from CS_PROFILE_NAME.

    NO FILE ATTACHMENTS REQUIRED. Single component, single script.

    Paladin Business Consulting | Internal Use Only
    Version: 1.0.0
#>

param(
    [switch]$GUIMode,
    [string]$SiteName = ''
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# SHARED CONSTANTS
# =============================================================================
$BaseDir     = 'C:\ProgramData\Paladin\Deployer'
$TemplateDir = "$BaseDir\Templates"
$LogDir      = "$BaseDir\Logs"
$TempDir     = "$BaseDir\Temp"
$SelfDest    = "$BaseDir\Paladin-Deployer.ps1"
$TaskName    = 'Paladin_Deployer_GUI'

# =============================================================================
# DATTO LAUNCHER (SYSTEM context)
# Runs when invoked as a Datto component -- launches GUI as logged-on user
# =============================================================================
if (-not $GUIMode) {

    function Write-DattoLog {
        param([string]$Msg)
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Msg"
    }

    Write-DattoLog 'Paladin Software Deployer v1.0.0'
    Write-DattoLog 'Mode: Datto SYSTEM launcher'

    # Create dirs
    foreach ($d in @($BaseDir, $TemplateDir, $LogDir, $TempDir)) {
        if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force | Out-Null }
    }

    # Copy self to fixed staging path
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $SelfDest -Force -EA Stop
        Write-DattoLog "Script staged: $SelfDest"
    } catch {
        Write-DattoLog "ERROR: Could not stage script: $($_.Exception.Message)"
        exit 1
    }

    # Get logged-on user
    $loggedOnUser = $null
    try {
        $cs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
        if ($null -ne $cs -and -not [string]::IsNullOrEmpty($cs.UserName)) {
            $loggedOnUser = ($cs.UserName -split '\\')[-1]
        }
    } catch {}

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

    if ([string]::IsNullOrEmpty($loggedOnUser)) {
        Write-DattoLog 'ERROR: No logged-on user found. A user must be logged in to run the GUI.'
        exit 1
    }
    Write-DattoLog "Logged-on user: $loggedOnUser"

    # Site name from Datto env var
    $site = $env:CS_PROFILE_NAME
    if ([string]::IsNullOrEmpty($site)) { $site = 'Default' }
    Write-DattoLog "Site: $site"

    # Launch GUI as logged-on user
    $psArgs = "-NonInteractive -ExecutionPolicy Bypass -File `"$SelfDest`" -GUIMode -SiteName `"$site`""
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    $null = & schtasks.exe /Create /TN $TaskName /TR "PowerShell.exe $psArgs" `
        /SC ONCE /ST 00:00 /RU $loggedOnUser /IT /F /RL HIGHEST 2>&1
    & schtasks.exe /Run /TN $TaskName 2>&1 | Out-Null

    Write-DattoLog 'GUI launched successfully. Tech can now interact with the deployer on the endpoint.'
    Write-DattoLog "Templates stored at: $TemplateDir"
    Start-Sleep -Seconds 5
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    exit 0
}

# =============================================================================
# GUI MODE -- everything below runs as the logged-on user
# =============================================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

foreach ($d in @($TemplateDir, $LogDir, $TempDir)) {
    if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force | Out-Null }
}

$SessionLog = "$LogDir\Deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# =============================================================================
# APP CATALOG
# Source: 'winget' | 'choco' | 'custom' | 'both'
# Custom = our own install logic embedded below
# Both   = winget primary, choco fallback
# =============================================================================
$AppCatalog = [ordered]@{

    'Browsers' = @(
        [PSCustomObject]@{ Name='Google Chrome';          Id='chrome';        Source='custom'; WingetId='Google.Chrome';                   Choco='googlechrome'        }
        [PSCustomObject]@{ Name='Mozilla Firefox';        Id='firefox';       Source='both';   WingetId='Mozilla.Firefox';                 Choco='firefox'             }
        [PSCustomObject]@{ Name='Microsoft Edge';         Id='edge';          Source='both';   WingetId='Microsoft.Edge';                  Choco='microsoft-edge'      }
        [PSCustomObject]@{ Name='Brave Browser';          Id='brave';         Source='both';   WingetId='Brave.Brave';                     Choco='brave'               }
        [PSCustomObject]@{ Name='Vivaldi';                Id='vivaldi';       Source='both';   WingetId='Vivaldi.Vivaldi';                 Choco='vivaldi'             }
        [PSCustomObject]@{ Name='Opera';                  Id='opera';         Source='both';   WingetId='Opera.Opera';                     Choco='opera'               }
    )

    'Communication' = @(
        [PSCustomObject]@{ Name='Microsoft Teams';        Id='teams';         Source='custom'; WingetId='Microsoft.Teams';                 Choco='microsoft-teams'     }
        [PSCustomObject]@{ Name='Zoom';                   Id='zoom';          Source='both';   WingetId='Zoom.Zoom';                       Choco='zoom'                }
        [PSCustomObject]@{ Name='Slack';                  Id='slack';         Source='both';   WingetId='SlackTechnologies.Slack';          Choco='slack'               }
        [PSCustomObject]@{ Name='8x8 Work';               Id='8x8';           Source='custom'; WingetId='';                                Choco=''                    }
        [PSCustomObject]@{ Name='Cisco Webex';            Id='webex';         Source='both';   WingetId='Cisco.WebexTeams';                Choco='webex-teams'         }
        [PSCustomObject]@{ Name='Skype';                  Id='skype';         Source='both';   WingetId='Microsoft.Skype';                 Choco='skype'               }
        [PSCustomObject]@{ Name='Discord';                Id='discord';       Source='both';   WingetId='Discord.Discord';                 Choco='discord'             }
        [PSCustomObject]@{ Name='Signal';                 Id='signal';        Source='both';   WingetId='OpenWhisperSystems.Signal';        Choco='signal'              }
    )

    'Microsoft / Office' = @(
        [PSCustomObject]@{ Name='Microsoft 365 Apps';     Id='office365';     Source='custom'; WingetId='';                                Choco=''                    }
        [PSCustomObject]@{ Name='.NET Runtime 6 x64';     Id='dotnet6';       Source='both';   WingetId='Microsoft.DotNet.DesktopRuntime.6'; Choco='dotnet-6.0-desktopruntime' }
        [PSCustomObject]@{ Name='.NET Runtime 8 x64';     Id='dotnet8';       Source='both';   WingetId='Microsoft.DotNet.DesktopRuntime.8'; Choco='dotnet-8.0-desktopruntime' }
        [PSCustomObject]@{ Name='.NET Runtime 9 x64';     Id='dotnet9';       Source='both';   WingetId='Microsoft.DotNet.DesktopRuntime.9'; Choco='dotnet-9.0-desktopruntime' }
        [PSCustomObject]@{ Name='VC++ 2013 x64';          Id='vcredist2013';  Source='custom'; WingetId='Microsoft.VCRedist.2013.x64';     Choco='vcredist2013'        }
        [PSCustomObject]@{ Name='VC++ 2015-2022 x64';     Id='vcredist';      Source='custom'; WingetId='Microsoft.VCRedist.2015+.x64';    Choco='vcredist140'         }
        [PSCustomObject]@{ Name='OneDrive';               Id='onedrive';      Source='both';   WingetId='Microsoft.OneDrive';              Choco='onedrive'            }
        [PSCustomObject]@{ Name='PowerBI Desktop';        Id='powerbi';       Source='both';   WingetId='Microsoft.PowerBI';               Choco='powerbi'             }
    )

    'Adobe' = @(
        [PSCustomObject]@{ Name='Adobe Acrobat Reader';   Id='adobereader';   Source='both';   WingetId='Adobe.Acrobat.Reader.64-bit';     Choco='adobereader'         }
        [PSCustomObject]@{ Name='Adobe AIR';              Id='adobeair';      Source='choco';  WingetId='';                                Choco='adobeair'            }
        [PSCustomObject]@{ Name='Adobe Creative Cloud';   Id='adobecc';       Source='both';   WingetId='Adobe.CreativeCloud';             Choco='adobe-creative-cloud'}
    )

    'Utilities' = @(
        [PSCustomObject]@{ Name='7-Zip';                  Id='7zip';          Source='both';   WingetId='7zip.7zip';                       Choco='7zip'                }
        [PSCustomObject]@{ Name='WinRAR';                 Id='winrar';        Source='both';   WingetId='RARLab.WinRAR';                   Choco='winrar'              }
        [PSCustomObject]@{ Name='WinDirStat';             Id='windirstat';    Source='custom'; WingetId='WinDirStat.WinDirStat';           Choco='windirstat'          }
        [PSCustomObject]@{ Name='TreeSize Free';          Id='treesize';      Source='both';   WingetId='JAMSoftware.TreeSize.Free';       Choco='treesizefree'        }
        [PSCustomObject]@{ Name='Notepad++';              Id='notepadpp';     Source='both';   WingetId='Notepad++.Notepad++';             Choco='notepadplusplus'     }
        [PSCustomObject]@{ Name='Greenshot';              Id='greenshot';     Source='both';   WingetId='Greenshot.Greenshot';             Choco='greenshot'           }
        [PSCustomObject]@{ Name='paint.net';              Id='paintnet';      Source='both';   WingetId='dotPDN.PaintDotNet';              Choco='paint.net'           }
        [PSCustomObject]@{ Name='BGInfo';                 Id='bginfo';        Source='both';   WingetId='Microsoft.Sysinternals.BGInfo';   Choco='bginfo'              }
        [PSCustomObject]@{ Name='BareTail';               Id='baretail';      Source='choco';  WingetId='';                                Choco='baretail'            }
        [PSCustomObject]@{ Name='Autoruns';               Id='autoruns';      Source='both';   WingetId='Microsoft.Sysinternals.Autoruns'; Choco='autoruns'            }
        [PSCustomObject]@{ Name='CPU-Z';                  Id='cpuz';          Source='both';   WingetId='CPUID.CPU-Z';                     Choco='cpu-z'               }
        [PSCustomObject]@{ Name='HWiNFO';                 Id='hwinfo';        Source='both';   WingetId='REALiX.HWiNFO';                  Choco='hwinfo'              }
        [PSCustomObject]@{ Name='CrystalDiskInfo';        Id='crystaldisk';   Source='both';   WingetId='CrystalDewWorld.CrystalDiskInfo'; Choco='crystaldiskinfo'     }
    )

    'Remote Access' = @(
        [PSCustomObject]@{ Name='AnyDesk';                Id='anydesk';       Source='both';   WingetId='AnyDesk.AnyDesk';                 Choco='anydesk'             }
        [PSCustomObject]@{ Name='TeamViewer';             Id='teamviewer';    Source='both';   WingetId='TeamViewer.TeamViewer';            Choco='teamviewer'          }
        [PSCustomObject]@{ Name='PuTTY';                  Id='putty';         Source='both';   WingetId='PuTTY.PuTTY';                     Choco='putty'               }
        [PSCustomObject]@{ Name='MobaXterm';              Id='mobaxterm';     Source='both';   WingetId='Mobatek.MobaXterm';               Choco='mobaxterm'           }
        [PSCustomObject]@{ Name='RoyalTS';                Id='royalts';       Source='both';   WingetId='RoyalApps.RoyalTS';               Choco='royalts'             }
    )

    'File Transfer' = @(
        [PSCustomObject]@{ Name='FileZilla';              Id='filezilla';     Source='both';   WingetId='TimKosse.FileZilla.Client';        Choco='filezilla'           }
        [PSCustomObject]@{ Name='WinSCP';                 Id='winscp';        Source='both';   WingetId='WinSCP.WinSCP';                    Choco='winscp'              }
        [PSCustomObject]@{ Name='Cyberduck';              Id='cyberduck';     Source='both';   WingetId='Cyberduck.Cyberduck';              Choco='cyberduck'           }
    )

    'Security' = @(
        [PSCustomObject]@{ Name='Malwarebytes';           Id='malwarebytes';  Source='both';   WingetId='Malwarebytes.Malwarebytes';        Choco='malwarebytes'        }
        [PSCustomObject]@{ Name='Bitwarden';              Id='bitwarden';     Source='both';   WingetId='Bitwarden.Bitwarden';              Choco='bitwarden'           }
        [PSCustomObject]@{ Name='KeePass';                Id='keepass';       Source='both';   WingetId='DominikReichl.KeePass';            Choco='keepass'             }
        [PSCustomObject]@{ Name='Wireshark';              Id='wireshark';     Source='both';   WingetId='WiresharkFoundation.Wireshark';    Choco='wireshark'           }
        [PSCustomObject]@{ Name='Nmap';                   Id='nmap';          Source='both';   WingetId='Insecure.Nmap';                    Choco='nmap'                }
    )

    'Media' = @(
        [PSCustomObject]@{ Name='VLC Media Player';       Id='vlc';           Source='both';   WingetId='VideoLAN.VLC';                     Choco='vlc'                 }
        [PSCustomObject]@{ Name='Spotify';                Id='spotify';       Source='both';   WingetId='Spotify.Spotify';                  Choco='spotify'             }
        [PSCustomObject]@{ Name='HandBrake';              Id='handbrake';     Source='both';   WingetId='HandBrake.HandBrake';              Choco='handbrake'           }
        [PSCustomObject]@{ Name='OBS Studio';             Id='obs';           Source='both';   WingetId='OBSProject.OBSStudio';             Choco='obs-studio'          }
        [PSCustomObject]@{ Name='GIMP';                   Id='gimp';          Source='both';   WingetId='GIMP.GIMP';                        Choco='gimp'                }
        [PSCustomObject]@{ Name='Inkscape';               Id='inkscape';      Source='both';   WingetId='Inkscape.Inkscape';                Choco='inkscape'            }
    )

    'Development' = @(
        [PSCustomObject]@{ Name='Visual Studio Code';     Id='vscode';        Source='both';   WingetId='Microsoft.VisualStudioCode';       Choco='vscode'              }
        [PSCustomObject]@{ Name='Git';                    Id='git';           Source='both';   WingetId='Git.Git';                          Choco='git'                 }
        [PSCustomObject]@{ Name='Python 3';               Id='python3';       Source='both';   WingetId='Python.Python.3';                  Choco='python3'             }
        [PSCustomObject]@{ Name='Node.js LTS';            Id='nodejs';        Source='both';   WingetId='OpenJS.NodeJS.LTS';                Choco='nodejs-lts'          }
        [PSCustomObject]@{ Name='Postman';                Id='postman';       Source='both';   WingetId='Postman.Postman';                  Choco='postman'             }
        [PSCustomObject]@{ Name='Docker Desktop';         Id='docker';        Source='both';   WingetId='Docker.DockerDesktop';             Choco='docker-desktop'      }
    )

    'Printing / PDF' = @(
        [PSCustomObject]@{ Name='Foxit PDF Reader';       Id='foxit';         Source='both';   WingetId='Foxit.FoxitReader';                Choco='foxitreader'         }
        [PSCustomObject]@{ Name='PDFCreator';             Id='pdfcreator';    Source='both';   WingetId='PDFForge.PDFCreator';              Choco='pdfcreator'          }
        [PSCustomObject]@{ Name='CutePDF Writer';         Id='cutepdf';       Source='choco';  WingetId='';                                 Choco='cutepdf'             }
        [PSCustomObject]@{ Name='Sumatra PDF';            Id='sumatrapdf';    Source='both';   WingetId='SumatraPDF.SumatraPDF';           Choco='sumatrapdf'          }
    )

    'Cloud Storage' = @(
        [PSCustomObject]@{ Name='Dropbox';                Id='dropbox';       Source='both';   WingetId='Dropbox.Dropbox';                  Choco='dropbox'             }
        [PSCustomObject]@{ Name='Google Drive';           Id='googledrive';   Source='both';   WingetId='Google.GoogleDrive';               Choco='googledrive'         }
        [PSCustomObject]@{ Name='Box Drive';              Id='boxdrive';      Source='both';   WingetId='Box.Box';                          Choco='box'                 }
    )

    'Accounting / Business' = @(
        [PSCustomObject]@{ Name='QuickBooks Desktop';     Id='quickbooks';    Source='custom'; WingetId='';                                 Choco=''                    }
        [PSCustomObject]@{ Name='Slack';                  Id='slack2';        Source='both';   WingetId='SlackTechnologies.Slack';           Choco='slack'               }
        [PSCustomObject]@{ Name='Citrix Workspace';       Id='citrix';        Source='both';   WingetId='Citrix.Workspace';                 Choco='citrix-workspace'    }
    )
}

# =============================================================================
# INSTALL ENGINE -- HELPERS
# =============================================================================

function Get-WingetExe {
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

function Get-ChocoExe {
    $c = 'C:\ProgramData\chocolatey\bin\choco.exe'
    if (Test-Path $c) { return $c }
    return $null
}

function Install-ChocoIfMissing {
    param([scriptblock]$Logger)
    & $Logger "Installing Chocolatey..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
        $env:chocolateyUseWindowsCompression = 'true'
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
        $p = Get-ChocoExe
        if ($p) { & $Logger "Chocolatey installed: $p"; return $p }
    } catch { & $Logger "Chocolatey install failed: $($_.Exception.Message)" }
    return $null
}

function Invoke-WingetInstall {
    param([string]$WingetPath, [string]$PackageId, [string]$Label, [scriptblock]$Logger, [string]$ExtraArgs = '')
    & $Logger "  [winget] $Label ($PackageId)"
    $argList = "install --id $PackageId -e --silent --accept-package-agreements --accept-source-agreements $ExtraArgs"
    try {
        $proc = Start-Process -FilePath $WingetPath -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden -EA Stop
        switch ($proc.ExitCode) {
            0            { & $Logger "  [OK] Installed via winget";       return 'ok'      }
            -1978335189  { & $Logger "  [SKIP] Already installed";        return 'skipped' }
            default      { & $Logger "  [WARN] winget exit $($proc.ExitCode)"; return 'fail' }
        }
    } catch {
        & $Logger "  [WARN] winget threw: $($_.Exception.Message)"
        return 'fail'
    }
}

function Invoke-ChocoInstall {
    param([string]$ChocoPath, [string]$Package, [string]$Label, [scriptblock]$Logger)
    & $Logger "  [choco] $Label ($Package)"
    try {
        $out = & $ChocoPath install $Package -y --no-progress --ignore-checksums 2>&1
        $out | ForEach-Object { & $Logger "  $_" }
        if ($LASTEXITCODE -eq 0) { & $Logger "  [OK] Installed via Chocolatey"; return 'ok' }
        & $Logger "  [FAILED] choco exit $LASTEXITCODE"
        return 'fail'
    } catch {
        & $Logger "  [FAILED] choco threw: $($_.Exception.Message)"
        return 'fail'
    }
}

function Invoke-DirectDownloadInstall {
    param([string]$Url, [string]$FileName, [string]$Args, [string]$Label, [scriptblock]$Logger)
    $dest = "$TempDir\$FileName"
    & $Logger "  [direct] Downloading $Label..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
        (New-Object System.Net.WebClient).DownloadFile($Url, $dest)
    } catch {
        & $Logger "  [FAILED] Download: $($_.Exception.Message)"
        return 'fail'
    }
    try {
        if ([string]::IsNullOrEmpty($Args)) {
            $proc = Start-Process -FilePath $dest -Wait -PassThru -WindowStyle Hidden -EA Stop
        } else {
            $proc = Start-Process -FilePath $dest -ArgumentList $Args -Wait -PassThru -WindowStyle Hidden -EA Stop
        }
        Remove-Item $dest -Force -EA SilentlyContinue
        if ($proc.ExitCode -in @(0,3010,1641)) {
            & $Logger "  [OK] Installed. Exit: $($proc.ExitCode)"
            return 'ok'
        }
        & $Logger "  [FAILED] Installer exit: $($proc.ExitCode)"
        return 'fail'
    } catch {
        & $Logger "  [FAILED] Install threw: $($_.Exception.Message)"
        return 'fail'
    }
}

# =============================================================================
# CUSTOM INSTALL FUNCTIONS
# =============================================================================

function Install-ChromeApp {
    param([string]$Wg, [scriptblock]$Logger)
    & $Logger '[Installing] Google Chrome'
    if ($Wg) {
        $r = Invoke-WingetInstall $Wg 'Google.Chrome' 'Google Chrome' $Logger
        if ($r -ne 'fail') { return $r }
    }
    return Invoke-DirectDownloadInstall `
        'https://dl.google.com/chrome/install/latest/chrome_installer.exe' `
        'ChromeSetup.exe' '/silent /install' 'Chrome' $Logger
}

function Install-TeamsApp {
    param([string]$Wg, [scriptblock]$Logger)
    & $Logger '[Installing] Microsoft Teams'

    # Detection first
    $teamsPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Teams',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Teams'
    )
    foreach ($rp in $teamsPaths) {
        if (Test-Path $rp) {
            & $Logger '  [SKIP] Teams already installed (registry detected)'
            return 'skipped'
        }
    }

    if ($Wg) {
        $r = Invoke-WingetInstall $Wg 'Microsoft.Teams' 'Microsoft Teams' $Logger
        if ($r -ne 'fail') { return $r }
    }
    [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
    return Invoke-DirectDownloadInstall `
        'https://statics.teams.cdn.office.net/production-windows-x86/lkg/MSTeamsSetup.exe' `
        'TeamsSetup.exe' '' 'Teams' $Logger
}

function Install-Office365App {
    param([string]$Wg, [scriptblock]$Logger)
    & $Logger '[Installing] Microsoft 365 Apps'

    # Already installed check
    $c2rPaths = @(
        'C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe'
        'C:\Program Files (x86)\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe'
    )
    $c2rRegKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\ClickToRun\Configuration'
    )
    $found = ($c2rPaths | Where-Object { Test-Path $_ } | Select-Object -First 1)
    if (-not $found) { $found = ($c2rRegKeys | Where-Object { Test-Path $_ } | Select-Object -First 1) }
    if ($found) {
        & $Logger '  [SKIP] Office 365 already installed (C2R detected)'
        return 'skipped'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
    $odtDir  = "$TempDir\ODT"
    if (-not (Test-Path $odtDir)) { New-Item $odtDir -ItemType Directory -Force | Out-Null }

    # Scrape latest ODT URL
    & $Logger '  Downloading Office Deployment Tool...'
    $odtUrl = $null
    try {
        $html = (New-Object System.Net.WebClient).DownloadString('https://www.microsoft.com/en-us/download/details.aspx?id=49117')
        $odtUrl = ($html -split '"' | Select-String 'download.microsoft.com' | Select-String '\.exe' | Select-Object -First 1).ToString().Trim()
    } catch {}
    if (-not $odtUrl) {
        $odtUrl = 'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_19029-20136.exe'
    }

    $odtExe = "$TempDir\ODTool.exe"
    try { (New-Object System.Net.WebClient).DownloadFile($odtUrl, $odtExe) }
    catch { & $Logger "  [FAILED] ODT download: $($_.Exception.Message)"; return 'fail' }

    # Verify signature
    try {
        $sig = Get-AuthenticodeSignature $odtExe
        if ($sig.Status.value__ -ne 0) { & $Logger '  [FAILED] ODT signature invalid'; return 'fail' }
        & $Logger '  ODT signature OK'
    } catch {}

    # Build config XML
    $varArch = if ([IntPtr]::Size -eq 8) { '64' } else { '32' }
    $siteName = $env:CS_PROFILE_NAME
    if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'Paladin' }

    [xml]$cfg  = New-Object System.Xml.XmlDocument
    $root      = $cfg.CreateNode('element','Configuration',$null)
    $add       = $cfg.CreateNode('element','Add',$null)
    $add.SetAttribute('OfficeClientEdition',$varArch)
    $add.SetAttribute('Channel','Current')
    $add.SetAttribute('MigrateArch','TRUE')
    $root.AppendChild($add) | Out-Null
    $prod = $cfg.CreateNode('element','Product',$null)
    $prod.SetAttribute('ID','O365ProPlusRetail')
    $add.AppendChild($prod) | Out-Null
    foreach ($lid in @('en-us','MatchOS')) {
        $lang = $cfg.CreateNode('element','Language',$null)
        $lang.SetAttribute('ID',$lid)
        $prod.AppendChild($lang) | Out-Null
    }
    foreach ($exc in @('Lync','OneDrive','OneNote','Bing')) {
        $x = $cfg.CreateNode('element','ExcludeApp',$null); $x.SetAttribute('ID',$exc)
        $prod.AppendChild($x) | Out-Null
    }
    foreach ($pair in @('SharedComputerLicensing=0','AUTOACTIVATE=0','FORCEAPPSHUTDOWN=FALSE','PinIconsToTaskbar=FALSE')) {
        $k,$v = $pair -split '='
        $p = $cfg.CreateNode('element','Property',$null)
        $p.SetAttribute('Name',$k); $p.SetAttribute('Value',$v)
        $root.AppendChild($p) | Out-Null
    }
    $disp = $cfg.CreateNode('element','Display',$null)
    $disp.SetAttribute('Level','None'); $disp.SetAttribute('AcceptEULA','TRUE')
    $root.AppendChild($disp) | Out-Null
    $upd = $cfg.CreateNode('element','Updates',$null); $upd.SetAttribute('Enabled','TRUE')
    $root.AppendChild($upd) | Out-Null
    $rmsi = $cfg.CreateNode('element','RemoveMSI',$null)
    $root.AppendChild($rmsi) | Out-Null
    $cfg.AppendChild($root) | Out-Null
    $cfgPath = "$odtDir\config.xml"
    $cfg.Save($cfgPath)

    # Extract ODT
    Start-Process $odtExe -ArgumentList "/extract:`"$odtDir`" /quiet /norestart" -Wait -WindowStyle Hidden
    $setup = "$odtDir\setup.exe"
    if (-not (Test-Path $setup)) { & $Logger '  [FAILED] ODT extraction failed'; return 'fail' }

    & $Logger '  Running Office setup (15-30 min)...'
    $proc = Start-Process $setup -ArgumentList "/configure `"$cfgPath`"" -Wait -PassThru -WindowStyle Hidden

    # Poll for C2R registry keys (install is async)
    $maxWait = 2400; $elapsed = 0; $done = $false
    while ($elapsed -lt $maxWait) {
        if (($c2rRegKeys | Where-Object { Test-Path $_ } | Select-Object -First 1)) { $done = $true; break }
        Start-Sleep -Seconds 30; $elapsed += 30
        & $Logger "  Office installing... $([int]($elapsed/60)) min elapsed"
    }
    Remove-Item $odtExe -Force -EA SilentlyContinue
    if ($done) { & $Logger '  [OK] Microsoft 365 Apps installed'; return 'ok' }
    & $Logger '  [WARN] Office registry not detected after 40 min -- check machine manually'
    return 'warn'
}

function Install-8x8App {
    param([string]$Wg, [scriptblock]$Logger)
    & $Logger '[Installing] 8x8 Work'

    # Get current user for scheduled task
    $curUser = $env:USERNAME
    if ([string]::IsNullOrEmpty($curUser)) { $curUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name -replace '^.+\\','' }

    # Check already installed
    $profileBase = [System.Environment]::GetFolderPath('LocalApplicationData')
    if (Test-Path "$profileBase\8x8-Work") {
        & $Logger '  [SKIP] 8x8 Work already installed'
        return 'skipped'
    }

    # Scrape latest URL
    [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
    $exeUrl = $null
    try {
        $pg = (New-Object System.Net.WebClient).DownloadString('https://support-portal.8x8.com/helpcenter/viewArticle.html?d=8bff4970-6fbf-4daf-842d-8ae9b533153d')
        if ($pg -match 'href="(https://work-desktop-assets\.8x8\.com/prod-publish/ga/work-64-exe-[^"]+\.exe)"') {
            $exeUrl = $Matches[1]
        }
    } catch {}
    if (-not $exeUrl) { $exeUrl = 'https://work-desktop-assets.8x8.com/prod-publish/ga/work-64-exe-v8.33.2-2.exe' }

    $dest = "$TempDir\8x8Setup.exe"
    & $Logger "  Downloading 8x8 from $exeUrl"
    try { (New-Object System.Net.WebClient).DownloadFile($exeUrl, $dest) }
    catch { & $Logger "  [FAILED] Download: $($_.Exception.Message)"; return 'fail' }

    # If running as user already, install directly
    $isSystem = ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem)
    if (-not $isSystem) {
        & $Logger '  Running installer directly (user context)'
        $proc = Start-Process -FilePath $dest -Wait -PassThru -WindowStyle Normal
        Remove-Item $dest -Force -EA SilentlyContinue
        Start-Sleep -Seconds 5
        if (Test-Path "$profileBase\8x8-Work") {
            & $Logger '  [OK] 8x8 Work installed'
            return 'ok'
        }
        & $Logger '  [WARN] 8x8 install directory not detected -- may still be installing'
        return 'warn'
    }

    # SYSTEM context -- use scheduled task
    $tn = 'Paladin_8x8_Install'
    & schtasks.exe /Delete /TN $tn /F 2>&1 | Out-Null
    $null = & schtasks.exe /Create /TN $tn /TR $dest /SC ONCE /ST 00:00 /RU $curUser /IT /F /RL HIGHEST 2>&1
    & schtasks.exe /Run /TN $tn 2>&1 | Out-Null
    & $Logger '  Scheduled task launched. Waiting for install...'
    $waited = 0
    while ($waited -lt 180) {
        Start-Sleep -Seconds 10; $waited += 10
        $userProfile = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -EA SilentlyContinue |
            Where-Object { ($_.PSChildName -match 'S-1-5-21') -and ((Split-Path $_.ProfileImagePath -Leaf) -eq $curUser) } |
            Select-Object -First 1).ProfileImagePath
        if ($userProfile -and (Test-Path "$userProfile\AppData\Local\8x8-Work")) {
            & schtasks.exe /Delete /TN $tn /F 2>&1 | Out-Null
            Remove-Item $dest -Force -EA SilentlyContinue
            & $Logger '  [OK] 8x8 Work installed'
            return 'ok'
        }
    }
    & schtasks.exe /Delete /TN $tn /F 2>&1 | Out-Null
    Remove-Item $dest -Force -EA SilentlyContinue
    & $Logger '  [WARN] 8x8 install not detected after 3 min -- verify manually'
    return 'warn'
}

function Install-DotNetApp {
    param([string]$Wg, [scriptblock]$Logger)
    $results = @()
    foreach ($ver in @('6','8','9')) {
        & $Logger "[Installing] .NET $ver Desktop Runtime x64"
        if ($Wg) {
            $r = Invoke-WingetInstall $Wg "Microsoft.DotNet.DesktopRuntime.$ver" ".NET $ver" $Logger '--architecture x64'
            $results += $r
            if ($r -eq 'fail') { & $Logger "  [WARN] .NET $ver winget failed -- no direct fallback" }
        }
    }
    return if ('ok' -in $results) { 'ok' } elseif ('skipped' -in $results) { 'skipped' } else { 'fail' }
}

function Install-VCRedistApp {
    param([string]$Wg, [scriptblock]$Logger)
    & $Logger '[Installing] Visual C++ Redistributables x64'
    $r1 = if ($Wg) { Invoke-WingetInstall $Wg 'Microsoft.VCRedist.2013.x64' 'VC++ 2013' $Logger } else { 'fail' }
    if ($r1 -eq 'fail') {
        Invoke-DirectDownloadInstall `
            'https://download.microsoft.com/download/2/E/6/2E61CFA4-993B-4DD4-91DA-3737CD5CD6E3/vcredist_x64.exe' `
            'vcredist2013.exe' '/install /quiet /norestart' 'VC++ 2013' $Logger | Out-Null
    }
    $r2 = if ($Wg) { Invoke-WingetInstall $Wg 'Microsoft.VCRedist.2015+.x64' 'VC++ 2015-2022' $Logger } else { 'fail' }
    if ($r2 -eq 'fail') {
        Invoke-DirectDownloadInstall `
            'https://aka.ms/vs/17/release/vc_redist.x64.exe' `
            'vcredist.exe' '/install /quiet /norestart' 'VC++ 2015-2022' $Logger | Out-Null
    }
    return 'ok'
}

function Install-WinDirStatApp {
    param([string]$Wg, [scriptblock]$Logger)
    & $Logger '[Installing] WinDirStat'
    if ($Wg) {
        $r = Invoke-WingetInstall $Wg 'WinDirStat.WinDirStat' 'WinDirStat' $Logger
        if ($r -ne 'fail') { return $r }
    }
    return Invoke-DirectDownloadInstall `
        'https://github.com/windirstat/windirstat/releases/download/v2.1.0/windirstat2_1_0_setup.exe' `
        'WinDirStat.exe' '/S' 'WinDirStat' $Logger
}

function Install-ZoomApp {
    param([string]$Wg, [scriptblock]$Logger)
    & $Logger '[Installing] Zoom'
    if ($Wg) {
        $r = Invoke-WingetInstall $Wg 'Zoom.Zoom' 'Zoom' $Logger
        if ($r -ne 'fail') { return $r }
    }
    return Invoke-DirectDownloadInstall `
        'https://zoom.us/client/latest/ZoomInstallerFull.exe' `
        'ZoomSetup.exe' '/silent /install' 'Zoom' $Logger
}

function Install-QuickBooksApp {
    param([string]$Wg, [scriptblock]$Logger)
    & $Logger '[QuickBooks Desktop]'
    & $Logger '  QuickBooks Desktop requires a valid license + product number from Intuit.'
    & $Logger '  Automated silent install is not possible without credentials.'
    & $Logger '  Opening Intuit download portal -- install manually with client license key.'
    try {
        Start-Process 'https://downloads.quickbooks.com/app/qbdt/products'
    } catch {}
    & $Logger '  [INFO] QB download page opened in browser. Install manually.'
    return 'warn'
}

# =============================================================================
# MASTER INSTALL DISPATCHER
# =============================================================================
function Install-App {
    param([PSCustomObject]$App, [string]$WingetPath, [string]$ChocoPath, [scriptblock]$Logger)

    & $Logger ">>> $($App.Name)"

    # Route custom apps to their dedicated functions
    switch ($App.Id) {
        'chrome'       { return Install-ChromeApp    $WingetPath $Logger }
        'teams'        { return Install-TeamsApp     $WingetPath $Logger }
        'office365'    { return Install-Office365App $WingetPath $Logger }
        '8x8'          { return Install-8x8App       $WingetPath $Logger }
        'dotnet6'      { if ($WingetPath) { return Invoke-WingetInstall $WingetPath 'Microsoft.DotNet.DesktopRuntime.6' '.NET 6' $Logger '--architecture x64' } }
        'dotnet8'      { if ($WingetPath) { return Invoke-WingetInstall $WingetPath 'Microsoft.DotNet.DesktopRuntime.8' '.NET 8' $Logger '--architecture x64' } }
        'dotnet9'      { if ($WingetPath) { return Invoke-WingetInstall $WingetPath 'Microsoft.DotNet.DesktopRuntime.9' '.NET 9' $Logger '--architecture x64' } }
        'vcredist2013' { return Install-VCRedistApp  $WingetPath $Logger }
        'vcredist'     { return Install-VCRedistApp  $WingetPath $Logger }
        'windirstat'   { return Install-WinDirStatApp  $WingetPath $Logger }
        'zoom'         { return Install-ZoomApp       $WingetPath $Logger }
        'quickbooks'   { return Install-QuickBooksApp $WingetPath $Logger }
    }

    # Standard winget/choco routing for everything else
    if ($App.Source -in @('winget','both') -and $App.WingetId -and $WingetPath) {
        $r = Invoke-WingetInstall $WingetPath $App.WingetId $App.Name $Logger
        if ($r -ne 'fail') { return $r }
    }
    if ($App.Source -in @('choco','both') -and $App.Choco -and $ChocoPath) {
        return Invoke-ChocoInstall $ChocoPath $App.Choco $App.Name $Logger
    }
    if ($App.Source -in @('choco','both') -and $App.Choco -and -not $ChocoPath) {
        & $Logger '  Chocolatey not found -- attempting auto-install...'
        $ChocoPath = Install-ChocoIfMissing $Logger
        if ($ChocoPath) { return Invoke-ChocoInstall $ChocoPath $App.Choco $App.Name $Logger }
    }
    & $Logger "  [FAILED] No install method available for $($App.Name)"
    return 'fail'
}

# =============================================================================
# TEMPLATE FUNCTIONS
# =============================================================================
function Get-TemplatePath { param([string]$Name)
    "$TemplateDir\$($Name -replace '[\\/:*?"<>|]','_').json"
}
function Get-AllTemplates {
    @(Get-ChildItem $TemplateDir -Filter '*.json' -EA SilentlyContinue |
      ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) } | Sort-Object)
}
function Save-DeployTemplate { param([string]$Name, [hashtable]$Sel)
    $Sel | ConvertTo-Json -Depth 3 | Set-Content (Get-TemplatePath $Name) -Encoding UTF8 -Force
}
function Load-DeployTemplate { param([string]$Name)
    $p = Get-TemplatePath $Name
    if (-not (Test-Path $p)) { return @{} }
    try {
        $obj = (Get-Content $p -Raw -Encoding UTF8) | ConvertFrom-Json
        $ht  = @{}
        $obj.PSObject.Properties | ForEach-Object { $ht[$_.Name] = [bool]$_.Value }
        return $ht
    } catch { return @{} }
}
function Remove-DeployTemplate { param([string]$Name)
    $p = Get-TemplatePath $Name
    if (Test-Path $p) { Remove-Item $p -Force }
}

# =============================================================================
# XAML
# =============================================================================
[xml]$XAML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Paladin Software Deployer"
    Height="780" Width="980"
    MinHeight="640" MinWidth="820"
    WindowStartupLocation="CenterScreen"
    Background="#F0F2F5"
    FontFamily="Segoe UI">

  <Window.Resources>
    <!-- Button styles -->
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Background" Value="#1565C0"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="20,9"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1976D2"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#90CAF9"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SecBtn" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#424242"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="BorderBrush" Value="#BDBDBD"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F5F5F5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="DangerBtn" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#C62828"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="BorderBrush" Value="#EF9A9A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FFF5F5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GreenBtn" TargetType="Button">
      <Setter Property="Background" Value="#E8F5E9"/>
      <Setter Property="Foreground" Value="#2E7D32"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="BorderBrush" Value="#A5D6A7"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#C8E6C9"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- CheckBox style -->
    <Style x:Key="AppCB" TargetType="CheckBox">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#212121"/>
      <Setter Property="Margin" Value="2,3,6,3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <!-- Category header -->
    <Style x:Key="CatHeader" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#1565C0"/>
      <Setter Property="Margin" Value="0,10,0,3"/>
      <!-- TextTransform not available in WPF .NET Framework -->
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="58"/>    <!-- Header -->
      <RowDefinition Height="46"/>    <!-- Template bar -->
      <RowDefinition Height="*"/>     <!-- Content -->
      <RowDefinition Height="42"/>    <!-- Log header -->
      <RowDefinition Height="155"/>   <!-- Log -->
      <RowDefinition Height="54"/>    <!-- Action bar -->
    </Grid.RowDefinitions>

    <!-- ═══ HEADER ═══════════════════════════════════════════════════════════ -->
    <Border Grid.Row="0" Background="#0D47A1">
      <Grid Margin="20,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Grid.Column="0">
          <Viewbox Width="28" Height="28" Margin="0,0,12,0">
            <Canvas Width="24" Height="24">
              <Rectangle Width="10" Height="10" Fill="White" Canvas.Left="0" Canvas.Top="0" RadiusX="2" RadiusY="2"/>
              <Rectangle Width="10" Height="10" Fill="#64B5F6" Canvas.Left="13" Canvas.Top="0" RadiusX="2" RadiusY="2"/>
              <Rectangle Width="10" Height="10" Fill="#64B5F6" Canvas.Left="0" Canvas.Top="13" RadiusX="2" RadiusY="2"/>
              <Rectangle Width="10" Height="10" Fill="White" Canvas.Left="13" Canvas.Top="13" RadiusX="2" RadiusY="2"/>
            </Canvas>
          </Viewbox>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="PALADIN SOFTWARE DEPLOYER" FontSize="15" FontWeight="Bold"
                       Foreground="White"/>
            <TextBlock x:Name="TxtSiteLabel" Text="Site: —" FontSize="11"
                       Foreground="#90CAF9" Margin="0,1,0,0"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,4,0">
          <Border Background="#1565C0" CornerRadius="12" Padding="10,3" Margin="0,0,8,0">
            <TextBlock x:Name="TxtSelCount" Text="0 selected" FontSize="11"
                       Foreground="#BBDEFB" FontWeight="SemiBold"/>
          </Border>
          <Border x:Name="BadgeWinget" Background="#1B5E20" CornerRadius="4" Padding="8,3" Margin="0,0,4,0">
            <TextBlock Text="winget ✓" FontSize="10" Foreground="#A5D6A7"/>
          </Border>
          <Border x:Name="BadgeChoco" Background="#4E342E" CornerRadius="4" Padding="8,3">
            <TextBlock Text="choco —" FontSize="10" Foreground="#FFCCBC"/>
          </Border>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ═══ TEMPLATE BAR ════════════════════════════════════════════════════ -->
    <Border Grid.Row="1" Background="White" BorderBrush="#E0E0E0" BorderThickness="0,0,0,1">
      <Grid Margin="20,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="190"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="Template:" VerticalAlignment="Center"
                   FontSize="12" Foreground="#616161" Margin="0,0,8,0"/>
        <ComboBox x:Name="CmbTemplates" Grid.Column="1" Height="28"
                  VerticalContentAlignment="Center" FontSize="12"/>
        <Button x:Name="BtnLoad"   Grid.Column="2" Content="Load"    Style="{StaticResource SecBtn}"    Height="28" Margin="6,0,0,0" Padding="10,4"/>
        <Button x:Name="BtnSave"   Grid.Column="3" Content="Save"    Style="{StaticResource SecBtn}"    Height="28" Margin="4,0,0,0" Padding="10,4"/>
        <Button x:Name="BtnDelete" Grid.Column="4" Content="Delete"  Style="{StaticResource DangerBtn}" Height="28" Margin="4,0,0,0" Padding="10,4"/>
        <Button x:Name="BtnNew"    Grid.Column="5" Content="+ New"   Style="{StaticResource GreenBtn}"  Height="28" Margin="4,0,0,0" Padding="10,4"/>
        <StackPanel Grid.Column="7" Orientation="Horizontal">
          <Button x:Name="BtnAll"  Content="All"   Style="{StaticResource SecBtn}" Height="28" Padding="10,4" Margin="0,0,4,0"/>
          <Button x:Name="BtnNone" Content="None"  Style="{StaticResource SecBtn}" Height="28" Padding="10,4"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ═══ MAIN CONTENT ════════════════════════════════════════════════════ -->
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="230"/>
      </Grid.ColumnDefinitions>

      <!-- App catalog (scrollable checklist) -->
      <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto"
                    Background="#F8F9FA" Padding="20,8,16,8">
        <StackPanel x:Name="AppPanel"/>
      </ScrollViewer>

      <!-- Right sidebar -->
      <Border Grid.Column="1" Background="White" BorderBrush="#E0E0E0" BorderThickness="1,0,0,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="14,12,14,12">
          <StackPanel>

            <TextBlock Text="QUICK INSTALL" FontSize="10" FontWeight="Bold"
                       Foreground="#9E9E9E" Margin="0,0,0,6"/>

            <!-- Chocolatey -->
            <TextBlock Text="Chocolatey package:" FontSize="11" Foreground="#616161" Margin="0,0,0,3"/>
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="TxtChoco" Height="26" FontSize="11" Padding="5,3"
                       BorderBrush="#BDBDBD" BorderThickness="1"
                       VerticalContentAlignment="Center" Grid.Column="0"
                       ToolTip="e.g. vlc, notepadplusplus, adobereader"/>
              <Button x:Name="BtnInstChoco" Grid.Column="1" Content="Go"
                      Style="{StaticResource SecBtn}" Height="26" Width="32"
                      Padding="4,3" Margin="4,0,0,0"/>
            </Grid>

            <!-- Winget -->
            <TextBlock Text="Winget package ID:" FontSize="11" Foreground="#616161" Margin="0,0,0,3"/>
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="TxtWinget" Height="26" FontSize="11" Padding="5,3"
                       BorderBrush="#BDBDBD" BorderThickness="1"
                       VerticalContentAlignment="Center" Grid.Column="0"
                       ToolTip="e.g. VideoLAN.VLC"/>
              <Button x:Name="BtnInstWinget" Grid.Column="1" Content="Go"
                      Style="{StaticResource SecBtn}" Height="26" Width="32"
                      Padding="4,3" Margin="4,0,0,0"/>
            </Grid>

            <Separator Margin="0,6,0,10"/>

            <TextBlock Text="EXE / MSI INSTALLER" FontSize="10" FontWeight="Bold"
                       Foreground="#9E9E9E" Margin="0,0,0,6"/>
            <TextBlock Text="Path or URL:" FontSize="11" Foreground="#616161" Margin="0,0,0,3"/>
            <Grid Margin="0,0,0,6">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBox x:Name="TxtExePath" Height="26" FontSize="10" Padding="5,3"
                       BorderBrush="#BDBDBD" BorderThickness="1"
                       VerticalContentAlignment="Center" Grid.Column="0"/>
              <Button x:Name="BtnBrowse" Grid.Column="1" Content="..."
                      Style="{StaticResource SecBtn}" Height="26" Width="28"
                      Padding="2,3" Margin="4,0,0,0"/>
            </Grid>
            <TextBlock Text="Silent args (optional):" FontSize="11" Foreground="#616161" Margin="0,0,0,3"/>
            <TextBox x:Name="TxtExeArgs" Height="26" FontSize="11" Padding="5,3"
                     BorderBrush="#BDBDBD" BorderThickness="1"
                     VerticalContentAlignment="Center" Margin="0,0,0,6"
                     ToolTip="/silent /norestart"/>
            <Button x:Name="BtnRunExe" Content="Run Installer"
                    Style="{StaticResource SecBtn}" Height="28" Margin="0,0,0,0"/>

            <Separator Margin="0,12,0,10"/>

            <TextBlock Text="SESSION" FontSize="10" FontWeight="Bold"
                       Foreground="#9E9E9E" Margin="0,0,0,6"/>
            <Button x:Name="BtnRetry"   Content="Retry Failed"  Style="{StaticResource SecBtn}" Height="28" Margin="0,0,0,4"/>
            <Button x:Name="BtnOpenLog" Content="Open Log File" Style="{StaticResource SecBtn}" Height="28" Margin="0,0,0,4"/>
            <Button x:Name="BtnClearLog" Content="Clear Log"    Style="{StaticResource SecBtn}" Height="28"/>

          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>

    <!-- ═══ LOG HEADER ══════════════════════════════════════════════════════ -->
    <Border Grid.Row="3" Background="#EEEEEE" BorderBrush="#E0E0E0"
            BorderThickness="0,1,0,0" Padding="20,0">
      <Grid>
        <TextBlock Text="INSTALLATION LOG" VerticalAlignment="Center"
                   FontSize="10.5" FontWeight="Bold" Foreground="#757575"/>
        <TextBlock x:Name="TxtStatus" VerticalAlignment="Center"
                   HorizontalAlignment="Right" FontSize="11" Foreground="#616161"/>
      </Grid>
    </Border>

    <!-- ═══ LOG OUTPUT ═══════════════════════════════════════════════════════ -->
    <Border Grid.Row="4" Background="#1A1A2E">
      <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto">
        <TextBox x:Name="TxtLog"
                 Background="Transparent" Foreground="#E0E0E0"
                 FontFamily="Cascadia Mono,Consolas,Courier New"
                 FontSize="11" BorderThickness="0"
                 IsReadOnly="True" TextWrapping="NoWrap"
                 AcceptsReturn="True" Padding="16,10"
                 VerticalScrollBarVisibility="Disabled"/>
      </ScrollViewer>
    </Border>

    <!-- ═══ ACTION BAR ═══════════════════════════════════════════════════════ -->
    <Border Grid.Row="5" Background="White" BorderBrush="#E0E0E0"
            BorderThickness="0,1,0,0">
      <Grid Margin="20,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="TxtActionStatus" VerticalAlignment="Center"
                   FontSize="12" Foreground="#757575"/>
        <Button x:Name="BtnInstall" Grid.Column="1"
                Content="Install Selected" Style="{StaticResource PrimaryBtn}"
                Height="38" Margin="0,0,10,0"/>
        <Button x:Name="BtnClose" Grid.Column="2"
                Content="Close" Style="{StaticResource SecBtn}" Height="38" Padding="16,0"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

# =============================================================================
# LOAD WINDOW
# =============================================================================
try {
    $reader = New-Object System.Xml.XmlNodeReader $XAML
    $Win    = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.MessageBox]::Show("Failed to load GUI: $($_.Exception.Message)",'Error')
    exit 1
}

# Control references
$TxtSiteLabel  = $Win.FindName('TxtSiteLabel')
$TxtSelCount   = $Win.FindName('TxtSelCount')
$BadgeWinget   = $Win.FindName('BadgeWinget')
$BadgeChoco    = $Win.FindName('BadgeChoco')
$AppPanel      = $Win.FindName('AppPanel')
$CmbTemplates  = $Win.FindName('CmbTemplates')
$BtnLoad       = $Win.FindName('BtnLoad')
$BtnSave       = $Win.FindName('BtnSave')
$BtnDelete     = $Win.FindName('BtnDelete')
$BtnNew        = $Win.FindName('BtnNew')
$BtnAll        = $Win.FindName('BtnAll')
$BtnNone       = $Win.FindName('BtnNone')
$TxtChoco      = $Win.FindName('TxtChoco')
$BtnInstChoco  = $Win.FindName('BtnInstChoco')
$TxtWinget     = $Win.FindName('TxtWinget')
$BtnInstWinget = $Win.FindName('BtnInstWinget')
$TxtExePath    = $Win.FindName('TxtExePath')
$TxtExeArgs    = $Win.FindName('TxtExeArgs')
$BtnBrowse     = $Win.FindName('BtnBrowse')
$BtnRunExe     = $Win.FindName('BtnRunExe')
$BtnRetry      = $Win.FindName('BtnRetry')
$BtnOpenLog    = $Win.FindName('BtnOpenLog')
$BtnClearLog   = $Win.FindName('BtnClearLog')
$TxtLog        = $Win.FindName('TxtLog')
$LogScroll     = $Win.FindName('LogScroll')
$TxtStatus     = $Win.FindName('TxtStatus')
$TxtActionStatus = $Win.FindName('TxtActionStatus')
$BtnInstall    = $Win.FindName('BtnInstall')
$BtnClose      = $Win.FindName('BtnClose')

# Runtime state
$script:CBMap      = @{}   # Id -> CheckBox
$script:FailedIds  = [System.Collections.Generic.List[string]]::new()
$script:Installing = $false
$script:WingetPath = Get-WingetExe
$script:ChocoPath  = Get-ChocoExe

# =============================================================================
# UI HELPERS
# =============================================================================
function UILog {
    param([string]$Msg, [string]$Color = '#E0E0E0')
    $ts   = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] $Msg"
    $TxtLog.Dispatcher.Invoke([action]{
        $TxtLog.AppendText("$line`r`n")
        $TxtLog.ScrollToEnd()
    })
    Add-Content -Path $SessionLog -Value $line -EA SilentlyContinue
}

function Update-SelCount {
    $n = ($script:CBMap.Values | Where-Object { $_.IsChecked -eq $true }).Count
    $TxtSelCount.Text    = "$n selected"
    $TxtActionStatus.Text = if ($n -eq 0) { 'Select apps to install' } else { "$n app(s) ready to install" }
}

function Set-UIBusy { param([bool]$Busy)
    $BtnInstall.IsEnabled = -not $Busy
    $BtnLoad.IsEnabled    = -not $Busy
    $BtnSave.IsEnabled    = -not $Busy
    $script:Installing    = $Busy
    $TxtStatus.Text       = if ($Busy) { 'Installing...' } else { '' }
}

# =============================================================================
# BUILD APP CHECKLIST
# =============================================================================
foreach ($cat in $AppCatalog.Keys) {

    $catHeader = New-Object System.Windows.Controls.TextBlock
    $catHeader.Text   = $cat
    $catHeader.Style  = $Win.Resources['CatHeader']
    $AppPanel.Children.Add($catHeader) | Out-Null

    $wrap = New-Object System.Windows.Controls.WrapPanel
    $wrap.Orientation = [System.Windows.Controls.Orientation]::Horizontal

    foreach ($app in $AppCatalog[$cat]) {
        # Skip duplicate IDs (slack2 etc.)
        if ($script:CBMap.ContainsKey($app.Id)) { continue }

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $app.Name
        $cb.Tag     = $app.Id
        $cb.Style   = $Win.Resources['AppCB']
        $cb.ToolTip = switch ($app.Source) {
            'winget' { "winget: $($app.WingetId)" }
            'choco'  { "choco: $($app.Choco)" }
            'both'   { "winget: $($app.WingetId) | choco fallback: $($app.Choco)" }
            'custom' { 'Paladin custom installer' }
        }
        $cb.Add_Checked({   Update-SelCount })
        $cb.Add_Unchecked({ Update-SelCount })
        $script:CBMap[$app.Id] = $cb
        $wrap.Children.Add($cb) | Out-Null
    }

    $AppPanel.Children.Add($wrap) | Out-Null

    $sep = New-Object System.Windows.Controls.Separator
    $sep.Margin = [System.Windows.Thickness]::new(0,4,0,0)
    $sep.Foreground = [System.Windows.Media.Brushes]::LightGray
    $AppPanel.Children.Add($sep) | Out-Null
}

# =============================================================================
# TEMPLATE MANAGEMENT
# =============================================================================
function Refresh-Templates {
    $cur = $CmbTemplates.SelectedItem
    $CmbTemplates.Items.Clear()
    foreach ($t in (Get-AllTemplates)) { $CmbTemplates.Items.Add($t) | Out-Null }
    if ($cur -and $CmbTemplates.Items.Contains($cur)) { $CmbTemplates.SelectedItem = $cur }
    elseif ($CmbTemplates.Items.Contains($SiteName))  { $CmbTemplates.SelectedItem = $SiteName }
    elseif ($CmbTemplates.Items.Count -gt 0)           { $CmbTemplates.SelectedIndex = 0 }
}

function Apply-Template { param([string]$Name)
    $sel = Load-DeployTemplate $Name
    foreach ($kvp in $script:CBMap.GetEnumerator()) {
        $cb = $kvp.Value
        $cb.IsChecked = if ($sel.ContainsKey($kvp.Key)) { $sel[$kvp.Key] } else { $false }
    }
    Update-SelCount
    UILog "Template loaded: $Name"
}

function Collect-Selections {
    $ht = @{}
    foreach ($kvp in $script:CBMap.GetEnumerator()) { $ht[$kvp.Key] = [bool]$kvp.Value.IsChecked }
    return $ht
}

Refresh-Templates
if ($CmbTemplates.Items.Contains($SiteName)) { Apply-Template $SiteName }

$BtnLoad.Add_Click({
    $n = $CmbTemplates.SelectedItem; if ($n) { Apply-Template $n }
})

$BtnSave.Add_Click({
    $n = $CmbTemplates.SelectedItem
    if ([string]::IsNullOrWhiteSpace($n)) {
        [System.Windows.MessageBox]::Show('Select or create a template first.','Save')
        return
    }
    Save-DeployTemplate $n (Collect-Selections)
    UILog "Template saved: $n"
    [System.Windows.MessageBox]::Show("Saved: $n","Paladin Deployer")
})

$BtnDelete.Add_Click({
    $n = $CmbTemplates.SelectedItem
    if ([string]::IsNullOrWhiteSpace($n)) { return }
    if ([System.Windows.MessageBox]::Show("Delete '$n'?","Confirm",[System.Windows.MessageBoxButton]::YesNo) -eq 'Yes') {
        Remove-DeployTemplate $n
        Refresh-Templates
        UILog "Template deleted: $n"
    }
})

$BtnNew.Add_Click({
    $n = [Microsoft.VisualBasic.Interaction]::InputBox('Template name:','New Template',$SiteName)
    if ([string]::IsNullOrWhiteSpace($n)) { return }
    Save-DeployTemplate $n (Collect-Selections)
    Refresh-Templates
    $CmbTemplates.SelectedItem = $n
    UILog "Template created: $n"
})

$BtnAll.Add_Click({  foreach ($cb in $script:CBMap.Values) { $cb.IsChecked = $true  }; Update-SelCount })
$BtnNone.Add_Click({ foreach ($cb in $script:CBMap.Values) { $cb.IsChecked = $false }; Update-SelCount })

# =============================================================================
# INSTALL SESSION
# =============================================================================
function Start-Session { param([System.Collections.Generic.List[PSCustomObject]]$Apps)
    if ($script:Installing) {
        [System.Windows.MessageBox]::Show('Install already running.','Paladin Deployer')
        return
    }

    Set-UIBusy $true
    $script:FailedIds.Clear()
    $BtnRetry.IsEnabled = $false

    $wg    = $script:WingetPath
    $choco = $script:ChocoPath

    # Ensure Chocolatey available if any app needs it
    $needsChoco = $Apps | Where-Object { $_.Source -in @('choco','both') -and -not $_.WingetId -and $_.Choco }
    if ($needsChoco -and -not $choco) {
        UILog 'Chocolatey needed -- auto-installing...'
        $choco = Install-ChocoIfMissing { param($m) UILog $m }
        if ($choco) {
            $script:ChocoPath = $choco
            $BadgeChoco.Background = [System.Windows.Media.Brushes]::DarkGreen
        }
    }

    $ok = 0; $skip = 0; $fail = 0

    UILog "=== Install session: $($Apps.Count) app(s) ==="

    foreach ($app in $Apps) {
        $logger = { param($m) UILog $m }
        try {
            $result = Install-App -App $app -WingetPath $wg -ChocoPath $choco -Logger $logger
            switch ($result) {
                'ok'      { $ok++   }
                'skipped' { $skip++ }
                'warn'    { $skip++ }
                'fail'    { $fail++; $script:FailedIds.Add($app.Id) | Out-Null }
                default   { $fail++; $script:FailedIds.Add($app.Id) | Out-Null }
            }
        } catch {
            UILog "ERROR: $($_.Exception.Message)"
            $fail++
            $script:FailedIds.Add($app.Id) | Out-Null
        }
    }

    UILog "=== Done: $ok installed | $skip skipped | $fail failed ==="
    $TxtStatus.Text = "$ok installed, $skip skipped, $fail failed"

    if ($fail -gt 0) {
        $BtnRetry.IsEnabled = $true
        $TxtStatus.Text += " — click Retry Failed"
    }

    Set-UIBusy $false
}

$BtnInstall.Add_Click({
    $selected = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($cat in $AppCatalog.Keys) {
        foreach ($app in $AppCatalog[$cat]) {
            $cb = $script:CBMap[$app.Id]
            if ($cb -and $cb.IsChecked -eq $true) { $selected.Add($app) | Out-Null }
        }
    }
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show('No apps selected.','Paladin Deployer')
        return
    }
    Start-Session $selected
})

$BtnRetry.Add_Click({
    if ($script:FailedIds.Count -eq 0) {
        [System.Windows.MessageBox]::Show('Nothing to retry.','Paladin Deployer')
        return
    }
    $retry = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($cat in $AppCatalog.Keys) {
        foreach ($app in $AppCatalog[$cat]) {
            if ($script:FailedIds -contains $app.Id) { $retry.Add($app) | Out-Null }
        }
    }
    UILog "=== Retry: $($retry.Count) app(s) ==="
    Start-Session $retry
})

# =============================================================================
# CUSTOM INSTALL PANEL
# =============================================================================
$BtnInstChoco.Add_Click({
    $pkg = $TxtChoco.Text.Trim()
    if (-not $pkg) { [System.Windows.MessageBox]::Show('Enter a package name.','Chocolatey'); return }
    $choco = $script:ChocoPath
    if (-not $choco) { $choco = Install-ChocoIfMissing { param($m) UILog $m }; $script:ChocoPath = $choco }
    if (-not $choco) { UILog '[FAILED] Chocolatey unavailable'; return }
    UILog "choco install $pkg"
    Invoke-ChocoInstall $choco $pkg $pkg { param($m) UILog $m } | Out-Null
})

$BtnInstWinget.Add_Click({
    $pkg = $TxtWinget.Text.Trim()
    if (-not $pkg) { [System.Windows.MessageBox]::Show('Enter a package ID.','winget'); return }
    $wg = $script:WingetPath
    if (-not $wg) { UILog '[FAILED] winget not found'; return }
    UILog "winget install --id $pkg"
    Invoke-WingetInstall $wg $pkg $pkg { param($m) UILog $m } | Out-Null
})

$BtnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Installers (*.exe;*.msi)|*.exe;*.msi|All files|*.*'
    $dlg.Title  = 'Select Installer'
    if ($dlg.ShowDialog() -eq 'OK') { $TxtExePath.Text = $dlg.FileName }
})

$BtnRunExe.Add_Click({
    $path = $TxtExePath.Text.Trim()
    $args = $TxtExeArgs.Text.Trim()
    if (-not $path) { [System.Windows.MessageBox]::Show('Enter a path or URL.','Run Installer'); return }
    if ($path -match '^https?://') {
        UILog "Downloading: $path"
        $dest = "$TempDir\CustomInstall$(Split-Path $path -Leaf)"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
            (New-Object System.Net.WebClient).DownloadFile($path, $dest)
            $path = $dest
            UILog "Downloaded: $dest"
        } catch { UILog "Download failed: $($_.Exception.Message)"; return }
    }
    if (-not (Test-Path $path)) { UILog "File not found: $path"; return }
    UILog "Running: $path $args"
    try {
        $proc = if ($args) {
            Start-Process -FilePath $path -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        } else {
            Start-Process -FilePath $path -Wait -PassThru -WindowStyle Hidden
        }
        if ($proc.ExitCode -in @(0,3010,1641)) { UILog "[OK] Exit: $($proc.ExitCode)" }
        else { UILog "[WARN] Exit: $($proc.ExitCode)" }
    } catch { UILog "Error: $($_.Exception.Message)" }
})

$BtnClearLog.Add_Click({ $TxtLog.Clear() })
$BtnOpenLog.Add_Click({ if (Test-Path $SessionLog) { Start-Process notepad.exe $SessionLog } })
$BtnClose.Add_Click({ $Win.Close() })

# =============================================================================
# STARTUP
# =============================================================================
$TxtSiteLabel.Text = "Site: $SiteName"
Update-SelCount
$BtnRetry.IsEnabled = $false

UILog "Paladin Software Deployer v1.0.0"
UILog "Site: $SiteName"
UILog "Templates: $TemplateDir"
UILog "Log: $SessionLog"

# Pre-flight: ensure winget and Chocolatey are available before GUI is usable
UILog "--- Pre-flight checks ---"

# winget check
if ($script:WingetPath) {
    UILog "winget: OK ($($script:WingetPath))"
    $BadgeWinget.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(27,94,32))
    $BadgeWinget.Child.Text = 'winget OK'
} else {
    UILog "winget: not found -- attempting bootstrap..."
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -EA Stop
        Start-Sleep -Seconds 5
        $script:WingetPath = Get-WingetExe
    } catch {}
    if ($script:WingetPath) {
        UILog "winget: bootstrapped OK ($($script:WingetPath))"
        $BadgeWinget.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(27,94,32))
    } else {
        UILog "winget: UNAVAILABLE -- direct download fallbacks will be used" 'WARN'
        $BadgeWinget.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(183,28,28))
    }
}

# Chocolatey check and install
if ($script:ChocoPath) {
    UILog "Chocolatey: OK ($($script:ChocoPath))"
    $BadgeChoco.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(27,94,32))
    $BadgeChoco.Child.Text = 'choco OK'
} else {
    UILog "Chocolatey: not found -- installing now..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
        $env:chocolateyUseWindowsCompression = 'true'
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
        $script:ChocoPath = Get-ChocoExe
    } catch {
        UILog "Chocolatey install failed: $($_.Exception.Message)" 'WARN'
    }
    if ($script:ChocoPath) {
        UILog "Chocolatey: installed OK ($($script:ChocoPath))"
        $BadgeChoco.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(27,94,32))
        $BadgeChoco.Child.Text = 'choco OK'
    } else {
        UILog "Chocolatey: install FAILED -- choco-sourced apps may not install" 'WARN'
        $BadgeChoco.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(183,28,28))
        $BadgeChoco.Child.Text = 'choco FAIL'
    }
}

UILog "--- Pre-flight complete. Ready. ---"

$Win.ShowDialog() | Out-Null
