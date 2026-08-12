"""Builders for fake World of Warcraft install trees.

Kept out of ``conftest.py`` so test modules can import them by name.
"""

from __future__ import annotations

from pathlib import Path

DEFAULT_CONFIG = """SET gxWindow "1"
SET gxResolution "2560x1440"
SET realmList "us.logon.worldofwarcraft.com"
SET Sound_MasterVolume "0.4"
"""


def write(path: Path, text: str = "x") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def make_install(
    root: Path,
    flavor: str,
    *,
    account: str = "12345678#1",
    realm: str = "Whitemane",
    characters: tuple[str, ...] = ("Bankalt",),
    addons: tuple[str, ...] = ("WeakAuras", "Details"),
    config: str | None = DEFAULT_CONFIG,
    account_saved_variables: tuple[str, ...] = ("WeakAuras.lua",),
) -> Path:
    """Create one client folder, e.g. ``<root>/_classic_``, populated enough to copy."""
    install = root / flavor
    install.mkdir(parents=True, exist_ok=True)

    for addon in addons:
        write(install / "Interface" / "AddOns" / addon / f"{addon}.toc", f"## Title: {addon}\n")
        write(install / "Interface" / "AddOns" / addon / f"{addon}.lua", "-- code\n")

    if config is not None:
        write(install / "WTF" / "Config.wtf", config)

    account_dir = install / "WTF" / "Account" / account
    for name in account_saved_variables:
        write(account_dir / "SavedVariables" / name, "-- account profile\n")
    write(account_dir / "macros-cache.txt", "macros\n")
    write(account_dir / "bindings-cache.wtf", "bindings\n")

    for character in characters:
        char_dir = account_dir / realm / character
        write(char_dir / "SavedVariables" / "WeakAuras.lua", "-- char profile\n")
        write(char_dir / "AddOns.txt", "WeakAuras: enabled\n")
        write(char_dir / "layout-local.txt", "layout\n")
        write(char_dir / "macros-cache.txt", "char macros\n")
        write(char_dir / "bindings-cache.wtf", "char bindings\n")

    return install
