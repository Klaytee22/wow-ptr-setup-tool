"""Read and merge ``Config.wtf``.

``Config.wtf`` is a flat list of ``SET key "value"`` lines holding client-wide
settings (resolution, window mode, addon-version checking, …). Copying the live
file wholesale is the usual advice, but a few keys are client-specific — the
realm list in particular points a client at a set of servers, and carrying the
live value across can send the PTR client at live realms. So the merge keeps
those keys from the target instead of overwriting them.
"""

from __future__ import annotations

import re
from pathlib import Path

_SET_RE = re.compile(r'^\s*SET\s+(?P<key>[\w.]+)\s+"(?P<value>.*)"\s*$')

# Keys that must keep the PTR client's own value.
PROTECTED_KEYS: tuple[str, ...] = (
    "realmList",
    "realmName",
    "portal",
    "agentUID",
    "accountName",
    "lastCharacterIndex",
)


def parse(text: str) -> dict[str, str]:
    """Parse ``Config.wtf`` contents into an ordered key → value mapping."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        match = _SET_RE.match(line)
        if match:
            out[match.group("key")] = match.group("value")
    return out


def read(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    return parse(path.read_text(encoding="utf-8", errors="replace"))


def render(settings: dict[str, str]) -> str:
    """Render a mapping back to ``Config.wtf`` syntax, one ``SET`` per line."""
    lines = [f'SET {key} "{value}"' for key, value in settings.items()]
    return "\n".join(lines) + "\n"


def merge(
    source: dict[str, str],
    target: dict[str, str],
    *,
    protected: tuple[str, ...] = PROTECTED_KEYS,
    overrides: dict[str, str] | None = None,
) -> dict[str, str]:
    """Overlay the live client's settings onto the PTR client's settings.

    Target values win for ``protected`` keys; ``overrides`` win over everything.
    Keys the target has and the source lacks are preserved.
    """
    merged = dict(target)
    for key, value in source.items():
        if key in protected:
            continue
        merged[key] = value
    for key in protected:
        if key in target:
            merged[key] = target[key]
    for key, value in (overrides or {}).items():
        merged[key] = value
    return merged


def diff(before: dict[str, str], after: dict[str, str]) -> list[dict[str, str]]:
    """Human-readable list of the changes a merge would make, for the preview."""
    changes: list[dict[str, str]] = []
    for key in sorted(set(before) | set(after)):
        old = before.get(key)
        new = after.get(key)
        if old == new:
            continue
        changes.append(
            {
                "key": key,
                "before": "" if old is None else old,
                "after": "" if new is None else new,
                "kind": "added" if old is None else ("removed" if new is None else "changed"),
            }
        )
    return changes
