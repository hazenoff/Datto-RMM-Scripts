#Requires -Version 3.0
# =============================================================================
# Paladin Service Watchdog Manager [WIN]
# Datto RMM Component | Script | PowerShell
# Version: 1.0.2
# Context: NT AUTHORITY\SYSTEM (Datto entry) -> logged-on user (GUI)
#
# DESCRIPTION:
#   WPF GUI for configuring the Paladin Service Watchdog. Launched by Datto
#   as SYSTEM, immediately relaunches itself as the logged-on user via
#   scheduled task (same pattern as NetworkPro and PrinterManager).
#
#   GUI shows all services on the machine in a scrollable grid:
#     - Service name, display name, current state (color coded)
#     - Watch checkbox  -- include/exclude from watchdog
#     - Auto-Repair checkbox -- attempt restart or monitor-only
#   Add Service panel -- manually pin a service by name
#   Status bar -- last watchdog run time and result from registry
#   Save button -- writes all changes to registry instantly
#   Refresh button -- re-queries all service states
#   View Log button -- opens ServiceWatchdog.log in Notepad
#
# REGISTRY WRITTEN:
#   HKLM:\SOFTWARE\Paladin\ServiceWatchdog\Watchlist
#   HKLM:\SOFTWARE\Paladin\ServiceWatchdog\Excludelist
#   HKLM:\SOFTWARE\Paladin\ServiceWatchdog\RepairFlags
#
# INPUT VARIABLES: None
# EXIT CODES: 0 always (GUI tool)
# =============================================================================

param([switch]$GUIMode)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# =============================================================================
# CONSTANTS
# =============================================================================
$ScriptVer      = '1.0.2'
$BaseDir        = 'C:\ProgramData\Paladin\ServiceWatchdog'
$LogFile        = "$BaseDir\ServiceWatchdog.log"
$SelfDest       = "$BaseDir\Paladin-ServiceWatchdog-Manager.ps1"
$TaskName       = 'Paladin_SvcWatchdog_Manager'
$RegBase        = 'HKLM:\SOFTWARE\Paladin\ServiceWatchdog'
$RegWatchlist   = "$RegBase\Watchlist"
$RegExcludelist = "$RegBase\Excludelist"
$RegRepairFlags = "$RegBase\RepairFlags"
$RegConfig      = "$RegBase\Config"

# Demand-start services -- shown but locked out of Watch in GUI
$DemandStartExclusions = @(
    'edgeupdate','edgeupdatem','gupdate','gupdatem',
    'googleupdaterservice','googleupdaterinternalservice',
    'trustedinstaller','msiserver','wuauserv',
    'bits','dosvc','usosvc','waasmedicgsvc',
    'clipsvc','appxsvc','wscsvc'
)

# =============================================================================
# DATTO SYSTEM LAUNCHER
# =============================================================================
if (-not $GUIMode) {

    function Write-SysLog { param([string]$M) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $M" }

    Write-SysLog "Paladin Service Watchdog Manager v$ScriptVer -- SYSTEM launcher"

    if (-not (Test-Path $BaseDir)) { New-Item $BaseDir -ItemType Directory -Force | Out-Null }

    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $SelfDest -Force -EA Stop
        Write-SysLog "Staged: $SelfDest"
    } catch { Write-SysLog "ERROR staging: $($_.Exception.Message)"; exit 1 }

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
    Write-SysLog "Launching GUI as: $user"

    $psArgs = "-NonInteractive -ExecutionPolicy Bypass -File `"$SelfDest`" -GUIMode"
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    & schtasks.exe /Create /TN $TaskName /TR "PowerShell.exe $psArgs" `
        /SC ONCE /ST 00:00 /RU $user /IT /F /RL HIGHEST 2>&1 | Out-Null
    & schtasks.exe /Run /TN $TaskName 2>&1 | Out-Null
    Write-SysLog "GUI launched. Manager is running on the user desktop."
    Start-Sleep -Seconds 5
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    exit 0
}

# =============================================================================
# GUI MODE
# =============================================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# --- Colors / theme (matches Paladin toolset) ---
$ColorHeader  = '#1A3A5C'
$ColorAccent  = '#2E6DA4'
$ColorBtnFace = '#2E6DA4'
$ColorBtnText = '#FFFFFF'
$ColorBg      = '#F5F5F5'
$ColorGrid    = '#FFFFFF'
$ColorRunning = '#1A7A3C'
$ColorStopped = '#C0392B'
$ColorUnknown = '#7F8C8D'
$ColorWarn    = '#E67E22'

# =============================================================================
# REGISTRY HELPERS
# =============================================================================

function Get-RegHash {
    param([string]$Path)
    $hash = @{}
    try {
        $props = Get-ItemProperty -Path $Path -EA SilentlyContinue
        if ($null -eq $props) { return $hash }
        $props.PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS' } |
            ForEach-Object { $hash[$_.Name.ToLower()] = $_.Value }
    } catch {}
    return $hash
}

function Set-RegHash {
    param([string]$Path, [hashtable]$Data)
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force -EA Stop | Out-Null }
        # Clear existing
        $existing = Get-Item -Path $Path -EA SilentlyContinue
        if ($null -ne $existing) {
            $existing.GetValueNames() | ForEach-Object {
                Remove-ItemProperty -Path $Path -Name $_ -EA SilentlyContinue
            }
        }
        foreach ($key in $Data.Keys) {
            New-ItemProperty -Path $Path -Name $key -Value $Data[$key] `
                -PropertyType String -Force -EA SilentlyContinue | Out-Null
        }
        return $true
    } catch { return $false }
}

function Get-WatchdogConfig {
    $cfg = @{ LastRun = 'Never'; LastResult = 'No data'; MachineType = 'Unknown'; WatchlistBuilt = 'Never' }
    try {
        $props = Get-ItemProperty -Path $RegConfig -EA SilentlyContinue
        if ($null -ne $props) {
            if ($props.LastRun)        { $cfg.LastRun        = $props.LastRun }
            if ($props.LastResult)     { $cfg.LastResult     = $props.LastResult }
            if ($props.MachineType)    { $cfg.MachineType    = $props.MachineType }
            if ($props.WatchlistBuilt) { $cfg.WatchlistBuilt = $props.WatchlistBuilt }
        }
    } catch {}
    return $cfg
}

function Test-DemandStart {
    param([string]$ServiceName)
    $lower = $ServiceName.ToLower()
    foreach ($ex in $DemandStartExclusions) {
        if ($lower -like "$ex*") { return $true }
    }
    return $false
}

# =============================================================================
# SERVICE DATA LOADER
# =============================================================================

function Get-AllServiceData {
    $watchlist   = Get-RegHash -Path $RegWatchlist
    $excludelist = Get-RegHash -Path $RegExcludelist
    $repairFlags = Get-RegHash -Path $RegRepairFlags

    $services = @()
    try {
        $allSvcs = Get-WmiObject -Class Win32_Service -EA SilentlyContinue |
            Sort-Object DisplayName

        foreach ($svc in $allSvcs) {
            $key      = $svc.Name.ToLower()
            $watched  = $watchlist.ContainsKey($key)
            $excluded = $excludelist.ContainsKey($key)
            $isDemand = Test-DemandStart -ServiceName $svc.Name

            # Repair flag: default true unless explicitly '0'
            $repairOn = $true
            if ($repairFlags.ContainsKey($key) -and $repairFlags[$key] -eq '0') { $repairOn = $false }

            $entry = New-Object PSObject -Property @{
                Name        = $svc.Name
                DisplayName = $svc.DisplayName
                State       = $svc.State
                StartMode   = $svc.StartMode
                Watched     = $watched
                AutoRepair  = $repairOn
                IsDemand    = $isDemand
                IsExcluded  = $excluded
            }
            $services += $entry
        }
    } catch {}
    return $services
}

# =============================================================================
# XAML
# =============================================================================

[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Paladin Service Watchdog Manager"
    Width="900" Height="680"
    WindowStartupLocation="CenterScreen"
    Background="#F5F5F5"
    FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style x:Key="HeaderBtn" TargetType="Button">
      <Setter Property="Background" Value="#2E6DA4"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="ColHdr" TargetType="TextBlock">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="54"/>
      <RowDefinition Height="36"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="38"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Background="#1A3A5C">
      <Grid Margin="16,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="Paladin" Foreground="#5BA3E0" FontSize="18" FontWeight="Bold"/>
          <TextBlock Text=" Service Watchdog Manager" Foreground="White" FontSize="18" FontWeight="Light"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,4,0">
          <Button x:Name="BtnRefresh" Content="Refresh" Style="{StaticResource HeaderBtn}" Margin="4,0"/>
          <Button x:Name="BtnSave"    Content="Save Changes" Style="{StaticResource HeaderBtn}" Margin="4,0" Background="#1A7A3C"/>
          <Button x:Name="BtnViewLog" Content="View Log" Style="{StaticResource HeaderBtn}" Margin="4,0" Background="#555"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Filter bar -->
    <Border Grid.Row="1" Background="#2E6DA4" Padding="12,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="200"/>
          <ColumnDefinition Width="20"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="Filter:" Foreground="White" VerticalAlignment="Center" Margin="0,0,6,0"/>
        <TextBox x:Name="TxtFilter" Grid.Column="1" VerticalAlignment="Center" Padding="4,2" FontSize="12"/>
        <CheckBox x:Name="ChkWatchedOnly" Grid.Column="3" Content="Watched only" Foreground="White"
                  VerticalAlignment="Center" Margin="12,0,0,0"/>
        <CheckBox x:Name="ChkStoppedOnly" Grid.Column="6" Content="Stopped only" Foreground="White"
                  VerticalAlignment="Center" Margin="12,0,0,0"/>
      </Grid>
    </Border>

    <!-- Column headers -->
    <Border Grid.Row="2" BorderBrush="#CCC" BorderThickness="0,0,0,1">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="28"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" Background="#345D8A" Padding="8,0">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="22"/>
              <ColumnDefinition Width="180"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="80"/>
              <ColumnDefinition Width="70"/>
              <ColumnDefinition Width="80"/>
            </Grid.ColumnDefinitions>
            <TextBlock Grid.Column="0"/>
            <TextBlock Grid.Column="1" Text="Service Name"   Style="{StaticResource ColHdr}" Margin="4,0"/>
            <TextBlock Grid.Column="2" Text="Display Name"   Style="{StaticResource ColHdr}" Margin="4,0"/>
            <TextBlock Grid.Column="3" Text="State"          Style="{StaticResource ColHdr}" HorizontalAlignment="Center"/>
            <TextBlock Grid.Column="4" Text="Watch"          Style="{StaticResource ColHdr}" HorizontalAlignment="Center"/>
            <TextBlock Grid.Column="5" Text="Auto-Repair"    Style="{StaticResource ColHdr}" HorizontalAlignment="Center"/>
          </Grid>
        </Border>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="SvcPanel" Background="White"/>
        </ScrollViewer>
      </Grid>
    </Border>

    <!-- Add service panel -->
    <Border Grid.Row="3" Background="#E8EEF4" Padding="12,8" BorderBrush="#CCC" BorderThickness="0,1,0,1">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="220"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Column="0" Text="Add service to watchlist:" VerticalAlignment="Center" Margin="0,0,8,0" FontWeight="SemiBold"/>
        <TextBox x:Name="TxtAddService" Grid.Column="1" Padding="4,3" FontSize="12" VerticalAlignment="Center"/>
        <Button x:Name="BtnAddService" Grid.Column="2" Content="Add" Margin="8,0,0,0"
                Background="#2E6DA4" Foreground="White" Padding="12,4" BorderThickness="0" Cursor="Hand"/>
        <TextBlock x:Name="TxtAddStatus" Grid.Column="3" VerticalAlignment="Center" Margin="12,0,0,0" FontSize="11" Foreground="#555"/>
      </Grid>
    </Border>

    <!-- Status bar -->
    <Border Grid.Row="4" Background="#1A3A5C" Padding="12,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="TxtStatus" Foreground="#AAC8E8" VerticalAlignment="Center" FontSize="11"/>
        <TextBlock x:Name="TxtVersion" Grid.Column="1" Foreground="#556B82" VerticalAlignment="Center" FontSize="11"
                   Text="Paladin Service Watchdog Manager v1.0.2"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

# =============================================================================
# BUILD WINDOW
# =============================================================================

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$BtnRefresh    = $window.FindName('BtnRefresh')
$BtnSave       = $window.FindName('BtnSave')
$BtnViewLog    = $window.FindName('BtnViewLog')
$BtnAddService = $window.FindName('BtnAddService')
$TxtFilter     = $window.FindName('TxtFilter')
$ChkWatchedOnly= $window.FindName('ChkWatchedOnly')
$ChkStoppedOnly= $window.FindName('ChkStoppedOnly')
$SvcPanel      = $window.FindName('SvcPanel')
$TxtAddService = $window.FindName('TxtAddService')
$TxtAddStatus  = $window.FindName('TxtAddStatus')
$TxtStatus     = $window.FindName('TxtStatus')

# =============================================================================
# STATE
# =============================================================================

$script:ServiceRows = @()   # array of hashtables: {Name, WatchChk, RepairChk, StateBlock}

# =============================================================================
# ROW BUILDER
# =============================================================================

# =============================================================================
# SORT STATE
# =============================================================================
$script:SortColumn = 'DisplayName'
$script:SortAsc    = $true
$script:ServiceRows = @()

# =============================================================================
# ROW BUILDER  (KI-120 fix: GetNewClosure() on checkbox event scriptblocks)
# =============================================================================

function New-ServiceRow {
    param($SvcData, [bool]$Alternate)

    $bg = if ($Alternate) { '#F0F4F8' } else { '#FFFFFF' }

    $row                 = New-Object System.Windows.Controls.Border
    $row.Background      = $bg
    $row.BorderBrush     = '#E0E0E0'
    $row.BorderThickness = '0,0,0,1'
    $row.Padding         = '8,4'
    $row.Tag             = $SvcData.Name

    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in @(22, 180, [double]::NaN, 80, 70, 80)) {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        if ([double]::IsNaN($w)) {
            $col.Width = New-Object System.Windows.GridLength(1,[System.Windows.GridUnitType]::Star)
        } else {
            $col.Width = New-Object System.Windows.GridLength($w)
        }
        $grid.ColumnDefinitions.Add($col) | Out-Null
    }

    # Demand-start indicator
    $dot                = New-Object System.Windows.Controls.TextBlock
    $dot.Text           = if ($SvcData.IsDemand) { 'D' } else { '' }
    $dot.Foreground     = '#E67E22'
    $dot.FontSize       = 9
    $dot.FontWeight     = 'Bold'
    $dot.VerticalAlignment = 'Center'
    $dot.ToolTip        = 'Demand-start service -- normally stopped by OS design'
    [System.Windows.Controls.Grid]::SetColumn($dot, 0)
    $grid.Children.Add($dot) | Out-Null

    # Service name
    $nameBlock                  = New-Object System.Windows.Controls.TextBlock
    $nameBlock.Text             = $SvcData.Name
    $nameBlock.VerticalAlignment= 'Center'
    $nameBlock.FontSize         = 12
    $nameBlock.Margin           = '4,0'
    $nameBlock.ToolTip          = $SvcData.Name
    [System.Windows.Controls.Grid]::SetColumn($nameBlock, 1)
    $grid.Children.Add($nameBlock) | Out-Null

    # Display name
    $dispBlock                  = New-Object System.Windows.Controls.TextBlock
    $dispBlock.Text             = $SvcData.DisplayName
    $dispBlock.VerticalAlignment= 'Center'
    $dispBlock.FontSize         = 12
    $dispBlock.Margin           = '4,0'
    $dispBlock.TextTrimming     = 'CharacterEllipsis'
    $dispBlock.ToolTip          = $SvcData.DisplayName
    [System.Windows.Controls.Grid]::SetColumn($dispBlock, 2)
    $grid.Children.Add($dispBlock) | Out-Null

    # State
    $stateBlock = New-Object System.Windows.Controls.TextBlock
    $stateColor = switch ($SvcData.State) {
        'Running' { $ColorRunning }
        'Stopped' { $ColorStopped }
        default   { $ColorUnknown }
    }
    $stateBlock.Text                = $SvcData.State
    $stateBlock.Foreground          = $stateColor
    $stateBlock.FontWeight          = 'SemiBold'
    $stateBlock.FontSize            = 11
    $stateBlock.HorizontalAlignment = 'Center'
    $stateBlock.VerticalAlignment   = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($stateBlock, 3)
    $grid.Children.Add($stateBlock) | Out-Null

    # Watch checkbox
    $watchChk                     = New-Object System.Windows.Controls.CheckBox
    $watchChk.IsChecked           = $SvcData.Watched
    $watchChk.HorizontalAlignment = 'Center'
    $watchChk.VerticalAlignment   = 'Center'
    $watchChk.IsEnabled           = (-not $SvcData.IsDemand)
    $watchChk.ToolTip             = if ($SvcData.IsDemand) { 'Demand-start -- cannot be watched' } else { 'Include in watchdog monitoring' }
    [System.Windows.Controls.Grid]::SetColumn($watchChk, 4)
    $grid.Children.Add($watchChk) | Out-Null

    # Auto-Repair checkbox
    $repairChk                     = New-Object System.Windows.Controls.CheckBox
    $repairChk.IsChecked           = ($SvcData.AutoRepair -and $SvcData.Watched -and (-not $SvcData.IsDemand))
    $repairChk.HorizontalAlignment = 'Center'
    $repairChk.VerticalAlignment   = 'Center'
    $repairChk.IsEnabled           = ($SvcData.Watched -and (-not $SvcData.IsDemand))
    $repairChk.ToolTip             = 'Automatically restart this service if stopped'
    [System.Windows.Controls.Grid]::SetColumn($repairChk, 5)
    $grid.Children.Add($repairChk) | Out-Null

    # KI-120 fix: capture local refs, use GetNewClosure() so scriptblock captures correct scope
    $localRepair = $repairChk
    $checkedSb   = { $localRepair.IsEnabled = $true }.GetNewClosure()
    $uncheckedSb = { $localRepair.IsEnabled = $false; $localRepair.IsChecked = $false }.GetNewClosure()
    $watchChk.Add_Checked($checkedSb)
    $watchChk.Add_Unchecked($uncheckedSb)

    $row.Child = $grid

    $script:ServiceRows += @{
        Name      = $SvcData.Name
        WatchChk  = $watchChk
        RepairChk = $repairChk
        Row       = $row
        IsDemand  = $SvcData.IsDemand
        State     = $SvcData.State
        Watched   = $SvcData.Watched
    }

    return $row
}

# =============================================================================
# SORT + POPULATE
# =============================================================================

function Invoke-Sort {
    param([string]$Column)
    if ($script:SortColumn -eq $Column) {
        $script:SortAsc = -not $script:SortAsc
    } else {
        $script:SortColumn = $Column
        $script:SortAsc    = $true
    }
    Invoke-PopulateGrid
}

function Invoke-PopulateGrid {
    $script:ServiceRows = @()
    $SvcPanel.Children.Clear()

    $allSvcs     = Get-AllServiceData
    $filterText  = $TxtFilter.Text.Trim().ToLower()
    $watchedOnly = ($ChkWatchedOnly.IsChecked -eq $true)
    $stoppedOnly = ($ChkStoppedOnly.IsChecked -eq $true)

    $filtered = $allSvcs | Where-Object {
        $ok = $true
        if ($filterText)  { $ok = $ok -and ($_.Name.ToLower() -like "*$filterText*" -or $_.DisplayName.ToLower() -like "*$filterText*") }
        if ($watchedOnly) { $ok = $ok -and $_.Watched }
        if ($stoppedOnly) { $ok = $ok -and ($_.State -ne 'Running') }
        $ok
    }

    # Sort
    $sorted = switch ($script:SortColumn) {
        'Name'        { if ($script:SortAsc) { $filtered | Sort-Object Name        } else { $filtered | Sort-Object Name        -Descending } }
        'DisplayName' { if ($script:SortAsc) { $filtered | Sort-Object DisplayName } else { $filtered | Sort-Object DisplayName -Descending } }
        'State'       { if ($script:SortAsc) { $filtered | Sort-Object State       } else { $filtered | Sort-Object State       -Descending } }
        'Watched'     { if ($script:SortAsc) { $filtered | Sort-Object Watched     } else { $filtered | Sort-Object Watched     -Descending } }
        'AutoRepair'  { if ($script:SortAsc) { $filtered | Sort-Object AutoRepair  } else { $filtered | Sort-Object AutoRepair  -Descending } }
        default       { $filtered | Sort-Object DisplayName }
    }

    $i = 0
    foreach ($svc in $sorted) {
        $row = New-ServiceRow -SvcData $svc -Alternate (($i % 2) -eq 1)
        $SvcPanel.Children.Add($row) | Out-Null
        $i++
    }

    $cfg = Get-WatchdogConfig
    $arrow = if ($script:SortAsc) { '[^]' } else { '[v]' }
    $TxtStatus.Text = "Last run: $($cfg.LastRun)  |  $($cfg.LastResult)  |  Sorted by: $($script:SortColumn) $arrow  |  Showing $i of $($allSvcs.Count)"
    $TxtStatus.Foreground = '#AAC8E8'
}

# =============================================================================
# SAVE
# =============================================================================

function Invoke-Save {
    $newWatchlist   = @{}
    $newRepairFlags = @{}
    $newExcludelist = @{}

    foreach ($entry in $script:ServiceRows) {
        $key = $entry.Name.ToLower()
        if ($entry.WatchChk.IsChecked -eq $true) {
            $newWatchlist[$key]   = $entry.Name
            $newRepairFlags[$key] = if ($entry.RepairChk.IsChecked -eq $true) { '1' } else { '0' }
        } else {
            $newExcludelist[$key] = $entry.Name
        }
    }

    $ok1 = Set-RegHash -Path $RegWatchlist   -Data $newWatchlist
    $ok2 = Set-RegHash -Path $RegRepairFlags -Data $newRepairFlags
    $ok3 = Set-RegHash -Path $RegExcludelist -Data $newExcludelist

    if ($ok1 -and $ok2 -and $ok3) {
        $TxtStatus.Text       = "Saved $(Get-Date -Format 'HH:mm:ss') -- $($newWatchlist.Count) watched, $($newExcludelist.Count) excluded. Watchdog picks up new config on next run."
        $TxtStatus.Foreground = '#90EE90'
    } else {
        $TxtStatus.Text       = "ERROR: One or more registry writes failed. Check permissions."
        $TxtStatus.Foreground = '#FF6B6B'
    }
}

# =============================================================================
# ADD SERVICE
# =============================================================================

function Invoke-AddService {
    $svcName = $TxtAddService.Text.Trim()
    if ([string]::IsNullOrEmpty($svcName)) { $TxtAddStatus.Text = 'Enter a service name.'; return }
    $svc = Get-WmiObject -Class Win32_Service -Filter "Name='$svcName'" -EA SilentlyContinue
    if ($null -eq $svc) {
        $TxtAddStatus.Text       = "Service '$svcName' not found on this machine."
        $TxtAddStatus.Foreground = '#C0392B'
        return
    }
    try {
        if (-not (Test-Path "$RegBase\Pinlist")) { New-Item -Path "$RegBase\Pinlist" -Force | Out-Null }
        New-ItemProperty -Path "$RegBase\Pinlist" -Name $svcName.ToLower() -Value $svcName -PropertyType String -Force | Out-Null
    } catch {}
    $TxtAddStatus.Text       = "Added '$svcName' ($($svc.DisplayName)). Refresh to see in list."
    $TxtAddStatus.Foreground = '#1A7A3C'
    $TxtAddService.Text      = ''
    Invoke-PopulateGrid
}

# =============================================================================
# COLUMN HEADER SORT BUTTONS  (injected after XAML load)
# =============================================================================

function Add-SortHeader {
    param([string]$Content, [string]$SortKey, [int]$ColIndex, [string]$HAlign = 'Left')
    $btn = New-Object System.Windows.Controls.Button
    $btn.Content             = $Content
    $btn.Background          = 'Transparent'
    $btn.Foreground          = 'White'
    $btn.BorderThickness     = '0'
    $btn.Cursor              = 'Hand'
    $btn.FontSize            = 12
    $btn.FontWeight          = 'SemiBold'
    $btn.HorizontalAlignment = $HAlign
    $btn.VerticalAlignment   = 'Center'
    $btn.Padding             = '4,0'
    $btn.ToolTip             = "Sort by $Content"
    $localKey = $SortKey
    $sb = { Invoke-Sort -Column $localKey }.GetNewClosure()
    $btn.Add_Click($sb)
    [System.Windows.Controls.Grid]::SetColumn($btn, $ColIndex)
    return $btn
}

# =============================================================================
# EVENT WIRING
# =============================================================================

$BtnRefresh.Add_Click({    Invoke-PopulateGrid })
$BtnSave.Add_Click({       Invoke-Save })
$BtnViewLog.Add_Click({
    if (Test-Path $LogFile) { Start-Process notepad.exe -ArgumentList $LogFile }
    else { [System.Windows.MessageBox]::Show('Log file not found. Watchdog has not run yet.','Paladin') }
})
$BtnAddService.Add_Click({ Invoke-AddService })
$TxtFilter.Add_TextChanged({ Invoke-PopulateGrid })
$ChkWatchedOnly.Add_Checked({   Invoke-PopulateGrid })
$ChkWatchedOnly.Add_Unchecked({ Invoke-PopulateGrid })
$ChkStoppedOnly.Add_Checked({   Invoke-PopulateGrid })
$ChkStoppedOnly.Add_Unchecked({ Invoke-PopulateGrid })

# Replace static column header TextBlocks with clickable sort buttons
# Find the header Border (first child of the column header grid in Row 2)
$hdrGrid = $null
try {
    # Walk visual tree to find the header grid
    $outerBorder = $null
    foreach ($child in $window.Content.Children) {
        if ($child -is [System.Windows.Controls.Border] -and [System.Windows.Controls.Grid]::GetRow($child) -eq 2) {
            $outerBorder = $child; break
        }
    }
    if ($null -ne $outerBorder) {
        $innerGrid = $outerBorder.Child
        if ($null -ne $innerGrid -and $innerGrid.RowDefinitions.Count -ge 1) {
            foreach ($child in $innerGrid.Children) {
                if ([System.Windows.Controls.Grid]::GetRow($child) -eq 0) {
                    $hdrGrid = $child.Child  # the inner Grid inside the Border
                    break
                }
            }
        }
    }
} catch {}

if ($null -ne $hdrGrid) {
    $hdrGrid.Children.Clear()
    $hdrGrid.Children.Add((Add-SortHeader -Content 'Service Name'  -SortKey 'Name'        -ColIndex 1)) | Out-Null
    $hdrGrid.Children.Add((Add-SortHeader -Content 'Display Name'  -SortKey 'DisplayName' -ColIndex 2)) | Out-Null
    $hdrGrid.Children.Add((Add-SortHeader -Content 'State'         -SortKey 'State'       -ColIndex 3 -HAlign 'Center')) | Out-Null
    $hdrGrid.Children.Add((Add-SortHeader -Content 'Watch'         -SortKey 'Watched'     -ColIndex 4 -HAlign 'Center')) | Out-Null
    $hdrGrid.Children.Add((Add-SortHeader -Content 'Auto-Repair'   -SortKey 'AutoRepair'  -ColIndex 5 -HAlign 'Center')) | Out-Null
}

# =============================================================================
# LAUNCH
# =============================================================================

Invoke-PopulateGrid
$window.ShowDialog() | Out-Null
