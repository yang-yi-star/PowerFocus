# -*- coding: utf-8 -*-
"""PowerFocus MCP Server 0.11.0 协议与安全回归测试。

覆盖重点（来自红队攻防审计与 Bug 猎手报告）：
- 2026-07-28 无状态核心：不握手即可 tools/call
- 旧 initialize 握手兼容、server/discover
- 确定性工具顺序 + 缓存提示
- 默认只读、REA 不暴露、写工具一次性确认 nonce（静态 true 必须被拒）
- 「声明即白名单」：token / idempotency_id 等字段不得注入后端
- 畸形 JSON-RPC 消息不得打崩 handle()（对应 B28 / F11）
"""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "mcp"))

from powerfocus_mcp import __version__, version_info  # noqa: E402
from powerfocus_mcp import server as mcp  # noqa: E402


def _policy(**kw):
    base = dict(allow_write=False, allow_install=False, root=str(ROOT), port=18080)
    base.update(kw)
    return mcp.Policy(**base)


def _rt(policy=None, api_result=None, collector=None):
    p = policy or _policy()
    rt = mcp.Runtime(p)
    if api_result is not None or collector is not None:
        def fake(method, path, payload=None, query=None, timeout=15.0):
            if collector is not None:
                collector.append({"method": method, "path": path,
                                  "payload": payload, "query": query})
            return api_result if api_result is not None else {"ok": True}
        rt.call_api = fake
    return p, rt


def _rpc(method, params=None, policy=None, rt=None, msg_id=1, **kw):
    p, r = (policy, rt) if rt is not None else _rt(policy, **kw)
    msg = {"jsonrpc": "2.0", "id": msg_id, "method": method}
    if params is not None:
        msg["params"] = params
    return mcp.handle(msg, p, r)


def _call_tool(name, arguments, policy=None, rt=None, **kw):
    return _rpc("tools/call", {"name": name, "arguments": arguments},
                policy=policy, rt=rt, **kw)


# ---------------------------------------------------------------- 版本对齐

def test_version_aligned_with_app_release():
    info = version_info()
    assert info["mcp_version"] == __version__ == "0.11.0"
    assert info["target_app_version"] == __version__
    assert info["default_protocol_version"] == "2026-07-28"
    assert "2024-11-05" in info["protocol_versions"]
    assert (ROOT / "mcp" / "VERSION.json").is_file()


# ---------------------------------------------------------------- 无状态核心

def test_tools_call_without_initialize_is_allowed():
    collector = []
    p, rt = _rt(api_result={"app": "ok"}, collector=collector)
    resp = _call_tool("pf_health", {}, policy=p, rt=rt)
    assert resp["id"] == 1 and "result" in resp and "error" not in resp
    assert resp["result"]["isError"] is False
    assert json.loads(resp["result"]["content"][0]["text"])["app"] == "ok"
    assert collector[0]["method"] == "GET" and collector[0]["path"] == "/api/health"


def test_tools_list_deterministic_with_cache_hints():
    a = _rpc("tools/list")
    b = _rpc("tools/list")
    names_a = [t["name"] for t in a["result"]["tools"]]
    names_b = [t["name"] for t in b["result"]["tools"]]
    assert names_a == names_b == sorted(names_a)
    assert len(names_a) == len(set(names_a)) == 10  # 默认只读 10 个
    assert a["result"]["ttlMs"] == 60000
    assert a["result"]["cacheScope"] == "server"


def test_server_discover_reports_policy_and_protocol():
    r = _rpc("server/discover")
    d = r["result"]
    assert d["protocolVersion"] == "2026-07-28"
    assert "2026-07-28" in d["protocolVersions"]
    assert d["stateless"] is True
    assert d["mrtr"] == "confirm-only"
    assert d["policy"]["defaultReadOnly"] is True
    assert d["policy"]["reaProxyExposed"] is False
    assert d["serverInfo"]["version"] == __version__


def test_initialize_compatibility_for_older_clients():
    r = _rpc("initialize", {"protocolVersion": "2024-11-05",
                            "clientInfo": {"name": "legacy", "version": "1"}})
    assert r["result"]["protocolVersion"] == "2024-11-05"
    assert r["result"]["serverInfo"]["name"] == "powerfocus-mcp"
    assert "instructions" in r["result"]


# ---------------------------------------------------------------- 只读默认

def test_default_policy_hides_write_and_dangerous_tools():
    names = [t["name"] for t in _rpc("tools/list")["result"]["tools"]]
    assert "pf_run_command" not in names
    assert "pf_install_component" not in names
    assert not any(n.startswith("rea") for n in names)


def test_disabled_write_tool_is_indistinguishable_from_unknown():
    r = _call_tool("pf_run_command", {"action": "status"})
    assert r["error"]["code"] == -32602
    assert "Unknown tool" in r["error"]["message"]


def test_readonly_tool_rejects_injected_fields():
    collector = []
    p, rt = _rt(api_result={"count": 0}, collector=collector)
    _call_tool("pf_processes", {"q": "notepad", "token": "LEAK", "confirm": True},
               policy=p, rt=rt)
    assert collector[0]["query"] == {"q": "notepad"}
    assert collector[0]["payload"] is None


# ---------------------------------------------------------------- 一次性确认

def _write_policy():
    return _policy(allow_write=True)


def _first_write_call(args, rt):
    return _call_tool("pf_boost_model", args, policy=_write_policy(), rt=rt)


def test_write_issues_nonce_and_does_not_execute():
    collector = []
    p, rt = _rt(policy=_write_policy(), api_result={"ok": True}, collector=collector)
    first = _call_tool("pf_boost_model", {"mode": "dry_run"}, policy=p, rt=rt)
    assert first["result"]["resultType"] == "input_required"
    nonce = first["result"]["confirm"]["nonce"]
    assert isinstance(nonce, str) and len(nonce) >= 16
    assert nonce in first["result"]["content"][0]["text"]
    assert collector == []  # 首次绝不执行


def test_static_true_is_rejected_as_confirmation():
    """红队 F8：静态常量确认令牌不可接受。"""
    p, rt = _rt(policy=_write_policy(), api_result={"ok": True})
    _call_tool("pf_boost_model", {"mode": "dry_run"}, policy=p, rt=rt)
    bad = _call_tool("pf_boost_model", {"mode": "dry_run", "_mcp_confirm": True},
                     policy=p, rt=rt)
    assert bad["error"]["code"] == -32602  # 类型必须是 nonce 字符串


def test_nonce_executes_once_and_cannot_be_reused():
    collector = []
    p, rt = _rt(policy=_write_policy(), api_result={"ok": True}, collector=collector)
    first = _call_tool("pf_boost_model", {"mode": "dry_run"}, policy=p, rt=rt)
    nonce = first["result"]["confirm"]["nonce"]

    ok = _call_tool("pf_boost_model", {"mode": "dry_run", "_mcp_confirm": nonce},
                    policy=p, rt=rt)
    assert ok["result"]["isError"] is False
    assert collector and collector[0]["payload"] == {"mode": "dry_run"}

    again = _call_tool("pf_boost_model", {"mode": "dry_run", "_mcp_confirm": nonce},
                       policy=p, rt=rt)
    assert again["result"]["isError"] is True
    assert "已被使用" in json.loads(again["result"]["content"][0]["text"])["error"]
    assert len(collector) == 1  # 重放没有二次执行


def test_nonce_is_bound_to_arguments_and_tool():
    p, rt = _rt(policy=_write_policy(), api_result={"ok": True})
    first = _call_tool("pf_boost_model", {"mode": "dry_run"}, policy=p, rt=rt)
    nonce = first["result"]["confirm"]["nonce"]
    changed = _call_tool("pf_boost_model", {"mode": "apply", "_mcp_confirm": nonce},
                         policy=p, rt=rt)
    assert changed["result"]["isError"] is True
    assert "不匹配" in json.loads(changed["result"]["content"][0]["text"])["error"]


def test_input_responses_retry_path_supported():
    collector = []
    p, rt = _rt(policy=_write_policy(), api_result={"ok": True}, collector=collector)
    first = _rpc("tools/call", {"name": "pf_boost_model",
                                "arguments": {"mode": "dry_run"}}, policy=p, rt=rt)
    nonce = first["result"]["confirm"]["nonce"]
    second = mcp.handle({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": "pf_boost_model", "arguments": {"mode": "dry_run"},
                   "inputResponses": {"confirm": nonce}},
    }, p, rt)
    assert second["result"]["isError"] is False
    assert len(collector) == 1


def test_install_tool_requires_second_switch():
    p = _policy(allow_write=True, allow_install=False)
    names = [t["name"] for t in _rpc("tools/list", policy=p)["result"]["tools"]]
    assert "pf_install_component" not in names
    p2 = _policy(allow_write=True, allow_install=True)
    names2 = [t["name"] for t in _rpc("tools/list", policy=p2)["result"]["tools"]]
    assert "pf_install_component" in names2


# ---------------------------------------------------------------- 参数白名单

def test_command_whitelist_drops_token_and_idempotency_id():
    """红队 F2/F5：AI 侧不得注入 token 或指定幂等键。"""
    collector = []
    p, rt = _rt(policy=_write_policy(), api_result={"ok": True}, collector=collector)
    args = {"action": "status", "token": "KERNEL_SECRET",
            "idempotency_id": "fixed-id", "_raw": "whatever"}
    first = _call_tool("pf_run_command", args, policy=p, rt=rt)
    nonce = first["result"]["confirm"]["nonce"]
    sent = dict(args, _mcp_confirm=nonce)
    _call_tool("pf_run_command", sent, policy=p, rt=rt)
    payload = collector[0]["payload"]
    assert payload == {"action": "status"}
    assert "token" not in payload and "idempotency_id" not in payload


def test_unknown_action_rejected_by_schema():
    p, rt = _rt(policy=_write_policy(), api_result={"ok": True})
    r = _call_tool("pf_run_command", {"action": "drop_all_tables"}, policy=p, rt=rt)
    assert r["error"]["code"] == -32602
    assert "不在允许范围" in r["error"]["message"]


def test_missing_required_argument_rejected():
    p, rt = _rt(policy=_write_policy(), api_result={"ok": True})
    r = _call_tool("pf_chat", {}, policy=p, rt=rt)
    assert r["error"]["code"] == -32602
    assert "缺少必填参数" in r["error"]["message"]


# ---------------------------------------------------------------- 畸形消息免疫

@pytest.mark.parametrize("msg", [
    {"jsonrpc": "2.0", "id": 1, "method": None},
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": []},
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": "oops"},
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": []},
    {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
     "params": {"name": "pf_health", "arguments": []}},
    {"jsonrpc": "2.0", "id": 1, "method": ""},
    {"jsonrpc": "2.0", "id": 1},
    {"jsonrpc": "1.0", "id": 1, "method": "tools/list"},
    "not-a-dict",
    None,
])
def test_malformed_messages_never_raise(msg):
    """B28/F11：畸形消息不得打崩 stdio 进程，也不得污染协议流。"""
    resp = mcp.handle(msg, _policy(), mcp.Runtime(_policy()))
    assert resp is None or isinstance(resp, dict)
    if isinstance(resp, dict):
        json.dumps(resp, ensure_ascii=False, default=str)  # 必须可序列化


def test_notification_without_id_is_ignored():
    assert mcp.handle({"jsonrpc": "2.0", "method": "notifications/initialized"},
                      _policy(), mcp.Runtime(_policy())) is None


def test_unknown_method_returns_standard_error():
    r = _rpc("no/such/method")
    assert r["error"]["code"] == -32601


def test_ping():
    assert _rpc("ping")["result"] == {}


def test_audit_record_contains_only_argument_keys(tmp_path, monkeypatch):
    """审计日志不得记录参数值或令牌。"""
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))
    mcp._audit("pf_run_command", "write",
               {"action": "focus", "token": "SUPER_SECRET", "process_name": "game"},
               True, 12)
    text = (tmp_path / "PowerFocus" / "mcp" / "audit.jsonl").read_text(encoding="utf-8")
    assert "SUPER_SECRET" not in text and "game" not in text
    assert "token" in text and "arg_keys" in text
