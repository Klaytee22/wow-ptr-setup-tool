"""Local web API + wizard.

The whole UI is one page talking to this API. It binds to 127.0.0.1 only — the
tool reads and writes the user's game folders, so it has no business being
reachable from the network.
"""

from __future__ import annotations

from pathlib import Path

from fastapi import Body, FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from . import __version__
from .fsops import UnsafePathError, list_backups, restore_backup
from .session import Session
from .steps import STEPS_BY_ID, apply_steps

WEB_DIR = Path(__file__).parent / "web"


def create_app(session: Session | None = None) -> FastAPI:
    """Build the app. Tests pass their own :class:`Session` to control the state."""
    app = FastAPI(title="WoW PTR UI Setup", version=__version__)
    state = session or Session()
    app.state.session = state

    app.mount("/static", StaticFiles(directory=WEB_DIR / "static"), name="static")

    @app.get("/")
    def index() -> FileResponse:
        return FileResponse(WEB_DIR / "index.html")

    @app.get("/api/state")
    def get_state() -> dict:
        if not state.installs:
            state.rescan()
        return state.snapshot()

    @app.post("/api/rescan")
    def rescan() -> dict:
        state.rescan()
        return state.snapshot()

    @app.post("/api/roots")
    def add_root(payload: dict = Body(...)) -> dict:
        path = str(payload.get("path", "")).strip()
        if not path:
            raise HTTPException(status_code=400, detail="A folder path is required.")
        if not Path(path).expanduser().is_dir():
            raise HTTPException(status_code=404, detail=f"No folder at {path}")
        state.add_root(path)
        return state.snapshot()

    @app.post("/api/selection")
    def set_selection(payload: dict = Body(default={})) -> dict:
        state.set_selection(
            source_id=payload.get("source_id"),
            target_id=payload.get("target_id"),
            source_account=payload.get("source_account"),
            target_account=payload.get("target_account"),
            characters=payload.get("characters"),
            options=payload.get("options"),
        )
        return state.snapshot()

    @app.post("/api/steps/{step_id}/ack")
    def acknowledge(step_id: str, payload: dict = Body(default={})) -> dict:
        if step_id not in STEPS_BY_ID:
            raise HTTPException(status_code=404, detail=f"Unknown step {step_id}")
        state.acknowledge(step_id, bool(payload.get("done", True)))
        return state.snapshot()

    @app.post("/api/apply")
    def apply(payload: dict = Body(default={})) -> dict:
        step_ids = list(payload.get("step_ids") or [])
        dry_run = bool(payload.get("dry_run", False))
        unknown = [s for s in step_ids if s not in STEPS_BY_ID]
        if unknown:
            raise HTTPException(status_code=400, detail=f"Unknown step(s): {', '.join(unknown)}")
        if not state.ctx.ready:
            raise HTTPException(status_code=400, detail="Pick a live client and a PTR client first.")
        try:
            results = apply_steps(state.ctx, step_ids, dry_run=dry_run)
        except UnsafePathError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {"results": [r.to_dict() for r in results], "state": state.snapshot()}

    @app.get("/api/backups")
    def backups() -> dict:
        if not state.ctx.target:
            return {"backups": []}
        return {"backups": list_backups(state.ctx.target.path)}

    @app.post("/api/backups/{backup_id}/restore")
    def restore(backup_id: str) -> dict:
        if not state.ctx.target:
            raise HTTPException(status_code=400, detail="No PTR client selected.")
        try:
            count = restore_backup(state.ctx.target.path, backup_id)
        except FileNotFoundError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        return {"restored": count, "state": state.snapshot()}

    return app
