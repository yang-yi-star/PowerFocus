# -*- coding: utf-8 -*-
"""隐私防护 P0（posture.py）回归。

为什么要有这份测试：
    「只读体检」这个承诺有四个容易悄悄破掉的地方——
      · 有人图省事在 posture 里 import httpx 去查 IP → 「页面加载零外联」失效；
      · 注册表缺键时随手当成「开着」或「关着」 → 用户看到的是猜的，不是事实；
      · 某一项抛异常把整页打空 → 和 51 号同一类事故；
      · 公网 IP 检测没先写审计就发请求，或 GET 也能触发 → 「点击即知情」失效。
    这里每条钉一个。

隔离原则：
    注册表全部走假表（monkeypatch posture.read_*），绝不读真机；
    连接列表、进程名、审计列表全部注入；
    出口 IP 用假 httpx，绝不发真实请求；计划任务目录用 tmp_path。
"""
import asyncio
import re
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[2]
APP_DIR = ROOT / "product" / "v1.00" / "app"
sys.path.insert(0, str(APP_DIR))
import posture  # noqa: E402
import security  # noqa: E402
import server  # noqa: E402


# ---------------------------------------------------------------- 假注册表

class FakeReg:
    def __init__(self):
        self.d, self.s, self.b, self.subs, self.vals = {}, {}, {}, {}, {}

    def install(self, monkeypatch):
        monkeypatch.setattr(posture, "read_dword", lambda root, path, name: self.d.get((path, name)))
        monkeypatch.setattr(posture, "read_str", lambda root, path, name: self.s.get((path, name)))
        monkeypatch.setattr(posture, "read_bytes", lambda root, path, name: self.b.get((path, name)))
        monkeypatch.setattr(posture, "enum_subkeys", lambda root, path: list(self.subs.get(path, [])))
        monkeypatch.setattr(posture, "enum_values", lambda root, path: list(self.vals.get(path, [])))


FW = "SYSTEM\\CurrentControlSet\\Services\\SharedAccess\\Parameters\\FirewallPolicy"
TS = "SYSTEM\\CurrentControlSet\\Control\\Terminal Server"
POL = "SOFTWARE\\Policies\\Microsoft\\Windows NT\\DNSClient"
NB = "SYSTEM\\CurrentControlSet\\Services\\NetBT\\Parameters\\Interfaces"
WLAN = "SOFTWARE\\Microsoft\\WlanSvc\\Interfaces"
ADID = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo"
LOC = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location"
RUN = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run"


def _firewall(reg, domain=1, private=1, public=1):
    for key, val in (("DomainProfile", domain), ("StandardProfile", private), ("PublicProfile", public)):
        if val is not None:
            reg.d[(FW + "\\" + key, "EnableFirewall")] = val


# ---------------------------------------------------------------- 承诺一：零外联（结构锁）

def test_posture_has_no_network_imports():
    src = (APP_DIR / "posture.py").read_text(encoding="utf-8")
    for bad in ("import httpx", "import urllib", "import socket", "import requests", "http.client"):
        assert bad not in src, "posture.py 出现了网络库：%s" % bad


# ---------------------------------------------------------------- 承诺二：未知不猜

def test_firewall_all_on_is_ok(monkeypatch):
    reg = FakeReg()
    reg.install(monkeypatch)
    _firewall(reg)
    it = posture.check_firewall()
    assert it["status"] == "ok"
    assert "公用网络=开" in it["value"]


def test_firewall_public_off_is_warn(monkeypatch):
    reg = FakeReg()
    reg.install(monkeypatch)
    _firewall(reg, public=0)
    it = posture.check_firewall()
    assert it["status"] == "warn"
    assert "公用网络" in it["detail"]


def test_firewall_missing_key_is_unknown_not_ok(monkeypatch):
    reg = FakeReg()
    reg.install(monkeypatch)
    _firewall(reg, public=None)
    it = posture.check_firewall()
    assert it["status"] == "unknown"
    assert "公用网络=未知" in it["value"]


def test_rdp_three_states(monkeypatch):
    reg = FakeReg()
    reg.install(monkeypatch)
    reg.d[(TS, "PortNumber")] = 3389
    reg.d[(TS, "fDenyTSConnections")] = 1
    assert posture.check_rdp()["status"] == "ok"
    reg.d[(TS, "fDenyTSConnections")] = 0
    it = posture.check_rdp()
    assert it["status"] == "warn" and "3389" in it["value"]
    del reg.d[(TS, "fDenyTSConnections")]
    assert posture.check_rdp()["status"] == "unknown"


def test_name_resolution_policy_off_and_netbios_disabled_is_ok(monkeypatch):
    reg = FakeReg()
    reg.install(monkeypatch)
    reg.d[(POL, "EnableMulticast")] = 0
    reg.subs[NB] = ["Tcpip_A", "Tcpip_B"]
    reg.d[(NB + "\\Tcpip_A", "NetbiosOptions")] = 2
    reg.d[(NB + "\\Tcpip_B", "NetbiosOptions")] = 2
    it = posture.check_name_resolution()
    assert it["status"] == "ok"
    assert "多播名称解析=已关闭" in it["value"]
    assert "NetBIOS over TCP/IP=0 开 / 2 关" in it["value"]


def test_name_resolution_default_is_warn_and_nothing_readable_is_unknown(monkeypatch):
    reg = FakeReg()
    reg.install(monkeypatch)
    reg.subs[NB] = ["Tcpip_A"]
    it = posture.check_name_resolution()
    assert it["status"] == "warn" and "默认开启" in it["value"]
    reg.subs.clear()
    assert posture.check_name_resolution()["status"] == "unknown"


def test_mac_random_states(monkeypatch):
    reg = FakeReg()
    reg.install(monkeypatch)
    reg.subs[WLAN] = ["{a}"]
    reg.b[(WLAN + "\\{a}", "RandomMacState")] = b"\x01\x00\x00\x00"
    assert posture.check_mac_random()["status"] == "ok"
    reg.b[(WLAN + "\\{a}", "RandomMacState")] = b"\x00\x00\x00\x00"
    assert posture.check_mac_random()["status"] == "warn"
    reg.subs.clear()
    assert posture.check_mac_random()["status"] == "unknown"


def test_adid_and_location(monkeypatch):
    reg = FakeReg()
    reg.install(monkeypatch)
    reg.d[(ADID, "Enabled")] = 0
    assert posture.check_adid()["status"] == "ok"
    reg.d[(ADID, "Enabled")] = 1
    assert posture.check_adid()["status"] == "warn"
    reg.s[(LOC, "Value")] = "Allow"
    assert posture.check_location()["status"] == "warn"
    reg.s[("HKLM:" + LOC, "Value")] = "x"  # 假表不区分 root，这里只验证 Deny 优先于 Allow
    reg.s[(LOC, "Value")] = "Deny"
    assert posture.check_location()["status"] == "ok"


# ---------------------------------------------------------------- 自启项：读得出「最高权限」

def _write_task(tasks_dir, name, text, utf16=True):
    p = tasks_dir / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((b"\xff\xfe" + text.encode("utf-16-le")) if utf16 else text.encode("utf-8"))


def test_autostart_finds_highest_privilege_task(monkeypatch, tmp_path):
    sysroot = tmp_path / "Win"
    tasks = sysroot / "System32" / "Tasks"
    xml = ('<Task><Principals><Principal><RunLevel>HighestAvailable</RunLevel></Principal></Principals>'
           '<Actions><Exec><Command>E:\\PowerFocus\\product\\v1.00\\dist\\电脑算力调度中心.exe</Command>'
           '</Exec></Actions></Task>')
    _write_task(tasks, "PowerFocusAutoV2", xml)
    _write_task(tasks, "Microsoft/Windows/Other", '<Task><Command>something.exe</Command></Task>')
    monkeypatch.setenv("SystemRoot", str(sysroot))
    monkeypatch.setenv("APPDATA", str(tmp_path / "appdata"))
    monkeypatch.setenv("ProgramData", str(tmp_path / "programdata"))
    reg = FakeReg()
    reg.install(monkeypatch)
    it = posture.check_autostart()
    assert it["status"] == "info"
    rows = it["rows"]
    assert len(rows) == 1
    assert rows[0]["kind"] == "计划任务" and rows[0]["run_level"] == "最高权限"
    assert "算力调度中心.exe" in rows[0]["target"]
    # 再加一个 Run 键。假表不区分 HKCU/HKLM，所以两条 root 都会命中——这里只验证「能列出来、带权限标签」
    reg.vals[RUN] = [("电脑算力调度中心", r'"E:\x\电脑算力调度中心.exe"')]
    rows = posture.check_autostart()["rows"]
    kinds = {(r["kind"], r["run_level"]) for r in rows}
    assert ("计划任务", "最高权限") in kinds
    assert any(k[0] == "注册表 Run" and k[1] in ("当前用户", "所有用户") for k in kinds)
    assert all("算力调度中心.exe" in r["target"] for r in rows)


def test_autostart_none_found(monkeypatch, tmp_path):
    sysroot = tmp_path / "Win"
    (sysroot / "System32" / "Tasks").mkdir(parents=True)
    monkeypatch.setenv("SystemRoot", str(sysroot))
    monkeypatch.setenv("APPDATA", str(tmp_path / "appdata"))
    monkeypatch.setenv("ProgramData", str(tmp_path / "programdata"))
    FakeReg().install(monkeypatch)
    it = posture.check_autostart()
    assert it["status"] == "info" and it["rows"] == [] and it["value"] == "没有"


# ---------------------------------------------------------------- 外联列表：只列公网已建立连接

def _conn(status, ip, port, pid):
    return SimpleNamespace(status=status, raddr=SimpleNamespace(ip=ip, port=port), pid=pid)


def test_outbound_filters_private_loopback_listen_and_aggregates():
    conns = [
        _conn("ESTABLISHED", "8.8.8.8", 443, 10),
        _conn("ESTABLISHED", "8.8.8.8", 443, 10),
        _conn("ESTABLISHED", "192.168.1.1", 80, 11),      # 私网：不列
        _conn("ESTABLISHED", "127.0.0.1", 8080, 11),      # 回环：不列
        _conn("ESTABLISHED", "100.64.0.1", 443, 11),      # 运营商级 NAT：不列
        _conn("LISTEN", "8.8.4.4", 443, 12),              # 未建立：不列
        _conn("ESTABLISHED", "1.1.1.1", 53, None),        # 读不到归属：计入 denied
    ]
    it = posture.check_outbound(conn_iter=lambda: conns, proc_name=lambda pid: "proc%d" % pid)
    assert it["status"] == "info"
    rows = it["rows"]
    assert rows[0] == {"proc": "proc10", "ip": "8.8.8.8", "port": 443, "count": 2}
    assert {r["ip"] for r in rows} == {"8.8.8.8", "1.1.1.1"}
    assert rows[1]["proc"] == "(权限不足)"
    assert "1 条读不到归属" in it["value"]


def test_outbound_failure_is_unknown():
    def boom():
        raise PermissionError("x")
    it = posture.check_outbound(conn_iter=boom)
    assert it["status"] == "unknown" and it["rows"] == []


def test_summarize_app_outbound_counts_and_keeps_newest():
    items = [
        {"ts": "2026-11-24 10:00:00", "event": "chat", "target": "cloud"},
        {"ts": "2026-11-24 09:00:00", "event": "chat", "target": "cloud"},
        {"ts": "2026-11-24 08:00:00", "event": "chat", "target": "local"},
        {"ts": "2026-11-24 07:00:00", "event": "bootstrap_install", "component": "node"},
        {"ts": "2026-11-24 06:00:00", "event": "exitip_check", "host": "api.ipify.org"},
        {"ts": "2026-11-24 05:00:00", "event": "settings_changed"},
        "garbage", None,
    ]
    out = posture.summarize_app_outbound(items)
    assert out["chat_cloud"] == 2 and out["chat_local"] == 1
    assert out["bootstrap"] == 1 and out["exitip"] == 1
    assert out["last"]["chat_cloud"] == "2026-11-24 10:00:00"


# ---------------------------------------------------------------- 承诺三：单项崩不拖整页 + 评分

def test_collect_one_check_raising_becomes_unknown(monkeypatch):
    reg = FakeReg()
    reg.install(monkeypatch)
    _firewall(reg)
    monkeypatch.setattr(posture, "check_rdp", lambda: (_ for _ in ()).throw(RuntimeError("boom")))
    res = posture.collect(conn_iter=lambda: [], proc_name=lambda pid: "p")
    by_id = {c["id"]: c for c in res["checks"]}
    assert by_id["rdp"]["status"] == "unknown" and "RuntimeError" in by_id["rdp"]["detail"]
    assert by_id["firewall"]["status"] == "ok"
    assert res["read_only"] is True
    # 防火墙 ok、RDP 不计分、对话默认未知（未传）：1/1 = 100
    assert res["score"] == 100


def test_collect_score_and_summary(monkeypatch, tmp_path):
    reg = FakeReg()
    reg.install(monkeypatch)
    _firewall(reg, public=0)
    reg.d[(TS, "fDenyTSConnections")] = 1
    _isolate_fs(monkeypatch, tmp_path)
    res = posture.collect(conn_iter=lambda: [], proc_name=lambda pid: "p", chat_default="local")
    # 计分的只有三项：防火墙 warn、RDP ok、对话默认 ok → 2/3；名称广播等读不到的是「未知」，不计分
    assert res["score"] == 67
    assert res["summary"].startswith("1 项需要注意：Windows 防火墙")
    assert "项读取不到" in res["summary"]
    assert {c["id"] for c in res["checks"] if c["status"] == "unknown"} >= {"naming", "netcat", "adid"}


def _isolate_fs(monkeypatch, tmp_path):
    """自启项检查会读启动文件夹和计划任务目录：指到空目录，不碰真机。"""
    sysroot = tmp_path / "Win"
    (sysroot / "System32" / "Tasks").mkdir(parents=True)
    monkeypatch.setenv("SystemRoot", str(sysroot))
    monkeypatch.setenv("APPDATA", str(tmp_path / "appdata"))
    monkeypatch.setenv("ProgramData", str(tmp_path / "programdata"))


def test_collect_without_pwsh_does_not_spawn_and_reports_unknown(monkeypatch):
    def no_run(*a, **k):
        raise AssertionError("不传 pwsh 时不允许起子进程")
    monkeypatch.setattr(posture.subprocess, "run", no_run)
    FakeReg().install(monkeypatch)
    res = posture.collect(pwsh=None, conn_iter=lambda: [], proc_name=lambda pid: "p")
    by_id = {c["id"]: c for c in res["checks"]}
    assert by_id["netcat"]["status"] == "unknown"
    assert "PowerShell 7" in by_id["netcat"]["detail"]


def test_declared_outbound_lists_every_host():
    hosts = " ".join(x["host"] for x in posture.APP_OUTBOUND_DECLARED)
    for h in ("devbuilds.s.kaspersky-labs.com", "dm.s.kaspersky-labs.com", "nodejs.org", "api.ipify.org"):
        assert h in hosts
    assert all(x["when"] for x in posture.APP_OUTBOUND_DECLARED)


# ---------------------------------------------------------------- 承诺四：API 行为

def _client():
    from fastapi.testclient import TestClient
    return TestClient(server.app, base_url="http://127.0.0.1")


def test_posture_endpoint_returns_collect_result_and_needs_token(monkeypatch):
    monkeypatch.setattr(posture, "collect", lambda **kw: {"read_only": True, "score": 7, "checks": [], "summary": "x", "kw": kw})
    c = _client()
    assert c.get("/api/security/posture").status_code >= 400
    c.headers.update({"X-PF-Token": server._token()})
    r = c.get("/api/security/posture")
    assert r.status_code == 200
    body = r.json()
    assert body["score"] == 7
    assert body["kw"]["chat_default"] in ("cloud", "local")
    assert body["kw"]["pwsh"] is None or isinstance(body["kw"]["pwsh"], str)


def test_exitip_is_post_only():
    c = _client()
    c.headers.update({"X-PF-Token": server._token()})
    assert c.get("/api/security/posture/exitip").status_code == 405


class _FakeResp:
    def __init__(self, status, payload):
        self.status_code, self._p = status, payload

    def json(self):
        return self._p


class _FakeClient:
    calls = []

    def __init__(self, *a, **k):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False

    async def get(self, url, headers=None):
        _FakeClient.calls.append(url)
        return _FakeResp(200, {"ip": "203.0.113.7"})


def test_exitip_audits_before_request_and_returns_ip(monkeypatch):
    import httpx
    order = []
    monkeypatch.setattr(httpx, "AsyncClient", _FakeClient)
    _FakeClient.calls = []
    monkeypatch.setattr(security, "audit", lambda event, **f: order.append(event))
    monkeypatch.setattr(server.security, "audit", lambda event, **f: order.append(event))
    c = _client()
    c.headers.update({"X-PF-Token": server._token()})
    r = c.post("/api/security/posture/exitip")
    assert r.status_code == 200 and r.json()["ip"] == "203.0.113.7"
    assert order[0] == "exitip_check", "必须先写审计再发请求"
    assert _FakeClient.calls == ["https://api.ipify.org?format=json"]


def test_exitip_upstream_failure_is_502_without_body(monkeypatch):
    import httpx

    class Bad(_FakeClient):
        async def get(self, url, headers=None):
            return _FakeResp(500, {"secret": "upstream-body-must-not-leak"})

    events = []
    monkeypatch.setattr(httpx, "AsyncClient", Bad)
    monkeypatch.setattr(server.security, "audit", lambda event, **f: events.append(event))
    c = _client()
    c.headers.update({"X-PF-Token": server._token()})
    r = c.post("/api/security/posture/exitip")
    assert r.status_code == 502
    assert "upstream-body" not in r.text
    assert "exitip_check_failed" in events


def test_exitip_rejects_non_ip_payload(monkeypatch):
    import httpx

    class Weird(_FakeClient):
        async def get(self, url, headers=None):
            return _FakeResp(200, {"ip": "<script>alert(1)</script>"})

    monkeypatch.setattr(httpx, "AsyncClient", Weird)
    monkeypatch.setattr(server.security, "audit", lambda event, **f: None)
    c = _client()
    c.headers.update({"X-PF-Token": server._token()})
    assert c.post("/api/security/posture/exitip").status_code == 502
