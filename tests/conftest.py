"""Shared fixtures. The builders themselves live in ``helpers.py``."""

from __future__ import annotations

from pathlib import Path

import pytest

from helpers import make_install


@pytest.fixture
def wow_root(tmp_path: Path) -> Path:
    """A ``World of Warcraft`` folder holding a populated live client and an empty PTR one."""
    root = tmp_path / "World of Warcraft"
    make_install(root, "_classic_")
    make_install(
        root,
        "_classic_ptr_",
        realm="PTR Whitemane",
        addons=(),
        config='SET realmList "us.logon-ptr.worldofwarcraft.com"\nSET gxWindow "0"\n',
        account_saved_variables=(),
    )
    return root
