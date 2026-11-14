# -*- coding: utf-8 -*-
"""命令总线回执协议回归测试（对应工程审计 P0-1 / P0-2）。"""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "product" / "v1.00" / "app"))
import bus_receipt  # noqa: E402


def test_plain_json_receipt_is_success():
    ok, body = bus_receipt.parse_receipt('{"status": "ok", "active": "game"}')
    assert ok is True
    assert json.loads(body)["active"] == "game"


def test_legacy_timestamp_prefix_is_stripped():
    """旧内核回执首行是时间戳，剥离后 /api/router 才能解析出 data。"""
    raw = "2026-11-14 08:31:02\n" + '{"status": "ok", "active": "work"}'
    ok, body = bus_receipt.parse_receipt(raw)
    assert ok is True
    assert json.loads(body)["active"] == "work"


def test_error_receipt_is_failure():
    ok, body = bus_receipt.parse_receipt("ERROR: 命令解析/执行异常: 参数缺失")
    assert ok is False
    assert body.startswith("ERROR:")


def test_legacy_timestamp_plus_error_is_failure():
    """两代格式叠加时也不能把失败当成功。"""
    ok, body = bus_receipt.parse_receipt("2026-11-14 08:31:02\nERROR: 内核未响应")
    assert ok is False
    assert body == "ERROR: 内核未响应"


def test_fullwidth_colon_error_is_failure():
    ok, _ = bus_receipt.parse_receipt("ERROR：执行失败")
    assert ok is False


def test_empty_receipt_keeps_legacy_behavior():
    assert bus_receipt.parse_receipt("") == (True, "")
    assert bus_receipt.parse_receipt("   \n ") == (True, "")


def test_atomic_write_leaves_no_tmp_and_full_json(tmp_path):
    target = tmp_path / "ui-1-1.json"
    bus_receipt.atomic_write(target, bus_receipt.dumps_command({"action": "router_status"}))
    assert not (tmp_path / "ui-1-1.json.tmp").exists()
    assert json.loads(target.read_text(encoding="utf-8"))["action"] == "router_status"


def test_gc_done_removes_only_stale_files(tmp_path):
    stale_receipt = tmp_path / "old.json.result.txt"
    stale_cmd = tmp_path / "old.json"
    fresh = tmp_path / "fresh.json.result.txt"
    for p in (stale_receipt, stale_cmd, fresh):
        p.write_text("x", encoding="utf-8")
    old = 1_000_000.0
    now = 2_000_000.0
    for p in (stale_receipt, stale_cmd):
        os.utime(p, (old, old))
    os.utime(fresh, (now - 10, now - 10))

    removed = bus_receipt.gc_done(tmp_path, max_age=3600, now=now)
    assert removed == 2
    assert not stale_receipt.exists()
    assert not stale_cmd.exists()
    assert fresh.exists()


def test_gc_done_on_missing_dir_returns_zero(tmp_path):
    assert bus_receipt.gc_done(tmp_path / "nope") == 0
