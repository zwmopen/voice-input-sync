param(
    [switch]$Silent
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
$HttpExe = Join-Path $BaseDir "VoiceInputSyncHttp.exe"
$WsExe = Join-Path $BaseDir "VoiceInputSyncWs.exe"
$ClientExe = Join-Path $BaseDir "VoiceInputSyncClient.exe"
$QrExe = Join-Path $BaseDir "VoiceInputSyncQr.exe"
$StartBat = Join-Path $PackageDir "双击启动语音输入同步.bat"
$ShortcutIcon = Join-Path $BaseDir "assets\voice-sync-icon.ico"
$DesktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "语音输入同步.lnk"

New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path (Join-Path $LogsDir "startup.log") -Value "[$stamp] $Message"
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

function Get-PortListeners {
    param([int]$Port)

    return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
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

function Launch-PortableProcess {
    param(
        [string]$Name,
        [string]$ExePath
    )

    if (-not (Test-Path $ExePath)) {
        throw "Missing executable: $ExePath"
    }

    $existing = Get-ExecutableProcess -ExecutablePath $ExePath
    if ((@($existing)).Length -gt 0) {
        Write-Log "$Name already running."
        return $true
    }

    $stdout = Join-Path $LogsDir "$Name.out.log"
    $stderr = Join-Path $LogsDir "$Name.err.log"

    Start-Process -FilePath $ExePath `
        -WorkingDirectory $BaseDir `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr | Out-Null

    Write-Log "$Name launch requested."
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

function Assert-PortFree {
    param([int]$Port)

    $listeners = @(Get-PortListeners -Port $Port)
    if ($listeners.Length -eq 0) {
        return
    }

    $details = foreach ($listener in $listeners) {
        $procName = "Unknown"
        try {
            $procName = (Get-Process -Id $listener.OwningProcess -ErrorAction Stop).ProcessName
        } catch {
        }
        "{0} (PID {1})" -f $procName, $listener.OwningProcess
    }

    throw ("端口 {0} 已被占用：{1}" -f $Port, ($details -join ", "))
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
    if (-not (Test-Path $StartBat)) {
        Write-Log "Desktop shortcut skipped: start launcher missing."
        return $false
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($DesktopShortcut)
    $shortcut.TargetPath = $StartBat
    $shortcut.WorkingDirectory = $PackageDir
    $shortcut.Description = "语音输入同步"

    if (Test-Path $ShortcutIcon) {
        $shortcut.IconLocation = $ShortcutIcon
    }

    $shortcut.Save()
    Write-Log ("Desktop shortcut ready: {0}" -f $DesktopShortcut)
    return $true
}

function Show-Stage {
    param(
        [string]$Message,
        [string]$Color = "Cyan"
    )

    Write-Log ("UI: " + $Message)
    if (-not $Silent) {
        Write-Host $Message -ForegroundColor $Color
    }
}

try {
    Write-Log "=== portable-start.ps1 started ==="
    Show-Stage -Message "正在准备启动环境，请稍候 5 到 10 秒..." -Color "Yellow"

    try {
        Show-Stage -Message "正在创建桌面快捷方式..." -Color "DarkCyan"
        $shortcutOk = Ensure-DesktopShortcut
        Write-Log ("Desktop shortcut status: {0}" -f $shortcutOk)
    } catch {
        Write-Log ("Desktop shortcut failed: " + $_.Exception.Message)
    }

    Show-Stage -Message "正在检查上一次残留进程..." -Color "DarkCyan"
    $stoppedCount = Stop-ManagedProcesses
    Write-Log ("Self-check cleaned managed processes: {0}" -f $stoppedCount)

    Show-Stage -Message "正在检查端口和运行环境..." -Color "DarkCyan"
    Assert-PortFree -Port 8000
    Assert-PortFree -Port 8765

    Show-Stage -Message "正在启动同步服务..." -Color "DarkCyan"
    Launch-PortableProcess -Name "http" -ExePath $HttpExe | Out-Null
    Launch-PortableProcess -Name "ws" -ExePath $WsExe | Out-Null
    Launch-PortableProcess -Name "client" -ExePath $ClientExe | Out-Null

    $httpOk = Wait-PortReady -Port 8000 -TimeoutSeconds 20
    Write-Log "http port ready: $httpOk"

    $wsOk = Wait-PortReady -Port 8765 -TimeoutSeconds 20
    Write-Log "ws port ready: $wsOk"

    $clientOk = Wait-ProcessReady -ExePath $ClientExe -TimeoutSeconds 8
    Write-Log "client process ready: $clientOk"

    $lanIp = Get-LanIp
    $url = if ($lanIp) { "http://$lanIp`:8000/mobile.html" } else { "http://127.0.0.1:8000/mobile.html" }

    Set-Content -Path $LatestUrlFile -Value $url -Encoding UTF8

    Show-Stage -Message "正在准备手机扫码页..." -Color "DarkCyan"
    $qrOk = $false
    if (Test-Path $QrExe) {
        try {
            & $QrExe --url $url --svg $QrSvgFile --html $QrHtmlFile
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

    $shareText = @"
语音输入同步

优先用手机扫一扫电脑上的二维码。
如果扫码不方便，再在手机浏览器打开下面这个地址：
$url

使用提醒
1. 手机和电脑要在同一个 Wi-Fi 或同一个局域网
2. 先把电脑光标点到你要输入的位置
3. 如果手机已经连上，但电脑没有开始打字，请双击“如果输入没反应-请用管理员启动.bat”
"@
    Set-Content -Path $ShareUrlFile -Value $shareText -Encoding UTF8

    try {
        Set-Clipboard -Value $url
    } catch {
        Write-Log "Clipboard skipped."
    }

    Write-Log "Startup result: HTTP=$httpOk WS=$wsOk CLIENT=$clientOk QR=$qrOk URL=$url"

    if (-not $Silent) {
        if ($qrOk) {
            Start-Process $QrHtmlFile | Out-Null
        } else {
            Start-Process $url | Out-Null
        }
        Write-Host ""
        Write-Host "语音输入同步已启动。" -ForegroundColor Cyan
        Write-Host "优先让手机扫电脑上的二维码；地址也已经复制到剪贴板。" -ForegroundColor Yellow
        Write-Host $url -ForegroundColor Yellow
        Write-Host ""
        Write-Host "如果手机已连接但电脑不打字，请改用管理员启动入口。" -ForegroundColor DarkYellow
        Write-Host ""
    }
} catch {
    Write-Log ("ERROR: " + $_.Exception.Message)
    if (-not $Silent) {
        Write-Host ""
        Write-Host ("启动失败：" + $_.Exception.Message) -ForegroundColor Red
        Write-Host ""
    }
    exit 1
}
