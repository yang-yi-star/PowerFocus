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
import json
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
    assert rows[0] == {"proc": "proc10", "ip": "8.8.8.8", "port": 443, "count": 2, "plain": False}
    assert {r["ip"] for r in rows} == {"8.8.8.8", "1.1.1.1"}
    assert rows[1]["proc"] == "(权限不足)"
    assert "1 条读不到归属" in it["value"]


def test_outbound_marks_plaintext_ports():
    conns = [_conn("ESTABLISHED", "1.1.1.1", 80, 10), _conn("ESTABLISHED", "1.0.0.1", 443, 10)]
    it = posture.check_outbound(conn_iter=lambda: conns, proc_name=lambda pid: "p")
    by_port = {r["port"]: r["plain"] for r in it["rows"]}
    assert by_port == {80: True, 443: False}


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
    for cid in ("dnsenc", "httpsonly", "eavesdrop"):
        assert by_id[cid]["status"] == "unknown", cid


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
    import shield
    probe = {"ok": False, "reason": "test"}
    seen = {}
    monkeypatch.setattr(posture, "collect", lambda **kw: {"read_only": True, "score": 7, "checks": [], "summary": "x", "kw": kw})
    monkeypatch.setattr(posture, "content_probe", lambda pwsh=None: probe)      # 不起真进程
    def _status(pwsh=None, probe=None):
        seen["probe"] = probe
        return [{"id": "ad_id", "state": "off"}]
    monkeypatch.setattr(shield, "status", _status)
    c = _client()
    assert c.get("/api/security/posture").status_code >= 400
    c.headers.update({"X-PF-Token": server._token()})
    r = c.get("/api/security/posture")
    assert r.status_code == 200
    body = r.json()
    assert body["score"] == 7
    assert body["kw"]["chat_default"] in ("cloud", "local")
    assert body["kw"]["pwsh"] is None or isinstance(body["kw"]["pwsh"], str)
    # 开关列表随体检一起返回，且复用同一次探测结果
    assert body["shield"][0]["id"] == "ad_id"
    assert body["kw"]["content"] == probe and seen["probe"] is probe


def test_posture_endpoint_keeps_unknown_when_probe_fails(monkeypatch):
    """探测不到 → 内容保密三项必须是 unknown，绝不能当成正常。"""
    FakeReg().install(monkeypatch)
    monkeypatch.setattr(posture, "content_probe", lambda pwsh=None: posture._empty_probe("no_pwsh"))
    monkeypatch.setattr(posture, "check_network_category", lambda pwsh=None: posture._item("netcat", "当前网络类型", "unknown", "--", "", "", "low"))
    res = posture.collect(pwsh=None, conn_iter=lambda: [], proc_name=lambda pid: "p", content=posture._empty_probe("rc_1"))
    by_id = {c["id"]: c for c in res["checks"]}
    assert by_id["dnsenc"]["status"] == "unknown"
    assert by_id["eavesdrop"]["status"] == "unknown"
    # 注册表里没有策略 + 探测不到 Edge → 未知（不是「需注意」，也不是「正常」）
    assert by_id["httpsonly"]["status"] == "unknown"
    assert by_id["tlsfloor"]["status"] == "info"


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


# ---------------------------------------------------------------- 内容保密：别人看得到我在浏览器里干什么
# 这台机器的真实基线（2026-11-25 实测）：主 DNS 223.5.5.5 已加密，备用 223.6.6.6 没有加密模板；
# Edge 158 没有策略；根证书里有 Watt Toolkit 的 CA。下面的假数据照这个形状造。

def _probe(**kw):
    base = {
        "ok": True, "reason": "", "os_build": 26300, "edge_version": "158.0.4370.33",
        "dns_servers": ["223.5.5.5", "223.6.6.6"],
        "doh": {"223.5.5.5": {"has": True, "url": "https://dns.alidns.com/dns-query", "auto": True, "fallback": False}},
        "doh_flags": ["enabled", "enabled"], "roots": [],
    }
    base.update(kw)
    return base


def test_dns_encrypted_backup_server_without_template_is_warn():
    it = posture.check_dns_encrypted(_probe())
    assert it["status"] == "warn" and "223.6.6.6" in it["value"] and "部分明文" in it["value"]


def test_dns_encrypted_all_configured_is_ok_and_admits_provider_sees_queries():
    p = _probe()
    p["doh"]["223.6.6.6"] = {"has": True, "url": "https://dns.alidns.com/dns-query", "auto": True, "fallback": False}
    it = posture.check_dns_encrypted(p)
    assert it["status"] == "ok"
    assert "解析服务商" in it["detail"]      # 如实说明：服务商自己看得到


def test_dns_global_switch_off_beats_per_server_config():
    it = posture.check_dns_encrypted(_probe(doh_flags=["disabled", "enabled"]))
    assert it["status"] == "warn" and "总开关" in it["value"]


def test_dns_encrypted_unreadable_is_unknown_not_ok():
    assert posture.check_dns_encrypted(None)["status"] == "unknown"
    assert posture.check_dns_encrypted({})["status"] == "unknown"
    assert posture.check_dns_encrypted(posture._empty_probe("rc_1"))["status"] == "unknown"


def test_https_only_states(monkeypatch):
    reg = FakeReg()
    reg.install(monkeypatch)
    it = posture.check_https_only(_probe())                       # Edge 够新、没有策略 → 需注意
    assert it["status"] == "warn" and "158.0.4370.33" in it["value"]
    reg.s[("SOFTWARE\\Policies\\Microsoft\\Edge", "HttpsOnlyMode")] = "force_balanced_enabled"
    assert posture.check_https_only(_probe())["status"] == "ok"
    reg.s[("SOFTWARE\\Policies\\Microsoft\\Edge", "HttpsOnlyMode")] = "force_enabled"
    assert "严格" in posture.check_https_only(_probe())["value"]
    reg.s[("SOFTWARE\\Policies\\Microsoft\\Edge", "HttpsOnlyMode")] = "disallowed"
    assert posture.check_https_only(_probe())["status"] == "warn"
    del reg.s[("SOFTWARE\\Policies\\Microsoft\\Edge", "HttpsOnlyMode")]
    assert posture.check_https_only({})["status"] == "unknown"     # 探测不到 → 未知，不是正常
    assert posture.check_https_only(_probe(edge_version=None))["status"] == "info"
    assert posture.check_https_only(_probe(edge_version="120.0.1.0"))["status"] == "info"


def test_tls_floor_is_info_only(monkeypatch):
    reg = FakeReg()
    reg.install(monkeypatch)
    assert posture.check_tls_floor()["status"] == "info" and "系统默认" in posture.check_tls_floor()["value"]
    reg.d[("SYSTEM\\CurrentControlSet\\Control\\SecurityProviders\\SCHANNEL\\Protocols\\TLS 1.0\\Client", "Enabled")] = 1
    it = posture.check_tls_floor()
    assert it["status"] == "info" and "TLS 1.0" in it["value"]


def _root(subject, days, ca=True, key_cert_sign=True, server_auth=False, code_signing=False):
    from datetime import date, timedelta
    start = date(2026, 4, 29)
    return {"subject": subject, "not_before": start.isoformat(), "not_after": (start + timedelta(days=days)).isoformat(),
            "self_signed": True, "store": "LocalMachine\\Root", "is_ca": ca, "key_cert_sign": key_cert_sign,
            "server_auth": server_auth, "code_signing": code_signing, "san": []}


def _no_hosts(monkeypatch):
    monkeypatch.setattr(posture, "_hosts_redirects", lambda: 0)


def test_eavesdrop_known_accelerator_ca_is_info_and_names_the_tool(monkeypatch):
    _no_hosts(monkeypatch)
    FakeReg().install(monkeypatch)
    it = posture.check_eavesdrop(_probe(roots=[_root("C=CN, O=BeyondDimension, CN=SteamTools Certificate", 300)]))
    assert it["status"] == "info" and "1 个私有 CA" in it["value"]
    assert "SteamTools Certificate" in it["detail"] and "Watt Toolkit" in it["detail"]


def test_eavesdrop_unknown_private_ca_is_warn(monkeypatch):
    _no_hosts(monkeypatch)
    FakeReg().install(monkeypatch)
    it = posture.check_eavesdrop(_probe(roots=[_root("CN=某个来路不明的工具", 200)]))
    assert it["status"] == "warn" and "来历不明" in it["detail"]


def test_eavesdrop_non_ca_certs_cannot_impersonate_and_do_not_alarm(monkeypatch):
    _no_hosts(monkeypatch)
    FakeReg().install(monkeypatch)
    roots = [_root("CN=DESKTOP-O1QN1R0", 3650, ca=False, key_cert_sign=False, server_auth=True),
             _root("CN=BTIG Local Dev", 365, ca=False, key_cert_sign=False, code_signing=True)]
    it = posture.check_eavesdrop(_probe(roots=roots))
    assert it["status"] == "info" and "没有私有 CA" in it["value"]
    assert "冒充不了任何网站" in it["detail"] and "代码签名" in it["detail"]


def test_eavesdrop_long_lived_public_roots_are_not_private_ca(monkeypatch):
    _no_hosts(monkeypatch)
    FakeReg().install(monkeypatch)
    it = posture.check_eavesdrop(_probe(roots=[_root("C=US, O=DigiCert Inc, CN=DigiCert Global Root G2", 9000)]))
    assert it["status"] == "info" and "没有私有 CA" in it["value"]


def test_eavesdrop_system_proxy_is_reported(monkeypatch):
    _no_hosts(monkeypatch)
    reg = FakeReg()
    reg.install(monkeypatch)
    inet = "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"
    reg.d[(inet, "ProxyEnable")] = 1
    reg.s[(inet, "ProxyServer")] = "127.0.0.1:7890"
    it = posture.check_eavesdrop(_probe(roots=[]))
    assert it["status"] == "warn" and "127.0.0.1:7890" in it["detail"]
    assert posture.check_eavesdrop({})["status"] == "unknown"


def test_content_probe_without_pwsh_does_not_spawn(monkeypatch):
    def no_run(*a, **k):
        raise AssertionError("没有 pwsh 时不允许起子进程")
    monkeypatch.setattr(posture.subprocess, "run", no_run)
    out = posture.content_probe(None)
    assert out["ok"] is False and out["reason"] == "no_pwsh" and out["roots"] is None


def test_content_probe_normalizes_real_shaped_json(monkeypatch, tmp_path):
    pwsh = tmp_path / "pwsh.exe"
    pwsh.write_text("")
    payload = {
        "ok": True, "os_build": 26300, "edge_version": "158.0.4370.33",
        "ifaces": [{"if": "WLAN", "servers": ["223.5.5.5", "223.6.6.6"]}, {"if": "以太网", "servers": ["223.5.5.5"]}],
        "doh": {"223.5.5.5": {"tpl": "https://dns.alidns.com/dns-query", "auto": True, "fallback": False}},
        "doh_flags": ["enabled", "enabled"], "roots": [{"subject": "CN=医院", "self_signed": True}],
    }
    seen = []

    class R:
        returncode = 0
        stdout = json.dumps(payload, ensure_ascii=False)

    def run(args, **kw):
        seen.append(args)
        return R()

    monkeypatch.setattr(posture.subprocess, "run", run)
    out = posture.content_probe(str(pwsh))
    assert out["ok"] is True
    assert out["dns_servers"] == ["223.5.5.5", "223.6.6.6"]          # 跨网卡去重
    assert out["doh"]["223.5.5.5"]["auto"] is True and out["doh"]["223.5.5.5"]["url"].startswith("https://")
    assert out["doh_flags"] == ["enabled", "enabled"] and out["edge_version"] == "158.0.4370.33"
    assert out["roots"][0]["subject"] == "CN=医院"
    assert seen[0][:4] == [str(pwsh), "-NoProfile", "-NonInteractive", "-Command"]


def test_content_probe_bad_output_is_unknown_not_ok(monkeypatch, tmp_path):
    pwsh = tmp_path / "pwsh.exe"
    pwsh.write_text("")
    monkeypatch.setattr(posture.subprocess, "run", lambda *a, **k: SimpleNamespace(returncode=1, stdout=""))
    assert posture.content_probe(str(pwsh))["reason"] == "rc_1"
    monkeypatch.setattr(posture.subprocess, "run", lambda *a, **k: SimpleNamespace(returncode=0, stdout="[]"))
    assert posture.content_probe(str(pwsh))["reason"] == "bad_json"
    monkeypatch.setattr(posture.subprocess, "run", lambda *a, **k: SimpleNamespace(returncode=0, stdout="{"))
    assert posture.content_probe(str(pwsh))["ok"] is False


def test_content_command_is_read_only_and_makes_no_requests():
    cmd = posture._CONTENT_COMMAND
    for bad in ("Resolve-DnsName", "Invoke-WebRequest", "Invoke-RestMethod", "Set-ItemProperty", "New-ItemProperty",
                "Remove-Item", "Set-DnsClient", "netsh", "curl"):
        assert bad not in cmd.replace("netsh dnsclient show global", ""), bad   # 只允许这一条只读的 show
    assert "Get-DnsClientDohServerAddress" in cmd and "Cert:\\LocalMachine\\Root" in cmd


def test_content_checks_share_one_probe(monkeypatch, tmp_path):
    """collect 收到探测结果时不再自己起进程：三项吃同一份。"""
    FakeReg().install(monkeypatch)
    _isolate_fs(monkeypatch, tmp_path)
    spawns = []

    def no_run(*a, **k):
        spawns.append(a)
        raise AssertionError("已有探测结果时不允许再起子进程")

    monkeypatch.setattr(posture.subprocess, "run", no_run)
    monkeypatch.setattr(posture, "check_network_category",
                        lambda pwsh=None: posture._item("netcat", "当前网络类型", "unknown", "--", "", "", "low"))
    res = posture.collect(pwsh="pwsh.exe", conn_iter=lambda: [], proc_name=lambda pid: "p",
                          content=_probe(doh_flags=["disabled", "enabled"]))
    assert spawns == []
    by_id = {c["id"]: c for c in res["checks"]}
    assert by_id["dnsenc"]["status"] == "warn" and by_id["httpsonly"]["status"] == "warn"
    # 其余读不到的不计分；DNS 需注意、HTTPS 需注意 → 0/2
    assert res["score"] == 0 and res["summary"].startswith("2 项需要注意")


# ---------------------------------------------------------------- 真机事故回归（2026-11-25，真机踩坑）

def test_read_helpers_return_value_not_type_code(monkeypatch):
    """真机事故：QueryValueEx 返回 (数据, 类型)，read_* 一度拿 [1]（类型码）当值。
    这台机器的开关值恰好都是 1、DWORD 的类型码恰好是 4，碰巧没露馅——第一次写 0 才暴露。
    假值故意选「值 ≠ 类型码」的组合，顺序再拿反必红。"""
    monkeypatch.setattr(posture, "_read_value", lambda root, path, name: (1, 4))
    assert posture.read_dword(posture.HKLM, "x", "y") == 1        # 拿反会读到 4
    monkeypatch.setattr(posture, "_read_value", lambda root, path, name: ("Allow", 1))
    assert posture.read_str(posture.HKLM, "x", "y") == "Allow"    # 拿反会读到 "1"
    monkeypatch.setattr(posture, "_read_value", lambda root, path, name: (b"\x01", 3))
    assert posture.read_bytes(posture.HKLM, "x", "y") == b"\x01"
    monkeypatch.setattr(posture, "_read_value", lambda root, path, name: ("0x1", 4))
    assert posture.read_dword(posture.HKLM, "x", "y") is None    # 非数值仍按读不到处理
