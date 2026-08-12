from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from ptrsetup.app import create_app
from ptrsetup.session import Session


@pytest.fixture
def client(wow_root: Path) -> TestClient:
    session = Session()
    session.extra_roots = [wow_root]
    session.rescan()
    return TestClient(create_app(session))


def test_index_serves_the_wizard(client: TestClient) -> None:
    response = client.get("/")
    assert response.status_code == 200
    assert "WoW PTR UI Setup" in response.text


def test_state_returns_installs_selection_and_steps(client: TestClient) -> None:
    state = client.get("/api/state").json()
    assert len(state["installs"]) == 2
    assert state["selection"]["source"]["dirname"] == "_classic_"
    assert state["selection"]["target"]["dirname"] == "_classic_ptr_"
    assert {s["id"] for s in state["steps"]} >= {"copy_addons", "verify_in_game"}


def test_options_can_be_toggled(client: TestClient) -> None:
    state = client.post("/api/selection", json={"options": {"include_chat_cache": True}}).json()
    assert state["selection"]["options"]["include_chat_cache"] is True


def test_manual_steps_can_be_acknowledged(client: TestClient) -> None:
    state = client.post("/api/steps/verify_in_game/ack", json={"done": True}).json()
    step = next(s for s in state["steps"] if s["id"] == "verify_in_game")
    assert step["status"]["state"] == "done"


def test_unknown_step_ids_are_rejected(client: TestClient) -> None:
    assert client.post("/api/steps/nope/ack", json={"done": True}).status_code == 404
    assert client.post("/api/apply", json={"step_ids": ["nope"]}).status_code == 400


def test_dry_run_apply_reports_without_writing(client: TestClient, wow_root: Path) -> None:
    body = client.post("/api/apply", json={"step_ids": ["copy_addons"], "dry_run": True}).json()
    assert body["results"][0]["ok"] is True
    assert body["results"][0]["dry_run"] is True
    assert not (wow_root / "_classic_ptr_" / "Interface" / "AddOns" / "WeakAuras").exists()


def test_apply_copies_and_then_lists_a_backup(client: TestClient, wow_root: Path) -> None:
    client.post("/api/apply", json={"step_ids": ["copy_addons", "copy_config_wtf"]})
    assert (wow_root / "_classic_ptr_" / "Interface" / "AddOns" / "WeakAuras").is_dir()

    backups = client.get("/api/backups").json()["backups"]
    assert [b["label"] for b in backups] == ["copy_config_wtf"]

    restored = client.post(f"/api/backups/{backups[0]['id']}/restore").json()
    assert restored["restored"] == 1


def test_adding_a_missing_folder_path_404s(client: TestClient, tmp_path: Path) -> None:
    response = client.post("/api/roots", json={"path": str(tmp_path / "nowhere")})
    assert response.status_code == 404


def test_apply_requires_a_selection(wow_root: Path) -> None:
    empty = TestClient(create_app(Session()))
    response = empty.post("/api/apply", json={"step_ids": ["copy_addons"]})
    assert response.status_code == 400
