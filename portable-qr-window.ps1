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
$StartupLog = Join-Path $LogsDir "startup.log"
$ServerRuntimeLog = Join-Path $BaseDir "logs\server-runtime.log"
$IconPath = Join-Path $BaseDir "assets\voice-sync-icon.ico"
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
        $featuredColor = "#F6FBF8"
    } else {
        $softColor = "#F5E7D1"
        $textColor = "#C87720"
        $featuredColor = "#FBF6EF"
    }

    $TitleText.Text = $Title
    $SubtitleText.Text = $Subtitle
    $BadgeText.Text = $BadgeLabel
    $BadgeText.Foreground = New-Brush $textColor
    $BadgeText.Parent.Background = New-Brush $softColor

    $Card.BorderBrush = if ($Featured) { New-Brush $AccentColor } else { New-Brush "#D8E0E9" }
    $Card.Background = if ($Featured) { New-Brush $featuredColor } else { New-Brush "#EDF2F7" }
    $CopyButton.Background = New-Brush $softColor
    $CopyButton.Foreground = New-Brush $textColor

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

    $script:StatusPill.Background = New-Brush "#F5E7D1"
    $script:StatusDot.Fill = New-Brush "#D07F2A"
    $script:StatusText.Text = "未连接"
    $script:StatusText.Foreground = New-Brush "#D07F2A"
    $script:StatusHintText.Text = "扫码后，这里会自动变成已连接。"
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="语音输入同步 · 扫码连接"
        Width="1080"
        Height="790"
        MinWidth="980"
        MinHeight="730"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanMinimize"
        Background="#EDF2F7"
        ShowInTaskbar="True"
        FontFamily="Microsoft YaHei UI"
        SnapsToDevicePixels="True">
    <Window.Resources>
        <Style x:Key="GuideCardStyle" TargetType="Border">
            <Setter Property="Padding" Value="18,16"/>
            <Setter Property="Margin" Value="0,0,14,0"/>
            <Setter Property="CornerRadius" Value="22"/>
            <Setter Property="Background" Value="#F4F7FB"/>
            <Setter Property="BorderBrush" Value="#DCE4ED"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>
        <Style x:Key="CopyButtonStyle" TargetType="Button">
            <Setter Property="Height" Value="44"/>
            <Setter Property="Margin" Value="0,14,0,0"/>
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
                                CornerRadius="18">
                            <Border.Effect>
                                <DropShadowEffect BlurRadius="14"
                                                  ShadowDepth="5"
                                                  Direction="270"
                                                  Opacity="0.18"
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
    <Grid>
        <Grid.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#EDF2F7" Offset="0"/>
                <GradientStop Color="#DDE4EC" Offset="1"/>
            </LinearGradientBrush>
        </Grid.Background>

        <Ellipse Width="280"
                 Height="280"
                 Margin="-60,-110,0,0"
                 HorizontalAlignment="Left"
                 VerticalAlignment="Top"
                 Fill="#22D07F2A"/>
        <Ellipse Width="240"
                 Height="240"
                 Margin="0,-70,-40,0"
                 HorizontalAlignment="Right"
                 VerticalAlignment="Top"
                 Fill="#184DB57C"/>

        <Border Margin="26"
                CornerRadius="34"
                Background="#E7ECF2"
                BorderBrush="#F7FAFD"
                BorderThickness="1">
            <Border.Effect>
                <DropShadowEffect BlurRadius="34" ShadowDepth="16" Direction="315" Color="#99A8B8" Opacity="0.32"/>
            </Border.Effect>

            <Grid Margin="28">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <Border Grid.Row="0"
                        CornerRadius="30"
                        Background="#F0F5FA"
                        BorderBrush="#F8FBFF"
                        BorderThickness="1"
                        Padding="24,22">
                    <Border.Effect>
                        <DropShadowEffect BlurRadius="20"
                                          ShadowDepth="8"
                                          Direction="270"
                                          Color="#B1BFCC"
                                          Opacity="0.16"/>
                    </Border.Effect>
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <StackPanel Grid.Row="0" Grid.Column="0">
                            <Border HorizontalAlignment="Left"
                                    Padding="12,6"
                                    CornerRadius="999"
                                    Background="#F5E7D1">
                                <TextBlock Text="语音输入同步 · 手机扫码连接"
                                           FontSize="13"
                                           FontWeight="Bold"
                                           Foreground="#C87720"/>
                            </Border>
                            <TextBlock Text="先扫局域网，连上后回电脑点中输入框。"
                                       Margin="0,16,0,0"
                                       FontSize="31"
                                       FontWeight="Bold"
                                       Foreground="#213244"
                                       TextWrapping="Wrap"/>
                            <TextBlock Text="上面先放局域网直连，下面保留互联网备用。两张二维码和地址一一对应，优先走最短那条路。"
                                       Margin="0,12,0,0"
                                       FontSize="16"
                                       Foreground="#667687"
                                       TextWrapping="Wrap"/>
                        </StackPanel>

                        <StackPanel Grid.Row="0"
                                    Grid.Column="1"
                                    HorizontalAlignment="Right">
                            <Border x:Name="StatusPill"
                                    Padding="16,10"
                                    CornerRadius="999"
                                    Background="#F5E7D1">
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse x:Name="StatusDot"
                                             Width="10"
                                             Height="10"
                                             Margin="0,0,8,0"
                                             VerticalAlignment="Center"
                                             Fill="#D07F2A"/>
                                    <TextBlock x:Name="StatusText"
                                               Text="未连接"
                                               FontSize="15"
                                               FontWeight="Bold"
                                               Foreground="#D07F2A"/>
                                </StackPanel>
                            </Border>
                            <TextBlock x:Name="StatusHintText"
                                       Width="240"
                                       Margin="0,10,0,0"
                                       FontSize="13.5"
                                       Foreground="#6B7A8B"
                                       TextAlignment="Right"
                                       TextWrapping="Wrap"/>
                        </StackPanel>

                        <UniformGrid Grid.Row="1"
                                     Grid.ColumnSpan="2"
                                     Margin="0,22,0,0"
                                     Columns="3">
                            <Border Style="{StaticResource GuideCardStyle}">
                                <TextBlock Text="1 先扫局域网"
                                           FontSize="15"
                                           FontWeight="SemiBold"
                                           Foreground="#274160"/>
                            </Border>
                            <Border Style="{StaticResource GuideCardStyle}">
                                <TextBlock Text="2 等这里变已连接"
                                           FontSize="15"
                                           FontWeight="SemiBold"
                                           Foreground="#274160"/>
                            </Border>
                            <Border Margin="0"
                                    Style="{StaticResource GuideCardStyle}">
                                <TextBlock Text="3 回电脑点输入框"
                                           FontSize="15"
                                           FontWeight="SemiBold"
                                           Foreground="#274160"/>
                            </Border>
                        </UniformGrid>
                    </Grid>
                </Border>

                <Grid Grid.Row="1" Margin="0,24,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="20"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <Border x:Name="LanCard"
                            Grid.Column="0"
                            Padding="22"
                            CornerRadius="28"
                            Background="#F6FBF8"
                            BorderBrush="#4DB57C"
                            BorderThickness="1">
                        <Border.Effect>
                            <DropShadowEffect BlurRadius="18"
                                              ShadowDepth="8"
                                              Direction="270"
                                              Opacity="0.18"
                                              Color="#A5B2BF"/>
                        </Border.Effect>
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="216"/>
                                <ColumnDefinition Width="22"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <StackPanel Grid.Column="0">
                            <Border Background="#E7F3EC"
                                    CornerRadius="14"
                                    Padding="12,6"
                                    HorizontalAlignment="Left">
                                <TextBlock x:Name="LanBadgeText"
                                           Text="推荐地址"
                                           FontSize="13"
                                           FontWeight="Bold"
                                           Foreground="#278659"/>
                            </Border>

                            <Border
                                    Margin="0,16,0,0"
                                    Padding="16"
                                    Height="216"
                                    CornerRadius="24"
                                    Background="#FFFFFF"
                                    BorderBrush="#F7FAFD"
                                    BorderThickness="1">
                                <Border.Effect>
                                    <DropShadowEffect BlurRadius="18"
                                                      ShadowDepth="8"
                                                      Direction="270"
                                                      Opacity="0.18"
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
                                        CornerRadius="20"
                                        Background="#FFFFFF"
                                        BorderBrush="#F4F7FB"
                                        BorderThickness="1">
                                    <Border.Effect>
                                        <DropShadowEffect BlurRadius="14"
                                                          ShadowDepth="6"
                                                          Direction="270"
                                                          Opacity="0.14"
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
                                        Background="#E7F3EC"
                                        Foreground="#278659"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <Border x:Name="OnlineCard"
                            Grid.Column="2"
                            Padding="22"
                            CornerRadius="28"
                            Background="#EDF2F7"
                            BorderBrush="#D8E0E9"
                            BorderThickness="1">
                        <Border.Effect>
                            <DropShadowEffect BlurRadius="18"
                                              ShadowDepth="8"
                                              Direction="270"
                                              Opacity="0.18"
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
                                    CornerRadius="14"
                                    Padding="12,6"
                                    HorizontalAlignment="Left">
                                <TextBlock x:Name="OnlineBadgeText"
                                           Text="互联网备用"
                                           FontSize="13"
                                           FontWeight="Bold"
                                           Foreground="#C87720"/>
                            </Border>

                            <Border
                                    Margin="0,16,0,0"
                                    Padding="16"
                                    Height="216"
                                    CornerRadius="24"
                                    Background="#FFFFFF"
                                    BorderBrush="#F7FAFD"
                                    BorderThickness="1">
                                <Border.Effect>
                                    <DropShadowEffect BlurRadius="18"
                                                      ShadowDepth="8"
                                                      Direction="270"
                                                      Opacity="0.18"
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
                                        CornerRadius="20"
                                        Background="#FFFFFF"
                                        BorderBrush="#F4F7FB"
                                        BorderThickness="1">
                                    <Border.Effect>
                                        <DropShadowEffect BlurRadius="14"
                                                          ShadowDepth="6"
                                                          Direction="270"
                                                          Opacity="0.14"
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
                                        Background="#F5E7D1"
                                        Foreground="#C87720"/>
                            </StackPanel>
                        </Grid>
                    </Border>
                </Grid>
            </Grid>
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
$onlineCard = $window.FindName("OnlineCard")
$onlineBadgeText = $window.FindName("OnlineBadgeText")
$onlineTitle = $window.FindName("OnlineTitle")
$onlineSubtitle = $window.FindName("OnlineSubtitle")
$onlineAddress = $window.FindName("OnlineAddress")
$onlineImage = $window.FindName("OnlineImage")
$onlinePlaceholder = $window.FindName("OnlinePlaceholder")
$onlineCopyButton = $window.FindName("OnlineCopyButton")

$lanCopyButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($lanAddress.Text) -and $lanCopyButton.IsEnabled) {
        [System.Windows.Clipboard]::SetText($lanAddress.Text)
        $script:StatusHintText.Text = "局域网地址已复制，可以直接发到手机。"
    }
})

$onlineCopyButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($onlineAddress.Text) -and $onlineCopyButton.IsEnabled) {
        [System.Windows.Clipboard]::SetText($onlineAddress.Text)
        $script:StatusHintText.Text = "互联网地址已复制，可以直接发到手机。"
    }
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
        -AccentColor "#4DB57C"

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
        -AccentColor "#D07F2A"

    $presence = Get-MobilePresenceState
    Set-StatusUi -Connected $presence.Connected -RemoteList $presence.RemoteList
}

$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromSeconds(1.2)
$refreshTimer.Add_Tick({
    Sync-WindowState
})

$window.Add_ContentRendered({
    Sync-WindowState
    $refreshTimer.Start()
})

$window.Add_Closed({
    $refreshTimer.Stop()
})

[void]$window.ShowDialog()
