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

    $TitleText.Text = $Title
    $SubtitleText.Text = $Subtitle
    $BadgeText.Text = $BadgeLabel
    $BadgeText.Foreground = New-Brush "#FFFFFF"
    $BadgeText.Parent.Background = New-Brush $AccentColor

    $Card.BorderBrush = if ($Featured) { New-Brush $AccentColor } else { New-Brush "#D8E0E9" }
    $Card.Background = if ($Featured) { New-Brush "#F7FAFD" } else { New-Brush "#EDF2F7" }

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
        $script:StatusPill.Background = New-Brush "#4DB57C"
        $script:StatusText.Text = "已连接"
        $script:StatusHintText.Text = if ($RemoteList) { "手机已经连上，来源：" + $RemoteList } else { "手机已经连上，现在回电脑点输入框就能直接输入。" }
        return
    }

    $script:StatusPill.Background = New-Brush "#D07F2A"
    $script:StatusText.Text = "等待连接"
    $script:StatusHintText.Text = "先扫上面的局域网码；手机打开后，再回电脑点中输入框。"
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="语音输入同步 · 扫码连接"
        Width="1120"
        Height="840"
        MinWidth="980"
        MinHeight="760"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanMinimize"
        Background="#EDF2F7"
        ShowInTaskbar="True"
        FontFamily="Microsoft YaHei UI"
        SnapsToDevicePixels="True">
    <Grid>
        <Grid.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#EDF2F7" Offset="0"/>
                <GradientStop Color="#DDE4EC" Offset="1"/>
            </LinearGradientBrush>
        </Grid.Background>

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
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel>
                        <Border Width="80"
                                Height="8"
                                Margin="0,0,0,16"
                                HorizontalAlignment="Left"
                                Background="#D07F2A"
                                CornerRadius="8"/>
                        <TextBlock Text="语音输入同步 · 手机扫码连接"
                                   FontSize="34"
                                   FontWeight="Bold"
                                   Foreground="#213244"/>
                        <TextBlock Text="局域网优先，互联网备用。手机打开后，回电脑点中输入框就能直接输入。"
                                   Margin="0,12,0,0"
                                   FontSize="17"
                                   Foreground="#647384"
                                   TextWrapping="Wrap"/>
                    </StackPanel>

                    <StackPanel Grid.Column="1" HorizontalAlignment="Right">
                        <Border x:Name="StatusPill"
                                Padding="20,10"
                                CornerRadius="18"
                                Background="#D07F2A">
                            <TextBlock x:Name="StatusText"
                                       Text="等待连接"
                                       FontSize="18"
                                       FontWeight="Bold"
                                       Foreground="White"/>
                        </Border>
                        <TextBlock x:Name="StatusHintText"
                                   Width="290"
                                   Margin="0,12,0,0"
                                   TextAlignment="Right"
                                   FontSize="14"
                                   Foreground="#667687"
                                   TextWrapping="Wrap"/>
                    </StackPanel>
                </Grid>

                <UniformGrid Grid.Row="1"
                             Margin="0,24,0,0"
                             Columns="3">
                    <Border Margin="0,0,14,0"
                            Padding="18,14"
                            CornerRadius="20"
                            Background="#F4F7FB"
                            BorderBrush="#DCE4ED"
                            BorderThickness="1">
                        <TextBlock Text="1 先扫局域网二维码"
                                   FontSize="16"
                                   FontWeight="SemiBold"
                                   Foreground="#274160"/>
                    </Border>
                    <Border Margin="0,0,14,0"
                            Padding="18,14"
                            CornerRadius="20"
                            Background="#F4F7FB"
                            BorderBrush="#DCE4ED"
                            BorderThickness="1">
                        <TextBlock Text="2 手机显示已连接"
                                   FontSize="16"
                                   FontWeight="SemiBold"
                                   Foreground="#274160"/>
                    </Border>
                    <Border Padding="18,14"
                            CornerRadius="20"
                            Background="#F4F7FB"
                            BorderBrush="#DCE4ED"
                            BorderThickness="1">
                        <TextBlock Text="3 回电脑点输入框"
                                   FontSize="16"
                                   FontWeight="SemiBold"
                                   Foreground="#274160"/>
                    </Border>
                </UniformGrid>

                <Grid Grid.Row="2" Margin="0,24,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="24"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <Border x:Name="LanCard"
                            Grid.Column="0"
                            Padding="24"
                            CornerRadius="28"
                            Background="#F7FAFD"
                            BorderBrush="#4DB57C"
                            BorderThickness="2">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <Border Background="#4DB57C"
                                    CornerRadius="14"
                                    Padding="12,6"
                                    HorizontalAlignment="Left">
                                <TextBlock x:Name="LanBadgeText"
                                           Text="推荐地址"
                                           FontSize="13"
                                           FontWeight="Bold"
                                           Foreground="White"/>
                            </Border>

                            <Border Grid.Row="1"
                                    Margin="0,16,0,0"
                                    Padding="16"
                                    CornerRadius="24"
                                    Background="#EEF4F9"
                                    BorderBrush="#D8E0E9"
                                    BorderThickness="1">
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

                            <StackPanel Grid.Row="2" Margin="0,20,0,0">
                                <TextBlock x:Name="LanTitle"
                                           Text="局域网直连"
                                           FontSize="28"
                                           FontWeight="Bold"
                                           Foreground="#213244"/>
                                <TextBlock x:Name="LanSubtitle"
                                           Text="自己手机热点 / 家里 Wi-Fi 时优先试这个"
                                           Margin="0,10,0,0"
                                           FontSize="16"
                                           Foreground="#647384"
                                           TextWrapping="Wrap"/>
                                <Border Margin="0,16,0,0"
                                        Padding="16,14"
                                        CornerRadius="20"
                                        Background="#EDF2F7"
                                        BorderBrush="#D8E0E9"
                                        BorderThickness="1">
                                    <TextBlock x:Name="LanAddress"
                                               FontSize="15"
                                               Foreground="#233446"
                                               TextWrapping="Wrap"/>
                                </Border>
                                <Button x:Name="LanCopyButton"
                                        Content="复制局域网地址"
                                        Height="44"
                                        Margin="0,14,0,0"
                                        Background="#E7F3EC"
                                        BorderBrush="#CFE4D7"
                                        Foreground="#238355"
                                        FontSize="15"
                                        FontWeight="SemiBold"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <Border x:Name="OnlineCard"
                            Grid.Column="2"
                            Padding="24"
                            CornerRadius="28"
                            Background="#EDF2F7"
                            BorderBrush="#D8E0E9"
                            BorderThickness="1">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <Border Background="#D07F2A"
                                    CornerRadius="14"
                                    Padding="12,6"
                                    HorizontalAlignment="Left">
                                <TextBlock x:Name="OnlineBadgeText"
                                           Text="互联网备用"
                                           FontSize="13"
                                           FontWeight="Bold"
                                           Foreground="White"/>
                            </Border>

                            <Border Grid.Row="1"
                                    Margin="0,16,0,0"
                                    Padding="16"
                                    CornerRadius="24"
                                    Background="#EEF4F9"
                                    BorderBrush="#D8E0E9"
                                    BorderThickness="1">
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

                            <StackPanel Grid.Row="2" Margin="0,20,0,0">
                                <TextBlock x:Name="OnlineTitle"
                                           Text="互联网地址"
                                           FontSize="28"
                                           FontWeight="Bold"
                                           Foreground="#213244"/>
                                <TextBlock x:Name="OnlineSubtitle"
                                           Text="局域网打不开时，再试这个互联网地址"
                                           Margin="0,10,0,0"
                                           FontSize="16"
                                           Foreground="#647384"
                                           TextWrapping="Wrap"/>
                                <Border Margin="0,16,0,0"
                                        Padding="16,14"
                                        CornerRadius="20"
                                        Background="#EDF2F7"
                                        BorderBrush="#D8E0E9"
                                        BorderThickness="1">
                                    <TextBlock x:Name="OnlineAddress"
                                               FontSize="15"
                                               Foreground="#233446"
                                               TextWrapping="Wrap"/>
                                </Border>
                                <Button x:Name="OnlineCopyButton"
                                        Content="复制互联网地址"
                                        Height="44"
                                        Margin="0,14,0,0"
                                        Background="#F5E7D1"
                                        BorderBrush="#E8D0B0"
                                        Foreground="#C87720"
                                        FontSize="15"
                                        FontWeight="SemiBold"/>
                            </StackPanel>
                        </Grid>
                    </Border>
                </Grid>

                <Border Grid.Row="3"
                        Margin="0,22,0,0"
                        Padding="18,16"
                        CornerRadius="22"
                        Background="#F4F7FB"
                        BorderBrush="#DCE4ED"
                        BorderThickness="1">
                    <TextBlock Text="用法很简单：扫码以后，先看手机页已经能输入，再回电脑把光标点进真正要输入的位置。"
                               FontSize="15"
                               Foreground="#617182"
                               TextWrapping="Wrap"/>
                </Border>
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
