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
$QrHtmlFile = Join-Path $PackageDir "手机扫码打开.html"
$QrWindowScript = Join-Path $BaseDir "portable-qr-window.ps1"
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
$script:EstimatedTotalSeconds = 12
$script:TipMessages = @(
    "通常约 8-20 秒，网络较慢时可能到 30 秒。",
    "准备好后会自动弹出扫码页。",
    "如果已经在运行，这次会直接复用当前会话。"
)

New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
Remove-Item -LiteralPath $StatusFile -Force -ErrorAction SilentlyContinue

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
        $stream = [System.IO.File]::Open($StatusFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
            try {
                $content = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
        } finally {
            $stream.Dispose()
        }

        if ([string]::IsNullOrWhiteSpace($content)) {
            return $null
        }

        return $content | ConvertFrom-Json
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
            Write-UiLog ("已打开扫码窗口: {0}" -f $QrWindowScript)
            return $true
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
        $script:HeroRing.Stroke = New-Brush "#CBE5D7"
        $script:HeroAccent.Fill = New-Brush "#4DB57C"
        return
    }

    if ($State -eq "error") {
        $script:StatusBadge.Background = New-Brush "#C35A58"
        $script:StatusBadgeText.Text = Get-Text @(0x542F,0x52A8,0x5931,0x8D25)
        $script:StatusBadgeText.Foreground = New-Brush "#FFFFFF"
        $script:HeroOrb.Fill = New-Brush "#F7ECEC"
        $script:HeroRing.Stroke = New-Brush "#E8D4D2"
        $script:HeroAccent.Fill = New-Brush "#C35A58"
        return
    }

    $script:StatusBadge.Background = New-Brush "#D08A35"
    $script:StatusBadgeText.Text = Get-Text @(0x542F,0x52A8,0x4E2D)
    $script:StatusBadgeText.Foreground = New-Brush "#FFFFFF"
    $script:HeroOrb.Fill = New-Brush "#F1F5FA"
    $script:HeroRing.Stroke = New-Brush "#D6E0EC"
    $script:HeroAccent.Fill = New-Brush "#D08A35"
}

function Set-StageState {
    param(
        [System.Windows.Controls.Border]$Chip,
        [string]$Mode
    )

    switch ($Mode) {
        "done" {
            $Chip.Background = New-Brush "#EAF1F8"
            $Chip.BorderBrush = New-Brush "#D8E4EF"
            $Chip.Child.Foreground = New-Brush "#35567F"
        }
        "active" {
            $Chip.Background = New-Brush "#F4E5CF"
            $Chip.BorderBrush = New-Brush "#EACFA9"
            $Chip.Child.Foreground = New-Brush "#D08A35"
        }
        "error" {
            $Chip.Background = New-Brush "#F7ECEC"
            $Chip.BorderBrush = New-Brush "#E8D4D2"
            $Chip.Child.Foreground = New-Brush "#C35A58"
        }
        default {
            $Chip.Background = New-Brush "#EEF3F9"
            $Chip.BorderBrush = New-Brush "#D9E3EE"
            $Chip.Child.Foreground = New-Brush "#6B7D92"
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
    param(
        [string]$State = "running",
        [double]$Percent = 0
    )

    $script:CurrentPercent = [Math]::Max(0, [Math]::Min(100, $Percent))
    $trackWidth = [Math]::Max(0, $script:ProgressTrack.ActualWidth - 10)
    if ($trackWidth -le 0) {
        return
    }

    if ($State -eq "success") {
        $script:ProgressTrack.Background = New-Brush "#DCEFE4"
        $script:ProgressFill.Background = New-Brush "#4DB57C"
        $script:ProgressFill.Width = $trackWidth
        $script:ProgressFill.RenderTransform.X = 0
        $script:ProgressShimmer.Visibility = "Collapsed"
        return
    }

    if ($State -eq "error") {
        $script:ProgressTrack.Background = New-Brush "#F4E4E3"
        $script:ProgressFill.Background = New-Brush "#C35A58"
        $script:ProgressFill.Width = $trackWidth
        $script:ProgressFill.RenderTransform.X = 0
        $script:ProgressShimmer.Visibility = "Collapsed"
        return
    }

    $segmentWidth = [Math]::Min([Math]::Max(150, [Math]::Floor($trackWidth * 0.34)), [Math]::Max(86, $trackWidth - 18))
    $script:ProgressTrack.Background = New-Brush "#D9E4EF"
    $script:ProgressFill.Background = New-Brush "#D08A35"
    $script:ProgressFill.Width = $segmentWidth
    $script:ProgressShimmer.Visibility = "Visible"
}

function Set-ProgressTarget {
    param(
        [double]$Percent,
        [switch]$Immediate
    )

    $script:ProgressTarget = [Math]::Max(0, [Math]::Min(100, $Percent))
    if ($Immediate) {
        Update-ProgressFill -State $script:CurrentState -Percent $script:ProgressTarget
    }
}

function Update-HeroCopy {
    param(
        [string]$State,
        [int]$Percent
    )

    if ($State -eq "success") {
        $script:HeroTitle.Text = "同步服务已经就绪"
        $script:HeroSubtitle.Text = "扫码页已经准备好，稍后会自动收起到后台。"
        return
    }

    if ($State -eq "error") {
        $script:HeroTitle.Text = "这次启动没有完成"
        $script:HeroSubtitle.Text = "可以先看右侧提示，必要时直接打开日志。"
        return
    }

    if ($Percent -lt 36) {
        $script:HeroTitle.Text = "正在准备启动环境"
        $script:HeroSubtitle.Text = "先检查残留进程、快捷方式和基础运行环境。"
        return
    }

    if ($Percent -lt 74) {
        $script:HeroTitle.Text = "正在寻找端口并启动服务"
        $script:HeroSubtitle.Text = "会自动挑可用端口，不会因为占用直接卡住。"
        return
    }

    $script:HeroTitle.Text = "正在生成手机入口"
    $script:HeroSubtitle.Text = "正在整理局域网地址、二维码和扫码页。"
}

function Update-StartupEstimate {
    param(
        [int]$Percent = 12
    )

    if (-not $script:WindowShownAt) {
        return
    }

    $elapsed = [int][Math]::Max(0, [Math]::Floor(((Get-Date) - $script:WindowShownAt).TotalSeconds))
    $normalizedPercent = [int][Math]::Max(10, [Math]::Min(92, $Percent))
    $predictedTotal = if ($elapsed -le 0) {
        12
    } else {
        [int][Math]::Round(($elapsed * 100.0) / $normalizedPercent)
    }

    $predictedTotal = [int][Math]::Max(9, [Math]::Min(35, $predictedTotal))
    if ($normalizedPercent -lt 28) {
        $predictedTotal = [int][Math]::Max($predictedTotal, 12)
    }

    $script:EstimatedTotalSeconds = $predictedTotal
    $remaining = [int][Math]::Max(0, $predictedTotal - $elapsed)
    $script:SubtitleText.Text = "通常约 8-20 秒，网络较慢时可能到 30 秒。"

    if ($remaining -le 1) {
        $script:FooterText.Text = ("已用 {0} 秒，正在做最后收尾..." -f $elapsed)
    } else {
        $script:FooterText.Text = ("预计总耗时约 {0} 秒，已用 {1} 秒，还需约 {2} 秒。" -f $predictedTotal, $elapsed, $remaining)
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

function Hide-LauncherWindow {
    if (-not $script:MainWindow) {
        return
    }

    try {
        $script:MainWindow.Hide()
        Write-UiLog "启动窗口已隐藏。"
    } catch {
        Write-UiLog ("隐藏启动窗口失败: " + $_.Exception.Message)
    }
}

function Close-LauncherWindow {
    if (-not $script:MainWindow) {
        return
    }

    try {
        $script:AllowWindowClose = $true
        $script:MainWindow.Close()
        Write-UiLog "启动窗口已关闭。"
    } catch {
        Write-UiLog ("关闭启动窗口失败: " + $_.Exception.Message)
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
        "-ForceOpenPage"
    )

    $script:StartupProcess = Start-Process powershell.exe -ArgumentList $startupArgs -WindowStyle Hidden -PassThru
    Write-UiLog ("已拉起启动服务 PID={0}" -f $script:StartupProcess.Id)
}

function Arm-AutoMinimize {
    param(
        [int]$MinimumVisibleSeconds = 8,
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
    Write-UiLog "检测到已有启动窗口，直接打开当前扫码页。"
    $existingTarget = if (Test-Path $QrHtmlFile) { $QrHtmlFile } else { (Resolve-OpenTarget) }
    [void](Invoke-ShellOpen -Target $existingTarget)
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
        Background="#E9EFF6"
        ShowInTaskbar="False"
        FontFamily="Microsoft YaHei UI"
        SnapsToDevicePixels="True">
    <Window.Resources>
        <Style x:Key="ActionButtonStyle" TargetType="Button">
            <Setter Property="Height" Value="44"/>
            <Setter Property="Padding" Value="16,0"/>
            <Setter Property="Margin" Value="0,0,12,0"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#D7E1EC"/>
            <Setter Property="Background" Value="#EAF1F8"/>
            <Setter Property="Foreground" Value="#2B3F57"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="12">
                            <Border.Effect>
                                <DropShadowEffect BlurRadius="10"
                                                  ShadowDepth="3"
                                                  Direction="270"
                                                  Opacity="0.16"
                                                  Color="#A4B3C2"/>
                            </Border.Effect>
                            <ContentPresenter HorizontalAlignment="Center"
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
                <GradientStop Color="#EAF1F8" Offset="0"/>
                <GradientStop Color="#DCE5F0" Offset="1"/>
            </LinearGradientBrush>
        </Grid.Background>

        <Border Margin="28"
                CornerRadius="22"
                Background="#E8EFF6"
                BorderBrush="#F7FAFD"
                BorderThickness="1">
            <Border.Effect>
                <DropShadowEffect BlurRadius="24" ShadowDepth="8" Direction="315" Color="#93A5B8" Opacity="0.23"/>
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
                            Background="#D08A35"
                            CornerRadius="8"/>
                    <Border Width="14"
                            Height="8"
                            Margin="0,0,8,0"
                            Background="#E6C79D"
                            CornerRadius="8"/>
                    <Border Width="14"
                            Height="8"
                            Background="#CFDBE8"
                            CornerRadius="8"/>
                </StackPanel>

                <Border Grid.Row="1"
                        Grid.Column="0"
                        Padding="26"
                        CornerRadius="18"
                        Background="#EEF3F9"
                        BorderBrush="#F7FAFD"
                        BorderThickness="1">
                    <Border.Effect>
                        <DropShadowEffect BlurRadius="16" ShadowDepth="6" Direction="315" Color="#A5B5C6" Opacity="0.2"/>
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
                                CornerRadius="14"
                                Background="#D08A35">
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
                                     Fill="#F1F5FA"
                                     Stroke="#F8FBFE"
                                     StrokeThickness="2"/>
                            <Ellipse x:Name="HeroRing"
                                     Width="132"
                                     Height="132"
                                     Stroke="#D6E0EC"
                                     StrokeThickness="14"
                                     Fill="Transparent"/>
                            <Ellipse x:Name="HeroAccent"
                                     Width="84"
                                     Height="84"
                                     Fill="#D08A35"
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
                                       Text="&#x6B63;&#x5728;&#x51C6;&#x5907;&#x542F;&#x52A8;&#x73AF;&#x5883;"
                                       Margin="0,8,0,8"
                                       FontSize="28"
                                       FontWeight="Bold"
                                       Foreground="#24384F"
                                       TextWrapping="Wrap"/>
                            <TextBlock x:Name="HeroSubtitle"
                                       Text="&#x4F1A;&#x5148;&#x68C0;&#x67E5;&#x6B8B;&#x7559;&#x8FDB;&#x7A0B;&#x3001;&#x7AEF;&#x53E3;&#x548C;&#x542F;&#x52A8;&#x73AF;&#x5883;&#x3002;"
                                       FontSize="16"
                                       Foreground="#6B7D92"
                                       TextWrapping="Wrap"/>
                        </StackPanel>
                    </Grid>
                </Border>

                <Border Grid.Row="1"
                        Grid.Column="2"
                        Padding="30"
                        CornerRadius="18"
                        Background="#EEF3F9"
                        BorderBrush="#F7FAFD"
                        BorderThickness="1">
                    <Border.Effect>
                        <DropShadowEffect BlurRadius="16" ShadowDepth="6" Direction="315" Color="#A5B5C6" Opacity="0.2"/>
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
                                   Foreground="#24384F"/>

                        <TextBlock x:Name="SubtitleText"
                                   Grid.Row="1"
                                   Margin="0,12,0,0"
                                   Text="&#x901A;&#x5E38;&#x7EA6; 8-20 &#x79D2;&#xFF0C;&#x7F51;&#x7EDC;&#x8F83;&#x6162;&#x65F6;&#x53EF;&#x80FD;&#x5230; 30 &#x79D2;&#x3002;"
                                   FontSize="18"
                                   Foreground="#6B7D92"
                                   TextWrapping="Wrap"/>

                        <StackPanel Grid.Row="2"
                                    Margin="0,28,0,0"
                                    Orientation="Horizontal">
                            <Border x:Name="StageChipOne"
                                    Padding="16,8"
                                    Margin="0,0,12,0"
                                    CornerRadius="14"
                                    Background="#F4E5CF"
                                    BorderBrush="#EACFA9"
                                    BorderThickness="1">
                                <TextBlock Text="&#x68C0;&#x67E5;&#x73AF;&#x5883;"
                                           FontSize="16"
                                           FontWeight="SemiBold"
                                           Foreground="#D08A35"/>
                            </Border>
                            <Border x:Name="StageChipTwo"
                                    Padding="16,8"
                                    Margin="0,0,12,0"
                                    CornerRadius="14"
                                    Background="#EEF3F9"
                                    BorderBrush="#D9E3EE"
                                    BorderThickness="1">
                                <TextBlock Text="&#x542F;&#x52A8;&#x540C;&#x6B65;"
                                           FontSize="16"
                                           FontWeight="SemiBold"
                                           Foreground="#6B7D92"/>
                            </Border>
                            <Border x:Name="StageChipThree"
                                    Padding="16,8"
                                    CornerRadius="14"
                                    Background="#EEF3F9"
                                    BorderBrush="#D9E3EE"
                                    BorderThickness="1">
                                <TextBlock Text="&#x6253;&#x5F00;&#x626B;&#x7801;&#x9875;"
                                           FontSize="16"
                                           FontWeight="SemiBold"
                                           Foreground="#6B7D92"/>
                            </Border>
                        </StackPanel>

                        <TextBlock x:Name="DetailText"
                                   Grid.Row="3"
                                   Margin="0,28,0,0"
                                   Text="&#x6B63;&#x5728;&#x68C0;&#x67E5;&#x73AF;&#x5883;..."
                                   FontSize="23"
                                   FontWeight="SemiBold"
                                   Foreground="#24384F"
                                   TextWrapping="Wrap"/>

                        <TextBlock x:Name="TipText"
                                   Grid.Row="4"
                                   Margin="0,14,0,0"
                                   Text="&#x901A;&#x5E38;&#x7EA6; 8-20 &#x79D2;&#xFF0C;&#x7F51;&#x7EDC;&#x6162;&#x65F6;&#x53EF;&#x80FD;&#x5230; 30 &#x79D2;&#x3002;"
                                   FontSize="16"
                                   Foreground="#6B7D92"
                                   TextWrapping="Wrap"/>

                        <Grid Grid.Row="5" Margin="0,34,0,0" VerticalAlignment="Bottom">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <Border x:Name="ProgressTrack"
                                    Height="14"
                                    Background="#D9E4EF"
                                    CornerRadius="8"
                                    SnapsToDevicePixels="True">
                                <Grid ClipToBounds="True">
                                    <Border x:Name="ProgressFill"
                                            HorizontalAlignment="Left"
                                            Width="150"
                                            Background="#D08A35"
                                            CornerRadius="8">
                                        <Border.RenderTransform>
                                            <TranslateTransform X="-150"/>
                                        </Border.RenderTransform>
                                    </Border>
                                    <Border x:Name="ProgressShimmer"
                                            Width="110"
                                            HorizontalAlignment="Left"
                                            CornerRadius="8"
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
                                       Foreground="#6B7D92"
                                       TextWrapping="Wrap"/>
                        </Grid>

                        <StackPanel Grid.Row="6"
                                    Margin="0,28,0,0"
                                    Orientation="Horizontal"
                                    HorizontalAlignment="Left">
                            <Button x:Name="OpenButton"
                                    Content="&#x6253;&#x5F00;&#x626B;&#x7801;&#x9875;"
                                    Style="{StaticResource ActionButtonStyle}"
                                    Width="140"
                                    Visibility="Collapsed"/>
                            <Button x:Name="CopyButton"
                                    Content="&#x590D;&#x5236;&#x624B;&#x673A;&#x5730;&#x5740;"
                                    Style="{StaticResource ActionButtonStyle}"
                                    Width="146"
                                    Visibility="Collapsed"/>
                            <Button x:Name="LogButton"
                                    Content="&#x67E5;&#x770B;&#x65E5;&#x5FD7;"
                                    Style="{StaticResource ActionButtonStyle}"
                                    Width="116"
                                    Visibility="Collapsed"/>
                            <Button x:Name="CloseButton"
                                    Content="&#x6682;&#x65F6;&#x6536;&#x8D77;"
                                    Style="{StaticResource ActionButtonStyle}"
                                    Width="136"
                                    Margin="0"/>
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
        $button.Background = New-Brush "#EAF1F8"
        $button.BorderBrush = New-Brush "#D7E1EC"
        $button.Foreground = New-Brush "#2B3F57"
    }
    $script:OpenButton.Background = New-Brush "#D08A35"
    $script:OpenButton.BorderBrush = New-Brush "#D08A35"
    $script:OpenButton.Foreground = New-Brush "#FFFFFF"

    Set-BadgeState -State "running"
    Update-Chips -State "running" -Percent 12
    Update-ProgressFill -State "running" -Percent 12
    Update-HeroCopy -State "running" -Percent 12
    Set-ProgressTarget -Percent 18

    $script:ProgressTrack.Add_SizeChanged({
        Update-ProgressFill -State $script:CurrentState -Percent $script:CurrentPercent
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
    $animationTimer.Interval = [TimeSpan]::FromMilliseconds(72)
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
            if (($script:AnimationTick % 8) -eq 0) {
                $index = [int](($script:AnimationTick / 8) % $script:TipMessages.Count)
                $script:TipText.Text = $script:TipMessages[$index]
                Update-StartupEstimate -Percent $script:CurrentPercent
            }

            $trackWidth = [Math]::Max(160, $script:ProgressTrack.ActualWidth)
            $travelWidth = [Math]::Max(220, [int]($trackWidth + $script:ProgressFill.Width + 30))
            $segmentOffset = (($script:AnimationTick * 34) % $travelWidth) - $script:ProgressFill.Width
            $script:ProgressFill.RenderTransform.X = $segmentOffset
            $script:ProgressShimmer.RenderTransform.X = $segmentOffset + 54
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
    $launchTimer.Interval = [TimeSpan]::FromMilliseconds(60)
    $launchTimer.Add_Tick({
        $launchTimer.Stop()
        Start-BackendLaunch
    })

    $pollTimer = New-Object System.Windows.Threading.DispatcherTimer
    $pollTimer.Interval = [TimeSpan]::FromMilliseconds(140)
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
                Update-ProgressFill -State "success" -Percent 100
                Update-HeroCopy -State "success" -Percent 100
                $script:CloseButton.Content = "暂时收起"
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
                Update-ProgressFill -State "error" -Percent 100
                Update-HeroCopy -State "error" -Percent 100
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
            Update-ProgressFill -State "running" -Percent $percent
            Update-HeroCopy -State "running" -Percent $percent
            $script:CloseButton.Content = "暂时收起"
            if (-not [string]::IsNullOrWhiteSpace([string]$status.title)) {
                $script:TitleText.Text = [string]$status.title
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$status.detail)) {
                $script:DetailText.Text = [string]$status.detail
            }
            Update-StartupEstimate -Percent $percent
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
            Update-ProgressFill -State "error" -Percent 100
            Update-HeroCopy -State "error" -Percent 100
            $script:LogButton.Visibility = "Visible"
        }
    })

    $window.Add_ContentRendered({
        if (-not $script:WindowShownAt) {
            $script:WindowShownAt = Get-Date
            Write-UiLog "启动窗口已显示。"
            Update-StartupEstimate -Percent $script:CurrentPercent
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
