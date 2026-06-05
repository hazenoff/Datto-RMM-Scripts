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
      Bookmarks
      Browsing history

    Browsers covered:
      Google Chrome, Microsoft Edge, Brave, Vivaldi, Opera, Opera GX,
      Chromium, Mozilla Firefox, Waterfox, LibreWolf

    Runs as NT AUTHORITY\SYSTEM via Datto RMM.
    Targets all user profiles automatically.

    Paladin Business Consulting | Internal Use Only
    Version: 2.0.0 | Min OS: Windows 10 / Server 2016
#>

$script:ExitCode = 0

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
    param([String[]]$Paths)
    foreach ($p in $Paths) {
        if (!(Test-Path $p)) { continue }
        try {
            Remove-Item -Path $p -Recurse -Force -EA Stop
            Write-Host "    Removed: $p"
        } catch {
            Write-Host "    [Warn] Could not remove '$p': $($_.Exception.Message)"
            $script:ExitCode = 1
        }
    }
}

# ---------------------------------------------------------------------------
# Reset-ChromiumProfile
# Covers Chrome, Edge, Brave, Vivaldi, Opera, Chromium (all Chromium-engine)
# Preserves: Bookmarks, History, Login Data (passwords), Favicons
# ---------------------------------------------------------------------------
function Reset-ChromiumProfile {
    param([String]$UserDataPath, [String]$Label)

    if (!(Test-Path $UserDataPath)) { return }

    $profileDirs = Get-ChildItem -Path $UserDataPath -Directory -EA SilentlyContinue |
                   Where-Object { $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$' }

    if (!$profileDirs) {
        Write-Host "  [$Label] No profiles found -- skipping."
        return
    }

    foreach ($dir in $profileDirs) {
        $base = $dir.FullName
        Write-Host "  [$Label] Resetting profile: $($dir.Name)"

        # Settings (browser recreates clean defaults on next launch)
        Remove-PathItems -Paths @(
            "$base\Preferences"
            "$base\Secure Preferences"
        )

        # Extensions
        Remove-PathItems -Paths @(
            "$base\Extensions"
            "$base\Extension State"
            "$base\Extension Rules"
            "$base\External Extensions"
        )

        # Cookies + site data
        Remove-PathItems -Paths @(
            "$base\Cookies"
            "$base\Network\Cookies"
            "$base\Session Storage"
            "$base\Local Storage"
            "$base\IndexedDB"
            "$base\Service Worker"
            "$base\databases"
            "$base\QuotaManager"
            "$base\QuotaManager-journal"
            "$base\Visited Links"
            "$base\Top Sites"
            "$base\Top Sites-journal"
            "$base\Shortcuts"
            "$base\Shortcuts-journal"
            "$base\Web Data"
            "$base\Web Data-journal"
            "$base\Network Action Predictor"
            "$base\Network Action Predictor-journal"
        )

        # Cache
        Remove-PathItems -Paths @(
            "$base\Cache"
            "$base\Cache2"
            "$base\Code Cache"
            "$base\GPUCache"
            "$base\Media Cache"
            "$base\Application Cache"
        )

        # Search engines (reset to browser default)
        Remove-PathItems -Paths @(
            "$base\Search Logos"
        )

        # PRESERVED (not touched):
        #   Bookmarks      -- user bookmarks
        #   Bookmarks.bak  -- backup
        #   History        -- browsing history
        #   History-journal
        #   Login Data     -- saved passwords
        #   Login Data-journal
        #   Favicons
        #   Favicons-journal
    }
}

# ---------------------------------------------------------------------------
# Reset-FirefoxProfile
# Covers Firefox, Waterfox, LibreWolf
# Preserves: places.sqlite (bookmarks+history), key4.db, logins.json (passwords)
# ---------------------------------------------------------------------------
function Reset-FirefoxProfile {
    param([String]$RoamingPath, [String]$LocalPath, [String]$Label)

    if (!(Test-Path $RoamingPath)) { return }

    $profileDirs = Get-ChildItem -Path $RoamingPath -Directory -EA SilentlyContinue
    if (!$profileDirs) {
        Write-Host "  [$Label] No profiles found -- skipping."
        return
    }

    foreach ($dir in $profileDirs) {
        $base      = $dir.FullName
        $localBase = Join-Path $LocalPath $dir.Name
        Write-Host "  [$Label] Resetting profile: $($dir.Name)"

        # Settings (Firefox recreates defaults on next launch)
        Remove-PathItems -Paths @(
            "$base\prefs.js"
            "$base\user.js"
        )

        # Extensions
        Remove-PathItems -Paths @(
            "$base\extensions"
            "$base\extensions.json"
            "$base\extension-preferences.json"
            "$base\extension-settings.json"
            "$base\addonStartup.json.lz4"
        )

        # Cookies
        Remove-PathItems -Paths @(
            "$base\cookies.sqlite"
            "$base\cookies.sqlite-wal"
            "$base\cookies.sqlite-shm"
        )

        # Session data
        Get-ChildItem -Path $base -Filter 'sessionstore*.jsonlz4' -Force -EA SilentlyContinue |
            Remove-Item -Force -EA SilentlyContinue

        # Site storage
        Remove-PathItems -Paths @(
            "$base\webappsstore.sqlite"
            "$base\webappsstore.sqlite-wal"
            "$base\webappsstore.sqlite-shm"
            "$base\content-prefs.sqlite"
            "$base\storage\default"
            "$base\IndexedDB"
        )

        # Form history
        Remove-PathItems -Paths @(
            "$base\formhistory.sqlite"
            "$base\formhistory.sqlite-wal"
            "$base\formhistory.sqlite-shm"
        )

        # Cache (local path)
        Remove-PathItems -Paths @("$localBase\cache2")

        # PRESERVED (not touched):
        #   places.sqlite   -- bookmarks + history
        #   key4.db         -- password encryption key
        #   logins.json     -- saved passwords
        #   favicons.sqlite -- site icons
        #   cert9.db        -- certificates
    }
}

# ===========================================================================
# MAIN
# ===========================================================================

Write-Host '======================================================='
Write-Host ' Paladin Browser Factory Reset v2.0.0'
Write-Host ' Preserving: Passwords | Bookmarks | History'
Write-Host '======================================================='

# ---- Kill all browser processes up front ----------------------------------
$browserProcs = @('chrome','msedge','firefox','brave','opera','vivaldi',
                  'waterfox','librewolf','chromium')
Write-Host "`n[Step 1] Stopping browser processes..."
foreach ($proc in $browserProcs) {
    $found = Get-Process -Name $proc -EA SilentlyContinue
    if ($found) {
        Write-Host "  Stopping: $proc ($($found.Count) instance(s))"
        $found | Stop-Process -Force -EA SilentlyContinue
    }
}
Start-Sleep -Seconds 2

# ---- Enumerate all user profiles ------------------------------------------
Write-Host "`n[Step 2] Enumerating user profiles..."
$allProfiles = Get-UserHives
if (!$allProfiles -or $allProfiles.Count -eq 0) {
    Write-Host '[Error] No user profiles found.'
    exit 1
}

# Load offline hives so we can enumerate paths (not strictly required for file
# ops, but ensures consistency with the Paladin pattern)
$loadedHives = @()
foreach ($u in $allProfiles) {
    if (!(Test-Path "Registry::HKEY_USERS\$($u.SID)")) {
        $loadedHives += $u.SID
        Start-Process 'cmd.exe' -ArgumentList "/C reg.exe LOAD HKU\$($u.SID) `"$($u.UserHive)`"" `
            -Wait -WindowStyle Hidden
    }
    Write-Host "  Profile: $($u.UserName)  ($($u.Path))"
}

# ---- Per-user reset --------------------------------------------------------
Write-Host "`n[Step 3] Resetting browsers for each profile..."

foreach ($u in $allProfiles) {
    Write-Host "`n--- User: $($u.UserName) ---"

    # Chromium-engine browsers
    $chromiumBrowsers = @(
        @{ Label='Chrome';    Path="$($u.Path)\AppData\Local\Google\Chrome\User Data" },
        @{ Label='Edge';      Path="$($u.Path)\AppData\Local\Microsoft\Edge\User Data" },
        @{ Label='Brave';     Path="$($u.Path)\AppData\Local\BraveSoftware\Brave-Browser\User Data" },
        @{ Label='Vivaldi';   Path="$($u.Path)\AppData\Local\Vivaldi\User Data" },
        @{ Label='Opera';     Path="$($u.Path)\AppData\Roaming\Opera Software\Opera Stable" },
        @{ Label='Opera GX';  Path="$($u.Path)\AppData\Roaming\Opera Software\Opera GX Stable" },
        @{ Label='Chromium';  Path="$($u.Path)\AppData\Local\Chromium\User Data" }
    )

    foreach ($b in $chromiumBrowsers) {
        if (Test-Path $b.Path) {
            Reset-ChromiumProfile -UserDataPath $b.Path -Label $b.Label
        }
    }

    # Firefox-engine browsers
    $firefoxBrowsers = @(
        @{ Label='Firefox';   Roaming="$($u.Path)\AppData\Roaming\Mozilla\Firefox\Profiles";   Local="$($u.Path)\AppData\Local\Mozilla\Firefox\Profiles" },
        @{ Label='Waterfox';  Roaming="$($u.Path)\AppData\Roaming\Waterfox\Profiles";           Local="$($u.Path)\AppData\Local\Waterfox\Profiles" },
        @{ Label='LibreWolf'; Roaming="$($u.Path)\AppData\Roaming\librewolf\Profiles";          Local="$($u.Path)\AppData\Local\librewolf\Profiles" }
    )

    foreach ($b in $firefoxBrowsers) {
        if (Test-Path $b.Roaming) {
            Reset-FirefoxProfile -RoamingPath $b.Roaming -LocalPath $b.Local -Label $b.Label
        }
    }
}

# ---- Unload hives ----------------------------------------------------------
foreach ($sid in $loadedHives) {
    [gc]::Collect()
    Start-Sleep -Seconds 1
    Start-Process 'cmd.exe' -ArgumentList "/C reg.exe UNLOAD HKU\$sid" -Wait -WindowStyle Hidden | Out-Null
}

# ---- Result ----------------------------------------------------------------
Write-Host "`n======================================================="
if ($script:ExitCode -eq 0) {
    Write-Host 'SUCCESS: All browsers reset. Passwords/history/bookmarks preserved.'
} else {
    Write-Host 'COMPLETE WITH WARNINGS: Some items could not be removed. Review output above.'
}
Write-Host '======================================================='
exit $script:ExitCode
