param(
    [string]$SourceZip = "",
    [string]$SourceDir = "",
    [switch]$LaunchAfterInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$zipPath = if ($SourceZip) { $SourceZip } else { Join-Path $scriptDir "语音输入同步-绿色版.zip" }
$productName = "语音输入同步"
$productVersion = "2026.04.03.1"
$installDir = Join-Path $env:LOCALAPPDATA "Programs\$productName"
$desktopShortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "$productName.lnk"
$startMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$productName"
$startMenuShortcutPath = Join-Path $startMenuDir "$productName.lnk"
$uninstallShortcutPath = Join-Path $startMenuDir "卸载$productName.lnk"
$uninstallRegistryKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$productName"
$tempExtractDir = Join-Path ([System.IO.Path]::GetTempPath()) ("voice-input-sync-install-" + [guid]::NewGuid().ToString("N"))
$iconPath = Join-Path $installDir "_runtime\assets\voice-sync-icon.ico"
$launcherBat = Join-Path $installDir "双击启动语音输入同步.bat"
$uninstallScript = Join-Path $installDir "uninstall.ps1"
$uninstallBat = Join-Path $installDir "卸载语音输入同步.bat"

function New-Shortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetPath,
        [string]$Arguments = "",
        [string]$WorkingDirectory = "",
        [string]$IconLocation = "",
        [string]$Description = ""
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    if ($WorkingDirectory) {
        $shortcut.WorkingDirectory = $WorkingDirectory
    }
    if ($IconLocation) {
        $shortcut.IconLocation = $IconLocation
    }
    if ($Description) {
        $shortcut.Description = $Description
    }
    $shortcut.Save()
}

$contentRoot = ""
if ($SourceDir -and (Test-Path $SourceDir)) {
    $contentRoot = $SourceDir
} elseif (Test-Path $zipPath) {
    $contentRoot = ""
} else {
    throw "找不到安装载荷。"
}

Write-Host ""
Write-Host "语音输入同步正在安装，请稍候..." -ForegroundColor Cyan
Write-Host ""

New-Item -ItemType Directory -Path $tempExtractDir -Force | Out-Null
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
New-Item -ItemType Directory -Path $startMenuDir -Force | Out-Null

try {
    if (Test-Path $launcherBat) {
        try {
            $stopScript = Join-Path $installDir "_runtime\portable-stop.ps1"
            if (Test-Path $stopScript) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $stopScript -Silent
            }
        } catch {
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not $contentRoot) {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tempExtractDir -Force
        $contentRoot = $tempExtractDir
    }

    Copy-Item -Path (Join-Path $contentRoot "*") -Destination $installDir -Recurse -Force

    $uninstallScriptContent = @(
        "param()"
        "Set-StrictMode -Version Latest"
        "`$ErrorActionPreference = 'Stop'"
        "`$installDir = Split-Path -Parent `$MyInvocation.MyCommand.Path"
        "`$desktopShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) '语音输入同步.lnk'"
        "`$startMenuDir = Join-Path `$env:APPDATA 'Microsoft\Windows\Start Menu\Programs\语音输入同步'"
        "`$registryKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\语音输入同步'"
        "try {"
        "    `$stopScript = Join-Path `$installDir '_runtime\portable-stop.ps1'"
        "    if (Test-Path `$stopScript) {"
        "        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$stopScript -Silent"
        "    }"
        "} catch {"
        "}"
        "Start-Sleep -Milliseconds 500"
        "Remove-Item `$desktopShortcutPath -Force -ErrorAction SilentlyContinue"
        "Remove-Item `$startMenuDir -Recurse -Force -ErrorAction SilentlyContinue"
        "Remove-Item `$registryKey -Force -Recurse -ErrorAction SilentlyContinue"
        "Set-Location ([System.IO.Path]::GetTempPath())"
        "Remove-Item `$installDir -Recurse -Force -ErrorAction SilentlyContinue"
        "Write-Host ''"
        "Write-Host '语音输入同步已卸载。' -ForegroundColor Green"
        "Write-Host ''"
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($uninstallScript, (($uninstallScriptContent -split "`r?`n") -join "`r`n"), [System.Text.UTF8Encoding]::new($true))

    $uninstallBatContent = @(
        "@echo off"
        "setlocal"
        'cd /d "%~dp0"'
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"'
        "exit /b %ERRORLEVEL%"
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($uninstallBat, (($uninstallBatContent -split "`r?`n") -join "`r`n"), [System.Text.UTF8Encoding]::new($true))

    New-Shortcut -ShortcutPath $desktopShortcutPath -TargetPath $launcherBat -WorkingDirectory $installDir -IconLocation $iconPath -Description $productName
    New-Shortcut -ShortcutPath $startMenuShortcutPath -TargetPath $launcherBat -WorkingDirectory $installDir -IconLocation $iconPath -Description $productName
    New-Shortcut -ShortcutPath $uninstallShortcutPath -TargetPath $uninstallBat -WorkingDirectory $installDir -IconLocation $iconPath -Description ("卸载" + $productName)

    New-Item -Path $uninstallRegistryKey -Force | Out-Null
    New-ItemProperty -Path $uninstallRegistryKey -Name "DisplayName" -Value $productName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallRegistryKey -Name "DisplayVersion" -Value $productVersion -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallRegistryKey -Name "Publisher" -Value "zwmopen" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallRegistryKey -Name "InstallLocation" -Value $installDir -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallRegistryKey -Name "DisplayIcon" -Value $iconPath -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallRegistryKey -Name "UninstallString" -Value ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $uninstallScript + '"') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallRegistryKey -Name "NoModify" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $uninstallRegistryKey -Name "NoRepair" -Value 1 -PropertyType DWord -Force | Out-Null

    if ($LaunchAfterInstall -and (Test-Path $launcherBat)) {
        Start-Process -FilePath $launcherBat | Out-Null
    }

    Write-Host "安装完成。" -ForegroundColor Green
    Write-Host ("安装位置: " + $installDir) -ForegroundColor DarkGray
    Write-Host "桌面和开始菜单快捷方式都已经创建。" -ForegroundColor DarkGray
    Write-Host ""
} finally {
    Remove-Item $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
}
