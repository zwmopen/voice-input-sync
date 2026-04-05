param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName WindowsFormsIntegration

$ErrorActionPreference = "Stop"
[System.Windows.Forms.Application]::EnableVisualStyles()

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDir = Split-Path -Parent $BaseDir
$LogsDir = Join-Path $PackageDir "logs"
$LatestUrlFile = Join-Path $PackageDir "latest-url.txt"
$RuntimeConfigFile = Join-Path $BaseDir "runtime-config.json"
$BuildInfoFile = Join-Path $BaseDir "build-info.json"
$UpdateStatusFile = Join-Path $LogsDir "update-status.json"
$QrHtmlFile = Join-Path $PackageDir ((-join ([int[]](0x624B,0x673A,0x626B,0x7801,0x6253,0x5F00) | ForEach-Object { [char]$_ })) + ".html")
$QrWindowScript = Join-Path $BaseDir "portable-qr-window.ps1"
$SettingsWindowScript = Join-Path $BaseDir "portable-settings-window.ps1"
$UpdateCheckScript = Join-Path $BaseDir "portable-check-update.ps1"
$StopScript = Join-Path $BaseDir "portable-stop.ps1"
$IconPath = Join-Path $BaseDir "assets\voice-sync-icon.ico"
$MutexName = "Local\VoiceInputSyncPortableTray"
$TrayMutex = $null
$OwnsTrayMutex = $false
$script:AllowWindowClose = $false
$script:PopupVisible = $false
$script:PopupShownAt = $null

New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null

function Get-UiText {
    param([int[]]$Codes)

    return (-join ($Codes | ForEach-Object { [char]$_ }))
}

function Write-Log {
    param([string]$Message)

    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path (Join-Path $LogsDir "tray.log") -Value "[$stamp] $Message" -Encoding UTF8
}

function Enter-TrayMutex {
    $createdNew = $false
    $script:TrayMutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
    $script:OwnsTrayMutex = [bool]$createdNew
    return $script:OwnsTrayMutex
}

function Exit-TrayMutex {
    if ($script:TrayMutex) {
        try {
            if ($script:OwnsTrayMutex) {
                $script:TrayMutex.ReleaseMutex()
            }
        } catch {
        } finally {
            $script:TrayMutex.Dispose()
            $script:TrayMutex = $null
            $script:OwnsTrayMutex = $false
        }
    }
}

function Read-LatestUrl {
    if (-not (Test-Path $LatestUrlFile)) {
        return ""
    }

    try {
        return (Get-Content -Raw -LiteralPath $LatestUrlFile -Encoding UTF8).Trim()
    } catch {
        return ""
    }
}

function Read-RuntimeConfig {
    if (-not (Test-Path $RuntimeConfigFile)) {
        return $null
    }

    try {
        return Get-Content -Raw -LiteralPath $RuntimeConfigFile -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log ("Runtime config read failed: " + $_.Exception.Message)
        return $null
    }
}

function Read-BuildInfo {
    if (-not (Test-Path $BuildInfoFile)) {
        return $null
    }

    try {
        return Get-Content -Raw -LiteralPath $BuildInfoFile -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log ("Build info read failed: " + $_.Exception.Message)
        return $null
    }
}

function Read-UpdateStatus {
    if (-not (Test-Path $UpdateStatusFile)) {
        return $null
    }

    try {
        return Get-Content -Raw -LiteralPath $UpdateStatusFile -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log ("Update status read failed: " + $_.Exception.Message)
        return $null
    }
}

function Get-ConfigValue {
    param(
        $Config,
        [string]$PropertyName
    )

    if (-not $Config) {
        return ""
    }

    if ($null -eq $Config.PSObject.Properties[$PropertyName]) {
        return ""
    }

    $value = [string]$Config.$PropertyName
    if ([string]::IsNullOrWhiteSpace($value)) {
        return ""
    }

    return $value.Trim()
}

function Get-PreferredMobileUrl {
    $config = Read-RuntimeConfig
    foreach ($candidate in @(
        (Get-ConfigValue -Config $config -PropertyName "directUrl"),
        (Get-ConfigValue -Config $config -PropertyName "directIpUrl"),
        (Read-LatestUrl),
        (Get-ConfigValue -Config $config -PropertyName "publicHttpUrl")
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return ""
}

function Open-Target {
    param([string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return $false
    }

    try {
        $resolvedTarget = $Target
        if (-not ($Target -match '^[a-zA-Z][a-zA-Z0-9+.-]*://')) {
            $resolvedTarget = (Resolve-Path -LiteralPath $Target).Path
        }

        $resolvedQrHtml = ""
        try {
            if (Test-Path $QrHtmlFile) {
                $resolvedQrHtml = (Resolve-Path -LiteralPath $QrHtmlFile).Path
            }
        } catch {
            $resolvedQrHtml = ""
        }

        if ($resolvedQrHtml -and $resolvedTarget -eq $resolvedQrHtml -and (Test-Path $QrWindowScript)) {
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.ProcessId -ne $PID -and
                    $_.CommandLine -and
                    $_.CommandLine -like '*portable-qr-window.ps1*'
                } |
                ForEach-Object {
                    try {
                        Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
                    } catch {
                    }
                }

            Start-Process -FilePath (Get-Command powershell.exe).Source `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $QrWindowScript) `
                -WorkingDirectory $PackageDir `
                -WindowStyle Hidden | Out-Null
            Write-Log ("Opened QR window: {0}" -f $QrWindowScript)
            return $true
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $resolvedTarget
        $psi.UseShellExecute = $true
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        Write-Log ("Opened target: {0}" -f $resolvedTarget)
        return $true
    } catch {
        Write-Log ("Open target failed: " + $_.Exception.Message)
        return $false
    }
}

function Show-Balloon {
    param(
        [System.Windows.Forms.NotifyIcon]$NotifyIcon,
        [string]$Title,
        [string]$Text,
        [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info
    )

    try {
        $NotifyIcon.BalloonTipTitle = $Title
        $NotifyIcon.BalloonTipText = $Text
        $NotifyIcon.BalloonTipIcon = $Icon
        $NotifyIcon.ShowBalloonTip(2200)
    } catch {
    }
}

function New-WpfBrush {
    param([string]$Color)

    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Set-ButtonPalette {
    param(
        [System.Windows.Controls.Button]$Button,
        [string]$BaseColor,
        [string]$HoverColor,
        [string]$TextColor
    )

    $palette = [pscustomobject]@{
        Base = New-WpfBrush $BaseColor
        Hover = New-WpfBrush $HoverColor
        Text = New-WpfBrush $TextColor
    }

    $Button.Tag = $palette
    $Button.Background = $palette.Base
    $Button.Foreground = $palette.Text
    $Button.Add_MouseEnter({
        $sender = [System.Windows.Controls.Button]$this
        $sender.Background = $sender.Tag.Hover
    })
    $Button.Add_MouseLeave({
        $sender = [System.Windows.Controls.Button]$this
        $sender.Background = $sender.Tag.Base
    })
}

function Set-MenuButtonContent {
    param(
        [System.Windows.Controls.Button]$Button,
        [string]$Label,
        [bool]$ShowDot = $false
    )

    if (-not $ShowDot) {
        $Button.Content = $Label
        return
    }

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = [System.Windows.Thickness]::new(0)

    $columnText = New-Object System.Windows.Controls.ColumnDefinition
    $columnText.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $columnDot = New-Object System.Windows.Controls.ColumnDefinition
    $columnDot.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($columnText)
    $grid.ColumnDefinitions.Add($columnDot)

    $text = New-Object System.Windows.Controls.TextBlock
    $text.Text = $Label
    $text.FontSize = 11.8
    $text.FontWeight = "Bold"
    $text.Foreground = $Button.Foreground
    $text.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($text, 0)
    $grid.Children.Add($text) | Out-Null

    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 8
    $dot.Height = 8
    $dot.Fill = New-WpfBrush "#4DB57C"
    $dot.Margin = [System.Windows.Thickness]::new(10,0,4,0)
    $dot.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($dot, 1)
    $grid.Children.Add($dot) | Out-Null

    $Button.Content = $grid
}

function Set-ButtonEnabledState {
    param(
        [System.Windows.Controls.Button]$Button,
        [bool]$Enabled
    )

    $Button.IsEnabled = $Enabled
    if ($Enabled) {
        $Button.Opacity = 1
        $Button.Cursor = [System.Windows.Input.Cursors]::Hand
        $Button.Foreground = $Button.Tag.Text
        $Button.Background = $Button.Tag.Base
    } else {
        $Button.Opacity = 0.58
        $Button.Cursor = [System.Windows.Input.Cursors]::Arrow
        $Button.Foreground = New-WpfBrush "#8797A8"
        $Button.Background = New-WpfBrush "#E2EAF3"
    }
}

function Resolve-MenuLocation {
    param(
        [double]$Width,
        [double]$Height
    )

    $cursor = [System.Windows.Forms.Cursor]::Position
    $screen = [System.Windows.Forms.Screen]::FromPoint($cursor)
    $workArea = $screen.WorkingArea

    $x = $cursor.X - [Math]::Min(18, [int]($Width / 7))
    $y = $cursor.Y - [Math]::Min(18, [int]($Height / 9))

    if (($x + $Width) -gt $workArea.Right) {
        $x = $workArea.Right - $Width - 8
    }
    if (($y + $Height) -gt $workArea.Bottom) {
        $y = $workArea.Bottom - $Height - 8
    }
    if ($x -lt $workArea.Left + 8) {
        $x = $workArea.Left + 8
    }
    if ($y -lt $workArea.Top + 8) {
        $y = $workArea.Top + 8
    }

    return [System.Windows.Point]::new([double]$x, [double]$y)
}

function Start-BackgroundUpdateCheck {
    param([switch]$Force)

    if (-not (Test-Path $UpdateCheckScript)) {
        return
    }

    try {
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $UpdateCheckScript)
        if ($Force) {
            $arguments += "-Force"
        }

        Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    } catch {
        Write-Log ("Update check start failed: " + $_.Exception.Message)
    }
}

if (-not (Enter-TrayMutex)) {
    Write-Log "Tray already running."
    exit 0
}

$titleText = Get-UiText 0x8BED,0x97F3,0x8F93,0x5165,0x540C,0x6B65
$subtitleText = Get-UiText 0x5C40,0x57DF,0x7F51,0x4F18,0x5148,0xFF0C,0x4E92,0x8054,0x7F51,0x5907,0x7528
$openQrLabel = Get-UiText 0x6253,0x5F00,0x626B,0x7801,0x9875
$openMobileLabel = Get-UiText 0x6253,0x5F00,0x624B,0x673A,0x9875
$copyLabel = Get-UiText 0x590D,0x5236,0x5730,0x5740
$settingsLabel = Get-UiText 0x8BBE,0x7F6E
$exitLabel = Get-UiText 0x9000,0x51FA,0x540C,0x6B65
$qrOpenFailedText = Get-UiText 0x626B,0x7801,0x754C,0x9762,0x6682,0x65F6,0x8FD8,0x6CA1,0x51C6,0x5907,0x597D,0x3002
$pendingText = Get-UiText 0x8FD8,0x6CA1,0x62FF,0x5230,0x624B,0x673A,0x5730,0x5740,0xFF0C,0x8BF7,0x7A0D,0x540E,0x518D,0x8BD5,0x3002
$copiedText = Get-UiText 0x624B,0x673A,0x5730,0x5740,0x5DF2,0x7ECF,0x590D,0x5236,0x3002
$copyFailedText = Get-UiText 0x590D,0x5236,0x5931,0x8D25,0xFF0C,0x8BF7,0x7A0D,0x540E,0x91CD,0x8BD5,0x3002
$openFailedText = Get-UiText 0x624B,0x673A,0x9875,0x9762,0x6682,0x65F6,0x8FD8,0x6CA1,0x51C6,0x5907,0x597D,0x3002
$settingsFailedText = Get-UiText 0x8BBE,0x7F6E,0x7A97,0x53E3,0x6682,0x65F6,0x6253,0x4E0D,0x5F00,0x3002
$readyText = Get-UiText 0x5DF2,0x7ECF,0x5728,0x540E,0x53F0,0x5F85,0x547D,0x3002,0x53CC,0x51FB,0x6258,0x76D8,0x56FE,0x6807,0x53EF,0x4EE5,0x6253,0x5F00,0x626B,0x7801,0x9875,0x3002

$notifyIcon = $null
$popupWindow = $null
$context = $null

try {
    $context = New-Object System.Windows.Forms.ApplicationContext

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="212"
        Height="262"
        WindowStyle="None"
        ResizeMode="NoResize"
        ShowInTaskbar="False"
        ShowActivated="True"
        Topmost="True"
        Focusable="True"
        Background="Transparent"
        AllowsTransparency="True"
        WindowStartupLocation="Manual"
        UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="MenuButtonStyle" TargetType="Button">
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="13,0,0,0"/>
      <Setter Property="FontFamily" Value="Microsoft YaHei UI"/>
      <Setter Property="FontSize" Value="11.8"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="OuterShadow"
                      Background="{TemplateBinding Background}"
                      CornerRadius="12">
                <Border.Effect>
                  <DropShadowEffect BlurRadius="9"
                                    ShadowDepth="3"
                                    Direction="270"
                                    Opacity="0.15"
                                    Color="#97A6B4"/>
                </Border.Effect>
              </Border>
              <Border CornerRadius="12"
                      BorderBrush="#F3F8FD"
                      BorderThickness="1"
                      Margin="0.5,0.5,0,0"
                      Opacity="0.9"/>
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Background="#EAF1F8"
          BorderBrush="#F7FBFF"
          BorderThickness="1"
          CornerRadius="16"
          Padding="15"
          SnapsToDevicePixels="True">
    <Border.Effect>
      <DropShadowEffect BlurRadius="16"
                        ShadowDepth="0"
                        Opacity="0.18"
                        Color="#7E8FA2"/>
    </Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <StackPanel Grid.Row="0">
        <Border Width="54"
                Height="4"
                Background="#D08A35"
                CornerRadius="4"
                HorizontalAlignment="Left"
                Margin="0,0,0,10"/>
        <TextBlock x:Name="TitleText"
                   FontFamily="Microsoft YaHei UI"
                   FontSize="14.4"
                   FontWeight="Bold"
                   Foreground="#22364C"/>
        <TextBlock x:Name="SubtitleText"
                   Margin="0,4,0,0"
                   FontFamily="Microsoft YaHei UI"
                   FontSize="10.2"
                   Foreground="#728194"/>
      </StackPanel>
      <StackPanel Grid.Row="1" Margin="0,12,0,0">
        <Button x:Name="QrButton" Style="{StaticResource MenuButtonStyle}"/>
        <Button x:Name="MobileButton" Style="{StaticResource MenuButtonStyle}"/>
        <Button x:Name="CopyButton" Style="{StaticResource MenuButtonStyle}"/>
        <Button x:Name="SettingsButton" Style="{StaticResource MenuButtonStyle}" Margin="0,0,0,8"/>
      </StackPanel>
      <StackPanel Grid.Row="2" Margin="0,2,0,0">
        <Border Height="1"
                Background="#D9E1EA"
                Margin="2,0,2,10"/>
        <Button x:Name="ExitButton" Style="{StaticResource MenuButtonStyle}" Margin="0,0,0,0"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $popupWindow = [System.Windows.Markup.XamlReader]::Load($reader)
    [System.Windows.Forms.Integration.ElementHost]::EnableModelessKeyboardInterop($popupWindow)

    $titleLabel = [System.Windows.Controls.TextBlock]$popupWindow.FindName("TitleText")
    $subtitleLabel = [System.Windows.Controls.TextBlock]$popupWindow.FindName("SubtitleText")
    $openQrButton = [System.Windows.Controls.Button]$popupWindow.FindName("QrButton")
    $openMobileButton = [System.Windows.Controls.Button]$popupWindow.FindName("MobileButton")
    $copyButton = [System.Windows.Controls.Button]$popupWindow.FindName("CopyButton")
    $settingsButton = [System.Windows.Controls.Button]$popupWindow.FindName("SettingsButton")
    $exitButton = [System.Windows.Controls.Button]$popupWindow.FindName("ExitButton")

    $titleLabel.Text = $titleText
    $subtitleLabel.Text = $subtitleText
    Set-ButtonPalette -Button $openQrButton -BaseColor "#F4E5CF" -HoverColor "#ECD8B6" -TextColor "#C87720"
    Set-ButtonPalette -Button $openMobileButton -BaseColor "#EAF1F8" -HoverColor "#DEE8F3" -TextColor "#244A73"
    Set-ButtonPalette -Button $copyButton -BaseColor "#EAF1F8" -HoverColor "#DEE8F3" -TextColor "#244A73"
    Set-ButtonPalette -Button $settingsButton -BaseColor "#EAF1F8" -HoverColor "#DEE8F3" -TextColor "#244A73"
    Set-ButtonPalette -Button $exitButton -BaseColor "#F3E6E6" -HoverColor "#EBD7D6" -TextColor "#C55A51"
    Set-MenuButtonContent -Button $openQrButton -Label $openQrLabel
    Set-MenuButtonContent -Button $openMobileButton -Label $openMobileLabel
    Set-MenuButtonContent -Button $copyButton -Label $copyLabel
    Set-MenuButtonContent -Button $settingsButton -Label $settingsLabel
    Set-MenuButtonContent -Button $exitButton -Label $exitLabel

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    if (Test-Path $IconPath) {
        try {
            $notifyIcon.Icon = New-Object System.Drawing.Icon($IconPath)
        } catch {
        }
    }
    $notifyIcon.Text = $titleText
    $notifyIcon.Visible = $true

    function Hide-CustomMenu {
        if ($popupWindow -and $script:PopupVisible) {
            $script:PopupVisible = $false
            $script:PopupShownAt = $null
            $popupWindow.Hide()
        }
    }

    function Update-MenuAvailability {
        $preferredUrl = Get-PreferredMobileUrl
        $hasUrl = -not [string]::IsNullOrWhiteSpace($preferredUrl)
        Set-ButtonEnabledState -Button $openMobileButton -Enabled $hasUrl
        Set-ButtonEnabledState -Button $copyButton -Enabled $hasUrl

        $updateStatus = Read-UpdateStatus
        $buildInfo = Read-BuildInfo
        $currentVersion = ""
        if ($buildInfo) {
            $currentVersion = [string]$buildInfo.appVersion
            if ([string]::IsNullOrWhiteSpace($currentVersion)) {
                $currentVersion = [string]$buildInfo.gitCommit
            }
        }
        $showUpdateDot = $false
        if ($updateStatus -and ([string]$updateStatus.currentVersion).Trim() -eq $currentVersion -and [bool]$updateStatus.hasUpdate) {
            $showUpdateDot = $true
        }
        Set-MenuButtonContent -Button $settingsButton -Label $settingsLabel -ShowDot $showUpdateDot
    }

    function Show-CustomMenu {
        Update-MenuAvailability
        $location = Resolve-MenuLocation -Width $popupWindow.Width -Height $popupWindow.Height
        $popupWindow.Left = [Math]::Round($location.X)
        $popupWindow.Top = [Math]::Round($location.Y)
        $script:PopupVisible = $true
        $script:PopupShownAt = Get-Date
        if (-not $popupWindow.IsVisible) {
            $popupWindow.Show()
        }
        $popupWindow.Topmost = $true
        $popupWindow.Activate() | Out-Null
        $popupWindow.Focus() | Out-Null
        Write-Log "Tray menu opened."
    }

    function Toggle-CustomMenu {
        if ($script:PopupVisible) {
            Hide-CustomMenu
        } else {
            Show-CustomMenu
        }
    }

    $openQrAction = {
        Hide-CustomMenu
        $target = if (Test-Path $QrHtmlFile) { $QrHtmlFile } else { "" }
        if (-not (Open-Target -Target $target)) {
            Show-Balloon -NotifyIcon $notifyIcon -Title $titleText -Text $qrOpenFailedText -Icon ([System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }

    $openMobileAction = {
        Hide-CustomMenu
        $target = Get-PreferredMobileUrl
        if (-not (Open-Target -Target $target)) {
            Show-Balloon -NotifyIcon $notifyIcon -Title $titleText -Text $openFailedText -Icon ([System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }

    $copyAction = {
        Hide-CustomMenu
        $url = Get-PreferredMobileUrl
        if ([string]::IsNullOrWhiteSpace($url)) {
            Show-Balloon -NotifyIcon $notifyIcon -Title $titleText -Text $pendingText -Icon ([System.Windows.Forms.ToolTipIcon]::Warning)
            return
        }

        try {
            Set-Clipboard -Value $url
            Show-Balloon -NotifyIcon $notifyIcon -Title $titleText -Text $copiedText -Icon ([System.Windows.Forms.ToolTipIcon]::Info)
        } catch {
            Show-Balloon -NotifyIcon $notifyIcon -Title $titleText -Text $copyFailedText -Icon ([System.Windows.Forms.ToolTipIcon]::Error)
        }
    }

    $settingsAction = {
        Hide-CustomMenu
        if (-not (Test-Path $SettingsWindowScript)) {
            Show-Balloon -NotifyIcon $notifyIcon -Title $titleText -Text $settingsFailedText -Icon ([System.Windows.Forms.ToolTipIcon]::Warning)
            return
        }

        try {
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.ProcessId -ne $PID -and
                    $_.CommandLine -and
                    $_.CommandLine -like '*portable-settings-window.ps1*'
                } |
                ForEach-Object {
                    try {
                        Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
                    } catch {
                    }
                }

            Start-Process -FilePath (Get-Command powershell.exe).Source `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $SettingsWindowScript) `
                -WorkingDirectory $PackageDir `
                -WindowStyle Hidden | Out-Null
        } catch {
            Show-Balloon -NotifyIcon $notifyIcon -Title $titleText -Text $settingsFailedText -Icon ([System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }

    $exitAction = {
        Hide-CustomMenu
        try {
            if (Test-Path $StopScript) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StopScript -Silent
            }
        } catch {
            Write-Log ("Stop script failed: " + $_.Exception.Message)
        } finally {
            $script:AllowWindowClose = $true
            if ($popupWindow) {
                $popupWindow.Close()
            }
            $context.ExitThread()
        }
    }

    $openQrButton.Add_Click($openQrAction)
    $openMobileButton.Add_Click($openMobileAction)
    $copyButton.Add_Click($copyAction)
    $settingsButton.Add_Click($settingsAction)
    $exitButton.Add_Click($exitAction)

    $notifyIcon.Add_MouseClick({
        param($sender, $e)

        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            Toggle-CustomMenu
            return
        }

        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $openQrAction.Invoke()
        }
    })

    $notifyIcon.Add_DoubleClick({
        Toggle-CustomMenu
    })

    $updateTimer = New-Object System.Windows.Forms.Timer
    $updateTimer.Interval = 5000
    $updateTimer.Add_Tick({
        Update-MenuAvailability
    })
    $updateTimer.Start()
    Start-BackgroundUpdateCheck

    $popupWindow.Add_Deactivated({
        if ($script:PopupShownAt) {
            $elapsed = ((Get-Date) - $script:PopupShownAt).TotalMilliseconds
            if ($elapsed -lt 450) {
                return
            }
        }

        Hide-CustomMenu
    })

    $popupWindow.Add_PreviewKeyDown({
        param($sender, $e)

        if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
            Hide-CustomMenu
        }
    })

    $popupWindow.Add_Closing({
        param($sender, $e)

        if (-not $script:AllowWindowClose) {
            $e.Cancel = $true
            Hide-CustomMenu
        }
    })

    Show-Balloon -NotifyIcon $notifyIcon -Title $titleText -Text $readyText -Icon ([System.Windows.Forms.ToolTipIcon]::Info)
    Write-Log "Tray started."
    [System.Windows.Forms.Application]::Run($context)
} catch {
    Write-Log ("Tray fatal error: " + $_.Exception.ToString())
    throw
} finally {
    if ($notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
    if ($popupWindow) {
        try {
            $script:AllowWindowClose = $true
            $popupWindow.Close()
        } catch {
        }
    }
    Exit-TrayMutex
}
