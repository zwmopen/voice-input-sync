param(
    [switch]$Silent,
    [switch]$ForceOpenBrowser,
    [switch]$SkipSetup
)

$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogsDir = Join-Path $BaseDir "logs"
$MarkerFile = Join-Path $BaseDir ".browser-opened-at"
$SetupMarker = Join-Path $BaseDir ".setup-complete"
$LatestUrlFile = Join-Path $BaseDir "latest-url.txt"
$StartupBatName = "voice-input-sync-startup.bat"
$MutexName = "Global\VoiceInputSyncStarter"
$Script:PythonLauncher = $null
$Script:PythonArgsPrefix = @()

if (-not (Test-Path $BaseDir)) {
    throw "voice-input-sync folder not found: $BaseDir"
}

if (-not (Test-Path $LogsDir)) {
    New-Item -Path $LogsDir -ItemType Directory -Force | Out-Null
}

$StartupLog = Join-Path $LogsDir "startup.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $StartupLog -Value "[$timestamp] $Message"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-MatchedProcess {
    param([string]$Pattern)
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine -like $Pattern
    })
}

function Resolve-PythonLauncher {
    $pyCmd = Get-Command py -ErrorAction SilentlyContinue
    if ($pyCmd) {
        $Script:PythonLauncher = $pyCmd.Source
        $Script:PythonArgsPrefix = @("-3")
        return
    }

    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        $Script:PythonLauncher = $pythonCmd.Source
        $Script:PythonArgsPrefix = @()
        return
    }

    throw "Python launcher not found. Please install py or python."
}

function Test-TcpPortListening {
    param([int]$Port)
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    return $listeners.Count -gt 0
}

function Wait-PortReady {
    param(
        [int]$Port,
        [int]$TimeoutSeconds = 10
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

function Start-PythonProcess {
    param(
        [string]$Name,
        [string[]]$ScriptArgs,
        [string]$Pattern,
        [int]$Port = 0
    )

    $existing = Get-MatchedProcess -Pattern $Pattern
    if ($existing.Count -gt 0) {
        Write-Log ("{0} already running. Skip duplicate start." -f $Name)
        if ($Port -le 0) {
            return $true
        }
        return (Test-TcpPortListening -Port $Port)
    }

    $stdout = Join-Path $LogsDir "$Name.out.log"
    $stderr = Join-Path $LogsDir "$Name.err.log"
    $fullArgs = @($Script:PythonArgsPrefix) + @($ScriptArgs)

    Write-Log ("Starting {0}: {1} {2}" -f $Name, $Script:PythonLauncher, ($fullArgs -join " "))
    Start-Process -FilePath $Script:PythonLauncher `
        -ArgumentList $fullArgs `
        -WorkingDirectory $BaseDir `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr | Out-Null

    if ($Port -gt 0) {
        $ok = Wait-PortReady -Port $Port -TimeoutSeconds 10
        Write-Log ("{0} port ready: {1}" -f $Name, $ok)
        return $ok
    }

    Start-Sleep -Milliseconds 600
    $started = (Get-MatchedProcess -Pattern $Pattern).Count -gt 0
    Write-Log ("{0} process ready: {1}" -f $Name, $started)
    return $started
}

function Ensure-StartupEntry {
    $startupDir = [Environment]::GetFolderPath("Startup")
    $startupBatPath = Join-Path $startupDir $StartupBatName
    $startupContent = @"
@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$BaseDir\autostart.ps1" -Silent
"@
    Set-Content -Path $startupBatPath -Value $startupContent -Encoding UTF8
    Write-Log ("Ensured startup entry: {0}" -f $startupBatPath)
}

function Ensure-FirstRunSetup {
    if ($SkipSetup) {
        Write-Log "Setup skipped by flag."
        return
    }

    Ensure-StartupEntry

    if (-not (Test-Path $SetupMarker)) {
        Set-Content -Path $SetupMarker -Value (Get-Date).ToString("o") -Encoding UTF8
        Write-Log "Setup marker created."
    }
}

function Ensure-FirewallRule {
    param(
        [string]$DisplayName,
        [int]$Port
    )

    if (-not (Test-IsAdministrator)) {
        Write-Log ("Not elevated. Skip firewall rule: {0}" -f $DisplayName)
        return
    }

    try {
        $existing = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-NetFirewallRule `
                -DisplayName $DisplayName `
                -Direction Inbound `
                -Action Allow `
                -Protocol TCP `
                -LocalPort $Port `
                -Profile Any | Out-Null
            Write-Log ("Created firewall rule: {0}" -f $DisplayName)
        }
    } catch {
        Write-Log ("Firewall rule skipped: {0}" -f $DisplayName)
    }
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
        if ($alias -match 'vEthernet|WSL|Hyper-V|VMware|VirtualBox|Loopback|Docker|Tailscale|ZeroTier|Bluetooth') {
            continue
        }

        [pscustomobject]@{
            IPAddress = $ip.IPAddress
            Metric = if ($iface) { $iface.InterfaceMetric } else { 9999 }
            Priority = if ($alias -match 'Wi-?Fi|WLAN') { 1 } elseif ($alias -match 'Ethernet') { 2 } else { 9 }
        }
    }

    $best = $candidates | Sort-Object Priority, Metric | Select-Object -First 1
    if ($best) {
        return $best.IPAddress
    }

    return $null
}

function Should-OpenBrowser {
    if ($ForceOpenBrowser) { return $true }
    if (-not $Silent) { return $true }
    if (-not (Test-Path $MarkerFile)) { return $true }

    try {
        $last = Get-Content -Raw -Encoding UTF8 $MarkerFile
        $lastDt = [DateTime]::Parse($last)
        return ((Get-Date) - $lastDt).TotalMinutes -ge 15
    } catch {
        return $true
    }
}

$mutex = New-Object System.Threading.Mutex($false, $MutexName)
$hasLock = $false

try {
    try {
        $hasLock = $mutex.WaitOne(0)
    } catch {
        $hasLock = $false
    }

    if (-not $hasLock) {
        Write-Log "Another launch is already running. Exit current instance."
        exit 0
    }

    Write-Log ("=== autostart.ps1 started (Silent={0} ForceOpenBrowser={1}) ===" -f $Silent, $ForceOpenBrowser)
    Resolve-PythonLauncher
    Ensure-FirstRunSetup

    Ensure-FirewallRule -DisplayName "VoiceInputSync HTTP 8000" -Port 8000
    Ensure-FirewallRule -DisplayName "VoiceInputSync WS 8765" -Port 8765

    $serverPy = Join-Path $BaseDir "server.py"
    $clientPy = Join-Path $BaseDir "client.py"

    $httpOk = Start-PythonProcess `
        -Name "http-server" `
        -ScriptArgs @("-m", "http.server", "8000", "--bind", "0.0.0.0") `
        -Pattern "*http.server*8000*" `
        -Port 8000

    $wsOk = Start-PythonProcess `
        -Name "websocket-server" `
        -ScriptArgs @($serverPy) `
        -Pattern "*$serverPy*" `
        -Port 8765

    $clientOk = Start-PythonProcess `
        -Name "desktop-client" `
        -ScriptArgs @($clientPy) `
        -Pattern "*$clientPy*"

    $lanIp = Get-LanIp
    $urlIp = if ($lanIp) { "http://$lanIp`:8000/mobile.html" } else { "http://127.0.0.1:8000/mobile.html" }

    Set-Content -Path $LatestUrlFile -Value $urlIp -Encoding UTF8

    try {
        Set-Clipboard -Value $urlIp
    } catch {
        Write-Log ("Clipboard skipped: {0}" -f $_.Exception.Message)
    }

    if (Should-OpenBrowser) {
        Start-Process $urlIp | Out-Null
        Set-Content -Path $MarkerFile -Value ((Get-Date).ToString("o")) -Encoding UTF8
        Write-Log ("Opened browser: {0}" -f $urlIp)
    }

    Write-Log ("Startup result: HTTP={0} WS={1} CLIENT={2} URL={3}" -f $httpOk, $wsOk, $clientOk, $urlIp)

    if (-not $Silent) {
        Write-Host "Voice Input Sync started." -ForegroundColor Cyan
        Write-Host ("Phone URL: {0}" -f $urlIp) -ForegroundColor Yellow
    }
} catch {
    Write-Log ("ERROR: {0}" -f $_.Exception.Message)
    if (-not $Silent) {
        Write-Host ("Start failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    exit 1
} finally {
    if ($hasLock) {
        try {
            $mutex.ReleaseMutex() | Out-Null
        } catch {
        }
    }
    $mutex.Dispose()
}
