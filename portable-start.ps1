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
$QrLanPngFile = Join-Path $PackageDir "qr-lan.png"
$QrOnlinePngFile = Join-Path $PackageDir "qr-online.png"
$RuntimeConfigFile = Join-Path $BaseDir "runtime-config.json"
$BuildInfoFile = Join-Path $BaseDir "build-info.json"
$TrayScript = Join-Path $BaseDir "portable-tray.ps1"
$QrWindowScript = Join-Path $BaseDir "portable-qr-window.ps1"
$StartBat = Join-Path $PackageDir "双击启动语音输入同步.bat"
$LauncherVbs = Join-Path $PackageDir "启动语音输入同步.vbs"
$LauncherScript = Join-Path $BaseDir "portable-launch-ui.ps1"
$ShortcutIcon = Join-Path $BaseDir "assets\voice-sync-icon.ico"
$DesktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "语音输入同步.lnk"
$StatusOutputFile = if ($StatusFile) { $StatusFile } else { Join-Path $LogsDir "startup-status.json" }
$OpenStateFile = Join-Path $LogsDir "page-open-state.json"
$TunnelHttpOutLog = Join-Path $LogsDir "tunnel-http.out.log"
$TunnelHttpErrLog = Join-Path $LogsDir "tunnel-http.err.log"
$TunnelWsOutLog = Join-Path $LogsDir "tunnel-ws.out.log"
$TunnelWsErrLog = Join-Path $LogsDir "tunnel-ws.err.log"
$StartupMutexName = "Local\VoiceInputSyncPortableStartup"
$StartupMutex = $null
$OwnsStartupMutex = $false

New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null

function Resolve-ManagedExecutablePath {
    param([string]$BaseName)

    $folderPath = Join-Path (Join-Path $BaseDir $BaseName) ($BaseName + ".exe")
    if (Test-Path $folderPath) {
        return $folderPath
    }

    $flatPath = Join-Path $BaseDir ($BaseName + ".exe")
    if (Test-Path $flatPath) {
        return $flatPath
    }

    return $flatPath
}

$HttpExe = Resolve-ManagedExecutablePath -BaseName "VoiceInputSyncHttp"
$WsExe = Resolve-ManagedExecutablePath -BaseName "VoiceInputSyncWs"
$ClientExe = Resolve-ManagedExecutablePath -BaseName "VoiceInputSyncClient"
$QrExe = Resolve-ManagedExecutablePath -BaseName "VoiceInputSyncQr"
$HttpScript = Join-Path $BaseDir "portable_http_server.py"
$WsScript = Join-Path $BaseDir "server.py"

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
        [bool]$OpenHandled = $false,
        [bool]$ReuseSession = $false
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
        reuseSession = $ReuseSession
        updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    $payload | ConvertTo-Json -Compress | Set-Content -Path $StatusOutputFile -Encoding UTF8
}

function Get-ShortcutIconLocation {
    if (-not (Test-Path $ShortcutIcon)) {
        return ""
    }

    try {
        $iconHash = (Get-FileHash -LiteralPath $ShortcutIcon -Algorithm SHA256).Hash.Substring(0, 8).ToLowerInvariant()
        $iconDir = Split-Path -Parent $ShortcutIcon
        $shortcutIconPath = Join-Path $iconDir ("voice-sync-shortcut-{0}.ico" -f $iconHash)

        if (-not (Test-Path $shortcutIconPath)) {
            Copy-Item -LiteralPath $ShortcutIcon -Destination $shortcutIconPath -Force
        }

        Get-ChildItem -LiteralPath $iconDir -Filter "voice-sync-shortcut-*.ico" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $shortcutIconPath } |
            Remove-Item -Force -ErrorAction SilentlyContinue

        return ($shortcutIconPath + ",0")
    } catch {
        Write-Log ("Shortcut icon refresh failed: " + $_.Exception.Message)
        return ($ShortcutIcon + ",0")
    }
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

    if (-not (Test-Path $ExecutablePath)) {
        return @()
    }

    $processName = [System.IO.Path]::GetFileNameWithoutExtension($ExecutablePath)
    $normalizedPath = [System.IO.Path]::GetFullPath($ExecutablePath).ToLowerInvariant()
    $matches = @()

    foreach ($proc in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
        $procPath = $null
        try {
            $procPath = $proc.Path
        } catch {
            $procPath = $null
        }

        if ($procPath -and $procPath.ToLowerInvariant() -eq $normalizedPath) {
            $matches += $proc
        }
    }

    return $matches
}

function Get-ProcessIdValue {
    param($ProcessObject)

    if ($null -ne $ProcessObject -and $null -ne $ProcessObject.PSObject.Properties["Id"]) {
        return [int]$ProcessObject.Id
    }
    if ($null -ne $ProcessObject -and $null -ne $ProcessObject.PSObject.Properties["ProcessId"]) {
        return [int]$ProcessObject.ProcessId
    }

    return 0
}

function Get-ProcessCommandLineValue {
    param($ProcessObject)

    if ($null -ne $ProcessObject -and $null -ne $ProcessObject.PSObject.Properties["CommandLine"]) {
        return [string]$ProcessObject.CommandLine
    }

    return ""
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

function Test-TcpPortAvailable {
    param([int]$Port)

    $socket = $null
    try {
        $socket = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Tcp)
        $socket.ExclusiveAddressUse = $true
        $socket.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $Port))
        return $true
    } catch {
        return $false
    } finally {
        if ($socket) {
            $socket.Dispose()
        }
    }
}

function Test-TcpPortListening {
    param(
        [int]$Port,
        [string]$Address = "127.0.0.1",
        [int]$TimeoutMilliseconds = 280
    )

    $client = $null
    $asyncResult = $null

    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }

        $client.EndConnect($asyncResult)
        return $true
    } catch {
        return $false
    } finally {
        if ($asyncResult) {
            $asyncResult.AsyncWaitHandle.Close()
        }
        if ($client) {
            $client.Close()
        }
    }
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
        Start-Sleep -Milliseconds 180
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
        if (Test-TcpPortAvailable -Port $port) {
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

    Start-Process -FilePath $ExePath `
        -ArgumentList $Arguments `
        -WorkingDirectory $BaseDir `
        -WindowStyle Hidden | Out-Null

    Write-Log ("{0} launch requested: {1}" -f $Name, ($Arguments -join " "))
    return $true
}

function Resolve-PythonExecutable {
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return [string]$cmd.Source
    }

    return ""
}

function Launch-PythonScriptProcess {
    param(
        [string]$Name,
        [string]$PythonPath,
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    if ([string]::IsNullOrWhiteSpace($PythonPath) -or -not (Test-Path $PythonPath)) {
        throw "Missing python executable: $PythonPath"
    }
    if (-not (Test-Path $ScriptPath)) {
        throw "Missing script: $ScriptPath"
    }

    $fullArgs = @("-u", $ScriptPath) + $Arguments
    Start-Process -FilePath $PythonPath `
        -ArgumentList $fullArgs `
        -WorkingDirectory $BaseDir `
        -WindowStyle Hidden | Out-Null

    Write-Log ("{0} python launch requested: {1}" -f $Name, ($fullArgs -join " "))
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
        Start-Sleep -Milliseconds 180
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
                $procId = Get-ProcessIdValue -ProcessObject $proc
                Stop-Process -Id $procId -Force -ErrorAction Stop
                $stopped++
                Write-Log ("Self-check stopped PID={0} Path={1}" -f $procId, $target)
            } catch {
                Write-Log ("Self-check failed to stop PID={0}: {1}" -f (Get-ProcessIdValue -ProcessObject $proc), $_.Exception.Message)
            }
        }
    }

    Start-Sleep -Milliseconds 80
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

function Get-PrimaryNetworkProfile {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.IPAddress -and
        $_.IPAddress -notlike "127.*" -and
        $_.IPAddress -notlike "169.254*" -and
        $_.PrefixOrigin -ne "WellKnown"
    }

    $candidates = foreach ($ip in $ips) {
        $alias = [string]$ip.InterfaceAlias
        if ($alias -match "vEthernet|WSL|Hyper-V|VMware|VirtualBox|Loopback|Docker|Tailscale|ZeroTier|Bluetooth") {
            continue
        }

        $priority = if ($alias -match "Wi-?Fi|WLAN") { 1 } elseif ($alias -match "Ethernet") { 2 } else { 9 }
        [pscustomobject]@{
            InterfaceAlias = $alias
            InterfaceIndex = [int]$ip.InterfaceIndex
            IPAddress = [string]$ip.IPAddress
            Priority = $priority
        }
    }

    $primary = $candidates | Sort-Object Priority | Select-Object -First 1
    if (-not $primary) {
        return $null
    }

    $profile = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceIndex -eq $primary.InterfaceIndex
    } | Select-Object -First 1

    return [pscustomobject]@{
        InterfaceAlias = $primary.InterfaceAlias
        IPAddress = $primary.IPAddress
        NetworkCategory = if ($profile) { [string]$profile.NetworkCategory } else { "" }
        Name = if ($profile) { [string]$profile.Name } else { "" }
    }
}

function Resolve-TunnelLauncher {
    foreach ($candidate in @("lt.cmd", "lt", "lt.ps1", "npx.cmd", "npx")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) {
            return [pscustomobject]@{
                Name = [string]$cmd.Name
                Source = [string]$cmd.Source
            }
        }
    }

    return $null
}

function Get-TunnelProcesses {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and (
            $_.CommandLine -match '(?i)localtunnel.*--port\s+8000(\s|$)' -or
            $_.CommandLine -match '(?i)localtunnel.*--port\s+8765(\s|$)' -or
            $_.CommandLine -match '(?i)localtunnel.*--port\s+8001(\s|$)' -or
            $_.CommandLine -match '(?i)localtunnel.*--port\s+8766(\s|$)'
        )
    })
}

function Stop-TunnelProcesses {
    $stopped = 0
    foreach ($proc in @(Get-TunnelProcesses | Group-Object ProcessId | ForEach-Object { $_.Group[0] })) {
        $procId = Get-ProcessIdValue -ProcessObject $proc
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            $stopped++
            Write-Log ("Tunnel cleanup stopped PID={0} CMD={1}" -f $procId, (Get-ProcessCommandLineValue -ProcessObject $proc))
        } catch {
            Write-Log ("Tunnel cleanup failed PID={0}: {1}" -f $procId, $_.Exception.Message)
        }
    }

    if ($stopped -gt 0) {
        Start-Sleep -Milliseconds 120
    }

    return $stopped
}

function Wait-TunnelUrl {
    param(
        [string]$LogPath,
        [int]$TimeoutSeconds = 20
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path $LogPath) {
            try {
                foreach ($line in @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)) {
                    if ($line -match '(https://[a-zA-Z0-9.-]+\.loca\.lt)') {
                        return $matches[1]
                    }
                }
            } catch {
            }
        }

        Start-Sleep -Milliseconds 250
    }

    return ""
}

function Start-LocalTunnelProcess {
    param(
        [int]$Port,
        [string]$StdOutPath,
        [string]$StdErrPath
    )

    $launcher = Resolve-TunnelLauncher
    if (-not $launcher) {
        Write-Log "Tunnel skipped: no localtunnel launcher found."
        return ""
    }

    Remove-Item -LiteralPath $StdOutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StdErrPath -Force -ErrorAction SilentlyContinue

    if ($launcher.Name -like "npx*") {
        Start-Process -FilePath $launcher.Source `
            -ArgumentList @("--yes", "localtunnel", "--port", $Port) `
            -WorkingDirectory $BaseDir `
            -WindowStyle Hidden `
            -RedirectStandardOutput $StdOutPath `
            -RedirectStandardError $StdErrPath | Out-Null
    } elseif ($launcher.Source -like "*.ps1") {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $launcher.Source, "--port", $Port) `
            -WorkingDirectory $BaseDir `
            -WindowStyle Hidden `
            -RedirectStandardOutput $StdOutPath `
            -RedirectStandardError $StdErrPath | Out-Null
    } else {
        Start-Process -FilePath $launcher.Source `
            -ArgumentList @("--port", $Port) `
            -WorkingDirectory $BaseDir `
            -WindowStyle Hidden `
            -RedirectStandardOutput $StdOutPath `
            -RedirectStandardError $StdErrPath | Out-Null
    }

    $url = Wait-TunnelUrl -LogPath $StdOutPath -TimeoutSeconds 20
    if ([string]::IsNullOrWhiteSpace($url)) {
        $errPreview = ""
        if (Test-Path $StdErrPath) {
            try {
                $errPreview = ((Get-Content -LiteralPath $StdErrPath -Tail 5 -ErrorAction SilentlyContinue) -join " | ")
            } catch {
                $errPreview = ""
            }
        }
        Write-Log ("Tunnel start failed on port {0}: {1}" -f $Port, $errPreview)
    } else {
        Write-Log ("Tunnel ready on port {0}: {1}" -f $Port, $url)
    }

    return $url
}

function Get-ShareEndpoints {
    param(
        [string]$DirectUrl,
        [string]$DirectIpUrl,
        [int]$HttpPort,
        [int]$WsPort,
        [string]$SessionToken
    )

    $statusWsUrl = "ws://127.0.0.1:$WsPort"
    $preferredLanUrl = if (-not [string]::IsNullOrWhiteSpace($DirectUrl)) { $DirectUrl } else { $DirectIpUrl }
    $networkProfile = Get-PrimaryNetworkProfile
    $preferTunnel = $false
    if ($networkProfile -and $networkProfile.NetworkCategory -eq "Public") {
        $preferTunnel = $true
    }

    if (-not $preferTunnel) {
        return [pscustomobject]@{
            PrimaryUrl = $preferredLanUrl
            DirectUrl = $DirectUrl
            DirectIpUrl = $DirectIpUrl
            PublicHttpUrl = ""
            PublicWsUrl = ""
            StatusWsUrl = $statusWsUrl
            PreferTunnel = $false
            NetworkProfile = $networkProfile
        }
    }

    $stoppedTunnels = Stop-TunnelProcesses
    if ($stoppedTunnels -gt 0) {
        Write-Log ("Cleaned previous tunnel processes: {0}" -f $stoppedTunnels)
    }

    $publicHttpUrl = Start-LocalTunnelProcess -Port $HttpPort -StdOutPath $TunnelHttpOutLog -StdErrPath $TunnelHttpErrLog
    if ([string]::IsNullOrWhiteSpace($publicHttpUrl)) {
        Write-Log "Tunnel mode unavailable, fallback to direct LAN address."
        return [pscustomobject]@{
            PrimaryUrl = $preferredLanUrl
            DirectUrl = $DirectUrl
            DirectIpUrl = $DirectIpUrl
            PublicHttpUrl = ""
            PublicWsUrl = ""
            StatusWsUrl = $statusWsUrl
            PreferTunnel = $true
            NetworkProfile = $networkProfile
        }
    }

    return [pscustomobject]@{
        PrimaryUrl = if (-not [string]::IsNullOrWhiteSpace($preferredLanUrl)) { $preferredLanUrl } else { $publicHttpUrl.TrimEnd('/') + "/mobile.html" }
        DirectUrl = $DirectUrl
        DirectIpUrl = $DirectIpUrl
        PublicHttpUrl = $publicHttpUrl.TrimEnd('/') + "/mobile.html"
        PublicWsUrl = ""
        StatusWsUrl = $statusWsUrl
        PreferTunnel = $true
        NetworkProfile = $networkProfile
    }
}

function Ensure-DesktopShortcut {
    $shell = New-Object -ComObject WScript.Shell
    $targetPath = ""
    $arguments = ""
    if (Test-Path $LauncherVbs) {
        $targetPath = (Get-Command wscript.exe).Source
        $arguments = ('//nologo "{0}"' -f $LauncherVbs)
    } elseif (Test-Path $LauncherScript) {
        $targetPath = (Get-Command powershell.exe).Source
        $arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $LauncherScript)
    } elseif (Test-Path $StartBat) {
        $targetPath = $StartBat
    } else {
        Write-Log "Desktop shortcut skipped: no launcher target found."
        return $false
    }

    $iconLocation = Get-ShortcutIconLocation

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

function Remove-LegacyStartupEntries {
    $startupDir = [Environment]::GetFolderPath("Startup")
    $legacyTargets = @(
        (Join-Path $startupDir "voice-input-sync-startup.bat"),
        (Join-Path $startupDir "voice-input-sync-startup.vbs")
    )

    foreach ($target in $legacyTargets) {
        if (-not (Test-Path $target)) {
            continue
        }

        try {
            Remove-Item -LiteralPath $target -Force
            Write-Log ("Removed legacy startup entry: {0}" -f $target)
        } catch {
            Write-Log ("Failed to remove legacy startup entry {0}: {1}" -f $target, $_.Exception.Message)
        }
    }
}

function Get-LegacyCompanionProcesses {
    $startupDir = [Environment]::GetFolderPath("Startup")
    $batPath = [regex]::Escape((Join-Path $startupDir "voice-input-sync-startup.bat"))
    $vbsPath = [regex]::Escape((Join-Path $startupDir "voice-input-sync-startup.vbs"))
    $patterns = @(
        '(?i)voice-input-sync.*\\client\.py(\s|$)',
        '(?i)voice-input-sync.*\\server\.py(\s|$)',
        '(?i)voice-input-sync.*\\portable_http_server\.py(\s|$)',
        '(?i)voice-input-sync.*\\autostart\.ps1(\s|$)',
        $batPath,
        $vbsPath
    )

    $legacyProcesses = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $commandLine = Get-ProcessCommandLineValue -ProcessObject $proc
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            continue
        }

        foreach ($pattern in $patterns) {
            if ($commandLine -match $pattern) {
                [void]$legacyProcesses.Add($proc)
                break
            }
        }
    }

    return @($legacyProcesses.ToArray() | Group-Object ProcessId | ForEach-Object { $_.Group[0] })
}

function Get-LegacyHttpProcesses {
    param([bool]$IncludeCompanionHttp = $false)

    if (-not $IncludeCompanionHttp) {
        return @()
    }

    $legacyHttpProcesses = New-Object System.Collections.Generic.List[object]
    foreach ($proc in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $commandLine = Get-ProcessCommandLineValue -ProcessObject $proc
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            continue
        }

        if ($commandLine -match '(?i)-m\s+http\.server\s+8000(\s|$)') {
            [void]$legacyHttpProcesses.Add($proc)
        }
    }

    return @($legacyHttpProcesses.ToArray() | Group-Object ProcessId | ForEach-Object { $_.Group[0] })
}

function Stop-LegacyProcesses {
    $companions = @(Get-LegacyCompanionProcesses)
    $targets = New-Object System.Collections.Generic.List[object]

    foreach ($proc in $companions) {
        [void]$targets.Add($proc)
    }

    if ($companions.Count -gt 0) {
        foreach ($proc in @(Get-LegacyHttpProcesses -IncludeCompanionHttp $true)) {
            [void]$targets.Add($proc)
        }
    }

    $targets = @($targets.ToArray() | Group-Object ProcessId | ForEach-Object { $_.Group[0] })
    $stopped = 0

    foreach ($proc in $targets) {
        $procId = Get-ProcessIdValue -ProcessObject $proc
        $commandLine = Get-ProcessCommandLineValue -ProcessObject $proc
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            $stopped++
            Write-Log ("Legacy cleanup stopped PID={0} CMD={1}" -f $procId, $commandLine)
        } catch {
            Write-Log ("Legacy cleanup failed PID={0}: {1}" -f $procId, $_.Exception.Message)
        }
    }

    if ($stopped -gt 0) {
        Start-Sleep -Milliseconds 200
    }

    return [pscustomobject]@{
        Found = $targets.Count
        Stopped = $stopped
    }
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

function Write-RuntimeConfig {
    param(
        [int]$HttpPort,
        [int]$WsPort,
        [string]$SessionToken = "",
        [string]$DirectUrl = "",
        [string]$DirectIpUrl = "",
        [string]$PublicHttpUrl = "",
        [string]$PublicWsUrl = ""
    )

    $buildInfo = Read-BuildInfo
    $buildId = ""
    if ($buildInfo -and $buildInfo.buildId) {
        $buildId = [string]$buildInfo.buildId
    }

    $config = [ordered]@{
        httpPort = $HttpPort
        wsPort = $WsPort
        sessionToken = $SessionToken
        directUrl = $DirectUrl
        directIpUrl = $DirectIpUrl
        publicHttpUrl = $PublicHttpUrl
        publicWsUrl = $PublicWsUrl
        buildId = $buildId
        updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    $config | ConvertTo-Json -Compress | Set-Content -Path $RuntimeConfigFile -Encoding UTF8
    Write-Log ("Runtime config written: HTTP={0} WS={1} BUILD={2} PUBLIC={3}" -f $HttpPort, $WsPort, $buildId, ([string](-not [string]::IsNullOrWhiteSpace($PublicHttpUrl))))
}

function Test-HttpAssetHealthy {
    param(
        [int]$Port,
        [string]$RelativePath
    )

    $uri = "http://127.0.0.1:{0}/{1}?ts={2}" -f $Port, $RelativePath.TrimStart('/'), ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    try {
        $request = [System.Net.HttpWebRequest]::Create($uri)
        $request.Method = "GET"
        $request.Timeout = 2500
        $request.ReadWriteTimeout = 2500
        $request.AllowAutoRedirect = $false
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        try {
            return ($response.StatusCode -eq [System.Net.HttpStatusCode]::OK)
        } finally {
            $response.Close()
        }
    } catch {
        Write-Log ("HTTP asset health check failed: {0}" -f $uri)
        return $false
    }
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
    $buildInfo = Read-BuildInfo
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

    $currentBuildId = ""
    if ($buildInfo -and $null -ne $buildInfo.PSObject.Properties["buildId"] -and $buildInfo.buildId) {
        $currentBuildId = [string]$buildInfo.buildId
    }

    $sessionBuildId = ""
    if ($null -ne $config.PSObject.Properties["buildId"] -and $config.buildId) {
        $sessionBuildId = [string]$config.buildId
    }

    if ($currentBuildId -and $sessionBuildId -and $currentBuildId -ne $sessionBuildId) {
        Write-Log ("Existing session ignored because build changed: current={0} session={1}" -f $currentBuildId, $sessionBuildId)
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
    if (-not (Test-HttpAssetHealthy -Port $httpPort -RelativePath "mobile.html")) {
        Write-Log ("Existing session ignored because mobile.html is not healthy on port {0}" -f $httpPort)
        return $null
    }
    if (-not (Test-HttpAssetHealthy -Port $httpPort -RelativePath "runtime-config.json")) {
        Write-Log ("Existing session ignored because runtime-config.json is not healthy on port {0}" -f $httpPort)
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
        if ($lanIp) {
            $url = "http://$lanIp`:$httpPort/mobile.html"
        } else {
            $url = "http://127.0.0.1:$httpPort/mobile.html"
        }
    }

    $pageTarget = if (Test-Path $QrHtmlFile) { $QrHtmlFile } else { $url }
    $sessionToken = ""
    if ($null -ne $config.PSObject.Properties["sessionToken"] -and $config.sessionToken) {
        $sessionToken = [string]$config.sessionToken
    }
    $directUrl = ""
    if ($null -ne $config.PSObject.Properties["directUrl"] -and $config.directUrl) {
        $directUrl = [string]$config.directUrl
    }
    $directIpUrl = ""
    if ($null -ne $config.PSObject.Properties["directIpUrl"] -and $config.directIpUrl) {
        $directIpUrl = [string]$config.directIpUrl
    }
    $publicHttpUrl = ""
    if ($null -ne $config.PSObject.Properties["publicHttpUrl"] -and $config.publicHttpUrl) {
        $publicHttpUrl = [string]$config.publicHttpUrl
    }
    $publicWsUrl = ""
    if ($null -ne $config.PSObject.Properties["publicWsUrl"] -and $config.publicWsUrl) {
        $publicWsUrl = [string]$config.publicWsUrl
    }

    return [pscustomobject]@{
        HttpPort = $httpPort
        WsPort = $wsPort
        Url = $url
        PageTarget = $pageTarget
        SessionToken = $sessionToken
        DirectUrl = $directUrl
        DirectIpUrl = $directIpUrl
        PublicHttpUrl = $publicHttpUrl
        PublicWsUrl = $publicWsUrl
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
            Write-Log ("Opened QR window: {0}" -f $QrWindowScript)
            return $true
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

function Update-ShareArtifacts {
    param(
        [string]$RecommendedUrl,
        [int]$WsPort,
        [string]$SessionToken = "",
        [string]$StatusWsUrl = "",
        [string]$OnlineUrl = "",
        [string]$LanUrl = ""
    )

    if ([string]::IsNullOrWhiteSpace($RecommendedUrl)) {
        return $false
    }

    Set-Content -Path $LatestUrlFile -Value $RecommendedUrl -Encoding UTF8

    $qrOk = $false
    if (Test-Path $QrExe) {
        try {
            $qrArgs = @(
                "--url", $RecommendedUrl,
                "--svg", $QrSvgFile,
                "--html", $QrHtmlFile,
                "--ws-port", $WsPort,
                "--session-token", $SessionToken
            )
            if (-not [string]::IsNullOrWhiteSpace($StatusWsUrl)) {
                $qrArgs += @("--status-ws-url", $StatusWsUrl)
            }
            $qrArgs += @(
                "--online-url", $OnlineUrl,
                "--lan-url", $LanUrl,
                "--online-png", $QrOnlinePngFile,
                "--lan-png", $QrLanPngFile
            )
            & $QrExe @qrArgs
            if ($LASTEXITCODE -eq 0 -and (Test-Path $QrHtmlFile) -and (Test-Path $QrSvgFile)) {
                $qrOk = $true
            }
        } catch {
            Write-Log ("QR refresh failed: " + $_.Exception.Message)
        }
    }

    $shareText = @(
        "语音输入同步"
        ""
        "优先用手机扫一扫电脑上的二维码。"
        "当前推荐地址："
        $RecommendedUrl
        ""
        "局域网直连地址："
        $(if ([string]::IsNullOrWhiteSpace($LanUrl)) { "（当前没有单独的局域网地址）" } else { $LanUrl })
        ""
        "互联网地址："
        $(if ([string]::IsNullOrWhiteSpace($OnlineUrl)) { "（当前这次启动还没拿到互联网地址）" } else { $OnlineUrl })
        ""
        "使用提醒"
        "1. 先试上面的局域网直连地址"
        "2. 如果局域网打不开，再试下面的互联网地址"
        "3. 先把电脑光标点到你要输入的位置"
        "4. 如果手机已经连上，但电脑没有开始打字，请双击如果输入没反应-请用管理员启动.bat"
    ) -join "`r`n"
    Set-Content -Path $ShareUrlFile -Value $shareText -Encoding UTF8

    try {
        Set-Clipboard -Value $RecommendedUrl
    } catch {
        Write-Log "Clipboard skipped."
    }

    return $qrOk
}

try {
    Write-Log "=== portable-start.ps1 started ==="
    Show-Stage -Title "正在准备启动环境" -Detail "通常只要几秒，请稍候。" -Emoji "🚀" -Color "Yellow" -Percent 8
    $forceFreshSession = $false

    if (-not (Enter-StartupMutex)) {
        Write-Log "Startup mutex already held by another launcher."
        Show-Stage -Title "已经在启动中" -Detail "这次不再重复启动，也不会再重复开网页。" -Emoji "🫧" -Color "DarkCyan" -Percent 16

        $existingSession = Get-ExistingRunningSession
        if ($existingSession) {
            [void](Update-ShareArtifacts -RecommendedUrl $existingSession.Url -WsPort $existingSession.WsPort -SessionToken $existingSession.SessionToken -StatusWsUrl ("ws://127.0.0.1:{0}" -f $existingSession.WsPort) -OnlineUrl $existingSession.PublicHttpUrl -LanUrl $existingSession.DirectUrl)
            $shouldOpenPage = $ForceOpenPage -or $OpenPageOnSuccess -or -not $Silent
            $pageOpened = $false
            if ($shouldOpenPage) {
                $pageOpened = Try-OpenPageWithCooldown -Target $existingSession.PageTarget -Url $existingSession.Url
            }

            Start-TrayResident | Out-Null
            Write-Log ("Reused existing running session: HTTP={0} WS={1}" -f $existingSession.HttpPort, $existingSession.WsPort)
            Write-Status -State "success" -Title "已经在运行" -Detail "我直接复用了当前会话，没有重复启动。" -Emoji "✅" -Percent 100 -Url $existingSession.Url -PageTarget $existingSession.PageTarget -OpenHandled $pageOpened -ReuseSession $true
            return
        }

        $existingStatus = Read-Status
        if ($existingStatus -and $existingStatus.state) {
            $reuseSession = $false
            if ($null -ne $existingStatus.PSObject.Properties["reuseSession"]) {
                $reuseSession = [bool]$existingStatus.reuseSession
            }
            Write-Status -State ([string]$existingStatus.state) -Title ([string]$existingStatus.title) -Detail ([string]$existingStatus.detail) -Emoji ([string]$existingStatus.emoji) -Percent ([int]$existingStatus.percent) -Url ([string]$existingStatus.url) -PageTarget ([string]$existingStatus.pageTarget) -OpenHandled ([bool]$existingStatus.openHandled) -ReuseSession $reuseSession
        } else {
            Write-Status -State "running" -Title "已经在启动中" -Detail "上一个启动流程还没结束，请稍候几秒。" -Emoji "⏳" -Percent 18
        }
        return
    }

    Write-Log "Startup mutex acquired."

    try {
        Remove-LegacyStartupEntries

        $legacyCleanup = Stop-LegacyProcesses
        if ($legacyCleanup.Found -gt 0) {
            $forceFreshSession = $legacyCleanup.Stopped -gt 0
            $legacyDetail = if ($legacyCleanup.Stopped -gt 0) {
                "发现旧版后台残留，已经替你收干净。"
            } else {
                "发现旧版后台残留，但这次没能完全结束。"
            }
            Show-Stage -Title "正在清理旧版本残留" -Detail $legacyDetail -Emoji "🧼" -Color "DarkCyan" -Percent 14
            Write-Log ("Legacy cleanup summary: found={0} stopped={1}" -f $legacyCleanup.Found, $legacyCleanup.Stopped)
        }

        Show-Stage -Title "正在检查桌面快捷方式" -Detail "只在需要时才会更新桌面入口。" -Emoji "🪄" -Color "DarkCyan" -Percent 16
        $shortcutOk = Ensure-DesktopShortcut
        Write-Log ("Desktop shortcut status: {0}" -f $shortcutOk)
    } catch {
        Write-Log ("Desktop shortcut failed: " + $_.Exception.Message)
    }

    $networkProfile = Get-PrimaryNetworkProfile
    if ($networkProfile -and $networkProfile.NetworkCategory -eq "Public") {
        $forceFreshSession = $true
        Write-Log ("Startup will refresh public-network share targets: {0} {1} {2}" -f $networkProfile.Name, $networkProfile.InterfaceAlias, $networkProfile.IPAddress)
    }
    $pythonExe = Resolve-PythonExecutable
    $usePythonLanRuntime = $false
    if (
        $networkProfile -and
        $networkProfile.NetworkCategory -eq "Public" -and
        -not [string]::IsNullOrWhiteSpace($pythonExe) -and
        (Test-Path $HttpScript) -and
        (Test-Path $WsScript)
    ) {
        $usePythonLanRuntime = $true
        Write-Log ("Public network detected, prefer Python LAN stack: {0}" -f $pythonExe)
    }

    $existingSession = if ($forceFreshSession) { $null } else { Get-ExistingRunningSession }
    if ($existingSession) {
        Show-Stage -Title "检测到已在运行" -Detail "这次直接复用现有会话，不再重启。" -Emoji "♻️" -Color "DarkCyan" -Percent 24
        [void](Update-ShareArtifacts -RecommendedUrl $existingSession.Url -WsPort $existingSession.WsPort -SessionToken $existingSession.SessionToken -StatusWsUrl ("ws://127.0.0.1:{0}" -f $existingSession.WsPort) -OnlineUrl $existingSession.PublicHttpUrl -LanUrl $existingSession.DirectUrl)
        $shouldOpenPage = $ForceOpenPage -or $OpenPageOnSuccess -or -not $Silent
        $pageOpened = $false
        if ($shouldOpenPage) {
            $pageOpened = Try-OpenPageWithCooldown -Target $existingSession.PageTarget -Url $existingSession.Url
        }

        Start-TrayResident | Out-Null
        Write-Log ("Reused healthy running session: HTTP={0} WS={1}" -f $existingSession.HttpPort, $existingSession.WsPort)
        Write-Status -State "success" -Title "已经在运行" -Detail "我直接复用了当前会话。" -Emoji "✅" -Percent 100 -Url $existingSession.Url -PageTarget $existingSession.PageTarget -OpenHandled $pageOpened -ReuseSession $true
        return
    }

    Show-Stage -Title "正在清理旧进程" -Detail "把上一次残留的后台先收干净。" -Emoji "🧹" -Color "DarkCyan" -Percent 28
    $stoppedCount = Stop-ManagedProcesses
    Write-Log ("Self-check cleaned managed processes: {0}" -f $stoppedCount)

    Show-Stage -Title "正在挑选可用端口" -Detail "被占用时会自动换一个，不会卡死。" -Emoji "🔎" -Color "DarkCyan" -Percent 40
    $httpPort = Get-AvailablePort -PreferredPort 8000
    $wsPort = Get-AvailablePort -PreferredPort 8765
    $sessionToken = New-SessionToken
    Write-RuntimeConfig -HttpPort $httpPort -WsPort $wsPort -SessionToken $sessionToken

    Show-Stage -Title "正在启动同步服务" -Detail ("网页端口 {0}，同步端口 {1}" -f $httpPort, $wsPort) -Emoji "⚙️" -Color "DarkCyan" -Percent 58
    if ($usePythonLanRuntime) {
        Launch-PythonScriptProcess -Name "http" -PythonPath $pythonExe -ScriptPath $HttpScript -Arguments @("--port", $httpPort) | Out-Null
        Launch-PythonScriptProcess -Name "ws" -PythonPath $pythonExe -ScriptPath $WsScript -Arguments @("--port", $wsPort, "--session-token", $sessionToken) | Out-Null
    } else {
        Launch-PortableProcess -Name "http" -ExePath $HttpExe -Arguments @("--port", $httpPort) | Out-Null
        Launch-PortableProcess -Name "ws" -ExePath $WsExe -Arguments @("--port", $wsPort, "--session-token", $sessionToken) | Out-Null
    }
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
    $directUrl = if ($lanIp) { "http://$lanIp`:$httpPort/mobile.html" } else { "http://127.0.0.1:$httpPort/mobile.html" }
    $directIpUrl = ""

    Show-Stage -Title "正在准备手机地址" -Detail "热点网络下会自动补一个更稳的兼容地址。" -Emoji "🛰️" -Color "DarkCyan" -Percent 72
    $shareEndpoints = Get-ShareEndpoints -DirectUrl $directUrl -DirectIpUrl $directIpUrl -HttpPort $httpPort -WsPort $wsPort -SessionToken $sessionToken
    $url = $shareEndpoints.PrimaryUrl
    Write-RuntimeConfig -HttpPort $httpPort -WsPort $wsPort -SessionToken $sessionToken -DirectUrl $shareEndpoints.DirectUrl -DirectIpUrl $shareEndpoints.DirectIpUrl -PublicHttpUrl $shareEndpoints.PublicHttpUrl -PublicWsUrl $shareEndpoints.PublicWsUrl

    Show-Stage -Title "正在准备扫码页" -Detail "马上就能在手机上扫二维码进入。" -Emoji "🌐" -Color "DarkCyan" -Percent 78
    $qrOk = Update-ShareArtifacts -RecommendedUrl $url -WsPort $wsPort -SessionToken $sessionToken -StatusWsUrl $shareEndpoints.StatusWsUrl -OnlineUrl $shareEndpoints.PublicHttpUrl -LanUrl $shareEndpoints.DirectUrl
    Write-Log "QR ready: $qrOk"

    Start-TrayResident | Out-Null

    $pageTarget = if ($qrOk) { $QrHtmlFile } else { $url }
    $shouldOpenPage = $ForceOpenPage -or $OpenPageOnSuccess -or -not $Silent
    $pageOpened = $false
    if ($shouldOpenPage) {
        $pageOpened = Try-OpenPageWithCooldown -Target $pageTarget -Url $url
    }
    Write-Log "Startup result: HTTP=$httpOk WS=$wsOk CLIENT=$clientOk QR=$qrOk URL=$url"
    Write-Status -State "success" -Title "启动好了" -Detail "扫码页已经准备好，马上为你打开。" -Emoji "✅" -Percent 100 -Url $url -PageTarget $pageTarget -OpenHandled $pageOpened -ReuseSession $false

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
