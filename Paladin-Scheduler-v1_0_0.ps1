#Requires -Version 3.0
param([switch]$GUIMode)
# =============================================================================
# Paladin Task Scheduler [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.0
# =============================================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer   = '1.0.0'
$BaseDir     = 'C:\ProgramData\Paladin\Scheduler'
$ScriptCache = "$BaseDir\Scripts"
$LogFile     = "$BaseDir\Scheduler.log"
$ManifestFile= "$BaseDir\scheduled-tasks.json"
$RepoBase    = 'https://raw.githubusercontent.com/hazenoff/Datto-RMM-Scripts/main/'
$PsExe       = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$TaskPrefix  = 'Paladin_Scheduled_'
$UDFSlot     = if ($env:UDFSlot -match '^\d+$') { [int]$env:UDFSlot } else { 31 }
$SiteName    = if ($env:CS_PROFILE_NAME) { $env:CS_PROFILE_NAME } else { 'UNKNOWN' }
$MachineName = $env:COMPUTERNAME

# =============================================================================
# CATALOG
# =============================================================================
$CatalogJson = @'
[
  {"Name":"Temp Profile Repair",      "File":"Paladin-TempProfileRepair-v2_0_1.ps1",  "EstMin":15,  "Params":"action=Remove"},
  {"Name":"Disk Clean",               "File":"Paladin-DiskClean.ps1",                  "EstMin":5,   "Params":""},
  {"Name":"Disk Clean (Desperation)", "File":"Paladin-DiskClean-DesperationMode.ps1",  "EstMin":10,  "Params":""},
  {"Name":"Storage Clean",            "File":"Paladin-StorageClean-v1_0_2.ps1",        "EstMin":60,  "Params":"action=Clean;inactiveDays=60;allowReboot=false;minFreeGB=2"},
  {"Name":"Spooler Reset",            "File":"Paladin-SpoolerReset-v1_0_0.ps1",        "EstMin":1,   "Params":""},
  {"Name":"Browser Reset",            "File":"Paladin-BrowserReset-v3_0_0.ps1",        "EstMin":2,   "Params":""},
  {"Name":"Sync Reset",               "File":"Paladin-SyncReset-v1_0_1.ps1",           "EstMin":3,   "Params":"target=Both"},
  {"Name":"Network Reset",            "File":"Paladin-NetworkReset-v1_0_0.ps1",        "EstMin":5,   "Params":"allowReboot=false"},
  {"Name":"App Updater (Silent)",     "File":"Paladin-AppUpdater-v1_0_2.ps1",          "EstMin":20,  "Params":"mode=Silent;allowSoftExclusions=false;allowReboot=false"},
  {"Name":"Windows Update",           "File":"Paladin-WindowsUpdate-v1_0_0.ps1",       "EstMin":30,  "Params":"action=Install;allowReboot=false"},
  {"Name":"Disk Maintenance",         "File":"Paladin-DiskMaintenance-v1_0_0.ps1",     "EstMin":120, "Params":"AllowReboot=false"},
  {"Name":"Update and Reset",         "File":"Paladin-UpdateReset-v1_0_0.ps1",         "EstMin":60,  "Params":"AllowReboot=false;WUAction=Install"},
  {"Name":"Offline Files Repair",     "File":"Paladin-OfflineFilesRepair-v1_0_0.ps1",  "EstMin":10,  "Params":"AllowReboot=false"}
]
'@

# =============================================================================
# SHARED HELPERS (always available)
# =============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try {
        if (-not (Test-Path $BaseDir)) { New-Item $BaseDir -ItemType Directory -Force -EA SilentlyContinue | Out-Null }
        Add-Content -Path $LogFile -Value $line -EA SilentlyContinue
    } catch {}
}

function Set-DattoUDF {
    param([int]$Slot, [string]$Value)
    $trimmed = if ($Value.Length -gt 255) { $Value.Substring(0,255) } else { $Value }
    try {
        New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' `
            -Name "Custom$Slot" -PropertyType String -Value $trimmed `
            -Force -EA Stop | Out-Null
        Write-Log "UDF$Slot => $trimmed"
    } catch {}
}

# =============================================================================
# SYSTEM LAUNCH BLOCK
# KW-005: schtasks /IT required for interactive desktop visibility
# =============================================================================

if (-not $GUIMode) {

    foreach ($d in @($BaseDir, $ScriptCache)) {
        if (-not (Test-Path $d)) { New-Item $d -ItemType Directory -Force -EA SilentlyContinue | Out-Null }
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $isSystem = $identity.IsSystem
    Write-Log "Paladin Scheduler v$ScriptVer | Site: $SiteName | Machine: $MachineName"
    Write-Log "Running as: $($identity.Name) | IsSystem: $isSystem"

    $selfDest = "$BaseDir\Paladin-Scheduler.ps1"
    try { Copy-Item -LiteralPath $PSCommandPath -Destination $selfDest -Force -EA Stop }
    catch { Write-Log "ERROR staging self: $($_.Exception.Message)" 'ERROR'; exit 1 }

    $psArgs = "-STA -ExecutionPolicy Bypass -File `"$selfDest`" -GUIMode"

    if ($isSystem) {
        $loggedOnUser = $null
        try { $loggedOnUser = (Get-WmiObject -Class Win32_ComputerSystem -EA Stop).UserName } catch {}
        if ([string]::IsNullOrEmpty($loggedOnUser)) {
            try {
                $loggedOnUser = (& query session 2>&1 |
                    Where-Object { $_ -match 'Active' } |
                    Select-Object -First 1) -replace '.*?(\S+)\s+\d+\s+Active.*','$1'
            } catch {}
        }
        if ([string]::IsNullOrEmpty($loggedOnUser)) {
            Write-Log 'ERROR: No logged-on user found -- cannot launch GUI' 'ERROR'
            Set-DattoUDF -Slot $UDFSlot -Value "FAIL $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $MachineName | No user session"
            exit 1
        }
        Write-Log "Logged-on user: $loggedOnUser -- launching via schtasks /IT"
        $launchTask = 'Paladin_Scheduler_Launch'
        & schtasks.exe /Delete /TN $launchTask /F 2>&1 | Out-Null
        $cmd = "$PsExe -STA -ExecutionPolicy Bypass -File `"$selfDest`" -GUIMode"
        & schtasks.exe /Create /TN $launchTask /TR $cmd /SC ONCE `
            /ST ((Get-Date).AddSeconds(5).ToString('HH:mm')) `
            /RU $loggedOnUser /IT /RL HIGHEST /F 2>&1 | Out-Null
        & schtasks.exe /Run /TN $launchTask 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        & schtasks.exe /Delete /TN $launchTask /F 2>&1 | Out-Null
        Write-Log "GUI launch task fired for: $loggedOnUser"

        # Wait up to 10 min for manifest to be saved or GUI to close
        Write-Log "Waiting for user to configure tasks (10 min timeout)..."
        $waited  = 0
        $signalFile = "$BaseDir\gui.closed"
        $lastMod = if (Test-Path $ManifestFile) { (Get-Item $ManifestFile).LastWriteTime } else { [datetime]::MinValue }
        # Clear any stale signal from previous run
        Remove-Item $signalFile -Force -EA SilentlyContinue

        while ($waited -lt 600) {
            Start-Sleep 5; $waited += 5
            # GUI closed signal -- exit immediately
            if (Test-Path $signalFile) {
                Write-Log "GUI closed by user -- exiting cleanly"
                Remove-Item $signalFile -Force -EA SilentlyContinue
                break
            }
            # Manifest saved -- tasks configured
            if (Test-Path $ManifestFile) {
                $cur = (Get-Item $ManifestFile).LastWriteTime
                if ($cur -gt $lastMod) { Write-Log "Manifest saved -- tasks configured"; break }
            }
        }
        if ($waited -ge 600) { Write-Log "Timeout waiting for GUI" 'WARN' }
        exit 0

    } else {
        Write-Log "Non-SYSTEM -- launching via Start-Process"
        Start-Process -FilePath $PsExe -ArgumentList $psArgs -Verb RunAs
        exit 0
    }

} # end if (-not $GUIMode)

# =============================================================================
# GUI MODE -- runs when re-launched with -GUIMode -STA as logged-on user
# =============================================================================

if ($GUIMode) {

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Web.Extensions

    $ser     = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $Catalog = $ser.Deserialize($CatalogJson, [System.Collections.ArrayList])

    # --- GUI helpers ---

    function Load-Manifest {
        if (Test-Path $ManifestFile) {
            try { return $ser.Deserialize((Get-Content $ManifestFile -Raw -EA Stop), [System.Collections.ArrayList]) } catch {}
        }
        return New-Object System.Collections.ArrayList
    }

    function Save-Manifest { param($tasks)
        try { [System.IO.File]::WriteAllText($ManifestFile, ($ser.Serialize($tasks)), [System.Text.Encoding]::ASCII) } catch {}
    }

    function Download-Script { param($fileName)
        if (-not (Test-Path $ScriptCache)) { New-Item $ScriptCache -ItemType Directory -Force -EA SilentlyContinue | Out-Null }
        $dest = "$ScriptCache\$fileName"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile("$RepoBase$fileName", $dest)
            return $true
        } catch {
            Write-Log "Download failed for ${fileName}: $($_.Exception.Message)" 'WARN'
            return $false
        }
    }

    function Get-TaskName { param($n) return "$TaskPrefix$($n -replace '[^a-zA-Z0-9]','_')" }

    function Get-NextRunDate { param([int]$days) return (Get-Date).AddDays($days).ToString('yyyy-MM-dd') }

    function Get-TaskStatusStr { param($taskName)
        & schtasks.exe /Query /TN $taskName /FO LIST 2>&1 | Out-Null
        return if ($LASTEXITCODE -eq 0) { 'Active' } else { 'Not registered' }
    }

    function Register-PaladinTask { param($task)
        $taskName    = Get-TaskName $task.Name
        $scriptPath  = "$ScriptCache\$($task.File)"
        $wrapperPath = "$ScriptCache\wrap_$($task.Name -replace '[^a-zA-Z0-9]','_').ps1"
        $lines = @()
        if ($task.Params) {
            foreach ($p in ($task.Params -split ';')) {
                if ($p -match '^([^=]+)=(.*)$') {
                    $envKey = $Matches[1]; $envVal = $Matches[2]
                    $lines += "`$env:$envKey = '$envVal'"
                }
            }
        }
        $lines += "& '$scriptPath' *>&1 | Tee-Object -FilePath '$ScriptCache\$($task.Name -replace ' ','_').log' -Append"
        [System.IO.File]::WriteAllLines($wrapperPath, $lines, [System.Text.Encoding]::ASCII)
        & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
        $cmd  = "$PsExe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$wrapperPath`""
        $days = [int]$task.FrequencyDays
        & schtasks.exe /Create /TN $taskName /TR $cmd /SC DAILY /MO $days `
            /ST $task.RunTime /RU SYSTEM /RL HIGHEST /F 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    }

    function Remove-PaladinTask { param($taskName)
        & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null
        $wrapper = "$ScriptCache\wrap_$($taskName -replace [regex]::Escape($TaskPrefix),'').ps1"
        Remove-Item $wrapper -Force -EA SilentlyContinue
    }

    function Write-UDFSummary { param($tasks)
        $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $names = ($tasks | ForEach-Object { "$($_.Name):$($_.FrequencyDays)d" }) -join ' | '
        $msg   = "PASS $ts | $MachineName | $($tasks.Count) tasks | $names"
        try { New-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' -Name "Custom$UDFSlot" -Value $msg -PropertyType String -Force -EA SilentlyContinue | Out-Null } catch {}
    }

    function ConvertTo24Hr { param($h,$m,$ampm)
        $hr = [int]$h
        if ($ampm -eq 'PM' -and $hr -ne 12) { $hr += 12 }
        if ($ampm -eq 'AM' -and $hr -eq 12) { $hr = 0 }
        return '{0:D2}:{1}' -f $hr, $m
    }

    function Set-Status { param($msg,[string]$color='#444')
        $txtStatus.Text = $msg
        $txtStatus.Foreground = $color
    }

    # --- XAML ---

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Paladin Task Scheduler" Width="840" Height="560"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Padding" Value="10,5"/>
            <Setter Property="MinWidth" Value="100"/>
            <Setter Property="Margin" Value="4,0"/>
        </Style>
    </Window.Resources>
    <DockPanel Margin="8">
        <GroupBox DockPanel.Dock="Top" Header="Add Script to Schedule" Margin="4" Padding="8">
            <WrapPanel Orientation="Horizontal">
                <Label Content="Script:" VerticalAlignment="Center"/>
                <ComboBox Name="cmbScript" Width="200" Margin="0,4,12,4" VerticalAlignment="Center"/>
                <Label Content="Frequency:" VerticalAlignment="Center"/>
                <ComboBox Name="cmbFreq" Width="90" Margin="0,4,12,4" VerticalAlignment="Center">
                    <ComboBoxItem Content="30 days" Tag="30"/>
                    <ComboBoxItem Content="60 days" Tag="60"/>
                    <ComboBoxItem Content="90 days" Tag="90"/>
                </ComboBox>
                <Label Content="Run at:" VerticalAlignment="Center"/>
                <ComboBox Name="cmbHour"   Width="50" Margin="0,4,2,4" VerticalAlignment="Center"/>
                <Label Content=":" VerticalAlignment="Center" Margin="0"/>
                <ComboBox Name="cmbMinute" Width="50" Margin="2,4,2,4" VerticalAlignment="Center">
                    <ComboBoxItem Content="00" Tag="00"/>
                    <ComboBoxItem Content="15" Tag="15"/>
                    <ComboBoxItem Content="30" Tag="30"/>
                    <ComboBoxItem Content="45" Tag="45"/>
                </ComboBox>
                <ComboBox Name="cmbAMPM"   Width="55" Margin="2,4,12,4" VerticalAlignment="Center">
                    <ComboBoxItem Content="AM"/>
                    <ComboBoxItem Content="PM"/>
                </ComboBox>
                <Button Name="btnAdd" Content="Add Script" VerticalAlignment="Center"/>
            </WrapPanel>
        </GroupBox>
        <Border DockPanel.Dock="Bottom" Background="#F0F0F0" BorderThickness="0,1,0,0"
                BorderBrush="#CCC" Padding="8,6" Margin="4,0,4,4">
            <DockPanel>
                <Button DockPanel.Dock="Right" Name="btnSave"
                        Content="Save All Tasks" Background="#0078D4" Foreground="White" MinWidth="120"/>
                <Button DockPanel.Dock="Right" Name="btnRemove"
                        Content="Remove Selected" Background="#C42B1C" Foreground="White" MinWidth="120"/>
                <TextBlock Name="txtStatus" VerticalAlignment="Center" Foreground="#444" TextWrapping="Wrap"/>
            </DockPanel>
        </Border>
        <GroupBox Header="Scheduled Tasks" Margin="4">
            <ListView Name="lvTasks" SelectionMode="Extended">
                <ListView.View>
                    <GridView>
                        <GridViewColumn Header="Script Name"   Width="190" DisplayMemberBinding="{Binding Name}"/>
                        <GridViewColumn Header="File"          Width="190" DisplayMemberBinding="{Binding File}"/>
                        <GridViewColumn Header="Frequency"     Width="80"  DisplayMemberBinding="{Binding FrequencyLabel}"/>
                        <GridViewColumn Header="Run Time"      Width="75"  DisplayMemberBinding="{Binding RunTime}"/>
                        <GridViewColumn Header="Next Run"      Width="90"  DisplayMemberBinding="{Binding NextRun}"/>
                        <GridViewColumn Header="Status"        Width="100" DisplayMemberBinding="{Binding TaskStatus}"/>
                    </GridView>
                </ListView.View>
            </ListView>
        </GroupBox>
    </DockPanel>
</Window>
'@

    # --- Load window ---
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $cmbScript = $window.FindName('cmbScript')
    $cmbFreq   = $window.FindName('cmbFreq')
    $cmbHour   = $window.FindName('cmbHour')
    $cmbMinute = $window.FindName('cmbMinute')
    $cmbAMPM   = $window.FindName('cmbAMPM')
    $lvTasks   = $window.FindName('lvTasks')
    $btnAdd    = $window.FindName('btnAdd')
    $btnRemove = $window.FindName('btnRemove')
    $btnSave   = $window.FindName('btnSave')
    $txtStatus = $window.FindName('txtStatus')

    # Populate script dropdown
    foreach ($entry in $Catalog) {
        $item         = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $entry.Name
        $item.Tag     = $entry
        $cmbScript.Items.Add($item) | Out-Null
    }
    $cmbScript.SelectedIndex = 0

    # Populate hour dropdown 1-12
    for ($h = 1; $h -le 12; $h++) {
        $item         = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $h.ToString()
        $item.Tag     = $h.ToString()
        $cmbHour.Items.Add($item) | Out-Null
    }
    $cmbHour.SelectedIndex   = 1    # 2 AM default
    $cmbMinute.SelectedIndex = 0
    $cmbAMPM.SelectedIndex   = 0
    $cmbFreq.SelectedIndex   = 0

    # Load existing tasks
    $scheduledTasks = Load-Manifest
    $taskItems      = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($t in $scheduledTasks) {
        if (-not $t.FrequencyLabel) { $t.FrequencyLabel = "$($t.FrequencyDays) days" }
        if (-not $t.TaskStatus)     { $t.TaskStatus     = Get-TaskStatusStr (Get-TaskName $t.Name) }
        $taskItems.Add([PSCustomObject]$t) | Out-Null
    }
    $lvTasks.ItemsSource = $taskItems

    # --- Button handlers ---

    $btnAdd.Add_Click({
        $scriptItem = $cmbScript.SelectedItem
        if ($null -eq $scriptItem) { Set-Status 'Select a script first.' '#C42B1C'; return }
        $entry    = $scriptItem.Tag
        $freqItem = $cmbFreq.SelectedItem
        $freqDays = if ($null -ne $freqItem) { [int]$freqItem.Tag } else { 30 }
        $hour     = if ($null -ne $cmbHour.SelectedItem)   { $cmbHour.SelectedItem.Tag }   else { '2' }
        $minute   = if ($null -ne $cmbMinute.SelectedItem) { $cmbMinute.SelectedItem.Tag } else { '00' }
        $ampm     = if ($null -ne $cmbAMPM.SelectedItem)   { $cmbAMPM.SelectedItem.Content } else { 'AM' }
        $runTime  = ConvertTo24Hr $hour $minute $ampm

        if ($taskItems | Where-Object { $_.Name -eq $entry.Name }) {
            Set-Status "$($entry.Name) already scheduled. Remove first to change." '#C42B1C'; return
        }

        Set-Status "Downloading $($entry.File)..." '#0078D4'
        $ok = Download-Script $entry.File
        if (-not $ok) { Set-Status "Download failed for $($entry.File)." '#C42B1C'; return }

        $newTask = [PSCustomObject]@{
            Name          = $entry.Name
            File          = $entry.File
            FrequencyDays = $freqDays
            FrequencyLabel= "$freqDays days"
            RunTime       = $runTime
            Params        = $entry.Params
            NextRun       = Get-NextRunDate $freqDays
            TaskStatus    = 'Pending save'
        }
        $taskItems.Add($newTask) | Out-Null
        Set-Status "$($entry.Name) added. Click Save All Tasks to register." '#107C10'
    })

    $btnRemove.Add_Click({
        $selected = @($lvTasks.SelectedItems)
        if ($selected.Count -eq 0) { Set-Status 'Select one or more tasks to remove.' '#C42B1C'; return }
        foreach ($item in $selected) {
            Remove-PaladinTask (Get-TaskName $item.Name)
            $taskItems.Remove($item) | Out-Null
        }
        $remaining = New-Object System.Collections.ArrayList
        foreach ($t in $taskItems) { $remaining.Add($t) | Out-Null }
        Save-Manifest $remaining
        Write-UDFSummary $remaining
        Set-Status "$($selected.Count) task(s) removed." '#107C10'
    })

    $btnSave.Add_Click({
        if ($taskItems.Count -eq 0) { Set-Status 'No tasks to save.' '#C42B1C'; return }
        Set-Status 'Registering tasks...' '#0078D4'
        $allOK = $true
        foreach ($item in $taskItems) {
            $taskHash = @{
                Name         = $item.Name
                File         = $item.File
                FrequencyDays= $item.FrequencyDays
                RunTime      = $item.RunTime
                Params       = $item.Params
            }
            $ok = Register-PaladinTask $taskHash
            if ($ok) { $item.TaskStatus = 'Active' } else { $item.TaskStatus = 'Error'; $allOK = $false }
        }
        $lvTasks.Items.Refresh()
        $manifest = New-Object System.Collections.ArrayList
        foreach ($t in $taskItems) { $manifest.Add($t) | Out-Null }
        Save-Manifest $manifest
        Write-UDFSummary $manifest
        if ($allOK) { Set-Status "All $($taskItems.Count) task(s) registered." '#107C10' }
        else        { Set-Status 'Some tasks failed. Check log.' '#C42B1C' }
    })

    $window.Add_Closed({
        # Write signal file so SYSTEM poll loop detects GUI exit immediately
        try { [System.IO.File]::WriteAllText("$BaseDir\gui.closed", (Get-Date -Format 'o'), [System.Text.Encoding]::ASCII) } catch {}
    })

    $window.ShowDialog() | Out-Null

} # end if ($GUIMode)

exit 0
