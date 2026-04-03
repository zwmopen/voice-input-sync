param(
    [switch]$Silent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PackageDir = Split-Path -Parent $BaseDir
$LogsDir = Join-Path $PackageDir "logs"

New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null

function Resolve-ManagedExecutablePath {
    param([string]$BaseName)

    $flatPath = Join-Path $BaseDir ($BaseName + ".exe")
    if (Test-Path $flatPath) {
        return $flatPath
    }

    $folderPath = Join-Path (Join-Path $BaseDir $BaseName) ($BaseName + ".exe")
    if (Test-Path $folderPath) {
        return $folderPath
    }

    return $flatPath
}

function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path (Join-Path $LogsDir "shutdown.log") -Value "[$stamp] $Message"
}

function Get-ManagedProcesses {
    $targets = @(
        (Resolve-ManagedExecutablePath -BaseName "VoiceInputSyncHttp"),
        (Resolve-ManagedExecutablePath -BaseName "VoiceInputSyncWs"),
        (Resolve-ManagedExecutablePath -BaseName "VoiceInputSyncClient")
    )

    $processes = @()
    foreach ($target in $targets) {
        if (-not (Test-Path $target)) {
            continue
        }

        $processName = [System.IO.Path]::GetFileNameWithoutExtension($target)
        $normalizedPath = [System.IO.Path]::GetFullPath($target).ToLowerInvariant()

        foreach ($proc in @(Get-Process -Name $processName -ErrorAction SilentlyContinue)) {
            $procPath = $null
            try {
                $procPath = $proc.Path
            } catch {
                $procPath = $null
            }

            if ($procPath -and $procPath.ToLowerInvariant() -eq $normalizedPath) {
                $processes += $proc
            }
        }
    }

    return $processes
}

function Get-ManagedAuxiliaryProcesses {
    $trayPattern = [regex]::Escape((Join-Path $BaseDir "portable-tray.ps1"))

    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine -match $trayPattern
    })
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

function Get-ProcessNameValue {
    param($ProcessObject)

    if ($null -ne $ProcessObject -and $null -ne $ProcessObject.PSObject.Properties["ProcessName"]) {
        return [string]$ProcessObject.ProcessName
    }
    if ($null -ne $ProcessObject -and $null -ne $ProcessObject.PSObject.Properties["Name"]) {
        return [string]$ProcessObject.Name
    }

    return "unknown"
}

try {
    Write-Log "=== portable-stop.ps1 started ==="

    $processes = @(Get-ManagedProcesses) + @(Get-ManagedAuxiliaryProcesses)
    $stopped = 0

    foreach ($proc in $processes) {
        try {
            $procId = Get-ProcessIdValue -ProcessObject $proc
            Stop-Process -Id $procId -Force -ErrorAction Stop
            $stopped++
            Write-Log ("Stopped PID={0} Name={1}" -f $procId, (Get-ProcessNameValue -ProcessObject $proc))
        } catch {
            Write-Log ("Stop failed PID={0}: {1}" -f (Get-ProcessIdValue -ProcessObject $proc), $_.Exception.Message)
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
