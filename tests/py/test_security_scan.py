# -*- coding: utf-8 -*-
"""安全扫描入口的契约测试。

重点验证「只报告不处置」这条安全边界：
  - 缺 path / scope 非法 / 未确认处置，一律 400，不得起扫描
  - 正常参数在 mock 掉 worker 后返回 started=true（不真跑 KVRT）
"""
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "app"))

import server  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

BASE = "http://127.0.0.1"


@pytest.fixture
def client():
    c = TestClient(server.app, base_url=BASE)
    c.headers.update({"X-PF-Token": server._token()})
    return c


@pytest.fixture(autouse=True)
def reset_scan_state():
    server._SCAN_STATE.update({"running": False, "result": None, "error": "",
                               "scope": "", "path": "", "started": "", "finished": ""})
    yield


@pytest.fixture
def no_real_scan(monkeypatch):
    """把真正的扫描线程换成空实现，测试不碰 KVRT。"""
    calls = []

    def fake_worker(scope, path, level, timeout, accept_eula=False):
        calls.append({"scope": scope, "path": path, "level": level,
                      "timeout": timeout, "accept_eula": accept_eula})

    monkeypatch.setattr(server, "_scan_worker", fake_worker)
    return calls


def test_scan_status_is_readable(client):
    r = client.get("/api/security/scan/status")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["running"] is False
    assert "engine" in body


def test_scan_requires_token():
    anon = TestClient(server.app, base_url=BASE)
    assert anon.get("/api/security/scan/status").status_code == 401
    assert anon.post("/api/security/scan", json={}).status_code == 401


def test_custom_scope_requires_absolute_path(client, no_real_scan):
    r = client.post("/api/security/scan", json={"scope": "custom", "accept_eula": True})
    assert r.status_code == 400
    assert "path" in r.text

    r = client.post("/api/security/scan",
                    json={"scope": "custom", "path": "relative\\a.exe",
                          "accept_eula": True})
    assert r.status_code == 400
    assert "绝对路径" in r.text


def test_bad_scope_rejected(client, no_real_scan):
    r = client.post("/api/security/scan",
                    json={"scope": "everything", "accept_eula": True})
    assert r.status_code == 400
    assert "custom" in r.text


def test_bad_process_level_rejected(client, no_real_scan):
    r = client.post("/api/security/scan",
                    json={"scope": "core", "process_level": 9, "accept_eula": True})
    assert r.status_code == 400


def test_scan_requires_explicit_eula(client, no_real_scan):
    """不代替用户接受协议：缺省、false、字符串 "true" 都不行。"""
    for body in ({"scope": "core"},
                 {"scope": "core", "accept_eula": False},
                 {"scope": "core", "accept_eula": "true"}):
        r = client.post("/api/security/scan", json=body)
        assert r.status_code == 400, body
        assert "EULA" in r.text


def test_disinfect_requires_second_consent(client, no_real_scan):
    """处置是不可逆动作：process_level>0 必须显式 disinfect_confirm=yes。"""
    r = client.post("/api/security/scan",
                    json={"scope": "core", "process_level": 2,
                          "accept_eula": True})
    assert r.status_code == 400
    assert "disinfect_confirm" in r.text

    r = client.post("/api/security/scan",
                    json={"scope": "core", "process_level": 2,
                          "disinfect_confirm": "yes", "accept_eula": True})
    assert r.status_code == 200


def test_scan_start_ok(client, no_real_scan):
    r = client.post("/api/security/scan",
                    json={"scope": "core", "accept_eula": True})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True and body["started"] is True
    assert body["process_level"] == 0            # 默认只报告
    assert body["accept_eula"] is True
    assert no_real_scan[-1]["level"] == 0
    assert no_real_scan[-1]["accept_eula"] is True


def test_scan_single_flight(client, no_real_scan):
    """扫描进行中再发起，必须 409，不能并发两个。"""
    server._SCAN_STATE["running"] = True
    r = client.post("/api/security/scan",
                    json={"scope": "core", "accept_eula": True})
    assert r.status_code == 409


def test_timeout_is_clamped(client, no_real_scan):
    r = client.post("/api/security/scan",
                    json={"scope": "core", "timeout_sec": 999999,
                          "accept_eula": True})
    assert r.status_code == 200
    assert r.json()["timeout_sec"] == 14400

    server._SCAN_STATE["running"] = False
    r = client.post("/api/security/scan",
                    json={"scope": "core", "timeout_sec": 1,
                          "accept_eula": True})
    assert r.json()["timeout_sec"] == 30
