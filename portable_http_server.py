import argparse
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def resolve_root() -> Path:
    if getattr(sys, "frozen", False):
        exe_dir = Path(sys.executable).resolve().parent
        # In PyInstaller onedir builds, the executable lives in a nested
        # subfolder like _runtime/VoiceInputSyncHttp/. The actual static site
        # assets live one level up at _runtime/.
        if exe_dir.name.lower().startswith("voiceinputsync"):
            return exe_dir.parent
        return exe_dir
    return Path(__file__).resolve().parent


ROOT = resolve_root()


class StaticHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)


def parse_args():
    parser = argparse.ArgumentParser(description="VoiceInputSync static HTTP server")
    parser.add_argument("--port", type=int, default=8000)
    return parser.parse_args()


def main():
    args = parse_args()
    server = ThreadingHTTPServer(("0.0.0.0", args.port), StaticHandler)
    print(f"VoiceInputSync HTTP server listening on http://0.0.0.0:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
