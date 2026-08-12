"""The actual steps of "get my live UI onto the PTR", in the order they happen.

Each class documents what it does and — in ``source_note`` — where the step came
from, so the list can be checked against the written guide it mirrors. Adding a
step means writing a class here and appending it to :data:`STEPS`; nothing else
in the app needs to change.
"""

from __future__ import annotations

from .. import configwtf
from ..detect import character_dir
from ..fsops import plan_file_copy, plan_tree_copy
from ..models import FileAction, StepResult, StepStatus
from .base import AUTO, MANUAL, Context, Step

# Per-character files that carry UI state alongside SavedVariables.
CHARACTER_LAYOUT_FILES = ("AddOns.txt", "layout-local.txt")
CHARACTER_EXTRA_FILES = ("macros-cache.txt", "bindings-cache.wtf")
ACCOUNT_EXTRA_FILES = ("macros-cache.txt", "bindings-cache.wtf", "config-cache.wtf")


class InstallPtrClient(Step):
    id = "install_ptr_client"
    title = "Install and launch the PTR client once"
    summary = (
        "The PTR builds its own WTF and Interface folders on first launch — "
        "nothing can be copied before that."
    )
    mode = MANUAL
    source_note = "Standard prerequisite: the folders this tool writes into do not exist until first launch."
    instructions = """
1. Open the **Battle.net launcher**.
2. In the game dropdown above the Play button, choose the **PTR** version of your client.
3. Install it if you have not already, then **launch it once** and sit at the character screen.
4. Quit the PTR client before continuing — WoW rewrites `WTF` on exit and would undo the copy.
""".strip()

    def status(self, ctx: Context) -> StepStatus:
        if ctx.target is None:
            return StepStatus("blocked", "No PTR client selected yet.")
        if not ctx.target.has_been_launched:
            return StepStatus(
                "ready",
                f"No WTF folder in {ctx.target.path.name} yet — launch the PTR client once.",
            )
        return StepStatus("done", f"{ctx.target.path.name} has a WTF folder.")


class CopyCharacter(Step):
    id = "copy_character"
    title = "Copy your character to the PTR"
    summary = "Per-character settings can only land once the character exists on a PTR realm."
    mode = MANUAL
    source_note = "Prerequisite for the per-character step; the copy itself happens on Blizzard's side."
    instructions = """
1. Log into the **PTR client** and pick a PTR realm.
2. At the character-select screen use **Copy Character** (or the character-copy page on the
   PTR website, depending on the season) and copy your live character across.
3. Log in as the copied character once, then **quit the client**.
4. Come back here and press **Rescan** — the character will show up in the mapping list.
""".strip()

    def status(self, ctx: Context) -> StepStatus:
        if self.id in ctx.acknowledged:
            return StepStatus("done", "Marked done.")
        if ctx.characters:
            return StepStatus("done", f"{len(ctx.characters)} character(s) mapped.")
        return StepStatus("ready", "No PTR characters found yet.")


class CopyAddons(Step):
    id = "copy_addons"
    title = "Copy your addons"
    summary = "Copies Interface/AddOns from the live client to the PTR client."
    mode = AUTO
    source_note = "The addon folder itself — without it, the copied settings have nothing to configure."
    instructions = (
        "Addons are plain folders, so this is a straight copy. Anything already on the PTR with "
        "the same name is backed up first, so a newer PTR-specific build can be restored."
    )

    def prerequisites(self, ctx: Context) -> str | None:
        blocker = super().prerequisites(ctx)
        if blocker:
            return blocker
        assert ctx.source is not None
        if not ctx.source.addons.is_dir():
            return f"No Interface/AddOns folder in {ctx.source.path.name}."
        return None

    def plan(self, ctx: Context) -> list[FileAction]:
        if not ctx.ready or ctx.source is None or ctx.target is None:
            return []
        return plan_tree_copy(
            ctx.source.addons,
            ctx.target.addons,
            overwrite=ctx.option("overwrite", True),
        )


class CopyConfigWtf(Step):
    id = "copy_config_wtf"
    title = "Carry over Config.wtf"
    summary = "Merges the live client's video, sound and interface cvars into the PTR's Config.wtf."
    mode = AUTO
    source_note = "Config.wtf holds the client-wide settings — resolution, window mode, and friends."
    instructions = (
        "This is a merge rather than a copy: realm and account keys stay on the PTR's own values so "
        "the PTR client keeps pointing at PTR realms. Everything else comes from your live client."
    )

    def prerequisites(self, ctx: Context) -> str | None:
        blocker = super().prerequisites(ctx)
        if blocker:
            return blocker
        assert ctx.source is not None
        if not ctx.source.config_wtf.is_file():
            return f"No Config.wtf in {ctx.source.path.name} — launch the live client once."
        return None

    def _merged(self, ctx: Context) -> tuple[dict[str, str], dict[str, str]]:
        assert ctx.source and ctx.target
        source = configwtf.read(ctx.source.config_wtf)
        target = configwtf.read(ctx.target.config_wtf)
        overrides: dict[str, str] = {}
        if ctx.option("allow_out_of_date", True):
            overrides["checkAddonVersion"] = "0"
        return target, configwtf.merge(source, target, overrides=overrides)

    def plan(self, ctx: Context) -> list[FileAction]:
        if not ctx.ready or ctx.source is None or ctx.target is None:
            return []
        if not ctx.source.config_wtf.is_file():
            return []
        before, after = self._merged(ctx)
        if before == after:
            return []
        text = configwtf.render(after)
        kind = "overwrite" if ctx.target.config_wtf.exists() else "create"
        changes = configwtf.diff(before, after)
        note = ", ".join(f"{c['key']}={c['after']}" for c in changes[:6])
        if len(changes) > 6:
            note += f", +{len(changes) - 6} more"
        return [
            FileAction(
                kind,
                None,
                ctx.target.config_wtf,
                len(text.encode("utf-8")),
                note or "no changes",
                content=text,
            )
        ]

    def config_diff(self, ctx: Context) -> list[dict[str, str]]:
        """Key-by-key preview, rendered as a table in the wizard."""
        if not ctx.ready or ctx.source is None or not ctx.source.config_wtf.is_file():
            return []
        before, after = self._merged(ctx)
        return configwtf.diff(before, after)


class CopyAccountSavedVariables(Step):
    id = "copy_account_saved_variables"
    title = "Copy account-wide addon settings"
    summary = "Copies WTF/Account/<ACCOUNT>/SavedVariables — the profiles shared by all your characters."
    mode = AUTO
    source_note = "Account-level SavedVariables: where most addons keep their profiles."
    instructions = (
        "Your live and PTR account folder names are usually identical, but if they differ pick the "
        "right pair above — copying into the wrong account folder silently does nothing in game."
    )

    def prerequisites(self, ctx: Context) -> str | None:
        blocker = super().prerequisites(ctx)
        if blocker:
            return blocker
        if not ctx.source_account or not ctx.target_account:
            return "Pick an account folder on both clients first."
        return None

    def plan(self, ctx: Context) -> list[FileAction]:
        src_dir = ctx.source_account_dir()
        dst_dir = ctx.target_account_dir()
        if not src_dir or not dst_dir:
            return []
        actions = plan_tree_copy(
            src_dir / "SavedVariables",
            dst_dir / "SavedVariables",
            overwrite=ctx.option("overwrite", True),
        )
        if ctx.option("include_macros_bindings", True):
            for name in ACCOUNT_EXTRA_FILES:
                actions += plan_file_copy(
                    src_dir / name, dst_dir / name, overwrite=ctx.option("overwrite", True)
                )
        return actions


class CopyCharacterData(Step):
    id = "copy_character_data"
    title = "Copy per-character settings"
    summary = "Copies each mapped character's SavedVariables, addon list and frame layout."
    mode = AUTO
    source_note = "Character-level SavedVariables, plus the layout files that make the UI come up arranged."
    instructions = (
        "Each row maps one live character onto one PTR character. Realm names differ between live "
        "and PTR, so check the mapping before applying — data lands in the PTR character's folder."
    )

    def plan(self, ctx: Context) -> list[FileAction]:
        if not ctx.ready or ctx.source is None or ctx.target is None:
            return []
        overwrite = ctx.option("overwrite", True)
        actions: list[FileAction] = []
        for pair in ctx.characters:
            src_dir = character_dir(ctx.source, pair.source)
            dst_dir = character_dir(ctx.target, pair.target)
            actions += plan_tree_copy(
                src_dir / "SavedVariables", dst_dir / "SavedVariables", overwrite=overwrite
            )
            names = list(CHARACTER_LAYOUT_FILES)
            if ctx.option("include_macros_bindings", True):
                names += list(CHARACTER_EXTRA_FILES)
            if ctx.option("include_chat_cache", False):
                names.append("chat-cache.txt")
            for name in names:
                actions += plan_file_copy(src_dir / name, dst_dir / name, overwrite=overwrite)
        return actions

    def prerequisites(self, ctx: Context) -> str | None:
        blocker = super().prerequisites(ctx)
        if blocker:
            return blocker
        if not ctx.characters:
            return "Map at least one character first."
        return None


class AllowOutOfDateAddons(Step):
    id = "allow_out_of_date_addons"
    title = "Allow out-of-date addons"
    summary = 'Sets checkAddonVersion "0" so addons built for live still load on the PTR.'
    mode = AUTO
    source_note = "PTR runs a higher interface version, so every copied addon reads as out of date."
    instructions = (
        "Equivalent to ticking **Load out of date AddOns** on the character-select addon list, but "
        "set directly in Config.wtf so it survives the copy."
    )

    def plan(self, ctx: Context) -> list[FileAction]:
        if not ctx.ready or ctx.target is None:
            return []
        current = configwtf.read(ctx.target.config_wtf)
        if current.get("checkAddonVersion") == "0":
            return []
        merged = dict(current)
        merged["checkAddonVersion"] = "0"
        text = configwtf.render(merged)
        kind = "overwrite" if ctx.target.config_wtf.exists() else "create"
        return [
            FileAction(
                kind,
                None,
                ctx.target.config_wtf,
                len(text.encode("utf-8")),
                'checkAddonVersion "0"',
                content=text,
            )
        ]

    def status(self, ctx: Context) -> StepStatus:
        blocker = self.prerequisites(ctx)
        if blocker:
            return StepStatus("blocked", blocker)
        assert ctx.target is not None
        if configwtf.read(ctx.target.config_wtf).get("checkAddonVersion") == "0":
            return StepStatus("done", "Already enabled on the PTR client.")
        return StepStatus("ready", "Will set checkAddonVersion to 0.")


class VerifyInGame(Step):
    id = "verify_in_game"
    title = "Launch the PTR and check the UI"
    summary = "Confirm the addons loaded and your layout came across."
    mode = MANUAL
    source_note = "Closing check — the copy is only good if the client comes up with it."
    instructions = """
1. Launch the **PTR client** and log in on the copied character.
2. At character select, open **AddOns** and confirm your list is there and enabled.
3. In game, run `/reload` once — some addons only settle their profile on a reload.
4. If something is missing, come back and use **Restore a backup** to undo, then re-apply
   with the affected step ticked on.
""".strip()

    def status(self, ctx: Context) -> StepStatus:
        return StepStatus("done" if self.id in ctx.acknowledged else "ready")


STEPS: tuple[Step, ...] = (
    InstallPtrClient(),
    CopyCharacter(),
    CopyAddons(),
    CopyConfigWtf(),
    CopyAccountSavedVariables(),
    CopyCharacterData(),
    AllowOutOfDateAddons(),
    VerifyInGame(),
)

STEPS_BY_ID: dict[str, Step] = {s.id: s for s in STEPS}


def apply_steps(ctx: Context, step_ids: list[str], *, dry_run: bool = False) -> list[StepResult]:
    """Run the named steps in canonical order, skipping unknown ids."""
    wanted = [s for s in STEPS if s.id in set(step_ids)]
    return [s.apply(ctx, dry_run=dry_run) for s in wanted]
