# -*- coding: utf-8 -*-
"""防护开关（shield.py）回归。

钉死的承诺（每条对应一个容易悄悄破掉的地方）：
  · 先记后改：还原日志写不进去 → 一个字节都不改系统；
  · 改完必验：复验不通过 → 当场自动还原，系统回到原样；
  · 还原即原样：原来没有的值删掉、我们建的空键删掉；原来有的按原类型原值写回；
  · 不越界：源码里不许出现删证书 / 改代理 / 改防火墙 / 网络库；
  · 单一真相源：开关的「已收紧」= 对应体检项的「正常」；
  · 接口：必须带令牌、只收 POST、不认识的开关一律 400。

隔离原则：注册表走内存假表（shield 的原语和 posture 的读指向同一张表），命令走假执行器，
还原日志指到 tmp_path。全程不读、不写真机，不起真进程。
"""
import json
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
import shield  # noqa: E402

RA = "SYSTEM\\CurrentControlSet\\Control\\Remote Assistance"
ADID = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo"
EDGE = "SOFTWARE\\Policies\\Microsoft\\Edge"
MC = "SOFTWARE\\Policies\\Microsoft\\Windows NT\\DNSClient"
NB = "SYSTEM\\CurrentControlSet\\Services\\NetBT\\Parameters\\Interfaces"
T_DWORD, T_SZ = shield._REG_DWORD, shield._REG_SZ
LM, CU = shield.HKLM, shield.HKCU


# ---------------------------------------------------------------- 内存假注册表：shield 写进去的，posture 读得出来

class Store:
    def __init__(self):
        self.vals = {}     # (hive, path, name) -> (type, value)
        self.keys = set()  # 没有值、但确实存在的键
        self.subs = {}     # path -> [子键名]

    def _all_keys(self):
        return self.keys | {(h, p) for (h, p, _n) in self.vals}

    def exists(self, hive, path):
        return (hive, path) in self._all_keys()

    def children(self, hive, path):
        pref = path + "\\"
        n_sub = sum(1 for (h, p) in self._all_keys() if h == hive and p.startswith(pref) and "\\" not in p[len(pref):])
        n_val = sum(1 for (h, p, _n) in self.vals if h == hive and p == path)
        return n_sub, n_val

    def install(self, monkeypatch):
        m = monkeypatch
        m.setattr(shield, "_key_exists", self.exists)
        # 假表按 QueryValueEx 的真实顺序存 (数据, 类型)——真机事故就是顺序拿反了，假表必须与真实 API 同序
        m.setattr(shield, "_read_raw", lambda hive, path, name: self.vals.get((hive, path, name)))
        m.setattr(shield, "_write_value",
                  lambda hive, path, name, typ, value: self.vals.__setitem__((hive, path, name), (value, typ)))
        m.setattr(shield, "_delete_value", lambda hive, path, name: self.vals.pop((hive, path, name), None))
        m.setattr(shield, "_key_is_empty", lambda hive, path: self.exists(hive, path) and self.children(hive, path) == (0, 0))
        m.setattr(shield, "_delete_key", lambda hive, path: self.keys.discard((hive, path)))

        def rd(root, path, name):
            v = self.vals.get((root, path, name))
            return v[0] if v and v[1] == T_DWORD else None

        def rs(root, path, name):
            v = self.vals.get((root, path, name))
            return v[0] if v and isinstance(v[0], str) else None

        m.setattr(posture, "read_dword", rd)
        m.setattr(posture, "read_str", rs)
        m.setattr(posture, "enum_subkeys", lambda root, path: list(self.subs.get(path, [])))
        return self


class Runner:
    def __init__(self, rc=0):
        self.calls = []
        self.rc = rc

    def __call__(self, args):
        self.calls.append([str(x) for x in args])
        return self.rc, ""


@pytest.fixture
def rig(tmp_path, monkeypatch):
    """每个用例一套：假注册表 + 隔离的还原日志 + 收集到的审计事件。"""
    monkeypatch.setenv("PF_SHIELD_JOURNAL", str(tmp_path / "shield" / "journal.json"))
    monkeypatch.setattr(security, "protect_file", lambda p, writable=False: True)
    events = []
    monkeypatch.setattr(security, "audit", lambda event, **f: events.append((event, f)))
    box = SimpleNamespace(store=Store().install(monkeypatch), events=events, tmp=tmp_path)
    return box


def _pwsh(rig):
    """需要一个「存在」的 pwsh 路径：探测函数已被替换，不会真的起进程。"""
    p = rig.tmp / "pwsh.exe"
    p.write_text("")
    return str(p)


def _probe(**kw):
    base = {
        "ok": True, "reason": "", "os_build": 26300, "edge_version": "158.0.4370.33", "roots": [],
        "dns_servers": ["223.5.5.5", "223.6.6.6"],
        "doh": {"223.5.5.5": {"has": True, "url": shield.DOH_TEMPLATE, "auto": True, "fallback": False}},
        "doh_flags": ["enabled", "enabled"],
    }
    base.update(kw)
    return base


def _backup_encrypted(p):
    p["doh"]["223.6.6.6"] = {"has": True, "url": shield.DOH_TEMPLATE, "auto": True, "fallback": False}
    return p


# ---------------------------------------------------------------- 开关清单：用户看得到的字段一个不少

def test_every_action_declares_what_the_user_sees():
    for aid, act in shield.ACTIONS.items():
        for k in ("title", "scope", "why", "risk", "admin", "recommended", "probe", "check", "apply"):
            assert k in act, (aid, k)
        assert act["title"] and act["why"] and act["scope"]
    assert list(shield.ACTIONS) == list(shield.ACTION_ORDER)
    # 名称广播不在推荐项里：家里靠电脑名找 NAS / 打印机的人会被它坑到，默认不动
    assert shield.recommended_ids() == ["https_only_edge", "doh_all", "remote_assist", "ad_id"]
    assert shield.ACTIONS["name_broadcast"]["recommended"] is False


def test_unknown_id_is_rejected_without_touching_anything(rig):
    res = shield.apply(["nope"])
    assert res == [{"id": "nope", "ok": False, "error": "没有这个开关"}]
    assert rig.store.vals == {} and shield._load()["entries"] == []
    # 一项不认识，不影响同一批里认识的那些
    assert shield.apply(["nope", "ad_id"])[1]["ok"] is True


# ---------------------------------------------------------------- 真机事故回归（2026-11-25，真机踩坑）

def test_store_order_matches_queryvalueex(rig):
    """假表必须按 (数据, 类型) 存——与 winreg.QueryValueEx 同序。
    拿反的假表会把拿反的实现也测成绿的（真机第一次跑就翻车，测试却全绿）。"""
    rig.store.vals[(LM, RA, "fAllowToGetHelp")] = (1, T_DWORD)
    assert shield._read_raw(LM, RA, "fAllowToGetHelp") == (1, T_DWORD)
    ctx = shield._Ctx()
    ctx.reg_set("HKLM", RA, "fAllowToGetHelp", T_DWORD, 0)
    assert ctx.undo[0]["value"] == 1 and ctx.undo[0]["type"] == T_DWORD
    assert rig.store.vals[(LM, RA, "fAllowToGetHelp")] == (0, T_DWORD)


def test_rollback_restores_original_value_not_type_code(rig):
    """真机事故的直接回归：值原为 1、类型码为 4（DWORD）。
    顺序拿反时，还原会拿类型码 1 当类型、值 4 当数据写回——注册表当场报「类型转换失败」。"""
    rig.store.vals[(LM, RA, "fAllowToGetHelp")] = (1, T_DWORD)
    assert shield.apply(["remote_assist"])[0]["ok"] is True
    assert rig.store.vals[(LM, RA, "fAllowToGetHelp")] == (0, T_DWORD)
    assert shield.revert() == [{"id": "remote_assist", "ok": True, "title": "远程协助"}]
    assert rig.store.vals[(LM, RA, "fAllowToGetHelp")] == (1, T_DWORD)   # 值 1 回来了，不是 4
    assert posture.check_remote_assist()["status"] == "warn"              # posture 也按真值判


def test_failed_rollback_still_journals_the_change_for_later_revert(rig, monkeypatch):
    """真机事故二：自动还原失败时系统停在改过的状态——必须把改动记入还原日志，
    否则用户失去还原途径；记入后故障排除仍能从应用里还原。"""
    rig.store.vals[(CU, ADID, "Enabled")] = (1, T_DWORD)
    monkeypatch.setattr(posture, "check_adid", lambda: posture._item("adid", "广告 ID", "warn", "已开启", "", "", "low"))
    real_write = shield._write_value
    calls = []

    def flaky(hive, path, name, typ, value):
        calls.append(value)
        if len(calls) >= 2:
            raise RuntimeError("write denied")     # 第 1 次正向写入成功，第 2 次回滚还原失败
        real_write(hive, path, name, typ, value)

    monkeypatch.setattr(shield, "_write_value", flaky)
    res = shield.apply(["ad_id"])
    assert res[0]["ok"] is False and "记入还原日志" in res[0]["note"]
    assert rig.store.vals[(CU, ADID, "Enabled")] == (0, T_DWORD)        # 系统停在改过的状态
    entries = shield._load()["entries"]
    assert [e["id"] for e in entries] == ["ad_id"]
    assert entries[0]["undo"][0]["value"] == 1 and entries[0]["undo"][0]["type"] == T_DWORD
    monkeypatch.setattr(shield, "_write_value", real_write)
    assert shield.revert(["ad_id"])[0]["ok"] is True
    assert rig.store.vals[(CU, ADID, "Enabled")] == (1, T_DWORD)        # 之后仍能还原回去


# ---------------------------------------------------------------- 承诺三：还原即原样

def test_apply_then_revert_restores_previous_value_and_type(rig):
    rig.store.vals[(CU, ADID, "Enabled")] = (1, T_DWORD)
    res = shield.apply(["ad_id"])
    assert res == [{"id": "ad_id", "ok": True, "state": "on", "title": "广告 ID", "note": ""}]
    assert rig.store.vals[(CU, ADID, "Enabled")] == (0, T_DWORD)
    assert posture.check_adid()["status"] == "ok"                       # 单一真相源
    entries = shield._load()["entries"]
    assert [e["id"] for e in entries] == ["ad_id"]
    assert entries[0]["undo"][0]["existed"] is True and entries[0]["undo"][0]["value"] == 1

    assert shield.revert(["ad_id"]) == [{"id": "ad_id", "ok": True, "title": "广告 ID"}]
    assert rig.store.vals[(CU, ADID, "Enabled")] == (1, T_DWORD)
    assert shield._load()["entries"] == []
    assert [e for e, _f in rig.events] == ["shield_apply", "shield_revert"]


def test_revert_writes_back_the_original_string_not_just_the_default(rig, monkeypatch):
    monkeypatch.setattr(posture, "content_probe", lambda pwsh=None: _probe())
    rig.store.vals[(CU, EDGE, "HttpsOnlyMode")] = ("disallowed", T_SZ)
    assert shield.apply(["https_only_edge"], _pwsh(rig))[0]["ok"] is True
    assert rig.store.vals[(CU, EDGE, "HttpsOnlyMode")] == ("force_balanced_enabled", T_SZ)
    assert posture.check_https_only(_probe())["status"] == "ok"
    shield.revert()
    assert rig.store.vals[(CU, EDGE, "HttpsOnlyMode")] == ("disallowed", T_SZ)   # 原值、原类型


def test_revert_removes_value_and_the_empty_key_we_created(rig, monkeypatch):
    monkeypatch.setattr(posture, "content_probe", lambda pwsh=None: _probe())
    rig.store.keys.add((CU, "SOFTWARE\\Policies"))            # 父键本来就有；Edge 子键本来没有
    shield.apply(["https_only_edge"], _pwsh(rig))
    assert rig.store.exists(CU, EDGE) and (CU, EDGE, "HttpsOnlyMode") in rig.store.vals
    shield.revert()
    assert (CU, EDGE, "HttpsOnlyMode") not in rig.store.vals
    assert not rig.store.exists(CU, EDGE)                     # 我们建的空键一并删掉
    assert rig.store.exists(CU, "SOFTWARE\\Policies")         # 原有的父键不动


def test_revert_keeps_a_key_that_existed_before_even_if_now_empty(rig, monkeypatch):
    monkeypatch.setattr(posture, "content_probe", lambda pwsh=None: _probe())
    rig.store.keys.add((CU, EDGE))                            # 这个键用户本来就有（空的）
    shield.apply(["https_only_edge"], _pwsh(rig))
    shield.revert()
    assert (CU, EDGE, "HttpsOnlyMode") not in rig.store.vals
    assert rig.store.exists(CU, EDGE)                         # 不是我们建的，不删


def test_revert_with_empty_journal_is_a_noop(rig):
    assert shield.revert() == []
    assert shield.revert(["ad_id"]) == []


# ---------------------------------------------------------------- 承诺一：先记后改

def test_unwritable_journal_means_not_a_single_byte_changes(rig, monkeypatch):
    blocker = rig.tmp / "blocker"
    blocker.write_text("x")                                   # 让日志目录建不出来
    monkeypatch.setenv("PF_SHIELD_JOURNAL", str(blocker / "journal.json"))
    rig.store.vals[(CU, ADID, "Enabled")] = (1, T_DWORD)
    res = shield.apply(["ad_id"])
    assert res[0]["ok"] is False and "还原日志" in res[0]["error"]
    assert rig.store.vals[(CU, ADID, "Enabled")] == (1, T_DWORD)


def test_journal_records_how_to_undo_before_reporting_success(rig):
    rig.store.vals[(LM, RA, "fAllowToGetHelp")] = (1, T_DWORD)
    assert shield.apply(["remote_assist"])[0]["ok"] is True
    raw = json.loads(shield.journal_path().read_text(encoding="utf-8"))
    assert raw["entries"][0]["id"] == "remote_assist"
    undo = raw["entries"][0]["undo"][0]
    assert undo["op"] == "reg" and undo["hive"] == "HKLM"
    assert undo["path"] == RA and undo["name"] == "fAllowToGetHelp"
    assert undo["existed"] is True and undo["type"] == T_DWORD and undo["value"] == 1


# ---------------------------------------------------------------- 承诺二：改完必验

def test_verify_failure_rolls_back_automatically(rig, monkeypatch):
    rig.store.vals[(CU, ADID, "Enabled")] = (1, T_DWORD)
    monkeypatch.setattr(posture, "check_adid",
                        lambda: posture._item("adid", "广告 ID", "warn", "已开启", "", "", "low"))
    res = shield.apply(["ad_id"])
    assert res[0]["ok"] is False and "复验" in res[0]["error"] and "已自动还原" in res[0]["note"]
    assert rig.store.vals[(CU, ADID, "Enabled")] == (1, T_DWORD)       # 回到原样
    assert shield._load()["entries"] == []                            # 不留半截记录


def test_every_result_carries_a_human_readable_title(rig, monkeypatch):
    """界面要显示「DNS 查询全加密：没有权限…」，不能只甩一个 doh_all 给用户看。"""
    rig.store.vals[(CU, ADID, "Enabled")] = (1, T_DWORD)
    monkeypatch.setattr(posture, "check_adid", lambda: posture._item("adid", "广告 ID", "warn", "已开启", "", "", "low"))
    assert shield.apply(["ad_id"])[0]["title"] == "广告 ID"                      # 复验失败
    monkeypatch.setattr(posture, "content_probe", lambda pwsh=None: _probe())
    monkeypatch.setattr(shield, "_default_run", Runner(rc=1))
    assert shield.apply(["doh_all"], _pwsh(rig))[0]["title"] == "DNS 查询全加密"   # 命令失败
    assert shield.apply(["doh_all"], None)[0]["title"] == "DNS 查询全加密"         # 没法探测
    blocker = rig.tmp / "blocker"
    blocker.write_text("x")
    monkeypatch.setenv("PF_SHIELD_JOURNAL", str(blocker / "journal.json"))
    res = shield.apply(["remote_assist", "nope"])
    assert res[0]["title"] == "远程协助" and res[1]["title"] == "nope"


def test_verify_step_crashing_counts_as_not_verified(rig, monkeypatch):
    rig.store.vals[(CU, EDGE, "HttpsOnlyMode")] = ("disallowed", T_SZ)
    calls = []

    def flaky(pwsh=None):
        calls.append(1)
        if len(calls) == 1:
            return _probe()
        raise OSError("probe died")

    monkeypatch.setattr(posture, "content_probe", flaky)
    res = shield.apply(["https_only_edge"], _pwsh(rig))
    assert res[0]["ok"] is False
    assert rig.store.vals[(CU, EDGE, "HttpsOnlyMode")] == ("disallowed", T_SZ)


def test_already_tightened_is_reported_without_changing_anything(rig, monkeypatch):
    rig.store.vals[(CU, ADID, "Enabled")] = (0, T_DWORD)
    runner = Runner()
    monkeypatch.setattr(shield, "_default_run", runner)
    res = shield.apply(["ad_id"])
    assert res[0]["ok"] is True and res[0]["state"] == "on" and "没有改动" in res[0]["note"]
    assert shield._load()["entries"] == [] and runner.calls == []


# ---------------------------------------------------------------- 失败路径：不留半截状态，话说清楚

def test_partial_failure_rolls_back_what_was_already_written(rig, monkeypatch):
    rig.store.subs[NB] = ["Tcpip_{1}"]
    real_write = shield._write_value

    def flaky(hive, path, name, typ, value):
        if name == "NetbiosOptions":
            raise PermissionError("denied")
        real_write(hive, path, name, typ, value)

    monkeypatch.setattr(shield, "_write_value", flaky)
    res = shield.apply(["name_broadcast"])
    assert res[0]["ok"] is False and "已按原值还原" in res[0]["note"]
    assert not any(p == MC for (_h, p, _n) in rig.store.vals)          # 第一步写的也被撤回
    assert shield._load()["entries"] == []


def test_permission_error_is_explained_as_needing_admin(monkeypatch):
    def boom(*a, **k):
        raise PermissionError("denied")

    monkeypatch.setattr(shield, "winreg", SimpleNamespace(CreateKeyEx=boom, SetValueEx=boom))
    with pytest.raises(RuntimeError) as ei:
        shield._write_value(LM, "X", "Y", T_DWORD, 0)
    assert "管理员" in str(ei.value)


def test_command_failure_is_reported_and_nothing_is_journaled(rig, monkeypatch):
    monkeypatch.setattr(posture, "content_probe", lambda pwsh=None: _probe())
    monkeypatch.setattr(shield, "_default_run", Runner(rc=1))
    res = shield.apply(["doh_all"], _pwsh(rig))
    assert res[0]["ok"] is False and "netsh" in res[0]["error"] and "退出码 1" in res[0]["error"]
    assert shield._load()["entries"] == []


def test_doh_action_needing_probe_without_pwsh_is_refused_before_running(rig, monkeypatch):
    runner = Runner()
    monkeypatch.setattr(shield, "_default_run", runner)
    res = shield.apply(["doh_all"], None)
    assert res[0]["ok"] is False and "PowerShell 7" in res[0]["error"]
    assert runner.calls == []


# ---------------------------------------------------------------- DNS 全加密：改什么、就只还原什么

def test_doh_action_configures_the_unencrypted_server_and_undoes_exactly_that(rig, monkeypatch):
    before = _probe()
    probes = [before, _backup_encrypted(_probe())]
    monkeypatch.setattr(posture, "content_probe", lambda pwsh=None: probes.pop(0))
    runner = Runner()
    monkeypatch.setattr(shield, "_default_run", runner)
    assert posture.check_dns_encrypted(before)["status"] == "warn"

    res = shield.apply(["doh_all"], _pwsh(rig))
    assert res[0]["ok"] is True
    assert runner.calls == [[
        "netsh", "dnsclient", "add", "encryption", "server=223.6.6.6",
        "dohtemplate=https://dns.alidns.com/dns-query", "autoupgrade=yes", "udpfallback=no"]]

    assert shield.revert() == [{"id": "doh_all", "ok": True, "title": "DNS 查询全加密"}]
    assert runner.calls[1] == ["netsh", "dnsclient", "delete", "encryption", "server=223.6.6.6"]
    assert len(runner.calls) == 2                                  # 已经加密的 223.5.5.5 一点没碰


def test_doh_action_turns_global_switch_on_and_restores_it(rig, monkeypatch):
    before = _probe(doh_flags=["disabled", "enabled"])
    after = _backup_encrypted(_probe(doh_flags=["enabled", "enabled"]))
    probes = [before, after]
    monkeypatch.setattr(posture, "content_probe", lambda pwsh=None: probes.pop(0))
    runner = Runner()
    monkeypatch.setattr(shield, "_default_run", runner)
    assert shield.apply(["doh_all"], _pwsh(rig))[0]["ok"] is True
    assert runner.calls[-1] == ["netsh", "dnsclient", "set", "global", "doh=yes"]
    shield.revert()
    assert ["netsh", "dnsclient", "set", "global", "doh=disabled"] in runner.calls   # 回到原值
    assert len(runner.calls) == 4                                       # 改两步、还原两步，仅此而已


def test_default_runner_takes_system_tools_from_system32_not_cwd(rig, monkeypatch):
    seen = []

    def run(args, **kw):
        seen.append(args)
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    monkeypatch.setattr(shield.subprocess, "run", run)
    assert shield._default_run(["netsh", "dnsclient", "show", "global"]) == (0, "")
    assert seen[0][0].lower().endswith("\\system32\\netsh.exe")


# ---------------------------------------------------------------- 承诺五：单一真相源 + 状态

def test_status_mirrors_posture_and_marks_what_is_journaled(rig, monkeypatch):
    monkeypatch.setattr(posture, "content_probe", lambda pwsh=None: _probe())
    rig.store.vals[(LM, RA, "fAllowToGetHelp")] = (1, T_DWORD)
    items = {x["id"]: x for x in shield.status(pwsh=_pwsh(rig))}
    assert [x["id"] for x in shield.status(pwsh=_pwsh(rig))] == list(shield.ACTION_ORDER)
    assert items["remote_assist"]["state"] == "off" and items["remote_assist"]["admin"] is True
    assert items["ad_id"]["state"] == "unknown" and items["ad_id"]["value"] == "--"
    assert items["https_only_edge"]["state"] == "off" and items["doh_all"]["state"] == "off"
    assert items["name_broadcast"]["journaled"] is False

    shield.apply(["remote_assist"], _pwsh(rig))
    items = {x["id"]: x for x in shield.status(pwsh=_pwsh(rig))}
    assert items["remote_assist"]["state"] == "on" and items["remote_assist"]["journaled"] is True
    assert posture.check_remote_assist()["status"] == "ok"


def test_status_with_unreadable_state_says_unknown_instead_of_off(rig, monkeypatch):
    monkeypatch.setattr(posture, "check_adid", lambda: (_ for _ in ()).throw(OSError("x")))
    items = {x["id"]: x for x in shield.status(probe=_probe())}
    assert items["ad_id"]["state"] == "unknown"


def test_status_reuses_a_given_probe_and_spawns_nothing(rig, monkeypatch):
    def no_probe(pwsh=None):
        raise AssertionError("已有探测结果时不许再探测")

    monkeypatch.setattr(posture, "content_probe", no_probe)
    assert len(shield.status(probe=_probe())) == len(shield.ACTION_ORDER)


# ---------------------------------------------------------------- DNS 实测：结论必须有依据

def _dns_run(monkeypatch, payload=None, rc=0, raw=None):
    seen = []

    def run(args, **kw):
        seen.append(args)
        return SimpleNamespace(returncode=rc, stdout=raw if raw is not None else json.dumps(payload))

    monkeypatch.setattr(shield.subprocess, "run", run)
    return seen


def test_dns_check_says_encrypted_only_when_connections_are_443_and_all_configured(rig, monkeypatch):
    _dns_run(monkeypatch, {"servers": ["223.5.5.5"], "conns": [{"ip": "223.5.5.5", "port": 443}], "doh": ["223.5.5.5"]})
    r = shield.dns_check(_pwsh(rig))
    assert r["encrypted"] is True and r["via"] == ["223.5.5.5:443"] and "443" in r["detail"]


def test_dns_check_catches_plaintext_port_53(rig, monkeypatch):
    _dns_run(monkeypatch, {"servers": ["223.6.6.6"], "conns": [{"ip": "223.6.6.6", "port": 53}], "doh": []})
    r = shield.dns_check(_pwsh(rig))
    assert r["encrypted"] is False and "明文" in r["detail"] and r["via"] == ["223.6.6.6:53"]


def test_dns_check_refuses_to_conclude_without_evidence(rig, monkeypatch):
    # 没抓到连接 + 有服务器没配加密 → 判断不了（不是「正常」，也不是「有问题」）
    _dns_run(monkeypatch, {"servers": ["223.5.5.5", "223.6.6.6"], "conns": [], "doh": ["223.5.5.5"]})
    assert shield.dns_check(_pwsh(rig))["encrypted"] is None
    # 没抓到连接 + 全都配了加密 → 按配置算加密，并在说明里写明是按配置
    _dns_run(monkeypatch, {"servers": ["223.5.5.5"], "conns": [], "doh": ["223.5.5.5"]})
    r = shield.dns_check(_pwsh(rig))
    assert r["encrypted"] is True and "按配置" in r["detail"]
    # 这次走了 443，但有服务器没配加密 → 仍然不下「加密」的结论
    _dns_run(monkeypatch, {"servers": ["223.5.5.5", "223.6.6.6"],
                           "conns": [{"ip": "223.5.5.5", "port": 443}], "doh": ["223.5.5.5"]})
    assert shield.dns_check(_pwsh(rig))["encrypted"] is None


def test_dns_check_bad_inputs_never_claim_encrypted(rig, monkeypatch):
    _dns_run(monkeypatch, {"servers": [], "conns": [], "doh": []})
    assert shield.dns_check(_pwsh(rig))["encrypted"] is None
    _dns_run(monkeypatch, rc=1)
    assert shield.dns_check(_pwsh(rig))["encrypted"] is None
    _dns_run(monkeypatch, raw="{")
    assert shield.dns_check(_pwsh(rig))["encrypted"] is None

    def no_run(*a, **k):
        raise AssertionError("没有 pwsh 时不允许起子进程")

    monkeypatch.setattr(shield.subprocess, "run", no_run)
    assert shield.dns_check(None)["encrypted"] is None


def test_dns_check_only_resolves_a_random_nonexistent_name_and_visits_no_website():
    cmd = shield._DNSCHECK_COMMAND
    assert "Resolve-DnsName" in cmd and "[guid]::NewGuid()" in cmd
    for bad in ("Invoke-WebRequest", "Invoke-RestMethod", "curl", "Set-", "Remove-Item", "New-Item"):
        assert bad not in cmd


# ---------------------------------------------------------------- 承诺五：不越界（结构锁）

def test_shield_source_stays_within_its_declared_bounds():
    src = (APP_DIR / "shield.py").read_text(encoding="utf-8")
    # 不删证书、不改代理、不改防火墙、不删文件、不联网
    for bad in ("Cert:", "certutil", "ProxyEnable", "ProxyServer", "AutoConfigURL", "advfirewall",
                "Remove-Item", "import httpx", "import socket", "import requests", "import urllib",
                "rmdir", "unlink(", "os.remove"):
        assert bad not in src, "shield.py 越界：%s" % bad
    # 网络设置只允许动 DNS 加密这一类
    netsh = [ln.strip() for ln in src.splitlines() if '"netsh"' in ln]
    assert netsh and all('"dnsclient"' in ln and ('"encryption"' in ln or '"global"' in ln) for ln in netsh)


# ---------------------------------------------------------------- 承诺六：接口

def _client():
    from fastapi.testclient import TestClient
    return TestClient(server.app, base_url="http://127.0.0.1")


PATHS = ("/api/security/shield/apply", "/api/security/shield/revert", "/api/security/shield/dnscheck")


def test_shield_endpoints_need_token_and_only_accept_post():
    c = _client()
    for path in PATHS:
        assert c.get(path).status_code >= 400
        assert c.post(path, json={}).status_code >= 400            # 没带令牌
    c.headers.update({"X-PF-Token": server._token()})
    for path in PATHS:
        assert c.get(path).status_code == 405


def test_apply_endpoint_rejects_malformed_and_unknown_ids(rig):
    c = _client()
    c.headers.update({"X-PF-Token": server._token()})
    url = "/api/security/shield/apply"
    assert c.post(url, json={}).status_code == 400
    assert c.post(url, json={"ids": []}).status_code == 400
    assert c.post(url, json={"ids": "ad_id"}).status_code == 400
    assert c.post(url, json={"ids": [1]}).status_code == 400
    assert c.post(url, json={"ids": ["ad_id", "nope"]}).status_code == 400
    assert c.post(url, content=b"not json", headers={"Content-Type": "application/json"}).status_code == 400
    assert rig.events == []                                        # 被拒的请求不进审计，也不动系统


def test_apply_endpoint_passes_ids_deduplicated_and_returns_per_item_results(rig, monkeypatch):
    seen = {}

    def fake_apply(ids, pwsh=None):
        seen["ids"], seen["pwsh"] = ids, pwsh
        return [{"id": "ad_id", "ok": True, "state": "on", "title": "广告 ID"},
                {"id": "remote_assist", "ok": False, "error": "没有权限写入（这一项需要以管理员身份运行本应用）"}]

    monkeypatch.setattr(shield, "apply", fake_apply)
    monkeypatch.setattr(server, "_pwsh", lambda: "pwsh.exe")
    c = _client()
    c.headers.update({"X-PF-Token": server._token()})
    r = c.post("/api/security/shield/apply", json={"ids": ["ad_id", "remote_assist", "ad_id"]})
    assert r.status_code == 200
    assert seen["ids"] == ["ad_id", "remote_assist"] and seen["pwsh"] == "pwsh.exe"
    body = r.json()
    assert [x["ok"] for x in body["results"]] == [True, False]      # 一项失败不影响其他项的回报
    assert [e for e, _f in rig.events] == ["shield_apply_request"]


def test_revert_endpoint_all_or_selected(rig, monkeypatch):
    seen = []
    monkeypatch.setattr(shield, "revert", lambda ids: seen.append(ids) or [])
    c = _client()
    c.headers.update({"X-PF-Token": server._token()})
    assert c.post("/api/security/shield/revert", json={"all": True}).status_code == 200
    assert c.post("/api/security/shield/revert", json={"ids": ["ad_id"]}).status_code == 200
    assert c.post("/api/security/shield/revert", json={"all": "yes"}).status_code == 400   # 只认真正的 true
    assert seen == [None, ["ad_id"]]


def test_dnscheck_endpoint_returns_the_verdict(rig, monkeypatch):
    verdict = {"encrypted": True, "via": ["223.5.5.5:443"], "servers": ["223.5.5.5"], "detail": "x", "ts": "t"}
    monkeypatch.setattr(shield, "dns_check", lambda pwsh: verdict)
    c = _client()
    c.headers.update({"X-PF-Token": server._token()})
    r = c.post("/api/security/shield/dnscheck")
    assert r.status_code == 200 and r.json()["encrypted"] is True
