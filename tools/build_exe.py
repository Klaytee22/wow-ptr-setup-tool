"""Build a standalone executable with PyInstaller.

    pip install -e ".[build]"
    python tools/build_exe.py

Produces ``dist/ptrsetup.exe`` on Windows, ``dist/ptrsetup`` elsewhere. The web
assets are bundled into the binary, so the result is a single file to hand over.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "src" / "ptrsetup" / "web"


def main() -> int:
    separator = ";" if os.name == "nt" else ":"
    command = [
        sys.executable,
        "-m",
        "PyInstaller",
        "--noconfirm",
        "--clean",
        "--onefile",
        "--name",
        "ptrsetup",
        "--paths",
        str(ROOT / "src"),
        "--add-data",
        f"{WEB}{separator}ptrsetup/web",
        # uvicorn loads these lazily, so PyInstaller cannot see them by itself.
        "--hidden-import",
        "uvicorn.logging",
        "--hidden-import",
        "uvicorn.loops.auto",
        "--hidden-import",
        "uvicorn.protocols.http.auto",
        "--hidden-import",
        "uvicorn.protocols.websockets.auto",
        "--hidden-import",
        "uvicorn.lifespan.on",
        str(ROOT / "src" / "ptrsetup" / "__main__.py"),
    ]
    print(" ".join(command))
    return subprocess.call(command, cwd=ROOT)


if __name__ == "__main__":
    raise SystemExit(main())
