from __future__ import annotations

from pathlib import Path

import pytest

from ptrsetup.fsops import (
    UnsafePathError,
    apply_actions,
    human_size,
    is_within,
    iter_files,
    list_backups,
    plan_file_copy,
    plan_tree_copy,
    restore_backup,
)
from ptrsetup.models import FileAction

from helpers import write


def test_plan_marks_new_files_as_create(tmp_path: Path) -> None:
    src = tmp_path / "src"
    write(src / "a.lua", "one")
    write(src / "nested" / "b.lua", "two")
    actions = plan_tree_copy(src, tmp_path / "dest")
    assert {a.kind for a in actions} == {"create"}
    assert len(actions) == 2


def test_plan_marks_existing_files_as_overwrite_or_skip(tmp_path: Path) -> None:
    src, dest = tmp_path / "src", tmp_path / "dest"
    write(src / "a.lua", "new")
    write(dest / "a.lua", "old")
    assert plan_tree_copy(src, dest)[0].kind == "overwrite"
    skipped = plan_tree_copy(src, dest, overwrite=False)[0]
    assert skipped.kind == "skip"
    assert skipped.note == "already exists"


def test_plan_excludes_junk_files(tmp_path: Path) -> None:
    src = tmp_path / "src"
    write(src / "a.lua", "one")
    write(src / ".DS_Store", "junk")
    write(src / "sub" / "Thumbs.db", "junk")
    assert [a.dest.name for a in plan_tree_copy(src, tmp_path / "dest")] == ["a.lua"]


def test_plan_file_copy_handles_a_missing_source(tmp_path: Path) -> None:
    assert plan_file_copy(tmp_path / "nope.txt", tmp_path / "dest.txt") == []


def test_apply_copies_files_and_backs_up_overwrites(tmp_path: Path) -> None:
    install = tmp_path / "_classic_ptr_"
    src = tmp_path / "src"
    write(src / "a.lua", "new content")
    write(install / "Interface" / "a.lua", "old content")

    actions = plan_tree_copy(src, install / "Interface")
    performed, backup = apply_actions(actions, install_path=install, label="copy_addons")

    assert len(performed) == 1
    assert (install / "Interface" / "a.lua").read_text() == "new content"
    assert backup is not None
    assert (backup / "Interface" / "a.lua").read_text() == "old content"


def test_dry_run_writes_nothing(tmp_path: Path) -> None:
    install = tmp_path / "_classic_ptr_"
    install.mkdir()
    src = tmp_path / "src"
    write(src / "a.lua", "new")

    actions = plan_tree_copy(src, install / "Interface")
    performed, backup = apply_actions(actions, install_path=install, label="x", dry_run=True)

    assert performed == []
    assert backup is None
    assert not (install / "Interface").exists()


def test_restore_puts_the_originals_back(tmp_path: Path) -> None:
    install = tmp_path / "_classic_ptr_"
    src = tmp_path / "src"
    write(src / "a.lua", "new")
    write(install / "WTF" / "a.lua", "original")

    apply_actions(plan_tree_copy(src, install / "WTF"), install_path=install, label="step")
    backups = list_backups(install)
    assert len(backups) == 1
    assert backups[0]["file_count"] == 1

    restored = restore_backup(install, backups[0]["id"])
    assert restored == 1
    assert (install / "WTF" / "a.lua").read_text() == "original"


def test_restore_rejects_an_unknown_backup(tmp_path: Path) -> None:
    install = tmp_path / "_classic_ptr_"
    install.mkdir()
    with pytest.raises(FileNotFoundError):
        restore_backup(install, "nope")


def test_writes_outside_the_target_install_are_refused(tmp_path: Path) -> None:
    install = tmp_path / "_classic_ptr_"
    install.mkdir()
    escape = FileAction("create", write(tmp_path / "src.lua", "x"), tmp_path / "elsewhere.lua", 1)
    with pytest.raises(UnsafePathError):
        apply_actions([escape], install_path=install, label="bad")


def test_generated_content_actions_are_written(tmp_path: Path) -> None:
    install = tmp_path / "_classic_ptr_"
    install.mkdir()
    action = FileAction("create", None, install / "WTF" / "Config.wtf", 0, content='SET a "1"\n')
    apply_actions([action], install_path=install, label="config")
    assert (install / "WTF" / "Config.wtf").read_text() == 'SET a "1"\n'


def test_iter_files_returns_sorted_relative_paths(tmp_path: Path) -> None:
    write(tmp_path / "b.lua", "b")
    write(tmp_path / "a" / "c.lua", "c")
    assert [str(p) for p in iter_files(tmp_path)] == [str(Path("a") / "c.lua"), "b.lua"]


def test_is_within(tmp_path: Path) -> None:
    assert is_within(tmp_path / "a" / "b", tmp_path)
    assert not is_within(tmp_path.parent / "other", tmp_path)


def test_human_size() -> None:
    assert human_size(0) == "0 B"
    assert human_size(2048) == "2.0 KB"
