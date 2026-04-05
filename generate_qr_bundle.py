from __future__ import annotations

import argparse
import base64
import html
import io
import json
from datetime import datetime
from pathlib import Path

import qrcode
from qrcode.image.svg import SvgPathImage


def build_svg_text(url: str) -> str:
    qr = qrcode.QRCode(
        version=None,
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=10,
        border=2,
    )
    qr.add_data(url)
    qr.make(fit=True)

    image = qr.make_image(image_factory=SvgPathImage)
    buffer = io.BytesIO()
    image.save(buffer)
    return buffer.getvalue().decode("utf-8")


def build_svg(url: str, output_path: Path) -> None:
    output_path.write_text(build_svg_text(url), encoding="utf-8")


def svg_to_data_uri(svg_text: str) -> str:
    encoded = base64.b64encode(svg_text.encode("utf-8")).decode("ascii")
    return f"data:image/svg+xml;base64,{encoded}"


def build_access_card(
    *,
    card_id: str,
    title: str,
    subtitle: str,
    url: str,
    active: bool,
    featured: bool,
    badge_text: str,
    tone: str,
    qr_src: str,
) -> str:
    tone_class = "accent" if tone == "accent" else "green"
    copy_button = (
        f'<button class="copy-pill" type="button" data-copy="{html.escape(card_id)}">复制地址</button>'
        if active
        else '<button class="copy-pill disabled" type="button" disabled>暂不可用</button>'
    )
    url_markup = html.escape(url) if active else "当前这次启动还没拿到互联网地址"
    qr_markup = (
        f'<img src="{html.escape(qr_src)}" alt="{html.escape(title)}二维码">'
        if active
        else '<div class="qr-placeholder">正在等待在线地址</div>'
    )
    card_class = "access-card featured" if featured else "access-card"

    return f"""
            <article class="{card_class}">
                <div class="card-qr">
                    <div class="card-badge {tone_class}">{html.escape(badge_text)}</div>
                    {qr_markup}
                </div>
                <div class="card-main">
                    <div class="card-head">
                        <div>
                            <h2>{html.escape(title)}</h2>
                            <p class="card-subtitle">{html.escape(subtitle)}</p>
                        </div>
                        {copy_button}
                    </div>
                    <div class="address-box {'disabled' if not active else ''}" data-copy="{html.escape(card_id)}" tabindex="{0 if active else -1}" role="button" aria-label="复制{html.escape(title)}">
                        <div class="address-label">手机打开地址</div>
                        <div class="address-value" id="{html.escape(card_id)}Value">{url_markup}</div>
                    </div>
                </div>
            </article>
"""


def build_html(
    recommended_url: str,
    svg_filename: str,
    ws_port: int,
    session_token: str,
    *,
    status_ws_url: str = "",
    online_url: str = "",
    lan_url: str = "",
) -> str:
    host = recommended_url.split("://", 1)[1].split("/", 1)[0].split(":", 1)[0]
    ws_url = status_ws_url or f"ws://{host}:{ws_port}"
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    main_qr_src = html.escape(svg_filename)

    if recommended_url == online_url and online_url:
        online_qr_src = main_qr_src
    elif online_url:
        online_qr_src = svg_to_data_uri(build_svg_text(online_url))
    else:
        online_qr_src = ""

    if recommended_url == lan_url and lan_url:
        lan_qr_src = main_qr_src
    elif lan_url:
        lan_qr_src = svg_to_data_uri(build_svg_text(lan_url))
    else:
        lan_qr_src = ""

    online_featured = bool(online_url)
    lan_featured = not online_featured and bool(lan_url)

    online_card = build_access_card(
        card_id="online",
        title="互联网地址",
        subtitle="不在同一局域网时优先用这个",
        url=online_url,
        active=bool(online_url),
        featured=online_featured,
        badge_text="推荐地址" if online_featured else "互联网地址",
        tone="accent",
        qr_src=online_qr_src,
    )
    lan_card = build_access_card(
        card_id="lan",
        title="局域网直连",
        subtitle="自己手机热点 / 家里网络更适合",
        url=lan_url,
        active=bool(lan_url),
        featured=lan_featured,
        badge_text="当前可用" if lan_featured else "局域网直连",
        tone="green",
        qr_src=lan_qr_src,
    )

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>语音输入同步 - 手机扫码连接</title>
    <style>
        :root {{
            --paper: #e7ecf2;
            --card: rgba(237, 242, 247, 0.96);
            --text: #28384b;
            --muted: #66758a;
            --accent: #cf7e29;
            --accent-soft: rgba(207, 126, 41, 0.12);
            --green: #258657;
            --green-soft: rgba(37, 134, 87, 0.12);
            --red: #c44a45;
            --shadow-up: 18px 18px 34px rgba(173, 183, 196, 0.8), -18px -18px 34px rgba(255, 255, 255, 0.96);
            --shadow-inset: inset 8px 8px 14px rgba(176, 185, 197, 0.72), inset -8px -8px 14px rgba(255, 255, 255, 0.9);
        }}

        * {{
            box-sizing: border-box;
        }}

        body {{
            margin: 0;
            min-height: 100vh;
            font-family: "Microsoft YaHei UI", "PingFang SC", "Noto Sans SC", sans-serif;
            color: var(--text);
            background:
                radial-gradient(circle at top left, rgba(207, 126, 41, 0.12), transparent 24%),
                radial-gradient(circle at top right, rgba(37, 134, 87, 0.10), transparent 20%),
                linear-gradient(180deg, #edf2f7 0%, #dde4eb 100%);
            padding: 24px;
        }}

        .shell {{
            width: min(1180px, 100%);
            margin: 0 auto;
            display: grid;
            gap: 24px;
        }}

        .hero,
        .status-shell,
        .access-shell {{
            background: var(--card);
            border-radius: 30px;
            box-shadow: var(--shadow-up);
            padding: 28px;
        }}

        .eyebrow {{
            display: inline-flex;
            align-items: center;
            gap: 8px;
            padding: 8px 14px;
            border-radius: 999px;
            background: var(--accent-soft);
            color: var(--accent);
            font-size: 13px;
            font-weight: 700;
        }}

        h1 {{
            margin: 18px 0 10px;
            font-size: clamp(32px, 5vw, 48px);
            line-height: 1.08;
        }}

        .hero p {{
            margin: 0;
            color: var(--muted);
            line-height: 1.8;
            font-size: 16px;
            max-width: 860px;
        }}

        .status-shell {{
            display: grid;
            gap: 14px;
        }}

        .status-label {{
            font-size: 13px;
            font-weight: 700;
            color: var(--muted);
        }}

        .status-button {{
            width: 100%;
            border: none;
            border-radius: 999px;
            padding: 16px 18px;
            font-size: 18px;
            font-weight: 800;
            color: var(--accent);
            background: var(--paper);
            box-shadow: 8px 8px 16px rgba(176, 185, 197, 0.8), -8px -8px 16px rgba(255, 255, 255, 0.95);
        }}

        .status-button.connected {{
            color: #fff;
            background: linear-gradient(145deg, #6dc99a, #3da86f);
            box-shadow: 8px 8px 18px rgba(61, 168, 111, 0.35), -8px -8px 16px rgba(255, 255, 255, 0.9);
        }}

        .status-note {{
            color: var(--muted);
            line-height: 1.75;
            font-size: 14px;
        }}

        .status-note.success {{
            color: var(--green);
        }}

        .status-note.error {{
            color: var(--red);
        }}

        .access-shell {{
            display: grid;
            gap: 16px;
        }}

        .access-card {{
            display: grid;
            grid-template-columns: 220px minmax(0, 1fr);
            gap: 18px;
            padding: 18px;
            border-radius: 24px;
            background: var(--paper);
            box-shadow: var(--shadow-inset);
        }}

        .access-card.featured {{
            outline: 1px solid rgba(207, 126, 41, 0.15);
        }}

        .card-qr {{
            display: grid;
            gap: 12px;
            align-content: start;
        }}

        .card-badge {{
            display: inline-flex;
            align-items: center;
            justify-content: center;
            padding: 8px 14px;
            border-radius: 999px;
            font-size: 13px;
            font-weight: 800;
            justify-self: start;
        }}

        .card-badge.accent {{
            background: var(--accent-soft);
            color: var(--accent);
        }}

        .card-badge.green {{
            background: var(--green-soft);
            color: var(--green);
        }}

        .card-qr img,
        .qr-placeholder {{
            width: 100%;
            min-height: 190px;
            display: grid;
            place-items: center;
            padding: 16px;
            border-radius: 22px;
            background: #fff;
            box-shadow: 10px 10px 22px rgba(170, 179, 190, 0.72), -10px -10px 22px rgba(255, 255, 255, 0.92);
        }}

        .card-qr img {{
            object-fit: contain;
        }}

        .qr-placeholder {{
            color: var(--muted);
            text-align: center;
            line-height: 1.7;
            font-size: 14px;
            background: linear-gradient(180deg, rgba(255, 255, 255, 0.95), rgba(244, 247, 251, 0.94));
        }}

        .card-main {{
            display: grid;
            gap: 14px;
            align-content: start;
        }}

        .card-head {{
            display: flex;
            align-items: flex-start;
            justify-content: space-between;
            gap: 12px;
        }}

        .card-head h2 {{
            margin: 0;
            font-size: 24px;
            line-height: 1.25;
        }}

        .card-subtitle {{
            margin: 8px 0 0;
            color: var(--muted);
            font-size: 14px;
            line-height: 1.7;
        }}

        .copy-pill {{
            border: none;
            border-radius: 999px;
            padding: 10px 16px;
            background: var(--paper);
            color: var(--accent);
            font-size: 13px;
            font-weight: 700;
            cursor: pointer;
            box-shadow: 6px 6px 12px rgba(176, 185, 197, 0.8), -6px -6px 12px rgba(255, 255, 255, 0.95);
            white-space: nowrap;
        }}

        .copy-pill.disabled {{
            color: #8794a3;
            cursor: default;
        }}

        .address-box {{
            padding: 16px 18px;
            border-radius: 20px;
            background: rgba(255, 255, 255, 0.72);
            box-shadow: 8px 8px 16px rgba(176, 185, 197, 0.58), -8px -8px 16px rgba(255, 255, 255, 0.9);
            cursor: pointer;
            outline: none;
        }}

        .address-box.disabled {{
            cursor: default;
            opacity: 0.8;
        }}

        .address-label {{
            font-size: 13px;
            font-weight: 700;
            color: #35567f;
            margin-bottom: 10px;
        }}

        .address-value {{
            word-break: break-all;
            font-size: 16px;
            line-height: 1.7;
            color: #18314f;
            font-weight: 700;
        }}

        .meta {{
            font-size: 13px;
            color: #756b60;
        }}

        .toast {{
            position: fixed;
            left: 50%;
            bottom: 28px;
            transform: translateX(-50%) translateY(24px);
            background: var(--card);
            color: var(--green);
            padding: 14px 22px;
            border-radius: 999px;
            box-shadow: var(--shadow-up);
            font-size: 14px;
            font-weight: 700;
            opacity: 0;
            pointer-events: none;
            transition: opacity 0.2s ease, transform 0.2s ease;
        }}

        .toast.show {{
            opacity: 1;
            transform: translateX(-50%) translateY(0);
        }}

        @media (max-width: 860px) {{
            .access-card {{
                grid-template-columns: 1fr;
            }}
        }}

        @media (max-width: 640px) {{
            body {{
                padding: 16px;
            }}

            .hero,
            .status-shell,
            .access-shell {{
                padding: 22px;
                border-radius: 24px;
            }}

            .card-head {{
                flex-direction: column;
                align-items: stretch;
            }}

            .copy-pill {{
                width: 100%;
            }}
        }}
    </style>
</head>
<body>
    <main class="shell">
        <section class="hero">
            <div class="eyebrow">语音输入同步 · 手机扫码连接</div>
            <h1>两个入口，按你的网络来。</h1>
            <p>互联网地址适合不在同一局域网时直接开。局域网直连更适合你自己手机热点给电脑，或者家里同一个热点。每一张卡右边就是对应地址，左边就是对应二维码。</p>
        </section>

        <section class="status-shell">
            <div class="status-label">连接状态</div>
            <button class="status-button" type="button" id="connectionStatus">等待连接</button>
            <div class="status-note" id="statusNote">扫码以后，电脑这里会自动显示已连接。输入成功或失败，也会在这里给你反馈。</div>
            <div class="meta">生成时间：{generated_at}</div>
        </section>

        <section class="access-shell">
{online_card}
{lan_card}
        </section>
    </main>

    <div class="toast" id="toast">地址已复制。</div>

    <script>
        const urls = {{
            online: {json.dumps(online_url, ensure_ascii=False)},
            lan: {json.dumps(lan_url, ensure_ascii=False)}
        }};
        const statusWsUrl = {json.dumps(ws_url, ensure_ascii=False)};
        const sessionToken = {json.dumps(session_token, ensure_ascii=False)};
        const toast = document.getElementById("toast");
        const connectionStatus = document.getElementById("connectionStatus");
        const statusNote = document.getElementById("statusNote");
        let toastTimer = null;
        let monitorWs = null;

        function showToast(message) {{
            toast.textContent = message;
            toast.classList.add("show");
            window.clearTimeout(toastTimer);
            toastTimer = window.setTimeout(() => {{
                toast.classList.remove("show");
            }}, 1800);
        }}

        function fallbackCopy(text) {{
            const textarea = document.createElement("textarea");
            textarea.value = text;
            textarea.setAttribute("readonly", "");
            textarea.style.position = "fixed";
            textarea.style.opacity = "0";
            document.body.appendChild(textarea);
            textarea.select();
            textarea.setSelectionRange(0, textarea.value.length);
            const copied = document.execCommand("copy");
            document.body.removeChild(textarea);
            return copied;
        }}

        async function copyText(text, successMessage, failureMessage) {{
            if (!text) {{
                showToast("当前这个地址还没准备好。");
                return;
            }}

            try {{
                if (navigator.clipboard && window.isSecureContext) {{
                    await navigator.clipboard.writeText(text);
                    showToast(successMessage);
                    return;
                }}
            }} catch (error) {{
            }}

            if (fallbackCopy(text)) {{
                showToast(successMessage);
            }} else {{
                showToast(failureMessage);
            }}
        }}

        function wireCopy(cardId, successMessage, failureMessage) {{
            const targets = document.querySelectorAll(`[data-copy="${{cardId}}"]`);
            for (const target of targets) {{
                if (target.classList.contains("disabled")) {{
                    continue;
                }}

                const handler = (event) => {{
                    if (event.type === "keydown" && event.key !== "Enter" && event.key !== " ") {{
                        return;
                    }}
                    event.preventDefault();
                    if (target.tagName === "BUTTON") {{
                        event.stopPropagation();
                    }}
                    copyText(urls[cardId], successMessage, failureMessage);
                }};

                target.addEventListener("click", handler);
                target.addEventListener("keydown", handler);
            }}
        }}

        function setConnectedState(connected) {{
            if (connected) {{
                connectionStatus.textContent = "已连接";
                connectionStatus.className = "status-button connected";
                return;
            }}

            connectionStatus.textContent = "等待连接";
            connectionStatus.className = "status-button";
        }}

        function setStatusNote(message, tone = "normal") {{
            statusNote.textContent = message;
            statusNote.className = "status-note";
            if (tone === "success") {{
                statusNote.classList.add("success");
            }} else if (tone === "error") {{
                statusNote.classList.add("error");
            }}
        }}

        function handleAck(data) {{
            if (data.ok) {{
                setStatusNote("最近一次输入已经同步到电脑。", "success");
                return;
            }}

            if (data.reason === "permission_denied") {{
                setStatusNote("电脑输入权限不足，请回电脑端改用管理员启动。", "error");
                return;
            }}

            setStatusNote("电脑输入失败，请回电脑端重试。", "error");
        }}

        function updatePresence(connected) {{
            const mobileReady = !!connected.mobile;
            const desktopReady = !!connected.desktop;

            setConnectedState(mobileReady);
            if (!mobileReady) {{
                setStatusNote("扫码以后，电脑这里会自动显示已连接。");
                return;
            }}

            if (desktopReady) {{
                setStatusNote("已连接。现在回到你真正要输入的电脑窗口，点一下输入框，再开始说话或打字。");
            }} else {{
                setStatusNote("手机已连接，但电脑输入端还没准备好。请回电脑端检查启动状态。", "error");
            }}
        }}

        function connectPresence() {{
            monitorWs = new WebSocket(statusWsUrl);

            monitorWs.onopen = () => {{
                monitorWs.send(JSON.stringify({{ type: "register", role: "monitor", token: sessionToken }}));
            }};

            monitorWs.onmessage = (event) => {{
                try {{
                    const data = JSON.parse(event.data);
                    if (data.type === "presence") {{
                        updatePresence(data.connected || {{}});
                    }} else if (data.type === "ack") {{
                        handleAck(data);
                    }} else if (data.type === "auth" && data.ok === false) {{
                        setStatusNote("这次启动会话已经失效，请重新从电脑端打开扫码页。", "error");
                    }}
                }} catch (error) {{
                }}
            }};

            monitorWs.onclose = () => {{
                setConnectedState(false);
                setStatusNote("扫码页与后台连接断开，正在自动重连。", "error");
                window.setTimeout(connectPresence, 3000);
            }};

            monitorWs.onerror = () => {{
                setStatusNote("扫码页暂时连不上后台，请稍后。", "error");
            }};
        }}

        wireCopy("online", "互联网地址已复制。", "互联网地址复制失败。");
        wireCopy("lan", "局域网地址已复制。", "局域网地址复制失败。");
        connectPresence();
    </script>
</body>
</html>
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate QR assets for Voice Input Sync.")
    parser.add_argument("--url", required=True)
    parser.add_argument("--svg", required=True)
    parser.add_argument("--html", required=True)
    parser.add_argument("--ws-port", type=int, default=8765)
    parser.add_argument("--session-token", default="")
    parser.add_argument("--status-ws-url", default="")
    parser.add_argument("--online-url", default="")
    parser.add_argument("--lan-url", default="")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    svg_path = Path(args.svg).expanduser().resolve()
    html_path = Path(args.html).expanduser().resolve()

    svg_path.parent.mkdir(parents=True, exist_ok=True)
    html_path.parent.mkdir(parents=True, exist_ok=True)

    build_svg(args.url, svg_path)
    html_path.write_text(
        build_html(
            args.url,
            svg_path.name,
            args.ws_port,
            args.session_token,
            status_ws_url=args.status_ws_url,
            online_url=args.online_url.strip(),
            lan_url=args.lan_url.strip(),
        ),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
