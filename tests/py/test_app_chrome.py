# -*- coding: utf-8 -*-
"""应用化补齐回归：关于 / 更新检查 / 应用偏好 / 日志配置导出 / 版本真源。

隔离原则：
  · 数据目录用 POWERFOCUS_DATA_DIR 指到 tmp_path，不写真机配置；
  · 开机自启注册表读写桩掉，不碰 HKCU；
  · 更新检查的网络请求桩掉，失败路径必须如实回报 checked=false，不许 500；
  · 导出配置不得带出 API Key（DPAPI 凭据库不参与备份）。
"""
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "product" / "v1.00" / "app"))

import version  # noqa: E402
import preferences  # noqa: E402
import server  # noqa: E402


def _client(tmp_path, monkeypatch):
    monkeypatch.setenv("POWERFOCUS_DATA_DIR", str(tmp_path))
    monkeypatch.setattr(server, "_HTTP_TOKEN_FILE", tmp_path / "http.token")
    monkeypatch.setattr(server, "TOKEN_FILE", tmp_path / ".auth_token")
    c = TestClient(server.app, base_url="http://127.0.0.1")
    c.headers.update({"X-PF-Token": server._token()})
    return c


# ---------------------------------------------------------------- 关于 / 版本

def test_about_reports_version_and_links(tmp_path, monkeypatch):
    c = _client(tmp_path, monkeypatch)
    r = c.get("/api/about")
    assert r.status_code == 200
    body = r.json()
    assert body["release"]
    assert body["slot"] == version.SLOT == "v1.00"
    assert "github.com" in body["source_url"]
    assert body["license"] == "Apache-2.0"
    assert body["kernel_version"]


def test_about_requires_token(tmp_path, monkeypatch):
    monkeypatch.setenv("POWERFOCUS_DATA_DIR", str(tmp_path))
    monkeypatch.setattr(server, "_HTTP_TOKEN_FILE", tmp_path / "http.token")
    c = TestClient(server.app, base_url="http://127.0.0.1")
    assert c.get("/api/about").status_code >= 400


def test_version_env_override_wins(monkeypatch):
    monkeypatch.setenv("PF_RELEASE_TAG", "v0.99.0")
    assert version.release_version() == "v0.99.0"


def test_version_falls_back_without_env(monkeypatch):
    monkeypatch.delenv("PF_RELEASE_TAG", raising=False)
    v = version.release_version()
    assert v and isinstance(v, str)


# ---------------------------------------------------------------- 更新检查

class _BoomClient:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False

    async def get(self, *a, **k):
        raise RuntimeError("network down")


def test_update_check_failure_is_reported_not_500(tmp_path, monkeypatch):
    monkeypatch.setattr(server.httpx, "AsyncClient", _BoomClient)
    c = _client(tmp_path, monkeypatch)
    r = c.get("/api/update-check")
    assert r.status_code == 200
    body = r.json()
    assert body["checked"] is False
    assert body["reason"]


# ---------------------------------------------------------------- 应用偏好

def test_preferences_defaults_roundtrip(tmp_path, monkeypatch):
    c = _client(tmp_path, monkeypatch)
    monkeypatch.setattr(server, "_set_autostart", lambda enabled: None)
    monkeypatch.setattr(server, "_autostart_enabled", lambda: False)

    got = c.get("/api/preferences").json()
    assert got["autostart"] is False
    assert got["close_action"] == "exit"
    assert got["poll_interval_ms"] == 1000
    assert got["onboarded"] is False

    r = c.post("/api/preferences", json={
        "autostart": True, "close_action": "tray",
        "poll_interval_ms": 99999, "onboarded": True, "rogue_key": "x"})
    assert r.status_code == 200
    saved = r.json()["preferences"]
    assert saved["autostart"] is True
    assert saved["close_action"] == "tray"
    assert saved["poll_interval_ms"] == 10000          # 超上限钳制
    assert saved["onboarded"] is True
    assert "rogue_key" not in saved

    # 非法枚举回退默认；区间外下限钳制
    r2 = c.post("/api/preferences", json={"close_action": "explode", "poll_interval_ms": 40})
    saved2 = r2.json()["preferences"]
    assert saved2["close_action"] == "exit"
    assert saved2["poll_interval_ms"] == 500


def test_preferences_autostart_hooks_registry(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(server, "_set_autostart", lambda enabled: calls.append(enabled))
    monkeypatch.setattr(server, "_autostart_enabled", lambda: True)
    c = _client(tmp_path, monkeypatch)
    r = c.post("/api/preferences", json={"autostart": True})
    assert r.status_code == 200
    assert calls == [True]
    assert r.json()["preferences"]["autostart_active"] is True


# ---------------------------------------------------------------- 导出

def test_export_config_omits_api_key(tmp_path, monkeypatch):
    c = _client(tmp_path, monkeypatch)
    # 直接往配置里塞一个 api_key 模拟旧明文残留；导出必须剥掉
    server._write_config({"system_prompt": "hi", "api_key": "SECRET-LEAK"})
    r = c.get("/api/export/config")
    assert r.status_code == 200
    body = r.json()
    assert "SECRET-LEAK" not in r.text
    assert body["config"].get("system_prompt") == "hi"
    assert "api_key" not in body["config"]


def test_export_logs_returns_text(tmp_path, monkeypatch):
    c = _client(tmp_path, monkeypatch)
    r = c.get("/api/export/logs")
    assert r.status_code == 200
    assert "text/plain" in r.headers["content-type"]
    assert isinstance(r.text, str)
