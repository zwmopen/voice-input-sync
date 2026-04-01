param(
    [switch]$Silent,
    [switch]$ForceOpenPage,
    [switch]$OpenPageOnSuccess,
    [string]$StatusFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDir = Split-Path -Parent $BaseDir
$LogsDir = Join-Path $PackageDir "logs"
$LatestUrlFile = Join-Path $PackageDir "latest-url.txt"
$ShareUrlFile = Join-Path $PackageDir "手机打开这个地址.txt"
$QrHtmlFile = Join-Path $PackageDir "手机扫码打开.html"
$QrSvgFile = Join-Path $PackageDir "手机扫码连接.svg"
$RuntimeConfigFile = Join-Path $BaseDir "runtime-config.json"
$HttpExe = Join-Path $BaseDir "VoiceInputSyncHttp.exe"
$WsExe = Join-Path $BaseDir "VoiceInputSyncWs.exe"
$ClientExe = Join-Path $BaseDir "VoiceInputSyncClient.exe"
$QrExe = Join-Path $BaseDir "VoiceInputSyncQr.exe"
$StartBat = Join-Path $PackageDir "双击启动语音输入同步.bat"
$LauncherScript = Join-Path $BaseDir "portable-launch-ui.ps1"
$ShortcutIcon = Join-Path $BaseDir "assets\voice-sync-icon.ico"
$DesktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "语音输入同步.lnk"
$StatusOutputFile = if ($StatusFile) { $StatusFile } else { Join-Path $LogsDir "startup-status.json" }

New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null

function Write-Log {
    param([string]$Message)

    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path (Join-Path $LogsDir "startup.log") -Value "[$stamp] $Message" -Encoding UTF8
}

function Write-Status {
    param(
        [string]$State,
        [string]$Title,
        [string]$Detail = "",
        [string]$Emoji = "",
        [int]$Percent = 0,
        [string]$Url = "",
        [string]$PageTarget = "",
        [bool]$OpenHandled = $false
    )

    $statusDir = Split-Path -Parent $StatusOutputFile
    if ($statusDir) {
        New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
    }

    $payload = [ordered]@{
        state = $State
        title = $Title
        detail = $Detail
        emoji = $Emoji
        percent = $Percent
        url = $Url
        pageTarget = $PageTarget
        openHandled = $OpenHandled
        updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    $payload | ConvertTo-Json -Compress | Set-Content -Path $StatusOutputFile -Encoding UTF8
}

function Get-ExecutableProcess {
    param([string]$ExecutablePath)

    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath -eq $ExecutablePath
    })
}

function Test-TcpPortListening {
    param([int]$Port)

    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    return ($listeners.Length -gt 0)
}

function Wait-PortReady {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 12
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-TcpPortListening -Port $Port) {
            return $true
        }
        Start-Sleep -Milliseconds 300
    }

    return $false
}

function Get-AvailablePort {
    param(
        [int]$PreferredPort,
        [int]$SearchSpan = 20
    )

    for ($port = $PreferredPort; $port -lt ($PreferredPort + $SearchSpan); $port++) {
        if (-not (Test-TcpPortListening -Port $port)) {
            if ($port -ne $PreferredPort) {
                Write-Log ("端口 {0} 已占用，自动改用 {1}" -f $PreferredPort, $port)
            }
            return $port
        }
    }

    throw ("从 {0} 开始附近没有找到可用端口。" -f $PreferredPort)
}

function Launch-PortableProcess {
    param(
        [string]$Name,
        [string]$ExePath,
        [string[]]$Arguments = @()
    )

    if (-not (Test-Path $ExePath)) {
        throw "Missing executable: $ExePath"
    }

    $stdout = Join-Path $LogsDir "$Name.out.log"
    $stderr = Join-Path $LogsDir "$Name.err.log"

    Start-Process -FilePath $ExePath `
        -ArgumentList $Arguments `
        -WorkingDirectory $BaseDir `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr | Out-Null

    Write-Log ("{0} launch requested: {1}" -f $Name, ($Arguments -join " "))
    return $true
}

function Wait-ProcessReady {
    param(
        [string]$ExePath,
        [int]$TimeoutSeconds = 8
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ((@(Get-ExecutableProcess -ExecutablePath $ExePath)).Length -gt 0) {
            return $true
        }
        Start-Sleep -Milliseconds 300
    }

    return $false
}

function Stop-ManagedProcesses {
    $targets = @($HttpExe, $WsExe, $ClientExe)
    $stopped = 0

    foreach ($target in $targets) {
        $processes = @(Get-ExecutableProcess -ExecutablePath $target)
        foreach ($proc in $processes) {
            try {
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                $stopped++
                Write-Log ("Self-check stopped PID={0} Path={1}" -f $proc.ProcessId, $target)
            } catch {
                Write-Log ("Self-check failed to stop PID={0}: {1}" -f $proc.ProcessId, $_.Exception.Message)
            }
        }
    }

    Start-Sleep -Milliseconds 500
    return $stopped
}

function Get-LanIp {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.IPAddress -and
        $_.IPAddress -notlike "127.*" -and
        $_.IPAddress -notlike "169.254*" -and
        $_.PrefixOrigin -ne "WellKnown"
    }

    $candidates = foreach ($ip in $ips) {
        $iface = Get-NetIPInterface -InterfaceIndex $ip.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $alias = $ip.InterfaceAlias
        if ($alias -match "vEthernet|WSL|Hyper-V|VMware|VirtualBox|Loopback|Docker|Tailscale|ZeroTier|Bluetooth") {
            continue
        }

        [pscustomobject]@{
            IPAddress = $ip.IPAddress
            Metric = if ($iface) { $iface.InterfaceMetric } else { 9999 }
            Priority = if ($alias -match "Wi-?Fi|WLAN") { 1 } elseif ($alias -match "Ethernet") { 2 } else { 9 }
        }
    }

    ($candidates | Sort-Object Priority, Metric | Select-Object -First 1).IPAddress
}

function Ensure-DesktopShortcut {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($DesktopShortcut)
    if (Test-Path $LauncherScript) {
        $shortcut.TargetPath = (Get-Command powershell.exe).Source
        $shortcut.Arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $LauncherScript)
    } elseif (Test-Path $StartBat) {
        $shortcut.TargetPath = $StartBat
    } else {
        Write-Log "Desktop shortcut skipped: no launcher target found."
        return $false
    }

    $shortcut.WorkingDirectory = $PackageDir
    $shortcut.Description = "语音输入同步"

    if (Test-Path $ShortcutIcon) {
        $shortcut.IconLocation = $ShortcutIcon
    }

    $shortcut.Save()
    Write-Log ("Desktop shortcut ready: {0}" -f $DesktopShortcut)
    return $true
}

function Write-RuntimeConfig {
    param(
        [int]$HttpPort,
        [int]$WsPort
    )

    $config = [ordered]@{
        httpPort = $HttpPort
        wsPort = $WsPort
        updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    $config | ConvertTo-Json -Compress | Set-Content -Path $RuntimeConfigFile -Encoding UTF8
    Write-Log ("Runtime config written: HTTP={0} WS={1}" -f $HttpPort, $WsPort)
}

function Show-Stage {
    param(
        [string]$Title,
        [string]$Detail = "",
        [string]$Emoji = "",
        [string]$Color = "Cyan",
        [int]$Percent = 0
    )

    $summary = if ($Detail) { "{0} | {1}" -f $Title, $Detail } else { $Title }
    Write-Log ("UI: " + $summary)
    Write-Status -State "running" -Title $Title -Detail $Detail -Emoji $Emoji -Percent $Percent

    if (-not $Silent) {
        $prefix = if ($Emoji) { "{0} " -f $Emoji } else { "" }
        Write-Host ($prefix + $Title) -ForegroundColor $Color
        if ($Detail) {
            Write-Host $Detail -ForegroundColor DarkGray
        }
    }
}

function Open-PageTarget {
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
        Write-Log ("Opened page target: {0}" -f $resolvedTarget)
        return $true
    } catch {
        Write-Log ("Open page failed: " + $_.Exception.Message)
        try {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "start", "", $Target -WindowStyle Hidden | Out-Null
            Write-Log ("Open page fallback succeeded: {0}" -f $Target)
            return $true
        } catch {
            Write-Log ("Open page fallback failed: " + $_.Exception.Message)
            return $false
        }
    }
}

try {
    Write-Log "=== portable-start.ps1 started ==="
    Show-Stage -Title "正在准备启动环境" -Detail "通常只要几秒，请稍候。" -Emoji "🚀" -Color "Yellow" -Percent 8

    try {
        Show-Stage -Title "正在创建桌面快捷方式" -Detail "桌面入口会自动刷新到最新版。" -Emoji "🪄" -Color "DarkCyan" -Percent 16
        $shortcutOk = Ensure-DesktopShortcut
        Write-Log ("Desktop shortcut status: {0}" -f $shortcutOk)
    } catch {
        Write-Log ("Desktop shortcut failed: " + $_.Exception.Message)
    }

    Show-Stage -Title "正在清理旧进程" -Detail "把上一次残留的后台先收干净。" -Emoji "🧹" -Color "DarkCyan" -Percent 28
    $stoppedCount = Stop-ManagedProcesses
    Write-Log ("Self-check cleaned managed processes: {0}" -f $stoppedCount)

    Show-Stage -Title "正在挑选可用端口" -Detail "被占用时会自动换一个，不会卡死。" -Emoji "🔎" -Color "DarkCyan" -Percent 40
    $httpPort = Get-AvailablePort -PreferredPort 8000
    $wsPort = Get-AvailablePort -PreferredPort 8765
    Write-RuntimeConfig -HttpPort $httpPort -WsPort $wsPort

    Show-Stage -Title "正在启动同步服务" -Detail ("网页端口 {0}，同步端口 {1}" -f $httpPort, $wsPort) -Emoji "⚙️" -Color "DarkCyan" -Percent 58
    Launch-PortableProcess -Name "http" -ExePath $HttpExe -Arguments @("--port", $httpPort) | Out-Null
    Launch-PortableProcess -Name "ws" -ExePath $WsExe -Arguments @("--port", $wsPort) | Out-Null
    Launch-PortableProcess -Name "client" -ExePath $ClientExe -Arguments @("--ws-url", "ws://127.0.0.1:$wsPort") | Out-Null

    $httpOk = Wait-PortReady -Port $httpPort -TimeoutSeconds 20
    Write-Log "http port ready: $httpOk"
    if (-not $httpOk) {
        throw ("网页服务启动失败，端口 {0} 没有成功监听。" -f $httpPort)
    }

    $wsOk = Wait-PortReady -Port $wsPort -TimeoutSeconds 20
    Write-Log "ws port ready: $wsOk"
    if (-not $wsOk) {
        throw ("同步服务启动失败，端口 {0} 没有成功监听。" -f $wsPort)
    }

    $clientOk = Wait-ProcessReady -ExePath $ClientExe -TimeoutSeconds 8
    Write-Log "client process ready: $clientOk"
    if (-not $clientOk) {
        throw "电脑输入端没有成功启动。"
    }

    $lanIp = Get-LanIp
    $url = if ($lanIp) { "http://$lanIp`:$httpPort/mobile.html" } else { "http://127.0.0.1:$httpPort/mobile.html" }
    Set-Content -Path $LatestUrlFile -Value $url -Encoding UTF8

    Show-Stage -Title "正在准备扫码页" -Detail "马上就能在手机上扫二维码进入。" -Emoji "🌐" -Color "DarkCyan" -Percent 78
    $qrOk = $false
    if (Test-Path $QrExe) {
        try {
            & $QrExe --url $url --svg $QrSvgFile --html $QrHtmlFile --ws-port $wsPort
            if ($LASTEXITCODE -eq 0 -and (Test-Path $QrHtmlFile) -and (Test-Path $QrSvgFile)) {
                $qrOk = $true
            }
        } catch {
            Write-Log ("QR generation failed: " + $_.Exception.Message)
        }
    } else {
        Write-Log "QR executable missing."
    }
    Write-Log "QR ready: $qrOk"

    $shareText = @(
        "语音输入同步"
        ""
        "优先用手机扫一扫电脑上的二维码。"
        "如果扫码不方便，再在手机浏览器打开下面这个地址："
        $url
        ""
        "使用提醒"
        "1. 手机和电脑要在同一个 Wi-Fi 或同一个局域网"
        "2. 先把电脑光标点到你要输入的位置"
        "3. 如果手机已经连上，但电脑没有开始打字，请双击如果输入没反应-请用管理员启动.bat"
    ) -join "`r`n"
    Set-Content -Path $ShareUrlFile -Value $shareText -Encoding UTF8

    try {
        Set-Clipboard -Value $url
    } catch {
        Write-Log "Clipboard skipped."
    }

    $pageTarget = if ($qrOk) { $QrHtmlFile } else { $url }
    $shouldOpenPage = $ForceOpenPage -or $OpenPageOnSuccess -or -not $Silent
    $pageOpened = $false
    if ($shouldOpenPage) {
        $pageOpened = Open-PageTarget -Target $pageTarget
    }
    Write-Log "Startup result: HTTP=$httpOk WS=$wsOk CLIENT=$clientOk QR=$qrOk URL=$url"
    Write-Status -State "success" -Title "启动好了" -Detail "扫码页已经准备好，马上为你打开。" -Emoji "✅" -Percent 100 -Url $url -PageTarget $pageTarget -OpenHandled $pageOpened

    if (-not $Silent) {
        Write-Host ""
        Write-Host "语音输入同步已启动。" -ForegroundColor Cyan
        Write-Host "扫码页和手机地址都已经准备好。" -ForegroundColor Yellow
        Write-Host $url -ForegroundColor Yellow
        Write-Host ""
    }
} catch {
    $errorMessage = $_.Exception.Message
    Write-Log ("ERROR: " + $errorMessage)
    Write-Status -State "error" -Title "启动没有完成" -Detail $errorMessage -Emoji "⚠️" -Percent 100

    if (-not $Silent) {
        Write-Host ""
        Write-Host ("启动失败：" + $errorMessage) -ForegroundColor Red
        Write-Host ""
    }
    exit 1
}
