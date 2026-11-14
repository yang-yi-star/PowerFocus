# -*- coding: utf-8 -*-
"""v0.11.0 P0 加固回归测试。

每一条都对应一处代码实证过的缺陷，且全部隔离在 tmp_path，
不再向 versions/*/commands/ 写任何东西。
"""
import asyncio
import inspect
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[2]

import sys
sys.path.insert(0, str(ROOT / "app"))
import server  # noqa: E402


# ---------------------------------------------------------------- 令牌解耦

def test_http_token_and_kernel_token_are_different(tmp_path, monkeypatch):
    """免鉴权首页会注入 HTTP 令牌，它绝不能等于内核授权令牌。"""
    monkeypatch.setattr(server, "_HTTP_TOKEN_FILE", tmp_path / "http.token")
    monkeypatch.setattr(server, "TOKEN_FILE", tmp_path / ".auth_token")
    (tmp_path / ".auth_token").write_text("KERNEL_SECRET", encoding="utf-8")
    http = server._token()
    assert http and http != "KERNEL_SECRET"
    assert server._kernel_token() == "KERNEL_SECRET"
    assert (tmp_path / "http.token").read_text(encoding="utf-8") == http


def test_token_bootstrap_is_atomic_under_concurrency(tmp_path, monkeypatch):
    """并发首次启动不得产出多个不同令牌，也不留 .tmp。"""
    monkeypatch.setattr(server, "_HTTP_TOKEN_FILE", tmp_path / "http.token")
    with ThreadPoolExecutor(max_workers=12) as ex:
        vals = list(ex.map(lambda _: server._token(), range(12)))
    assert len(set(vals)) == 1
    assert not list(tmp_path.glob("*.tmp"))


def test_index_injects_only_http_token(tmp_path, monkeypatch):
    """GET / 免鉴权，注入的必须是 HTTP 令牌，内核令牌不得出现在响应里。"""
    monkeypatch.setattr(server, "_HTTP_TOKEN_FILE", tmp_path / "http.token")
    monkeypatch.setattr(server, "TOKEN_FILE", tmp_path / ".auth_token")
    (tmp_path / ".auth_token").write_text("KERNEL_SECRET", encoding="utf-8")
    c = TestClient(server.app, base_url="http://127.0.0.1")
    r = c.get("/")
    assert r.status_code == 200
    assert "KERNEL_SECRET" not in r.text
    assert server._token() in r.text


# ---------------------------------------------------------------- 命令注入

def test_command_endpoint_strips_injected_token_and_idempotency(tmp_path, monkeypatch):
    """客户端传 token / idempotency_id 必须被丢弃，幂等键由服务端生成。"""
    monkeypatch.setattr(server, "_HTTP_TOKEN_FILE", tmp_path / "http.token")
    captured = {}

    async def fake(cmd, timeout=30.0):
        captured.update(cmd)
        return True, "OK"

    monkeypatch.setattr(server, "bus_call", fake)
    c = TestClient(server.app, base_url="http://127.0.0.1")
    c.headers.update({"X-PF-Token": server._token()})
    r = c.post("/api/command", json={
        "action": "status", "token": "INJECTED", "idempotency_id": "fixed-id"})
    assert r.status_code == 200
    assert captured.get("action") == "status"
    assert "token" not in captured
    assert "idempotency_id" not in captured


def test_destructive_action_uses_kernel_token_not_http_token(tmp_path, monkeypatch):
    """破坏性动作注入的是内核令牌，且必须 confirm。"""
    monkeypatch.setattr(server, "_HTTP_TOKEN_FILE", tmp_path / "http.token")
    monkeypatch.setattr(server, "TOKEN_FILE", tmp_path / ".auth_token")
    (tmp_path / ".auth_token").write_text("KERNEL_SECRET", encoding="utf-8")
    captured = {}

    async def fake(cmd, timeout=30.0):
        captured.update(cmd)
        return True, "OK"

    monkeypatch.setattr(server, "bus_call", fake)
    c = TestClient(server.app, base_url="http://127.0.0.1")
    c.headers.update({"X-PF-Token": server._token()})

    denied = c.post("/api/command", json={"action": "kill_process", "process_name": "x"})
    assert denied.status_code == 400

    ok = c.post("/api/command", json={"action": "kill_process",
                                       "process_name": "x", "confirm": True})
    assert ok.status_code == 200
    assert captured.get("token") == "KERNEL_SECRET"


# ---------------------------------------------------------------- 回执稳定性

def test_empty_receipt_is_not_reported_as_success(tmp_path):
    """旧内核非原子写可能先产生空文件：空回执必须再等，不能立刻判成功。"""
    in_dir, done_dir = tmp_path / "in", tmp_path / "done"
    done_dir.mkdir()
    cli = server.bus.BusClient(in_dir, done_dir, "test-kernel")

    async def scenario():
        task = asyncio.create_task(cli.call({"action": "status"}, timeout=3.0))
        f = None
        for _ in range(100):
            files = list(in_dir.glob("*.json"))
            if files:
                f = files[0]
                break
            await asyncio.sleep(0.02)
        assert f is not None, "命令未写入"
        receipt = done_dir / (f.stem + ".json.result.txt")
        receipt.write_text("", encoding="utf-8")       # 模拟半截写入
        await asyncio.sleep(0.05)
        receipt.write_text("ERROR: 内核失败", encoding="utf-8")
        return await task

    ok, text = asyncio.run(scenario())
    assert ok is False
    assert "ERROR" in text


@pytest.mark.parametrize("rel", [
    "versions/v0.09/电脑算力调度中心_v0.09.ps1",
    "versions/v0.10/电脑算力调度中心_v0.10.ps1",
])
def test_kernel_receipt_writer_is_atomic_and_timestamp_free(rel):
    """当前 stable 与 dev 两代内核都必须写纯正文且原子替换。"""
    txt = (ROOT / rel).read_text(encoding="utf-8")
    assert "$stamp`n$resultText" not in txt
    assert '$tmpPath = $resultPath + ".tmp"' in txt
    assert "Move-Item -LiteralPath $tmpPath -Destination $resultPath -Force" in txt


# ---------------------------------------------------------------- 路径

def test_no_hardcoded_developer_root():
    src = inspect.getsource(server.resolve_pf_root)
    assert "E:\\PowerFocus" not in src


def test_tests_do_not_call_real_bus_call():
    """防止再次出现「monkeypatch 无效 + 断言恒真 + 污染生产目录」的组合。"""
    needle = "server." + "bus_call("  # 拼开，避免守卫命中自身源码
    for p in (ROOT / "tests" / "py").glob("test_*.py"):
        if p.name == "test_p0_hardening.py":
            continue
        txt = p.read_text(encoding="utf-8")
        assert needle not in txt, "%s 仍在调用真实总线" % p.name
