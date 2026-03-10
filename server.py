"""
实时语音输入同步系统
手机端语音输入 → 网页显示 → 实时同步到电脑 → 自动打字到当前窗口
"""

import asyncio
import websockets
import json
from datetime import datetime

# 存储连接的客户端
connected_clients = set()

async def handler(websocket, path):
    """处理客户端连接"""
    connected_clients.add(websocket)
    client_addr = websocket.remote_address
    print(f"[{datetime.now().strftime('%H:%M:%S')}] 客户端连接: {client_addr}")

    try:
        async for message in websocket:
            data = json.loads(message)
            msg_type = data.get('type')
            content = data.get('content', '')

            # 广播给所有其他客户端
            for client in connected_clients:
                if client != websocket:
                    await client.send(message)

            # 打印日志
            timestamp = datetime.now().strftime('%H:%M:%S')
            if msg_type == 'text':
                preview = content[:30] + '...' if len(content) > 30 else content
                print(f"[{timestamp}] 文字: {preview}")
            elif msg_type == 'backspace':
                print(f"[{timestamp}] 按键: 退格")
            elif msg_type == 'enter':
                print(f"[{timestamp}] 按键: 回车")
            elif msg_type == 'tab':
                print(f"[{timestamp}] 按键: Tab")
            elif msg_type == 'space':
                print(f"[{timestamp}] 按键: 空格")

    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        connected_clients.remove(websocket)
        print(f"[{datetime.now().strftime('%H:%M:%S')}] 客户端断开: {client_addr}")

async def main():
    print("=" * 60)
    print("实时语音输入同步服务器")
    print("=" * 60)
    print(f"启动时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"服务地址: ws://0.0.0.0:8765")
    print("=" * 60)
    print("\n等待连接...\n")

    async with websockets.serve(handler, "0.0.0.0", 8765):
        await asyncio.Future()  # 永久运行

if __name__ == "__main__":
    asyncio.run(main())
