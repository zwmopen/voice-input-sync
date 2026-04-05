from __future__ import annotations

import argparse
import asyncio
import json
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import websockets
from websockets.exceptions import ConnectionClosed


VALID_ROLES = {"mobile", "desktop", "monitor"}
INPUT_MESSAGE_TYPES = {"text", "backspace", "enter", "tab", "space", "clear", "replace_all"}
SESSION_TOKEN = ""


def resolve_log_file() -> Path:
    if getattr(sys, "frozen", False):
        base_dir = Path(sys.executable).resolve().parent.parent / "logs"
    else:
        base_dir = Path(__file__).resolve().parent / "logs"
    base_dir.mkdir(parents=True, exist_ok=True)
    return base_dir / "server-runtime.log"


LOG_FILE = resolve_log_file()


@dataclass
class ClientMeta:
    role: str = "unknown"
    authenticated: bool = False


connected_clients: set[websockets.WebSocketServerProtocol] = set()
client_meta: dict[websockets.WebSocketServerProtocol, ClientMeta] = {}


def log(message: str) -> None:
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {message}"
    print(line, flush=True)
    with LOG_FILE.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def build_presence_payload() -> str:
    counts = {role: 0 for role in VALID_ROLES}
    counts["unknown"] = 0

    for meta in client_meta.values():
        if meta.authenticated and meta.role in VALID_ROLES:
            counts[meta.role] += 1
        else:
            counts["unknown"] += 1

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


async def send_to_targets(
    payload: str,
    targets: list[websockets.WebSocketServerProtocol],
) -> None:
    stale_clients = []

    for client in targets:
        try:
            await client.send(payload)
        except ConnectionClosed:
            stale_clients.append(client)

    for client in stale_clients:
        connected_clients.discard(client)
        client_meta.pop(client, None)


async def broadcast_presence() -> None:
    if not connected_clients:
        return
    await send_to_targets(build_presence_payload(), list(connected_clients))


async def broadcast_ack(data: dict[str, object]) -> None:
    payload = json.dumps(data, ensure_ascii=False)
    targets = [
        client
        for client, meta in client_meta.items()
        if meta.authenticated and meta.role in {"mobile", "monitor"}
    ]
    if targets:
        await send_to_targets(payload, targets)


async def relay_input_to_desktops(
    payload: str,
    sender: websockets.WebSocketServerProtocol,
) -> None:
    targets = [
        client
        for client, meta in client_meta.items()
        if client != sender and meta.authenticated and meta.role == "desktop"
    ]
    if targets:
        await send_to_targets(payload, targets)


async def reject_client(
    websocket: websockets.WebSocketServerProtocol,
    reason: str,
    close_code: int,
) -> None:
    payload = json.dumps(
        {"type": "auth", "ok": False, "reason": reason},
        ensure_ascii=False,
    )
    try:
        await websocket.send(payload)
    except ConnectionClosed:
        return
    await websocket.close(code=close_code, reason=reason)


async def handle_register(
    websocket: websockets.WebSocketServerProtocol,
    data: dict[str, object],
) -> bool:
    token = str(data.get("token", ""))
    role = str(data.get("role", "unknown"))

    if SESSION_TOKEN and token != SESSION_TOKEN:
        log(f"register rejected: invalid token from {websocket.remote_address}")
        await reject_client(websocket, "invalid_token", 4001)
        return False

    if role not in VALID_ROLES:
        role = "unknown"

    client_meta[websocket] = ClientMeta(role=role, authenticated=True)
    await websocket.send(
        json.dumps(
            {"type": "auth", "ok": True, "role": role},
            ensure_ascii=False,
        )
    )
    log(f"register ok: {websocket.remote_address} -> {role}")
    await broadcast_presence()
    return True


def preview_text(text: str, limit: int = 40) -> str:
    return text if len(text) <= limit else text[:limit] + "..."


def log_input(data: dict[str, object]) -> None:
    msg_type = str(data.get("type", "unknown"))
    message_id = str(data.get("messageId", ""))
    content = str(data.get("content", ""))

    if msg_type == "text":
        log(f"input text {message_id}: {preview_text(content)!r}")
    elif msg_type == "replace_all":
        log(f"input replace_all {message_id}: len={len(content)}")
    elif msg_type == "clear":
        log(f"input clear {message_id}: len={content}")
    else:
        log(f"input {msg_type} {message_id}")


async def handle_ack(
    websocket: websockets.WebSocketServerProtocol,
    data: dict[str, object],
) -> None:
    meta = client_meta.get(websocket, ClientMeta())
    if not meta.authenticated or meta.role != "desktop":
        await reject_client(websocket, "desktop_ack_required", 4003)
        return

    payload = {
        "type": "ack",
        "messageId": str(data.get("messageId", "")),
        "action": str(data.get("action", "")),
        "ok": bool(data.get("ok", False)),
        "reason": str(data.get("reason", "")),
        "detail": str(data.get("detail", "")),
        "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }
    await broadcast_ack(payload)
    log(
        "ack {0} {1}: ok={2} reason={3}".format(
            payload["action"],
            payload["messageId"],
            payload["ok"],
            payload["reason"] or "none",
        )
    )


async def handler(websocket, path) -> None:
    del path
    connected_clients.add(websocket)
    client_meta[websocket] = ClientMeta()
    log(f"client connected: {websocket.remote_address}")
    await broadcast_presence()

    try:
        async for raw_message in websocket:
            try:
                data = json.loads(raw_message)
            except json.JSONDecodeError:
                log(f"json decode failed from {websocket.remote_address}")
                continue

            msg_type = str(data.get("type", ""))
            if msg_type == "register":
                ok = await handle_register(websocket, data)
                if not ok:
                    return
                continue

            meta = client_meta.get(websocket, ClientMeta())
            if not meta.authenticated:
                await reject_client(websocket, "register_required", 4002)
                return

            if msg_type in INPUT_MESSAGE_TYPES:
                if meta.role != "mobile":
                    await reject_client(websocket, "mobile_input_required", 4004)
                    return
                await relay_input_to_desktops(raw_message, websocket)
                log_input(data)
                continue

            if msg_type == "ack":
                await handle_ack(websocket, data)
                continue

            log(f"ignored message from {meta.role}: {msg_type}")
    except ConnectionClosed:
        pass
    finally:
        connected_clients.discard(websocket)
        client_meta.pop(websocket, None)
        log(f"client disconnected: {websocket.remote_address}")
        await broadcast_presence()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="VoiceInputSync websocket relay server")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--session-token", default="")
    return parser.parse_args()


async def main(port: int, session_token: str) -> None:
    global SESSION_TOKEN
    SESSION_TOKEN = session_token.strip()
    servers = []

    log("=" * 60)
    log("VoiceInputSync relay server ready")
    log(f"started at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    log(f"listening on: ws://0.0.0.0:{port}")
    log(f"session token required: {bool(SESSION_TOKEN)}")

    try:
        servers.append(await websockets.serve(handler, "0.0.0.0", port))
        try:
            servers.append(await websockets.serve(handler, "::", port))
            log(f"listening on: ws://[::]:{port}")
        except OSError as error:
            log(f"ipv6 listener skipped: {error}")
        await asyncio.Future()
    finally:
        for server in servers:
            server.close()
        for server in servers:
            await server.wait_closed()


if __name__ == "__main__":
    args = parse_args()
    asyncio.run(main(args.port, args.session_token))
