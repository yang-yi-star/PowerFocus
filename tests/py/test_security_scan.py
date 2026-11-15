# -*- coding: utf-8 -*-
"""安全扫描入口的契约测试。

重点验证「只报告不处置」这条安全边界：
  - 缺 path / scope 非法 / 未确认处置，一律 400，不得起扫描
  - 正常参数在 mock 掉 worker 后返回 started=true（不真跑 KVRT）
"""
import sys
import time
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

    def fake_worker(scope, path, level, timeout):
        calls.append({"scope": scope, "path": path,
                      "level": level, "timeout": timeout})

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
    r = client.post("/api/security/scan", json={"scope": "custom"})
    assert r.status_code == 400
    assert "path" in r.text

    r = client.post("/api/security/scan",
                    json={"scope": "custom", "path": "relative\\a.exe"})
    assert r.status_code == 400
    assert "绝对路径" in r.text


def test_bad_scope_rejected(client, no_real_scan):
    r = client.post("/api/security/scan", json={"scope": "everything"})
    assert r.status_code == 400
    assert "custom" in r.text


def test_bad_process_level_rejected(client, no_real_scan):
    r = client.post("/api/security/scan",
                    json={"scope": "core", "process_level": 9})
    assert r.status_code == 400


def test_disinfect_requires_second_consent(client, no_real_scan):
    """处置是不可逆动作：process_level>0 必须显式 disinfect_confirm=yes。"""
    r = client.post("/api/security/scan",
                    json={"scope": "core", "process_level": 2})
    assert r.status_code == 400
    assert "disinfect_confirm" in r.text

    r = client.post("/api/security/scan",
                    json={"scope": "core", "process_level": 2,
                          "disinfect_confirm": "yes"})
    assert r.status_code == 200


def test_scan_start_ok(client, no_real_scan):
    r = client.post("/api/security/scan", json={"scope": "core"})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True and body["started"] is True
    assert body["process_level"] == 0            # 默认只报告
    assert no_real_scan[-1]["level"] == 0


def test_scan_single_flight(client, no_real_scan):
    """扫描进行中再发起，必须 409，不能并发两个。"""
    server._SCAN_STATE["running"] = True
    r = client.post("/api/security/scan", json={"scope": "core"})
    assert r.status_code == 409


def test_timeout_is_clamped(client, no_real_scan):
    r = client.post("/api/security/scan",
                    json={"scope": "core", "timeout_sec": 999999})
    assert r.status_code == 200
    assert r.json()["timeout_sec"] == 14400

    server._SCAN_STATE["running"] = False
    r = client.post("/api/security/scan",
                    json={"scope": "core", "timeout_sec": 1})
    assert r.json()["timeout_sec"] == 30
