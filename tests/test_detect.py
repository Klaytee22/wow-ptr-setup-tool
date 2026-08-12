from __future__ import annotations

from pathlib import Path

from ptrsetup.detect import (
    find_installs,
    list_accounts,
    list_characters,
    list_realms,
    suggest_pair,
)

from helpers import make_install


def test_finds_both_clients_under_a_root(wow_root: Path) -> None:
    installs = find_installs([wow_root])
    names = {i.flavor.dirname for i in installs}
    assert names == {"_classic_", "_classic_ptr_"}


def test_accepts_a_path_to_a_single_client_folder(wow_root: Path) -> None:
    installs = find_installs([wow_root / "_classic_ptr_"])
    # Pointing at one client still surfaces its sibling, since the parent is scanned.
    assert {i.flavor.dirname for i in installs} == {"_classic_", "_classic_ptr_"}


def test_ignores_unrelated_folders(tmp_path: Path) -> None:
    root = tmp_path / "World of Warcraft"
    make_install(root, "_classic_")
    (root / "Utils").mkdir()
    (root / "_not_a_flavor_").mkdir()
    assert [i.flavor.dirname for i in find_installs([root])] == ["_classic_"]


def test_suggest_pair_matches_the_same_game_line(wow_root: Path) -> None:
    source, target = suggest_pair(find_installs([wow_root]))
    assert source is not None and target is not None
    assert source.flavor.dirname == "_classic_"
    assert target.flavor.dirname == "_classic_ptr_"


def test_suggest_pair_prefers_a_matching_line_over_a_matching_root(tmp_path: Path) -> None:
    root_a = tmp_path / "A" / "World of Warcraft"
    root_b = tmp_path / "B" / "World of Warcraft"
    make_install(root_a, "_retail_")
    make_install(root_b, "_classic_")
    make_install(root_b, "_classic_ptr_")
    source, target = suggest_pair(find_installs([root_a, root_b]))
    assert source is not None and target is not None
    assert source.flavor.line == target.flavor.line == "classic"


def test_suggest_pair_with_no_ptr_client(tmp_path: Path) -> None:
    root = tmp_path / "World of Warcraft"
    make_install(root, "_classic_")
    source, target = suggest_pair(find_installs([root]))
    assert source is not None
    assert target is None


def test_lists_accounts_realms_and_characters(wow_root: Path) -> None:
    live = next(i for i in find_installs([wow_root]) if not i.flavor.is_ptr)
    assert list_accounts(live) == ["12345678#1"]
    assert list_realms(live, "12345678#1") == ["Whitemane"]
    chars = list_characters(live, "12345678#1")
    assert [c.name for c in chars] == ["Bankalt"]
    assert chars[0].id == "12345678#1/Whitemane/Bankalt"


def test_saved_variables_is_not_mistaken_for_a_realm(wow_root: Path) -> None:
    live = next(i for i in find_installs([wow_root]) if not i.flavor.is_ptr)
    assert "SavedVariables" not in list_realms(live, "12345678#1")


def test_has_been_launched_reflects_the_wtf_folder(tmp_path: Path) -> None:
    root = tmp_path / "World of Warcraft"
    make_install(root, "_classic_")
    fresh = root / "_classic_ptr_"
    (fresh / "Interface").mkdir(parents=True)
    installs = {i.flavor.dirname: i for i in find_installs([root])}
    assert installs["_classic_"].has_been_launched is True
    assert installs["_classic_ptr_"].has_been_launched is False
