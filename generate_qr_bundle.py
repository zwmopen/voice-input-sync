from __future__ import annotations

import argparse
import html
import io
import json
from datetime import datetime
from pathlib import Path

import qrcode
from qrcode.image.svg import SvgPathImage


def build_svg(url: str, output_path: Path) -> None:
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
    output_path.write_text(buffer.getvalue().decode("utf-8"), encoding="utf-8")


def build_html(url: str, svg_filename: str, ws_port: int, session_token: str) -> str:
    host = url.split("://", 1)[1].split("/", 1)[0].split(":", 1)[0]
    ws_url = f"ws://{host}:{ws_port}"
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

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
            --red-soft: rgba(196, 74, 69, 0.1);
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
            width: min(1160px, 100%);
            margin: 0 auto;
            display: grid;
            grid-template-columns: minmax(340px, 420px) minmax(360px, 1fr);
            gap: 24px;
        }}

        .card {{
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
            font-size: clamp(34px, 5vw, 52px);
            line-height: 1.05;
        }}

        p {{
            margin: 0;
            color: var(--muted);
            line-height: 1.8;
            font-size: 16px;
        }}

        .qr-wrap {{
            margin-top: 20px;
            border-radius: 26px;
            padding: 22px;
            background: var(--paper);
            box-shadow: var(--shadow-inset);
            display: flex;
            align-items: center;
            justify-content: center;
        }}

        .qr-wrap img {{
            width: min(100%, 340px);
            height: auto;
            display: block;
            padding: 14px;
            border-radius: 20px;
            background: #fff;
            box-shadow: 10px 10px 22px rgba(170, 179, 190, 0.72), -10px -10px 22px rgba(255, 255, 255, 0.92);
        }}

        .status-panel {{
            margin-top: 18px;
            padding: 18px;
            border-radius: 22px;
            background: var(--paper);
            box-shadow: var(--shadow-inset);
        }}

        .status-label {{
            font-size: 13px;
            font-weight: 700;
            color: var(--muted);
            margin-bottom: 10px;
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
            margin-top: 12px;
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

        .url-box {{
            margin-top: 18px;
            padding: 18px;
            border-radius: 22px;
            background: var(--paper);
            box-shadow: var(--shadow-inset);
            cursor: pointer;
        }}

        .url-head {{
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 12px;
            margin-bottom: 10px;
        }}

        .url-label {{
            font-size: 13px;
            font-weight: 700;
            color: #35567f;
        }}

        .copy-pill {{
            border: none;
            border-radius: 999px;
            padding: 8px 14px;
            background: var(--paper);
            color: var(--accent);
            font-size: 13px;
            font-weight: 700;
            cursor: pointer;
            box-shadow: 6px 6px 12px rgba(176, 185, 197, 0.8), -6px -6px 12px rgba(255, 255, 255, 0.95);
        }}

        .url-value {{
            word-break: break-all;
            font-size: 16px;
            line-height: 1.7;
            color: #18314f;
            font-weight: 700;
        }}

        .list {{
            display: grid;
            gap: 12px;
        }}

        .item {{
            padding: 16px 18px;
            border-radius: 18px;
            background: var(--paper);
            box-shadow: 10px 10px 20px rgba(176, 185, 197, 0.7), -10px -10px 20px rgba(255, 255, 255, 0.92);
        }}

        .item strong {{
            display: block;
            margin-bottom: 6px;
            font-size: 15px;
        }}

        .meta {{
            margin-top: 18px;
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

        @media (max-width: 940px) {{
            .shell {{
                grid-template-columns: 1fr;
            }}
        }}

        @media (max-width: 640px) {{
            body {{
                padding: 16px;
            }}

            .card {{
                padding: 22px;
                border-radius: 24px;
            }}

            .url-head {{
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
        <section class="card">
            <div class="eyebrow">语音输入同步 · 手机扫码连接</div>
            <h1>扫一扫，马上开始。</h1>
            <p>手机扫这个二维码就能直接进入输入页。扫完以后，回到你真正要输入的电脑窗口，点一下输入框，再开始说话或打字。</p>

            <div class="qr-wrap">
                <img src="{html.escape(svg_filename)}" alt="语音输入同步二维码">
            </div>

            <div class="status-panel">
                <div class="status-label">连接状态</div>
                <button class="status-button" type="button" id="connectionStatus">等待连接</button>
                <div class="status-note" id="statusNote">扫码以后，电脑这里会自动显示已连接。输入成功或失败，也会在这里给你反馈。</div>
            </div>

            <div class="meta">生成时间：{generated_at}</div>
        </section>

        <section class="card">
            <div class="list">
                <div class="item">
                    <strong>手机打开地址</strong>
                    <div class="url-box" id="urlBox" role="button" tabindex="0" aria-label="点击复制手机地址">
                        <div class="url-head">
                            <div class="url-label">手动地址</div>
                            <button class="copy-pill" type="button" id="copyButton">点击复制地址</button>
                        </div>
                        <div class="url-value">{html.escape(url)}</div>
                    </div>
                </div>

                <div class="item">
                    <strong>先做这一件事</strong>
                    <span>在电脑上先把光标点到你真正要输入的位置。这个工具只负责把手机上的输入送过去，不会替你决定要输入到哪个框里。</span>
                </div>

                <div class="item">
                    <strong>如果手机连上了但电脑没打字</strong>
                    <span>回到绿色包根目录，双击“如果输入没反应-请用管理员启动.bat”。新版已经会把失败原因直接回传到这页和手机页。</span>
                </div>

                <div class="item">
                    <strong>输入模式说明</strong>
                    <span>手机页现在有“实时同步”和“整段同步”两种模式。输入法改写频繁时，改用整段同步会更稳。</span>
                </div>
            </div>
        </section>
    </main>

    <div class="toast" id="toast">地址已复制。</div>

    <script>
        const manualUrl = {json.dumps(url, ensure_ascii=False)};
        const statusWsUrl = {json.dumps(ws_url, ensure_ascii=False)};
        const sessionToken = {json.dumps(session_token, ensure_ascii=False)};
        const urlBox = document.getElementById("urlBox");
        const copyButton = document.getElementById("copyButton");
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

        async function copyManualUrl() {{
            try {{
                if (navigator.clipboard && window.isSecureContext) {{
                    await navigator.clipboard.writeText(manualUrl);
                    showToast("地址已复制，去手机浏览器打开就行。");
                    return;
                }}
            }} catch (error) {{
            }}

            if (fallbackCopy(manualUrl)) {{
                showToast("地址已复制，去手机浏览器打开就行。");
            }} else {{
                showToast("复制失败，请手动长按地址。");
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
                setStatusNote("扫码以后，电脑这里会自动显示已连接。", "normal");
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

        urlBox.addEventListener("click", () => {{
            copyManualUrl();
        }});

        copyButton.addEventListener("click", (event) => {{
            event.stopPropagation();
            copyManualUrl();
        }});

        urlBox.addEventListener("keydown", (event) => {{
            if (event.key === "Enter" || event.key === " ") {{
                event.preventDefault();
                copyManualUrl();
            }}
        }});

        connectPresence();
    </script>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate QR assets for Voice Input Sync.")
    parser.add_argument("--url", required=True)
    parser.add_argument("--svg", required=True)
    parser.add_argument("--html", required=True)
    parser.add_argument("--ws-port", type=int, default=8765)
    parser.add_argument("--session-token", default="")
    args = parser.parse_args()

    svg_path = Path(args.svg).expanduser().resolve()
    html_path = Path(args.html).expanduser().resolve()

    svg_path.parent.mkdir(parents=True, exist_ok=True)
    html_path.parent.mkdir(parents=True, exist_ok=True)

    build_svg(args.url, svg_path)
    html_path.write_text(
        build_html(args.url, svg_path.name, args.ws_port, args.session_token),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
