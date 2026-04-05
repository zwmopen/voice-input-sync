param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
[System.Windows.Forms.Application]::EnableVisualStyles()

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDir = Split-Path -Parent $BaseDir
$LogsDir = Join-Path $PackageDir "logs"
$LatestUrlFile = Join-Path $PackageDir "latest-url.txt"
$QrHtmlFile = Join-Path $PackageDir "手机扫码打开.html"
$StopScript = Join-Path $BaseDir "portable-stop.ps1"
$IconPath = Join-Path $BaseDir "assets\voice-sync-icon.ico"
$MutexName = "Local\VoiceInputSyncPortableTray"
$TrayMutex = $null
$OwnsTrayMutex = $false

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

if (-not (Enter-TrayMutex)) {
    Write-Log "Tray already running."
    exit 0
}

$titleText = Get-UiText 0x8BED,0x97F3,0x8F93,0x5165,0x540C,0x6B65
$openQrLabel = Get-UiText 0x6253,0x5F00,0x626B,0x7801,0x754C,0x9762
$openMobileLabel = Get-UiText 0x6253,0x5F00,0x624B,0x673A,0x9875,0x9762
$copyLabel = Get-UiText 0x590D,0x5236,0x624B,0x673A,0x5730,0x5740
$exitLabel = Get-UiText 0x9000,0x51FA,0x8BED,0x97F3,0x8F93,0x5165,0x540C,0x6B65
$qrOpenFailedText = Get-UiText 0x626B,0x7801,0x754C,0x9762,0x6682,0x65F6,0x8FD8,0x6CA1,0x51C6,0x5907,0x597D,0x3002
$pendingText = Get-UiText 0x8FD8,0x6CA1,0x62FF,0x5230,0x624B,0x673A,0x5730,0x5740,0xFF0C,0x8BF7,0x7A0D,0x540E,0x518D,0x8BD5,0x3002
$copiedText = Get-UiText 0x624B,0x673A,0x5730,0x5740,0x5DF2,0x7ECF,0x590D,0x5236,0x3002
$copyFailedText = Get-UiText 0x590D,0x5236,0x5931,0x8D25,0xFF0C,0x8BF7,0x7A0D,0x540E,0x91CD,0x8BD5,0x3002
$openFailedText = Get-UiText 0x624B,0x673A,0x9875,0x9762,0x6682,0x65F6,0x8FD8,0x6CA1,0x51C6,0x5907,0x597D,0x3002
$readyText = Get-UiText 0x5DF2,0x7ECF,0x5728,0x540E,0x53F0,0x5F85,0x547D,0x3002,0x53CC,0x51FB,0x6258,0x76D8,0x56FE,0x6807,0x53EF,0x4EE5,0x91CD,0x65B0,0x6253,0x5F00,0x624B,0x673A,0x9875,0x9762,0x3002

$notifyIcon = $null

try {
    $context = New-Object System.Windows.Forms.ApplicationContext
    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $openQrItem = $menu.Items.Add($openQrLabel)
    $openMobileItem = $menu.Items.Add($openMobileLabel)
    $copyItem = $menu.Items.Add($copyLabel)
    [void]$menu.Items.Add("-")
    $exitItem = $menu.Items.Add($exitLabel)

    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    if (Test-Path $IconPath) {
        try {
            $notifyIcon.Icon = New-Object System.Drawing.Icon($IconPath)
        } catch {
        }
    }
    $notifyIcon.Text = $titleText
    $notifyIcon.ContextMenuStrip = $menu
    $notifyIcon.Visible = $true

    $openQrAction = {
        if (-not (Open-Target -Target $QrHtmlFile)) {
            Show-Balloon -NotifyIcon $notifyIcon -Title $titleText -Text $qrOpenFailedText -Icon ([System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }

    $openMobileAction = {
        $target = Read-LatestUrl
        if (-not (Open-Target -Target $target)) {
            Show-Balloon -NotifyIcon $notifyIcon -Title $titleText -Text $openFailedText -Icon ([System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }

    $openQrItem.add_Click($openQrAction)
    $openMobileItem.add_Click($openMobileAction)
    $notifyIcon.add_DoubleClick($openQrAction)

    $copyItem.add_Click({
        $url = Read-LatestUrl
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
    })

    $exitItem.add_Click({
        try {
            if (Test-Path $StopScript) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $StopScript -Silent
            }
        } catch {
            Write-Log ("Stop script failed: " + $_.Exception.Message)
        } finally {
            $context.ExitThread()
        }
    })

    Show-Balloon -NotifyIcon $notifyIcon -Title $titleText -Text $readyText -Icon ([System.Windows.Forms.ToolTipIcon]::Info)
    Write-Log "Tray started."
    [System.Windows.Forms.Application]::Run($context)
} finally {
    if ($notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }
    Exit-TrayMutex
    Write-Log "Tray exited."
}
