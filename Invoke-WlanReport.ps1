#Requires -Version 5.1
#Requires -PSEdition Desktop

<#
.SYNOPSIS
    WLAN Report Manager - GUI wrapper for netsh wlan show wlanreport.
.DESCRIPTION
    Generates the Windows WLAN connectivity report, auto-opens it in the
    default browser, and provides Save, Export, and scheduled email options.
.NOTES
    Author : Spectre AI / Paladin Business Consulting
    Requires: PowerShell 5.1 Desktop, Admin rights for report generation.
              Scheduled email requires SMTP relay accessible from this machine.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- ASSEMBLIES --------------------------------------------------------------
[void][System.Reflection.Assembly]::LoadWithPartialName('PresentationFramework')
[void][System.Reflection.Assembly]::LoadWithPartialName('PresentationCore')
[void][System.Reflection.Assembly]::LoadWithPartialName('WindowsBase')
Add-Type -AssemblyName System.Windows.Forms

# -- CONSTANTS ---------------------------------------------------------------
$script:ReportSource = "$env:ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html"
$script:LogPath      = "$env:TEMP\WlanReportManager.log"
$script:TaskName     = 'PaladinWlanEmailReport'

# -- XAML --------------------------------------------------------------------
[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="WLAN Report Manager - Paladin Business Consulting"
    Height="680" Width="820"
    MinHeight="580" MinWidth="700"
    WindowStartupLocation="CenterScreen"
    Background="#1A1A2E">

    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background"   Value="#0F3460"/>
            <Setter Property="Foreground"   Value="White"/>
            <Setter Property="FontSize"     Value="13"/>
            <Setter Property="FontWeight"   Value="SemiBold"/>
            <Setter Property="Padding"      Value="14,7"/>
            <Setter Property="Margin"       Value="5,3"/>
            <Setter Property="Cursor"       Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#E94560"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#333355"/>
                    <Setter Property="Foreground" Value="#777799"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#E94560"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#C73652"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background"   Value="#16213E"/>
            <Setter Property="Foreground"   Value="#E0E0E0"/>
            <Setter Property="BorderBrush"  Value="#0F3460"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"      Value="6,4"/>
            <Setter Property="Margin"       Value="4,3"/>
            <Setter Property="FontFamily"   Value="Consolas"/>
            <Setter Property="FontSize"     Value="12"/>
            <Setter Property="CaretBrush"   Value="White"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground"   Value="#AAAACC"/>
            <Setter Property="FontSize"     Value="12"/>
            <Setter Property="Padding"      Value="2,4,2,2"/>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Background"   Value="#16213E"/>
            <Setter Property="Foreground"   Value="#E0E0E0"/>
            <Setter Property="BorderBrush"  Value="#0F3460"/>
            <Setter Property="Padding"      Value="6,4"/>
            <Setter Property="Margin"       Value="4,3"/>
            <Setter Property="FontSize"     Value="12"/>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Foreground"       Value="#AAAACC"/>
            <Setter Property="BorderBrush"      Value="#0F3460"/>
            <Setter Property="BorderThickness"  Value="1"/>
            <Setter Property="Padding"          Value="8,6"/>
            <Setter Property="Margin"           Value="6,4"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground"   Value="#AAAACC"/>
            <Setter Property="FontSize"     Value="12"/>
            <Setter Property="Margin"       Value="4,3"/>
        </Style>
    </Window.Resources>

    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- HEADER -->
        <Border Grid.Row="0" Background="#0F3460" CornerRadius="4" Padding="12,8" Margin="0,0,0,8">
            <StackPanel>
                <TextBlock Text="WLAN Report Manager" FontSize="20" FontWeight="Bold"
                           Foreground="White"/>
                <TextBlock Text="netsh wlan show wlanreport - Paladin Business Consulting"
                           FontSize="11" Foreground="#8888AA" Margin="0,2,0,0"/>
            </StackPanel>
        </Border>

        <!-- ACTION ROW -->
        <Border Grid.Row="1" Background="#16213E" CornerRadius="4" Padding="8,6" Margin="0,0,0,6">
            <WrapPanel>
                <Button x:Name="btnGenerate"  Content="Generate Report"    Style="{StaticResource AccentButton}"/>
                <Button x:Name="btnOpenReport" Content="Open in Browser"   IsEnabled="False"/>
                <Button x:Name="btnSave"       Content="Save Report"       IsEnabled="False"/>
                <Button x:Name="btnExport"     Content="Export Report"     IsEnabled="False"/>
                <Button x:Name="btnViewLog"    Content="View Log"/>
            </WrapPanel>
        </Border>

        <!-- SCHEDULED EMAIL -->
        <GroupBox Grid.Row="2" Header="  Scheduled Email Report  " Margin="0,0,0,6">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- Row 0: SMTP + Port + TLS -->
                <Label Grid.Row="0" Grid.Column="0" Content="SMTP Server:"/>
                <TextBox x:Name="txtSmtpServer" Grid.Row="0" Grid.Column="1"
                         ToolTip="e.g. smtp.office365.com"/>
                <Label Grid.Row="0" Grid.Column="2" Content="Port:" Margin="8,4,2,2"/>
                <TextBox x:Name="txtSmtpPort" Grid.Row="0" Grid.Column="3"
                         Text="587" Width="60" HorizontalAlignment="Left"/>
                <CheckBox x:Name="chkTls" Grid.Row="0" Grid.Column="4"
                          Content="Use TLS" IsChecked="True" VerticalAlignment="Center" Margin="8,3"/>

                <!-- Row 1: From / To / Subject -->
                <Label Grid.Row="1" Grid.Column="0" Content="From:"/>
                <TextBox x:Name="txtFrom" Grid.Row="1" Grid.Column="1"
                         ToolTip="Sender email address"/>
                <Label Grid.Row="1" Grid.Column="2" Content="To:" Margin="8,4,2,2"/>
                <TextBox x:Name="txtTo" Grid.Row="1" Grid.Column="3"
                         ToolTip="Recipient email (comma-separated for multiple)"/>
                <Button x:Name="btnTestEmail" Grid.Row="1" Grid.Column="4"
                        Content="Test Email" Margin="8,3,0,3" Padding="10,5"/>

                <!-- Row 2: Credential + Schedule + Register -->
                <Label Grid.Row="2" Grid.Column="0" Content="SMTP User:"/>
                <TextBox x:Name="txtSmtpUser" Grid.Row="2" Grid.Column="1"
                         ToolTip="Leave blank if relay needs no auth"/>
                <Label Grid.Row="2" Grid.Column="2" Content="Schedule:" Margin="8,4,2,2"/>
                <ComboBox x:Name="cboSchedule" Grid.Row="2" Grid.Column="3">
                    <ComboBoxItem Content="Daily - 6:00 AM"     Tag="DAILY"/>
                    <ComboBoxItem Content="Daily - 8:00 AM"     Tag="DAILY8"/>
                    <ComboBoxItem Content="Weekly - Monday 6 AM" Tag="WEEKLY"/>
                    <ComboBoxItem Content="Every 4 Hours"       Tag="4HR"/>
                    <ComboBoxItem Content="Every 12 Hours"      Tag="12HR"/>
                    <ComboBoxItem Content="On System Startup"   Tag="STARTUP"/>
                </ComboBox>
                <Button x:Name="btnSchedule" Grid.Row="2" Grid.Column="4"
                        Content="Register Task" Margin="8,3,0,3" Padding="10,5"/>
            </Grid>
        </GroupBox>

        <!-- LOG -->
        <GroupBox Grid.Row="3" Header="  Activity Log  ">
            <TextBox x:Name="txtLog"
                     IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                     FontFamily="Consolas" FontSize="11.5" Background="#0D1B2A"
                     Foreground="#00FF88" BorderThickness="0" AcceptsReturn="True"/>
        </GroupBox>

        <!-- STATUS BAR -->
        <Border Grid.Row="4" Background="#0F3460" CornerRadius="4" Padding="8,5" Margin="0,6,0,0">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="txtStatus" Grid.Column="0"
                           Text="Ready. Click Generate Report to begin."
                           Foreground="#AAAACC" FontSize="11" VerticalAlignment="Center"/>
                <TextBlock x:Name="txtReportPath" Grid.Column="1"
                           Text="" Foreground="#555577" FontSize="10"
                           VerticalAlignment="Center" Margin="8,0,0,0"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@

# -- PARSE WINDOW ------------------------------------------------------------
$reader = New-Object System.Xml.XmlNodeReader $xaml
try {
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.MessageBox]::Show("Failed to load UI: $_", "Startup Error",
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    exit 1
}

# -- FINDNAME ----------------------------------------------------------------
$window.Add_Loaded({
    $script:btnGenerate   = $window.FindName('btnGenerate')
    $script:btnOpenReport = $window.FindName('btnOpenReport')
    $script:btnSave       = $window.FindName('btnSave')
    $script:btnExport     = $window.FindName('btnExport')
    $script:btnViewLog    = $window.FindName('btnViewLog')
    $script:btnTestEmail  = $window.FindName('btnTestEmail')
    $script:btnSchedule   = $window.FindName('btnSchedule')
    $script:txtLog        = $window.FindName('txtLog')
    $script:txtStatus     = $window.FindName('txtStatus')
    $script:txtReportPath = $window.FindName('txtReportPath')
    $script:txtSmtpServer = $window.FindName('txtSmtpServer')
    $script:txtSmtpPort   = $window.FindName('txtSmtpPort')
    $script:txtSmtpUser   = $window.FindName('txtSmtpUser')
    $script:txtFrom       = $window.FindName('txtFrom')
    $script:txtTo         = $window.FindName('txtTo')
    $script:chkTls        = $window.FindName('chkTls')
    $script:cboSchedule   = $window.FindName('cboSchedule')

    $script:cboSchedule.SelectedIndex = 0

    Write-UiLog "WLAN Report Manager initialized." 'INFO'
    Write-UiLog "Report will be generated at: $script:ReportSource" 'INFO'

    # Wire events
    $script:btnGenerate.Add_Click(  { Invoke-GenerateReport })
    $script:btnOpenReport.Add_Click({ Invoke-OpenReport     })
    $script:btnSave.Add_Click(      { Invoke-SaveReport     })
    $script:btnExport.Add_Click(    { Invoke-ExportReport   })
    $script:btnViewLog.Add_Click(   { Start-Process notepad.exe -ArgumentList $script:LogPath })
    $script:btnTestEmail.Add_Click( { Invoke-TestEmail      })
    $script:btnSchedule.Add_Click(  { Invoke-RegisterTask   })
})

# -- HELPERS -----------------------------------------------------------------
function Write-UiLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts   = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts][$Level] $Message"

    # UI update
    if ($null -ne $script:txtLog) {
        $script:txtLog.AppendText("$line`r`n")
        $script:txtLog.ScrollToEnd()
    }

    # File log
    try {
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

function Set-Status {
    param([string]$Text)
    if ($null -ne $script:txtStatus) { $script:txtStatus.Text = $Text }
}

function Enable-ReportButtons {
    $script:btnOpenReport.IsEnabled = $true
    $script:btnSave.IsEnabled       = $true
    $script:btnExport.IsEnabled     = $true
    $script:txtReportPath.Text      = $script:ReportSource
}

function Get-SmtpPassword {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text        = 'SMTP Password'
    $dlg.Size        = New-Object System.Drawing.Size(320, 140)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Enter SMTP password (leave blank for relay):'
    $lbl.Location = New-Object System.Drawing.Point(10, 12)
    $lbl.Size = New-Object System.Drawing.Size(290, 18)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.PasswordChar = '*'
    $tb.Location = New-Object System.Drawing.Point(10, 36)
    $tb.Size = New-Object System.Drawing.Size(285, 22)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'OK'
    $btnOk.DialogResult = 'OK'
    $btnOk.Location = New-Object System.Drawing.Point(115, 68)
    $btnOk.Size = New-Object System.Drawing.Size(80, 28)

    $dlg.Controls.AddRange(@($lbl, $tb, $btnOk))
    $dlg.AcceptButton = $btnOk

    if ($dlg.ShowDialog() -eq 'OK') { return $tb.Text }
    return $null
}

# -- CORE FUNCTIONS -----------------------------------------------------------
function Invoke-GenerateReport {
    Set-Status 'Generating WLAN report...'
    Write-UiLog 'Running: netsh wlan show wlanreport' 'INFO'

    $script:btnGenerate.IsEnabled = $false

    try {
        $result = & netsh wlan show wlanreport 2>&1
        $output = $result -join "`n"
        Write-UiLog $output 'INFO'

        if (Test-Path -LiteralPath $script:ReportSource -ErrorAction SilentlyContinue) {
            Write-UiLog 'Report generated successfully.' 'INFO'
            Set-Status 'Report generated. Opening in browser...'
            Enable-ReportButtons
            Invoke-OpenReport
        } else {
            Write-UiLog 'Report file not found after generation. Run as administrator?' 'WARN'
            Set-Status 'Warning: report file not found. Ensure you are running as administrator.'
            [System.Windows.MessageBox]::Show(
                "Report was not found at:`n$script:ReportSource`n`nPlease ensure this tool is running as administrator.",
                "Report Not Found",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning)
        }
    } catch {
        Write-UiLog "Error generating report: $_" 'ERROR'
        Set-Status "Error: $_"
    } finally {
        $script:btnGenerate.IsEnabled = $true
    }
}

function Invoke-OpenReport {
    if (-not (Test-Path -LiteralPath $script:ReportSource -ErrorAction SilentlyContinue)) {
        Write-UiLog 'No report found. Generate the report first.' 'WARN'
        Set-Status 'No report available. Click Generate Report first.'
        return
    }
    try {
        Start-Process $script:ReportSource
        Write-UiLog "Opened report in default browser: $script:ReportSource" 'INFO'
        Set-Status 'Report opened in browser.'
    } catch {
        Write-UiLog "Failed to open report: $_" 'ERROR'
    }
}

function Invoke-SaveReport {
    if (-not (Test-Path -LiteralPath $script:ReportSource -ErrorAction SilentlyContinue)) {
        Write-UiLog 'No report to save.' 'WARN'; return
    }

    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title      = 'Save WLAN Report'
    $dlg.Filter     = 'HTML Report (*.html)|*.html|All Files (*.*)|*.*'
    $dlg.FileName   = "WLAN-Report-$(Get-Date -Format 'yyyy-MM-dd_HHmm').html"
    $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')

    if ($dlg.ShowDialog() -eq 'OK') {
        try {
            Copy-Item -LiteralPath $script:ReportSource -Destination $dlg.FileName -Force -ErrorAction Stop
            Write-UiLog "Report saved to: $($dlg.FileName)" 'INFO'
            Set-Status "Saved to: $($dlg.FileName)"
        } catch {
            Write-UiLog "Save failed: $_" 'ERROR'
            Set-Status "Save failed: $_"
        }
    }
}

function Invoke-ExportReport {
    if (-not (Test-Path -LiteralPath $script:ReportSource -ErrorAction SilentlyContinue)) {
        Write-UiLog 'No report to export.' 'WARN'; return
    }

    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description         = 'Select export destination folder'
    $dlg.ShowNewFolderButton = $true

    if ($dlg.ShowDialog() -eq 'OK') {
        $stamp      = Get-Date -Format 'yyyy-MM-dd_HHmm'
        $destHtml   = Join-Path $dlg.SelectedPath "WLAN-Report-$stamp.html"

        # Also grab the supporting wlanreport folder if present
        $reportDir  = Join-Path ([System.IO.Path]::GetDirectoryName($script:ReportSource)) 'wlanreport'

        try {
            Copy-Item -LiteralPath $script:ReportSource -Destination $destHtml -Force -ErrorAction Stop
            Write-UiLog "Report exported: $destHtml" 'INFO'

            if (Test-Path -LiteralPath $reportDir -ErrorAction SilentlyContinue) {
                $destDir = Join-Path $dlg.SelectedPath "wlanreport-$stamp"
                try {
                    Copy-Item -LiteralPath $reportDir -Destination $destDir -Recurse -Force -ErrorAction Stop
                    Write-UiLog "Supporting assets exported to: $destDir" 'INFO'
                } catch {
                    Write-UiLog "Asset copy skipped: $_" 'WARN'
                }
            }

            Set-Status "Exported to: $($dlg.SelectedPath)"
        } catch {
            Write-UiLog "Export failed: $_" 'ERROR'
            Set-Status "Export failed: $_"
        }
    }
}

function Invoke-TestEmail {
    $smtp  = $script:txtSmtpServer.Text.Trim()
    $port  = $script:txtSmtpPort.Text.Trim()
    $from  = $script:txtFrom.Text.Trim()
    $to    = $script:txtTo.Text.Trim()
    $user  = $script:txtSmtpUser.Text.Trim()
    $useTls = $script:chkTls.IsChecked

    foreach ($f in @('SMTP Server', $smtp), @('From', $from), @('To', $to)) {
        if ([string]::IsNullOrWhiteSpace($f[1])) {
            [System.Windows.MessageBox]::Show("$($f[0]) is required.", "Validation",
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
    }

    $pass = $null
    if (-not [string]::IsNullOrWhiteSpace($user)) { $pass = Get-SmtpPassword }

    try {
        $params = @{
            SmtpServer  = $smtp
            Port        = [int]$port
            From        = $from
            To          = @($to -split ',\s*')
            Subject     = 'WLAN Report Manager - Test Email'
            Body        = "This is a test email from WLAN Report Manager on $($env:COMPUTERNAME) at $(Get-Date)."
            UseSsl      = [bool]$useTls
        }
        if (-not [string]::IsNullOrWhiteSpace($user) -and $null -ne $pass) {
            $secPass = ConvertTo-SecureString $pass -AsPlainText -Force
            $params.Credential = New-Object System.Management.Automation.PSCredential($user, $secPass)
        }

        Send-MailMessage @params -ErrorAction Stop
        Write-UiLog "Test email sent successfully to: $to" 'INFO'
        Set-Status 'Test email sent.'
        [System.Windows.MessageBox]::Show("Test email sent to: $to", "Success",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    } catch {
        Write-UiLog "Test email failed: $_" 'ERROR'
        Set-Status "Email failed: $_"
        [System.Windows.MessageBox]::Show("Send failed:`n$_", "Email Error",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
}

function Invoke-RegisterTask {
    $smtp   = $script:txtSmtpServer.Text.Trim()
    $port   = $script:txtSmtpPort.Text.Trim()
    $from   = $script:txtFrom.Text.Trim()
    $to     = $script:txtTo.Text.Trim()
    $user   = $script:txtSmtpUser.Text.Trim()
    $useTls = [bool]$script:chkTls.IsChecked

    foreach ($f in @('SMTP Server', $smtp), @('From', $from), @('To', $to)) {
        if ([string]::IsNullOrWhiteSpace($f[1])) {
            [System.Windows.MessageBox]::Show("$($f[0]) is required for scheduled task.", "Validation",
                [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
    }

    # Get SMTP password if needed
    $encPass = ''
    if (-not [string]::IsNullOrWhiteSpace($user)) {
        $pass = Get-SmtpPassword
        if ($null -eq $pass) { return }
        # Store encrypted with DPAPI (current user context) inside the script
        $encBytes = [System.Security.Cryptography.ProtectedData]::Protect(
            [System.Text.Encoding]::UTF8.GetBytes($pass),
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $encPass = [Convert]::ToBase64String($encBytes)
    }

    # Selected schedule
    $sel = $script:cboSchedule.SelectedItem
    $tag = if ($null -ne $sel) { $sel.Tag } else { 'DAILY' }

    # Build the payload script saved to ProgramData
    $payDir  = "$env:ProgramData\Paladin\WlanReport"
    $payPath = "$payDir\Send-WlanReport.ps1"

    $tlsStr  = if ($useTls) { '$true' } else { '$false' }
    $userStr = if ([string]::IsNullOrWhiteSpace($user)) { "''" } else { "'$user'" }

    $payload = @"
#Requires -Version 5.1
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

`$smtpServer = '$smtp'
`$smtpPort   = $port
`$fromAddr   = '$from'
`$toAddrs    = @('$($to -split ',\s*' | ForEach-Object { $_.Trim() } -join "','")') 
`$useTls     = $tlsStr
`$smtpUser   = $userStr
`$encPass    = '$encPass'

try {
    # Generate fresh report
    `$null = & netsh wlan show wlanreport 2>&1

    `$reportPath = "`$env:ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html"
    if (-not (Test-Path -LiteralPath `$reportPath)) {
        throw "Report not found at: `$reportPath"
    }

    `$body = "Automated WLAN Report from `$(`$env:COMPUTERNAME) - Generated `$(Get-Date -Format 'yyyy-MM-dd HH:mm')"

    `$params = @{
        SmtpServer   = `$smtpServer
        Port         = `$smtpPort
        From         = `$fromAddr
        To           = `$toAddrs
        Subject      = "WLAN Report - `$(`$env:COMPUTERNAME) - `$(Get-Date -Format 'yyyy-MM-dd')"
        Body         = `$body
        Attachments  = `$reportPath
        UseSsl       = `$useTls
    }

    if (-not [string]::IsNullOrWhiteSpace(`$smtpUser) -and -not [string]::IsNullOrWhiteSpace(`$encPass)) {
        Add-Type -AssemblyName System.Security
        `$decBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            [Convert]::FromBase64String(`$encPass), `$null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        `$plain  = [System.Text.Encoding]::UTF8.GetString(`$decBytes)
        `$secPwd = ConvertTo-SecureString `$plain -AsPlainText -Force
        `$params.Credential = New-Object System.Management.Automation.PSCredential(`$smtpUser, `$secPwd)
    }

    Send-MailMessage @params -ErrorAction Stop
    Write-Output "Email sent at `$(Get-Date)"
} catch {
    Write-Error "Failed: `$_"
    exit 1
}
"@

    try {
        if (-not (Test-Path -LiteralPath $payDir -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path $payDir -Force -ErrorAction Stop | Out-Null
        }
        [System.IO.File]::WriteAllText($payPath, $payload, [System.Text.Encoding]::UTF8)
        Write-UiLog "Payload script written to: $payPath" 'INFO'
    } catch {
        Write-UiLog "Failed to write payload: $_" 'ERROR'
        Set-Status "Failed to write payload: $_"
        return
    }

    # Build schtasks trigger based on selection
    $psExe       = (Get-Process -Id $PID).Path
    $taskArgs    = "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$payPath`""

    try {
        # Remove old task if exists
        $existing = schtasks /Query /TN $script:TaskName /FO LIST 2>&1
        if ($LASTEXITCODE -eq 0) {
            schtasks /Delete /TN $script:TaskName /F | Out-Null
            Write-UiLog "Removed existing task: $script:TaskName" 'INFO'
        }

        switch ($tag) {
            'DAILY'   {
                schtasks /Create /TN $script:TaskName /TR "`"$psExe`" $taskArgs" `
                    /SC DAILY /ST 06:00 /RL HIGHEST /F | Out-Null
            }
            'DAILY8'  {
                schtasks /Create /TN $script:TaskName /TR "`"$psExe`" $taskArgs" `
                    /SC DAILY /ST 08:00 /RL HIGHEST /F | Out-Null
            }
            'WEEKLY'  {
                schtasks /Create /TN $script:TaskName /TR "`"$psExe`" $taskArgs" `
                    /SC WEEKLY /D MON /ST 06:00 /RL HIGHEST /F | Out-Null
            }
            '4HR'     {
                schtasks /Create /TN $script:TaskName /TR "`"$psExe`" $taskArgs" `
                    /SC HOURLY /MO 4 /RL HIGHEST /F | Out-Null
            }
            '12HR'    {
                schtasks /Create /TN $script:TaskName /TR "`"$psExe`" $taskArgs" `
                    /SC HOURLY /MO 12 /RL HIGHEST /F | Out-Null
            }
            'STARTUP' {
                schtasks /Create /TN $script:TaskName /TR "`"$psExe`" $taskArgs" `
                    /SC ONSTART /RL HIGHEST /F | Out-Null
            }
            default   {
                schtasks /Create /TN $script:TaskName /TR "`"$psExe`" $taskArgs" `
                    /SC DAILY /ST 06:00 /RL HIGHEST /F | Out-Null
            }
        }

        if ($LASTEXITCODE -ne 0) { throw "schtasks exited with code $LASTEXITCODE" }

        $schedLabel = $sel.Content
        Write-UiLog "Scheduled task registered: '$script:TaskName' ($schedLabel)" 'INFO'
        Set-Status "Task '$script:TaskName' registered - $schedLabel"
        [System.Windows.MessageBox]::Show(
            "Scheduled task registered successfully.`n`nTask: $script:TaskName`nSchedule: $schedLabel`n`nThe WLAN report will be generated and emailed automatically.",
            "Task Registered",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information)
    } catch {
        Write-UiLog "Failed to register task: $_" 'ERROR'
        Set-Status "Task registration failed: $_"
        [System.Windows.MessageBox]::Show("Failed to register task:`n$_", "Error",
            [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
}

# -- SHOW WINDOW --------------------------------------------------------------
[void]$window.ShowDialog()
