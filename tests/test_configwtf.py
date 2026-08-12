from __future__ import annotations

from ptrsetup import configwtf

LIVE = """SET gxWindow "1"
SET gxResolution "2560x1440"
SET realmList "us.logon.worldofwarcraft.com"
# a comment line the parser ignores
SET Sound_MasterVolume "0.4"
"""

PTR = """SET realmList "us.logon-ptr.worldofwarcraft.com"
SET gxWindow "0"
SET ptrOnlySetting "7"
"""


def test_parse_reads_set_lines_and_ignores_the_rest() -> None:
    parsed = configwtf.parse(LIVE)
    assert parsed["gxResolution"] == "2560x1440"
    assert len(parsed) == 4


def test_merge_takes_live_values() -> None:
    merged = configwtf.merge(configwtf.parse(LIVE), configwtf.parse(PTR))
    assert merged["gxWindow"] == "1"
    assert merged["gxResolution"] == "2560x1440"


def test_merge_keeps_the_ptr_realm_list() -> None:
    merged = configwtf.merge(configwtf.parse(LIVE), configwtf.parse(PTR))
    assert merged["realmList"] == "us.logon-ptr.worldofwarcraft.com"


def test_merge_preserves_ptr_only_keys() -> None:
    merged = configwtf.merge(configwtf.parse(LIVE), configwtf.parse(PTR))
    assert merged["ptrOnlySetting"] == "7"


def test_overrides_win_over_everything() -> None:
    merged = configwtf.merge(
        configwtf.parse(LIVE), configwtf.parse(PTR), overrides={"checkAddonVersion": "0"}
    )
    assert merged["checkAddonVersion"] == "0"


def test_render_round_trips() -> None:
    parsed = configwtf.parse(LIVE)
    assert configwtf.parse(configwtf.render(parsed)) == parsed


def test_diff_labels_each_change() -> None:
    before = configwtf.parse(PTR)
    after = configwtf.merge(configwtf.parse(LIVE), before)
    kinds = {c["key"]: c["kind"] for c in configwtf.diff(before, after)}
    assert kinds["gxWindow"] == "changed"
    assert kinds["gxResolution"] == "added"
    assert "realmList" not in kinds
