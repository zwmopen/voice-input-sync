@echo off
chcp 65001 >nul
title 语音输入同步系统

echo ============================================================
echo 语音输入同步系统 - 启动中...
echo ============================================================
echo.

:: 获取电脑名（固定地址）
for /f "skip=1" %%a in ('hostname') do set PC_NAME=%%a
set PC_NAME=%COMPUTERNAME%

:: 获取局域网IP（备用）
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr "IPv4"') do (
    for /f "tokens=1-4 delims=." %%b in ("%%a") do (
        if not "%%b"=="169" (
            set LOCAL_IP=%%b.%%c.%%d.%%e
        )
    )
)

echo [√] 电脑名: %PC_NAME%
echo [√] 局域网IP: %LOCAL_IP%
echo.

:: 设置固定访问地址（使用电脑名）
set HTTP_URL=http://%PC_NAME%:8000/mobile.html
set HTTP_URL_IP=http://%LOCAL_IP%:8000/mobile.html

:: 启动HTTP服务器
start "HTTP Server" /min cmd /c "cd /d D:\AICode\voice-input-sync && python -m http.server 8000"

:: 启动WebSocket服务器
start "WebSocket Server" /min cmd /c "cd /d D:\AICode\voice-input-sync && python server.py"

:: 启动客户端
start "Client" cmd /k "cd /d D:\AICode\voice-input-sync && python client.py"

:: 等待服务启动
timeout /t 2 /nobreak >nul

:: 在电脑浏览器打开（用于测试）
start %HTTP_URL%

:: 复制固定地址到剪贴板（使用电脑名）
echo %HTTP_URL% | clip

echo.
echo ============================================================
echo [√] 启动完成！
echo ============================================================
echo.
echo 📱 手机访问地址（推荐使用，已复制）：
echo    %HTTP_URL%
echo    （固定地址，不会变化）
echo.
echo 📱 备用地址（IP地址）：
echo    %HTTP_URL_IP%
echo    （可能会变化）
echo.
echo 💡 使用说明：
echo    1. 在电脑上打开任意窗口，光标放在输入位置
echo    2. 在手机网页上用语音输入法说话
echo    3. 文字会自动输入到电脑
echo.
echo ⭐ 提示：
echo    - 建议在手机浏览器保存书签，下次直接访问
echo    - 使用电脑名访问，地址固定不变
echo.
pause
