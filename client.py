from __future__ import annotations

import argparse
import asyncio
import json
import sys
from datetime import datetime
from pathlib import Path

import keyboard
import websockets
from websockets.exceptions import ConnectionClosed


SERVER_URL = "ws://localhost:8765"
DELETE_SPEED = 0.01
FALLBACK_DELETE_LIMIT = 64


def resolve_log_file() -> Path:
    if getattr(sys, "frozen", False):
        base_dir = Path(sys.executable).resolve().parent.parent / "logs"
    else:
        base_dir = Path(__file__).resolve().parent / "logs"
    base_dir.mkdir(parents=True, exist_ok=True)
    return base_dir / "client-runtime.log"


LOG_FILE = resolve_log_file()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="VoiceInputSync desktop typing client")
    parser.add_argument("--ws-url", default=SERVER_URL)
    parser.add_argument("--session-token", default="")
    return parser.parse_args()


def log(message: str) -> None:
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{stamp}] {message}"
    print(line, flush=True)
    with LOG_FILE.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def classify_error(error: Exception) -> tuple[str, str]:
    message = str(error).strip() or error.__class__.__name__
    lower_message = message.lower()

    if "access is denied" in lower_message or "denied" in lower_message:
        return ("permission_denied", "电脑输入权限不足，请回到电脑端改用管理员启动。")

    return ("input_failed", "电脑输入端执行失败，请回到电脑端重试。")


async def send_ack(
    websocket,
    message_id: str,
    action: str,
    ok: bool,
    reason: str,
    detail: str,
) -> None:
    payload = {
        "type": "ack",
        "messageId": message_id,
        "action": action,
        "ok": ok,
        "reason": reason,
        "detail": detail,
    }
    await websocket.send(json.dumps(payload, ensure_ascii=False))


async def register_desktop(websocket, session_token: str) -> None:
    payload = {
        "type": "register",
        "role": "desktop",
        "token": session_token,
    }
    await websocket.send(json.dumps(payload, ensure_ascii=False))
    log("desktop client register requested")


async def type_text(text: str) -> tuple[bool, str, str]:
    try:
        keyboard.write(text, delay=0.01)
        log(f"text typed: {text[:60]!r}")
        return (True, "ok", "已输入到电脑。")
    except Exception as error:  # noqa: BLE001
        reason, detail = classify_error(error)
        log(f"text typing failed: {error}")
        return (False, reason, detail)


async def press_key(key: str) -> tuple[bool, str, str]:
    try:
        keyboard.press_and_release(key)
        log(f"key pressed: {key}")
        return (True, "ok", "快捷键已发送到电脑。")
    except Exception as error:  # noqa: BLE001
        reason, detail = classify_error(error)
        log(f"key press failed {key}: {error}")
        return (False, reason, detail)


async def clear_target(char_count: int) -> tuple[bool, str, str]:
    try:
        keyboard.press_and_release("ctrl+a")
        await asyncio.sleep(0.05)
        keyboard.press_and_release("delete")
        await asyncio.sleep(0.08)

        fallback_count = min(max(char_count, 0), FALLBACK_DELETE_LIMIT)
        for _ in range(fallback_count):
            keyboard.press_and_release("backspace")
            await asyncio.sleep(DELETE_SPEED)

        log(f"target cleared: fallback_backspace={fallback_count}")
        return (True, "ok", "电脑内容已清空。")
    except Exception as error:  # noqa: BLE001
        reason, detail = classify_error(error)
        log(f"clear target failed: {error}")
        return (False, reason, detail)


async def replace_all_text(text: str) -> tuple[bool, str, str]:
    cleared, clear_reason, clear_detail = await clear_target(len(text))
    if not cleared:
        return (False, clear_reason, clear_detail)

    if not text:
        return (True, "ok", "电脑内容已同步为空。")

    typed, type_reason, type_detail = await type_text(text)
    if not typed:
        return (False, type_reason, type_detail)

    return (True, "ok", "整段内容已经同步到电脑。")


async def handle_input_message(data: dict[str, object]) -> tuple[bool, str, str]:
    msg_type = str(data.get("type", ""))
    content = str(data.get("content", ""))

    if msg_type == "text":
        return await type_text(content)
    if msg_type == "backspace":
        return await press_key("backspace")
    if msg_type == "enter":
        return await press_key("enter")
    if msg_type == "tab":
        return await press_key("tab")
    if msg_type == "space":
        return await press_key("space")
    if msg_type == "clear":
        try:
            clear_count = int(content)
        except ValueError:
            clear_count = 0
        return await clear_target(clear_count)
    if msg_type == "replace_all":
        return await replace_all_text(content)

    return (False, "unsupported_action", "电脑输入端暂不支持这个操作。")


async def receive_messages(server_url: str, session_token: str) -> None:
    log(f"connecting to {server_url}")

    while True:
        try:
            async with websockets.connect(server_url) as websocket:
                await register_desktop(websocket, session_token)

                async for raw_message in websocket:
                    data = json.loads(raw_message)
                    msg_type = str(data.get("type", ""))

                    if msg_type == "auth":
                        if data.get("ok"):
                            log("desktop client authenticated")
                        else:
                            log(f"desktop client rejected: {data.get('reason', 'unknown')}")
                        continue

                    if msg_type == "presence":
                        connected = data.get("connected", {})
                        log(
                            "presence: mobile={0} desktop={1}".format(
                                connected.get("mobile", False),
                                connected.get("desktop", False),
                            )
                        )
                        continue

                    message_id = str(data.get("messageId", ""))
                    if not message_id:
                        log(f"ignored message without messageId: {msg_type}")
                        continue

                    ok, reason, detail = await handle_input_message(data)
                    await send_ack(websocket, message_id, msg_type, ok, reason, detail)
        except (ConnectionClosed, ConnectionError):
            log("connection closed, retrying in 3s")
            await asyncio.sleep(3)
        except Exception as error:  # noqa: BLE001
            log(f"desktop client error: {error}")
            await asyncio.sleep(3)


if __name__ == "__main__":
    args = parse_args()
    log("=" * 60)
    log("VoiceInputSync desktop client ready")
    log(f"started at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

    try:
        asyncio.run(receive_messages(args.ws_url, args.session_token))
    except KeyboardInterrupt:
        log("desktop client exited")
