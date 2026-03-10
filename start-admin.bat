@echo off
chcp 65001 >nul
title 语音输入同步系统（管理员权限）

echo ============================================================
echo 语音输入同步系统 - 启动中...
echo ============================================================
echo.

:: 获取局域网IP（排除169.254.x.x）
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr "IPv4"') do (
    for /f "tokens=1-4 delims=." %%b in ("%%a") do (
        if not "%%b"=="169" (
            set LOCAL_IP=%%b.%%c.%%d.%%e
        )
    )
)

echo [√] 局域网IP: %LOCAL_IP%
echo.

:: 复制网址到剪贴板
echo http://%LOCAL_IP%:8000/mobile.html | clip

:: 启动HTTP服务器
start "HTTP Server" /min python -m http.server 8000

:: 启动WebSocket服务器
start "WebSocket Server" /min python server.py

:: 等待服务启动
timeout /t 2 /nobreak >nul

:: 启动客户端（管理员权限）
echo [!] 正在以管理员权限启动客户端...
powershell -Command "Start-Process python -ArgumentList 'client.py' -Verb RunAs -WorkingDirectory '%~dp0'"

:: 等待客户端启动
timeout /t 1 /nobreak >nul

:: 打开浏览器
start http://localhost:8000/mobile.html

echo.
echo ============================================================
echo [√] 启动完成！
echo ============================================================
echo.
echo 📱 手机访问地址（已复制到剪贴板）：
echo    http://%LOCAL_IP%:8000/mobile.html
echo.
echo ⚠️  重要提示：
echo    客户端已以管理员权限启动
echo    如果弹出UAC提示，请点击"是"
echo.
echo 💡 使用说明：
echo    1. 在电脑上打开任意窗口，光标放在输入位置
echo    2. 在手机网页上用语音输入法说话
echo    3. 文字会自动输入到电脑
echo.
pause
