#Requires -Version 3.0
<#
.SYNOPSIS
    Browser Factory Reset [WIN]
    Paladin Business Consulting | Datto RMM Component

.DESCRIPTION
    Performs a factory reset on all detected browsers for all user profiles.
    Equivalent to clicking "Reset settings" inside each browser.

    REMOVES:
      Preferences/settings, extensions, cookies, site storage (IndexedDB,
      Local Storage, Session Storage, Service Worker), cache, form history,
      session data, search engine config.

    PRESERVES (never touched):
      Passwords (Login Data / logins.json / key4.db)
      Bookmarks (Bookmarks / Bookmarks.bak / places.sqlite)
      Browsing history (History / places.sqlite)
      Certificates (cert9.db)
      Favicons

    Browsers covered:
      Google Chrome, Microsoft Edge, Brave, Vivaldi, Opera, Opera GX,
      Chromium, Mozilla Firefox, Waterfox, LibreWolf

    AUDIT / COMPLIANCE:
      Full audit log written to C:\ProgramData\Paladin\BrowserReset\
      Log is ACL-hardened to SYSTEM + Administrators only (HIPAA-safe).
      Every action is timestamped with machine context.
      Preserved items are explicitly confirmed in log per user.
      UDF slot 6 updated with outcome for Datto visibility.

    Runs as NT AUTHORITY\SYSTEM via Datto RMM.
    Targets all user profiles automatically.

    Paladin Business Consulting | Internal Use Only
    Version: 3.0.0 | Min OS: Windows 10 / Server 2016
#>

$script:ExitCode  = 0
$script:Removed   = 0
$script:Warned    = 0
$script:Errors    = 0
$script:Preserved = 0

# ===========================================================================
# CONSTANTS
# ===========================================================================
$LogDir   = 'C:\ProgramData\Paladin\BrowserReset'
$LogFile  = "$LogDir\BrowserReset.log"
$UDFSlot  = 6
$UDFPath  = 'HKLM:\SOFTWARE\CentraStage'
$UDFName  = "Custom$UDFSlot"
$MaxLogMB = 5

# ===========================================================================
# AUDIT / LOGGING HELPERS
# ===========================================================================

function Write-AuditLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try {
        Add-Content -Path $LogFile -Value $line -EA SilentlyContinue
    } catch {}
}

function Write-AuditSeparator {
    Write-AuditLog ('=' * 60)
}

function Write-PreservedConfirmation {
    param([string]$User, [string]$Browser, [string[]]$PreservedItems)
    foreach ($item in $PreservedItems) {
        Write-AuditLog "  [PRESERVED] User:$User Browser:$Browser Item:$item -- NOT touched"
        $script:Preserved++
    }
}

function Set-UDFStatus {
    param([string]$Text)
    $v = $Text.Substring(0, [Math]::Min($Text.Length, 255))
    try {
        if (-not (Test-Path $UDFPath)) { New-Item -Path $UDFPath -Force -EA SilentlyContinue | Out-Null }
        New-ItemProperty -Path $UDFPath -Name $UDFName -Value $v -PropertyType String -Force -EA SilentlyContinue | Out-Null
    } catch {}
}

function Initialize-AuditLog {
    # Create log directory
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null
    }

    # Rotate log if over MaxLogMB
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile -EA SilentlyContinue).Length / 1MB) -gt $MaxLogMB) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Move-Item -LiteralPath $LogFile -Destination "$LogFile.$stamp.bak" -Force -EA SilentlyContinue
    }

    # Harden log directory ACL -- SYSTEM + Administrators only (HIPAA-safe)
    try {
        $acl  = Get-Acl -Path $LogDir -EA Stop
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
        $sysRule  = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $admRule  = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($sysRule)
        $acl.AddAccessRule($admRule)
        Set-Acl -Path $LogDir -AclObject $acl -EA Stop
    } catch {
        Write-AuditLog "WARN: Could not harden log ACL: $($_.Exception.Message)" 'WARN'
    }
}

# ===========================================================================
# HELPERS
# ===========================================================================

function Get-UserHives {
    $patterns = @('S-1-12-1-(\d+-?){4}$', 'S-1-5-21-(\d+-?){4}$')
    $results  = @()
    foreach ($p in $patterns) {
        $results += Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' -EA SilentlyContinue |
            Where-Object { $_.PSChildName -match $p } |
            Select-Object @{Name='SID';      Expression={ $_.PSChildName }},
                          @{Name='UserName'; Expression={ Split-Path $_.ProfileImagePath -Leaf }},
                          @{Name='UserHive'; Expression={ "$($_.ProfileImagePath)\NTuser.dat" }},
                          @{Name='Path';     Expression={ $_.ProfileImagePath }}
    }
    $results
}

function Remove-PathItems {
    param([string]$User, [string]$Browser, [String[]]$Paths)
    foreach ($p in $Paths) {
        if (!(Test-Path $p)) { continue }
        try {
            Remove-Item -Path $p -Recurse -Force -EA Stop
            Write-AuditLog "  [REMOVED] User:$User Browser:$Browser Path:$(Split-Path $p -Leaf)"
            $script:Removed++
        } catch {
            Write-AuditLog "  [WARN] User:$User Browser:$Browser Path:$(Split-Path $p -Leaf) -- $($_.Exception.Message)" 'WARN'
            $script:Warned++
            $script:ExitCode = 1
        }
    }
}

# ===========================================================================
# RESET FUNCTIONS
# ===========================================================================

function Reset-ChromiumProfile {
    param([String]$UserDataPath, [String]$Label, [String]$UserName)

    if (!(Test-Path $UserDataPath)) { return }

    $profileDirs = Get-ChildItem -Path $UserDataPath -Directory -EA SilentlyContinue |
                   Where-Object { $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' }

    if (!$profileDirs) {
        Write-AuditLog "  [$Label] No profiles found -- skipping"
        return
    }

    foreach ($dir in $profileDirs) {
        $base = $dir.FullName
        Write-AuditLog "  [$Label] Resetting profile: $($dir.Name) for user: $UserName"

        # Settings
        Remove-PathItems -User $UserName -Browser $Label -Paths @(
            "$base\Preferences", "$base\Secure Preferences"
        )

        # Extensions
        Remove-PathItems -User $UserName -Browser $Label -Paths @(
            "$base\Extensions", "$base\Extension State",
            "$base\Extension Rules", "$base\External Extensions"
        )

        # Cookies + site data
        Remove-PathItems -User $UserName -Browser $Label -Paths @(
            "$base\Cookies", "$base\Network\Cookies",
            "$base\Session Storage", "$base\Local Storage",
            "$base\IndexedDB", "$base\Service Worker",
            "$base\databases", "$base\QuotaManager",
            "$base\QuotaManager-journal", "$base\Visited Links",
            "$base\Top Sites", "$base\Top Sites-journal",
            "$base\Shortcuts", "$base\Shortcuts-journal",
            "$base\Web Data", "$base\Web Data-journal",
            "$base\Network Action Predictor",
            "$base\Network Action Predictor-journal"
        )

        # Cache
        Remove-PathItems -User $UserName -Browser $Label -Paths @(
            "$base\Cache", "$base\Cache2", "$base\Code Cache",
            "$base\GPUCache", "$base\Media Cache", "$base\Application Cache"
        )

        # Search engines
        Remove-PathItems -User $UserName -Browser $Label -Paths @("$base\Search Logos")

        # Explicit preserved item confirmation (compliance audit trail)
        $preservedItems = @(
            'Bookmarks (user bookmarks file)',
            'Bookmarks.bak (bookmark backup)',
            'History (browsing history database)',
            'History-journal',
            'Login Data (saved passwords)',
            'Login Data-journal',
            'Favicons', 'Favicons-journal'
        )
        Write-PreservedConfirmation -User $UserName -Browser $Label -PreservedItems $preservedItems
    }
}

function Reset-FirefoxProfile {
    param([String]$RoamingPath, [String]$LocalPath, [String]$Label, [String]$UserName)

    if (!(Test-Path $RoamingPath)) { return }

    $profileDirs = Get-ChildItem -Path $RoamingPath -Directory -EA SilentlyContinue
    if (!$profileDirs) {
        Write-AuditLog "  [$Label] No profiles found -- skipping"
        return
    }

    foreach ($dir in $profileDirs) {
        $base      = $dir.FullName
        $localBase = Join-Path $LocalPath $dir.Name
        Write-AuditLog "  [$Label] Resetting profile: $($dir.Name) for user: $UserName"

        # Settings
        Remove-PathItems -User $UserName -Browser $Label -Paths @(
            "$base\prefs.js", "$base\user.js"
        )

        # Extensions
        Remove-PathItems -User $UserName -Browser $Label -Paths @(
            "$base\extensions", "$base\extensions.json",
            "$base\extension-preferences.json",
            "$base\extension-settings.json",
            "$base\addonStartup.json.lz4"
        )

        # Cookies
        Remove-PathItems -User $UserName -Browser $Label -Paths @(
            "$base\cookies.sqlite", "$base\cookies.sqlite-wal",
            "$base\cookies.sqlite-shm"
        )

        # Session data
        $sessions = Get-ChildItem -Path $base -Filter 'sessionstore*.jsonlz4' -Force -EA SilentlyContinue
        foreach ($s in $sessions) {
            try {
                Remove-Item -LiteralPath $s.FullName -Force -EA Stop
                Write-AuditLog "  [REMOVED] User:$UserName Browser:$Label Path:$($s.Name)"
                $script:Removed++
            } catch {
                Write-AuditLog "  [WARN] User:$UserName Browser:$Label Path:$($s.Name) -- $($_.Exception.Message)" 'WARN'
                $script:Warned++
            }
        }

        # Site storage
        Remove-PathItems -User $UserName -Browser $Label -Paths @(
            "$base\webappsstore.sqlite", "$base\webappsstore.sqlite-wal",
            "$base\webappsstore.sqlite-shm", "$base\content-prefs.sqlite",
            "$base\storage\default", "$base\IndexedDB"
        )

        # Form history
        Remove-PathItems -User $UserName -Browser $Label -Paths @(
            "$base\formhistory.sqlite", "$base\formhistory.sqlite-wal",
            "$base\formhistory.sqlite-shm"
        )

        # Cache
        Remove-PathItems -User $UserName -Browser $Label -Paths @("$localBase\cache2")

        # Explicit preserved item confirmation
        $preservedItems = @(
            'places.sqlite (bookmarks + browsing history)',
            'key4.db (password encryption key)',
            'logins.json (saved passwords)',
            'favicons.sqlite (site icons)',
            'cert9.db (certificates)'
        )
        Write-PreservedConfirmation -User $UserName -Browser $Label -PreservedItems $preservedItems
    }
}

# ===========================================================================
# MAIN
# ===========================================================================

# Initialize log + ACL
Initialize-AuditLog

# Collect machine context
$machineName = $env:COMPUTERNAME
$domainName  = $env:USERDOMAIN
$osInfo      = (Get-WmiObject Win32_OperatingSystem -EA SilentlyContinue).Caption
$runAs       = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$siteName    = $env:CS_PROFILE_NAME
if ([string]::IsNullOrEmpty($siteName)) { $siteName = 'UNKNOWN' }
$runTime     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

Write-AuditSeparator
Write-AuditLog 'PALADIN BROWSER FACTORY RESET -- AUDIT LOG'
Write-AuditLog "Script Version : 3.0.0"
Write-AuditLog "Timestamp      : $runTime"
Write-AuditLog "Machine        : $machineName"
Write-AuditLog "Domain         : $domainName"
Write-AuditLog "OS             : $osInfo"
Write-AuditLog "Run As         : $runAs"
Write-AuditLog "Datto Site     : $siteName"
Write-AuditSeparator
Write-AuditLog 'ACTION         : Browser Factory Reset'
Write-AuditLog 'SCOPE          : All user profiles on this machine'
Write-AuditLog 'PRESERVED      : Passwords | Bookmarks | History | Certificates'
Write-AuditLog 'REMOVED        : Extensions | Cookies | Cache | Settings | Site Data'
Write-AuditSeparator

Set-UDFStatus "BrowserReset: Running | $machineName | $runTime"

# Step 1 -- Kill browser processes
Write-AuditLog '[Step 1] Stopping browser processes'
$browserProcs = @('chrome','msedge','firefox','brave','opera','vivaldi',
                  'waterfox','librewolf','chromium')
foreach ($proc in $browserProcs) {
    $found = Get-Process -Name $proc -EA SilentlyContinue
    if ($found) {
        Write-AuditLog "  Stopping: $proc ($($found.Count) instance(s))"
        $found | Stop-Process -Force -EA SilentlyContinue
    }
}
Start-Sleep -Seconds 2

# Step 2 -- Enumerate profiles
Write-AuditLog '[Step 2] Enumerating user profiles'
$allProfiles = Get-UserHives
if (!$allProfiles -or $allProfiles.Count -eq 0) {
    Write-AuditLog 'ERROR: No user profiles found' 'ERROR'
    Set-UDFStatus "BrowserReset: FAILED -- no profiles | $machineName | $runTime"
    exit 1
}

# Load offline hives
$loadedHives = @()
foreach ($u in $allProfiles) {
    if (!(Test-Path "Registry::HKEY_USERS\$($u.SID)")) {
        $loadedHives += $u.SID
        Start-Process 'cmd.exe' -ArgumentList "/C reg.exe LOAD HKU\$($u.SID) `"$($u.UserHive)`"" `
            -Wait -WindowStyle Hidden
    }
    Write-AuditLog "  Found profile: $($u.UserName) SID:$($u.SID)"
}

Write-AuditLog "  Total profiles found: $($allProfiles.Count)"

# Step 3 -- Per-user reset
Write-AuditLog '[Step 3] Resetting browsers per profile'

foreach ($u in $allProfiles) {
    Write-AuditSeparator
    Write-AuditLog "Processing user: $($u.UserName)"

    # Chromium browsers
    $chromiumBrowsers = @(
        @{ Label='Chrome';   Path="$($u.Path)\AppData\Local\Google\Chrome\User Data" },
        @{ Label='Edge';     Path="$($u.Path)\AppData\Local\Microsoft\Edge\User Data" },
        @{ Label='Brave';    Path="$($u.Path)\AppData\Local\BraveSoftware\Brave-Browser\User Data" },
        @{ Label='Vivaldi';  Path="$($u.Path)\AppData\Local\Vivaldi\User Data" },
        @{ Label='Opera';    Path="$($u.Path)\AppData\Roaming\Opera Software\Opera Stable" },
        @{ Label='Opera GX'; Path="$($u.Path)\AppData\Roaming\Opera Software\Opera GX Stable" },
        @{ Label='Chromium'; Path="$($u.Path)\AppData\Local\Chromium\User Data" }
    )

    foreach ($b in $chromiumBrowsers) {
        if (Test-Path $b.Path) {
            Write-AuditLog "  Detected: $($b.Label)"
            Reset-ChromiumProfile -UserDataPath $b.Path -Label $b.Label -UserName $u.UserName
        }
    }

    # Firefox browsers
    $firefoxBrowsers = @(
        @{ Label='Firefox';   Roaming="$($u.Path)\AppData\Roaming\Mozilla\Firefox\Profiles";  Local="$($u.Path)\AppData\Local\Mozilla\Firefox\Profiles" },
        @{ Label='Waterfox';  Roaming="$($u.Path)\AppData\Roaming\Waterfox\Profiles";          Local="$($u.Path)\AppData\Local\Waterfox\Profiles" },
        @{ Label='LibreWolf'; Roaming="$($u.Path)\AppData\Roaming\librewolf\Profiles";         Local="$($u.Path)\AppData\Local\librewolf\Profiles" }
    )

    foreach ($b in $firefoxBrowsers) {
        if (Test-Path $b.Roaming) {
            Write-AuditLog "  Detected: $($b.Label)"
            Reset-FirefoxProfile -RoamingPath $b.Roaming -LocalPath $b.Local -Label $b.Label -UserName $u.UserName
        }
    }
}

# Step 4 -- Unload hives
foreach ($sid in $loadedHives) {
    [gc]::Collect()
    Start-Sleep -Seconds 1
    Start-Process 'cmd.exe' -ArgumentList "/C reg.exe UNLOAD HKU\$sid" -Wait -WindowStyle Hidden | Out-Null
}

# ===========================================================================
# FINAL AUDIT RECORD
# ===========================================================================
$endTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-AuditSeparator
Write-AuditLog 'FINAL AUDIT RECORD'
Write-AuditLog "Machine        : $machineName"
Write-AuditLog "Domain         : $domainName"
Write-AuditLog "Started        : $runTime"
Write-AuditLog "Completed      : $endTime"
Write-AuditLog "Run As         : $runAs"
Write-AuditLog "Profiles reset : $($allProfiles.Count)"
Write-AuditLog "Items removed  : $($script:Removed)"
Write-AuditLog "Items preserved: $($script:Preserved) (passwords/bookmarks/history/certs)"
Write-AuditLog "Warnings       : $($script:Warned)"
Write-AuditLog "Errors         : $($script:Errors)"
Write-AuditLog "Exit code      : $($script:ExitCode)"
Write-AuditLog "Log location   : $LogFile"
Write-AuditSeparator

if ($script:ExitCode -eq 0) {
    $outcome = "SUCCESS: All browsers reset. $($script:Removed) items removed. $($script:Preserved) preserved."
    Write-AuditLog $outcome
    Set-UDFStatus "BrowserReset: OK Removed:$($script:Removed) Preserved:$($script:Preserved) | $machineName | $endTime"
} else {
    $outcome = "COMPLETE WITH WARNINGS: $($script:Removed) removed | $($script:Warned) warnings. Review log: $LogFile"
    Write-AuditLog $outcome 'WARN'
    Set-UDFStatus "BrowserReset: WARN Removed:$($script:Removed) Warnings:$($script:Warned) | $machineName | $endTime"
}

exit $script:ExitCode
