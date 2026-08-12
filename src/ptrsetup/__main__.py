"""Entry point: start the local server and open the wizard in the browser."""

from __future__ import annotations

import argparse
import socket
import threading
import webbrowser

import uvicorn

from .app import create_app

HOST = "127.0.0.1"


def free_port(preferred: int = 8731) -> int:
    """Use the preferred port if it is free, otherwise let the OS pick one."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind((HOST, preferred))
            return preferred
        except OSError:
            pass
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind((HOST, 0))
        return int(sock.getsockname()[1])


def main() -> None:
    parser = argparse.ArgumentParser(prog="ptrsetup", description="Copy your live WoW UI to the PTR.")
    parser.add_argument("--port", type=int, default=0, help="Port to serve on (default: auto).")
    parser.add_argument("--no-browser", action="store_true", help="Do not open a browser window.")
    args = parser.parse_args()

    port = args.port or free_port()
    url = f"http://{HOST}:{port}/"

    if not args.no_browser:
        threading.Timer(0.8, lambda: webbrowser.open(url)).start()

    print(f"WoW PTR UI Setup running at {url}  (Ctrl+C to quit)")
    uvicorn.run(create_app(), host=HOST, port=port, log_level="warning")


if __name__ == "__main__":
    main()
