param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
[System.Windows.Forms.Application]::EnableVisualStyles()

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDir = Split-Path -Parent $BaseDir
$LogsDir = Join-Path $PackageDir "logs"
$LatestUrlFile = Join-Path $PackageDir "latest-url.txt"
$RuntimeConfigFile = Join-Path $BaseDir "runtime-config.json"
$QrHtmlFile = Join-Path $PackageDir ((-join ([int[]](0x624B,0x673A,0x626B,0x7801,0x6253,0x5F00) | ForEach-Object { [char]$_ })) + ".html")
$StopScript = Join-Path $BaseDir "portable-stop.ps1"
$IconPath = Join-Path $BaseDir "assets\voice-sync-icon.ico"
$MutexName = "Local\VoiceInputSyncPortableTray"
$TrayMutex = $null
$OwnsTrayMutex = $false
$script:AllowMenuClose = $false

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

function New-Color {
    param([string]$Hex)

    return [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

function Set-RoundedRegion {
    param(
        [System.Windows.Forms.Control]$Control,
        [int]$Radius
    )

    if (-not $Control -or $Control.Width -le 1 -or $Control.Height -le 1) {
        return
    }

    $diameter = [Math]::Max(2, $Radius * 2)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rect = [System.Drawing.Rectangle]::new(
        0,
        0,
        [Math]::Max(1, $Control.Width - 1),
        [Math]::Max(1, $Control.Height - 1)
    )

    $path.AddArc($rect.X, $rect.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($rect.Right - $diameter, $rect.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($rect.Right - $diameter, $rect.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()

    if ($Control.Region) {
        $Control.Region.Dispose()
    }

    $Control.Region = New-Object System.Drawing.Region($path)
    $path.Dispose()
}

function New-MenuButton {
    param(
        [string]$Text,
        [int]$Top,
        [System.Drawing.Color]$BaseColor,
        [System.Drawing.Color]$HoverColor,
        [System.Drawing.Color]$ForeColor,
        [float]$FontSize = 10.5
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point(18, $Top)
    $button.Size = New-Object System.Drawing.Size(248, 42)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $BaseColor
    $button.ForeColor = $ForeColor
    $button.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", $FontSize, [System.Drawing.FontStyle]::Bold)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $button.Padding = New-Object System.Windows.Forms.Padding(16, 0, 0, 0)
    $button.UseVisualStyleBackColor = $false
    $button.Tag = [pscustomobject]@{
        BaseColor = $BaseColor
        HoverColor = $HoverColor
        ForeColor = $ForeColor
    }

    $button.Add_MouseEnter({
        $sender = [System.Windows.Forms.Button]$this
        $sender.BackColor = $sender.Tag.HoverColor
    })

    $button.Add_MouseLeave({
        $sender = [System.Windows.Forms.Button]$this
        $sender.BackColor = $sender.Tag.BaseColor
    })

    $button.Add_SizeChanged({
        Set-RoundedRegion -Control $this -Radius 14
    })

    return $button
}

function Resolve-MenuLocation {
    param([System.Windows.Forms.Form]$Form)

    $cursor = [System.Windows.Forms.Cursor]::Position
    $screen = [System.Windows.Forms.Screen]::FromPoint($cursor)
    $workArea = $screen.WorkingArea

    $x = $cursor.X - [Math]::Min(26, [int]($Form.Width / 6))
    $y = $cursor.Y - [Math]::Min(24, [int]($Form.Height / 8))

    if (($x + $Form.Width) -gt $workArea.Right) {
        $x = $workArea.Right - $Form.Width - 10
    }
    if (($y + $Form.Height) -gt $workArea.Bottom) {
        $y = $workArea.Bottom - $Form.Height - 10
    }
    if ($x -lt $workArea.Left + 8) {
        $x = $workArea.Left + 8
    }
    if ($y -lt $workArea.Top + 8) {
        $y = $workArea.Top + 8
    }

    return New-Object System.Drawing.Point($x, $y)
}

if (-not (Enter-TrayMutex)) {
    Write-Log "Tray already running."
    exit 0
}

$titleText = Get-UiText 0x8BED,0x97F3,0x8F93,0x5165,0x540C,0x6B65
$subtitleText = Get-UiText 0x5C40,0x57DF,0x7F51,0x4F18,0x5148,0xFF0C,0x4E92,0x8054,0x7F51,0x5907,0x7528
$openQrLabel = Get-UiText 0x6253,0x5F00,0x626B,0x7801,0x754C,0x9762
$openMobileLabel = Get-UiText 0x6253,0x5F00,0x624B,0x673A,0x9875,0x9762
$copyLabel = Get-UiText 0x590D,0x5236,0x624B,0x673A,0x5730,0x5740
$exitLabel = Get-UiText 0x9000,0x51FA,0x8BED,0x97F3,0x8F93,0x5165,0x540C,0x6B65
$qrOpenFailedText = Get-UiText 0x626B,0x7801,0x754C,0x9762,0x6682,0x65F6,0x8FD8,0x6CA1,0x51C6,0x5907,0x597D,0x3002
$pendingText = Get-UiText 0x8FD8,0x6CA1,0x62FF,0x5230,0x624B,0x673A,0x5730,0x5740,0xFF0C,0x8BF7,0x7A0D,0x540E,0x518D,0x8BD5,0x3002
$copiedText = Get-UiText 0x624B,0x673A,0x5730,0x5740,0x5DF2,0x7ECF,0x590D,0x5236,0x3002
$copyFailedText = Get-UiText 0x590D,0x5236,0x5931,0x8D25,0xFF0C,0x8BF7,0x7A0D,0x540E,0x91CD,0x8BD5,0x3002
$openFailedText = Get-UiText 0x624B,0x673A,0x9875,0x9762,0x6682,0x65F6,0x8FD8,0x6CA1,0x51C6,0x5907,0x597D,0x3002
$readyText = Get-UiText 0x5DF2,0x7ECF,0x5728,0x540E,0x53F0,0x5F85,0x547D,0x3002,0x53CC,0x51FB,0x6258,0x76D8,0x56FE,0x6807,0x53EF,0x4EE5,0x91CD,0x65B0,0x6253,0x5F00,0x626B,0x7801,0x9875,0x3002
$headerHintText = Get-UiText 0x6258,0x76D8,0x5FEB,0x6377,0x64CD,0x4F5C

$menuBackColor = New-Color "#EDF2F7"
$cardColor = New-Color "#E7ECF2"
$accentColor = New-Color "#D07F2A"
$accentSoftColor = New-Color "#F2E7D9"
$neutralSoftColor = New-Color "#F6F9FC"
$greenSoftColor = New-Color "#E7F3EC"
$dangerSoftColor = New-Color "#F6E7E7"
$textColor = New-Color "#2B3B4F"
$mutedColor = New-Color "#748396"
$dangerColor = New-Color "#B9514D"
$separatorColor = New-Color "#D8E0E9"

$notifyIcon = $null
$menuForm = $null
$context = $null

try {
    $context = New-Object System.Windows.Forms.ApplicationContext

    $menuForm = New-Object System.Windows.Forms.Form
    $menuForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $menuForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $menuForm.ShowInTaskbar = $false
    $menuForm.TopMost = $true
    $menuForm.BackColor = $menuBackColor
    $menuForm.ClientSize = New-Object System.Drawing.Size(286, 282)
    $menuForm.KeyPreview = $true

    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point(0, 0)
    $card.Size = $menuForm.ClientSize
    $card.BackColor = $cardColor
    $card.Padding = New-Object System.Windows.Forms.Padding(0)
    $menuForm.Controls.Add($card)

    $accentBar = New-Object System.Windows.Forms.Panel
    $accentBar.Location = New-Object System.Drawing.Point(18, 14)
    $accentBar.Size = New-Object System.Drawing.Size(76, 5)
    $accentBar.BackColor = $accentColor
    $card.Controls.Add($accentBar)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $titleText
    $titleLabel.Location = New-Object System.Drawing.Point(18, 28)
    $titleLabel.Size = New-Object System.Drawing.Size(200, 28)
    $titleLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 12.5, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = $textColor
    $card.Controls.Add($titleLabel)

    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Text = $subtitleText
    $subtitleLabel.Location = New-Object System.Drawing.Point(18, 56)
    $subtitleLabel.Size = New-Object System.Drawing.Size(210, 18)
    $subtitleLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8.9, [System.Drawing.FontStyle]::Regular)
    $subtitleLabel.ForeColor = $mutedColor
    $card.Controls.Add($subtitleLabel)

    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Text = $headerHintText
    $hintLabel.Location = New-Object System.Drawing.Point(18, 82)
    $hintLabel.Size = New-Object System.Drawing.Size(120, 18)
    $hintLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8.6, [System.Drawing.FontStyle]::Bold)
    $hintLabel.ForeColor = $accentColor
    $card.Controls.Add($hintLabel)

    $openQrButton = New-MenuButton -Text $openQrLabel -Top 108 -BaseColor $accentSoftColor -HoverColor (New-Color "#EBCFAD") -ForeColor $accentColor
    $openMobileButton = New-MenuButton -Text $openMobileLabel -Top 156 -BaseColor $greenSoftColor -HoverColor (New-Color "#D8ECDD") -ForeColor (New-Color "#2C7A58")
    $copyButton = New-MenuButton -Text $copyLabel -Top 204 -BaseColor $neutralSoftColor -HoverColor (New-Color "#E7EEF6") -ForeColor $textColor

    $separator = New-Object System.Windows.Forms.Panel
    $separator.Location = New-Object System.Drawing.Point(18, 252)
    $separator.Size = New-Object System.Drawing.Size(248, 1)
    $separator.BackColor = $separatorColor

    $exitButton = New-MenuButton -Text $exitLabel -Top 262 -BaseColor $dangerSoftColor -HoverColor (New-Color "#ECD6D6") -ForeColor $dangerColor
    $exitButton.Size = New-Object System.Drawing.Size(248, 42)
    $menuForm.ClientSize = New-Object System.Drawing.Size(286, 322)
    $card.Size = $menuForm.ClientSize

    foreach ($control in @($openQrButton, $openMobileButton, $copyButton, $separator, $exitButton)) {
        $card.Controls.Add($control)
    }

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
        if ($menuForm -and $menuForm.Visible) {
            $menuForm.Hide()
        }
    }

    function Update-MenuAvailability {
        $preferredUrl = Get-PreferredMobileUrl
        $hasUrl = -not [string]::IsNullOrWhiteSpace($preferredUrl)

        foreach ($button in @($openMobileButton, $copyButton)) {
            if ($hasUrl) {
                $button.Enabled = $true
                $button.ForeColor = $button.Tag.ForeColor
                $button.BackColor = $button.Tag.BaseColor
            } else {
                $button.Enabled = $false
                $button.ForeColor = $mutedColor
                $button.BackColor = New-Color "#E4EAF1"
            }
        }
    }

    function Show-CustomMenu {
        Update-MenuAvailability
        $menuForm.Location = Resolve-MenuLocation -Form $menuForm
        $menuForm.Show()
        $menuForm.Activate()
        Write-Log "Tray menu opened."
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

    $exitAction = {
        Hide-CustomMenu
        try {
            if (Test-Path $StopScript) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StopScript -Silent
            }
        } catch {
            Write-Log ("Stop script failed: " + $_.Exception.Message)
        } finally {
            $script:AllowMenuClose = $true
            if ($menuForm) {
                $menuForm.Close()
            }
            $context.ExitThread()
        }
    }

    $openQrButton.Add_Click($openQrAction)
    $openMobileButton.Add_Click($openMobileAction)
    $copyButton.Add_Click($copyAction)
    $exitButton.Add_Click($exitAction)

    $notifyIcon.Add_MouseUp({
        param($sender, $e)

        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            if ($menuForm.Visible) {
                Hide-CustomMenu
            } else {
                Show-CustomMenu
            }
        }
    })

    $notifyIcon.Add_DoubleClick($openQrAction)

    $menuForm.Add_Deactivate({
        Hide-CustomMenu
    })

    $menuForm.Add_KeyDown({
        param($sender, $e)

        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
            Hide-CustomMenu
        }
    })

    $menuForm.Add_FormClosing({
        param($sender, $e)

        if (-not $script:AllowMenuClose) {
            $e.Cancel = $true
            Hide-CustomMenu
        }
    })

    $menuForm.Add_SizeChanged({
        Set-RoundedRegion -Control $menuForm -Radius 24
        Set-RoundedRegion -Control $card -Radius 22
    })

    Set-RoundedRegion -Control $menuForm -Radius 24
    Set-RoundedRegion -Control $card -Radius 22
    foreach ($button in @($openQrButton, $openMobileButton, $copyButton, $exitButton)) {
        Set-RoundedRegion -Control $button -Radius 14
    }

    Show-Balloon -NotifyIcon $notifyIcon -Title $titleText -Text $readyText -Icon ([System.Windows.Forms.ToolTipIcon]::Info)
    Write-Log "Tray started."
    [System.Windows.Forms.Application]::Run($context)
} finally {
    if ($menuForm) {
        $script:AllowMenuClose = $true
        $menuForm.Dispose()
    }
    if ($notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
    Exit-TrayMutex
    Write-Log "Tray exited."
}
