"""
实时语音输入同步服务
负责中转手机输入消息，并向手机页、桌面扫码页广播连接状态。
"""

from __future__ import annotations

import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path

import websockets


def resolve_log_file() -> Path:
    if getattr(sys, "frozen", False):
        base_dir = Path(sys.executable).resolve().parent.parent / "logs"
    else:
        base_dir = Path(__file__).resolve().parent / "logs"
    base_dir.mkdir(parents=True, exist_ok=True)
    return base_dir / "server-runtime.log"


LOG_FILE = resolve_log_file()
VALID_ROLES = {"mobile", "desktop", "monitor"}
INPUT_MESSAGE_TYPES = {"text", "backspace", "enter", "tab", "space", "clear"}
connected_clients: set[websockets.WebSocketServerProtocol] = set()
client_roles: dict[websockets.WebSocketServerProtocol, str] = {}


def log(message: str) -> None:
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {message}"
    print(line, flush=True)
    with LOG_FILE.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def build_presence_payload() -> str:
    counts = {role: 0 for role in VALID_ROLES}
    counts["unknown"] = 0

    for role in client_roles.values():
        counts[role if role in counts else "unknown"] += 1

    payload = {
        "type": "presence",
        "counts": counts,
        "connected": {
            "mobile": counts["mobile"] > 0,
            "desktop": counts["desktop"] > 0,
            "monitor": counts["monitor"] > 0,
        },
    }
    return json.dumps(payload, ensure_ascii=False)


async def send_to_targets(message: str, targets: list[websockets.WebSocketServerProtocol]) -> None:
    stale_clients = []
    for client in targets:
        try:
            await client.send(message)
        except websockets.exceptions.ConnectionClosed:
            stale_clients.append(client)

    for client in stale_clients:
        connected_clients.discard(client)
        client_roles.pop(client, None)


async def broadcast_presence() -> None:
    if not connected_clients:
        return
    await send_to_targets(build_presence_payload(), list(connected_clients))


async def relay_input_to_desktops(message: str, sender: websockets.WebSocketServerProtocol) -> None:
    desktop_clients = [
        client
        for client in connected_clients
        if client != sender and client_roles.get(client) == "desktop"
    ]
    await send_to_targets(message, desktop_clients)


async def handler(websocket, path):
    connected_clients.add(websocket)
    client_roles[websocket] = "unknown"
    client_addr = websocket.remote_address
    log(f"客户端连接: {client_addr}")
    await broadcast_presence()

    try:
        async for message in websocket:
            data = json.loads(message)
            msg_type = data.get("type")
            content = data.get("content", "")

            if msg_type == "register":
                role = data.get("role", "unknown")
                if role not in VALID_ROLES:
                    role = "unknown"
                client_roles[websocket] = role
                log(f"角色注册: {client_addr} -> {role}")
                await broadcast_presence()
                continue

            if msg_type in INPUT_MESSAGE_TYPES:
                await relay_input_to_desktops(message, websocket)

            timestamp = datetime.now().strftime("%H:%M:%S")
            if msg_type == "text":
                preview = content[:30] + "..." if len(content) > 30 else content
                log(f"[{timestamp}] 文字: {preview}")
            elif msg_type == "backspace":
                log(f"[{timestamp}] 按键: 退格")
            elif msg_type == "enter":
                log(f"[{timestamp}] 按键: 回车")
            elif msg_type == "tab":
                log(f"[{timestamp}] 按键: Tab")
            elif msg_type == "space":
                log(f"[{timestamp}] 按键: 空格")
            elif msg_type == "clear":
                log(f"[{timestamp}] 清空: {content} 个字符")
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        connected_clients.discard(websocket)
        client_roles.pop(websocket, None)
        log(f"客户端断开: {client_addr}")
        await broadcast_presence()


async def main():
    log("=" * 60)
    log("语音输入同步服务端")
    log(f"启动时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    log("服务地址: ws://0.0.0.0:8765")
    log("等待连接...")

    async with websockets.serve(handler, "0.0.0.0", 8765):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
