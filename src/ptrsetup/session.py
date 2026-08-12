"""In-process state for one run of the wizard.

The tool is a single-user local app, so state lives in memory for the lifetime
of the process. Everything that matters is on disk anyway — the session just
remembers what the user picked and re-derives the rest on every refresh.
"""

from __future__ import annotations

from pathlib import Path

from .detect import find_installs, list_accounts, list_characters, suggest_pair
from .models import CharacterRef, Install
from .steps import STEPS, CharacterPair, Context

DEFAULT_OPTIONS: dict[str, bool] = {
    "overwrite": True,
    "include_macros_bindings": True,
    "include_chat_cache": False,
    "allow_out_of_date": True,
}


class Session:
    """Holds the selection and re-scans installs on demand."""

    def __init__(self) -> None:
        self.extra_roots: list[Path] = []
        self.installs: list[Install] = []
        self.ctx = Context(options=dict(DEFAULT_OPTIONS))
        self._autoselected = False

    # -- scanning ----------------------------------------------------------

    def rescan(self) -> list[Install]:
        self.installs = find_installs(self.extra_roots)
        self._reconcile_selection()
        if not self._autoselected:
            self.autoselect()
        return self.installs

    def add_root(self, path: str) -> list[Install]:
        candidate = Path(path).expanduser()
        if candidate.is_dir() and candidate not in self.extra_roots:
            self.extra_roots.append(candidate)
        return self.rescan()

    def install_by_id(self, install_id: str | None) -> Install | None:
        if not install_id:
            return None
        for install in self.installs:
            if install.id == install_id:
                return install
        return None

    def _reconcile_selection(self) -> None:
        """Drop selections whose folders vanished between scans."""
        ids = {i.id for i in self.installs}
        if self.ctx.source and self.ctx.source.id not in ids:
            self.ctx.source = None
        if self.ctx.target and self.ctx.target.id not in ids:
            self.ctx.target = None

    # -- selection ---------------------------------------------------------

    def autoselect(self) -> None:
        """Best-guess a full selection so the wizard opens with something useful."""
        source, target = suggest_pair(self.installs)
        self.ctx.source = self.ctx.source or source
        self.ctx.target = self.ctx.target or target
        self._autoselected = bool(self.ctx.source or self.ctx.target)
        self.autoselect_accounts()
        self.autoselect_characters()

    def autoselect_accounts(self) -> None:
        if self.ctx.source and not self.ctx.source_account:
            accounts = list_accounts(self.ctx.source)
            self.ctx.source_account = accounts[0] if accounts else None
        if self.ctx.target and not self.ctx.target_account:
            accounts = list_accounts(self.ctx.target)
            if self.ctx.source_account in accounts:
                self.ctx.target_account = self.ctx.source_account
            else:
                self.ctx.target_account = accounts[0] if accounts else None

    def autoselect_characters(self) -> None:
        """Pair live and PTR characters by name — realms rarely match, names do."""
        if self.ctx.characters:
            return
        source_chars = self.source_characters()
        target_chars = self.target_characters()
        if not source_chars or not target_chars:
            return
        by_name: dict[str, CharacterRef] = {}
        for char in source_chars:
            by_name.setdefault(char.name.lower(), char)
        pairs = []
        for target in target_chars:
            match = by_name.get(target.name.lower())
            if match:
                pairs.append(CharacterPair(source=match, target=target))
        self.ctx.characters = pairs

    def set_selection(
        self,
        *,
        source_id: str | None = None,
        target_id: str | None = None,
        source_account: str | None = None,
        target_account: str | None = None,
        characters: list[dict] | None = None,
        options: dict[str, bool] | None = None,
    ) -> None:
        if source_id is not None:
            new_source = self.install_by_id(source_id)
            if new_source != self.ctx.source:
                self.ctx.source = new_source
                self.ctx.source_account = None
                self.ctx.characters = []
        if target_id is not None:
            new_target = self.install_by_id(target_id)
            if new_target != self.ctx.target:
                self.ctx.target = new_target
                self.ctx.target_account = None
                self.ctx.characters = []
        if source_account is not None:
            self.ctx.source_account = source_account or None
            self.ctx.characters = []
        if target_account is not None:
            self.ctx.target_account = target_account or None
            self.ctx.characters = []
        if characters is not None:
            self.ctx.characters = [
                CharacterPair(
                    source=CharacterRef(**pair["source"]),
                    target=CharacterRef(**pair["target"]),
                )
                for pair in characters
            ]
        if options is not None:
            self.ctx.options.update({k: bool(v) for k, v in options.items()})

        self.autoselect_accounts()
        self.autoselect_characters()

    def acknowledge(self, step_id: str, done: bool) -> None:
        if done:
            self.ctx.acknowledged.add(step_id)
        else:
            self.ctx.acknowledged.discard(step_id)

    # -- derived views -----------------------------------------------------

    def source_characters(self) -> list[CharacterRef]:
        if self.ctx.source and self.ctx.source_account:
            return list_characters(self.ctx.source, self.ctx.source_account)
        return []

    def target_characters(self) -> list[CharacterRef]:
        if self.ctx.target and self.ctx.target_account:
            return list_characters(self.ctx.target, self.ctx.target_account)
        return []

    def snapshot(self) -> dict:
        """Everything the browser needs to render the whole wizard in one payload."""
        return {
            "installs": [i.to_dict() for i in self.installs],
            "extra_roots": [str(p) for p in self.extra_roots],
            "selection": self.ctx.to_dict(),
            "accounts": {
                "source": list_accounts(self.ctx.source) if self.ctx.source else [],
                "target": list_accounts(self.ctx.target) if self.ctx.target else [],
            },
            "characters": {
                "source": [c.to_dict() for c in self.source_characters()],
                "target": [c.to_dict() for c in self.target_characters()],
            },
            "steps": [s.to_dict(self.ctx) for s in STEPS],
        }
