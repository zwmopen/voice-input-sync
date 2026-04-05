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

function Get-ProcessCommandLineValue {
    param($ProcessObject)

    if ($null -ne $ProcessObject -and $null -ne $ProcessObject.PSObject.Properties["CommandLine"]) {
        return [string]$ProcessObject.CommandLine
    }

    return ""
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

function Get-LegacyProcesses {
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

    return @($targets.ToArray() | Group-Object { Get-ProcessIdValue -ProcessObject $_ } | ForEach-Object { $_.Group[0] })
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

try {
    Write-Log "=== portable-stop.ps1 started ==="

    $processes = @(Get-ManagedProcesses) + @(Get-ManagedAuxiliaryProcesses) + @(Get-LegacyProcesses) + @(Get-TunnelProcesses)
    $processes = @($processes | Group-Object { Get-ProcessIdValue -ProcessObject $_ } | ForEach-Object { $_.Group[0] })
    $stopped = 0

    foreach ($proc in $processes) {
        try {
            $procId = Get-ProcessIdValue -ProcessObject $proc
            Stop-Process -Id $procId -Force -ErrorAction Stop
            $stopped++
            Write-Log ("Stopped PID={0} Name={1} CMD={2}" -f $procId, (Get-ProcessNameValue -ProcessObject $proc), (Get-ProcessCommandLineValue -ProcessObject $proc))
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
