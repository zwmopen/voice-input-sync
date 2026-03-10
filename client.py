"""
电脑端客户端
接收手机端文字并模拟键盘输入到当前窗口
支持智能清空（根据字数计算删除时长）
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

# 删除速度配置（每个字符需要的秒数）
DELETE_SPEED = 0.01  # 10ms一个字符，每秒可删除100个字符

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

async def smart_clear(char_count):
    """
    智能清空 - 根据字符数量计算删除时长

    策略：
    1. 先尝试 Ctrl+A全选 + Delete删除（适用于大多数文本编辑器）
    2. 再用退格键补充删除（适用于命令行等不支持全选的场景）
    3. 根据字符数量计算需要的删除时长
    """
    try:
        char_count = int(char_count)
        print(f"  → 智能清空 {char_count} 个字符")

        # 方法1：Ctrl+A全选 + Delete（快速）
        keyboard.press_and_release('ctrl+a')
        await asyncio.sleep(0.05)
        keyboard.press_and_release('delete')
        await asyncio.sleep(0.1)

        # 方法2：补充退格键删除（兼容命令行等场景）
        # 计算需要的删除时长，每个字符约10ms
        delete_count = min(char_count, 5000)  # 最多删除5000个字符

        # 计算实际需要的删除时长（加20%余量）
        delete_duration = delete_count * DELETE_SPEED * 1.2

        print(f"  → 补充退格删除：{delete_count}个字符，预计{delete_duration:.1f}秒")

        # 执行快速退格删除
        for i in range(delete_count):
            keyboard.press_and_release('backspace')
            # 每100个字符输出一次进度
            if (i + 1) % 100 == 0:
                print(f"  → 已删除 {i+1}/{delete_count} 个字符")
            await asyncio.sleep(DELETE_SPEED)

        print(f"  ✓ 清空完成")
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
                print("智能清空：根据字数计算删除时长")
                print(f"删除速度：每秒约 {int(1/DELETE_SPEED)} 个字符")
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
                            await smart_clear(content)

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
