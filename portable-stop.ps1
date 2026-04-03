param(
    [switch]$Silent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDir = Split-Path -Parent $BaseDir
$LogsDir = Join-Path $PackageDir "logs"

New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path (Join-Path $LogsDir "shutdown.log") -Value "[$stamp] $Message"
}

function Get-ManagedProcesses {
    $targets = @(
        (Join-Path $BaseDir "VoiceInputSyncHttp.exe"),
        (Join-Path $BaseDir "VoiceInputSyncWs.exe"),
        (Join-Path $BaseDir "VoiceInputSyncClient.exe")
    )

    $targetSet = @{}
    foreach ($target in $targets) {
        $targetSet[$target.ToLowerInvariant()] = $true
    }

    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and $targetSet.ContainsKey($_.ExecutablePath.ToLowerInvariant())
    })
}

function Get-ManagedAuxiliaryProcesses {
    $trayPattern = [regex]::Escape((Join-Path $BaseDir "portable-tray.ps1"))

    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine -match $trayPattern
    })
}

try {
    Write-Log "=== portable-stop.ps1 started ==="

    $processes = @(Get-ManagedProcesses) + @(Get-ManagedAuxiliaryProcesses)
    $stopped = 0

    foreach ($proc in $processes) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            $stopped++
            Write-Log ("Stopped PID={0} Name={1}" -f $proc.ProcessId, $proc.Name)
        } catch {
            Write-Log ("Stop failed PID={0}: {1}" -f $proc.ProcessId, $_.Exception.Message)
        }
    }

    Write-Log ("Shutdown result: stopped={0}" -f $stopped)

    if (-not $Silent) {
        Write-Host ""
        Write-Host ("语音输入同步已关闭，结束了 {0} 个相关进程。" -f $stopped) -ForegroundColor Cyan
        Write-Host ""
    }
} catch {
    Write-Log ("ERROR: " + $_.Exception.Message)
    if (-not $Silent) {
        Write-Host ""
        Write-Host ("关闭失败：" + $_.Exception.Message) -ForegroundColor Red
        Write-Host ""
    }
    exit 1
}
