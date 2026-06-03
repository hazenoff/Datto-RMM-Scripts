#Requires -Version 3.0
<#
.SYNOPSIS
    Paladin Printer Manager [WIN]
    Paladin Business Consulting | Datto RMM Component | Single-File
    Version: 1.0.0

.DESCRIPTION
    Self-contained printer discovery, driver lookup, and deployment tool.
    
    SYSTEM MODE (Datto entry point):
      Detects domain join status, reads PaladinPrinters site variable,
      stages self to fixed path, launches GUI as logged-on user.

    GUI MODE (-GUIMode):
      Tab 1 DISCOVER -- Scans subnet for printers via port 9100 + SNMP.
                        Compares against known printers. Flags new/offline.
                        Provides clickable driver download URLs for new finds.
      Tab 2 DEPLOY   -- Select a known printer and install it machine-wide.
                        Checks driver cache first. Downloads if URL provided.
                        Full silent install: driver + port + printer object.
      Tab 3 INSTALLED -- Lists installed printers. Set default, remove.

    MODES:
      Domain-joined: subnet from PaladinPrinters site variable
      Workgroup/Home: subnet auto-detected from machine IP

    SITE VARIABLE: PaladinPrinters (JSON string)
    {
      "Subnet": "192.168.1",
      "Mode": "domain",
      "Printers": [
        {
          "Name": "Reception HP LaserJet",
          "IP": "192.168.1.50",
          "Manufacturer": "HP",
          "Model": "HP LaserJet Pro M404dn",
          "Driver": "HP Universal Printing PCL 6",
          "DriverUrl": "https://support.hp.com/us-en/drivers/printers",
          "DriverFile": "hpcu230u.inf",
          "Status": "managed",
          "AddedDate": "2026-05-30"
        }
      ]
    }

    DRIVER CACHE: C:\ProgramData\Paladin\Printers\DriverCache\<Manufacturer>\
    LOG:          C:\ProgramData\Paladin\Printers\PrinterManager.log
    INPUT VARS:   DiscoverOnly (Boolean) -- default true, skip deploy tab
#>

param(
    [switch]$GUIMode,
    [string]$SiteName     = '',
    [string]$SiteVarJson  = '',
    [string]$MachineMode  = 'auto'   # 'domain' | 'home' | 'auto'
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# ===========================================================================
# SHARED CONSTANTS
# ===========================================================================
$BaseDir      = 'C:\ProgramData\Paladin\Printers'
$CacheDir     = "$BaseDir\DriverCache"
$LogFile      = "$BaseDir\PrinterManager.log"
$SelfDest     = "$BaseDir\Paladin-PrinterManager.ps1"
$SiteVarFile  = "$BaseDir\SiteVar.json"
$TempDir      = "$BaseDir\Temp"
$TaskName     = 'Paladin_PrinterManager_GUI'
$MaxLogMB     = 5

# Driver URL lookup by manufacturer
$DriverUrls = @{
    'HP'       = 'https://support.hp.com/us-en/drivers/printers'
    'Canon'    = 'https://www.usa.canon.com/support/software-drivers'
    'Epson'    = 'https://epson.com/Support/Printers/'
    'Brother'  = 'https://support.brother.com/g/b/productsearch.aspx'
    'Xerox'    = 'https://www.xerox.com/en-us/support'
    'Ricoh'    = 'https://www.ricoh-usa.com/en/support-and-download'
    'Lexmark'  = 'https://www.lexmark.com/en_us/support/downloads.html'
    'Kyocera'  = 'https://www.kyoceradocumentsolutions.us/en/support/downloads.html'
    'Samsung'  = 'https://www.samsung.com/us/support/printers/'
    'Dell'     = 'https://www.dell.com/support/home/en-us?app=drivers'
    'Konica'   = 'https://www.konicaminolta.com/us-en/support'
    'Zebra'    = 'https://www.zebra.com/us/en/support-downloads.html'
    'Toshiba'  = 'https://business.toshiba.com/support/drivers'
    'Sharp'    = 'https://www.sharpusa.com/support/drivers'
    'Panasonic'= 'https://panasonic.net/cns/prodisplays/support/'
    'Unknown'  = 'https://www.google.com/search?q=printer+driver+download'
}

# Manufacturer detection patterns
$MfrPatterns = @(
    @{ Name='HP';        Pattern='HP|Hewlett|LaserJet|OfficeJet|DeskJet|PageWide|Color LaserJet' }
    @{ Name='Canon';     Pattern='Canon|imageRUNNER|imageCLASS|PIXMA|LBP|MF\d' }
    @{ Name='Epson';     Pattern='Epson|WorkForce|EcoTank|SureColor|ET-\d' }
    @{ Name='Brother';   Pattern='Brother|HL-|MFC-|DCP-' }
    @{ Name='Xerox';     Pattern='Xerox|Phaser|WorkCentre|VersaLink|AltaLink' }
    @{ Name='Ricoh';     Pattern='Ricoh|Aficio|SP \d|IM \d|MP \d' }
    @{ Name='Lexmark';   Pattern='Lexmark|CS\d|CX\d|MS\d|MX\d' }
    @{ Name='Kyocera';   Pattern='Kyocera|ECOSYS|TASKalfa' }
    @{ Name='Samsung';   Pattern='Samsung|Xpress|ProXpress|MultiXpress' }
    @{ Name='Konica';    Pattern='Konica|Minolta|bizhub|AccurioPress' }
    @{ Name='Zebra';     Pattern='Zebra|ZT\d|ZD\d|ZM\d|LP \d' }
    @{ Name='Toshiba';   Pattern='Toshiba|e-STUDIO' }
    @{ Name='Sharp';     Pattern='Sharp|MX-\d|BP-\d' }
)

function Get-Manufacturer {
    param([string]$Model)
    foreach ($m in $MfrPatterns) {
        if ($Model -match $m.Pattern) { return $m.Name }
    }
    return 'Unknown'
}

# ===========================================================================
# DATTO SYSTEM LAUNCHER
# ===========================================================================
if (-not $GUIMode) {

    function Write-SysLog { param([string]$M) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $M" }

    Write-SysLog 'Paladin Printer Manager v1.0.0 -- SYSTEM launcher'

    # Create dirs
    foreach ($d in @($BaseDir, $CacheDir)) {
        if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force | Out-Null }
    }

    # Read input variables
    $discoverOnly = $env:DiscoverOnly
    if ([string]::IsNullOrEmpty($discoverOnly)) { $discoverOnly = 'true' }

    # Read PaladinPrinters site variable
    $siteVarRaw = $env:PaladinPrinters
    if ([string]::IsNullOrEmpty($siteVarRaw)) { $siteVarRaw = '{}' }

    # Detect mode
    $cs       = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
    $isJoined = if ($null -ne $cs) { $cs.PartOfDomain } else { $false }
    $mode     = if ($isJoined) { 'domain' } else { 'home' }
    Write-SysLog "Mode: $mode | Domain joined: $isJoined"

    # If home mode and no subnet in site var, detect from machine IP
    $subnet = ''
    try {
        $parsed = $siteVarRaw | ConvertFrom-Json
        $subnet = $parsed.Subnet
    } catch {}

    if ([string]::IsNullOrEmpty($subnet)) {
        try {
            $localIP = (Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue |
                        Where-Object { $_.IPAddress -notmatch '^127\.' -and
                                       $_.IPAddress -notmatch '^169\.254\.' } |
                        Select-Object -First 1).IPAddress
            if ($localIP -match '^(\d+\.\d+\.\d+)\.\d+$') {
                $subnet = $Matches[1]
                Write-SysLog "Auto-detected subnet: $subnet"
            }
        } catch {}
    }

    # Stage self
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $SelfDest -Force -EA Stop
        Write-SysLog "Staged: $SelfDest"
    } catch { Write-SysLog "ERROR staging: $($_.Exception.Message)"; exit 1 }

    # Save site var to file for GUI to read
    $siteVarRaw | Set-Content $SiteVarFile -Encoding UTF8 -Force

    # Get logged-on user
    $user = $null
    try {
        $wcs = Get-WmiObject Win32_ComputerSystem -EA SilentlyContinue
        if ($wcs -and $wcs.UserName) { $user = ($wcs.UserName -split '\\')[-1] }
    } catch {}
    if (-not $user) {
        try {
            $qu = & query user 2>&1
            foreach ($l in $qu) {
                if ($l -match 'Active') { $user = ($l.Trim() -split '\s+')[0].TrimStart('>'); break }
            }
        } catch {}
    }

    if (-not $user) { Write-SysLog 'ERROR: No logged-on user found'; exit 1 }
    Write-SysLog "User: $user"

    $siteName = $env:CS_PROFILE_NAME
    if (-not $siteName) { $siteName = 'Default' }

    # Launch GUI
    $psArgs = "-NonInteractive -ExecutionPolicy Bypass -File `"$SelfDest`" -GUIMode -SiteName `"$siteName`" -MachineMode `"$mode`""
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    $null = & schtasks.exe /Create /TN $TaskName /TR "PowerShell.exe $psArgs" `
        /SC ONCE /ST 00:00 /RU $user /IT /F /RL HIGHEST 2>&1
    & schtasks.exe /Run /TN $TaskName 2>&1 | Out-Null

    Write-SysLog "GUI launched as $user for site: $siteName"
    Start-Sleep -Seconds 5
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    exit 0
}

# ===========================================================================
# GUI MODE
# ===========================================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

foreach ($d in @($BaseDir, $CacheDir)) {
    if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force | Out-Null }
}

# ===========================================================================
# LOGGING
# ===========================================================================
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Msg"
    Write-Host $line
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile -EA SilentlyContinue).Length/1MB) -gt $MaxLogMB) {
            Move-Item $LogFile "$LogFile.bak" -Force -EA SilentlyContinue
        }
        Add-Content $LogFile $line -EA SilentlyContinue
    } catch {}
}

# ===========================================================================
# SITE VARIABLE MANAGEMENT
# ===========================================================================
function Get-SiteVar {
    $raw = '{}'
    if (Test-Path $SiteVarFile) { $raw = Get-Content $SiteVarFile -Raw -Encoding UTF8 -EA SilentlyContinue }
    try { return $raw | ConvertFrom-Json } catch { return [PSCustomObject]@{} }
}

function Get-PrinterList {
    $sv = Get-SiteVar
    if ($sv.Printers) { return @($sv.Printers) }
    return @()
}

function Save-SiteVar {
    param([PSCustomObject]$Data)
    try {
        $Data | ConvertTo-Json -Depth 10 | Set-Content $SiteVarFile -Encoding UTF8 -Force
        Write-Log "Site variable updated: $SiteVarFile"
        return $true
    } catch {
        Write-Log "ERROR saving site var: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Add-PrinterToSiteVar {
    param([PSCustomObject]$NewPrinter)
    $sv = Get-SiteVar
    $list = [System.Collections.Generic.List[object]]::new()
    if ($sv.Printers) {
        foreach ($item in $sv.Printers) { $list.Add($item) | Out-Null }
    }

    # Check if IP already exists
    $existing = $list | Where-Object { $_.IP -eq $NewPrinter.IP }
    if ($existing) {
        Write-Log "Printer at $($NewPrinter.IP) already in site variable -- updating"
        $list.Remove($existing) | Out-Null
    }
    $list.Add($NewPrinter) | Out-Null
    $sv | Add-Member -MemberType NoteProperty -Name Printers -Value $list -Force
    return Save-SiteVar $sv
}

# ===========================================================================
# NETWORK SCANNER
# ===========================================================================
function Get-WingetExe {
    $candidates = @(
        "$env:LocalAppData\Microsoft\WindowsApps\winget.exe"
        'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe'
        "${env:ProgramFiles}\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe"
    )
    foreach ($c in $candidates) {
        $f = Get-Item -Path $c -EA SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

function Get-ChocoExe {
    $p = 'C:\ProgramData\chocolatey\bin\choco.exe'
    if (Test-Path $p) { return $p }
    return $null
}

function Install-ChocoIfMissing {
    param([scriptblock]$Logger)
    & $Logger 'Installing Chocolatey...'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
        $env:chocolateyUseWindowsCompression = 'true'
        $script = (Invoke-WebRequest -Uri 'https://chocolatey.org/install.ps1' -UseBasicParsing -EA Stop).Content
        Invoke-Expression $script
        $p = Get-ChocoExe
        if ($p) { & $Logger "Chocolatey installed: $p"; return $p }
    } catch { & $Logger "Chocolatey install failed: $($_.Exception.Message)" }
    return $null
}

function Get-LocalSubnet {
    try {
        # Strategy 1: Find the adapter with a default gateway -- most reliable
        $bestIP = $null
        $routes = Get-WmiObject Win32_IP4RouteTable -EA SilentlyContinue |
                  Where-Object { $_.Destination -eq '0.0.0.0' } |
                  Sort-Object Metric1

        foreach ($route in $routes) {
            $nic = Get-WmiObject Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
                   Where-Object { $_.InterfaceIndex -eq $route.InterfaceIndex -and
                                  $_.IPEnabled -eq $true }
            if ($nic -and $nic.IPAddress) {
                $ip = $nic.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and
                                                       $_ -notmatch '^127\.' -and
                                                       $_ -notmatch '^169\.254\.' } |
                      Select-Object -First 1
                if ($ip) { $bestIP = $ip; break }
            }
        }

        if ($bestIP -and $bestIP -match '^(\d+\.\d+\.\d+)\.\d+$') {
            return $Matches[1]
        }

        # Strategy 2: Get-NetIPAddress filtered to physical adapters with a gateway
        $adapters = Get-NetIPConfiguration -EA SilentlyContinue |
                    Where-Object { $_.IPv4DefaultGateway -and
                                   $_.NetAdapter.Status -eq 'Up' }
        foreach ($a in $adapters) {
            $ip = ($a.IPv4Address | Select-Object -First 1).IPAddress
            if ($ip -and $ip -notmatch '^127\.' -and $ip -notmatch '^169\.254\.' -and
                $ip -match '^(\d+\.\d+\.\d+)\.\d+$') {
                return $Matches[1]
            }
        }

        # Strategy 3: WMI fallback -- all enabled NICs with gateway
        $nics = Get-WmiObject Win32_NetworkAdapterConfiguration -EA SilentlyContinue |
                Where-Object { $_.IPEnabled -and $_.DefaultIPGateway }
        foreach ($nic in $nics) {
            $ip = $nic.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and
                                                   $_ -notmatch '^127\.' -and
                                                   $_ -notmatch '^169\.254\.' } |
                  Select-Object -First 1
            if ($ip -and $ip -match '^(\d+\.\d+\.\d+)\.\d+$') {
                return $Matches[1]
            }
        }
    } catch {}
    return '192.168.1'
}

function Test-PrinterPort {
    param([string]$IP, [int]$Port = 9100, [int]$TimeoutMs = 500)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task   = $client.ConnectAsync($IP, $Port)
        $task.Wait($TimeoutMs) | Out-Null
        $ok = ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion)
        try { $client.Close() } catch {}
        return $ok
    } catch { return $false }
}

function Get-SNMPInfo {
    param([string]$IP, [int]$TimeoutMs = 1500)
    $info = [PSCustomObject]@{
        IP           = $IP
        Model        = 'Unknown'
        Serial       = 'Unknown'
        Manufacturer = 'Unknown'
        PageCount    = 'Unknown'
        SysDesc      = ''
    }
    try {
        $snmp = New-Object -ComObject olePrn.OleSNMP -EA Stop
        $snmp.Open($IP, 'public', 1, $TimeoutMs)
        try { $info.Model    = $snmp.Get('.1.3.6.1.2.1.25.3.2.1.3.1') } catch {}
        try { $info.Serial   = $snmp.Get('.1.3.6.1.2.1.43.5.1.1.17.1') } catch {}
        try { $info.SysDesc  = $snmp.Get('.1.3.6.1.2.1.1.1.0') } catch {}
        try { $info.PageCount= $snmp.Get('.1.3.6.1.2.1.43.10.2.1.4.1.1') } catch {}
        $snmp.Close()

        # Fallback model from sysDesc
        if ([string]::IsNullOrEmpty($info.Model) -or $info.Model -eq 'Unknown') {
            if ($info.SysDesc) { $info.Model = $info.SysDesc }
        }

        $info.Manufacturer = Get-Manufacturer $info.Model
    } catch {}
    return $info
}

function Invoke-SubnetScan {
    param([string]$Subnet, [int]$StartIP = 1, [int]$EndIP = 254,
          [scriptblock]$Progress, [scriptblock]$Found)

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $total   = $EndIP - $StartIP + 1
    $done    = 0

    for ($i = $StartIP; $i -le $EndIP; $i++) {
        $ip = "$Subnet.$i"
        $done++
        if ($Progress) { & $Progress $done $total $ip }

        if (Test-PrinterPort -IP $ip -TimeoutMs 400) {
            $info = Get-SNMPInfo -IP $ip
            $results.Add($info) | Out-Null
            if ($Found) { & $Found $info }
            Write-Log "Found printer: $ip | $($info.Model) | $($info.Manufacturer)"
        }
    }
    return $results
}

# ===========================================================================
# PRINTER INSTALL ENGINE
# ===========================================================================
function Get-CachedDriver {
    param([string]$Manufacturer, [string]$DriverFile = '')
    # Look in manufacturer subfolder first, then all subfolders
    $searchDirs = @("$CacheDir\$Manufacturer", $CacheDir)
    foreach ($dir in $searchDirs) {
        if (-not (Test-Path $dir)) { continue }
        if ($DriverFile) {
            $f = Get-Item "$dir\$DriverFile" -EA SilentlyContinue
            if ($f) { return $f.FullName }
        }
        # Find any INF file
        $inf = Get-ChildItem $dir -Filter '*.inf' -Recurse -EA SilentlyContinue | Select-Object -First 1
        if ($inf) { return $inf.FullName }
    }
    return $null
}

function Get-DriverNameFromINF {
    <#
    .SYNOPSIS
    Reads the printer driver name exactly as Windows registers it from an INF file.
    Printer INFs register driver names in [Manufacturer] and model sections.
    The name in the CTL or model line left of the = sign is what Add-PrinterDriver needs.
    #>
    param([string]$INFPath)

    if (-not (Test-Path $INFPath)) { return $null }

    try {
        $lines = Get-Content $INFPath -Encoding Default -EA Stop

        # Build strings table from [Strings] section -- INFs use %VAR% substitution
        $strings  = @{}
        $inStrings = $false
        foreach ($line in $lines) {
            if ($line -match '^\[Strings\]') { $inStrings = $true; continue }
            if ($inStrings -and $line -match '^\[') { $inStrings = $false }
            if ($inStrings -and $line -match '^(\w+)\s*=\s*"([^"]*)"') {
                $strings[$Matches[1]] = $Matches[2]
            }
        }

        function Resolve-INFString {
            param([string]$s)
            if ($s -match '^%(.+)%$' -and $strings.ContainsKey($Matches[1])) {
                return $strings[$Matches[1]]
            }
            return $s.Trim('"').Trim()
        }

        # Find [Manufacturer] section -- lists manufacturer names and model sections
        $inMfr       = $false
        $modelSections = @()
        foreach ($line in $lines) {
            if ($line -match '^\[Manufacturer\]') { $inMfr = $true; continue }
            if ($inMfr -and $line -match '^\[') { $inMfr = $false }
            if ($inMfr -and $line -match '=\s*(\S+)') {
                # e.g. "Canon" = Canon.NTamd64 or Canon.NTx86
                $modelSections += $Matches[1] -split ',' | ForEach-Object { $_.Trim() }
            }
        }

        # Search each model section for driver name (left side of = in device lines)
        foreach ($section in $modelSections) {
            $inSection = $false
            foreach ($line in $lines) {
                if ($line -match "^\[$([regex]::Escape($section))\]") { $inSection = $true; continue }
                if ($inSection -and $line -match '^\[') { $inSection = $false }
                if ($inSection -and $line -match '^([^;=\[]+?)\s*=\s*\S') {
                    $raw = $Matches[1].Trim()
                    # Skip section headers and empty
                    if ($raw -match '^\s*$') { continue }
                    $name = Resolve-INFString $raw
                    # Must look like a printer driver name (has letters, reasonable length)
                    if ($name.Length -gt 4 -and $name.Length -lt 100 -and $name -match '[a-zA-Z]') {
                        return $name
                    }
                }
            }
        }

        # Fallback: look for any quoted string in model sections that looks like a driver name
        foreach ($line in $lines) {
            if ($line -match '^"([^"]{6,80})"\s*=') {
                return $Matches[1]
            }
        }
    } catch {}
    return $null
}

function Get-ResolvedDriverName {
    # If exact name not found, search installed drivers for closest match
    param([string]$DriverName, [scriptblock]$Logger)
    $exact = Get-PrinterDriver -Name $DriverName -EA SilentlyContinue
    if ($exact) { return $DriverName }

    # Fuzzy match -- find driver with most words in common
    $allDrivers = Get-PrinterDriver -EA SilentlyContinue
    if (-not $allDrivers) { return $DriverName }

    $words  = $DriverName -split '\s+' | Where-Object { $_.Length -gt 2 }
    $best   = $null
    $bestScore = 0
    foreach ($d in $allDrivers) {
        $score = ($words | Where-Object { $d.Name -match [regex]::Escape($_) }).Count
        if ($score -gt $bestScore) { $bestScore = $score; $best = $d.Name }
    }
    if ($best -and $bestScore -gt 0) {
        & $Logger "  Driver fuzzy match: '$DriverName' -> '$best' (score: $bestScore)"
        return $best
    }
    return $DriverName
}

function Install-NetworkPrinter {
    param(
        [string]$PrinterName,
        [string]$IP,
        [string]$DriverName,
        [string]$INFPath,
        [string]$PortName = '',
        [scriptblock]$Logger
    )

    # Port name -- use provided or auto-generate from IP
    if ([string]::IsNullOrEmpty($PortName)) {
        $PortName = "IP_$($IP.Replace('.','_'))"
    }
    $success = $true

    & $Logger "=== Installing: $PrinterName ==="
    & $Logger "  IP: $IP | Port: $PortName"
    & $Logger "  Driver: $DriverName"
    & $Logger "  INF: $(if ($INFPath) { $INFPath } else { '(none)' })"

    # Step 1: Stage driver via pnputil if INF provided
    if ($INFPath -and (Test-Path $INFPath)) {
        & $Logger "Step 1: Staging driver via pnputil..."
        try {
            $pnp = & pnputil.exe /add-driver $INFPath /install 2>&1
            $pnp | ForEach-Object { & $Logger "  pnputil: $_" }
            & $Logger "Step 1: OK"

            # Read driver name from original INF -- most reliable
            $infDriverName = Get-DriverNameFromINF $INFPath
            if ($infDriverName -and $infDriverName -ne $DriverName) {
                & $Logger "  INF driver name: $infDriverName"
                $DriverName = $infDriverName
            }

            # Get the staged OEM INF path from pnputil output -- needed for Add-PrinterDriver
            $pnpOut = $pnp | Out-String
            if ($pnpOut -match 'Published Name:\s+(oem\d+\.inf)') {
                $oemInfName = $Matches[1]
                # oem INFs live in C:\Windows\inf\
                $oemInfPath = "$env:SystemRoot\inf\$oemInfName"
                if (Test-Path $oemInfPath) {
                    $script:StagedINFPath = $oemInfPath
                    & $Logger "  Staged OEM INF: $oemInfPath"
                }
            }
        } catch {
            & $Logger "Step 1: WARN -- $($_.Exception.Message)"
        }
    } else {
        & $Logger "Step 1: No INF -- driver must already be in Windows driver store"
    }

    # Step 2: Resolve and install driver
    & $Logger "Step 2: Resolving driver name..."
    $resolvedDriver = Get-ResolvedDriverName -DriverName $DriverName -Logger $Logger
    if ($resolvedDriver -ne $DriverName) {
        & $Logger "  Using resolved name: $resolvedDriver"
        $DriverName = $resolvedDriver
    }
    try {
        $existing = Get-PrinterDriver -Name $DriverName -EA SilentlyContinue
        if ($existing) {
            & $Logger "Step 2: Driver already in Windows -- OK"
        } else {
            # Use staged OEM INF path if available -- this is what Add-PrinterDriver needs
            $infForInstall = if ($script:StagedINFPath -and (Test-Path $script:StagedINFPath)) {
                $script:StagedINFPath
            } elseif ($INFPath -and (Test-Path $INFPath)) {
                $INFPath
            } else { $null }

            if ($infForInstall) {
                & $Logger "  Using INF: $infForInstall"
                Add-PrinterDriver -Name $DriverName -InfPath $infForInstall -EA Stop
            } else {
                Add-PrinterDriver -Name $DriverName -EA Stop
            }
            & $Logger "Step 2: Driver installed OK"
        }
    } catch {
        & $Logger "Step 2: WARN -- $($_.Exception.Message)"
        & $Logger "  Available drivers in store:"
        Get-PrinterDriver -EA SilentlyContinue | ForEach-Object { & $Logger "    $($_.Name)" }
        # Last resort: try to find and use any matching manufacturer driver already in store
        $mfrDriver = Get-PrinterDriver -EA SilentlyContinue |
                     Where-Object { $_.Name -match 'Canon|imageCLASS|MF|LBP' } |
                     Select-Object -First 1
        if ($mfrDriver) {
            & $Logger "  Falling back to: $($mfrDriver.Name)"
            $DriverName = $mfrDriver.Name
        }
    }

    # Step 3: Create TCP/IP port
    & $Logger "Step 3: Creating port $PortName -> $IP"
    try {
        $existingPort = Get-PrinterPort -Name $PortName -EA SilentlyContinue
        if ($existingPort) {
            & $Logger "Step 3: Port already exists -- OK"
        } else {
            Add-PrinterPort -Name $PortName -PrinterHostAddress $IP -EA Stop
            & $Logger "Step 3: Port created OK"
        }
    } catch {
        & $Logger "Step 3: FAILED -- $($_.Exception.Message)"
        $success = $false
    }

    # Step 4: Install printer object
    & $Logger "Step 4: Creating printer object: $PrinterName"
    try {
        $existingPrinter = Get-Printer -Name $PrinterName -EA SilentlyContinue
        if ($existingPrinter) {
            & $Logger "Step 4: Printer already exists -- OK"
        } else {
            Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $PortName -EA Stop
            & $Logger "Step 4: Printer created OK"
        }
    } catch {
        & $Logger "Step 4: FAILED -- $($_.Exception.Message)"
        $success = $false
    }

    # Step 5: Verify
    & $Logger "Step 5: Verifying..."
    $verify = Get-Printer -Name $PrinterName -EA SilentlyContinue
    if ($verify) {
        & $Logger "Step 5: VERIFIED -- $PrinterName installed OK"
    } else {
        & $Logger "Step 5: WARN -- printer not found after install"
        $success = $false
    }

    & $Logger "=== Install complete. Success: $success ==="
    return $success
}

function Remove-NetworkPrinter {
    param([string]$PrinterName, [scriptblock]$Logger)
    & $Logger "Removing: $PrinterName"
    try {
        Remove-Printer -Name $PrinterName -EA Stop
        & $Logger "[OK] $PrinterName removed"
        return $true
    } catch {
        & $Logger "[FAILED] $($_.Exception.Message)"
        return $false
    }
}

# ===========================================================================
# XAML
# ===========================================================================
[xml]$XAML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Paladin Printer Manager"
    Height="720" Width="960"
    MinHeight="600" MinWidth="800"
    WindowStartupLocation="CenterScreen"
    Background="#F0F2F5"
    FontFamily="Segoe UI">

  <Window.Resources>
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Background" Value="#1565C0"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="16,7"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1976D2"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#BBDEFB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SecBtn" TargetType="Button">
      <Setter Property="Background" Value="White"/>
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
      <Setter Property="Background" Value="White"/>
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
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="58"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="44"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#0D47A1">
      <Grid Margin="16,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="[P]" FontSize="18" FontWeight="Bold" Foreground="White" Margin="0,0,10,0" VerticalAlignment="Center"/>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="PALADIN PRINTER MANAGER" FontSize="15" FontWeight="Bold" Foreground="White"/>
            <TextBlock x:Name="TxtHeader" Text="Site: - | Mode: -" FontSize="11" Foreground="#90CAF9"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <Border x:Name="BadgeMode" Background="#1565C0" CornerRadius="4" Padding="8,3" Margin="0,0,6,0">
            <TextBlock x:Name="TxtMode" Text="AUTO" FontSize="10" Foreground="#BBDEFB"/>
          </Border>
          <Border x:Name="BadgeDomain" Background="#1B5E20" CornerRadius="4" Padding="8,3">
            <TextBlock x:Name="TxtDomain" Text="DOMAIN" FontSize="10" Foreground="#A5D6A7"/>
          </Border>
        </StackPanel>
      </Grid>
    </Border>
    <TabControl Grid.Row="1" Background="#F0F2F5" BorderThickness="0" Margin="8,8,8,0">
      <TabItem Header="  Discover  " FontSize="13" FontWeight="SemiBold">
        <Grid Background="#F8F9FA">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="140"/>
          </Grid.RowDefinitions>
          <Border Grid.Row="0" Background="White" BorderBrush="#E0E0E0" BorderThickness="0,0,0,1" Padding="10,5,10,5">
            <StackPanel>
              <DockPanel LastChildFill="True" Margin="0,0,0,5">
                <Button x:Name="BtnScanStop" Content="Stop" DockPanel.Dock="Right"
                        Style="{StaticResource SecBtn}" Height="28" MinWidth="48"
                        Margin="4,0,0,0" IsEnabled="False"/>
                <Button x:Name="BtnScan" Content="Start Scan" DockPanel.Dock="Right"
                        Style="{StaticResource PrimaryBtn}" Height="28" MinWidth="90"/>
                <TextBlock Text="Subnet:" VerticalAlignment="Center" FontSize="12"
                           Foreground="#616161" Margin="0,0,5,0" DockPanel.Dock="Left"/>
                <TextBox x:Name="TxtSubnet" DockPanel.Dock="Left" Width="100" Height="26"
                         FontSize="12" Padding="5,3" BorderBrush="#BDBDBD" BorderThickness="1"
                         VerticalContentAlignment="Center" ToolTip="e.g. 192.168.1" Margin="0,0,2,0"/>
                <Button x:Name="BtnDetectSubnet" DockPanel.Dock="Left" Content="Auto"
                        Style="{StaticResource SecBtn}" Height="26" Padding="6,3"
                        Margin="0,0,8,0" ToolTip="Auto-detect subnet from active adapter"/>
                <TextBlock Text="From:" VerticalAlignment="Center" FontSize="12"
                           Foreground="#616161" Margin="0,0,5,0" DockPanel.Dock="Left"/>
                <TextBox x:Name="TxtScanFrom" DockPanel.Dock="Left" Width="48" Height="26"
                         FontSize="12" Text="1" Padding="5,3" BorderBrush="#BDBDBD"
                         BorderThickness="1" VerticalContentAlignment="Center" Margin="0,0,6,0"/>
                <TextBlock Text="To:" VerticalAlignment="Center" FontSize="12"
                           Foreground="#616161" Margin="0,0,5,0" DockPanel.Dock="Left"/>
                <TextBox x:Name="TxtScanTo" DockPanel.Dock="Left" Width="48" Height="26"
                         FontSize="12" Text="254" Padding="5,3" BorderBrush="#BDBDBD"
                         BorderThickness="1" VerticalContentAlignment="Center" Margin="0,0,0,0"/>
                <ProgressBar x:Name="PrgScan" Height="8" Margin="10,0,10,0"
                             Minimum="0" Maximum="100" Value="0"
                             Background="#E0E0E0" Foreground="#1565C0" VerticalAlignment="Center"/>
              </DockPanel>
              <DockPanel LastChildFill="True">
                <TextBlock Text="Speed:" VerticalAlignment="Center" FontSize="11"
                           Foreground="#616161" Margin="0,0,6,0" DockPanel.Dock="Left"/>
                <TextBlock Text="Stealth" VerticalAlignment="Center" FontSize="10"
                           Foreground="#E53935" Margin="0,0,4,0" DockPanel.Dock="Left"/>
                <Slider x:Name="SldSpeed" DockPanel.Dock="Left" Width="130"
                        Minimum="1" Maximum="5" Value="3"
                        IsSnapToTickEnabled="True" TickFrequency="1"
                        SmallChange="1" LargeChange="1" VerticalAlignment="Center"
                        Margin="0,0,4,0" ToolTip="Speed: 1=Stealth  3=Normal  5=Fast"/>
                <TextBlock Text="Fast" VerticalAlignment="Center" FontSize="10"
                           Foreground="#2E7D32" Margin="0,0,10,0" DockPanel.Dock="Left"/>
                <TextBlock x:Name="TxtSpeedLabel" DockPanel.Dock="Left" Text="Normal"
                           VerticalAlignment="Center" FontSize="10" FontWeight="SemiBold"
                           Foreground="#1565C0" Width="55" Margin="0,0,12,0"/>
                <TextBlock x:Name="TxtScanStatus" VerticalAlignment="Center"
                           FontSize="11" Foreground="#616161"/>
              </DockPanel>
            </StackPanel>
          </Border>
          <DataGrid x:Name="GridDiscover"
                    Grid.Row="1"
                    AutoGenerateColumns="False"
                    IsReadOnly="True"
                    GridLinesVisibility="Horizontal"
                    HeadersVisibility="Column"
                    SelectionMode="Single"
                    CanUserReorderColumns="False"
                    CanUserResizeRows="False"
                    Background="White"
                    RowBackground="White"
                    AlternatingRowBackground="#FAFAFA"
                    BorderThickness="0"
                    FontSize="12"
                    Margin="0">
            <DataGrid.ContextMenu>
              <ContextMenu>
                <MenuItem x:Name="MnuAssign"     Header="Assign Make / Model / Driver..."/>
                <MenuItem x:Name="MnuGetDriver"  Header="Search for Driver Online"/>
                <Separator/>
                <MenuItem x:Name="MnuAddSiteVar" Header="Add to Site Variable"/>
                <MenuItem x:Name="MnuSendDeploy" Header="Send to Deploy Tab"/>
              </ContextMenu>
            </DataGrid.ContextMenu>
            <DataGrid.Columns>
              <DataGridTextColumn Header="IP Address"    Binding="{Binding IP}"           Width="120"/>
              <DataGridTextColumn Header="Model"         Binding="{Binding Model}"         Width="*"/>
              <DataGridTextColumn Header="Manufacturer"  Binding="{Binding Manufacturer}"  Width="110"/>
              <DataGridTextColumn Header="Serial"        Binding="{Binding Serial}"        Width="120"/>
              <DataGridTextColumn Header="Pages"         Binding="{Binding PageCount}"     Width="70"/>
              <DataGridTextColumn Header="Status"        Binding="{Binding ScanStatus}"    Width="100"/>
            </DataGrid.Columns>
          </DataGrid>
          <Border Grid.Row="2" Background="White" BorderBrush="#E0E0E0" BorderThickness="0,1,0,1" Padding="12,6">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock VerticalAlignment="Center" FontSize="12" Foreground="#616161"/>
              <Button x:Name="BtnAddToSiteVar"  Grid.Column="1" Content="Add Selected to Site Variable"
                      Style="{StaticResource SecBtn}" Height="30" Margin="0,0,6,0" IsEnabled="False"/>
              <Button x:Name="BtnOpenDriverUrl" Grid.Column="2" Content="Get Driver"
                      Style="{StaticResource SecBtn}" Height="30" Margin="0,0,6,0" IsEnabled="False"
                      ToolTip="Opens manufacturer driver download page"/>
              <Button x:Name="BtnAddToQueue"    Grid.Column="3" Content="Send to Deploy Tab"
                      Style="{StaticResource PrimaryBtn}" Height="30" IsEnabled="False"/>
            </Grid>
          </Border>
          <Border Grid.Row="3" Background="#1A1A2E">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <TextBox x:Name="TxtScanLog"
                       Background="Transparent" Foreground="#D4D4D4"
                       FontFamily="Cascadia Mono,Consolas" FontSize="11"
                       BorderThickness="0" IsReadOnly="True"
                       TextWrapping="NoWrap" Padding="12,8"
                       AcceptsReturn="True" VerticalScrollBarVisibility="Disabled"/>
            </ScrollViewer>
          </Border>
        </Grid>
      </TabItem>
      <TabItem Header="  Deploy  " FontSize="13" FontWeight="SemiBold">
        <Grid Background="#F8F9FA">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="300"/>
          </Grid.ColumnDefinitions>
          <Grid Grid.Column="0">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Border Grid.Row="0" Background="White" BorderBrush="#E0E0E0"
                    BorderThickness="0,0,0,1" Padding="16,12">
              <StackPanel>
                <TextBlock Text="Select Printer to Deploy" FontSize="13" FontWeight="SemiBold"
                           Foreground="#212121" Margin="0,0,0,10"/>

                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="Printer:" VerticalAlignment="Center" FontSize="12"
                             Foreground="#616161" Margin="0,0,10,0" Width="70"/>
                  <ComboBox x:Name="CmbPrinters" Grid.Column="1" Height="30"
                            FontSize="12" VerticalContentAlignment="Center"/>
                </Grid>

                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="Name:" VerticalAlignment="Center" FontSize="12"
                             Foreground="#616161" Margin="0,0,10,0" Width="70"/>
                  <TextBox x:Name="TxtPrinterName" Grid.Column="1" Height="30"
                           FontSize="12" Padding="6,4" BorderBrush="#BDBDBD"
                           BorderThickness="1" VerticalContentAlignment="Center"
                           ToolTip="Friendly name shown in Windows"/>
                </Grid>

                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="Driver:" VerticalAlignment="Center" FontSize="12"
                             Foreground="#616161" Margin="0,0,10,0" Width="70"/>
                  <TextBox x:Name="TxtDriverName" Grid.Column="1" Height="30"
                           FontSize="12" Padding="6,4" BorderBrush="#BDBDBD"
                           BorderThickness="1" VerticalContentAlignment="Center"
                           ToolTip="Exact driver name as registered in Windows"/>
                </Grid>

                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="INF:" VerticalAlignment="Center" FontSize="12"
                             Foreground="#616161" Margin="0,0,10,0" Width="70"/>
                  <TextBox x:Name="TxtINFPath" Grid.Column="1" Height="30"
                           FontSize="11" Padding="6,4" BorderBrush="#BDBDBD"
                           BorderThickness="1" VerticalContentAlignment="Center"
                           ToolTip="Path to .INF driver file (optional if driver already in store)"/>
                  <Button x:Name="BtnBrowseINF" Grid.Column="2" Content="..."
                          Style="{StaticResource SecBtn}" Height="30" Width="32"
                          Padding="4,4" Margin="4,0,0,0"/>
                </Grid>

                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="Port:" VerticalAlignment="Center" FontSize="12"
                             Foreground="#616161" Margin="0,0,10,0" Width="70"/>
                  <TextBox x:Name="TxtPortName" Grid.Column="1" Height="30"
                           FontSize="11" Padding="6,4" BorderBrush="#BDBDBD"
                           BorderThickness="1" VerticalContentAlignment="Center"
                           ToolTip="TCP/IP port name - auto-generated from IP, override if needed"/>
                  <Button x:Name="BtnRefreshPort" Grid.Column="2" Content="Auto"
                          Style="{StaticResource SecBtn}" Height="30" Width="42"
                          Padding="4,4" Margin="4,0,0,0"
                          ToolTip="Auto-generate port name from IP address"/>
                </Grid>
                <Border x:Name="PnlDriverStatus" Background="#F3F4F6" CornerRadius="4"
                        Padding="10,6" Margin="0,0,0,10">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock x:Name="TxtDriverStatus" Text="Select a printer to check driver status"
                               FontSize="11" Foreground="#616161" VerticalAlignment="Center"/>
                  </StackPanel>
                </Border>

                <StackPanel Orientation="Horizontal">
                  <Button x:Name="BtnInstall" Content="Install Printer"
                          Style="{StaticResource PrimaryBtn}" Height="34" Margin="0,0,8,0"/>
                  <Button x:Name="BtnGetDriver" Content="Download Driver"
                          Style="{StaticResource SecBtn}" Height="34" Margin="0,0,8,0"
                          ToolTip="Opens manufacturer driver page in browser"/>
                  <Button x:Name="BtnBrowseDriver" Content="Browse Cache"
                          Style="{StaticResource SecBtn}" Height="34"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Grid.Row="1" Background="#1A1A2E">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <TextBox x:Name="TxtInstallLog"
                         Background="Transparent" Foreground="#D4D4D4"
                         FontFamily="Cascadia Mono,Consolas" FontSize="11"
                         BorderThickness="0" IsReadOnly="True"
                         TextWrapping="NoWrap" Padding="12,8"
                         AcceptsReturn="True" VerticalScrollBarVisibility="Disabled"/>
              </ScrollViewer>
            </Border>
          </Grid>
          <Border Grid.Column="1" Background="White" BorderBrush="#E0E0E0"
                  BorderThickness="1,0,0,0" Padding="16,16">
            <StackPanel>
              <TextBlock Text="PRINTER DETAILS" FontSize="10" FontWeight="Bold"
                         Foreground="#9E9E9E" Margin="0,0,0,12"/>

              <TextBlock Text="IP Address" FontSize="10" Foreground="#9E9E9E" Margin="0,0,0,2"/>
              <TextBlock x:Name="TxtInfoIP" Text="-" FontSize="13" FontWeight="SemiBold"
                         Foreground="#212121" Margin="0,0,0,10"/>

              <TextBlock Text="Model" FontSize="10" Foreground="#9E9E9E" Margin="0,0,0,2"/>
              <TextBlock x:Name="TxtInfoModel" Text="-" FontSize="12"
                         Foreground="#424242" TextWrapping="Wrap" Margin="0,0,0,10"/>

              <TextBlock Text="Manufacturer" FontSize="10" Foreground="#9E9E9E" Margin="0,0,0,2"/>
              <TextBlock x:Name="TxtInfoMfr" Text="-" FontSize="12" Foreground="#424242" Margin="0,0,0,10"/>

              <TextBlock Text="Status" FontSize="10" Foreground="#9E9E9E" Margin="0,0,0,2"/>
              <Border x:Name="BadgeStatus" Background="#E8F5E9" CornerRadius="3" Padding="8,3"
                      HorizontalAlignment="Left" Margin="0,0,0,10">
                <TextBlock x:Name="TxtInfoStatus" Text="Unknown" FontSize="11"
                           Foreground="#2E7D32" FontWeight="SemiBold"/>
              </Border>

              <TextBlock Text="Driver URL" FontSize="10" Foreground="#9E9E9E" Margin="0,0,0,2"/>
              <TextBlock x:Name="TxtInfoDriverUrl" Text="-" FontSize="11"
                         Foreground="#1565C0" TextWrapping="Wrap" Margin="0,0,0,4"
                         Cursor="Hand" TextDecorations="Underline"/>

              <Separator Margin="0,12,0,12"/>

              <TextBlock Text="DRIVER CACHE" FontSize="10" FontWeight="Bold"
                         Foreground="#9E9E9E" Margin="0,0,0,8"/>
              <TextBlock x:Name="TxtCacheStatus" Text="Checking..."
                         FontSize="11" Foreground="#616161" TextWrapping="Wrap" Margin="0,0,0,8"/>
              <Button x:Name="BtnOpenCache" Content="Open Cache Folder"
                      Style="{StaticResource SecBtn}" Height="28" HorizontalAlignment="Left"/>
            </StackPanel>
          </Border>
        </Grid>
      </TabItem>
      <TabItem Header="  Installed  " FontSize="13" FontWeight="SemiBold">
        <Grid Background="#F8F9FA">
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="50"/>
          </Grid.RowDefinitions>

          <DataGrid x:Name="GridInstalled"
                    Grid.Row="0"
                    AutoGenerateColumns="False"
                    IsReadOnly="True"
                    GridLinesVisibility="Horizontal"
                    HeadersVisibility="Column"
                    SelectionMode="Single"
                    CanUserReorderColumns="False"
                    CanUserResizeRows="False"
                    Background="White"
                    RowBackground="White"
                    AlternatingRowBackground="#FAFAFA"
                    BorderThickness="0"
                    FontSize="12">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Printer Name"  Binding="{Binding Name}"       Width="*"/>
              <DataGridTextColumn Header="Driver"        Binding="{Binding DriverName}"  Width="200"/>
              <DataGridTextColumn Header="Port"          Binding="{Binding PortName}"    Width="150"/>
              <DataGridTextColumn Header="Status"        Binding="{Binding PrinterStatus}" Width="100"/>
              <DataGridTextColumn Header="Default"       Binding="{Binding IsDefault}"   Width="70"/>
            </DataGrid.Columns>
          </DataGrid>

          <Border Grid.Row="1" Background="White" BorderBrush="#E0E0E0" BorderThickness="0,1,0,0">
            <Grid Margin="12,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="TxtInstalledCount" VerticalAlignment="Center"
                         FontSize="12" Foreground="#616161"/>
              <Button x:Name="BtnRefreshInstalled" Grid.Column="1" Content="Refresh"
                      Style="{StaticResource SecBtn}" Height="30" Margin="0,0,6,0"/>
              <Button x:Name="BtnSetDefault" Grid.Column="2" Content="Set as Default"
                      Style="{StaticResource SecBtn}" Height="30" Margin="0,0,6,0"/>
              <Button x:Name="BtnRemovePrinter" Grid.Column="3" Content="Remove"
                      Style="{StaticResource DangerBtn}" Height="30"/>
            </Grid>
          </Border>
        </Grid>
      </TabItem>
    </TabControl>
    <Border Grid.Row="2" Background="White" BorderBrush="#E0E0E0" BorderThickness="0,1,0,0">
      <Grid Margin="16,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="TxtStatusBar" VerticalAlignment="Center"
                   FontSize="11" Foreground="#757575"/>
        <Button x:Name="BtnClose" Grid.Column="1" Content="Close"
                Style="{StaticResource SecBtn}" Height="30" Padding="16,0"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

# ===========================================================================
# LOAD WINDOW
# ===========================================================================
try {
    $reader = New-Object System.Xml.XmlNodeReader $XAML
    $Win    = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.MessageBox]::Show("Failed to load GUI: $($_.Exception.Message)",'Error')
    exit 1
}

# Control references
$TxtHeader         = $Win.FindName('TxtHeader')
$TxtMode           = $Win.FindName('TxtMode')
$TxtDomain         = $Win.FindName('TxtDomain')
$BadgeDomain       = $Win.FindName('BadgeDomain')
$TxtSubnet         = $Win.FindName('TxtSubnet')
$TxtScanFrom       = $Win.FindName('TxtScanFrom')
$TxtScanTo         = $Win.FindName('TxtScanTo')
$PrgScan           = $Win.FindName('PrgScan')
$BtnScan           = $Win.FindName('BtnScan')
$BtnScanStop       = $Win.FindName('BtnScanStop')
$BtnDetectSubnet   = $Win.FindName('BtnDetectSubnet')
$SldSpeed          = $Win.FindName('SldSpeed')
$TxtSpeedLabel     = $Win.FindName('TxtSpeedLabel')
$GridDiscover      = $Win.FindName('GridDiscover')
$MnuAssign         = $GridDiscover.ContextMenu.Items | Where-Object { $_.Header -eq 'Assign Make / Model / Driver...' } | Select-Object -First 1
$MnuGetDriver      = $GridDiscover.ContextMenu.Items | Where-Object { $_.Header -eq 'Search for Driver Online' } | Select-Object -First 1
$MnuAddSiteVar     = $GridDiscover.ContextMenu.Items | Where-Object { $_.Header -eq 'Add to Site Variable' } | Select-Object -First 1
$MnuSendDeploy     = $GridDiscover.ContextMenu.Items | Where-Object { $_.Header -eq 'Send to Deploy Tab' } | Select-Object -First 1
$TxtScanStatus     = $Win.FindName('TxtScanStatus')
$BtnAddToSiteVar   = $Win.FindName('BtnAddToSiteVar')
$BtnOpenDriverUrl  = $Win.FindName('BtnOpenDriverUrl')
$BtnAddToQueue     = $Win.FindName('BtnAddToQueue')
$TxtScanLog        = $Win.FindName('TxtScanLog')
$CmbPrinters       = $Win.FindName('CmbPrinters')
$TxtPrinterName    = $Win.FindName('TxtPrinterName')
$TxtDriverName     = $Win.FindName('TxtDriverName')
$TxtINFPath        = $Win.FindName('TxtINFPath')
$BtnBrowseINF      = $Win.FindName('BtnBrowseINF')
$TxtPortName       = $Win.FindName('TxtPortName')
$BtnRefreshPort    = $Win.FindName('BtnRefreshPort')
$TxtDriverStatus   = $Win.FindName('TxtDriverStatus')
$PnlDriverStatus   = $Win.FindName('PnlDriverStatus')
$BtnInstall        = $Win.FindName('BtnInstall')
$BtnGetDriver      = $Win.FindName('BtnGetDriver')
$BtnBrowseDriver   = $Win.FindName('BtnBrowseDriver')
$TxtInstallLog     = $Win.FindName('TxtInstallLog')
$TxtInfoIP         = $Win.FindName('TxtInfoIP')
$TxtInfoModel      = $Win.FindName('TxtInfoModel')
$TxtInfoMfr        = $Win.FindName('TxtInfoMfr')
$TxtInfoStatus     = $Win.FindName('TxtInfoStatus')
$BadgeStatus       = $Win.FindName('BadgeStatus')
$TxtInfoDriverUrl  = $Win.FindName('TxtInfoDriverUrl')
$TxtCacheStatus    = $Win.FindName('TxtCacheStatus')
$BtnOpenCache      = $Win.FindName('BtnOpenCache')
$GridInstalled     = $Win.FindName('GridInstalled')
$TxtInstalledCount = $Win.FindName('TxtInstalledCount')
$BtnRefreshInstalled = $Win.FindName('BtnRefreshInstalled')
$BtnSetDefault     = $Win.FindName('BtnSetDefault')
$BtnRemovePrinter  = $Win.FindName('BtnRemovePrinter')
$TxtStatusBar      = $Win.FindName('TxtStatusBar')
$BtnClose          = $Win.FindName('BtnClose')

# Runtime state
$script:ScanRunning   = $false
$script:ScanResults   = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:SelectedPrint = $null
$script:SiteVar       = $null

# ===========================================================================
# UI HELPERS
# ===========================================================================
function ScanLog {
    param([string]$Msg)
    $ts = Get-Date -Format 'HH:mm:ss'
    $TxtScanLog.Dispatcher.Invoke([action]{
        $TxtScanLog.AppendText("[$ts] $Msg`r`n")
        $TxtScanLog.ScrollToEnd()
    })
    Write-Log $Msg
}

function InstallLog {
    param([string]$Msg)
    $ts = Get-Date -Format 'HH:mm:ss'
    $TxtInstallLog.Dispatcher.Invoke([action]{
        $TxtInstallLog.AppendText("[$ts] $Msg`r`n")
        $TxtInstallLog.ScrollToEnd()
    })
    Write-Log $Msg
}

function Set-Status { param([string]$Msg)
    $TxtStatusBar.Dispatcher.Invoke([action]{ $TxtStatusBar.Text = $Msg })
}

function Load-InstalledPrinters {
    $printers = Get-Printer -EA SilentlyContinue | ForEach-Object {
        $default = try { (Get-WmiObject -Query "SELECT * FROM Win32_Printer WHERE Name='$($_.Name)'" -EA SilentlyContinue).Default } catch { $false }
        [PSCustomObject]@{
            Name          = $_.Name
            DriverName    = $_.DriverName
            PortName      = $_.PortName
            PrinterStatus = $_.PrinterStatus
            IsDefault     = if ($default) { 'Yes' } else { '' }
        }
    }
    $GridInstalled.Dispatcher.Invoke([action]{
        $GridInstalled.ItemsSource = $printers
        $TxtInstalledCount.Text   = "$(@($printers).Count) printer(s) installed"
    })
}

function Load-DeployPrinterList {
    $CmbPrinters.Items.Clear()
    $CmbPrinters.Items.Add('[Select a printer...]') | Out-Null
    foreach ($p in (Get-PrinterList)) {
        $CmbPrinters.Items.Add("$($p.Name) [$($p.IP)]") | Out-Null
    }
    if ($CmbPrinters.Items.Count -gt 0) { $CmbPrinters.SelectedIndex = 0 }
}

function Update-PrinterInfoPanel {
    param([PSCustomObject]$Printer)
    if ($null -eq $Printer) {
        $TxtInfoIP.Text = '-'; $TxtInfoModel.Text = '-'
        $TxtInfoMfr.Text = '-'; $TxtInfoStatus.Text = 'Unknown'
        $TxtInfoDriverUrl.Text = '-'; $TxtCacheStatus.Text = '-'
        return
    }

    $TxtInfoIP.Text    = $Printer.IP
    $TxtInfoModel.Text = $Printer.Model
    $TxtInfoMfr.Text   = $Printer.Manufacturer

    # Check if already installed
    $installed = Get-Printer -Name $Printer.Name -EA SilentlyContinue
    if ($installed) {
        $TxtInfoStatus.Text     = 'Installed'
        $TxtInfoStatus.Foreground = [System.Windows.Media.Brushes]::Green
        $BadgeStatus.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(232,245,233))
    } else {
        $TxtInfoStatus.Text     = 'Not Installed'
        $TxtInfoStatus.Foreground = [System.Windows.Media.Brushes]::DarkOrange
        $BadgeStatus.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(255,243,224))
    }

    # Driver URL
    $url = if ($Printer.DriverUrl) { $Printer.DriverUrl }
           elseif ($DriverUrls.ContainsKey($Printer.Manufacturer)) { $DriverUrls[$Printer.Manufacturer] }
           else { $DriverUrls['Unknown'] }
    $TxtInfoDriverUrl.Text = $url
    $script:SelectedPrint = $Printer

    # Cache check
    $cached = Get-CachedDriver -Manufacturer $Printer.Manufacturer -DriverFile $Printer.DriverFile
    if ($cached) {
        $TxtCacheStatus.Text       = "Driver found:`n$cached"
        $TxtCacheStatus.Foreground = [System.Windows.Media.Brushes]::DarkGreen
        $TxtINFPath.Text           = $cached
        $TxtDriverStatus.Text      = 'Driver cached -- ready to install'
        $PnlDriverStatus.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(232,245,233))
    } else {
        $TxtCacheStatus.Text       = "No cached driver found for $($Printer.Manufacturer)"
        $TxtCacheStatus.Foreground = [System.Windows.Media.Brushes]::DarkOrange
        $TxtDriverStatus.Text      = 'No cached driver -- download required before install'
        $PnlDriverStatus.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(255,243,224))
    }

    # Populate deploy fields
    $TxtPrinterName.Text = $Printer.Name
    $TxtDriverName.Text  = $Printer.Driver
    $TxtPortName.Text    = "IP_$($Printer.IP.Replace('.','_'))"
}

# ===========================================================================
# DISCOVER TAB EVENTS
# ===========================================================================
# Speed map: slider value -> (TCP timeout ms, SNMP timeout ms, label, color)
$script:SpeedMap = @{
    1 = @{ TCP=1500; SNMP=2500; Label='Stealth';  Color='#9C27B0'; Tip='Very slow -- minimizes IDS alerts' }
    2 = @{ TCP=900;  SNMP=1800; Label='Cautious'; Color='#FF9800'; Tip='Slow -- suitable for monitored networks' }
    3 = @{ TCP=500;  SNMP=1500; Label='Normal';   Color='#1565C0'; Tip='Balanced speed and stealth' }
    4 = @{ TCP=300;  SNMP=900;  Label='Fast';     Color='#4CAF50'; Tip='Faster -- may trigger IDS on strict networks' }
    5 = @{ TCP=150;  SNMP=500;  Label='Fastest';  Color='#F44336'; Tip='Maximum speed -- will likely trigger IDS/IPS' }
}

$SldSpeed.Add_ValueChanged({
    $spd = [int]$SldSpeed.Value
    $map = $script:SpeedMap[$spd]
    $TxtSpeedLabel.Text       = $map.Label
    $TxtSpeedLabel.Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.ColorConverter]::ConvertFromString($map.Color))
    $SldSpeed.ToolTip         = "$($map.Label): TCP $($map.TCP)ms | SNMP $($map.SNMP)ms | $($map.Tip)"
})

# ===========================================================================
# ASSIGN PRINTER DIALOG
# ===========================================================================
function Invoke-DriverExeInstall {
    param([string]$ExePath, [string]$CacheDestDir, [string]$Mfr)
    # Snapshot driver store before install
    $beforeDrivers = @(Get-PrinterDriver -EA SilentlyContinue | Select-Object -ExpandProperty Name)

    # Run installer once -- with -Wait. User may see a UI. That is expected for EXE installers.
    # We cannot silently extract most manufacturer EXEs -- they are installers, not archives.
    $proc = Start-Process -FilePath $ExePath -Wait -PassThru -EA SilentlyContinue

    # Snapshot after -- find newly registered drivers
    $afterDrivers  = @(Get-PrinterDriver -EA SilentlyContinue | Select-Object -ExpandProperty Name)
    $newDrivers    = $afterDrivers | Where-Object { $beforeDrivers -notcontains $_ }

    # Also check driver store (DriverStorePath) for new INF files from this manufacturer
    $infFound = $null
    $driverStorePath = "$env:SystemRoot\System32\DriverStore\FileRepository"
    if (Test-Path $driverStorePath) {
        $inf = Get-ChildItem $driverStorePath -Filter '*.inf' -Recurse -EA SilentlyContinue |
               Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-10) -and
                              (Get-Content $_.FullName -EA SilentlyContinue | Select-String $Mfr -Quiet) } |
               Select-Object -First 1
        if ($inf) { $infFound = $inf.FullName }
    }

    return [PSCustomObject]@{
        NewDrivers = $newDrivers
        INFPath    = $infFound
        ExitCode   = if ($proc) { $proc.ExitCode } else { -1 }
    }
}

function Show-AssignDialog {
    param([PSCustomObject]$Printer)

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName System.Windows.Forms

    # Resolve winget path here in main scope where function is defined
    $wgPath = Get-WingetExe

    [xml]$dlgXAML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Assign Printer Details"
    Height="640" Width="560"
    MinHeight="480" MinWidth="480"
    WindowStartupLocation="CenterOwner"
    ResizeMode="CanResizeWithGrip"
    Background="#F5F5F5"
    FontFamily="Segoe UI">
  <Grid Margin="0">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="#0D47A1" Padding="16,12">
      <StackPanel>
        <TextBlock Text="Assign Printer Details" FontSize="15" FontWeight="Bold" Foreground="White"/>
        <TextBlock x:Name="DlgIP"   Text="" FontSize="11" Foreground="#90CAF9" Margin="0,2,0,0"/>
        <TextBlock x:Name="DlgSNMP" Text="" FontSize="10" Foreground="#64B5F6" TextWrapping="Wrap" Margin="0,2,0,0"/>
      </StackPanel>
    </Border>

    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Padding="16,12,16,12">
      <StackPanel>

        <TextBlock Text="Friendly Name (shown in Windows):" FontSize="12" Foreground="#424242" Margin="0,0,0,4"/>
        <TextBox x:Name="TxtDlgName" Height="30" FontSize="12" Padding="8,4"
                 BorderBrush="#BDBDBD" BorderThickness="1" Margin="0,0,0,12"/>

        <TextBlock Text="Manufacturer:" FontSize="12" Foreground="#424242" Margin="0,0,0,4"/>
        <ComboBox x:Name="CmbDlgMfr" Height="30" FontSize="12" Margin="0,0,0,12"
                  VerticalContentAlignment="Center"/>

        <TextBlock Text="Model (for driver search):" FontSize="12" Foreground="#424242" Margin="0,0,0,4"/>
        <TextBox x:Name="TxtDlgModel" Height="30" FontSize="12" Padding="8,4"
                 BorderBrush="#BDBDBD" BorderThickness="1" Margin="0,0,0,12"/>

        <TextBlock Text="Driver Name (as registered in Windows):" FontSize="12" Foreground="#424242" Margin="0,0,0,4"/>
        <TextBox x:Name="TxtDlgDriver" Height="30" FontSize="12" Padding="8,4"
                 BorderBrush="#BDBDBD" BorderThickness="1" Margin="0,0,0,16"/>

        <Border Background="#E3F2FD" CornerRadius="4" Padding="12,10" Margin="0,0,0,12">
          <StackPanel>
            <TextBlock Text="Driver Search" FontSize="11" FontWeight="Bold"
                       Foreground="#1565C0" Margin="0,0,0,8"/>
            <WrapPanel Margin="0,0,0,8">
              <Button x:Name="BtnDlgSearchWeb" Content="Manufacturer Site"
                      Height="28" Padding="10,4" Margin="0,0,6,4"
                      Background="#1565C0" Foreground="White" BorderThickness="0" Cursor="Hand"/>
              <Button x:Name="BtnDlgSearchGoogle" Content="Google Search"
                      Height="28" Padding="10,4" Margin="0,0,6,4"
                      Background="#4CAF50" Foreground="White" BorderThickness="0" Cursor="Hand"/>
              <Button x:Name="BtnDlgWinget" Content="Winget Search"
                      Height="28" Padding="10,4" Margin="0,0,0,4"
                      Background="#FF9800" Foreground="White" BorderThickness="0" Cursor="Hand"/>
            </WrapPanel>
            <Border Background="White" BorderBrush="#BDBDBD" BorderThickness="1" CornerRadius="3" Padding="6,4" MaxHeight="80">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <TextBlock x:Name="TxtDlgSearchResult"
                           Text="Select manufacturer and model, then search."
                           FontSize="10" Foreground="#616161" TextWrapping="Wrap"/>
              </ScrollViewer>
            </Border>
          </StackPanel>
        </Border>

        <Border Background="#E8F5E9" CornerRadius="4" Padding="12,10" Margin="0,0,0,12">
          <StackPanel>
            <TextBlock Text="Add Driver to Cache" FontSize="11" FontWeight="Bold"
                       Foreground="#2E7D32" Margin="0,0,0,8"/>

            <TextBlock Text="Option 1 - Download from URL:" FontSize="11"
                       Foreground="#424242" Margin="0,0,0,4"/>
            <DockPanel Margin="0,0,0,8" LastChildFill="True">
              <Button x:Name="BtnDlgDownload" DockPanel.Dock="Right" Content="Download"
                      Height="28" Padding="10,4" Margin="4,0,0,0"
                      Background="#2E7D32" Foreground="White" BorderThickness="0" Cursor="Hand"/>
              <TextBox x:Name="TxtDlgDriverUrl" Height="28" FontSize="11" Padding="6,4"
                       BorderBrush="#BDBDBD" BorderThickness="1"
                       VerticalContentAlignment="Center"
                       ToolTip="Paste direct download URL for the driver EXE or ZIP"/>
            </DockPanel>

            <TextBlock Text="Option 2 - Browse for already-downloaded file:" FontSize="11"
                       Foreground="#424242" Margin="0,0,0,4"/>
            <DockPanel Margin="0,0,0,8" LastChildFill="True">
              <Button x:Name="BtnDlgBrowse" DockPanel.Dock="Right" Content="Browse..."
                      Height="28" Padding="10,4" Margin="4,0,0,0"
                      Background="#546E7A" Foreground="White" BorderThickness="0" Cursor="Hand"/>
              <TextBox x:Name="TxtDlgBrowsePath" Height="28" FontSize="11" Padding="6,4"
                       BorderBrush="#BDBDBD" BorderThickness="1"
                       VerticalContentAlignment="Center" IsReadOnly="True"/>
            </DockPanel>

            <Border x:Name="PnlCacheStatus" Background="#F1F8E9" CornerRadius="3"
                    Padding="8,4" Visibility="Collapsed">
              <TextBlock x:Name="TxtCacheStatus2" FontSize="10" Foreground="#2E7D32" TextWrapping="Wrap"/>
            </Border>
          </StackPanel>
        </Border>

      </StackPanel>
    </ScrollViewer>

    <Border Grid.Row="2" Background="White" BorderBrush="#E0E0E0" BorderThickness="0,1,0,0" Padding="16,10">
      <DockPanel LastChildFill="False">
        <Button x:Name="BtnDlgCancel" DockPanel.Dock="Right" Content="Cancel"
                Height="32" Padding="14,6" Margin="0,0,0,0"
                Background="#E0E0E0" Foreground="#333" BorderThickness="0" Cursor="Hand"/>
        <Button x:Name="BtnDlgSave" DockPanel.Dock="Right" Content="Save to Site Variable"
                Height="32" Padding="14,6" Margin="0,0,8,0"
                Background="#2E7D32" Foreground="White" BorderThickness="0" Cursor="Hand"/>
        <Button x:Name="BtnDlgAddDeploy" DockPanel.Dock="Right" Content="Save + Deploy Tab"
                Height="32" Padding="14,6" Margin="0,0,8,0"
                Background="#1565C0" Foreground="White" BorderThickness="0" Cursor="Hand"/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

    $dlgReader = New-Object System.Xml.XmlNodeReader $dlgXAML
    $dlg       = [Windows.Markup.XamlReader]::Load($dlgReader)

    $DlgIP              = $dlg.FindName('DlgIP')
    $DlgSNMP            = $dlg.FindName('DlgSNMP')
    $TxtDlgName         = $dlg.FindName('TxtDlgName')
    $CmbDlgMfr          = $dlg.FindName('CmbDlgMfr')
    $TxtDlgModel        = $dlg.FindName('TxtDlgModel')
    $TxtDlgDriver       = $dlg.FindName('TxtDlgDriver')
    $BtnDlgSearchWeb    = $dlg.FindName('BtnDlgSearchWeb')
    $BtnDlgSearchGoogle = $dlg.FindName('BtnDlgSearchGoogle')
    $BtnDlgWinget       = $dlg.FindName('BtnDlgWinget')
    $TxtDlgSearchResult = $dlg.FindName('TxtDlgSearchResult')
    $TxtDlgDriverUrl    = $dlg.FindName('TxtDlgDriverUrl')
    $BtnDlgDownload     = $dlg.FindName('BtnDlgDownload')
    $TxtDlgBrowsePath   = $dlg.FindName('TxtDlgBrowsePath')
    $BtnDlgBrowse       = $dlg.FindName('BtnDlgBrowse')
    $PnlCacheStatus     = $dlg.FindName('PnlCacheStatus')
    $TxtCacheStatus2    = $dlg.FindName('TxtCacheStatus2')
    $BtnDlgAddDeploy    = $dlg.FindName('BtnDlgAddDeploy')
    $BtnDlgSave         = $dlg.FindName('BtnDlgSave')
    $BtnDlgCancel       = $dlg.FindName('BtnDlgCancel')

    # Pre-fill
    $DlgIP.Text   = "IP: $($Printer.IP)"
    $DlgSNMP.Text = "SNMP: $($Printer.Model)"
    $TxtDlgName.Text  = if ($Printer.Model -ne 'Unknown') { $Printer.Model } else { '' }
    $TxtDlgModel.Text = if ($Printer.Model -ne 'Unknown') { $Printer.Model } else { '' }

    # Manufacturer dropdown
    $mfrs = @('HP','Canon','Epson','Brother','Xerox','Ricoh','Lexmark',
              'Kyocera','Samsung','Konica','Zebra','Toshiba','Sharp','Panasonic','Other')
    foreach ($m in $mfrs) { $CmbDlgMfr.Items.Add($m) | Out-Null }

    $detectedMfr = if ($Printer.Manufacturer -ne 'Unknown') { $Printer.Manufacturer }
                   else { Get-Manufacturer $Printer.Model }
    if ($mfrs -contains $detectedMfr) { $CmbDlgMfr.SelectedItem = $detectedMfr }
    else { $CmbDlgMfr.SelectedIndex = 0 }

    $CmbDlgMfr.Add_SelectionChanged({
        $mfr = $CmbDlgMfr.SelectedItem
        if ($mfr -and -not $TxtDlgDriver.Text) {
            $TxtDlgDriver.Text = "$mfr Universal Print Driver"
        }
    })

    # Search buttons
    $BtnDlgSearchWeb.Add_Click({
        $mfr   = $CmbDlgMfr.SelectedItem
        $model = $TxtDlgModel.Text.Trim()
        if (-not $model) { $TxtDlgSearchResult.Text = 'Enter a model name first.'; return }
        $url = switch ($mfr) {
            'HP'      { "https://support.hp.com/us-en/drivers?query=$([Uri]::EscapeDataString($model))" }
            'Canon'   { "https://www.usa.canon.com/support/software-drivers?query=$([Uri]::EscapeDataString($model))" }
            'Epson'   { "https://epson.com/Support/Printers/s/$([Uri]::EscapeDataString($model))" }
            'Brother' { "https://support.brother.com/g/b/productsearch.aspx?q=$([Uri]::EscapeDataString($model))" }
            'Xerox'   { "https://www.xerox.com/en-us/support?search=$([Uri]::EscapeDataString($model))" }
            'Ricoh'   { "https://www.ricoh-usa.com/en/support-and-download?q=$([Uri]::EscapeDataString($model))" }
            'Lexmark' { "https://www.lexmark.com/en_us/support/downloads.html?query=$([Uri]::EscapeDataString($model))" }
            'Kyocera' { "https://www.kyoceradocumentsolutions.us/en/support/downloads.html?q=$([Uri]::EscapeDataString($model))" }
            default   { "https://www.google.com/search?q=$([Uri]::EscapeDataString("$mfr $model driver site:$($mfr.ToLower()).com"))" }
        }
        Start-Process $url
        $TxtDlgSearchResult.Text = "Opened: $url"
        $TxtDlgDriverUrl.Text    = ''
    })

    $BtnDlgSearchGoogle.Add_Click({
        $mfr   = $CmbDlgMfr.SelectedItem
        $model = $TxtDlgModel.Text.Trim()
        if (-not $model) { $TxtDlgSearchResult.Text = 'Enter a model name first.'; return }
        $q = [Uri]::EscapeDataString("$mfr $model Windows 10 11 driver download")
        Start-Process "https://www.google.com/search?q=$q"
        $TxtDlgSearchResult.Text = "Google opened for: $mfr $model"
    })

    $BtnDlgWinget.Add_Click({
        $mfr   = $CmbDlgMfr.SelectedItem
        $model = $TxtDlgModel.Text.Trim()
        if (-not $model) { $TxtDlgSearchResult.Text = 'Enter a model name first.'; return }
        $TxtDlgSearchResult.Text = 'Searching winget...'
        $dlg.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        try {
            if ($wgPath) {
                # Force ASCII output -- winget uses UTF-8 with BOM which corrupts in PS5.1
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName               = $wgPath
                $psi.Arguments              = "search `"$mfr $model`" --disable-interactivity --accept-source-agreements"
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.UseShellExecute        = $false
                $psi.CreateNoWindow         = $true
                $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
                $proc = [System.Diagnostics.Process]::Start($psi)
                $out  = $proc.StandardOutput.ReadToEnd()
                $proc.WaitForExit()
                # Strip non-printable chars
                $out = $out -replace '[^ -~
]', ''
                $out = ($out.Trim() -split '
?
' | Where-Object { $_ -match '\S' }) -join "`n"
                $TxtDlgSearchResult.Text = if ($out) { $out } else { "No winget package found for '$mfr $model'." }
            } else {
                $TxtDlgSearchResult.Text = 'winget not found on this machine.'
            }
        } catch {
            $TxtDlgSearchResult.Text = "Winget error: $($_.Exception.Message)"
        }
    })

    # Browse for local file
    $BtnDlgBrowse.Add_Click({
        $mfr = $CmbDlgMfr.SelectedItem
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title  = 'Select Driver File'
        $ofd.Filter = 'Driver files (*.inf;*.exe;*.zip;*.cab)|*.inf;*.exe;*.zip;*.cab|All files|*.*'
        $ofd.InitialDirectory = $CacheDir
        if ($ofd.ShowDialog() -eq 'OK') {
            $TxtDlgBrowsePath.Text = $ofd.FileName
            # Auto-copy INF to cache
            $ext  = [System.IO.Path]::GetExtension($ofd.FileName).ToLower()
            $dest = "$CacheDir\$mfr"
            if (-not (Test-Path $dest)) { New-Item $dest -ItemType Directory -Force | Out-Null }

            if ($ext -eq '.inf') {
                $srcDir = Split-Path $ofd.FileName -Parent
                Get-ChildItem $srcDir | Where-Object { $_.FullName -ne "$dest\$($_.Name)" } | ForEach-Object { Copy-Item $_.FullName "$dest\$($_.Name)" -Force -EA SilentlyContinue }
                # Auto-detect driver name from INF
                $detectedName = Get-DriverNameFromINF $ofd.FileName
                if ($detectedName) {
                    $TxtDlgDriver.Text = $detectedName
                } elseif (-not $TxtDlgDriver.Text) {
                    $TxtDlgDriver.Text = "$mfr Universal Print Driver"
                }
                $PnlCacheStatus.Visibility = 'Visible'
                $TxtCacheStatus2.Text      = "Driver files cached: $dest$(if ($detectedName) { "`nDriver name detected: $detectedName" })"

            } elseif ($ext -eq '.zip') {
                $extractDir = "$dest\Extracted"
                if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($ofd.FileName, $extractDir)
                $inf = Get-ChildItem $extractDir -Filter '*.inf' -Recurse -EA SilentlyContinue | Select-Object -First 1
                if ($inf) {
                    Get-ChildItem $inf.DirectoryName | Where-Object { $_.FullName -ne "$dest\$($_.Name)" } | ForEach-Object { Copy-Item $_.FullName "$dest\$($_.Name)" -Force -EA SilentlyContinue }
                    $TxtDlgBrowsePath.Text = $inf.FullName
                    $detectedName2 = Get-DriverNameFromINF $inf.FullName
                    if ($detectedName2) { $TxtDlgDriver.Text = $detectedName2 }
                    elseif (-not $TxtDlgDriver.Text) { $TxtDlgDriver.Text = "$mfr Universal Print Driver" }
                    $PnlCacheStatus.Visibility = 'Visible'
                    $TxtCacheStatus2.Text = "ZIP extracted. INF cached: $($inf.Name)$(if ($detectedName2) { "`nDriver: $detectedName2" })"
                } else {
                    $PnlCacheStatus.Visibility = 'Visible'
                    $TxtCacheStatus2.Text = "ZIP extracted to $extractDir`nNo INF found -- select it manually."
                }

            } elseif ($ext -eq '.exe') {
                # EXE installers cannot be silently extracted -- run installer and detect new driver
                $PnlCacheStatus.Visibility = 'Visible'
                $TxtCacheStatus2.Text      = "Running installer -- follow any prompts to complete driver installation..."
                $dlg.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
                $result = Invoke-DriverExeInstall -ExePath $ofd.FileName -CacheDestDir $dest -Mfr $mfr
                if ($result.NewDrivers.Count -gt 0) {
                    $detectedDriver = $result.NewDrivers[0]
                    $TxtDlgDriver.Text     = $detectedDriver
                    $TxtCacheStatus2.Text  = "Driver installed: $detectedDriver`nDriver name auto-populated above."
                    if ($result.INFPath) {
                        $TxtDlgBrowsePath.Text = $result.INFPath
                        $TxtCacheStatus2.Text += "`nINF: $($result.INFPath)"
                    }
                } elseif ($result.INFPath) {
                    $TxtDlgBrowsePath.Text = $result.INFPath
                    $TxtCacheStatus2.Text  = "INF found in driver store:`n$($result.INFPath)"
                } else {
                    $TxtCacheStatus2.Text = "Installer ran (exit: $($result.ExitCode)).`nIf driver installed, get driver name from Device Manager or Printers > Add Printer > Driver list.`nThen type it in the Driver Name field above."
                }
            } else {
                Copy-Item $ofd.FileName "$dest\$([System.IO.Path]::GetFileName($ofd.FileName))" -Force
                $PnlCacheStatus.Visibility = 'Visible'
                $TxtCacheStatus2.Text = "File cached: $dest"
            }
        }
    })

    # Download from URL
    $BtnDlgDownload.Add_Click({
        $url = $TxtDlgDriverUrl.Text.Trim()
        $mfr = $CmbDlgMfr.SelectedItem
        if ([string]::IsNullOrEmpty($url)) {
            [System.Windows.MessageBox]::Show('Paste a download URL first.','Download')
            return
        }
        $fileName = $url.Split('/')[-1]
        if ([string]::IsNullOrEmpty($fileName) -or -not ($fileName -match '\.')) {
            $fileName = "driver_$(Get-Date -Format 'yyyyMMddHHmmss').exe"
        }
        $dest = "$CacheDir\$mfr"
        if (-not (Test-Path $dest)) { New-Item $dest -ItemType Directory -Force | Out-Null }
        $destFile = "$dest\$fileName"

        $TxtDlgSearchResult.Text = "Downloading $fileName..."
        $dlg.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $null

            $downloaded = $false

            # Method 1: Invoke-WebRequest (handles redirects, TLS 1.2, modern headers)
            try {
                Invoke-WebRequest -Uri $url -OutFile $destFile -UseBasicParsing `
                    -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' `
                    -TimeoutSec 120 -EA Stop
                $downloaded = $true
            } catch { }

            # Method 2: WebClient fallback
            if (-not $downloaded -or -not (Test-Path $destFile)) {
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add('User-Agent','Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
                $wc.DownloadFile($url, $destFile)
                $downloaded = (Test-Path $destFile)
            }

            if ($downloaded -and (Test-Path $destFile) -and (Get-Item $destFile).Length -gt 0) {
                $TxtDlgSearchResult.Text = "Download complete: $fileName ($([int]((Get-Item $destFile).Length/1KB)) KB) -- extracting..."
                $TxtDlgBrowsePath.Text   = $destFile
                $dlg.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)

                $dlExt = [System.IO.Path]::GetExtension($destFile).ToLower()

                if ($dlExt -eq '.zip') {
                    $extractDir = "$dest\Extracted"
                    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
                    try {
                        Add-Type -AssemblyName System.IO.Compression.FileSystem
                        [System.IO.Compression.ZipFile]::ExtractToDirectory($destFile, $extractDir)
                        $inf = Get-ChildItem $extractDir -Filter '*.inf' -Recurse -EA SilentlyContinue | Select-Object -First 1
                        if ($inf) {
                            Get-ChildItem $inf.DirectoryName | Where-Object { $_.FullName -ne "$dest\$($_.Name)" } | ForEach-Object { Copy-Item $_.FullName "$dest\$($_.Name)" -Force -EA SilentlyContinue }
                            $TxtDlgBrowsePath.Text     = $inf.FullName
                            $detectedName3 = Get-DriverNameFromINF $inf.FullName
                            if ($detectedName3) { $TxtDlgDriver.Text = $detectedName3 }
                            $PnlCacheStatus.Visibility = 'Visible'
                            $TxtCacheStatus2.Text      = "ZIP extracted. INF cached:`n$($inf.FullName)$(if ($detectedName3) { "`nDriver: $detectedName3" })"
                            $TxtDlgSearchResult.Text   = "Ready -- INF: $($inf.Name)"
                        } else {
                            $PnlCacheStatus.Visibility = 'Visible'
                            $TxtCacheStatus2.Text      = "ZIP extracted to:`n$extractDir`nNo INF found automatically -- use Browse to select it."
                            $TxtDlgSearchResult.Text   = "Extracted -- no INF found. Browse manually."
                        }
                    } catch { $TxtDlgSearchResult.Text = "ZIP extract failed: $($_.Exception.Message)" }

                } elseif ($dlExt -eq '.exe') {
                    # EXE installers cannot be silently extracted -- run and detect new driver
                    $PnlCacheStatus.Visibility = 'Visible'
                    $TxtCacheStatus2.Text      = "Running installer -- follow any prompts..."
                    $TxtDlgSearchResult.Text   = "Installing driver -- please wait..."
                    $dlg.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
                    $result = Invoke-DriverExeInstall -ExePath $destFile -CacheDestDir $dest -Mfr $mfr
                    if ($result.NewDrivers.Count -gt 0) {
                        $detectedDriver            = $result.NewDrivers[0]
                        $TxtDlgDriver.Text         = $detectedDriver
                        $TxtDlgSearchResult.Text   = "Driver installed: $detectedDriver"
                        $TxtCacheStatus2.Text      = "Driver name auto-populated.`nUse Save + Deploy Tab to install the printer."
                        if ($result.INFPath) { $TxtDlgBrowsePath.Text = $result.INFPath }
                    } elseif ($result.INFPath) {
                        $TxtDlgBrowsePath.Text   = $result.INFPath
                        $TxtDlgSearchResult.Text = "INF found: $($result.INFPath)"
                        $TxtCacheStatus2.Text    = "Driver store INF detected."
                    } else {
                        $TxtDlgSearchResult.Text = "Installer ran (exit: $($result.ExitCode)). Check Driver Name field -- type the driver name if known."
                        $TxtCacheStatus2.Text    = "If driver installed OK, get its name from Device Manager or Printers > Add > Have Disk."
                    }
                } else {
                    $PnlCacheStatus.Visibility = 'Visible'
                    $TxtCacheStatus2.Text      = "Downloaded to:`n$destFile"
                }
            } else {
                $TxtDlgSearchResult.Text = "Download failed -- file empty or not created. Try opening the URL in a browser and saving manually."
            }
        } catch {
            $TxtDlgSearchResult.Text = "Download failed: $($_.Exception.Message)`n`nTry: open the URL in a browser, save the file, then use Browse to select it."
        }
    })

    # Build printer object from dialog fields
    function Build-PrinterObject {
        $mfr    = $CmbDlgMfr.SelectedItem
        $model  = $TxtDlgModel.Text.Trim()
        $drvUrl = if ($DriverUrls.ContainsKey($mfr)) { $DriverUrls[$mfr] } else { '' }
        # Check if we have a cached INF
        $infPath = ''
        if ($TxtDlgBrowsePath.Text -match '\.inf$') { $infPath = [System.IO.Path]::GetFileName($TxtDlgBrowsePath.Text) }
        return [PSCustomObject]@{
            Name         = $TxtDlgName.Text.Trim()
            IP           = $Printer.IP
            Manufacturer = $mfr
            Model        = $model
            Driver       = if ($TxtDlgDriver.Text.Trim()) { $TxtDlgDriver.Text.Trim() } else { "$mfr Universal Print Driver" }
            DriverUrl    = $drvUrl
            DriverFile   = $infPath
            Status       = 'managed'
            AddedDate    = (Get-Date -Format 'yyyy-MM-dd')
        }
    }

    $script:DlgResult  = $null
    $script:DlgPrinter = $null

    $BtnDlgSave.Add_Click({
        if (-not $TxtDlgName.Text.Trim()) { [System.Windows.MessageBox]::Show('Enter a friendly name.','Required'); return }
        $obj = Build-PrinterObject
        if (Add-PrinterToSiteVar $obj) {
            $script:DlgResult = 'saved'
            $dlg.Close()
        }
    })

    $BtnDlgAddDeploy.Add_Click({
        if (-not $TxtDlgName.Text.Trim()) { [System.Windows.MessageBox]::Show('Enter a friendly name.','Required'); return }
        $obj = Build-PrinterObject
        Add-PrinterToSiteVar $obj | Out-Null
        $script:DlgResult  = 'deploy'
        $script:DlgPrinter = $obj
        $dlg.Close()
    })

    $BtnDlgCancel.Add_Click({ $dlg.Close() })

    $dlg.ShowDialog() | Out-Null
    return $script:DlgResult
}


$BtnDetectSubnet.Add_Click({
    $detected = Get-LocalSubnet
    $TxtSubnet.Text = $detected
    ScanLog "Auto-detected subnet: $detected"
    Set-Status "Subnet: $detected"
})

$BtnScan.Add_Click({
    if ($script:ScanRunning) { return }

    $subnet = $TxtSubnet.Text.Trim()
    $fromIP = [int]($TxtScanFrom.Text.Trim())
    $toIP   = [int]($TxtScanTo.Text.Trim())

    if ([string]::IsNullOrEmpty($subnet)) {
        [System.Windows.MessageBox]::Show('Enter a subnet first.','Scan')
        return
    }

    $spd         = [int]$SldSpeed.Value
    $speedCfg    = $script:SpeedMap[$spd]
    $tcpTimeout  = $speedCfg.TCP

    $script:ScanRunning = $true
    $script:ScanResults.Clear()
    $GridDiscover.ItemsSource = $null
    $TxtScanLog.Clear()
    $BtnScan.IsEnabled     = $false
    $BtnScanStop.IsEnabled = $true
    $PrgScan.Value         = 0

    $total     = $toIP - $fromIP + 1
    $done      = 0
    $found     = 0
    $scanItems = [System.Collections.Generic.List[PSCustomObject]]::new()

    ScanLog "=== Scan started: $subnet.$fromIP - $subnet.$toIP | Speed: $($speedCfg.Label) | TCP: ${tcpTimeout}ms ==="

    for ($i = $fromIP; $i -le $toIP; $i++) {
        # Check stop flag
        if (-not $script:ScanRunning) {
            ScanLog "Scan stopped by user at $subnet.$i"
            break
        }

        $ip   = "$subnet.$i"
        $done++
        $pct  = [int](($done / $total) * 100)

        # Update progress on UI thread -- we ARE on UI thread, direct update works
        $PrgScan.Value      = $pct
        $TxtScanStatus.Text = "Testing $ip ($done / $total)..."

        # Force UI to process pending events so progress shows
        [System.Windows.Forms.Application]::DoEvents()

        # TCP check port 9100
        $open = $false
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $task   = $client.ConnectAsync($ip, 9100)
            $task.Wait($tcpTimeout) | Out-Null
            $open   = ($task.Status.ToString() -eq 'RanToCompletion')
            try { $client.Close() } catch {}
        } catch { $open = $false }

        ScanLog "  $ip : $(if ($open) { 'PORT OPEN -- querying SNMP...' } else { 'closed' })"

        if ($open) {
            $model  = 'Unknown'
            $serial = 'Unknown'
            $pages  = 'Unknown'

            try {
                $snmp = New-Object -ComObject olePrn.OleSNMP
                $snmp.Open($ip, 'public', 1, 1500)
                try { $m = $snmp.Get('.1.3.6.1.2.1.25.3.2.1.3.1'); if ($m) { $model  = $m } } catch {}
                try { $s = $snmp.Get('.1.3.6.1.2.1.43.5.1.1.17.1'); if ($s) { $serial = $s } } catch {}
                try { $p = $snmp.Get('.1.3.6.1.2.1.43.10.2.1.4.1.1'); if ($p) { $pages  = $p } } catch {}
                if ($model -eq 'Unknown') {
                    try { $sd = $snmp.Get('.1.3.6.1.2.1.1.1.0'); if ($sd) { $model = $sd } } catch {}
                }
                $snmp.Close()
            } catch {
                ScanLog "    SNMP failed: $($_.Exception.Message)"
            }

            $mfr        = Get-Manufacturer $model
            $known      = Get-PrinterList
            $knownMatch = $known | Where-Object { $_.IP -eq $ip } | Select-Object -First 1
            $status     = if ($knownMatch) { 'Known' } else { 'NEW' }
            $drvUrl     = if ($DriverUrls.ContainsKey($mfr)) { $DriverUrls[$mfr] } else { $DriverUrls['Unknown'] }

            $row = [PSCustomObject]@{
                IP           = $ip
                Model        = $model
                Manufacturer = $mfr
                Serial       = $serial
                PageCount    = $pages
                ScanStatus   = $status
                DriverUrl    = $drvUrl
            }

            $scanItems.Add($row) | Out-Null
            $found++

            # Update grid immediately
            $GridDiscover.ItemsSource = $null
            $GridDiscover.ItemsSource = $scanItems

            $BtnAddToSiteVar.IsEnabled  = $true
            $BtnOpenDriverUrl.IsEnabled = $true
            $BtnAddToQueue.IsEnabled    = $true

            ScanLog "    >>> FOUND: $model | $mfr | Serial: $serial | Status: $status"
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    # Done
    $script:ScanRunning   = $false
    $script:ScanResults   = $scanItems
    $PrgScan.Value        = 100
    $TxtScanStatus.Text   = "Scan complete -- $found printer(s) found from $total IPs tested"
    $BtnScan.IsEnabled     = $true
    $BtnScanStop.IsEnabled = $false
    ScanLog "=== Scan complete: $found printer(s) found | $done IPs tested ==="
    Set-Status "Scan complete -- $found printer(s) found"
})

$BtnScanStop.Add_Click({
    # Signal the scan loop to stop on next iteration
    $script:ScanRunning    = $false
    $TxtScanStatus.Text    = 'Stopping...'
    ScanLog 'Stop requested'
})

$BtnOpenDriverUrl.Add_Click({
    $sel = $GridDiscover.SelectedItem
    if ($null -eq $sel) { [System.Windows.MessageBox]::Show('Select a printer first.','Driver URL'); return }
    $url = $sel.DriverUrl
    if ($url) { Start-Process $url }
})

# Context menu wiring
$GridDiscover.ContextMenu.Add_Opened({
    $sel = $GridDiscover.SelectedItem
    $enabled = $null -ne $sel
    $MnuAssign.IsEnabled     = $enabled
    $MnuGetDriver.IsEnabled  = $enabled
    $MnuAddSiteVar.IsEnabled = $enabled
    $MnuSendDeploy.IsEnabled = $enabled
})

$MnuAssign.Add_Click({
    $sel = $GridDiscover.SelectedItem
    if ($null -eq $sel) { return }
    $result = Show-AssignDialog $sel
    if ($result -eq 'saved') {
        ScanLog "Printer assigned and saved to site variable: $($sel.IP)"
        Load-DeployPrinterList
        [System.Windows.MessageBox]::Show(
            "Printer saved to site variable.`nSwitch to the Deploy tab to install it.",
            'Saved')
    } elseif ($result -eq 'deploy') {
        $p = $script:DlgPrinter
        ScanLog "Printer assigned and sent to Deploy tab: $($p.Name)"
        Load-DeployPrinterList

        # Directly populate all deploy fields -- don't rely on dropdown selection event
        $TxtPrinterName.Text = $p.Name
        $TxtDriverName.Text  = $p.Driver
        $TxtPortName.Text    = "IP_$($p.IP.Replace('.','_'))"
        $TxtInfoIP.Text      = $p.IP
        $TxtInfoModel.Text   = $p.Model
        $TxtInfoMfr.Text     = $p.Manufacturer
        $TxtInfoDriverUrl.Text = $p.DriverUrl

        # INF path -- check cache for the file
        if ($p.DriverFile) {
            $infPath = "$CacheDir\$($p.Manufacturer)\$($p.DriverFile)"
            if (Test-Path $infPath) { $TxtINFPath.Text = $infPath }
        }
        if (-not $TxtINFPath.Text) {
            # Try to find any INF in manufacturer cache folder
            $inf = Get-ChildItem "$CacheDir\$($p.Manufacturer)" -Filter '*.inf' -Recurse -EA SilentlyContinue | Select-Object -First 1
            if ($inf) { $TxtINFPath.Text = $inf.FullName }
        }

        # Also try to select in dropdown
        $target = "$($p.Name) [$($p.IP)]"
        for ($i = 0; $i -lt $CmbPrinters.Items.Count; $i++) {
            if ($CmbPrinters.Items[$i] -eq $target) {
                $CmbPrinters.SelectedIndex = $i
                break
            }
        }

        # Update driver status
        if ($TxtINFPath.Text) {
            $TxtDriverStatus.Text = "Driver cached -- ready to install: $([System.IO.Path]::GetFileName($TxtINFPath.Text))"
            $PnlDriverStatus.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(232,245,233))
        } else {
            $TxtDriverStatus.Text = "No cached driver found -- download driver first"
            $PnlDriverStatus.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(255,243,224))
        }

        [System.Windows.MessageBox]::Show(
            "Printer queued in Deploy tab.`nSwitch to Deploy tab to install.",
            'Ready to Deploy')
    }
})

$MnuGetDriver.Add_Click({
    $sel = $GridDiscover.SelectedItem
    if ($null -eq $sel) { return }
    $mfr = if ($sel.Manufacturer -ne 'Unknown') { $sel.Manufacturer } else { Get-Manufacturer $sel.Model }
    $model = $sel.Model
    $q   = [Uri]::EscapeDataString("$mfr $model Windows driver download")
    $url = if ($DriverUrls.ContainsKey($mfr)) {
        $DriverUrls[$mfr]
    } else {
        "https://www.google.com/search?q=$q"
    }
    Start-Process $url
    ScanLog "Driver search opened for: $mfr $model"
})

$MnuAddSiteVar.Add_Click({
    $sel = $GridDiscover.SelectedItem
    if ($null -eq $sel) { return }
    # If model is unknown, force assign dialog first
    if ($sel.Model -eq 'Unknown' -or $sel.Manufacturer -eq 'Unknown') {
        [System.Windows.MessageBox]::Show(
            "Manufacturer or model is unknown.`nUse 'Assign Make / Model / Driver...' to fill in details first.",
            'Details Required')
        return
    }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Friendly name for this printer:`n$($sel.IP) | $($sel.Model)",
        'Printer Name', $sel.Model)
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $drvUrl = if ($DriverUrls.ContainsKey($sel.Manufacturer)) { $DriverUrls[$sel.Manufacturer] } else { $DriverUrls['Unknown'] }
    $newP = [PSCustomObject]@{
        Name         = $name
        IP           = $sel.IP
        Manufacturer = $sel.Manufacturer
        Model        = $sel.Model
        Driver       = "$($sel.Manufacturer) Universal Print Driver"
        DriverUrl    = $drvUrl
        DriverFile   = ''
        Status       = 'managed'
        AddedDate    = (Get-Date -Format 'yyyy-MM-dd')
    }
    if (Add-PrinterToSiteVar $newP) {
        ScanLog "Added to site variable: $name ($($sel.IP))"
        Load-DeployPrinterList
        [System.Windows.MessageBox]::Show("'$name' saved.`nDriver URL: $drvUrl", 'Saved')
    }
})

$MnuSendDeploy.Add_Click({
    $sel = $GridDiscover.SelectedItem
    if ($null -eq $sel) { return }
    if ($sel.Model -eq 'Unknown' -or $sel.Manufacturer -eq 'Unknown') {
        [System.Windows.MessageBox]::Show(
            "Use 'Assign Make / Model / Driver...' first to fill in details.",
            'Details Required')
        return
    }
    # Save to site var then switch to deploy
    $drvUrl = if ($DriverUrls.ContainsKey($sel.Manufacturer)) { $DriverUrls[$sel.Manufacturer] } else { $DriverUrls['Unknown'] }
    $newP = [PSCustomObject]@{
        Name         = $sel.Model
        IP           = $sel.IP
        Manufacturer = $sel.Manufacturer
        Model        = $sel.Model
        Driver       = "$($sel.Manufacturer) Universal Print Driver"
        DriverUrl    = $drvUrl
        DriverFile   = ''
        Status       = 'managed'
        AddedDate    = (Get-Date -Format 'yyyy-MM-dd')
    }
    Add-PrinterToSiteVar $newP | Out-Null
    Load-DeployPrinterList
    $target = "$($newP.Name) [$($newP.IP)]"
    for ($i = 0; $i -lt $CmbPrinters.Items.Count; $i++) {
        if ($CmbPrinters.Items[$i] -eq $target) {
            $CmbPrinters.SelectedIndex = $i
            break
        }
    }
    ScanLog "Sent to Deploy tab: $($newP.Name)"
    [System.Windows.MessageBox]::Show("Printer queued in Deploy tab.", 'Ready')
})

$BtnAddToSiteVar.Add_Click({
    $sel = $GridDiscover.SelectedItem
    if ($null -eq $sel) { [System.Windows.MessageBox]::Show('Select a printer first.','Add to Site Variable'); return }

    $name = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Enter a friendly name for this printer:`n$($sel.IP) | $($sel.Model)",
        'Printer Name',
        $sel.Model)
    if ([string]::IsNullOrWhiteSpace($name)) { return }

    $drvUrl = if ($DriverUrls.ContainsKey($sel.Manufacturer)) { $DriverUrls[$sel.Manufacturer] } else { $DriverUrls['Unknown'] }

    $newPrinter = [PSCustomObject]@{
        Name         = $name
        IP           = $sel.IP
        Manufacturer = $sel.Manufacturer
        Model        = $sel.Model
        Driver       = "$($sel.Manufacturer) Universal Print Driver"
        DriverUrl    = $drvUrl
        DriverFile   = ''
        Status       = 'managed'
        AddedDate    = (Get-Date -Format 'yyyy-MM-dd')
    }

    if (Add-PrinterToSiteVar $newPrinter) {
        ScanLog "Added to site variable: $name ($($sel.IP))"
        Load-DeployPrinterList
        [System.Windows.MessageBox]::Show("'$name' added to site variable.`nDriver URL: $drvUrl`n`nOpen the Driver URL to download the driver, then use the Deploy tab to install.","Added Successfully")
    }
})

$BtnAddToQueue.Add_Click({
    $sel = $GridDiscover.SelectedItem
    if ($null -eq $sel) { return }
    # Switch to Deploy tab and pre-populate
    $tc = $Win.FindName('TxtPrinterName')
    if ($tc) {
        $TxtPrinterName.Text = $sel.Model
        $TxtInfoIP.Text      = $sel.IP
        $TxtInfoModel.Text   = $sel.Model
        $TxtInfoMfr.Text     = $sel.Manufacturer
        # Find the TabControl and switch to Deploy tab
        $tabControl = [System.Windows.Media.VisualTreeHelper]::GetParent($TxtPrinterName)
        # Navigate up to TabControl
        $parent = $Win.FindName('CmbPrinters')
        ScanLog "Printer queued for deploy: $($sel.Model) ($($sel.IP))"
        [System.Windows.MessageBox]::Show("Switch to the Deploy tab to install $($sel.Model).","Queued for Deploy")
    }
})

# ===========================================================================
# DEPLOY TAB EVENTS
# ===========================================================================
$CmbPrinters.Add_SelectionChanged({
    $idx = $CmbPrinters.SelectedIndex
    if ($idx -le 0) { return }   # 0 = placeholder
    $printers = Get-PrinterList
    $selected = $printers[$idx - 1]
    if ($selected) { Update-PrinterInfoPanel $selected }
})

$TxtInfoDriverUrl.Add_MouseLeftButtonUp({
    $url = $TxtInfoDriverUrl.Text
    if ($url -and $url -ne '-') { Start-Process $url }
})

$BtnBrowseINF.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'INF Files (*.inf)|*.inf|All Files|*.*'
    $ofd.Title  = 'Select Driver INF File'
    $ofd.InitialDirectory = $CacheDir
    if ($ofd.ShowDialog() -eq 'OK') {
        $TxtINFPath.Text = $ofd.FileName
        # Auto-populate driver name from INF
        $detected = Get-DriverNameFromINF $ofd.FileName
        if ($detected) {
            $TxtDriverName.Text = $detected
            InstallLog "Driver name auto-detected from INF: $detected"
        }
    }
})

$BtnBrowseDriver.Add_Click({
    if (Test-Path $CacheDir) { Start-Process explorer.exe $CacheDir }
    else { [System.Windows.MessageBox]::Show("Cache folder not yet created.`nIt will be created when you add a driver.",'Cache') }
})

$BtnOpenCache.Add_Click({
    if (-not (Test-Path $CacheDir)) { New-Item $CacheDir -ItemType Directory -Force | Out-Null }
    Start-Process explorer.exe $CacheDir
})

$BtnGetDriver.Add_Click({
    $url = $TxtInfoDriverUrl.Text
    if (-not $url -or $url -eq '-') {
        $mfr = if ($script:SelectedPrint) { $script:SelectedPrint.Manufacturer } else { 'Unknown' }
        $url = if ($DriverUrls.ContainsKey($mfr)) { $DriverUrls[$mfr] } else { $DriverUrls['Unknown'] }
    }
    if ($url) { Start-Process $url }
})

$BtnRefreshPort.Add_Click({
    $ip = $TxtInfoIP.Text.Trim()
    if ($ip -and $ip -ne "-") {
        $TxtPortName.Text = "IP_$($ip.Replace('.','_'))"
    }
})

$BtnInstall.Add_Click({
    $name   = $TxtPrinterName.Text.Trim()
    $driver = $TxtDriverName.Text.Trim()
    $inf    = $TxtINFPath.Text.Trim()
    $ip     = $TxtInfoIP.Text.Trim()

    if ([string]::IsNullOrEmpty($name) -or [string]::IsNullOrEmpty($ip) -or $ip -eq '-') {
        [System.Windows.MessageBox]::Show('Select a printer and ensure Name and IP are filled.','Install')
        return
    }
    if ([string]::IsNullOrEmpty($driver)) {
        [System.Windows.MessageBox]::Show('Enter the driver name as it appears in Windows.','Driver Required')
        return
    }

    $BtnInstall.IsEnabled = $false
    $TxtInstallLog.Clear()
    $logger = { param($m) InstallLog $m }

    $port    = $TxtPortName.Text.Trim()
    if ([string]::IsNullOrEmpty($port)) { $port = "IP_$($ip.Replace('.','_'))" }
    $success = Install-NetworkPrinter -PrinterName $name -IP $ip `
                   -DriverName $driver -INFPath $inf -PortName $port -Logger $logger

    $BtnInstall.IsEnabled = $true
    if ($success) {
        Set-Status "Installed: $name"
        Load-InstalledPrinters
        # Update status badge
        Update-PrinterInfoPanel $script:SelectedPrint
    }
})

# ===========================================================================
# INSTALLED TAB EVENTS
# ===========================================================================
$BtnRefreshInstalled.Add_Click({ Load-InstalledPrinters })

$BtnSetDefault.Add_Click({
    $sel = $GridInstalled.SelectedItem
    if ($null -eq $sel) { [System.Windows.MessageBox]::Show('Select a printer first.','Set Default'); return }
    try {
        $wmi = Get-WmiObject -Query "SELECT * FROM Win32_Printer WHERE Name='$($sel.Name)'" -EA Stop
        $wmi.SetDefaultPrinter() | Out-Null
        Set-Status "Default printer set: $($sel.Name)"
        Load-InstalledPrinters
    } catch {
        [System.Windows.MessageBox]::Show("Failed to set default: $($_.Exception.Message)",'Error')
    }
})

$BtnRemovePrinter.Add_Click({
    $sel = $GridInstalled.SelectedItem
    if ($null -eq $sel) { [System.Windows.MessageBox]::Show('Select a printer first.','Remove'); return }
    $r = [System.Windows.MessageBox]::Show(
        "Remove printer '$($sel.Name)'?`nThis removes the printer but not the driver.",
        'Confirm Remove',
        [System.Windows.MessageBoxButton]::YesNo)
    if ($r -eq 'Yes') {
        $logger = { param($m) InstallLog $m }
        Remove-NetworkPrinter -PrinterName $sel.Name -Logger $logger
        Load-InstalledPrinters
    }
})

$BtnClose.Add_Click({ $Win.Close() })

# ===========================================================================
# STARTUP
# ===========================================================================

# Update header first so window looks right immediately
$TxtHeader.Text = "Site: $SiteName | Mode: $MachineMode"
$TxtMode.Text   = $MachineMode.ToUpper()
if ($MachineMode -eq 'home') {
    $BadgeDomain.Background = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(78,52,46))
    $TxtDomain.Text         = 'HOME'
    $TxtDomain.Foreground   = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(255,204,188))
}

# Load site variable
$script:SiteVar = Get-SiteVar
$sv             = $script:SiteVar

# Subnet -- gateway-aware detection, ignores VPN/virtual adapters
$freshSubnet    = Get-LocalSubnet
$TxtSubnet.Text = $freshSubnet
ScanLog "Paladin Printer Manager v1.0.0"
ScanLog "Site: $SiteName | Mode: $MachineMode"
ScanLog "Subnet auto-detected: $freshSubnet"
ScanLog "Driver cache: $CacheDir"
ScanLog "Log: $LogFile"

# -- PRE-FLIGHT: Install dependencies before anything else ------------------
ScanLog "--- Pre-flight: checking dependencies ---"

# Force TLS 1.2 globally -- required for all downloads
[Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
[Net.ServicePointManager]::ServerCertificateValidationCallback = $null

# 1. Winget
$script:WingetPath = Get-WingetExe
if ($script:WingetPath) {
    ScanLog "winget: OK ($($script:WingetPath))"
} else {
    ScanLog "winget: not found -- attempting bootstrap..."
    try {
        # Try AppX registration first (works on Win10/11 with App Installer present)
        $appx = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -EA SilentlyContinue
        if ($appx) {
            Add-AppxPackage -RegisterByFamilyName -MainPackage $appx.PackageFamilyName -EA SilentlyContinue
            Start-Sleep -Seconds 3
            $script:WingetPath = Get-WingetExe
        }
    } catch {}

    if (-not $script:WingetPath) {
        # Direct download of latest winget MSIX bundle
        try {
            ScanLog "winget: downloading installer..."
            $wingetUrl  = 'https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
            $wingetDest = "$TempDir\winget.msixbundle"
            if (-not (Test-Path $TempDir)) { New-Item $TempDir -ItemType Directory -Force | Out-Null }
            Invoke-WebRequest -Uri $wingetUrl -OutFile $wingetDest -UseBasicParsing -EA Stop
            Add-AppxPackage -Path $wingetDest -EA Stop
            Start-Sleep -Seconds 5
            $script:WingetPath = Get-WingetExe
            if ($script:WingetPath) { ScanLog "winget: installed OK" }
        } catch { ScanLog "winget: install failed -- $($_.Exception.Message)" }
    }

    if ($script:WingetPath) { ScanLog "winget: OK ($($script:WingetPath))" }
    else                    { ScanLog "winget: UNAVAILABLE -- direct download fallbacks will be used" }
}

# 2. Chocolatey
$script:ChocoPath = Get-ChocoExe
if ($script:ChocoPath) {
    ScanLog "Chocolatey: OK ($($script:ChocoPath))"
} else {
    ScanLog "Chocolatey: not found -- installing..."
    try {
        $env:chocolateyUseWindowsCompression = 'true'
        $chocoScript = (Invoke-WebRequest -Uri 'https://chocolatey.org/install.ps1' -UseBasicParsing -EA Stop).Content
        Invoke-Expression $chocoScript
        $script:ChocoPath = Get-ChocoExe
        if ($script:ChocoPath) { ScanLog "Chocolatey: installed OK ($($script:ChocoPath))" }
        else                   { ScanLog "Chocolatey: install failed -- choco unavailable" }
    } catch { ScanLog "Chocolatey: install failed -- $($_.Exception.Message)" }
}

# 3. NuGet provider (needed for some PS module installs)
try {
    $np = Get-PackageProvider -Name NuGet -EA SilentlyContinue
    if (-not $np -or $np.Version -lt '2.8.5.201') {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -EA SilentlyContinue | Out-Null
        ScanLog "NuGet provider: installed"
    } else {
        ScanLog "NuGet provider: OK"
    }
} catch { ScanLog "NuGet provider: skipped ($($_.Exception.Message))" }

ScanLog "--- Pre-flight complete ---"

# -- Printer lists ----------------------------------------------------------
Load-DeployPrinterList
Load-InstalledPrinters

ScanLog "Known printers in site variable: $(@(Get-PrinterList).Count)"
ScanLog "Ready -- right-click a scan result to assign, or click Start Scan."
Set-Status "Ready | Site: $SiteName | Subnet: $freshSubnet"
Write-Log "GUI started | Site: $SiteName | Mode: $MachineMode | Subnet: $freshSubnet"

$Win.ShowDialog() | Out-Null
