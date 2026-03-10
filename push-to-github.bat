@echo off
chcp 65001 >nul
title 推送到GitHub

echo ========================================
echo  推送 voice-input-sync 到 GitHub
echo ========================================
echo.

cd /d "%~dp0"

echo [1/5] 检查Git状态...
git status
echo.

echo [2/5] 添加所有文件...
git add .
echo ✅ 文件已添加
echo.

echo [3/5] 提交更改...
git commit -m "feat: 初始版本 - 实时语音输入同步系统

- ✅ WebSocket实时通信
- ✅ 手机语音输入 → 电脑自动打字
- ✅ 支持任意窗口（Word、聊天框等）
- ✅ 拟态风格UI设计
- ✅ 丰富控制按钮（清空、换行、删除、Tab、空格）
- ✅ 开机自启支持
- ✅ 详细使用手册
- ✅ MIT许可证"
echo ✅ 提交完成
echo.

echo [4/5] 检查GitHub CLI...
where gh >nul 2>&1
if %errorlevel% equ 0 (
    echo ✅ 检测到GitHub CLI
    
    echo [5/5] 创建GitHub仓库并推送...
    gh repo create voice-input-sync --public --source=. --remote=origin --push
    
    if %errorlevel% equ 0 (
        echo.
        echo ========================================
        echo  ✅ 发布成功！
        echo ========================================
        echo.
        echo 📦 仓库地址: https://github.com/zwmopen/voice-input-sync
        echo.
        echo 📖 README已包含：
        echo    - 项目介绍
        echo    - 快速开始
        echo    - 使用方法
        echo    - 故障排查
        echo    - 技术架构
        echo.
        start https://github.com/zwmopen/voice-input-sync
    ) else (
        echo ❌ 创建仓库失败
        echo 请检查GitHub CLI是否已登录
        echo 运行: gh auth login
    )
) else (
    echo ⚠️  未检测到GitHub CLI
    
    echo [5/5] 手动配置远程仓库...
    echo.
    echo 请手动创建GitHub仓库：
    echo 1. 访问 https://github.com/new
    echo 2. 仓库名称: voice-input-sync
    echo 3. 选择 Public
    echo 4. 不要勾选 "Initialize with README"
    echo 5. 点击 "Create repository"
    echo.
    echo 创建后，复制仓库URL，然后运行：
    echo git remote add origin YOUR_REPO_URL
    echo git push -u origin master
    echo.
    start https://github.com/new
)

echo.
pause
