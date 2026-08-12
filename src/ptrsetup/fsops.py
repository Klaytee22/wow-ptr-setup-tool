"""Preview-then-apply file copying, with a backup of everything overwritten.

Every step plans a list of :class:`FileAction` first and only writes when the
user presses Apply, so the wizard can always show exactly what is about to
change. Anything overwritten is copied into a timestamped backup folder that
:func:`restore_backup` can put back.
"""

from __future__ import annotations

import json
import shutil
import time
from collections.abc import Callable, Iterable
from pathlib import Path

from .models import FileAction

BACKUP_DIRNAME = "_ptrsetup_backups"
MANIFEST_NAME = "manifest.json"

# Never worth copying to the PTR, and noisy in the preview.
DEFAULT_EXCLUDES = ("Thumbs.db", ".DS_Store", "desktop.ini")


class UnsafePathError(RuntimeError):
    """Raised when a planned write would land outside the target install."""


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def _excluded(rel: Path, excludes: Iterable[str]) -> bool:
    names = set(excludes)
    return any(part in names for part in rel.parts)


def iter_files(root: Path, excludes: Iterable[str] = DEFAULT_EXCLUDES) -> list[Path]:
    """All files under ``root`` as paths relative to it, sorted for stable previews."""
    if not root.is_dir():
        return []
    out = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(root)
        if _excluded(rel, excludes):
            continue
        out.append(rel)
    return sorted(out)


def plan_tree_copy(
    src: Path,
    dest: Path,
    *,
    overwrite: bool = True,
    excludes: Iterable[str] = DEFAULT_EXCLUDES,
) -> list[FileAction]:
    """Plan a recursive copy of ``src`` onto ``dest`` without touching disk."""
    actions: list[FileAction] = []
    for rel in iter_files(src, excludes):
        s = src / rel
        d = dest / rel
        if not d.exists():
            actions.append(FileAction("create", s, d, s.stat().st_size))
        elif overwrite:
            actions.append(FileAction("overwrite", s, d, s.stat().st_size))
        else:
            actions.append(FileAction("skip", s, d, s.stat().st_size, "already exists"))
    return actions


def plan_file_copy(
    src: Path,
    dest: Path,
    *,
    overwrite: bool = True,
) -> list[FileAction]:
    """Plan a single-file copy."""
    if not src.is_file():
        return []
    size = src.stat().st_size
    if not dest.exists():
        return [FileAction("create", src, dest, size)]
    if overwrite:
        return [FileAction("overwrite", src, dest, size)]
    return [FileAction("skip", src, dest, size, "already exists")]


def backup_root(install_path: Path) -> Path:
    return install_path / BACKUP_DIRNAME


def new_backup_dir(install_path: Path, label: str) -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    safe = "".join(c if c.isalnum() or c in "-_" else "-" for c in label)
    return backup_root(install_path) / f"{stamp}-{safe}"


def apply_actions(
    actions: list[FileAction],
    *,
    install_path: Path,
    label: str,
    dry_run: bool = False,
    progress: Callable[[int, int], None] | None = None,
) -> tuple[list[FileAction], Path | None]:
    """Execute planned actions, backing up every file about to be overwritten.

    Returns the actions that were actually performed (skips are dropped) and the
    backup folder, if one was needed.

    Raises :class:`UnsafePathError` if any destination is outside ``install_path``
    — a guard against a mis-selected target turning into a copy over live files.
    """
    todo = [a for a in actions if a.kind in ("create", "overwrite")]
    for action in todo:
        if not is_within(action.dest, install_path):
            raise UnsafePathError(f"{action.dest} is outside {install_path}")

    if dry_run or not todo:
        return ([] if dry_run else todo), None

    overwrites = [a for a in todo if a.kind == "overwrite"]
    backup_dir: Path | None = None
    if overwrites:
        backup_dir = new_backup_dir(install_path, label)
        entries = []
        for action in overwrites:
            rel = action.dest.resolve().relative_to(install_path.resolve())
            target = backup_dir / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(action.dest, target)
            entries.append({"relative": str(rel), "restored_to": str(action.dest)})
        manifest = {
            "label": label,
            "install": str(install_path),
            "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "files": entries,
        }
        (backup_dir / MANIFEST_NAME).write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    total = len(todo)
    for index, action in enumerate(todo, start=1):
        action.dest.parent.mkdir(parents=True, exist_ok=True)
        if action.source is not None:
            shutil.copy2(action.source, action.dest)
        elif action.content is not None:
            action.dest.write_text(action.content, encoding="utf-8")
        else:
            raise UnsafePathError(f"action for {action.dest} has neither source nor content")
        if progress:
            progress(index, total)

    return todo, backup_dir


def list_backups(install_path: Path) -> list[dict]:
    """Backup folders for an install, newest first."""
    root = backup_root(install_path)
    if not root.is_dir():
        return []
    out = []
    for child in sorted(root.iterdir(), reverse=True):
        manifest = child / MANIFEST_NAME
        if not manifest.is_file():
            continue
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        out.append({"id": child.name, "path": str(child), "file_count": len(data.get("files", [])), **data})
    return out


def restore_backup(install_path: Path, backup_id: str) -> int:
    """Put a backup's files back where they came from. Returns the file count."""
    folder = backup_root(install_path) / backup_id
    manifest = folder / MANIFEST_NAME
    if not manifest.is_file():
        raise FileNotFoundError(f"no backup manifest at {manifest}")
    data = json.loads(manifest.read_text(encoding="utf-8"))
    restored = 0
    for entry in data.get("files", []):
        src = folder / entry["relative"]
        dest = install_path / entry["relative"]
        if not src.is_file():
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
        restored += 1
    return restored


def human_size(num: int) -> str:
    value = float(num)
    for unit in ("B", "KB", "MB", "GB"):
        if value < 1024 or unit == "GB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} GB"
