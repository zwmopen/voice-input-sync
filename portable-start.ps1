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
$TrayScript = Join-Path $BaseDir "portable-tray.ps1"
$StartBat = Join-Path $PackageDir "双击启动语音输入同步.bat"
$LauncherScript = Join-Path $BaseDir "portable-launch-ui.ps1"
$ShortcutIcon = Join-Path $BaseDir "assets\voice-sync-icon.ico"
$DesktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "语音输入同步.lnk"
$StatusOutputFile = if ($StatusFile) { $StatusFile } else { Join-Path $LogsDir "startup-status.json" }
$OpenStateFile = Join-Path $LogsDir "page-open-state.json"
$StartupMutexName = "Local\VoiceInputSyncPortableStartup"
$StartupMutex = $null
$OwnsStartupMutex = $false

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

function Read-Status {
    if (-not (Test-Path $StatusOutputFile)) {
        return $null
    }

    try {
        return Get-Content -Raw -LiteralPath $StatusOutputFile -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-ExecutableProcess {
    param([string]$ExecutablePath)

    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath -eq $ExecutablePath
    })
}

function Enter-StartupMutex {
    $createdNew = $false
    $script:StartupMutex = New-Object System.Threading.Mutex($true, $StartupMutexName, [ref]$createdNew)
    $script:OwnsStartupMutex = [bool]$createdNew
    return $script:OwnsStartupMutex
}

function Exit-StartupMutex {
    if ($script:StartupMutex) {
        try {
            if ($script:OwnsStartupMutex) {
                $script:StartupMutex.ReleaseMutex()
            }
        } catch {
        } finally {
            $script:StartupMutex.Dispose()
            $script:StartupMutex = $null
            $script:OwnsStartupMutex = $false
        }
    }
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

function New-SessionToken {
    return ([guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N"))
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
    $targetPath = ""
    $arguments = ""
    if (Test-Path $LauncherScript) {
        $targetPath = (Get-Command powershell.exe).Source
        $arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $LauncherScript)
    } elseif (Test-Path $StartBat) {
        $targetPath = $StartBat
    } else {
        Write-Log "Desktop shortcut skipped: no launcher target found."
        return $false
    }

    $iconLocation = if (Test-Path $ShortcutIcon) { "$ShortcutIcon,0" } else { "" }

    if (Test-Path $DesktopShortcut) {
        try {
            $existingShortcut = $shell.CreateShortcut($DesktopShortcut)
            $sameTarget = ([string]$existingShortcut.TargetPath) -eq $targetPath
            $sameArgs = ([string]$existingShortcut.Arguments) -eq $arguments
            $sameWorkDir = ([string]$existingShortcut.WorkingDirectory) -eq $PackageDir
            $sameIcon = ([string]$existingShortcut.IconLocation) -eq $iconLocation
            if ($sameTarget -and $sameArgs -and $sameWorkDir -and $sameIcon) {
                Write-Log "Desktop shortcut already up to date."
                return $true
            }
        } catch {
            Write-Log ("Desktop shortcut comparison failed: " + $_.Exception.Message)
        }
    }

    $shortcut = $shell.CreateShortcut($DesktopShortcut)
    $shortcut.TargetPath = $targetPath
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = $PackageDir
    $shortcut.Description = "语音输入同步"

    if ($iconLocation) {
        $shortcut.IconLocation = $iconLocation
    }

    $shortcut.Save()
    Write-Log ("Desktop shortcut ready: {0}" -f $DesktopShortcut)
    return $true
}

function Start-TrayResident {
    if (-not (Test-Path $TrayScript)) {
        Write-Log "Tray resident skipped: script missing."
        return $false
    }

    try {
        Start-Process -FilePath (Get-Command powershell.exe).Source `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $TrayScript) `
            -WorkingDirectory $BaseDir `
            -WindowStyle Hidden | Out-Null
        Write-Log "Tray resident launch requested."
        return $true
    } catch {
        Write-Log ("Tray resident failed: " + $_.Exception.Message)
        return $false
    }
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

function Get-ExistingRunningSession {
    $config = Read-RuntimeConfig
    if (-not $config) {
        return $null
    }

    try {
        $httpPort = [int]$config.httpPort
        $wsPort = [int]$config.wsPort
    } catch {
        return $null
    }

    if ($httpPort -le 0 -or $wsPort -le 0) {
        return $null
    }

    if ((@(Get-ExecutableProcess -ExecutablePath $HttpExe)).Length -eq 0) {
        return $null
    }
    if ((@(Get-ExecutableProcess -ExecutablePath $WsExe)).Length -eq 0) {
        return $null
    }
    if ((@(Get-ExecutableProcess -ExecutablePath $ClientExe)).Length -eq 0) {
        return $null
    }
    if (-not (Test-TcpPortListening -Port $httpPort)) {
        return $null
    }
    if (-not (Test-TcpPortListening -Port $wsPort)) {
        return $null
    }

    $url = ""
    if (Test-Path $LatestUrlFile) {
        try {
            $url = (Get-Content -Raw -LiteralPath $LatestUrlFile -Encoding UTF8).Trim()
        } catch {
            $url = ""
        }
    }

    if ([string]::IsNullOrWhiteSpace($url)) {
        $lanIp = Get-LanIp
        $url = if ($lanIp) { "http://$lanIp`:$httpPort/mobile.html" } else { "http://127.0.0.1:$httpPort/mobile.html" }
    }

    if ($url -notmatch "token=") {
        Write-Log "Existing session ignored because URL has no session token."
        return $null
    }

    $pageTarget = if (Test-Path $QrHtmlFile) { $QrHtmlFile } else { $url }

    return [pscustomobject]@{
        HttpPort = $httpPort
        WsPort = $wsPort
        Url = $url
        PageTarget = $pageTarget
    }
}

function Read-PageOpenState {
    if (-not (Test-Path $OpenStateFile)) {
        return $null
    }

    try {
        return Get-Content -Raw -LiteralPath $OpenStateFile -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Write-PageOpenState {
    param(
        [string]$Target,
        [string]$Url
    )

    $payload = [ordered]@{
        target = $Target
        url = $Url
        openedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    $payload | ConvertTo-Json -Compress | Set-Content -Path $OpenStateFile -Encoding UTF8
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
            Start-Process -FilePath $Target | Out-Null
            Write-Log ("Open page fallback succeeded: {0}" -f $Target)
            return $true
        } catch {
            Write-Log ("Open page fallback failed: " + $_.Exception.Message)
            return $false
        }
    }
}

function Try-OpenPageWithCooldown {
    param(
        [string]$Target,
        [string]$Url,
        [int]$CooldownSeconds = 12
    )

    $openTarget = if ([string]::IsNullOrWhiteSpace($Target)) { $Url } else { $Target }
    if ([string]::IsNullOrWhiteSpace($openTarget)) {
        return $false
    }

    $state = Read-PageOpenState
    if ($state -and $state.openedAt) {
        try {
            $lastOpened = [datetime]::ParseExact([string]$state.openedAt, "yyyy-MM-dd HH:mm:ss", $null)
            $elapsed = ((Get-Date) - $lastOpened).TotalSeconds
            if ($elapsed -lt $CooldownSeconds) {
                Write-Log ("Skip page open due to cooldown: {0:N1}s" -f $elapsed)
                return $true
            }
        } catch {
            Write-Log "Page open cooldown state ignored."
        }
    }

    $opened = Open-PageTarget -Target $openTarget
    if ($opened) {
        Write-PageOpenState -Target $Target -Url $Url
    }
    return $opened
}

try {
    Write-Log "=== portable-start.ps1 started ==="
    Show-Stage -Title "正在准备启动环境" -Detail "通常只要几秒，请稍候。" -Emoji "🚀" -Color "Yellow" -Percent 8

    if (-not (Enter-StartupMutex)) {
        Write-Log "Startup mutex already held by another launcher."
        Show-Stage -Title "已经在启动中" -Detail "这次不再重复启动，也不会再重复开网页。" -Emoji "🫧" -Color "DarkCyan" -Percent 16

        $existingSession = Get-ExistingRunningSession
        if ($existingSession) {
            $shouldOpenPage = $ForceOpenPage -or $OpenPageOnSuccess -or -not $Silent
            $pageOpened = $false
            if ($shouldOpenPage) {
                $pageOpened = Try-OpenPageWithCooldown -Target $existingSession.PageTarget -Url $existingSession.Url
            }

            Start-TrayResident | Out-Null
            Write-Log ("Reused existing running session: HTTP={0} WS={1}" -f $existingSession.HttpPort, $existingSession.WsPort)
            Write-Status -State "success" -Title "已经在运行" -Detail "我直接复用了当前会话，没有重复启动。" -Emoji "✅" -Percent 100 -Url $existingSession.Url -PageTarget $existingSession.PageTarget -OpenHandled $pageOpened
            return
        }

        $existingStatus = Read-Status
        if ($existingStatus -and $existingStatus.state) {
            Write-Status -State ([string]$existingStatus.state) -Title ([string]$existingStatus.title) -Detail ([string]$existingStatus.detail) -Emoji ([string]$existingStatus.emoji) -Percent ([int]$existingStatus.percent) -Url ([string]$existingStatus.url) -PageTarget ([string]$existingStatus.pageTarget) -OpenHandled ([bool]$existingStatus.openHandled)
        } else {
            Write-Status -State "running" -Title "已经在启动中" -Detail "上一个启动流程还没结束，请稍候几秒。" -Emoji "⏳" -Percent 18
        }
        return
    }

    Write-Log "Startup mutex acquired."

    try {
        Show-Stage -Title "正在检查桌面快捷方式" -Detail "只在需要时才会更新桌面入口。" -Emoji "🪄" -Color "DarkCyan" -Percent 16
        $shortcutOk = Ensure-DesktopShortcut
        Write-Log ("Desktop shortcut status: {0}" -f $shortcutOk)
    } catch {
        Write-Log ("Desktop shortcut failed: " + $_.Exception.Message)
    }

    $existingSession = Get-ExistingRunningSession
    if ($existingSession) {
        Show-Stage -Title "检测到已在运行" -Detail "这次直接复用现有会话，不再重启。" -Emoji "♻️" -Color "DarkCyan" -Percent 24
        $shouldOpenPage = $ForceOpenPage -or $OpenPageOnSuccess -or -not $Silent
        $pageOpened = $false
        if ($shouldOpenPage) {
            $pageOpened = Try-OpenPageWithCooldown -Target $existingSession.PageTarget -Url $existingSession.Url
        }

        Start-TrayResident | Out-Null
        Write-Log ("Reused healthy running session: HTTP={0} WS={1}" -f $existingSession.HttpPort, $existingSession.WsPort)
        Write-Status -State "success" -Title "已经在运行" -Detail "我直接复用了当前会话。" -Emoji "✅" -Percent 100 -Url $existingSession.Url -PageTarget $existingSession.PageTarget -OpenHandled $pageOpened
        return
    }

    Show-Stage -Title "正在清理旧进程" -Detail "把上一次残留的后台先收干净。" -Emoji "🧹" -Color "DarkCyan" -Percent 28
    $stoppedCount = Stop-ManagedProcesses
    Write-Log ("Self-check cleaned managed processes: {0}" -f $stoppedCount)

    Show-Stage -Title "正在挑选可用端口" -Detail "被占用时会自动换一个，不会卡死。" -Emoji "🔎" -Color "DarkCyan" -Percent 40
    $httpPort = Get-AvailablePort -PreferredPort 8000
    $wsPort = Get-AvailablePort -PreferredPort 8765
    $sessionToken = New-SessionToken
    Write-RuntimeConfig -HttpPort $httpPort -WsPort $wsPort

    Show-Stage -Title "正在启动同步服务" -Detail ("网页端口 {0}，同步端口 {1}" -f $httpPort, $wsPort) -Emoji "⚙️" -Color "DarkCyan" -Percent 58
    Launch-PortableProcess -Name "http" -ExePath $HttpExe -Arguments @("--port", $httpPort) | Out-Null
    Launch-PortableProcess -Name "ws" -ExePath $WsExe -Arguments @("--port", $wsPort, "--session-token", $sessionToken) | Out-Null
    Launch-PortableProcess -Name "client" -ExePath $ClientExe -Arguments @("--ws-url", "ws://127.0.0.1:$wsPort", "--session-token", $sessionToken) | Out-Null

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
    $url = if ($lanIp) { "http://$lanIp`:$httpPort/mobile.html?token=$sessionToken" } else { "http://127.0.0.1:$httpPort/mobile.html?token=$sessionToken" }
    Set-Content -Path $LatestUrlFile -Value $url -Encoding UTF8

    Show-Stage -Title "正在准备扫码页" -Detail "马上就能在手机上扫二维码进入。" -Emoji "🌐" -Color "DarkCyan" -Percent 78
    $qrOk = $false
    if (Test-Path $QrExe) {
        try {
            & $QrExe --url $url --svg $QrSvgFile --html $QrHtmlFile --ws-port $wsPort --session-token $sessionToken
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

    Start-TrayResident | Out-Null

    $pageTarget = if ($qrOk) { $QrHtmlFile } else { $url }
    $shouldOpenPage = $ForceOpenPage -or $OpenPageOnSuccess -or -not $Silent
    $pageOpened = $false
    if ($shouldOpenPage) {
        $pageOpened = Try-OpenPageWithCooldown -Target $pageTarget -Url $url
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
} finally {
    Exit-StartupMutex
}
