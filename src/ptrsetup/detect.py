"""Find WoW installs on this machine and enumerate what lives inside them.

Detection is deliberately forgiving: it scans the handful of places Battle.net
installs to, and the UI always lets the user paste a path the scan missed.
"""

from __future__ import annotations

import os
import platform
import string
from pathlib import Path

from .models import FLAVORS_BY_DIR, CharacterRef, Install

# Directories inside an account folder that are realms rather than payload.
_ACCOUNT_NON_REALM = {"SavedVariables"}


def candidate_roots() -> list[Path]:
    """Likely ``World of Warcraft`` parent folders for the current platform."""
    system = platform.system()
    roots: list[Path] = []

    if system == "Windows":
        drives = [f"{letter}:\\" for letter in string.ascii_uppercase if Path(f"{letter}:\\").exists()]
        for drive in drives:
            roots += [
                Path(drive) / "Program Files (x86)" / "World of Warcraft",
                Path(drive) / "Program Files" / "World of Warcraft",
                Path(drive) / "World of Warcraft",
                Path(drive) / "Games" / "World of Warcraft",
                Path(drive) / "Battle.net" / "World of Warcraft",
            ]
    elif system == "Darwin":
        roots += [
            Path("/Applications/World of Warcraft"),
            Path.home() / "Applications" / "World of Warcraft",
        ]
    else:  # Linux (Lutris / Wine prefixes are the common case)
        home = Path.home()
        roots += [
            home / "Games" / "World of Warcraft",
            home / ".wine" / "drive_c" / "Program Files (x86)" / "World of Warcraft",
            home / "World of Warcraft",
        ]

    extra = os.environ.get("PTRSETUP_EXTRA_ROOTS", "")
    roots += [Path(p) for p in extra.split(os.pathsep) if p.strip()]
    return roots


def installs_in_root(root: Path) -> list[Install]:
    """Every recognised client folder directly inside one ``World of Warcraft`` folder."""
    if not root.is_dir():
        return []
    found: list[Install] = []
    for child in sorted(root.iterdir()):
        flavor = FLAVORS_BY_DIR.get(child.name)
        if flavor and child.is_dir():
            found.append(Install(path=child, flavor=flavor))
    return found


def find_installs(extra_roots: list[Path] | None = None) -> list[Install]:
    """Scan the standard locations plus any user-supplied paths.

    A user-supplied path may point either at the ``World of Warcraft`` folder or
    at a single client folder inside it — both are accepted, because people copy
    whichever one their file explorer happens to be showing.
    """
    roots = list(candidate_roots()) + list(extra_roots or [])
    seen: dict[str, Install] = {}

    for root in roots:
        if not root.is_dir():
            continue
        # A path pointing straight at a client folder, e.g. ".../_classic_ptr_".
        flavor = FLAVORS_BY_DIR.get(root.name)
        if flavor:
            install = Install(path=root, flavor=flavor)
            seen.setdefault(install.id, install)
            root = root.parent
        for install in installs_in_root(root):
            seen.setdefault(install.id, install)

    return sorted(seen.values(), key=lambda i: (str(i.root), i.flavor.dirname))


def suggest_pair(installs: list[Install]) -> tuple[Install | None, Install | None]:
    """Pick the most plausible (source live client, target PTR client) pair.

    Prefers a live/PTR pair on the same line and under the same root, since that
    is what "copy my UI to the PTR" means for all but the oddest setups.
    """
    live = [i for i in installs if not i.flavor.is_ptr and i.has_been_launched]
    ptr = [i for i in installs if i.flavor.is_ptr]
    if not ptr:
        return (live[0] if live else None), None

    for target in ptr:
        for source in live:
            if source.flavor.line == target.flavor.line and source.root == target.root:
                return source, target
    for target in ptr:
        for source in live:
            if source.flavor.line == target.flavor.line:
                return source, target
    return (live[0] if live else None), ptr[0]


def list_accounts(install: Install) -> list[str]:
    """Account folder names under ``WTF/Account`` (usually the WoW account ID)."""
    if not install.account_root.is_dir():
        return []
    return sorted(
        p.name
        for p in install.account_root.iterdir()
        if p.is_dir() and p.name.upper() != "SAVEDVARIABLES"
    )


def list_realms(install: Install, account: str) -> list[str]:
    base = install.account_root / account
    if not base.is_dir():
        return []
    return sorted(p.name for p in base.iterdir() if p.is_dir() and p.name not in _ACCOUNT_NON_REALM)


def list_characters(install: Install, account: str) -> list[CharacterRef]:
    """Every character folder under an account, across all its realms."""
    chars: list[CharacterRef] = []
    for realm in list_realms(install, account):
        realm_dir = install.account_root / account / realm
        for child in sorted(realm_dir.iterdir()):
            if child.is_dir():
                chars.append(CharacterRef(account=account, realm=realm, name=child.name))
    return chars


def character_dir(install: Install, char: CharacterRef) -> Path:
    return install.account_root / char.account / char.realm / char.name
