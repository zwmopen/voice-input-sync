"""
电脑端客户端
接收手机端文字并模拟键盘输入到当前窗口
"""

import asyncio
import websockets
import json
import keyboard
import sys
from datetime import datetime

# 解决Windows编码问题
import os
os.environ['PYTHONIOENCODING'] = 'utf-8'

SERVER_URL = "ws://localhost:8765"

async def type_text(text):
    """模拟键盘输入"""
    try:
        keyboard.write(text, delay=0.01)
        return True
    except Exception as e:
        print(f"输入失败: {e}")
        return False

async def press_key(key):
    """模拟按键"""
    try:
        keyboard.press_and_release(key)
        return True
    except Exception as e:
        print(f"按键失败: {e}")
        return False

async def clear_text(count):
    """清空文字（发送多个退格键）"""
    try:
        for _ in range(int(count)):
            keyboard.press_and_release('backspace')
            await asyncio.sleep(0.01)  # 小延迟避免太快
        return True
    except Exception as e:
        print(f"清空失败: {e}")
        return False

async def receive_messages():
    """接收服务器消息"""
    print("正在连接服务器...")

    while True:
        try:
            async with websockets.connect(SERVER_URL) as websocket:
                print("=" * 60)
                print("已连接到服务器")
                print("=" * 60)
                print()
                print("手机端界面保持打开状态即可")
                print("在电脑上打开任意窗口，光标放在输入位置")
                print("手机端输入/操作会自动同步到电脑")
                print()
                print("等待手机输入...")
                print("-" * 60)

                async for message in websocket:
                    try:
                        data = json.loads(message)
                        msg_type = data.get('type')
                        content = data.get('content', '')

                        timestamp = datetime.now().strftime('%H:%M:%S')

                        if msg_type == 'text':
                            print(f"[{timestamp}] 文字: {content}")
                            await type_text(content)
                        elif msg_type == 'backspace':
                            print(f"[{timestamp}] 退格")
                            await press_key('backspace')
                        elif msg_type == 'enter':
                            print(f"[{timestamp}] 回车")
                            await press_key('enter')
                        elif msg_type == 'tab':
                            print(f"[{timestamp}] Tab")
                            await press_key('tab')
                        elif msg_type == 'space':
                            print(f"[{timestamp}] 空格")
                            await press_key('space')
                        elif msg_type == 'clear':
                            print(f"[{timestamp}] 清空: {content}个字符")
                            await clear_text(content)

                    except json.JSONDecodeError as e:
                        print(f"JSON解析错误: {e}")

        except (websockets.exceptions.ConnectionClosed, ConnectionError) as e:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] 连接断开，3秒后重连...")
            await asyncio.sleep(3)
        except Exception as e:
            print(f"错误: {e}")
            await asyncio.sleep(3)

if __name__ == "__main__":
    print("=" * 60)
    print("语音输入同步 - 电脑端客户端")
    print("=" * 60)
    print(f"启动时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print()

    try:
        asyncio.run(receive_messages())
    except KeyboardInterrupt:
        print("\n\n已退出")
