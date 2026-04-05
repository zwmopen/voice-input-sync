import argparse
import asyncio
import sys
from typing import Sequence

import client as desktop_client
import generate_qr_bundle
import portable_http_server
import server as relay_server


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="VoiceInputSync unified portable runtime"
    )
    parser.add_argument(
        "role",
        choices=("http", "ws", "client", "qr"),
        help="runtime role to execute",
    )
    parser.add_argument(
        "role_args",
        nargs=argparse.REMAINDER,
        help="arguments forwarded to role entry",
    )
    return parser.parse_args()


def _replace_argv(role_args: Sequence[str]) -> None:
    sys.argv = [sys.argv[0], *role_args]


def run_http(role_args: Sequence[str]) -> int:
    _replace_argv(role_args)
    portable_http_server.main()
    return 0


def run_ws(role_args: Sequence[str]) -> int:
    _replace_argv(role_args)
    args = relay_server.parse_args()
    asyncio.run(relay_server.main(args.port, args.session_token))
    return 0


def run_client(role_args: Sequence[str]) -> int:
    _replace_argv(role_args)
    args = desktop_client.parse_args()
    asyncio.run(desktop_client.receive_messages(args.ws_url, args.session_token))
    return 0


def run_qr(role_args: Sequence[str]) -> int:
    _replace_argv(role_args)
    return int(generate_qr_bundle.main())


def main() -> int:
    args = parse_args()
    dispatch = {
        "http": run_http,
        "ws": run_ws,
        "client": run_client,
        "qr": run_qr,
    }
    runner = dispatch[args.role]
    return runner(args.role_args)


if __name__ == "__main__":
    raise SystemExit(main())
