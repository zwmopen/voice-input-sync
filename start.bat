@echo off
chcp 65001 >nul
title 语音输入同步系统

echo ============================================================
echo 语音输入同步系统 - 启动中...
echo ============================================================
echo.

:: 获取正确的局域网IP（排除169.254.x.x）
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr "IPv4"') do (
    for /f "tokens=1-4 delims=." %%b in ("%%a") do (
        if not "%%b"=="169" (
            set REAL_IP=%%b.%%c.%%d.%%e
            goto :found
        )
    )
)

:found
if "%REAL_IP%"=="" (
    echo [错误] 未找到有效的局域网IP地址
    pause
    exit /b 1
)

echo [√] 局域网IP: %REAL_IP%
echo.

:: 复制网址到剪贴板
echo http://%REAL_IP%:8000/mobile.html | clip

:: 启动HTTP服务器
start "HTTP Server" /min python -m http.server 8000

:: 启动WebSocket服务器
start "WebSocket Server" /min python server.py

:: 启动客户端
start "Client" python client.py

:: 打开浏览器
timeout /t 2 /nobreak >nul
start http://localhost:8000/mobile.html

echo.
echo ============================================================
echo [√] 启动完成！
echo ============================================================
echo.
echo 手机访问: http://%REAL_IP%:8000/mobile.html
echo (已复制到剪贴板)
echo.
pause
