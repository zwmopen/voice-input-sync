# 语音输入同步

这个项目用于把手机上的语音输入或文字输入，实时同步到电脑当前光标所在的输入框里，适合聊天、写文案、写笔记和轻量办公。

## 推荐启动方式

- 桌面双击 `语音输入同步-启动并打开地址.bat`
- 或直接运行 [start.bat](D:\AICode\voice-input-sync\start.bat)

启动后会自动完成这些事情：

- 启动手机页面服务，端口 `8000`
- 启动 WebSocket 服务，端口 `8765`
- 启动桌面输入客户端
- 自动计算当前局域网手机访问地址
- 自动打开浏览器，并把地址复制到剪贴板

## 主要文件

- [autostart.ps1](D:\AICode\voice-input-sync\autostart.ps1)：后台核心启动脚本
- [launch-ui.ps1](D:\AICode\voice-input-sync\launch-ui.ps1)：带中文提示的前台启动脚本
- [start.bat](D:\AICode\voice-input-sync\start.bat)：推荐使用的稳定入口
- [启动并打开手机地址.bat](D:\AICode\voice-input-sync\启动并打开手机地址.bat)：中文别名入口
- [latest-url.txt](D:\AICode\voice-input-sync\latest-url.txt)：最近一次生成的手机访问地址
- [logs\startup.log](D:\AICode\voice-input-sync\logs\startup.log)：启动日志

## 手机怎么打开

双击启动后，浏览器会自动打开，同时项目会把手机地址写入 [latest-url.txt](D:\AICode\voice-input-sync\latest-url.txt)。

地址通常长这样：

```text
http://你的局域网IP:8000/mobile.html
```

只要手机和电脑在同一个局域网里，就可以直接打开这个地址。

## 这次修复了什么

- 修复了入口脚本在 `cmd` 下解析异常的问题
- 统一了桌面入口和项目入口的启动链路
- 重写了中文说明，避免再出现大片乱码
- 保留了开机自启能力，同时避免重复启动多个实例