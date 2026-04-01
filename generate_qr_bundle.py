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


def build_html(url: str, svg_filename: str, ws_port: int) -> str:
    safe_url = html.escape(url)
    safe_url_js = json.dumps(url, ensure_ascii=False)
    safe_svg = html.escape(svg_filename)
    host = url.split("://", 1)[1].split("/", 1)[0].split(":", 1)[0]
    safe_ws_url_js = json.dumps(f"ws://{host}:{ws_port}", ensure_ascii=False)
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>语音输入同步 - 手机扫码连接</title>
    <style>
        :root {{
            --bg: #e0e5ec;
            --panel: #e0e5ec;
            --text: #324256;
            --muted: #6f7b8d;
            --brand: #d97706;
            --brand-strong: #b25e00;
            --blue: #2457a6;
            --green: #1f8a5b;
            --shadow-raise: 16px 16px 34px #b8bec7, -16px -16px 34px #ffffff;
            --shadow-soft: 10px 10px 20px #bcc2cb, -10px -10px 20px #ffffff;
            --shadow-inset: inset 6px 6px 12px #bcc2cb, inset -6px -6px 12px #ffffff;
        }}

        * {{
            box-sizing: border-box;
        }}

        body {{
            margin: 0;
            font-family: "Microsoft YaHei UI", "PingFang SC", "Noto Sans SC", sans-serif;
            color: var(--text);
            background:
                radial-gradient(circle at top left, rgba(217, 119, 6, 0.14), transparent 24%),
                radial-gradient(circle at top right, rgba(36, 87, 166, 0.10), transparent 18%),
                linear-gradient(180deg, #edf1f6 0%, #dde3ea 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 24px;
        }}

        .shell {{
            width: min(1180px, 100%);
            display: grid;
            grid-template-columns: minmax(340px, 440px) minmax(340px, 1fr);
            gap: 24px;
        }}

        .card {{
            background: var(--panel);
            border-radius: 30px;
            box-shadow: var(--shadow-raise);
            padding: 28px;
        }}

        .eyebrow {{
            display: inline-flex;
            align-items: center;
            gap: 8px;
            padding: 8px 14px;
            border-radius: 999px;
            background: var(--panel);
            box-shadow: var(--shadow-soft);
            color: var(--brand);
            font-size: 13px;
            font-weight: 700;
        }}

        h1 {{
            margin: 18px 0 10px;
            font-size: clamp(34px, 5vw, 54px);
            line-height: 1.05;
        }}

        p {{
            margin: 0;
            line-height: 1.8;
            color: var(--muted);
            font-size: 16px;
        }}

        .qr-wrap {{
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 22px;
            border-radius: 26px;
            background: var(--panel);
            box-shadow: var(--shadow-inset);
            margin-bottom: 18px;
        }}

        .qr-wrap img {{
            width: min(100%, 360px);
            height: auto;
            display: block;
            border-radius: 18px;
            background: #fff;
            padding: 14px;
            box-shadow: 8px 8px 16px rgba(184, 190, 199, 0.9), -8px -8px 16px rgba(255, 255, 255, 0.95);
        }}

        .list {{
            display: grid;
            gap: 12px;
            margin-top: 18px;
        }}

        .item {{
            display: flex;
            gap: 12px;
            align-items: flex-start;
            padding: 14px 16px;
            border-radius: 18px;
            background: var(--panel);
            box-shadow: var(--shadow-soft);
        }}

        .badge {{
            width: 28px;
            height: 28px;
            flex: 0 0 auto;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            border-radius: 50%;
            color: #fff;
            font-weight: 700;
            background: linear-gradient(135deg, #d97706, #f4a340);
        }}

        .item strong {{
            display: block;
            margin-bottom: 4px;
            font-size: 15px;
        }}

        .url-box {{
            margin-top: 18px;
            padding: 18px;
            border-radius: 22px;
            background: var(--panel);
            box-shadow: var(--shadow-inset);
            cursor: pointer;
            transition: transform 0.18s ease, box-shadow 0.18s ease;
        }}

        .url-box:hover {{
            transform: translateY(-1px);
        }}

        .url-box:focus-visible {{
            outline: 3px solid rgba(36, 87, 166, 0.18);
            outline-offset: 4px;
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
            color: var(--blue);
            font-weight: 700;
        }}

        .copy-pill {{
            display: inline-flex;
            align-items: center;
            justify-content: center;
            padding: 8px 14px;
            border: none;
            border-radius: 999px;
            background: var(--panel);
            color: var(--brand-strong);
            font-size: 13px;
            font-weight: 700;
            cursor: pointer;
            box-shadow: 6px 6px 12px #b8bec7, -6px -6px 12px #ffffff;
        }}

        .copy-pill:active {{
            box-shadow: inset 4px 4px 8px #bcc2cb, inset -4px -4px 8px #ffffff;
        }}

        .url-value {{
            word-break: break-all;
            font-size: 16px;
            line-height: 1.7;
            color: #18314f;
            font-weight: 700;
        }}

        .url-help {{
            margin-top: 10px;
            font-size: 13px;
            color: var(--muted);
        }}

        .url-tip {{
            margin-top: 12px;
            display: inline-flex;
            align-items: center;
            gap: 8px;
            padding: 10px 14px;
            border-radius: 14px;
            background: rgba(36, 87, 166, 0.08);
            color: var(--blue);
            font-size: 13px;
            font-weight: 600;
        }}

        .status-panel {{
            margin-top: 18px;
            padding: 18px;
            border-radius: 22px;
            background: var(--panel);
            box-shadow: var(--shadow-inset);
        }}

        .status-label {{
            font-size: 13px;
            color: var(--muted);
            margin-bottom: 10px;
            font-weight: 700;
        }}

        .status-button {{
            width: 100%;
            border: none;
            border-radius: 999px;
            padding: 16px 18px;
            background: var(--panel);
            color: var(--brand-strong);
            font-size: 18px;
            font-weight: 800;
            box-shadow: 8px 8px 16px #b8bec7, -8px -8px 16px #ffffff;
        }}

        .status-button.connected {{
            color: #ffffff;
            background: linear-gradient(145deg, #7fd1a8, #49b27c);
            box-shadow: 8px 8px 18px rgba(73, 178, 124, 0.35), -8px -8px 16px rgba(255, 255, 255, 0.92);
        }}

        .status-note {{
            margin-top: 12px;
            font-size: 14px;
            line-height: 1.8;
            color: var(--muted);
        }}

        .tips {{
            display: grid;
            gap: 12px;
            margin-top: 20px;
        }}

        .tip {{
            padding: 16px 18px;
            border-radius: 18px;
            background: var(--panel);
            box-shadow: var(--shadow-soft);
        }}

        .tip strong {{
            display: block;
            margin-bottom: 6px;
            font-size: 15px;
        }}

        .meta {{
            margin-top: 18px;
            font-size: 13px;
            color: #7d7367;
        }}

        .toast {{
            position: fixed;
            left: 50%;
            bottom: 28px;
            transform: translateX(-50%) translateY(24px);
            background: var(--panel);
            color: var(--green);
            padding: 14px 22px;
            border-radius: 999px;
            box-shadow: var(--shadow-raise);
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

        @media (max-width: 920px) {{
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
            <h1>扫一扫，直接开始。</h1>
            <p>手机打开相机或微信扫一扫，扫这个二维码就能直接进入输入页，不用手工发链接，也不用自己拼地址。</p>

            <div class="url-box" id="urlBox" role="button" tabindex="0" aria-label="点击复制地址">
                <div class="url-head">
                    <div class="url-label">手机打开地址</div>
                    <button class="copy-pill" type="button" id="copyButton">点击复制地址</button>
                </div>
                <div class="url-value" id="manualUrl">{safe_url}</div>
            </div>

            <div class="status-panel">
                <div class="status-label">连接状态</div>
                <button class="status-button" type="button" id="connectionStatus">等待连接</button>
                <div class="status-note" id="statusNote">扫码后，回到你真正要输入的窗口，点一下输入框，再开始说话或打字。</div>
            </div>

            <div class="tips">
                <div class="tip">
                    <strong>使用前先做一件事</strong>
                    <span>先去电脑上把光标点到你要输入的位置，再用手机开始说话或打字。</span>
                </div>
                <div class="tip">
                    <strong>如果手机连上了，但电脑没打字</strong>
                    <span>回到绿色包根目录，双击“如果输入没反应-请用管理员启动.bat”。</span>
                </div>
            </div>

            <div class="meta">生成时间：{generated_at}</div>
        </section>

        <section class="card">
            <div class="qr-wrap">
                <img src="{safe_svg}" alt="语音输入同步二维码">
            </div>

            <div class="list">
                <div class="item">
                    <span class="badge">1</span>
                    <div>
                        <strong>确保同一个网络</strong>
                        <span>手机和电脑要在同一个 Wi-Fi 或同一个局域网里。</span>
                    </div>
                </div>
                <div class="item">
                    <span class="badge">2</span>
                    <div>
                        <strong>用手机扫一扫</strong>
                        <span>优先用相机或微信扫一扫；扫码失败时，再手动打开上方地址。</span>
                    </div>
                </div>
                <div class="item">
                    <span class="badge">3</span>
                    <div>
                        <strong>进入页面后直接输入</strong>
                        <span>可以用语音输入法，也可以手动打字，内容会同步到电脑当前光标位置。</span>
                    </div>
                </div>
            </div>
        </section>
    </main>
    <div class="toast" id="toast">地址已复制，去手机上打开就行。</div>
    <script>
        const manualUrl = {safe_url_js};
        const statusWsUrl = {safe_ws_url_js};
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
                    showToast("地址已复制，去手机浏览器粘贴即可。");
                    return;
                }}
            }} catch (error) {{
            }}

            if (fallbackCopy(manualUrl)) {{
                showToast("地址已复制，去手机浏览器粘贴即可。");
            }} else {{
                showToast("复制失败，请手动长按或选择地址。");
            }}
        }}

        function updatePresence(connected) {{
            const mobileReady = !!connected.mobile;
            const desktopReady = !!connected.desktop;

            if (mobileReady) {{
                connectionStatus.textContent = "已连接";
                connectionStatus.className = "status-button connected";
                if (desktopReady) {{
                    statusNote.textContent = "已连接。现在回到你真正要输入的窗口，点一下输入框，再开始说话或打字。";
                }} else {{
                    statusNote.textContent = "已连接。如果电脑没有打字，请回绿色包根目录使用“如果输入没反应-请用管理员启动.bat”。";
                }}
            }} else {{
                connectionStatus.textContent = "等待连接";
                connectionStatus.className = "status-button";
                statusNote.textContent = "扫码后，回到你真正要输入的窗口，点一下输入框，再开始说话或打字。";
            }}
        }}

        function connectPresence() {{
            monitorWs = new WebSocket(statusWsUrl);

            monitorWs.onopen = () => {{
                monitorWs.send(JSON.stringify({{ type: "register", role: "monitor" }}));
            }};

            monitorWs.onmessage = (event) => {{
                try {{
                    const data = JSON.parse(event.data);
                    if (data.type === "presence") {{
                        updatePresence(data.connected || {{}});
                    }}
                }} catch (error) {{
                }}
            }};

            monitorWs.onclose = () => {{
                updatePresence({{ mobile: false, desktop: false }});
                window.setTimeout(connectPresence, 3000);
            }};

            monitorWs.onerror = () => {{
                updatePresence({{ mobile: false, desktop: false }});
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
    args = parser.parse_args()

    svg_path = Path(args.svg).expanduser().resolve()
    html_path = Path(args.html).expanduser().resolve()

    svg_path.parent.mkdir(parents=True, exist_ok=True)
    html_path.parent.mkdir(parents=True, exist_ok=True)

    build_svg(args.url, svg_path)
    html_path.write_text(build_html(args.url, svg_path.name, args.ws_port), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
