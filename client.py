"""
电脑端客户端
接收手机端文字并模拟键盘输入到当前窗口，同时把运行日志写入文件。
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
from datetime import datetime
from pathlib import Path

import keyboard
import websockets


os.environ["PYTHONIOENCODING"] = "utf-8"
SERVER_URL = "ws://localhost:8765"
DELETE_SPEED = 0.01


def resolve_log_file() -> Path:
    if getattr(sys, "frozen", False):
        base_dir = Path(sys.executable).resolve().parent.parent / "logs"
    else:
        base_dir = Path(__file__).resolve().parent / "logs"
    base_dir.mkdir(parents=True, exist_ok=True)
    return base_dir / "client-runtime.log"


LOG_FILE = resolve_log_file()


def log(message: str) -> None:
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {message}"
    print(line, flush=True)
    with LOG_FILE.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")


async def register_desktop(websocket) -> None:
    await websocket.send(json.dumps({"type": "register", "role": "desktop"}, ensure_ascii=False))
    log("已向服务端注册桌面输入客户端。")


async def type_text(text: str) -> bool:
    try:
        keyboard.write(text, delay=0.01)
        log(f"输入成功: {text[:40]}")
        return True
    except Exception as error:
        log(f"输入失败: {error}")
        return False


async def press_key(key: str) -> bool:
    try:
        keyboard.press_and_release(key)
        log(f"按键成功: {key}")
        return True
    except Exception as error:
        log(f"按键失败: {error}")
        return False


async def smart_clear(char_count: str) -> bool:
    try:
        char_count_int = int(char_count)
        log(f"智能清空开始: {char_count_int} 个字符")

        keyboard.press_and_release("ctrl+a")
        await asyncio.sleep(0.05)
        keyboard.press_and_release("delete")
        await asyncio.sleep(0.1)

        delete_count = min(char_count_int, 5000)
        delete_duration = delete_count * DELETE_SPEED * 1.2
        log(f"补充退格删除: {delete_count} 个字符，预计 {delete_duration:.1f} 秒")

        for index in range(delete_count):
            keyboard.press_and_release("backspace")
            if (index + 1) % 100 == 0:
                log(f"已删除 {index + 1}/{delete_count} 个字符")
            await asyncio.sleep(DELETE_SPEED)

        log("清空完成")
        return True
    except Exception as error:
        log(f"清空失败: {error}")
        return False


async def receive_messages() -> None:
    log("正在连接服务器...")

    while True:
        try:
            async with websockets.connect(SERVER_URL) as websocket:
                await register_desktop(websocket)
                log("已连接到服务器，等待手机输入。")

                async for message in websocket:
                    try:
                        data = json.loads(message)
                        msg_type = data.get("type")
                        content = data.get("content", "")

                        if msg_type == "presence":
                            connected = data.get("connected", {})
                            log(
                                "连接状态更新: 手机={0} 电脑输入端={1}".format(
                                    connected.get("mobile", False),
                                    connected.get("desktop", False),
                                )
                            )
                            continue

                        if msg_type == "text":
                            await type_text(content)
                        elif msg_type == "backspace":
                            await press_key("backspace")
                        elif msg_type == "enter":
                            await press_key("enter")
                        elif msg_type == "tab":
                            await press_key("tab")
                        elif msg_type == "space":
                            await press_key("space")
                        elif msg_type == "clear":
                            await smart_clear(content)
                    except json.JSONDecodeError as error:
                        log(f"JSON解析错误: {error}")
        except (websockets.exceptions.ConnectionClosed, ConnectionError):
            log("连接断开，3秒后重连...")
            await asyncio.sleep(3)
        except Exception as error:
            log(f"客户端错误: {error}")
            await asyncio.sleep(3)


if __name__ == "__main__":
    log("=" * 60)
    log("语音输入同步 - 电脑端客户端")
    log(f"启动时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    try:
        asyncio.run(receive_messages())
    except KeyboardInterrupt:
        log("客户端已退出")
