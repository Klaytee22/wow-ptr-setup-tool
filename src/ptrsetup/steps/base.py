"""The step engine.

A step is one item in the guide. Both kinds live behind the same interface so
the wizard can render them in one list:

``auto``
    The tool can do it. ``plan()`` returns the file actions; ``apply()``
    performs them (or previews them with ``dry_run``).
``manual``
    Only the player can do it — installing the PTR client, running a character
    copy. The step supplies instructions and a ``status()`` check that watches
    the filesystem so the wizard can tick it off on its own once it's done.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from ..models import CharacterRef, FileAction, Install, StepResult, StepStatus

AUTO = "auto"
MANUAL = "manual"


@dataclass
class CharacterPair:
    """A live character mapped onto the PTR character it should feed.

    Realm names differ between live and PTR, and a copied character can land on
    a differently named realm, so the mapping is explicit rather than inferred.
    """

    source: CharacterRef
    target: CharacterRef

    def to_dict(self) -> dict:
        return {"source": self.source.to_dict(), "target": self.target.to_dict()}


@dataclass
class Context:
    """Everything a step needs to know: what to copy, where, and how."""

    source: Install | None = None
    target: Install | None = None
    source_account: str | None = None
    target_account: str | None = None
    characters: list[CharacterPair] = field(default_factory=list)
    options: dict[str, bool] = field(default_factory=dict)
    acknowledged: set[str] = field(default_factory=set)

    def option(self, key: str, default: bool = True) -> bool:
        return self.options.get(key, default)

    @property
    def ready(self) -> bool:
        return self.source is not None and self.target is not None

    def source_account_dir(self) -> Path | None:
        if self.source and self.source_account:
            return self.source.account_root / self.source_account
        return None

    def target_account_dir(self) -> Path | None:
        if self.target and self.target_account:
            return self.target.account_root / self.target_account
        return None

    def to_dict(self) -> dict:
        return {
            "source": self.source.to_dict() if self.source else None,
            "target": self.target.to_dict() if self.target else None,
            "source_account": self.source_account,
            "target_account": self.target_account,
            "characters": [c.to_dict() for c in self.characters],
            "options": self.options,
            "acknowledged": sorted(self.acknowledged),
        }


class Step:
    """Base class for both automated and manual steps."""

    id: str = ""
    title: str = ""
    summary: str = ""
    mode: str = AUTO
    #: Markdown shown in the step card — the hand-holding half of the tool.
    instructions: str = ""
    #: Where this step came from, so a reader can check it against the guide.
    source_note: str = ""

    # -- overridable hooks -------------------------------------------------

    def plan(self, ctx: Context) -> list[FileAction]:
        """File actions this step would perform. Manual steps return nothing."""
        return []

    def prerequisites(self, ctx: Context) -> str | None:
        """Why this step cannot run yet, or ``None`` if it can.

        Distinguishes "there is nothing to copy from" (blocked) from "everything
        is already copied" (done) — an empty plan means the second only once the
        prerequisites are satisfied.
        """
        if not ctx.ready:
            return "Pick a live client and a PTR client first."
        return None

    def status(self, ctx: Context) -> StepStatus:
        """Recomputed on every refresh; drives the tick marks in the wizard."""
        if self.mode == MANUAL:
            done = self.id in ctx.acknowledged
            return StepStatus("done" if done else "ready")
        blocker = self.prerequisites(ctx)
        if blocker:
            return StepStatus("blocked", blocker)
        actions = self.plan(ctx)
        if not actions:
            return StepStatus("done", "Already up to date — nothing left to copy.")
        if all(a.kind == "skip" for a in actions):
            return StepStatus("done", "Every file is already on the PTR.")
        return StepStatus("ready", f"{len(actions)} file(s) to copy.")

    def apply(self, ctx: Context, *, dry_run: bool = False) -> StepResult:
        """Run the step. Automated steps copy; manual steps just record the ack."""
        if self.mode == MANUAL:
            return StepResult(self.id, True, dry_run, "Manual step — nothing to automate.")

        from ..fsops import apply_actions  # local import keeps the module graph acyclic

        if not ctx.ready or ctx.target is None:
            return StepResult(self.id, False, dry_run, "No source/target selected.")

        actions = self.plan(ctx)
        if not actions:
            return StepResult(self.id, True, dry_run, "Nothing to do.")

        performed, backup = apply_actions(
            actions,
            install_path=ctx.target.path,
            label=self.id,
            dry_run=dry_run,
        )
        if dry_run:
            return StepResult(self.id, True, True, f"Preview: {len(actions)} file(s).", actions)
        message = f"Copied {len(performed)} file(s)."
        if backup:
            message += f" Overwritten files backed up to {backup.name}."
        return StepResult(self.id, True, False, message, actions)

    def to_dict(self, ctx: Context) -> dict:
        status = self.status(ctx)
        actions = self.plan(ctx) if self.mode == AUTO and ctx.ready else []
        return {
            "id": self.id,
            "title": self.title,
            "summary": self.summary,
            "mode": self.mode,
            "instructions": self.instructions,
            "source_note": self.source_note,
            "status": status.to_dict(),
            "action_count": len(actions),
            "bytes": sum(a.size for a in actions),
            "preview": [a.to_dict() for a in actions[:40]],
            "preview_truncated": len(actions) > 40,
        }
