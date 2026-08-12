"""Core value types shared by detection, the step engine and the web API.

Everything here is a plain dataclass with a ``to_dict`` so the FastAPI layer can
hand it straight to the browser without a serialisation library.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------
# Client flavors
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Flavor:
    """One WoW client folder that can sit inside a ``World of Warcraft`` install.

    ``line`` groups a live client with its PTR counterpart: ``_classic_`` and
    ``_classic_ptr_`` are both on the ``classic`` line, so the tool can suggest a
    source/target pair without the user thinking about folder names.
    """

    dirname: str
    label: str
    line: str
    is_ptr: bool


FLAVORS: tuple[Flavor, ...] = (
    Flavor("_retail_", "Retail", "retail", False),
    Flavor("_ptr_", "Retail PTR", "retail", True),
    Flavor("_xptr_", "Retail PTR 2", "retail", True),
    Flavor("_beta_", "Retail Beta", "retail", True),
    Flavor("_classic_", "Classic", "classic", False),
    Flavor("_classic_ptr_", "Classic PTR", "classic", True),
    Flavor("_classic_beta_", "Classic Beta", "classic", True),
    Flavor("_classic_era_", "Classic Era", "era", False),
    Flavor("_classic_era_ptr_", "Classic Era PTR", "era", True),
    Flavor("_classic_era_beta_", "Classic Era Beta", "era", True),
)

FLAVORS_BY_DIR: dict[str, Flavor] = {f.dirname: f for f in FLAVORS}


# --------------------------------------------------------------------------
# Installs and their contents
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Install:
    """A single client folder, e.g. ``.../World of Warcraft/_classic_ptr_``."""

    path: Path
    flavor: Flavor

    @property
    def id(self) -> str:
        return str(self.path)

    @property
    def root(self) -> Path:
        """The parent ``World of Warcraft`` folder holding every flavor."""
        return self.path.parent

    @property
    def wtf(self) -> Path:
        return self.path / "WTF"

    @property
    def account_root(self) -> Path:
        return self.wtf / "Account"

    @property
    def config_wtf(self) -> Path:
        return self.wtf / "Config.wtf"

    @property
    def addons(self) -> Path:
        return self.path / "Interface" / "AddOns"

    @property
    def has_been_launched(self) -> bool:
        """A client only grows its ``WTF`` tree once it has been run at least once."""
        return self.wtf.is_dir()

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "path": str(self.path),
            "label": self.flavor.label,
            "dirname": self.flavor.dirname,
            "line": self.flavor.line,
            "is_ptr": self.flavor.is_ptr,
            "has_been_launched": self.has_been_launched,
            "has_addons": self.addons.is_dir(),
        }


@dataclass(frozen=True)
class CharacterRef:
    """A ``WTF/Account/<ACCOUNT>/<Realm>/<Character>`` triple."""

    account: str
    realm: str
    name: str

    @property
    def id(self) -> str:
        return f"{self.account}/{self.realm}/{self.name}"

    def to_dict(self) -> dict:
        return {"id": self.id, "account": self.account, "realm": self.realm, "name": self.name}


# --------------------------------------------------------------------------
# File operations
# --------------------------------------------------------------------------


@dataclass
class FileAction:
    """One planned filesystem change, previewable before anything is written.

    Most actions copy ``source`` to ``dest``. A step that generates a file
    instead (the ``Config.wtf`` merge) leaves ``source`` empty and supplies
    ``content``, which the applier writes verbatim.
    """

    kind: str  # "create" | "overwrite" | "skip"
    source: Path | None
    dest: Path
    size: int = 0
    note: str = ""
    content: str | None = None

    def to_dict(self) -> dict:
        return {
            "kind": self.kind,
            "source": str(self.source) if self.source else None,
            "dest": str(self.dest),
            "size": self.size,
            "note": self.note,
        }


@dataclass
class StepStatus:
    """Where a step currently stands, recomputed on every plan refresh."""

    state: str  # "blocked" | "ready" | "done"
    detail: str = ""

    def to_dict(self) -> dict:
        return {"state": self.state, "detail": self.detail}


@dataclass
class StepResult:
    """Outcome of applying one step."""

    step_id: str
    ok: bool
    dry_run: bool
    message: str
    actions: list[FileAction] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "step_id": self.step_id,
            "ok": self.ok,
            "dry_run": self.dry_run,
            "message": self.message,
            "actions": [a.to_dict() for a in self.actions],
            "counts": {
                "create": sum(1 for a in self.actions if a.kind == "create"),
                "overwrite": sum(1 for a in self.actions if a.kind == "overwrite"),
                "skip": sum(1 for a in self.actions if a.kind == "skip"),
            },
        }
