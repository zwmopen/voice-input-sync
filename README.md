# 语音输入同步

把手机上的语音/文字输入，实时同步到电脑当前输入框。  
优先走局域网直连，局域网不通时可切换互联网备用地址。

## 下载

- 安装版：[Releases](https://github.com/zwmopen/voice-input-sync/releases/latest) 下载 `VoiceInputSync-Setup-v2026.04.12.01.exe`
- 绿色版：[Releases](https://github.com/zwmopen/voice-input-sync/releases/latest) 下载 `VoiceInputSync-Portable-v2026.04.12.01.zip`

## 三步上手（新版）

1. 双击桌面 `语音输入同步` 启动应用。
2. 扫码页会自动打开，先扫“局域网直连”二维码。
3. 电脑状态变成“已连接”后，回电脑点中目标输入框，再在手机端输入。

## 图文手册

- 本地离线版：[`share-user-guide.html`](./share-user-guide.html)
- 文本手册：[`使用手册.md`](./使用手册.md)

## 设置与更新（你这次提到的入口）

- 扫码主界面右上角新增了 `设置` 按钮（齿轮）。
- 检测到 GitHub 有新版本时，设置按钮右上会显示绿色提示点。
- 点设置后可直接“立即检查”或“打开下载页”更新。

## 常见问题

- 手机能打开页面，但电脑不输入：先回电脑点中真正输入框，再输入。
- 手机打不开局域网地址：先确认手机与电脑在同一网络，再尝试互联网备用地址。
- 托盘菜单无反应：升级到最新版本（本项目已做右键原生菜单兜底）。

## 核心文件

- `portable-launch-ui.ps1`：启动窗口
- `portable-start.ps1`：启动主流程
- `portable-qr-window.ps1`：扫码主界面（含设置按钮与更新点）
- `portable-settings-window.ps1`：设置页（版本检查）
- `portable-tray.ps1`：托盘菜单
- `mobile.html`：手机输入页
