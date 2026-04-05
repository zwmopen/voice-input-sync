param(
    [switch]$ForceCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDir = Split-Path -Parent $BaseDir
$LogsDir = Join-Path $PackageDir "logs"
$BuildInfoFile = Join-Path $BaseDir "build-info.json"
$UpdateStatusFile = Join-Path $LogsDir "update-status.json"
$UpdateCheckScript = Join-Path $BaseDir "portable-check-update.ps1"
$IconPath = Join-Path $BaseDir "assets\\voice-sync-icon.ico"

function Get-UiText {
    param([int[]]$Codes)

    return (-join ($Codes | ForEach-Object { [char]$_ }))
}

function New-Brush {
    param([string]$Color)

    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
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
    param([switch]$Force)

    if (-not (Test-Path $UpdateCheckScript)) {
        return
    }

    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $UpdateCheckScript)
    if ($Force) {
        $arguments += "-Force"
    }

    Start-Process -FilePath (Get-Command powershell.exe).Source -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

$windowTitleText = (Get-UiText 0x8BED,0x97F3,0x8F93,0x5165,0x540C,0x6B65) + " - " + (Get-UiText 0x8BBE,0x7F6E)
$headerTitleText = Get-UiText 0x7248,0x672C,0x4E0E,0x66F4,0x65B0
$headerHintText = (-join @(
    (Get-UiText 0x5BA2,0x6237,0x7AEF,0x4F1A,0x81EA,0x52A8,0x68C0,0x67E5),
    " GitHub ",
    (Get-UiText 0x6700,0x65B0,0x7248,0x672C),
    "."
))
$currentVersionLabelText = Get-UiText 0x5F53,0x524D,0x7248,0x672C
$latestVersionLabelText = Get-UiText 0x6700,0x65B0,0x7248,0x672C
$checkNowText = Get-UiText 0x7ACB,0x5373,0x68C0,0x67E5
$openDownloadText = Get-UiText 0x6253,0x5F00,0x4E0B,0x8F7D,0x9875
$closeText = Get-UiText 0x5173,0x95ED
$checkingText = Get-UiText 0x68C0,0x67E5,0x4E2D
$fetchingText = Get-UiText 0x6B63,0x5728,0x83B7,0x53D6
$checkingHintText = (-join @(
    (Get-UiText 0x6B63,0x5728,0x5411),
    " GitHub ",
    (Get-UiText 0x68C0,0x67E5,0x6700,0x65B0,0x7248,0x672C),
    "."
))
$unknownText = Get-UiText 0x672A,0x77E5
$missingVersionText = Get-UiText 0x672A,0x62FF,0x5230,0x7248,0x672C,0x53F7
$checkedAtPrefixText = Get-UiText 0x6700,0x8FD1,0x68C0,0x67E5,0xFF1A
$hasUpdateText = Get-UiText 0x6709,0x65B0,0x7248,0x672C
$checkFailedText = Get-UiText 0x68C0,0x67E5,0x5931,0x8D25
$alreadyLatestText = Get-UiText 0x5DF2,0x662F,0x6700,0x65B0
$updateMessageText = (-join @(
    (Get-UiText 0x53D1,0x73B0,0x65B0,0x7248,0x672C),
    ", ",
    (Get-UiText 0x53EF,0x4EE5,0x6253,0x5F00,0x4E0B,0x8F7D,0x9875),
    "."
))
$latestMessageText = (-join @(
    (Get-UiText 0x5F53,0x524D,0x5DF2,0x662F,0x6700,0x65B0,0x7248,0x672C),
    "."
))
$errorMessageText = (-join @(
    (Get-UiText 0x6682,0x65F6,0x8FD8,0x6CA1,0x8FDE,0x4E0A),
    " GitHub, ",
    (Get-UiText 0x7A0D,0x540E,0x518D,0x8BD5),
    "."
))
$emptyMessageText = (-join @(
    (Get-UiText 0x6682,0x65F6,0x6CA1,0x6709,0x62FF,0x5230),
    (Get-UiText 0x66F4,0x65B0,0x4FE1,0x606F),
    "."
))

$buildInfo = Read-BuildInfo
$currentVersion = ""
if ($buildInfo) {
    $currentVersion = [string]$buildInfo.appVersion
    if ([string]::IsNullOrWhiteSpace($currentVersion)) {
        $currentVersion = [string]$buildInfo.gitCommit
    }
}
if ([string]::IsNullOrWhiteSpace($currentVersion)) {
    $currentVersion = $unknownText
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="420"
        Height="288"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="#E8EEF4"
        FontFamily="Microsoft YaHei UI">
  <Border Margin="14"
          CornerRadius="28"
          Background="#EEF3F8"
          BorderBrush="#F8FBFE"
          BorderThickness="1">
    <Border.Effect>
      <DropShadowEffect BlurRadius="20" ShadowDepth="10" Direction="270" Color="#95A6B6" Opacity="0.18"/>
    </Border.Effect>
    <Grid Margin="22">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0">
        <TextBlock x:Name="HeaderTitleText"
                   FontSize="24"
                   FontWeight="Bold"
                   Foreground="#213244"/>
        <TextBlock x:Name="HeaderHintText"
                   Margin="0,8,0,0"
                   FontSize="13.2"
                   Foreground="#708093"/>
      </StackPanel>

      <Border Grid.Row="1"
              Margin="0,18,0,0"
              Padding="14,10"
              CornerRadius="18"
              Background="#F4F8FC"
              BorderBrush="#F8FBFE"
              BorderThickness="1">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock x:Name="CurrentVersionLabelText"
                       FontSize="12"
                       FontWeight="Bold"
                       Foreground="#7A8898"/>
            <TextBlock x:Name="CurrentVersionText"
                       Margin="0,5,0,0"
                       FontSize="18"
                       FontWeight="Bold"
                       Foreground="#213244"/>
          </StackPanel>
          <Border x:Name="StatusPill"
                  Grid.Column="1"
                  Padding="12,7"
                  CornerRadius="999"
                  Background="#E7EDF4"
                  VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="StatusDot"
                       Width="8"
                       Height="8"
                       Margin="0,0,8,0"
                       Fill="#7E8D9D"/>
              <TextBlock x:Name="StatusText"
                         FontSize="13"
                         FontWeight="Bold"
                         Foreground="#4E6278"/>
            </StackPanel>
          </Border>
        </Grid>
      </Border>

      <Grid Grid.Row="2" Margin="0,16,0,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0"
                Padding="14,12"
                CornerRadius="18"
                Background="#F4F8FC"
                BorderBrush="#F8FBFE"
                BorderThickness="1">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="LatestVersionLabelText"
                       FontSize="12"
                       FontWeight="Bold"
                       Foreground="#7A8898"/>
            <TextBlock x:Name="LatestVersionText"
                       Grid.Column="1"
                       HorizontalAlignment="Right"
                       FontSize="14"
                       FontWeight="Bold"
                       Foreground="#244A73"/>
          </Grid>
        </Border>

        <Border Grid.Row="1"
                Margin="0,12,0,0"
                Padding="14,12"
                CornerRadius="18"
                Background="#F4F8FC"
                BorderBrush="#F8FBFE"
                BorderThickness="1">
          <TextBlock x:Name="MessageText"
                     FontSize="13.2"
                     Foreground="#627283"
                     TextWrapping="Wrap"/>
        </Border>

        <TextBlock x:Name="CheckedAtText"
                   Grid.Row="2"
                   Margin="2,12,0,0"
                   FontSize="11.5"
                   Foreground="#8A97A6"/>
      </Grid>

      <Grid Grid.Row="3" Margin="0,18,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="12"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="12"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Button x:Name="CheckButton"
                Grid.Column="0"
                Height="40"/>
        <Button x:Name="ReleaseButton"
                Grid.Column="2"
                Height="40"/>
        <Button x:Name="CloseButton"
                Grid.Column="4"
                Height="40"/>
      </Grid>
    </Grid>
  </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)
$window.Title = $windowTitleText
$window.Background = New-Brush "#E8EEF4"

if (Test-Path $IconPath) {
    try {
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]((Resolve-Path -LiteralPath $IconPath).Path))
    } catch {
    }
}

$headerTitle = $window.FindName("HeaderTitleText")
$headerHint = $window.FindName("HeaderHintText")
$currentVersionLabel = $window.FindName("CurrentVersionLabelText")
$currentVersionText = $window.FindName("CurrentVersionText")
$statusPill = $window.FindName("StatusPill")
$statusDot = $window.FindName("StatusDot")
$statusText = $window.FindName("StatusText")
$latestVersionLabel = $window.FindName("LatestVersionLabelText")
$latestVersionText = $window.FindName("LatestVersionText")
$messageText = $window.FindName("MessageText")
$checkedAtText = $window.FindName("CheckedAtText")
$checkButton = $window.FindName("CheckButton")
$releaseButton = $window.FindName("ReleaseButton")
$closeButton = $window.FindName("CloseButton")

$headerTitle.Text = $headerTitleText
$headerHint.Text = $headerHintText
$currentVersionLabel.Text = $currentVersionLabelText
$currentVersionText.Text = $currentVersion
$latestVersionLabel.Text = $latestVersionLabelText
$checkButton.Content = $checkNowText
$releaseButton.Content = $openDownloadText
$closeButton.Content = $closeText

foreach ($button in @($checkButton, $releaseButton, $closeButton)) {
    $button.BorderThickness = 0
    $button.Cursor = [System.Windows.Input.Cursors]::Hand
    $button.FontSize = 13
    $button.FontWeight = "Bold"
}

$checkButton.Background = New-Brush "#F5E7D1"
$checkButton.Foreground = New-Brush "#C87720"
$releaseButton.Background = New-Brush "#EAF1F8"
$releaseButton.Foreground = New-Brush "#244A73"
$closeButton.Background = New-Brush "#E7EDF4"
$closeButton.Foreground = New-Brush "#4E6278"

function Update-UiFromStatus {
    $status = Read-UpdateStatus
    if (-not $status) {
        $statusPill.Background = New-Brush "#E7EDF4"
        $statusDot.Fill = New-Brush "#7E8D9D"
        $statusText.Text = $checkingText
        $statusText.Foreground = New-Brush "#4E6278"
        $latestVersionText.Text = $fetchingText
        $messageText.Text = $checkingHintText
        $checkedAtText.Text = ""
        return
    }

    $latestVersion = [string]$status.latestVersion
    $releaseUrl = [string]$status.releaseUrl
    if ([string]::IsNullOrWhiteSpace($releaseUrl)) {
        $releaseUrl = "https://github.com/zwmopen/voice-input-sync/releases/latest"
    }

    $script:ReleaseUrl = $releaseUrl
    if ([string]::IsNullOrWhiteSpace($latestVersion)) {
        $latestVersionText.Text = $missingVersionText
    } else {
        $latestVersionText.Text = $latestVersion
    }

    if ([string]::IsNullOrWhiteSpace([string]$status.checkedAt)) {
        $checkedAtText.Text = ""
    } else {
        $checkedAtText.Text = $checkedAtPrefixText + [string]$status.checkedAt
    }

    if ([bool]$status.hasUpdate) {
        $statusPill.Background = New-Brush "#E7F3EC"
        $statusDot.Fill = New-Brush "#4DB57C"
        $statusText.Text = $hasUpdateText
        $statusText.Foreground = New-Brush "#278659"
        $messageText.Text = $updateMessageText
        return
    }

    if ([string]$status.state -eq "error") {
        $statusPill.Background = New-Brush "#E7EDF4"
        $statusDot.Fill = New-Brush "#7E8D9D"
        $statusText.Text = $checkFailedText
        $statusText.Foreground = New-Brush "#4E6278"
        $messageText.Text = $errorMessageText
        return
    }

    $statusPill.Background = New-Brush "#EAF1F8"
    $statusDot.Fill = New-Brush "#4A78A9"
    $statusText.Text = $alreadyLatestText
    $statusText.Foreground = New-Brush "#244A73"
    if ([string]::IsNullOrWhiteSpace($latestVersion)) {
        $messageText.Text = $emptyMessageText
    } else {
        $messageText.Text = $latestMessageText
    }
}

$script:ReleaseUrl = "https://github.com/zwmopen/voice-input-sync/releases/latest"

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(900)
$timer.Add_Tick({
    Update-UiFromStatus
})
$timer.Start()

$checkButton.Add_Click({
    Start-UpdateCheck -Force
})

$releaseButton.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($script:ReleaseUrl)) {
        Start-Process $script:ReleaseUrl | Out-Null
    }
})

$closeButton.Add_Click({
    $window.Close()
})

$window.Add_Closed({
    $timer.Stop()
})

if ($ForceCheck -or -not (Test-Path $UpdateStatusFile)) {
    Start-UpdateCheck -Force
} else {
    Start-UpdateCheck
}

Update-UiFromStatus
$window.ShowDialog() | Out-Null
