param(
    [switch]$NoAutoClose
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDir = Split-Path -Parent $BaseDir
$LogsDir = Join-Path $PackageDir "logs"
$StartupScript = Join-Path $BaseDir "portable-start.ps1"
$StatusFile = Join-Path $LogsDir "startup-status.json"
$StartupLog = Join-Path $LogsDir "startup.log"
$IconPath = Join-Path $BaseDir "assets\voice-sync-icon.ico"
$CurrentUrl = ""
$CurrentPageTarget = ""
$PageOpened = $false
$AutoCloseQueued = $false

New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
Remove-Item $StatusFile -Force -ErrorAction SilentlyContinue

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

function Invoke-ShellOpen {
    param([string]$Target)

    if (-not $Target) {
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
        Write-UiLog ("Opened target: {0}" -f $resolvedTarget)
        return $true
    } catch {
        try {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "start", "", $Target -WindowStyle Hidden | Out-Null
            Write-UiLog ("Opened target via fallback: {0}" -f $Target)
            return $true
        } catch {
            Write-UiLog ("Open target failed: {0}" -f $_.Exception.Message)
            return $false
        }
    }
}

function Open-PageTarget {
    param(
        [string]$Target,
        [string]$FallbackUrl
    )

    if (Invoke-ShellOpen -Target $Target) {
        return $true
    }

    if ($FallbackUrl -and $FallbackUrl -ne $Target) {
        return (Invoke-ShellOpen -Target $FallbackUrl)
    }

    return $false
}

function Copy-PhoneUrl {
    if (-not $script:CurrentUrl) {
        return
    }

    try {
        Set-Clipboard -Value $script:CurrentUrl
        $script:FooterLabel.Text = "已复制手机地址，直接发给别人也可以。"
        $script:FooterLabel.ForeColor = [System.Drawing.Color]::FromArgb(39, 120, 82)
    } catch {
        [System.Windows.Forms.MessageBox]::Show("复制失败，请稍后重试。", "语音输入同步")
    }
}

$startupArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $StartupScript,
    "-Silent",
    "-OpenPageOnSuccess",
    "-StatusFile", $StatusFile
)
$StartupProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $startupArgs -WindowStyle Hidden -PassThru
Write-UiLog "Launcher window started."

$form = New-Object System.Windows.Forms.Form
$form.Text = "语音输入同步"
$form.StartPosition = "CenterScreen"
$form.ClientSize = New-Object System.Drawing.Size(470, 276)
$form.BackColor = [System.Drawing.Color]::FromArgb(244, 238, 229)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $false

if (Test-Path $IconPath) {
    try {
        $form.Icon = New-Object System.Drawing.Icon($IconPath)
    } catch {
    }
}

$card = New-Object System.Windows.Forms.Panel
$card.Size = New-Object System.Drawing.Size(430, 236)
$card.Location = New-Object System.Drawing.Point(20, 20)
$card.BackColor = [System.Drawing.Color]::FromArgb(255, 251, 244)
$card.BorderStyle = "FixedSingle"
$form.Controls.Add($card)

$topBar = New-Object System.Windows.Forms.Panel
$topBar.Location = New-Object System.Drawing.Point(0, 0)
$topBar.Size = New-Object System.Drawing.Size(430, 8)
$topBar.BackColor = [System.Drawing.Color]::FromArgb(211, 142, 50)
$card.Controls.Add($topBar)

$emojiLabel = New-Object System.Windows.Forms.Label
$emojiLabel.Location = New-Object System.Drawing.Point(24, 24)
$emojiLabel.Size = New-Object System.Drawing.Size(56, 56)
$emojiLabel.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 30, [System.Drawing.FontStyle]::Regular)
$emojiLabel.Text = "🚀"
$card.Controls.Add($emojiLabel)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Location = New-Object System.Drawing.Point(88, 24)
$titleLabel.Size = New-Object System.Drawing.Size(312, 32)
$titleLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 15, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(42, 53, 67)
$titleLabel.Text = "正在启动语音输入同步"
$card.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Location = New-Object System.Drawing.Point(90, 58)
$subtitleLabel.Size = New-Object System.Drawing.Size(300, 22)
$subtitleLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5)
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(113, 123, 137)
$subtitleLabel.Text = "通常 5 秒左右，会自动打开扫码页。"
$card.Controls.Add($subtitleLabel)

$badgeLabel = New-Object System.Windows.Forms.Label
$badgeLabel.Location = New-Object System.Drawing.Point(24, 98)
$badgeLabel.Size = New-Object System.Drawing.Size(104, 28)
$badgeLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9.5, [System.Drawing.FontStyle]::Bold)
$badgeLabel.ForeColor = [System.Drawing.Color]::White
$badgeLabel.BackColor = [System.Drawing.Color]::FromArgb(214, 140, 46)
$badgeLabel.TextAlign = "MiddleCenter"
$badgeLabel.Text = "启动中"
$card.Controls.Add($badgeLabel)

$detailLabel = New-Object System.Windows.Forms.Label
$detailLabel.Location = New-Object System.Drawing.Point(24, 138)
$detailLabel.Size = New-Object System.Drawing.Size(382, 32)
$detailLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 11)
$detailLabel.ForeColor = [System.Drawing.Color]::FromArgb(61, 73, 88)
$detailLabel.Text = "正在准备环境..."
$card.Controls.Add($detailLabel)

$footerLabel = New-Object System.Windows.Forms.Label
$footerLabel.Location = New-Object System.Drawing.Point(24, 170)
$footerLabel.Size = New-Object System.Drawing.Size(382, 18)
$footerLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8.8)
$footerLabel.ForeColor = [System.Drawing.Color]::FromArgb(122, 130, 139)
$footerLabel.Text = "准备好后会自动弹出扫码页。"
$card.Controls.Add($footerLabel)
$script:FooterLabel = $footerLabel

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(24, 192)
$progressBar.Size = New-Object System.Drawing.Size(382, 12)
$progressBar.Style = "Marquee"
$progressBar.MarqueeAnimationSpeed = 24
$card.Controls.Add($progressBar)

$actionButton = New-Object System.Windows.Forms.Button
$actionButton.Location = New-Object System.Drawing.Point(24, 208)
$actionButton.Size = New-Object System.Drawing.Size(108, 30)
$actionButton.Text = "打开扫码页"
$actionButton.Visible = $false
$actionButton.Add_Click({
    if (-not (Open-PageTarget -Target $script:CurrentPageTarget -FallbackUrl $script:CurrentUrl)) {
        [System.Windows.Forms.MessageBox]::Show("还没拿到扫码页地址，请稍后再试。", "语音输入同步")
    }
})
$card.Controls.Add($actionButton)

$copyButton = New-Object System.Windows.Forms.Button
$copyButton.Location = New-Object System.Drawing.Point(140, 208)
$copyButton.Size = New-Object System.Drawing.Size(96, 30)
$copyButton.Text = "复制地址"
$copyButton.Visible = $false
$copyButton.Add_Click({ Copy-PhoneUrl })
$card.Controls.Add($copyButton)

$logButton = New-Object System.Windows.Forms.Button
$logButton.Location = New-Object System.Drawing.Point(244, 208)
$logButton.Size = New-Object System.Drawing.Size(82, 30)
$logButton.Text = "查看日志"
$logButton.Visible = $false
$logButton.Add_Click({
    if (Test-Path $StartupLog) {
        Start-Process notepad.exe $StartupLog | Out-Null
    }
})
$card.Controls.Add($logButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Location = New-Object System.Drawing.Point(334, 208)
$closeButton.Size = New-Object System.Drawing.Size(72, 30)
$closeButton.Text = "关闭"
$closeButton.Visible = $false
$closeButton.Add_Click({ $form.Close() })
$card.Controls.Add($closeButton)

$closeTimer = New-Object System.Windows.Forms.Timer
$closeTimer.Interval = 2600
$closeTimer.Add_Tick({
    $closeTimer.Stop()
    $form.Close()
})

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 250
$pollTimer.Add_Tick({
    $status = Read-StartupStatus
    if ($status) {
        $emojiLabel.Text = if ($status.emoji) { [string]$status.emoji } else { "🚀" }
        $titleLabel.Text = if ($status.title) { [string]$status.title } else { "正在启动语音输入同步" }
        $detailLabel.Text = if ($status.detail) { [string]$status.detail } else { "正在处理中..." }

        if ($status.url) {
            $script:CurrentUrl = [string]$status.url
        }
        if ($status.pageTarget) {
            $script:CurrentPageTarget = [string]$status.pageTarget
        }

        switch ([string]$status.state) {
            "success" {
                $progressBar.Style = "Continuous"
                $progressBar.Value = 100
                $actionButton.Visible = $true
                $copyButton.Visible = [string]::IsNullOrWhiteSpace($script:CurrentUrl) -eq $false
                $closeButton.Visible = $true

                if (-not $script:PageOpened) {
                    $form.TopMost = $false
                    if ($status.openHandled) {
                        $script:PageOpened = $true
                    } else {
                        $script:PageOpened = Open-PageTarget -Target $script:CurrentPageTarget -FallbackUrl $script:CurrentUrl
                    }

                    if ($script:PageOpened) {
                        Write-UiLog "Launcher confirmed the page was opened."
                        $badgeLabel.Text = "已打开"
                        $badgeLabel.BackColor = [System.Drawing.Color]::FromArgb(35, 138, 91)
                        $titleLabel.Text = "扫码页已经打开"
                        $detailLabel.Text = "现在可以直接拿手机扫一扫。"
                        $footerLabel.Text = "如果浏览器被挡住了，点打开扫码页就行。"
                        $footerLabel.ForeColor = [System.Drawing.Color]::FromArgb(106, 118, 130)
                        $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
                    } else {
                        Write-UiLog "Launcher did not auto-open the page."
                        $badgeLabel.Text = "已就绪"
                        $badgeLabel.BackColor = [System.Drawing.Color]::FromArgb(35, 138, 91)
                        $titleLabel.Text = "启动好了"
                        $detailLabel.Text = "扫码页没自动弹出，点右下角打开扫码页。"
                        $footerLabel.Text = "地址也可以一键复制。"
                        $footerLabel.ForeColor = [System.Drawing.Color]::FromArgb(122, 130, 139)
                    }
                } else {
                    $badgeLabel.Text = "已打开"
                    $badgeLabel.BackColor = [System.Drawing.Color]::FromArgb(35, 138, 91)
                }

                if ($script:PageOpened -and -not $NoAutoClose -and -not $script:AutoCloseQueued) {
                    $script:AutoCloseQueued = $true
                    $closeTimer.Start()
                }
            }
            "error" {
                $badgeLabel.Text = "启动失败"
                $badgeLabel.BackColor = [System.Drawing.Color]::FromArgb(206, 77, 62)
                $progressBar.Style = "Continuous"
                $progressBar.Value = 100
                $logButton.Visible = $true
                $closeButton.Visible = $true
                $footerLabel.Text = "点查看日志能看到具体原因。"
                $footerLabel.ForeColor = [System.Drawing.Color]::FromArgb(145, 87, 77)
            }
            default {
                $badgeLabel.Text = "启动中"
                $badgeLabel.BackColor = [System.Drawing.Color]::FromArgb(214, 140, 46)
                $footerLabel.Text = "准备好后会自动弹出扫码页。"
                $footerLabel.ForeColor = [System.Drawing.Color]::FromArgb(122, 130, 139)
            }
        }
    }

    if ($StartupProcess.HasExited -and -not $status) {
        Write-UiLog "Launcher exited without any startup status."
        $badgeLabel.Text = "启动失败"
        $badgeLabel.BackColor = [System.Drawing.Color]::FromArgb(206, 77, 62)
        $titleLabel.Text = "启动没有完成"
        $detailLabel.Text = "后台脚本提前退出了，请点查看日志。"
        $emojiLabel.Text = "⚠️"
        $progressBar.Style = "Continuous"
        $progressBar.Value = 100
        $logButton.Visible = $true
        $closeButton.Visible = $true
        $footerLabel.Text = "如果还不行，再试一次管理员启动。"
        $footerLabel.ForeColor = [System.Drawing.Color]::FromArgb(145, 87, 77)
    }
})

$pollTimer.Start()
$form.Add_FormClosed({
    $pollTimer.Stop()
    $closeTimer.Stop()
    Write-UiLog "Launcher window closed."
})

[void]$form.ShowDialog()
