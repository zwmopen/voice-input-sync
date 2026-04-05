param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Step {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')"
    }
}

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
$venvDir = Join-Path $projectRoot ".build-venv"
$venvPython = Join-Path $venvDir "Scripts\python.exe"
$pyiRoot = Join-Path $projectRoot ".pyinstaller-portable"
$distRoot = Join-Path $pyiRoot "dist"
$workRoot = Join-Path $pyiRoot "build"
$specRoot = Join-Path $pyiRoot "spec"
$releaseRoot = Join-Path $projectRoot "release"
$productName = "语音输入同步-绿色版"
$packageRoot = Join-Path $releaseRoot $productName
$runtimeRoot = Join-Path $packageRoot "_runtime"
$zipPath = Join-Path $releaseRoot ($productName + ".zip")
$zipAliasPath = Join-Path $releaseRoot "VoiceInputSync-Portable.zip"
$setupAliasPath = Join-Path $releaseRoot "VoiceInputSync-Setup.exe"
$setupLocalizedPath = Join-Path $releaseRoot "语音输入同步-安装版.exe"
$iconScript = Join-Path $projectRoot "generate_app_icon.py"
$iconPath = Join-Path $projectRoot "assets\voice-sync-icon.ico"
$versionInfoPath = Join-Path $projectRoot "pyinstaller-version.txt"
$appVersionPath = Join-Path $projectRoot "app-version.txt"
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
$asciiEncoding = [System.Text.Encoding]::ASCII
$pyInstallerMode = "--onedir"
$existingRuntimeStop = Join-Path $runtimeRoot "portable-stop.ps1"

if (Test-Path $existingRuntimeStop) {
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $existingRuntimeStop -Silent
    } catch {
    }
}

$gitCommit = ""
try {
    $gitCommit = (git -C $projectRoot rev-parse --short HEAD 2>$null).Trim()
} catch {
    $gitCommit = ""
}

$appVersion = ""
if (Test-Path $appVersionPath) {
    try {
        $appVersion = (Get-Content -Raw -LiteralPath $appVersionPath -Encoding UTF8).Trim()
    } catch {
        $appVersion = ""
    }
}

$buildInfo = [ordered]@{
    buildId = [guid]::NewGuid().ToString("N")
    builtAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    gitCommit = $gitCommit
    appVersion = $appVersion
}
$buildInfoJson = $buildInfo | ConvertTo-Json -Compress

if (-not (Test-Path $venvPython)) {
    Invoke-Step -FilePath "python" -Arguments @("-m", "venv", $venvDir)
}

Invoke-Step -FilePath $venvPython -Arguments @("-m", "pip", "install", "--upgrade", "pip")
Invoke-Step -FilePath $venvPython -Arguments @("-m", "pip", "install", "pyinstaller", "websockets==11.0.3", "aiohttp", "keyboard", "qrcode", "pillow")
Invoke-Step -FilePath $venvPython -Arguments @($iconScript)

Remove-Item $pyiRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $packageRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $zipAliasPath -Force -ErrorAction SilentlyContinue
Remove-Item $setupAliasPath -Force -ErrorAction SilentlyContinue
Remove-Item $setupLocalizedPath -Force -ErrorAction SilentlyContinue

$buildTargets = @(
    @{ Name = "VoiceInputSyncRuntime"; Script = "portable_runtime.py" }
)

foreach ($target in $buildTargets) {
    $scriptPath = Join-Path $projectRoot $target.Script
    $args = @(
        "-m", "PyInstaller",
        "--noconfirm",
        "--clean",
        $pyInstallerMode,
        "--console",
        "--name", $target.Name,
        "--icon", $iconPath,
        "--version-file", $versionInfoPath,
        "--distpath", $distRoot,
        "--workpath", $workRoot,
        "--specpath", $specRoot,
        $scriptPath
    )
    Invoke-Step -FilePath $venvPython -Arguments $args
}

New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $packageRoot "logs") -Force | Out-Null

foreach ($target in $buildTargets) {
    $targetDir = Join-Path $distRoot $target.Name
    if (-not (Test-Path $targetDir)) {
        throw "Missing build output: $targetDir"
    }
    Copy-Item $targetDir $runtimeRoot -Recurse -Force
}

Copy-Item (Join-Path $projectRoot "mobile.html") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "favicon.svg") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "site.webmanifest") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "portable_http_server.py") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "server.py") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "client.py") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "generate_qr_bundle.py") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "portable_runtime.py") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "portable-start.ps1") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "portable-launch-ui.ps1") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "portable-qr-window.ps1") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "portable-check-update.ps1") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "portable-settings-window.ps1") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "portable-tray.ps1") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "portable-stop.ps1") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "README.md") $runtimeRoot -Force
Copy-Item (Join-Path $projectRoot "使用手册.md") $runtimeRoot -Force -ErrorAction SilentlyContinue
Set-Content -Path (Join-Path $runtimeRoot "build-info.json") -Value $buildInfoJson -Encoding UTF8
Copy-Item $appVersionPath (Join-Path $runtimeRoot "app-version.txt") -Force
Copy-Item (Join-Path $projectRoot "assets") $runtimeRoot -Recurse -Force
Remove-Item (Join-Path $runtimeRoot "assets\icon-options") -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $runtimeRoot "assets\voice-sync-icon-source.png") -Force -ErrorAction SilentlyContinue

Copy-Item (Join-Path $projectRoot "share-quick-start.txt") (Join-Path $packageRoot "先看这里.txt") -Force
Copy-Item (Join-Path $projectRoot "share-user-guide.html") (Join-Path $packageRoot "用户手册.html") -Force

Set-Content -Path (Join-Path $packageRoot "latest-url.txt") -Value "" -Encoding UTF8
Set-Content -Path (Join-Path $packageRoot "手机打开这个地址.txt") -Value "启动后，这里会自动写入手机要打开的地址。" -Encoding UTF8
Set-Content -Path (Join-Path $runtimeRoot "runtime-config.json") -Value '{"httpPort":8000,"wsPort":8765}' -Encoding UTF8
Set-Content -Path (Join-Path $packageRoot "手机扫码打开.html") -Value @"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>语音输入同步 - 请先启动</title>
    <style>
        :root {
            --bg-top: #f9f4ec;
            --bg-bottom: #f1ebe2;
            --paper: rgba(255, 252, 246, 0.94);
            --text: #1f2a38;
            --muted: #5e6a78;
            --line: rgba(31, 42, 56, 0.1);
            --shadow: 0 24px 56px rgba(91, 70, 43, 0.14);
            --green: #1f8f5f;
            --green-soft: rgba(31, 143, 95, 0.1);
            --amber: #d97706;
        }

        * {
            box-sizing: border-box;
        }

        body {
            margin: 0;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 24px;
            color: var(--text);
            font-family: "Microsoft YaHei UI", "PingFang SC", "Noto Sans SC", sans-serif;
            background:
                radial-gradient(circle at top left, rgba(217, 119, 6, 0.12), transparent 28%),
                radial-gradient(circle at right top, rgba(31, 143, 95, 0.11), transparent 24%),
                linear-gradient(180deg, var(--bg-top) 0%, var(--bg-bottom) 100%);
        }

        .shell {
            width: min(760px, 100%);
        }

        .card {
            position: relative;
            overflow: hidden;
            padding: 34px;
            border-radius: 28px;
            border: 1px solid var(--line);
            background: var(--paper);
            box-shadow: var(--shadow);
            backdrop-filter: blur(8px);
        }

        .card::after {
            content: "";
            position: absolute;
            top: -78px;
            right: -78px;
            width: 210px;
            height: 210px;
            border-radius: 50%;
            background: radial-gradient(circle, rgba(31, 143, 95, 0.16), transparent 68%);
            pointer-events: none;
        }

        .badge {
            display: inline-flex;
            align-items: center;
            padding: 8px 14px;
            border-radius: 999px;
            font-size: 13px;
            font-weight: 700;
            letter-spacing: 0.04em;
            color: var(--green);
            background: var(--green-soft);
        }

        h1 {
            margin: 16px 0 12px;
            font-size: clamp(30px, 5vw, 46px);
            line-height: 1.08;
        }

        .lead {
            margin: 0;
            max-width: 560px;
            font-size: 17px;
            line-height: 1.8;
            color: var(--muted);
        }

        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
            gap: 16px;
            margin-top: 26px;
        }

        .panel {
            padding: 20px;
            border-radius: 20px;
            border: 1px solid var(--line);
            background: rgba(255, 255, 255, 0.76);
        }

        .panel.primary {
            border-color: rgba(31, 143, 95, 0.18);
            background: linear-gradient(180deg, rgba(244, 252, 248, 0.96), rgba(255, 255, 255, 0.88));
        }

        .panel.secondary {
            border-color: rgba(217, 119, 6, 0.18);
            background: linear-gradient(180deg, rgba(255, 248, 239, 0.96), rgba(255, 255, 255, 0.88));
        }

        .kicker {
            margin: 0 0 10px;
            font-size: 13px;
            font-weight: 700;
            letter-spacing: 0.04em;
            text-transform: uppercase;
        }

        .primary .kicker {
            color: var(--green);
        }

        .secondary .kicker {
            color: var(--amber);
        }

        .panel h2 {
            margin: 0 0 12px;
            font-size: 22px;
            line-height: 1.35;
        }

        .panel p {
            margin: 0;
            color: var(--muted);
            line-height: 1.75;
            font-size: 15px;
        }

        .filename {
            display: inline-block;
            margin-top: 14px;
            padding: 10px 14px;
            border-radius: 14px;
            background: rgba(31, 42, 56, 0.06);
            color: var(--text);
            font-size: 14px;
            font-weight: 700;
            word-break: break-all;
        }

        .hint {
            margin-top: 18px;
            padding: 16px 18px;
            border-radius: 18px;
            border: 1px solid rgba(31, 143, 95, 0.14);
            background: rgba(31, 143, 95, 0.07);
            color: #2a5a45;
            font-size: 14px;
            line-height: 1.7;
        }

        .hint strong {
            color: var(--green);
        }

        @media (max-width: 640px) {
            body {
                padding: 16px;
            }

            .card {
                padding: 24px;
                border-radius: 22px;
            }

            h1 {
                font-size: 32px;
            }

            .lead {
                font-size: 16px;
            }
        }
    </style>
</head>
<body>
    <main class="shell">
        <section class="card">
            <div class="badge">启动提示</div>
            <h1>先启动电脑端，再用手机扫码</h1>
            <p class="lead">这不是报错页。先把电脑端程序拉起来，当前页面就会自动切换成扫码连接页，不用手动刷新。</p>

            <div class="grid">
                <article class="panel primary">
                    <p class="kicker">先做这个</p>
                    <h2>双击启动主程序</h2>
                    <p>打开绿色包根目录里的启动脚本，等几秒钟，页面会自动变成二维码连接页。</p>
                    <div class="filename">双击启动语音输入同步.bat</div>
                </article>

                <article class="panel secondary">
                    <p class="kicker">没反应再用</p>
                    <h2>改用管理员启动</h2>
                    <p>只有在手机已经连上，但电脑端还是没有开始输入时，才需要换这个脚本。</p>
                    <div class="filename">如果输入没反应-请用管理员启动.bat</div>
                </article>
            </div>

            <div class="hint">
                <strong>小提示：</strong>保持这个页面开着就行。启动成功后，它会自己变成扫码页。
            </div>
        </section>
    </main>
</body>
</html>
"@ -Encoding UTF8

$startBat = @"
@echo off
setlocal
cd /d "%~dp0"
start "" wscript.exe //nologo "%~dp0启动语音输入同步.vbs"
exit /b 0
"@
Write-TextFile -Path (Join-Path $packageRoot "双击启动语音输入同步.bat") -Content $startBat -Encoding $utf8Bom

$startVbs = @"
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
shell.CurrentDirectory = baseDir
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & baseDir & "\_runtime\portable-launch-ui.ps1""", 0, False
"@
Write-TextFile -Path (Join-Path $packageRoot "启动语音输入同步.vbs") -Content $startVbs -Encoding $asciiEncoding

$adminBat = @"
@echo off
setlocal
title 语音输入同步（管理员启动）
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo 正在申请管理员权限，请稍候几秒...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs -FilePath 'powershell.exe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%~dp0_runtime\portable-launch-ui.ps1""'"
exit /b %ERRORLEVEL%
"@
Write-TextFile -Path (Join-Path $packageRoot "如果输入没反应-请用管理员启动.bat") -Content $adminBat -Encoding $utf8Bom

$stopBat = @"
@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_runtime\portable-stop.ps1"
exit /b %ERRORLEVEL%
"@
Write-TextFile -Path (Join-Path $packageRoot "关闭语音输入同步.bat") -Content $stopBat -Encoding $asciiEncoding

Get-ChildItem (Join-Path $packageRoot "logs") -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $packageRoot "*") -DestinationPath $zipPath -Force

Write-Host "Build complete:"
Write-Host "  Folder: $packageRoot"
Write-Host "  Zip   : $zipPath"
