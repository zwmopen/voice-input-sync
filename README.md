# 语音输入同步系统

**手机端语音输入 → 实时同步到电脑 → 自动打字到任意窗口**

[![GitHub](https://img.shields.io/badge/GitHub-zwmopen/voice--input--sync-blue)](https://github.com/zwmopen/voice-input-sync)
[![Python](https://img.shields.io/badge/Python-3.7+-green)](https://www.python.org/)
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

---

## ✨ 特点

- 🎤 **使用手机语音输入法** - 识别更准确，麦克风质量更好
- ⚡ **实时同步** - 无需点击发送，即输即打
- 🎯 **支持任意窗口** - Word、记事本、聊天框等所有应用
- 🎨 **拟态风格UI** - 舒适美观的界面设计
- 🔧 **丰富控制** - 文字、清空、换行、删除、Tab、空格
- 🚀 **开机自启** - 支持后台自动启动
- 📱 **跨平台** - 手机支持iOS/Android，电脑Windows

---

## 🚀 快速开始

### 1. 安装依赖

```bash
pip install websockets keyboard
```

### 2. 启动系统

```bash
双击运行 start.bat
```

或手动启动：

```bash
# 启动HTTP服务器
python -m http.server 8000

# 启动WebSocket服务器
python server.py

# 启动客户端
python client.py
```

### 3. 手机连接

1. 手机和电脑连接同一WiFi
2. 手机浏览器访问显示的网址
3. 使用语音输入法开始输入

---

## 📖 使用方法

1. **电脑端**：打开任意窗口，光标放在输入位置
2. **手机端**：点击输入框，使用语音输入法说话
3. **自动同步**：文字实时出现在电脑上

### 控制按钮

| 按钮 | 功能 |
|------|------|
| 🗑️ 清空 | 清空手机和电脑端所有文字 |
| ↵ 换行 | 发送回车键 |
| 📤 发送全部 | 发送输入框中所有文字 |
| ⌫ 删除 | 发送退格键 |
| ␣ 空格 | 发送空格键 |
| ⇥ Tab | 发送Tab键 |

---

## ⚙️ 开机自启

### 方法1：启动文件夹（推荐）

1. 按 `Win + R`，输入 `shell:startup`
2. 右键 → 新建 → 快捷方式
3. 位置：`D:\AICode\voice-input-sync\autostart.vbs`
4. 完成

### 方法2：任务计划程序

1. Win + R → 输入 `taskschd.msc`
2. 右侧点击"创建基本任务"
3. 名称：语音输入同步
4. 触发器：启动时
5. 操作：启动程序
6. 程序：`D:\AICode\voice-input-sync\autostart.vbs`

---

## 🔧 故障排查

### 手机无法访问

- ✅ 确保手机和电脑在同一WiFi
- ✅ 关闭防火墙或添加端口例外
- ✅ 检查路由器是否启用AP隔离

### 文字没有输入

- ✅ 检查client.py是否运行
- ✅ 确保输入框有光标闪烁
- ✅ 以管理员权限运行

---

## 📊 技术架构

```
手机语音输入
    ↓
WebSocket通信
    ↓
服务器中转
    ↓
keyboard模拟输入
    ↓
任意窗口显示
```

---

## 📁 文件说明

```
voice-input-sync/
├── server.py          # WebSocket服务器
├── client.py          # 电脑客户端
├── mobile.html        # 手机端界面
├── start.bat          # 一键启动脚本
├── autostart.vbs      # 开机自启脚本
├── 使用手册.md        # 详细使用手册
└── README.md          # 本文件
```

---

## 🎯 应用场景

- 📝 写文档（Word、Markdown）
- 💬 聊天（微信、飞书、QQ）
- 💻 编程（VS Code、记事本）
- 📧 邮件（Outlook、Gmail）
- 🎨 设计（Figma、Sketch）

---

## 📝 更新日志

### v1.0.0 (2026-03-10)
- ✅ 初始版本发布
- ✅ 实时语音输入同步
- ✅ 拟态风格UI设计
- ✅ 清空功能同步电脑端
- ✅ 开机自启支持
- ✅ 详细使用手册

---

## 📄 许可证

MIT License

---

## 🤝 贡献

欢迎提交Issue和Pull Request！

---

**作者**：zwmopen
**GitHub**：https://github.com/zwmopen/voice-input-sync
