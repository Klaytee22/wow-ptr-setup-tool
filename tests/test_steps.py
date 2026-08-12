from __future__ import annotations

from pathlib import Path

import pytest

from ptrsetup import configwtf
from ptrsetup.detect import find_installs, list_characters
from ptrsetup.session import Session
from ptrsetup.steps import STEPS_BY_ID, CharacterPair, Context, apply_steps

from helpers import make_install


@pytest.fixture
def ctx(wow_root: Path) -> Context:
    """A fully-populated context: both clients, matching accounts, one character pair."""
    installs = find_installs([wow_root])
    source = next(i for i in installs if not i.flavor.is_ptr)
    target = next(i for i in installs if i.flavor.is_ptr)
    account = "12345678#1"
    return Context(
        source=source,
        target=target,
        source_account=account,
        target_account=account,
        characters=[
            CharacterPair(
                source=list_characters(source, account)[0],
                target=list_characters(target, account)[0],
            )
        ],
        options={"overwrite": True, "include_macros_bindings": True, "allow_out_of_date": True},
    )


# -- addons ---------------------------------------------------------------


def test_addons_step_copies_the_whole_folder(ctx: Context) -> None:
    step = STEPS_BY_ID["copy_addons"]
    assert step.status(ctx).state == "ready"
    step.apply(ctx)
    assert ctx.target is not None
    assert (ctx.target.addons / "WeakAuras" / "WeakAuras.toc").is_file()
    assert (ctx.target.addons / "Details" / "Details.lua").is_file()


def test_addons_step_is_a_no_op_once_copied(ctx: Context) -> None:
    step = STEPS_BY_ID["copy_addons"]
    step.apply(ctx)
    ctx.options["overwrite"] = False
    assert all(a.kind == "skip" for a in step.plan(ctx))


# -- Config.wtf -----------------------------------------------------------


def test_config_step_merges_without_stealing_the_realm_list(ctx: Context) -> None:
    STEPS_BY_ID["copy_config_wtf"].apply(ctx)
    assert ctx.target is not None
    written = configwtf.read(ctx.target.config_wtf)
    assert written["gxResolution"] == "2560x1440"
    assert written["realmList"] == "us.logon-ptr.worldofwarcraft.com"
    assert written["checkAddonVersion"] == "0"


def test_config_step_plan_is_empty_when_nothing_would_change(ctx: Context) -> None:
    step = STEPS_BY_ID["copy_config_wtf"]
    step.apply(ctx)
    assert step.plan(ctx) == []


# -- account-level --------------------------------------------------------


def test_account_step_copies_saved_variables_and_caches(ctx: Context) -> None:
    STEPS_BY_ID["copy_account_saved_variables"].apply(ctx)
    account_dir = ctx.target_account_dir()
    assert account_dir is not None
    assert (account_dir / "SavedVariables" / "WeakAuras.lua").is_file()
    assert (account_dir / "macros-cache.txt").is_file()


def test_account_step_respects_the_macros_option(ctx: Context) -> None:
    ctx.options["include_macros_bindings"] = False
    plan = STEPS_BY_ID["copy_account_saved_variables"].plan(ctx)
    assert all("macros-cache" not in a.dest.name for a in plan)


# -- character-level ------------------------------------------------------


def test_character_step_copies_into_the_mapped_ptr_character(ctx: Context) -> None:
    STEPS_BY_ID["copy_character_data"].apply(ctx)
    assert ctx.target is not None
    char_dir = ctx.target.account_root / "12345678#1" / "PTR Whitemane" / "Bankalt"
    assert (char_dir / "SavedVariables" / "WeakAuras.lua").is_file()
    assert (char_dir / "AddOns.txt").is_file()
    assert (char_dir / "layout-local.txt").is_file()


def test_character_step_is_blocked_without_a_mapping(ctx: Context) -> None:
    ctx.characters = []
    status = STEPS_BY_ID["copy_character_data"].status(ctx)
    assert status.state == "blocked"
    assert "character" in status.detail.lower()


# -- addon version check --------------------------------------------------


def test_out_of_date_step_flips_and_then_reports_done(ctx: Context) -> None:
    step = STEPS_BY_ID["allow_out_of_date_addons"]
    assert step.status(ctx).state == "ready"
    step.apply(ctx)
    assert ctx.target is not None
    assert configwtf.read(ctx.target.config_wtf)["checkAddonVersion"] == "0"
    assert step.status(ctx).state == "done"


# -- manual steps ---------------------------------------------------------


def test_manual_step_tracks_the_ptr_wtf_folder(ctx: Context) -> None:
    step = STEPS_BY_ID["install_ptr_client"]
    assert step.status(ctx).state == "done"  # the fixture PTR client has a WTF folder


def test_manual_verify_step_needs_an_acknowledgement(ctx: Context) -> None:
    step = STEPS_BY_ID["verify_in_game"]
    assert step.status(ctx).state == "ready"
    ctx.acknowledged.add(step.id)
    assert step.status(ctx).state == "done"


def test_manual_steps_report_success_without_touching_disk(ctx: Context) -> None:
    result = STEPS_BY_ID["copy_character"].apply(ctx)
    assert result.ok
    assert result.actions == []


# -- the whole run --------------------------------------------------------


def test_dry_run_changes_nothing(ctx: Context) -> None:
    assert ctx.target is not None
    results = apply_steps(ctx, ["copy_addons", "copy_config_wtf"], dry_run=True)
    assert all(r.ok and r.dry_run for r in results)
    assert not (ctx.target.addons / "WeakAuras").exists()


def test_full_run_leaves_every_step_done(ctx: Context) -> None:
    auto_ids = [s.id for s in STEPS_BY_ID.values() if s.mode == "auto"]
    results = apply_steps(ctx, auto_ids)
    assert all(r.ok for r in results)
    for step_id in auto_ids:
        # A second pass has nothing left to do.
        assert STEPS_BY_ID[step_id].plan(ctx) == [] or all(
            a.kind == "overwrite" for a in STEPS_BY_ID[step_id].plan(ctx)
        )


def test_step_serialisation_carries_status_and_preview(ctx: Context) -> None:
    payload = STEPS_BY_ID["copy_addons"].to_dict(ctx)
    assert payload["mode"] == "auto"
    assert payload["action_count"] == 4
    assert payload["bytes"] > 0
    assert payload["preview"][0]["kind"] == "create"


# -- session wiring -------------------------------------------------------


def test_session_autoselects_clients_accounts_and_characters(wow_root: Path) -> None:
    session = Session()
    session.extra_roots = [wow_root]
    session.rescan()
    assert session.ctx.source is not None and session.ctx.target is not None
    assert session.ctx.source_account == session.ctx.target_account == "12345678#1"
    assert [p.target.realm for p in session.ctx.characters] == ["PTR Whitemane"]


def test_changing_the_source_client_clears_stale_mappings(wow_root: Path) -> None:
    session = Session()
    session.extra_roots = [wow_root]
    session.rescan()
    assert session.ctx.target is not None
    session.set_selection(source_id=session.ctx.target.id)
    assert session.ctx.source is not None
    assert session.ctx.source.flavor.is_ptr


# -- status semantics -----------------------------------------------------


def test_a_finished_auto_step_reports_done_not_blocked(ctx: Context) -> None:
    step = STEPS_BY_ID["copy_config_wtf"]
    step.apply(ctx)
    status = step.status(ctx)
    assert status.state == "done"
    assert "up to date" in status.detail


def test_a_step_with_nothing_to_copy_from_reports_blocked(tmp_path: Path) -> None:
    root = tmp_path / "World of Warcraft"
    make_install(root, "_classic_", addons=())
    make_install(root, "_classic_ptr_", addons=())
    installs = find_installs([root])
    ctx = Context(
        source=next(i for i in installs if not i.flavor.is_ptr),
        target=next(i for i in installs if i.flavor.is_ptr),
    )
    status = STEPS_BY_ID["copy_addons"].status(ctx)
    assert status.state == "blocked"
    assert "AddOns" in status.detail


def test_skip_only_plans_report_done(ctx: Context) -> None:
    step = STEPS_BY_ID["copy_addons"]
    step.apply(ctx)
    ctx.options["overwrite"] = False
    assert step.status(ctx).state == "done"


def test_account_step_is_blocked_without_an_account_pair(ctx: Context) -> None:
    ctx.target_account = None
    assert STEPS_BY_ID["copy_account_saved_variables"].status(ctx).state == "blocked"
