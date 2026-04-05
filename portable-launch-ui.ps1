param(
    [switch]$NoAutoClose
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDir = Split-Path -Parent $BaseDir
$LogsDir = Join-Path $PackageDir "logs"
$StartupScript = Join-Path $BaseDir "portable-start.ps1"
$StatusFile = Join-Path $LogsDir "startup-status.json"
$StartupLog = Join-Path $LogsDir "startup.log"
$LatestUrlFile = Join-Path $PackageDir "latest-url.txt"
$IconPath = Join-Path $BaseDir "assets\voice-sync-icon.ico"
$ServerRuntimeLog = Join-Path $BaseDir "logs\server-runtime.log"
$LauncherMutexName = "Local\VoiceInputSyncPortableLauncher"
$script:LauncherMutex = $null
$script:OwnsLauncherMutex = $false
$script:AnimationTick = 0
$script:AutoMinimizeArmed = $false
$script:AllowWindowClose = $false
$script:MainWindow = $null
$script:CurrentUrl = ""
$script:CurrentTarget = ""
$script:CurrentState = "running"
$script:CurrentPercent = 12
$script:ProgressTarget = 18
$script:StartupProcess = $null
$script:CloseTimer = $null
$script:LaunchRequested = $false
$script:WindowShownAt = $null
$script:SuccessSeenAt = $null
$script:LastNetworkHint = ""
$script:TipMessages = @(
    "准备好后会自动弹出扫码页。",
    "如果已经在运行，这次会直接复用当前会话。",
    "手机和电脑连同一个 Wi-Fi 会更顺手。"
)

New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null

function Get-Text {
    param([int[]]$Codes)

    return (-join ($Codes | ForEach-Object { [char]$_ }))
}

function Enter-LauncherMutex {
    $createdNew = $false
    $script:LauncherMutex = New-Object System.Threading.Mutex($true, $LauncherMutexName, [ref]$createdNew)
    $script:OwnsLauncherMutex = [bool]$createdNew
    return $script:OwnsLauncherMutex
}

function Exit-LauncherMutex {
    if ($script:LauncherMutex) {
        try {
            if ($script:OwnsLauncherMutex) {
                $script:LauncherMutex.ReleaseMutex()
            }
        } catch {
        } finally {
            $script:LauncherMutex.Dispose()
            $script:LauncherMutex = $null
            $script:OwnsLauncherMutex = $false
        }
    }
}

function Write-UiLog {
    param([string]$Message)

    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $StartupLog -Value "[$stamp] UI: $Message" -Encoding UTF8
}

function Read-StartupStatus {
    if (-not (Test-Path $StatusFile)) {
        return $null
    }

    try {
        return Get-Content -Raw -LiteralPath $StatusFile -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
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

function Resolve-OpenTarget {
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentTarget)) {
        return $script:CurrentTarget
    }
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentUrl)) {
        return $script:CurrentUrl
    }
    return (Read-LatestUrl)
}

function Invoke-ShellOpen {
    param([string]$Target)

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return $false
    }

    try {
        $resolvedTarget = $Target
        if (-not ($Target -match '^[a-zA-Z][a-zA-Z0-9+.-]*://')) {
            $resolvedTarget = (Resolve-Path -LiteralPath $Target).Path
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $resolvedTarget
        $psi.UseShellExecute = $true
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        Write-UiLog ("已打开: {0}" -f $resolvedTarget)
        return $true
    } catch {
        Write-UiLog ("打开失败: " + $_.Exception.Message)
        return $false
    }
}

function Copy-CurrentUrl {
    $value = if (-not [string]::IsNullOrWhiteSpace($script:CurrentUrl)) {
        $script:CurrentUrl
    } else {
        Read-LatestUrl
    }

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    [System.Windows.Clipboard]::SetText($value)
    Write-UiLog "已复制手机地址。"
    return $true
}

function New-Brush {
    param([string]$Color)

    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Get-PrimaryNetworkInfo {
    $configs = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
        $_.IPv4Address -and $_.IPv4DefaultGateway
    })

    $candidates = foreach ($config in $configs) {
        $ipv4 = ($config.IPv4Address | Select-Object -First 1).IPAddress
        if (-not $ipv4 -or $ipv4 -like "169.254*") {
            continue
        }

        $priority = if ($config.InterfaceAlias -match "Wi-?Fi|WLAN") { 1 } elseif ($config.InterfaceAlias -match "Ethernet") { 2 } else { 9 }
        [pscustomobject]@{
            InterfaceAlias = [string]$config.InterfaceAlias
            IPv4 = [string]$ipv4
            Priority = $priority
        }
    }

    $primary = $candidates | Sort-Object Priority | Select-Object -First 1
    if (-not $primary) {
        return $null
    }

    $profile = Get-NetConnectionProfile -InterfaceAlias $primary.InterfaceAlias -ErrorAction SilentlyContinue | Select-Object -First 1
    [pscustomobject]@{
        InterfaceAlias = $primary.InterfaceAlias
        IPv4 = $primary.IPv4
        NetworkCategory = if ($profile) { [string]$profile.NetworkCategory } else { "" }
    }
}

function Get-ServerConnectionInsight {
    param([string]$LocalIp)

    $result = [pscustomobject]@{
        ExternalHit = $false
        ExternalIps = @()
        SelfInvalidToken = $false
    }

    if (-not (Test-Path $ServerRuntimeLog)) {
        return $result
    }

    $lines = @(Get-Content $ServerRuntimeLog -Tail 160 -ErrorAction SilentlyContinue)
    foreach ($line in $lines) {
        if ($line -match "client connected: \('([^']+)',") {
            $ip = [string]$matches[1]
            if ($ip -and $ip -ne "127.0.0.1" -and $ip -ne $LocalIp) {
                $result.ExternalHit = $true
                if ($result.ExternalIps -notcontains $ip) {
                    $result.ExternalIps += $ip
                }
            }
        }

        if ($line -match "register rejected: invalid token from \('([^']+)',") {
            $ip = [string]$matches[1]
            if ($ip -eq $LocalIp) {
                $result.SelfInvalidToken = $true
            }
        }
    }

    return $result
}

function Set-BadgeState {
    param([string]$State)

    if ($State -eq "success") {
        $script:StatusBadge.Background = New-Brush "#4DB57C"
        $script:StatusBadgeText.Text = Get-Text @(0x5DF2,0x5C31,0x7EEA)
        $script:StatusBadgeText.Foreground = New-Brush "#FFFFFF"
        $script:HeroOrb.Fill = New-Brush "#E7F3EC"
        $script:HeroRing.Stroke = New-Brush "#C7DDD0"
        $script:HeroAccent.Fill = New-Brush "#4DB57C"
        return
    }

    if ($State -eq "error") {
        $script:StatusBadge.Background = New-Brush "#C14E4A"
        $script:StatusBadgeText.Text = Get-Text @(0x542F,0x52A8,0x5931,0x8D25)
        $script:StatusBadgeText.Foreground = New-Brush "#FFFFFF"
        $script:HeroOrb.Fill = New-Brush "#F4E8E7"
        $script:HeroRing.Stroke = New-Brush "#E5CFCB"
        $script:HeroAccent.Fill = New-Brush "#C14E4A"
        return
    }

    $script:StatusBadge.Background = New-Brush "#D07F2A"
    $script:StatusBadgeText.Text = Get-Text @(0x542F,0x52A8,0x4E2D)
    $script:StatusBadgeText.Foreground = New-Brush "#FFFFFF"
    $script:HeroOrb.Fill = New-Brush "#EDF2F7"
    $script:HeroRing.Stroke = New-Brush "#D9E1EA"
    $script:HeroAccent.Fill = New-Brush "#D07F2A"
}

function Set-StageState {
    param(
        [System.Windows.Controls.Border]$Chip,
        [string]$Mode
    )

    switch ($Mode) {
        "done" {
            $Chip.Background = New-Brush "#E7F3EC"
            $Chip.BorderBrush = New-Brush "#D2E7DB"
            $Chip.Child.Foreground = New-Brush "#278659"
        }
        "active" {
            $Chip.Background = New-Brush "#F2E7D9"
            $Chip.BorderBrush = New-Brush "#E9D2B4"
            $Chip.Child.Foreground = New-Brush "#D07F2A"
        }
        "error" {
            $Chip.Background = New-Brush "#F4E8E7"
            $Chip.BorderBrush = New-Brush "#E5CFCB"
            $Chip.Child.Foreground = New-Brush "#C14E4A"
        }
        default {
            $Chip.Background = New-Brush "#EDF2F7"
            $Chip.BorderBrush = New-Brush "#D9E1EA"
            $Chip.Child.Foreground = New-Brush "#6F7F94"
        }
    }
}

function Update-Chips {
    param(
        [string]$State,
        [int]$Percent
    )

    if ($State -eq "error") {
        Set-StageState -Chip $script:StageChipOne -Mode "done"
        Set-StageState -Chip $script:StageChipTwo -Mode "done"
        Set-StageState -Chip $script:StageChipThree -Mode "error"
        return
    }

    if ($State -eq "success") {
        Set-StageState -Chip $script:StageChipOne -Mode "done"
        Set-StageState -Chip $script:StageChipTwo -Mode "done"
        Set-StageState -Chip $script:StageChipThree -Mode "done"
        return
    }

    if ($Percent -lt 36) {
        Set-StageState -Chip $script:StageChipOne -Mode "active"
        Set-StageState -Chip $script:StageChipTwo -Mode "idle"
        Set-StageState -Chip $script:StageChipThree -Mode "idle"
    } elseif ($Percent -lt 74) {
        Set-StageState -Chip $script:StageChipOne -Mode "done"
        Set-StageState -Chip $script:StageChipTwo -Mode "active"
        Set-StageState -Chip $script:StageChipThree -Mode "idle"
    } else {
        Set-StageState -Chip $script:StageChipOne -Mode "done"
        Set-StageState -Chip $script:StageChipTwo -Mode "done"
        Set-StageState -Chip $script:StageChipThree -Mode "active"
    }
}

function Update-ProgressFill {
    param([double]$Percent)

    $script:CurrentPercent = [Math]::Max(0, [Math]::Min(100, $Percent))
    $trackWidth = [Math]::Max(0, $script:ProgressTrack.ActualWidth - 10)
    $fillWidth = $trackWidth * ($script:CurrentPercent / 100.0)
    if ($script:CurrentPercent -gt 0 -and $fillWidth -lt 18) {
        $fillWidth = 18
    }
    $script:ProgressFill.Width = $fillWidth
}

function Set-ProgressTarget {
    param(
        [double]$Percent,
        [switch]$Immediate
    )

    $script:ProgressTarget = [Math]::Max(0, [Math]::Min(100, $Percent))
    if ($Immediate) {
        Update-ProgressFill -Percent $script:ProgressTarget
    }
}

function Minimize-LauncherWindow {
    if (-not $script:MainWindow) {
        return
    }

    if ($script:MainWindow.WindowState -eq [System.Windows.WindowState]::Minimized) {
        return
    }

    try {
        $script:MainWindow.ShowInTaskbar = $true
        $script:MainWindow.WindowState = [System.Windows.WindowState]::Minimized
        Write-UiLog "启动窗口已缩到任务栏。"
    } catch {
        Write-UiLog ("缩到任务栏失败: " + $_.Exception.Message)
    }
}

function Start-BackendLaunch {
    if ($script:LaunchRequested) {
        return
    }

    $script:LaunchRequested = $true
    Remove-Item -LiteralPath $StatusFile -Force -ErrorAction SilentlyContinue

    $startupArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $StartupScript,
        "-Silent",
        "-OpenPageOnSuccess"
    )

    $script:StartupProcess = Start-Process powershell.exe -ArgumentList $startupArgs -WindowStyle Hidden -PassThru
    Write-UiLog ("已拉起启动服务 PID={0}" -f $script:StartupProcess.Id)
}

function Arm-AutoMinimize {
    param(
        [int]$MinimumVisibleSeconds = 10,
        [int]$PostSuccessSeconds = 6
    )

    if (-not $script:CloseTimer) {
        return
    }

    $shownElapsedSeconds = 0
    if ($script:WindowShownAt) {
        $shownElapsedSeconds = [int]([Math]::Floor(((Get-Date) - $script:WindowShownAt).TotalSeconds))
    }

    $remainingMinimum = [Math]::Max(0, $MinimumVisibleSeconds - $shownElapsedSeconds)
    $delaySeconds = [Math]::Max($PostSuccessSeconds, $remainingMinimum)
    $script:CloseTimer.Stop()
    $script:CloseTimer.Interval = [TimeSpan]::FromSeconds($delaySeconds)
    $script:CloseTimer.Start()
    Write-UiLog ("将在 {0} 秒后自动缩到任务栏。" -f $delaySeconds)
}

if (-not (Enter-LauncherMutex)) {
    exit 0
}

try {
    Write-UiLog "启动窗口已打开。"

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="&#x8BED;&#x97F3;&#x8F93;&#x5165;&#x540C;&#x6B65;"
        Width="980"
        Height="640"
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

        <Border Margin="28"
                CornerRadius="32"
                Background="#E7ECF2"
                BorderBrush="#F7FAFD"
                BorderThickness="1">
            <Border.Effect>
                <DropShadowEffect BlurRadius="34" ShadowDepth="16" Direction="315" Color="#97A5B4" Opacity="0.35"/>
            </Border.Effect>

            <Grid Margin="26">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="290"/>
                    <ColumnDefinition Width="26"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <StackPanel Grid.Row="0"
                            Grid.ColumnSpan="3"
                            Margin="10,0,0,18"
                            Orientation="Horizontal"
                            VerticalAlignment="Center">
                    <Border Width="64"
                            Height="8"
                            Margin="0,0,10,0"
                            Background="#D07F2A"
                            CornerRadius="8"/>
                    <Border Width="14"
                            Height="8"
                            Margin="0,0,8,0"
                            Background="#E6C39A"
                            CornerRadius="8"/>
                    <Border Width="14"
                            Height="8"
                            Background="#D9E3ED"
                            CornerRadius="8"/>
                </StackPanel>

                <Border Grid.Row="1"
                        Grid.Column="0"
                        Padding="26"
                        CornerRadius="28"
                        Background="#EAF0F6"
                        BorderBrush="#F7FAFD"
                        BorderThickness="1">
                    <Border.Effect>
                        <DropShadowEffect BlurRadius="22" ShadowDepth="10" Direction="315" Color="#A5B3C2" Opacity="0.28"/>
                    </Border.Effect>

                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <Border x:Name="StatusBadge"
                                HorizontalAlignment="Left"
                                Padding="18,8"
                                CornerRadius="18"
                                Background="#D07F2A">
                            <TextBlock x:Name="StatusBadgeText"
                                       Text="&#x542F;&#x52A8;&#x4E2D;"
                                       FontSize="18"
                                       FontWeight="Bold"
                                       Foreground="White"/>
                        </Border>

                        <Grid Grid.Row="1" VerticalAlignment="Center">
                            <Ellipse x:Name="HeroOrb"
                                     Width="176"
                                     Height="176"
                                     Fill="#EDF2F7"
                                     Stroke="#F8FBFE"
                                     StrokeThickness="2"/>
                            <Ellipse x:Name="HeroRing"
                                     Width="132"
                                     Height="132"
                                     Stroke="#D9E1EA"
                                     StrokeThickness="14"
                                     Fill="Transparent"/>
                            <Ellipse x:Name="HeroAccent"
                                     Width="84"
                                     Height="84"
                                     Fill="#D07F2A"
                                     Opacity="0.18"/>
                            <TextBlock x:Name="HeroEmoji"
                                       Text="&#x1F4AB;"
                                       FontFamily="Segoe UI Emoji"
                                       FontSize="58"
                                       HorizontalAlignment="Center"
                                       VerticalAlignment="Center"/>
                        </Grid>

                        <StackPanel Grid.Row="2">
                            <TextBlock x:Name="HeroTitle"
                                       Text="&#x6B63;&#x5728;&#x8FDE;&#x63A5;&#x684C;&#x9762;&#x548C;&#x624B;&#x673A;"
                                       Margin="0,8,0,8"
                                       FontSize="28"
                                       FontWeight="Bold"
                                       Foreground="#2B3B4F"
                                       TextWrapping="Wrap"/>
                            <TextBlock x:Name="HeroSubtitle"
                                       Text="&#x51C6;&#x5907;&#x597D;&#x540E;&#x4F1A;&#x81EA;&#x52A8;&#x6253;&#x5F00;&#x626B;&#x7801;&#x9875;&#x3002;"
                                       FontSize="16"
                                       Foreground="#6F7F94"
                                       TextWrapping="Wrap"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <Border Grid.Row="1"
                        Grid.Column="2"
                        Padding="30"
                        CornerRadius="28"
                        Background="#EAF0F6"
                        BorderBrush="#F7FAFD"
                        BorderThickness="1">
                    <Border.Effect>
                        <DropShadowEffect BlurRadius="22" ShadowDepth="10" Direction="315" Color="#A5B3C2" Opacity="0.28"/>
                    </Border.Effect>

                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <TextBlock x:Name="TitleText"
                                   Text="&#x6B63;&#x5728;&#x542F;&#x52A8;&#x540C;&#x6B65;&#x670D;&#x52A1;"
                                   FontSize="34"
                                   FontWeight="Bold"
                                   Foreground="#2B3B4F"/>

                        <TextBlock x:Name="SubtitleText"
                                   Grid.Row="1"
                                   Margin="0,12,0,0"
                                   Text="&#x901A;&#x5E38; 5 &#x5230; 10 &#x79D2;&#x5DE6;&#x53F3;&#xFF0C;&#x4F1A;&#x81EA;&#x52A8;&#x628A;&#x626B;&#x7801;&#x9875;&#x6253;&#x5F00;&#x7ED9;&#x4F60;&#x3002;"
                                   FontSize="18"
                                   Foreground="#6F7F94"
                                   TextWrapping="Wrap"/>

                        <StackPanel Grid.Row="2"
                                    Margin="0,28,0,0"
                                    Orientation="Horizontal">
                            <Border x:Name="StageChipOne"
                                    Padding="16,8"
                                    Margin="0,0,12,0"
                                    CornerRadius="18"
                                    Background="#F2E7D9"
                                    BorderBrush="#E9D2B4"
                                    BorderThickness="1">
                                <TextBlock Text="&#x68C0;&#x67E5;&#x73AF;&#x5883;"
                                           FontSize="16"
                                           FontWeight="SemiBold"
                                           Foreground="#D07F2A"/>
                            </Border>
                            <Border x:Name="StageChipTwo"
                                    Padding="16,8"
                                    Margin="0,0,12,0"
                                    CornerRadius="18"
                                    Background="#EDF2F7"
                                    BorderBrush="#D9E1EA"
                                    BorderThickness="1">
                                <TextBlock Text="&#x542F;&#x52A8;&#x540C;&#x6B65;"
                                           FontSize="16"
                                           FontWeight="SemiBold"
                                           Foreground="#6F7F94"/>
                            </Border>
                            <Border x:Name="StageChipThree"
                                    Padding="16,8"
                                    CornerRadius="18"
                                    Background="#EDF2F7"
                                    BorderBrush="#D9E1EA"
                                    BorderThickness="1">
                                <TextBlock Text="&#x6253;&#x5F00;&#x626B;&#x7801;&#x9875;"
                                           FontSize="16"
                                           FontWeight="SemiBold"
                                           Foreground="#6F7F94"/>
                            </Border>
                        </StackPanel>

                        <TextBlock x:Name="DetailText"
                                   Grid.Row="3"
                                   Margin="0,28,0,0"
                                   Text="&#x6B63;&#x5728;&#x68C0;&#x67E5;&#x73AF;&#x5883;..."
                                   FontSize="23"
                                   FontWeight="SemiBold"
                                   Foreground="#2B3B4F"
                                   TextWrapping="Wrap"/>

                        <TextBlock x:Name="TipText"
                                   Grid.Row="4"
                                   Margin="0,14,0,0"
                                   Text="&#x901A;&#x5E38;&#x53EA;&#x8981;&#x51E0;&#x79D2;&#xFF0C;&#x51C6;&#x5907;&#x597D;&#x540E;&#x4F1A;&#x81EA;&#x52A8;&#x6253;&#x5F00;&#x626B;&#x7801;&#x9875;&#x3002;"
                                   FontSize="16"
                                   Foreground="#6F7F94"
                                   TextWrapping="Wrap"/>

                        <Grid Grid.Row="5" Margin="0,34,0,0" VerticalAlignment="Bottom">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <Border x:Name="ProgressTrack"
                                    Height="18"
                                    Background="#D8E0E9"
                                    CornerRadius="9"
                                    SnapsToDevicePixels="True">
                                <Grid ClipToBounds="True">
                                    <Border x:Name="ProgressFill"
                                            HorizontalAlignment="Left"
                                            Width="82"
                                            Background="#D07F2A"
                                            CornerRadius="9"/>
                                    <Border x:Name="ProgressShimmer"
                                            Width="110"
                                            HorizontalAlignment="Left"
                                            CornerRadius="9"
                                            Background="#45FFFFFF"
                                            IsHitTestVisible="False">
                                        <Border.RenderTransform>
                                            <TranslateTransform X="-140"/>
                                        </Border.RenderTransform>
                                    </Border>
                                </Grid>
                            </Border>

                            <TextBlock x:Name="FooterText"
                                       Grid.Row="1"
                                       Margin="0,12,0,0"
                                       Text="&#x6B63;&#x5728;&#x51C6;&#x5907;&#x542F;&#x52A8;&#x73AF;&#x5883;..."
                                       FontSize="15"
                                       Foreground="#6F7F94"
                                       TextWrapping="Wrap"/>
                        </Grid>

                        <StackPanel Grid.Row="6"
                                    Margin="0,28,0,0"
                                    Orientation="Horizontal"
                                    HorizontalAlignment="Left">
                            <Button x:Name="OpenButton"
                                    Content="&#x6253;&#x5F00;&#x626B;&#x7801;&#x9875;"
                                    Width="130"
                                    Height="44"
                                    Margin="0,0,12,0"
                                    Visibility="Collapsed"/>
                            <Button x:Name="CopyButton"
                                    Content="&#x590D;&#x5236;&#x624B;&#x673A;&#x5730;&#x5740;"
                                    Width="130"
                                    Height="44"
                                    Margin="0,0,12,0"
                                    Visibility="Collapsed"/>
                            <Button x:Name="LogButton"
                                    Content="&#x67E5;&#x770B;&#x65E5;&#x5FD7;"
                                    Width="110"
                                    Height="44"
                                    Margin="0,0,12,0"
                                    Visibility="Collapsed"/>
                            <Button x:Name="CloseButton"
                                    Content="&#x7F29;&#x5230;&#x4EFB;&#x52A1;&#x680F;"
                                    Width="136"
                                    Height="44"/>
                        </StackPanel>
                    </Grid>
                </Border>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $script:MainWindow = $window

    if (Test-Path $IconPath) {
        try {
            $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$IconPath)
        } catch {
            Write-UiLog "图标加载已跳过。"
        }
    }

    $script:StatusBadge = $window.FindName("StatusBadge")
    $script:StatusBadgeText = $window.FindName("StatusBadgeText")
    $script:HeroOrb = $window.FindName("HeroOrb")
    $script:HeroRing = $window.FindName("HeroRing")
    $script:HeroAccent = $window.FindName("HeroAccent")
    $script:HeroEmoji = $window.FindName("HeroEmoji")
    $script:HeroTitle = $window.FindName("HeroTitle")
    $script:HeroSubtitle = $window.FindName("HeroSubtitle")
    $script:TitleText = $window.FindName("TitleText")
    $script:SubtitleText = $window.FindName("SubtitleText")
    $script:DetailText = $window.FindName("DetailText")
    $script:TipText = $window.FindName("TipText")
    $script:FooterText = $window.FindName("FooterText")
    $script:ProgressTrack = $window.FindName("ProgressTrack")
    $script:ProgressFill = $window.FindName("ProgressFill")
    $script:ProgressShimmer = $window.FindName("ProgressShimmer")
    $script:StageChipOne = $window.FindName("StageChipOne")
    $script:StageChipTwo = $window.FindName("StageChipTwo")
    $script:StageChipThree = $window.FindName("StageChipThree")
    $script:OpenButton = $window.FindName("OpenButton")
    $script:CopyButton = $window.FindName("CopyButton")
    $script:LogButton = $window.FindName("LogButton")
    $script:CloseButton = $window.FindName("CloseButton")

    foreach ($button in @($script:OpenButton, $script:CopyButton, $script:LogButton, $script:CloseButton)) {
        $button.Background = New-Brush "#EDF2F7"
        $button.BorderBrush = New-Brush "#D9E1EA"
        $button.Foreground = New-Brush "#2B3B4F"
    }
    $script:OpenButton.Background = New-Brush "#D07F2A"
    $script:OpenButton.BorderBrush = New-Brush "#D07F2A"
    $script:OpenButton.Foreground = New-Brush "#FFFFFF"

    Set-BadgeState -State "running"
    Update-Chips -State "running" -Percent 12
    Update-ProgressFill -Percent 12
    Set-ProgressTarget -Percent 18

    $script:ProgressTrack.Add_SizeChanged({
        Update-ProgressFill -Percent $script:CurrentPercent
    })

    $script:OpenButton.Add_Click({
        [void](Invoke-ShellOpen -Target (Resolve-OpenTarget))
    })

    $script:CopyButton.Add_Click({
        if (Copy-CurrentUrl) {
            $script:FooterText.Text = "手机地址已复制。"
        }
    })

    $script:LogButton.Add_Click({
        if (Test-Path $StartupLog) {
            Start-Process notepad.exe $StartupLog | Out-Null
        }
    })

    $script:CloseButton.Add_Click({
        if ($script:CurrentState -eq "error") {
            $script:AllowWindowClose = $true
            $window.Close()
            return
        }

        Minimize-LauncherWindow
    })

    $window.Add_Closing({
        param($sender, $e)

        if ($script:AllowWindowClose -or $script:CurrentState -eq "error") {
            return
        }

        $e.Cancel = $true
        Minimize-LauncherWindow
    })

    $animationTimer = New-Object System.Windows.Threading.DispatcherTimer
    $animationTimer.Interval = [TimeSpan]::FromMilliseconds(90)
    $animationTimer.Add_Tick({
        $script:AnimationTick++
        if ($script:CurrentState -eq "running") {
            $pulse = (($script:AnimationTick % 12) + 1) / 12.0
            $script:HeroAccent.Opacity = 0.14 + ($pulse * 0.16)
            if (($script:AnimationTick % 2) -eq 0) {
                $script:HeroEmoji.Text = Get-Text @(0xD83D, 0xDCAB)
            } else {
                $script:HeroEmoji.Text = Get-Text @(0x2728)
            }
            if (($script:AnimationTick % 10) -eq 0) {
                $index = [int](($script:AnimationTick / 10) % $script:TipMessages.Count)
                $script:TipText.Text = $script:TipMessages[$index]
            }

            $trackWidth = [Math]::Max(120, $script:ProgressTrack.ActualWidth)
            $shimmerOffset = (($script:AnimationTick * 16) % ([int]($trackWidth + 160))) - 140
            $script:ProgressShimmer.RenderTransform.X = $shimmerOffset

            $targetPercent = [Math]::Max($script:ProgressTarget, 26)
            if ($script:CurrentPercent -lt $targetPercent) {
                $gap = $targetPercent - $script:CurrentPercent
                $step = [Math]::Min(4.8, [Math]::Max(0.55, $gap * 0.32))
                Update-ProgressFill -Percent ($script:CurrentPercent + $step)
            } elseif ($script:CurrentPercent -lt 86) {
                Update-ProgressFill -Percent ($script:CurrentPercent + 0.22)
            }
        }
    })

    $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:CloseTimer = $closeTimer
    $closeTimer.Interval = [TimeSpan]::FromMilliseconds(10000)
    $closeTimer.Add_Tick({
        $closeTimer.Stop()
        Minimize-LauncherWindow
    })

    $launchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $launchTimer.Interval = [TimeSpan]::FromMilliseconds(180)
    $launchTimer.Add_Tick({
        $launchTimer.Stop()
        Start-BackendLaunch
    })

    $pollTimer = New-Object System.Windows.Threading.DispatcherTimer
    $pollTimer.Interval = [TimeSpan]::FromMilliseconds(220)
    $pollTimer.Add_Tick({
        $status = Read-StartupStatus
        if ($status) {
            $percent = 0
            try {
                $percent = [int]$status.percent
            } catch {
                $percent = 0
            }

            $script:CurrentState = [string]$status.state
            $script:CurrentUrl = [string]$status.url
            $script:CurrentTarget = [string]$status.pageTarget

            if ($script:CurrentState -eq "success") {
                Set-BadgeState -State "success"
                Update-Chips -State "success" -Percent 100
                Set-ProgressTarget -Percent 100 -Immediate
                $script:CloseButton.Content = Get-Text @(0x7F29,0x5230,0x4EFB,0x52A1,0x680F)
                $script:TitleText.Text = [string]$status.title
                $script:DetailText.Text = [string]$status.detail
                if (-not $script:SuccessSeenAt) {
                    $script:SuccessSeenAt = Get-Date
                    if (-not $NoAutoClose -and -not $script:AutoMinimizeArmed) {
                        $script:AutoMinimizeArmed = $true
                        Arm-AutoMinimize
                    }
                }
                $script:OpenButton.Visibility = "Visible"
                if (-not [string]::IsNullOrWhiteSpace($script:CurrentUrl)) {
                    $script:CopyButton.Visibility = "Visible"
                } else {
                    $script:CopyButton.Visibility = "Collapsed"
                }
                $script:LogButton.Visibility = "Collapsed"
                $reuseSession = $false
                if ($null -ne $status.PSObject.Properties["reuseSession"]) {
                    $reuseSession = [bool]$status.reuseSession
                }

                $networkInfo = Get-PrimaryNetworkInfo
                $localIp = ""
                if ($networkInfo) {
                    $localIp = [string]$networkInfo.IPv4
                }
                $connectionInsight = Get-ServerConnectionInsight -LocalIp $localIp
                $elapsedSuccessSeconds = [int](([datetime](Get-Date)) - $script:SuccessSeenAt).TotalSeconds

                if ($connectionInsight.ExternalHit) {
                    $remoteText = (($connectionInsight.ExternalIps | Select-Object -First 3) -join " / ")
                    $script:TipText.Text = Get-Text @(0x5DF2,0x7ECF,0x68C0,0x6D4B,0x5230,0x624B,0x673A,0x6216,0x5176,0x4ED6,0x8BBE,0x5907,0x6253,0x5230,0x8FD9,0x53F0,0x7535,0x8111,0x3002)
                    $script:FooterText.Text = (Get-Text @(0x5916,0x90E8,0x8BBE,0x5907,0x6765,0x6E90,0xFF1A)) + $remoteText
                } else {
                    $networkSummary = if ($networkInfo) {
                        (Get-Text @(0x5F53,0x524D,0x7F51,0x7EDC,0xFF1A)) + ("{0} / {1} / {2}" -f $networkInfo.InterfaceAlias, $networkInfo.NetworkCategory, $networkInfo.IPv4)
                    } elseif (-not [string]::IsNullOrWhiteSpace($localIp)) {
                        (Get-Text @(0x5F53,0x524D,0x7F51,0x7EDC,0x20,0x49,0x50,0xFF1A)) + $localIp
                    } else {
                        [string]$status.detail
                    }

                    if ($elapsedSuccessSeconds -ge 12) {
                        $script:TipText.Text = Get-Text @(0x8FD8,0x6CA1,0x6709,0x4EFB,0x4F55,0x624B,0x673A,0x771F,0x6B63,0x6253,0x5230,0x8FD9,0x53F0,0x7535,0x8111,0x3002,0x901A,0x5E38,0x662F,0x6CA1,0x8FDE,0x540C,0x4E00,0x4E2A,0x20,0x57,0x69,0x2D,0x46,0x69,0xFF0C,0x6216,0x8005,0x8DEF,0x7531,0x5668,0x5F00,0x4E86,0x20,0x41,0x50,0x20,0x9694,0x79BB,0x3002)
                    } elseif ($connectionInsight.SelfInvalidToken) {
                        $script:TipText.Text = Get-Text @(0x8FD9,0x53F0,0x7535,0x8111,0x521A,0x521A,0x8FD8,0x5728,0x8BF7,0x6C42,0x65E7,0x4E8C,0x7EF4,0x7801,0x3002,0x8BF7,0x91CD,0x65B0,0x626B,0x73B0,0x5728,0x5F39,0x51FA,0x7684,0x65B0,0x4E8C,0x7EF4,0x7801,0x3002)
                    } elseif ($networkInfo -and $networkInfo.NetworkCategory -eq "Public" -and $elapsedSuccessSeconds -ge 6) {
                        $script:TipText.Text = Get-Text @(0x5F53,0x524D,0x20,0x57,0x69,0x2D,0x46,0x69,0x20,0x88AB,0x8BC6,0x522B,0x4E3A,0x516C,0x5171,0x7F51,0x7EDC,0x3002,0x624B,0x673A,0x6253,0x4E0D,0x5F00,0x65F6,0xFF0C,0x5148,0x786E,0x8BA4,0x548C,0x7535,0x8111,0x5728,0x540C,0x4E00,0x20,0x57,0x69,0x2D,0x46,0x69,0xFF0C,0x4E14,0x6CA1,0x6709,0x8BBE,0x5907,0x9694,0x79BB,0x3002)
                    } else {
                        $script:TipText.Text = Get-Text @(0x6B63,0x5728,0x7B49,0x624B,0x673A,0x771F,0x6B63,0x6253,0x5230,0x8FD9,0x53F0,0x7535,0x8111,0x3002,0x8BF7,0x626B,0x521A,0x521A,0x5F39,0x51FA,0x7684,0x65B0,0x4E8C,0x7EF4,0x7801,0x3002)
                    }

                    $script:FooterText.Text = $networkSummary
                }
                $networkHintSignature = "{0} || {1}" -f $script:TipText.Text, $script:FooterText.Text
                if ($networkHintSignature -ne $script:LastNetworkHint) {
                    $script:LastNetworkHint = $networkHintSignature
                    Write-UiLog ("连接提示: {0}" -f $networkHintSignature)
                }
                return
            }

            if ($script:CurrentState -eq "error") {
                Set-BadgeState -State "error"
                Update-Chips -State "error" -Percent 100
                Set-ProgressTarget -Percent 100 -Immediate
                $script:CloseButton.Content = Get-Text @(0x5173,0x95ED)
                $script:TitleText.Text = [string]$status.title
                $script:DetailText.Text = [string]$status.detail
                $script:FooterText.Text = [string]$status.detail
                $script:OpenButton.Visibility = "Collapsed"
                $script:CopyButton.Visibility = "Collapsed"
                $script:LogButton.Visibility = "Visible"
                return
            }

            Set-BadgeState -State "running"
            Update-Chips -State "running" -Percent $percent
            Set-ProgressTarget -Percent ([Math]::Max(22, [Math]::Min(92, $percent)))
            $script:CloseButton.Content = Get-Text @(0x7F29,0x5230,0x4EFB,0x52A1,0x680F)
            if (-not [string]::IsNullOrWhiteSpace([string]$status.title)) {
                $script:TitleText.Text = [string]$status.title
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$status.detail)) {
                $script:DetailText.Text = [string]$status.detail
                $script:FooterText.Text = [string]$status.detail
            }
            $script:OpenButton.Visibility = "Collapsed"
            $script:CopyButton.Visibility = "Collapsed"
            $script:LogButton.Visibility = "Collapsed"
            return
        }

        if ($script:StartupProcess -and $script:StartupProcess.HasExited) {
            $script:CurrentState = "error"
            Set-BadgeState -State "error"
            Update-Chips -State "error" -Percent 100
            Set-ProgressTarget -Percent 100 -Immediate
            $script:LogButton.Visibility = "Visible"
        }
    })

    $window.Add_ContentRendered({
        if (-not $script:WindowShownAt) {
            $script:WindowShownAt = Get-Date
            Write-UiLog "启动窗口已显示。"
            $launchTimer.Start()
        }
    })

    $window.Add_Closed({
        $animationTimer.Stop()
        $pollTimer.Stop()
        $closeTimer.Stop()
        $launchTimer.Stop()
        Write-UiLog "启动窗口已关闭。"
        Exit-LauncherMutex
    })

    $animationTimer.Start()
    $pollTimer.Start()
    [void]$window.ShowDialog()
} finally {
    Exit-LauncherMutex
}
