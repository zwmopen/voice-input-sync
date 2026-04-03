param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Content,
        [System.Text.Encoding]$Encoding
    )

    $normalized = (($Content -split "\r?\n") -join "`r`n")
    [System.IO.File]::WriteAllText($Path, $normalized, $Encoding)
}

$projectRoot = Split-Path -Parent $PSCommandPath
$releaseRoot = Join-Path $projectRoot "release"
$packageRoot = Join-Path $releaseRoot "语音输入同步-绿色版"
$asciiSetupPath = Join-Path $releaseRoot "VoiceInputSync-Setup.exe"
$finalSetupPath = Join-Path $releaseRoot "语音输入同步-安装版.exe"
$buildRoot = Join-Path $projectRoot ".sfx-build"
$payloadRoot = Join-Path $buildRoot "payload-root"
$payloadDir = Join-Path $payloadRoot "payload"
$installPs1Path = Join-Path $payloadRoot "installer-install.ps1"
$installCmdPath = Join-Path $payloadRoot "install.cmd"
$sfxCommentPath = Join-Path $buildRoot "sfx-comment.txt"
$rarExe = "C:\Program Files\WinRAR\Rar.exe"
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
$asciiEncoding = [System.Text.Encoding]::ASCII

if (-not (Test-Path $rarExe)) {
    throw "这台机器没有可用的 WinRAR CLI：$rarExe"
}

& (Join-Path $projectRoot "build-portable.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "绿色版打包失败，无法继续生成安装版。"
}

Remove-Item $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $asciiSetupPath -Force -ErrorAction SilentlyContinue
Remove-Item $finalSetupPath -Force -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
Copy-Item (Join-Path $packageRoot "*") $payloadDir -Recurse -Force
Copy-Item (Join-Path $projectRoot "installer-install.ps1") $installPs1Path -Force

$installCmd = @"
@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer-install.ps1" -SourceDir "%~dp0payload"
exit /b %ERRORLEVEL%
"@
Write-TextFile -Path $installCmdPath -Content $installCmd -Encoding $asciiEncoding

$sfxComment = @"
;The comment below contains SFX script commands

Title=语音输入同步 安装版
Text
语音输入同步

安装完成后，会自动创建桌面和开始菜单快捷方式。
EndText
TempMode
Silent=1
Overwrite=1
Setup=install.cmd
"@
Write-TextFile -Path $sfxCommentPath -Content $sfxComment -Encoding $utf8Bom

Push-Location $payloadRoot
try {
    & $rarExe a -r -ep1 -sfx -z"$sfxCommentPath" -y $asciiSetupPath *
    if ($LASTEXITCODE -ne 0) {
        throw "WinRAR SFX 打包失败。"
    }
} finally {
    Pop-Location
}

if (-not (Test-Path $asciiSetupPath)) {
    throw "没有生成安装版 EXE。"
}

Copy-Item $asciiSetupPath $finalSetupPath -Force
Remove-Item $buildRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Installer build complete:"
Write-Host "  EXE  : $finalSetupPath"
