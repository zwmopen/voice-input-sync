import argparse
import asyncio
import json
import sys
from collections import deque
from pathlib import Path

from aiohttp import ClientSession, WSMsgType, web


def resolve_root() -> Path:
    if getattr(sys, "frozen", False):
        exe_dir = Path(sys.executable).resolve().parent
        if exe_dir.name.lower().startswith("voiceinputsync"):
            return exe_dir.parent
        return exe_dir
    return Path(__file__).resolve().parent


ROOT = resolve_root()
RUNTIME_CONFIG_PATH = ROOT / "runtime-config.json"


def load_runtime_config() -> dict:
    if not RUNTIME_CONFIG_PATH.exists():
        return {}

    try:
        return json.loads(RUNTIME_CONFIG_PATH.read_text(encoding="utf-8-sig"))
    except Exception:
        return {}


def resolve_backend_ws_url() -> str:
    config = load_runtime_config()
    ws_port = int(config.get("wsPort", 8765) or 8765)
    return f"ws://127.0.0.1:{ws_port}"


def resolve_static_path(request_path: str) -> Path:
    clean_path = request_path.strip("/")
    if not clean_path:
        clean_path = "mobile.html"

    candidate = (ROOT / clean_path).resolve()
    if ROOT not in candidate.parents and candidate != ROOT:
        raise web.HTTPForbidden(text="forbidden")
    if not candidate.exists() or not candidate.is_file():
        raise web.HTTPNotFound(text="not found")
    return candidate


def json_response(payload: dict) -> web.Response:
    return web.Response(
        text=json.dumps(payload, ensure_ascii=False),
        content_type="application/json",
    )


class BridgeSession:
    def __init__(self, app: web.Application, token: str) -> None:
        self.app = app
        self.token = token
        self.backend_ws = None
        self.reader_task: asyncio.Task | None = None
        self.lock = asyncio.Lock()
        self.auth_event = asyncio.Event()
        self.connected = {"mobile": False, "desktop": False, "monitor": False}
        self.auth = {"ok": False, "role": "", "reason": ""}
        self.events: deque[dict] = deque(maxlen=160)
        self.last_event_id = 0

    def add_event(self, event: dict) -> None:
        self.last_event_id += 1
        record = dict(event)
        record["id"] = self.last_event_id
        self.events.append(record)

        if record.get("type") == "presence":
            self.connected = dict(record.get("connected", self.connected))
        elif record.get("type") == "auth":
            self.auth = {
                "ok": bool(record.get("ok", False)),
                "role": str(record.get("role", "")),
                "reason": str(record.get("reason", "")),
            }
            self.auth_event.set()

    def snapshot(self, since: int = 0) -> dict:
        return {
            "ok": True,
            "auth": dict(self.auth),
            "connected": dict(self.connected),
            "events": [event for event in self.events if int(event.get("id", 0)) > since],
            "lastEventId": self.last_event_id,
        }

    async def ensure_connected(self) -> None:
        async with self.lock:
            if self.backend_ws and not self.backend_ws.closed and self.reader_task and not self.reader_task.done():
                return

            await self._close_backend_locked()
            self.auth = {"ok": False, "role": "", "reason": ""}
            self.auth_event = asyncio.Event()

            session: ClientSession = self.app["http_client"]
            self.backend_ws = await session.ws_connect(resolve_backend_ws_url(), heartbeat=20)
            await self.backend_ws.send_json({"type": "register", "role": "mobile", "token": self.token})
            self.reader_task = asyncio.create_task(self._reader_loop())

        try:
            await asyncio.wait_for(self.auth_event.wait(), timeout=2.5)
        except asyncio.TimeoutError:
            pass

    async def _reader_loop(self) -> None:
        if self.backend_ws is None:
            return

        try:
            async for message in self.backend_ws:
                if message.type != WSMsgType.TEXT:
                    continue

                try:
                    payload = json.loads(message.data)
                except json.JSONDecodeError:
                    continue

                if payload.get("type") in {"auth", "presence", "ack"}:
                    self.add_event(payload)
        finally:
            self.connected["mobile"] = False
            self.backend_ws = None

    async def send(self, payload: dict) -> None:
        await self.ensure_connected()
        if not self.backend_ws or self.backend_ws.closed:
            raise RuntimeError("mobile bridge unavailable")
        await self.backend_ws.send_str(json.dumps(payload, ensure_ascii=False))

    async def close(self) -> None:
        async with self.lock:
            await self._close_backend_locked()

    async def _close_backend_locked(self) -> None:
        if self.reader_task and not self.reader_task.done():
            self.reader_task.cancel()
            try:
                await self.reader_task
            except asyncio.CancelledError:
                pass
        self.reader_task = None

        if self.backend_ws and not self.backend_ws.closed:
            await self.backend_ws.close()
        self.backend_ws = None


def get_bridge_session(app: web.Application, token: str) -> BridgeSession:
    bridges: dict[str, BridgeSession] = app["bridges"]
    if token not in bridges:
        bridges[token] = BridgeSession(app, token)
    return bridges[token]


def extract_token(request: web.Request, payload: dict | None = None) -> str:
    if payload and isinstance(payload.get("token"), str) and payload["token"].strip():
        return payload["token"].strip()

    query_token = request.query.get("token", "").strip()
    if query_token:
        return query_token

    raise web.HTTPBadRequest(text="missing token")


async def handle_static(request: web.Request) -> web.StreamResponse:
    candidate = resolve_static_path(request.match_info.get("path", ""))
    return web.FileResponse(candidate)


async def proxy_ws(request: web.Request) -> web.WebSocketResponse:
    browser_ws = web.WebSocketResponse(heartbeat=20)
    await browser_ws.prepare(request)

    session: ClientSession = request.app["http_client"]
    try:
        async with session.ws_connect(resolve_backend_ws_url(), heartbeat=20) as backend_ws:
            browser_task = asyncio.create_task(_pipe_browser_to_backend(browser_ws, backend_ws))
            backend_task = asyncio.create_task(_pipe_backend_to_browser(backend_ws, browser_ws))
            done, pending = await asyncio.wait(
                {browser_task, backend_task},
                return_when=asyncio.FIRST_COMPLETED,
            )
            for task in pending:
                task.cancel()
            for task in done:
                task.result()
    except Exception:
        await browser_ws.close()

    return browser_ws


async def _pipe_browser_to_backend(browser_ws: web.WebSocketResponse, backend_ws) -> None:
    async for message in browser_ws:
        if message.type == WSMsgType.TEXT:
            await backend_ws.send_str(message.data)
        elif message.type == WSMsgType.BINARY:
            await backend_ws.send_bytes(message.data)
        elif message.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.CLOSING):
            await backend_ws.close()
            break


async def _pipe_backend_to_browser(backend_ws, browser_ws: web.WebSocketResponse) -> None:
    async for message in backend_ws:
        if message.type == WSMsgType.TEXT:
            await browser_ws.send_str(message.data)
        elif message.type == WSMsgType.BINARY:
            await browser_ws.send_bytes(message.data)
        elif message.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.CLOSING):
            await browser_ws.close()
            break


async def handle_register(request: web.Request) -> web.Response:
    payload = await request.json()
    token = extract_token(request, payload)
    bridge = get_bridge_session(request.app, token)
    await bridge.ensure_connected()
    return json_response(bridge.snapshot())


async def handle_events(request: web.Request) -> web.Response:
    token = extract_token(request)
    since = int(request.query.get("since", "0") or 0)
    bridge = get_bridge_session(request.app, token)
    await bridge.ensure_connected()
    return json_response(bridge.snapshot(since))


async def handle_send(request: web.Request) -> web.Response:
    payload = await request.json()
    token = extract_token(request, payload)
    bridge = get_bridge_session(request.app, token)

    message = {key: value for key, value in payload.items() if key != "token"}
    await bridge.send(message)
    return json_response({"ok": True, "lastEventId": bridge.last_event_id})


async def on_startup(app: web.Application) -> None:
    app["http_client"] = ClientSession()
    app["bridges"] = {}


async def on_cleanup(app: web.Application) -> None:
    bridges: dict[str, BridgeSession] = app["bridges"]
    for bridge in bridges.values():
        await bridge.close()
    await app["http_client"].close()


def build_app() -> web.Application:
    app = web.Application()
    app.router.add_post("/api/register", handle_register)
    app.router.add_get("/api/events", handle_events)
    app.router.add_post("/api/send", handle_send)
    app.router.add_get("/ws", proxy_ws)
    app.router.add_get("/", handle_static)
    app.router.add_get("/{path:.*}", handle_static)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    return app


def parse_args():
    parser = argparse.ArgumentParser(description="VoiceInputSync static HTTP server")
    parser.add_argument("--port", type=int, default=8000)
    return parser.parse_args()


def main():
    args = parse_args()
    print(f"VoiceInputSync HTTP server listening on http://0.0.0.0:{args.port}")
    web.run_app(build_app(), host="0.0.0.0", port=args.port, handle_signals=False)


if __name__ == "__main__":
    main()
