param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDir = Split-Path -Parent $BaseDir
$LogsDir = Join-Path $PackageDir "logs"
$RuntimeConfigFile = Join-Path $BaseDir "runtime-config.json"
$BuildInfoFile = Join-Path $BaseDir "build-info.json"
$UpdateStatusFile = Join-Path $LogsDir "update-status.json"
$SettingsWindowScript = Join-Path $BaseDir "portable-settings-window.ps1"
$UpdateCheckScript = Join-Path $BaseDir "portable-check-update.ps1"
$StartupLog = Join-Path $LogsDir "startup.log"
$ServerRuntimeLog = Join-Path $BaseDir "logs\server-runtime.log"
$IconPath = Join-Path $BaseDir "assets\voice-sync-icon.ico"
$HeaderIconPath = Join-Path $BaseDir "assets\voice-sync-icon.png"
$LanQrPngFile = Join-Path $PackageDir "qr-lan.png"
$OnlineQrPngFile = Join-Path $PackageDir "qr-online.png"

function New-Brush {
    param([string]$Color)

    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Read-RuntimeConfig {
    if (-not (Test-Path $RuntimeConfigFile)) {
        return $null
    }

    try {
        return Get-Content -Raw -LiteralPath $RuntimeConfigFile -Encoding UTF8 | ConvertFrom-Json
    } catch {
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
        return $null
    }
}

function Start-UpdateCheck {
    if (-not (Test-Path $UpdateCheckScript)) {
        return
    }

    Start-Process -FilePath (Get-Command powershell.exe).Source `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $UpdateCheckScript) `
        -WorkingDirectory $PackageDir `
        -WindowStyle Hidden | Out-Null
}

function Test-HasPendingUpdate {
    $buildInfo = Read-BuildInfo
    $currentVersion = ""
    if ($buildInfo) {
        $currentVersion = [string]$buildInfo.appVersion
        if ([string]::IsNullOrWhiteSpace($currentVersion)) {
            $currentVersion = [string]$buildInfo.gitCommit
        }
    }

    if ([string]::IsNullOrWhiteSpace($currentVersion)) {
        return $false
    }

    $updateStatus = Read-UpdateStatus
    if (-not $updateStatus) {
        return $false
    }

    return (([string]$updateStatus.currentVersion).Trim() -eq $currentVersion -and [bool]$updateStatus.hasUpdate)
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

function Get-SessionStartTime {
    if (-not (Test-Path $StartupLog)) {
        return (Get-Date).AddMinutes(-10)
    }

    $lines = @(Get-Content -LiteralPath $StartupLog -Tail 120 -ErrorAction SilentlyContinue)
    $lines = [System.Linq.Enumerable]::Reverse([string[]]$lines)

    foreach ($line in $lines) {
        if ($line -match '^\[(?<stamp>[^\]]+)\] .*portable-start\.ps1 started') {
            try {
                return [datetime]::ParseExact($matches['stamp'], "yyyy-MM-dd HH:mm:ss", $null)
            } catch {
            }
        }
    }

    return (Get-Date).AddMinutes(-10)
}

function Get-HostFromUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ""
    }

    try {
        return ([Uri]$Url).Host
    } catch {
        return ""
    }
}

function Get-MobilePresenceState {
    $config = Read-RuntimeConfig
    $sessionStart = Get-SessionStartTime
    $localHosts = @(
        "127.0.0.1",
        "::1",
        (Get-HostFromUrl (Get-ConfigValue -Config $config -PropertyName "directUrl")),
        (Get-HostFromUrl (Get-ConfigValue -Config $config -PropertyName "directIpUrl"))
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    $mobilePeers = @{}
    if (-not (Test-Path $ServerRuntimeLog)) {
        return [pscustomobject]@{
            Connected = $false
            RemoteList = ""
        }
    }

    foreach ($line in @(Get-Content -LiteralPath $ServerRuntimeLog -Tail 240 -ErrorAction SilentlyContinue)) {
        if ($line -notmatch '^\[(?<stamp>[^\]]+)\]\s+(?<message>.+)$') {
            continue
        }

        try {
            $stamp = [datetime]::ParseExact($matches['stamp'], "yyyy-MM-dd HH:mm:ss", $null)
        } catch {
            continue
        }

        if ($stamp -lt $sessionStart) {
            continue
        }

        $message = [string]$matches['message']
        if ($message -match "register ok: \('([^']+)',\s*\d+\) -> mobile") {
            $ip = [string]$matches[1]
            if ($localHosts -notcontains $ip) {
                $mobilePeers[$ip] = $stamp
            }
            continue
        }

        if ($message -match "client disconnected: \('([^']+)',\s*\d+\)") {
            $ip = [string]$matches[1]
            if ($mobilePeers.ContainsKey($ip)) {
                $mobilePeers.Remove($ip)
            }
        }
    }

    return [pscustomobject]@{
        Connected = ($mobilePeers.Count -gt 0)
        RemoteList = (($mobilePeers.Keys | Sort-Object) -join " / ")
    }
}

function Load-BitmapImage {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.UriSource = [Uri]((Resolve-Path -LiteralPath $Path).Path)
        $bitmap.EndInit()
        $bitmap.Freeze()
        return $bitmap
    } catch {
        return $null
    }
}

function Set-CardUi {
    param(
        [System.Windows.Controls.Border]$Card,
        [System.Windows.Controls.TextBlock]$BadgeText,
        [System.Windows.Controls.TextBlock]$TitleText,
        [System.Windows.Controls.TextBlock]$SubtitleText,
        [System.Windows.Controls.TextBlock]$AddressText,
        [System.Windows.Controls.Image]$ImageControl,
        [System.Windows.Controls.TextBlock]$PlaceholderText,
        [System.Windows.Controls.Button]$CopyButton,
        [string]$Title,
        [string]$Subtitle,
        [string]$Url,
        [string]$ImagePath,
        [bool]$Featured,
        [string]$BadgeLabel,
        [string]$AccentColor
    )

    if ($AccentColor -eq "#4DB57C") {
        $softColor = "#E7F3EC"
        $textColor = "#278659"
    } elseif ($AccentColor -eq "#35567F") {
        $softColor = "#EAF1F8"
        $textColor = "#244A73"
    } else {
        $softColor = "#F4E5CF"
        $textColor = "#C87720"
    }

    $TitleText.Text = $Title
    $SubtitleText.Text = $Subtitle
    $BadgeText.Text = $BadgeLabel
    $BadgeText.Foreground = New-Brush $textColor
    $BadgeText.Parent.Background = New-Brush $softColor

    $Card.BorderBrush = New-Brush "#D5E0EC"
    $Card.Background = if ($Featured) { New-Brush "#EEF4FA" } else { New-Brush "#EEF3F9" }
    $CopyButton.Background = if ($Featured) { New-Brush "#F4E5CF" } else { New-Brush "#EAF1F8" }
    $CopyButton.Foreground = if ($Featured) { New-Brush "#C87720" } else { New-Brush "#244A73" }

    if ([string]::IsNullOrWhiteSpace($Url)) {
        $AddressText.Text = "当前还没有可用地址"
        $AddressText.Foreground = New-Brush "#7A8898"
        $CopyButton.IsEnabled = $false
        $CopyButton.Opacity = 0.56
    } else {
        $AddressText.Text = $Url
        $AddressText.Foreground = New-Brush "#233446"
        $CopyButton.IsEnabled = $true
        $CopyButton.Opacity = 1
    }

    $bitmap = Load-BitmapImage -Path $ImagePath
    if ($bitmap) {
        $ImageControl.Source = $bitmap
        $ImageControl.Visibility = "Visible"
        $PlaceholderText.Visibility = "Collapsed"
    } else {
        $ImageControl.Source = $null
        $ImageControl.Visibility = "Collapsed"
        $PlaceholderText.Visibility = "Visible"
    }
}

function Set-StatusUi {
    param(
        [bool]$Connected,
        [string]$RemoteList
    )

    if ($Connected) {
        $script:StatusPill.Background = New-Brush "#E7F3EC"
        $script:StatusDot.Fill = New-Brush "#4DB57C"
        $script:StatusText.Text = "已连接"
        $script:StatusText.Foreground = New-Brush "#278659"
        $script:StatusHintText.Text = "已连接，现在回电脑点中输入框就能直接输入。"
        return
    }

    $script:StatusPill.Background = New-Brush "#E7EDF4"
    $script:StatusDot.Fill = New-Brush "#7E8D9D"
    $script:StatusText.Text = "未连接"
    $script:StatusText.Foreground = New-Brush "#4E6278"
    $script:StatusHintText.Text = "扫码后，这里会自动变成已连接。"
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="语音输入同步 · 扫码连接"
        Width="1088"
        Height="760"
        MinWidth="980"
        MinHeight="710"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        ResizeMode="NoResize"
        Background="Transparent"
        AllowsTransparency="True"
        ShowInTaskbar="False"
        FontFamily="Microsoft YaHei UI"
        SnapsToDevicePixels="True"
        UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="TitleButtonStyle" TargetType="Button">
            <Setter Property="Width" Value="38"/>
            <Setter Property="Height" Value="38"/>
            <Setter Property="Margin" Value="0,0,0,0"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Foreground" Value="#395576"/>
            <Setter Property="Background" Value="#EAF1F8"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="10">
                            <Border.Effect>
                                <DropShadowEffect BlurRadius="8"
                                                  ShadowDepth="3"
                                                  Direction="270"
                                                  Opacity="0.14"
                                                  Color="#9FB1C4"/>
                            </Border.Effect>
                            <ContentPresenter HorizontalAlignment="Center"
                                              VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="GuideCardStyle" TargetType="Border">
            <Setter Property="Padding" Value="14,11"/>
            <Setter Property="Margin" Value="0,0,14,0"/>
            <Setter Property="CornerRadius" Value="12"/>
            <Setter Property="Background" Value="#EDF3F9"/>
            <Setter Property="BorderBrush" Value="#D7E2EE"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
        <Style x:Key="CopyButtonStyle" TargetType="Button">
            <Setter Property="Height" Value="42"/>
            <Setter Property="Margin" Value="0,12,0,0"/>
            <Setter Property="Padding" Value="18,0"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="HorizontalAlignment" Value="Left"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="12">
                            <Border.Effect>
                                <DropShadowEffect BlurRadius="10"
                                                  ShadowDepth="3"
                                                  Direction="270"
                                                  Opacity="0.16"
                                                  Color="#A5B2BF"/>
                            </Border.Effect>
                            <ContentPresenter Margin="{TemplateBinding Padding}"
                                              HorizontalAlignment="Center"
                                              VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid Background="Transparent">
        <Border Margin="12"
                CornerRadius="14"
                BorderBrush="#F7FAFD"
                BorderThickness="1">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#EAF1F8" Offset="0"/>
                    <GradientStop Color="#DCE5F0" Offset="1"/>
                </LinearGradientBrush>
            </Border.Background>
            <Border.Effect>
                <DropShadowEffect BlurRadius="20" ShadowDepth="6" Direction="315" Color="#99A8B8" Opacity="0.2"/>
            </Border.Effect>

            <Grid Margin="16">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="14"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <Border x:Name="HeaderShell"
                        Grid.Row="0"
                        CornerRadius="12"
                        Background="#EEF4FA"
                        BorderBrush="#F9FBFE"
                        BorderThickness="1"
                        Padding="14,10">
                    <Grid x:Name="TitleBar" Height="40">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Border Width="40"
                                Height="40"
                                CornerRadius="10"
                                Background="#EFF4FA">
                            <Border.Effect>
                                <DropShadowEffect BlurRadius="8"
                                                  ShadowDepth="3"
                                                  Direction="270"
                                                  Opacity="0.13"
                                                  Color="#A5B4C2"/>
                            </Border.Effect>
                            <Image x:Name="HeaderIcon"
                                   Width="22"
                                   Height="22"
                                   Stretch="Uniform"/>
                        </Border>
                        <StackPanel Margin="12,0,0,0">
                            <TextBlock Text="语音输入同步"
                                       FontSize="18"
                                       FontWeight="Bold"
                                       Foreground="#213244"/>
                            <TextBlock Text="扫码连接"
                                       Margin="0,2,0,0"
                                       FontSize="12.5"
                                       Foreground="#778597"/>
                        </StackPanel>
                    </StackPanel>

                    <StackPanel Grid.Column="1"
                                Orientation="Horizontal"
                                VerticalAlignment="Center">
                        <Grid Width="38"
                              Height="38">
                            <Button x:Name="SettingsButton"
                                    Style="{StaticResource TitleButtonStyle}"
                                    Background="#EAF1F8"
                                    Foreground="#2E4A68"
                                    ToolTip="打开设置"
                                    Content="&#xE713;"/>
                            <Ellipse x:Name="SettingsDot"
                                     Width="9"
                                     Height="9"
                                     Fill="#4DB57C"
                                     Stroke="#EEF4FA"
                                     StrokeThickness="1.2"
                                     HorizontalAlignment="Right"
                                     VerticalAlignment="Top"
                                     Margin="0,2,2,0"
                                     Visibility="Collapsed"/>
                        </Grid>
                        <Button x:Name="HideWindowButton"
                                Margin="10,0,0,0"
                                Style="{StaticResource TitleButtonStyle}"
                                Content="&#xE921;"/>
                        <Button x:Name="CloseWindowButton"
                                Margin="10,0,0,0"
                                Style="{StaticResource TitleButtonStyle}"
                                Background="#F4E5CF"
                                Foreground="#C87720"
                                Content="&#xE8BB;"/>
                    </StackPanel>
                    </Grid>
                </Border>

                <Border x:Name="GuideShell"
                        Grid.Row="2"
                        CornerRadius="12"
                        Background="#EEF4FA"
                        BorderBrush="#F8FBFF"
                        BorderThickness="1"
                        Padding="24,20">
                    <Border.Effect>
                        <DropShadowEffect BlurRadius="12"
                                          ShadowDepth="4"
                                          Direction="270"
                                          Color="#B1BFCC"
                                          Opacity="0.11"/>
                    </Border.Effect>
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="250"/>
                        </Grid.ColumnDefinitions>

                        <StackPanel Grid.Row="0" Grid.Column="0">
                            <Border HorizontalAlignment="Left"
                                    Padding="12,6"
                                    CornerRadius="999"
                                    Background="#F4E5CF">
                                <TextBlock Text="语音输入同步 · 手机扫码连接"
                                           FontSize="13"
                                           FontWeight="Bold"
                                           Foreground="#C87720"/>
                            </Border>
                            <TextBlock Text="先扫局域网，连上后回电脑点中输入框。"
                                       Margin="0,14,0,0"
                                       FontSize="28"
                                       FontWeight="Bold"
                                       Foreground="#213244"
                                       TextWrapping="Wrap"/>
                            <TextBlock Text="上面先试局域网直连，下面保留互联网备用。连上后回电脑点中真正要输入的位置。"
                                       Margin="0,10,0,0"
                                       FontSize="15"
                                       Foreground="#6B7D92"
                                       TextWrapping="Wrap"/>
                        </StackPanel>

                        <StackPanel Grid.Row="0"
                                    Grid.Column="1"
                                    HorizontalAlignment="Right">
                            <Border x:Name="StatusPill"
                                    Padding="14,8"
                                    CornerRadius="999"
                                    Background="#E7EDF4"
                                    HorizontalAlignment="Right">
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="StatusDot"
                                             Width="8"
                                             Height="8"
                                             Margin="0,0,8,0"
                                             VerticalAlignment="Center"
                                             Fill="#7E8D9D"/>
                                    <TextBlock x:Name="StatusText"
                                               Text="未连接"
                                               FontSize="14"
                                               FontWeight="Bold"
                                               Foreground="#4E6278"/>
                                </StackPanel>
                            </Border>
                            <TextBlock x:Name="StatusHintText"
                                       Width="230"
                                       Margin="0,9,0,0"
                                       FontSize="12.8"
                                       Foreground="#6B7A8B"
                                       TextAlignment="Right"
                                       TextWrapping="Wrap"/>
                        </StackPanel>

                        <UniformGrid Grid.Row="1"
                                     Grid.ColumnSpan="2"
                                     Margin="0,18,0,0"
                                     Columns="3">
                            <Border Style="{StaticResource GuideCardStyle}">
                                <TextBlock Text="1 先扫局域网"
                                           FontSize="14"
                                           FontWeight="SemiBold"
                                           Foreground="#2E4A68"/>
                            </Border>
                            <Border Style="{StaticResource GuideCardStyle}">
                                <TextBlock Text="2 等这里变已连接"
                                           FontSize="14"
                                           FontWeight="SemiBold"
                                           Foreground="#2E4A68"/>
                            </Border>
                            <Border Margin="0"
                                    Style="{StaticResource GuideCardStyle}">
                                <TextBlock Text="3 回电脑点输入框"
                                           FontSize="14"
                                           FontWeight="SemiBold"
                                           Foreground="#2E4A68"/>
                            </Border>
                        </UniformGrid>
                    </Grid>
                </Border>

                <Grid Grid.Row="3" Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="16"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <Border x:Name="LanCard"
                            Grid.Column="0"
                            Padding="22"
                            CornerRadius="14"
                            Background="#EEF4FA"
                            BorderBrush="#D5E0EC"
                            BorderThickness="1">
                        <Border.Effect>
                            <DropShadowEffect BlurRadius="10"
                                              ShadowDepth="3"
                                              Direction="270"
                                              Opacity="0.12"
                                              Color="#A5B2BF"/>
                        </Border.Effect>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="216"/>
                                <ColumnDefinition Width="22"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <StackPanel Grid.Column="0">
                            <Border Background="#F5E7D1"
                                    CornerRadius="10"
                                    Padding="12,6"
                                    HorizontalAlignment="Left">
                                <TextBlock x:Name="LanBadgeText"
                                           Text="推荐地址"
                                           FontSize="13"
                                           FontWeight="Bold"
                                           Foreground="#C87720"/>
                            </Border>

                            <Border
                                     Margin="0,16,0,0"
                                     Padding="16"
                                     Height="216"
                                     CornerRadius="14"
                                     Background="#FFFFFF"
                                     BorderBrush="#F7FAFD"
                                     BorderThickness="1">
                                <Border.Effect>
                                    <DropShadowEffect BlurRadius="10"
                                                      ShadowDepth="3"
                                                      Direction="270"
                                                      Opacity="0.12"
                                                      Color="#B4C1CD"/>
                                </Border.Effect>
                                <Grid>
                                    <Image x:Name="LanImage"
                                           Stretch="Uniform"
                                           Visibility="Collapsed"/>
                                    <TextBlock x:Name="LanPlaceholder"
                                               Text="正在准备局域网二维码"
                                               HorizontalAlignment="Center"
                                               VerticalAlignment="Center"
                                               FontSize="18"
                                               Foreground="#8190A0"
                                               TextWrapping="Wrap"/>
                                </Grid>
                            </Border>
                            </StackPanel>

                            <StackPanel Grid.Column="2">
                                <TextBlock x:Name="LanTitle"
                                           Text="局域网直连"
                                           FontSize="27"
                                           FontWeight="Bold"
                                           Foreground="#213244"/>
                                <TextBlock x:Name="LanSubtitle"
                                           Text="自己手机热点 / 家里 Wi-Fi 时优先试这个"
                                           Margin="0,10,0,0"
                                           FontSize="15"
                                           Foreground="#647384"
                                           TextWrapping="Wrap"/>
                                <Border Margin="0,16,0,0"
                                        Padding="16,14"
                                        CornerRadius="12"
                                        Background="#FFFFFF"
                                        BorderBrush="#F4F7FB"
                                        BorderThickness="1">
                                    <Border.Effect>
                                        <DropShadowEffect BlurRadius="9"
                                                          ShadowDepth="3"
                                                          Direction="270"
                                                          Opacity="0.10"
                                                          Color="#BAC6D2"/>
                                    </Border.Effect>
                                    <TextBlock x:Name="LanAddress"
                                               FontSize="15"
                                               Foreground="#233446"
                                               TextWrapping="Wrap"/>
                                </Border>
                                <Button x:Name="LanCopyButton"
                                        Content="复制局域网地址"
                                        Style="{StaticResource CopyButtonStyle}"
                                        Background="#F4E5CF"
                                        Foreground="#C87720"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <Border x:Name="OnlineCard"
                            Grid.Column="2"
                            Padding="22"
                            CornerRadius="14"
                            Background="#EEF4FA"
                            BorderBrush="#D5E0EC"
                            BorderThickness="1">
                        <Border.Effect>
                            <DropShadowEffect BlurRadius="10"
                                              ShadowDepth="3"
                                              Direction="270"
                                              Opacity="0.12"
                                              Color="#A5B2BF"/>
                        </Border.Effect>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="216"/>
                                <ColumnDefinition Width="22"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <StackPanel Grid.Column="0">
                            <Border Background="#EAF1F8"
                                    CornerRadius="10"
                                    Padding="12,6"
                                    HorizontalAlignment="Left">
                                <TextBlock x:Name="OnlineBadgeText"
                                           Text="互联网备用"
                                           FontSize="13"
                                           FontWeight="Bold"
                                           Foreground="#244A73"/>
                            </Border>

                            <Border
                                     Margin="0,16,0,0"
                                     Padding="16"
                                     Height="216"
                                     CornerRadius="14"
                                     Background="#FFFFFF"
                                     BorderBrush="#F7FAFD"
                                     BorderThickness="1">
                                <Border.Effect>
                                    <DropShadowEffect BlurRadius="10"
                                                      ShadowDepth="3"
                                                      Direction="270"
                                                      Opacity="0.12"
                                                      Color="#B4C1CD"/>
                                </Border.Effect>
                                <Grid>
                                    <Image x:Name="OnlineImage"
                                           Stretch="Uniform"
                                           Visibility="Collapsed"/>
                                    <TextBlock x:Name="OnlinePlaceholder"
                                               Text="当前还没有互联网二维码"
                                               HorizontalAlignment="Center"
                                               VerticalAlignment="Center"
                                               FontSize="18"
                                               Foreground="#8190A0"
                                               TextWrapping="Wrap"/>
                                </Grid>
                            </Border>
                            </StackPanel>

                            <StackPanel Grid.Column="2">
                                <TextBlock x:Name="OnlineTitle"
                                           Text="互联网地址"
                                           FontSize="27"
                                           FontWeight="Bold"
                                           Foreground="#213244"/>
                                <TextBlock x:Name="OnlineSubtitle"
                                           Text="局域网打不开时，再试这个互联网地址"
                                           Margin="0,10,0,0"
                                           FontSize="15"
                                           Foreground="#647384"
                                           TextWrapping="Wrap"/>
                                <Border Margin="0,16,0,0"
                                        Padding="16,14"
                                        CornerRadius="12"
                                        Background="#FFFFFF"
                                        BorderBrush="#F4F7FB"
                                        BorderThickness="1">
                                    <Border.Effect>
                                        <DropShadowEffect BlurRadius="9"
                                                          ShadowDepth="3"
                                                          Direction="270"
                                                          Opacity="0.10"
                                                          Color="#BAC6D2"/>
                                    </Border.Effect>
                                    <TextBlock x:Name="OnlineAddress"
                                               FontSize="15"
                                               Foreground="#233446"
                                               TextWrapping="Wrap"/>
                                </Border>
                                <Button x:Name="OnlineCopyButton"
                                        Content="复制互联网地址"
                                        Style="{StaticResource CopyButtonStyle}"
                                        Background="#EAF1F8"
                                        Foreground="#244A73"/>
                            </StackPanel>
                        </Grid>
                    </Border>
                </Grid>
            </Grid>
        </Border>

        <Border x:Name="CopyToast"
                HorizontalAlignment="Center"
                VerticalAlignment="Bottom"
                Margin="0,0,0,24"
                Padding="18,12"
                Background="#EAF1F8"
                BorderBrush="#F8FBFF"
                BorderThickness="1"
                CornerRadius="999"
                Visibility="Collapsed"
                Opacity="0.96">
            <Border.Effect>
                <DropShadowEffect BlurRadius="12"
                                  ShadowDepth="4"
                                  Direction="270"
                                  Opacity="0.18"
                                  Color="#9FB0C1"/>
            </Border.Effect>
            <TextBlock x:Name="CopyToastText"
                       Text="已复制"
                       FontSize="14"
                       FontWeight="Bold"
                       Foreground="#244A73"/>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

if (Test-Path $IconPath) {
    try {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$IconPath)
    } catch {
    }
}

$titleBar = $window.FindName("TitleBar")
$headerShell = $window.FindName("HeaderShell")
$guideShell = $window.FindName("GuideShell")
$headerIcon = $window.FindName("HeaderIcon")
$settingsButton = $window.FindName("SettingsButton")
$settingsDot = $window.FindName("SettingsDot")
$hideWindowButton = $window.FindName("HideWindowButton")
$closeWindowButton = $window.FindName("CloseWindowButton")
$script:StatusPill = $window.FindName("StatusPill")
$script:StatusDot = $window.FindName("StatusDot")
$script:StatusText = $window.FindName("StatusText")
$script:StatusHintText = $window.FindName("StatusHintText")
$lanCard = $window.FindName("LanCard")
$lanBadgeText = $window.FindName("LanBadgeText")
$lanTitle = $window.FindName("LanTitle")
$lanSubtitle = $window.FindName("LanSubtitle")
$lanAddress = $window.FindName("LanAddress")
$lanImage = $window.FindName("LanImage")
$lanPlaceholder = $window.FindName("LanPlaceholder")
$lanCopyButton = $window.FindName("LanCopyButton")
$copyToast = $window.FindName("CopyToast")
$copyToastText = $window.FindName("CopyToastText")
$onlineCard = $window.FindName("OnlineCard")
$onlineBadgeText = $window.FindName("OnlineBadgeText")
$onlineTitle = $window.FindName("OnlineTitle")
$onlineSubtitle = $window.FindName("OnlineSubtitle")
$onlineAddress = $window.FindName("OnlineAddress")
$onlineImage = $window.FindName("OnlineImage")
$onlinePlaceholder = $window.FindName("OnlinePlaceholder")
$onlineCopyButton = $window.FindName("OnlineCopyButton")

$copyToastTimer = New-Object System.Windows.Threading.DispatcherTimer
$copyToastTimer.Interval = [TimeSpan]::FromSeconds(1.4)
$copyToastTimer.Add_Tick({
    $copyToastTimer.Stop()
    $copyToast.Visibility = "Collapsed"
})

if (Test-Path $HeaderIconPath) {
    $headerBitmap = Load-BitmapImage -Path $HeaderIconPath
    if ($headerBitmap) {
        $headerIcon.Source = $headerBitmap
    }
}

function Show-CopyToast {
    param([string]$Message)

    $copyToastText.Text = $Message
    $copyToast.Visibility = "Visible"
    $copyToastTimer.Stop()
    $copyToastTimer.Start()
}

function Test-IsInteractiveElement {
    param([object]$Element)

    $current = $Element
    while ($current) {
        if ($current -is [System.Windows.Controls.Primitives.ButtonBase]) {
            return $true
        }
        if ($current -is [System.Windows.Controls.TextBoxBase]) {
            return $true
        }
        if ($current -is [System.Windows.Controls.PasswordBox]) {
            return $true
        }

        try {
            $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
        } catch {
            break
        }
    }

    return $false
}

function Update-SettingsBadge {
    if (-not $settingsDot) {
        return
    }

    $settingsDot.Visibility = if (Test-HasPendingUpdate) { "Visible" } else { "Collapsed" }
}

$lanCopyButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($lanAddress.Text) -and $lanCopyButton.IsEnabled) {
        [System.Windows.Clipboard]::SetText($lanAddress.Text)
        $script:StatusHintText.Text = "局域网地址已复制，可以直接发到手机。"
        Show-CopyToast "已复制局域网地址"
    }
})

$onlineCopyButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($onlineAddress.Text) -and $onlineCopyButton.IsEnabled) {
        [System.Windows.Clipboard]::SetText($onlineAddress.Text)
        $script:StatusHintText.Text = "互联网地址已复制，可以直接发到手机。"
        Show-CopyToast "已复制互联网地址"
    }
})

$settingsButton.Add_Click({
    if (-not (Test-Path $SettingsWindowScript)) {
        Show-CopyToast "设置入口不可用"
        return
    }

    try {
        Start-UpdateCheck
        & $SettingsWindowScript
    } catch {
        try {
            Start-Process -FilePath (Get-Command powershell.exe).Source `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $SettingsWindowScript) `
                -WorkingDirectory $PackageDir | Out-Null
        } catch {
            Show-CopyToast "设置打开失败"
        }
    }
})

$dragWindowAction = {
    param($sender, $e)

    try {
        if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
            if (Test-IsInteractiveElement -Element $e.OriginalSource) {
                return
            }
            $window.DragMove()
        }
    } catch {
    }
}

$titleBar.Add_MouseLeftButtonDown($dragWindowAction)
$headerShell.Add_MouseLeftButtonDown($dragWindowAction)
$guideShell.Add_MouseLeftButtonDown($dragWindowAction)

$hideWindowButton.Add_Click({
    $window.Hide()
})

$closeWindowButton.Add_Click({
    $window.Close()
})

function Sync-WindowState {
    $config = Read-RuntimeConfig
    $lanUrl = Get-ConfigValue -Config $config -PropertyName "directUrl"
    if ([string]::IsNullOrWhiteSpace($lanUrl)) {
        $lanUrl = Get-ConfigValue -Config $config -PropertyName "directIpUrl"
    }
    $onlineUrl = Get-ConfigValue -Config $config -PropertyName "publicHttpUrl"

    $featuredLan = -not [string]::IsNullOrWhiteSpace($lanUrl)
    $featuredOnline = (-not $featuredLan) -and (-not [string]::IsNullOrWhiteSpace($onlineUrl))

    Set-CardUi `
        -Card $lanCard `
        -BadgeText $lanBadgeText `
        -TitleText $lanTitle `
        -SubtitleText $lanSubtitle `
        -AddressText $lanAddress `
        -ImageControl $lanImage `
        -PlaceholderText $lanPlaceholder `
        -CopyButton $lanCopyButton `
        -Title "局域网直连" `
        -Subtitle "自己手机热点 / 家里 Wi-Fi 时优先试这个" `
        -Url $lanUrl `
        -ImagePath $LanQrPngFile `
        -Featured $featuredLan `
        -BadgeLabel $(if ($featuredLan) { "推荐地址" } else { "局域网直连" }) `
        -AccentColor "#D08A35"

    Set-CardUi `
        -Card $onlineCard `
        -BadgeText $onlineBadgeText `
        -TitleText $onlineTitle `
        -SubtitleText $onlineSubtitle `
        -AddressText $onlineAddress `
        -ImageControl $onlineImage `
        -PlaceholderText $onlinePlaceholder `
        -CopyButton $onlineCopyButton `
        -Title "互联网地址" `
        -Subtitle "局域网打不开时，再试这个互联网地址" `
        -Url $onlineUrl `
        -ImagePath $OnlineQrPngFile `
        -Featured $featuredOnline `
        -BadgeLabel $(if ($featuredOnline) { "推荐地址" } else { "互联网备用" }) `
        -AccentColor "#35567F"

    $presence = Get-MobilePresenceState
    Set-StatusUi -Connected $presence.Connected -RemoteList $presence.RemoteList
    Update-SettingsBadge
}

$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromSeconds(1.2)
$refreshTimer.Add_Tick({
    Sync-WindowState
})

$window.Add_ContentRendered({
    Start-UpdateCheck
    Sync-WindowState
    $refreshTimer.Start()
})

$window.Add_Closed({
    $refreshTimer.Stop()
    $copyToastTimer.Stop()
})

[void]$window.ShowDialog()
