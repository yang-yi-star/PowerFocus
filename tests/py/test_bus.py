# -*- coding: utf-8 -*-
"""BusClient 集成测试：用临时目录 + 伪内核，不依赖 FastAPI 或真实内核。"""
import asyncio
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "product" / "v1.00" / "app"))
import bus  # noqa: E402


def _client(tmp_path):
    in_dir, done_dir = tmp_path / "in", tmp_path / "done"
    in_dir.mkdir()
    done_dir.mkdir()
    return bus.BusClient(in_dir, done_dir, kernel_name="测试内核")


def _run(client, receipt_text, timeout=2.0):
    """起 BusClient.call，用伪内核消费命令并写回执，返回 (ok, text, 命令对象)。"""
    async def scenario():
        task = asyncio.create_task(client.call({"action": "router_status"}, timeout=timeout))
        written = None
        for _ in range(300):
            files = list(client.in_dir.glob("*.json"))
            if files:
                written = json.loads(files[0].read_text(encoding="utf-8"))
                if receipt_text is not None:
                    (client.done_dir / (files[0].name + ".result.txt")).write_text(
                        receipt_text, encoding="utf-8")
                    files[0].unlink()
                break
            await asyncio.sleep(0.01)
        ok, text = await task
        return ok, text, written
    return asyncio.run(scenario())


def test_success_and_legacy_timestamp_stripped(tmp_path):
    client = _client(tmp_path)
    ok, text, cmd = _run(client, '2026-11-14 09:00:00\n{"status":"ok","active":"game"}')
    assert ok is True
    assert text == '{"status":"ok","active":"game"}'
    assert cmd["action"] == "router_status"


def test_error_receipt_is_failure(tmp_path):
    client = _client(tmp_path)
    ok, text, _ = _run(client, "ERROR: 内核未响应")
    assert ok is False
    assert text.startswith("ERROR:")


def test_command_has_idempotency_id_and_no_tmp_left(tmp_path):
    client = _client(tmp_path)
    ok, _, cmd = _run(client, "ok")
    assert ok is True
    assert cmd["idempotency_id"].startswith("ui-")
    assert list(client.in_dir.glob("*.tmp")) == []
    assert list(client.in_dir.glob("*.json")) == []


def test_receipt_is_consumed(tmp_path):
    client = _client(tmp_path)
    _run(client, "ok")
    assert list(client.done_dir.glob("*.result.txt")) == []
    assert list(client.done_dir.glob("*.json")) == []


def test_timeout_returns_failure_and_withdraws_command(tmp_path):
    client = _client(tmp_path)
    ok, text, cmd = _run(client, None, timeout=0.5)
    assert ok is False
    assert "超时" in text
    assert cmd is not None                       # 伪内核确认命令确实发出
    assert list(client.in_dir.glob("*.json")) == []  # 超时已撤回


def test_ids_are_unique_under_burst(tmp_path):
    client = _client(tmp_path)
    ids = {client._new_id() for _ in range(200)}
    assert len(ids) == 200
