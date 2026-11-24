# -*- coding: utf-8 -*-
"""防护开关（隐私防护 P1）：把体检里发现的开口关上，每一项都能原样还原。

对用户承诺（测试逐条钉死，改这里先改测试）：
  1. 先记后改：动注册表之前先把原值记进还原日志；日志写不进去就不动系统。
  2. 改完必验：动作跑完立刻复验；没验上就当场自动还原，不让系统停在半截状态。
  3. 还原即原样：原来没有的值删掉（我们建的空键一并删），原来有的按原类型原值写回；
     命令类动作按逆操作还原。
  4. 全程审计：apply / revert / 失败 / 自动回滚都写 security.log。
  5. 不越界：只碰下面列出的几个注册表键和 netsh dnsclient；不删证书、不改代理、
     不动防火墙、不动第三方程序；不做 VPN / 代理改道。
  6. 单一真相源：一项算不算「已收紧」，以 posture 里对应的体检项为准——开关说关上了，
     体检就一定显示正常，两者不会各说各话。

取值依据（官方文档，查过再用）：
  - 远程协助：HKLM 下 SYSTEM/CurrentControlSet/Control/Remote Assistance 的 fAllowToGetHelp = 0
  - 广告 ID：HKCU 下 Software/Microsoft/Windows/CurrentVersion/AdvertisingInfo 的 Enabled = 0
      https://learn.microsoft.com/en-us/windows/privacy/manage-connections-from-windows-operating-system-components-to-microsoft-services
  - Edge 强制加密：HKCU 下 SOFTWARE/Policies/Microsoft/Edge 的 HttpsOnlyMode = "force_balanced_enabled"（REG_SZ，Edge 140+）
      https://learn.microsoft.com/de-de/deployedge/microsoft-edge-policies/HttpsOnlyMode
  - 名称广播：HKLM 下 SOFTWARE/Policies/Microsoft/Windows NT/DNSClient 的 EnableMulticast = 0；
      NetBIOS：HKLM 下 SYSTEM/CurrentControlSet/Services/NetBT/Parameters/Interfaces/Tcpip_* 的 NetbiosOptions = 2
  - DNS 加密：netsh dnsclient add|set encryption server=<IP> dohtemplate=<URL> autoupgrade=yes udpfallback=no；
      netsh dnsclient set global doh=yes；还原用 delete encryption / set global doh=<原值>
      https://learn.microsoft.com/en-gb/windows-server/administration/windows-commands/netsh-dnsclient
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from pathlib import Path

try:
    import winreg
except ImportError:
    winreg = None

import posture
import security

HKLM = getattr(winreg, "HKEY_LOCAL_MACHINE", None)
HKCU = getattr(winreg, "HKEY_CURRENT_USER", None)
_REG_SZ = getattr(winreg, "REG_SZ", 1)
_REG_DWORD = getattr(winreg, "REG_DWORD", 4)
_WOW64 = getattr(winreg, "KEY_WOW64_64KEY", 0)
_SET = (getattr(winreg, "KEY_SET_VALUE", 0) | (getattr(winreg, "KEY_READ", 0)))

DOH_TEMPLATE = "https://dns.alidns.com/dns-query"   # 阿里公共 DNS 的加密端点，与系统内置名单一致
_EDGE_POLICY = r"SOFTWARE\Policies\Microsoft\Edge"
_RA_PATH = r"SYSTEM\CurrentControlSet\Control\Remote Assistance"
_ADID_PATH = r"SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
_MC_PATH = r"SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
_NB_BASE = r"SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces"

_LOCK = threading.RLock()


# ---------------------------------------------------------------- 还原日志

def journal_path() -> Path:
    """还原日志落在本机应用数据目录（不落移动盘 / 仓库），可用 PF_SHIELD_JOURNAL 覆盖（测试用）。"""
    env = os.environ.get("PF_SHIELD_JOURNAL")
    if env:
        return Path(env)
    base = Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "PowerFocus" / "shield"
    return base / "journal.json"


def _load() -> dict:
    try:
        data = json.loads(journal_path().read_text(encoding="utf-8"))
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}
    entries = data.get("entries")
    data["entries"] = [e for e in entries if isinstance(e, dict)] if isinstance(entries, list) else []
    return data


def _save(data: dict) -> None:
    p = journal_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, p)
    security.protect_file(p, writable=True)


def _check_journal_writable() -> None:
    """还原日志写不进去就不许动系统——否则改了却没法还原。只以追加方式打开一下，不删任何文件。"""
    p = journal_path()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a", encoding="utf-8"):
            pass
    except Exception as e:
        raise RuntimeError("还原日志写不进去，为安全起见这次不改系统（%s）" % type(e).__name__)


def _pack(v):
    if isinstance(v, bytes):
        return {"__bytes__": list(v)}
    return v


def _unpack(v):
    if isinstance(v, dict) and "__bytes__" in v:
        return bytes(int(x) & 0xFF for x in v["__bytes__"])
    return v


# ---------------------------------------------------------------- 注册表原语（测试替换这几个，绝不碰真机）

def _hive(name):
    return {"HKLM": HKLM, "HKCU": HKCU}.get(name)


def _key_exists(hive, path) -> bool:
    if hive is None:
        return False
    try:
        with winreg.OpenKey(hive, path, 0, getattr(winreg, "KEY_READ", 0) | _WOW64):
            return True
    except OSError:
        return False


def _read_raw(hive, path, name):
    if hive is None:
        return None
    try:
        with winreg.OpenKey(hive, path, 0, getattr(winreg, "KEY_READ", 0) | _WOW64) as k:
            return winreg.QueryValueEx(k, name)
    except OSError:
        return None


def _write_value(hive, path, name, typ, value) -> None:
    if hive is None:
        raise RuntimeError("这个系统不支持注册表")
    try:
        with winreg.CreateKeyEx(hive, path, 0, _SET | _WOW64) as k:
            winreg.SetValueEx(k, name, 0, typ, value)
    except PermissionError:
        raise RuntimeError("没有权限写入（这一项需要以管理员身份运行本应用）")
    except OSError as e:
        raise RuntimeError("写入失败（%s）" % type(e).__name__)


def _delete_value(hive, path, name) -> None:
    if hive is None:
        return
    try:
        with winreg.OpenKey(hive, path, 0, _SET | _WOW64) as k:
            winreg.DeleteValue(k, name)
    except FileNotFoundError:
        pass
    except OSError:
        pass


def _key_is_empty(hive, path) -> bool:
    """键存在且既没有值也没有子键，才算空（只删我们自己建的空键）。"""
    if hive is None:
        return False
    try:
        with winreg.OpenKey(hive, path, 0, getattr(winreg, "KEY_READ", 0) | _WOW64) as k:
            n_sub, n_val, _ = winreg.QueryInfoKey(k)
        return n_sub == 0 and n_val == 0
    except OSError:
        return False


def _delete_key(hive, path) -> None:
    if hive is None:
        return
    try:
        winreg.DeleteKeyEx(hive, path, _WOW64, 0)
    except OSError:
        pass


# ---------------------------------------------------------------- 执行器

def _default_run(args):
    """跑一条系统命令，返回 (退出码, 输出)。exe 不带路径时固定从 System32 取，不吃当前目录。"""
    exe = args[0]
    if not os.path.isabs(exe):
        exe = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", exe)
    if not os.path.splitext(exe)[1]:        # 不依赖系统自动补扩展名：路径写全
        exe += ".exe"
    try:
        r = subprocess.run([exe] + list(args[1:]), capture_output=True, encoding="utf-8", errors="replace",
                           timeout=25, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except Exception as e:
        return 127, type(e).__name__


class _Ctx:
    """一次收紧动作的记录本：每改一处，先记下怎么还原。"""

    def __init__(self, runner=None):
        self.runner = runner or _default_run
        self.undo = []

    def reg_set(self, hive_name, path, name, typ, value):
        hive = _hive(hive_name)
        # 先记后改：原值先进记录本，再动系统。QueryValueEx 返回 (数据, 类型)——
        # [0] 是值本体、[1] 是类型码；顺序拿反会让还原时拿类型码当值写（真机踩过）。
        prev = _read_raw(hive, path, name)
        self.undo.append({"op": "reg", "hive": hive_name, "path": path, "name": name,
                          "key_existed": _key_exists(hive, path),
                          "existed": prev is not None,
                          "type": prev[1] if prev else None,
                          "value": _pack(prev[0]) if prev else None})
        _write_value(hive, path, name, typ, value)

    def cmd(self, args, undo_args):
        rc, out = self.runner(args)
        if rc != 0:
            raise RuntimeError("%s 执行失败（退出码 %d）" % (os.path.basename(str(args[0])), rc))
        self.undo.append({"op": "cmd", "args": [str(x) for x in undo_args]})


def _run_undo(ops, runner=None) -> list:
    """按相反顺序还原一组操作，返回错误列表（空 = 全部还原成功）。"""
    run = runner or _default_run
    errs = []
    for u in reversed(ops or []):
        try:
            if u.get("op") == "reg":
                hive = _hive(u["hive"])
                path, name = u["path"], u["name"]
                if u.get("existed"):
                    _write_value(hive, path, name, int(u["type"]), _unpack(u.get("value")))
                else:
                    _delete_value(hive, path, name)
                    if not u.get("key_existed") and _key_is_empty(hive, path):
                        _delete_key(hive, path)
            elif u.get("op") == "cmd":
                rc, _out = run(u["args"])
                if rc != 0:
                    raise RuntimeError("退出码 %d" % rc)
        except Exception as e:
            errs.append("%s 还原失败（%s）" % (u.get("name") or os.path.basename(str((u.get("args") or ["命令"])[0])), e))
    return errs


# ---------------------------------------------------------------- 各开关的动作

def _apply_remote_assist(ctx, probe):
    ctx.reg_set("HKLM", _RA_PATH, "fAllowToGetHelp", _REG_DWORD, 0)


def _apply_adid(ctx, probe):
    ctx.reg_set("HKCU", _ADID_PATH, "Enabled", _REG_DWORD, 0)


def _apply_https_only(ctx, probe):
    ctx.reg_set("HKCU", _EDGE_POLICY, "HttpsOnlyMode", _REG_SZ, "force_balanced_enabled")


def _apply_name_broadcast(ctx, probe):
    ctx.reg_set("HKLM", _MC_PATH, "EnableMulticast", _REG_DWORD, 0)
    for i in posture.enum_subkeys(HKLM, _NB_BASE):
        sub = _NB_BASE + "\\" + i
        if posture.read_dword(HKLM, sub, "NetbiosOptions") != 2:
            ctx.reg_set("HKLM", sub, "NetbiosOptions", _REG_DWORD, 2)


def _apply_doh(ctx, probe):
    """给每个没配加密的解析服务器配加密模板，并确保总开关是开的。"""
    c = probe if isinstance(probe, dict) else {}
    doh = c.get("doh") or {}
    seen = set()
    for s in (c.get("dns_servers") or []):
        s = str(s)
        if s in seen:
            continue
        seen.add(s)
        e = doh.get(s) or {}
        if e.get("url") and e.get("auto"):
            continue
        if e:
            ctx.cmd(["netsh", "dnsclient", "set", "encryption", "server=" + s,
                     "dohtemplate=" + DOH_TEMPLATE, "autoupgrade=yes", "udpfallback=no"],
                    ["netsh", "dnsclient", "set", "encryption", "server=" + s,
                     "dohtemplate=" + str(e.get("url") or DOH_TEMPLATE),
                     "autoupgrade=" + ("yes" if e.get("auto") else "no"),
                     "udpfallback=" + ("yes" if e.get("fallback") else "no")])
        else:
            ctx.cmd(["netsh", "dnsclient", "add", "encryption", "server=" + s,
                     "dohtemplate=" + DOH_TEMPLATE, "autoupgrade=yes", "udpfallback=no"],
                    ["netsh", "dnsclient", "delete", "encryption", "server=" + s])
    flags = c.get("doh_flags") or []
    prev = flags[0] if flags else None
    if prev != "enabled":
        ctx.cmd(["netsh", "dnsclient", "set", "global", "doh=yes"],
                ["netsh", "dnsclient", "set", "global",
                 "doh=" + (prev if prev in ("disabled", "auto") else "auto")])


def _state(item) -> str:
    st = (item or {}).get("status")
    return "on" if st == "ok" else ("unknown" if st == "unknown" else "off")


ACTIONS = {
    "https_only_edge": {
        "title": "浏览器强制加密", "scope": "当前用户 · Edge 140 以上", "admin": False, "recommended": True, "probe": True,
        "why": "手动输入的 http 网址、从别的程序点开的链接也会先走加密连接；只有对方不支持加密时才回退。",
        "risk": "只对 Edge 生效。Edge 的设置里会出现「由你的组织管理」——那是这条策略的固定标记，不是被别人控制了。",
        "check": lambda probe: posture.check_https_only(probe), "apply": _apply_https_only,
    },
    "doh_all": {
        "title": "DNS 查询全加密", "scope": "本机", "admin": True, "recommended": True, "probe": True,
        "why": "所有解析服务器都走加密通道，主服务器失败时也不落到明文。",
        "risk": "极端情况：解析服务商的加密通道整体不可用时，域名会解析不了，在这里还原即可恢复。",
        "check": lambda probe: posture.check_dns_encrypted(probe), "apply": _apply_doh,
    },
    "remote_assist": {
        "title": "远程协助", "scope": "本机", "admin": True, "recommended": True, "probe": False,
        "why": "别人拿到你的邀请文件就能远程操作这台电脑。",
        "risk": "你以后想用「快速助手」找人帮忙时，要先在这里还原。",
        "check": lambda probe: posture.check_remote_assist(), "apply": _apply_remote_assist,
    },
    "ad_id": {
        "title": "广告 ID", "scope": "当前用户", "admin": False, "recommended": True, "probe": False,
        "why": "应用凭广告 ID 跨应用追踪你的使用习惯。",
        "risk": "",
        "check": lambda probe: posture.check_adid(), "apply": _apply_adid,
    },
    "name_broadcast": {
        "title": "名称广播（LLMNR / NetBIOS）", "scope": "本机", "admin": True, "recommended": False, "probe": False,
        "why": "不再把电脑名和本地 IP 广播给同一个网络里的所有设备。",
        "risk": "家里靠电脑名找 NAS、打印机或共享文件夹的会找不到，要改用 IP。重启后生效。",
        "check": lambda probe: posture.check_name_resolution(), "apply": _apply_name_broadcast,
    },
}
ACTION_ORDER = ("https_only_edge", "doh_all", "remote_assist", "ad_id", "name_broadcast")


def recommended_ids() -> list:
    return [a for a in ACTION_ORDER if ACTIONS[a]["recommended"]]


def _probe_for(act, pwsh):
    if not act["probe"]:
        return None
    if not pwsh or not os.path.exists(pwsh):
        raise RuntimeError("这一项需要 PowerShell 7 才能执行和复验")
    return posture.content_probe(pwsh)


def _evaluate(act, probe):
    try:
        return act["check"](probe if act["probe"] else None)
    except Exception:
        return {"status": "unknown"}


def apply(ids, pwsh=None) -> list:
    """收紧一组开关。逐项返回结果：{id, ok, state, title, error, note}。一项失败不影响其他项。"""
    out = []
    with _LOCK:
        try:
            _check_journal_writable()
        except Exception as e:
            security.audit("shield_apply", ok=False, error=str(e))
            return [{"id": a, "ok": False, "title": ACTIONS[a]["title"] if a in ACTIONS else a,
                     "error": str(e)} for a in ids]
        for aid in ids:
            act = ACTIONS.get(aid)
            if not act:
                out.append({"id": aid, "ok": False, "error": "没有这个开关"})
                continue
            try:
                probe = _probe_for(act, pwsh)
            except Exception as e:
                out.append({"id": aid, "ok": False, "title": act["title"], "error": str(e)})
                continue
            if _state(_evaluate(act, probe)) == "on":
                out.append({"id": aid, "ok": True, "state": "on", "title": act["title"], "note": "本来就是收紧的，没有改动"})
                continue
            ctx = _Ctx()
            try:
                act["apply"](ctx, probe)
            except Exception as e:
                _run_undo(ctx.undo)
                security.audit("shield_apply", id=aid, ok=False, error=str(e))
                out.append({"id": aid, "ok": False, "title": act["title"], "error": str(e),
                            "note": "没有改成；已经写进去的部分已按原值还原"})
                continue
            try:
                after = _state(_evaluate(act, _probe_for(act, pwsh) if act["probe"] else None))
            except Exception as e:   # 复验本身出错，同样不能当作通过
                after = "error: %s" % type(e).__name__
            if after != "on":
                errs = _run_undo(ctx.undo)
                security.audit("shield_apply", id=aid, ok=False, error="verify_failed",
                               rollback_errors="; ".join(errs) if errs else None)
                note = "已自动还原"
                if errs:
                    # 系统停在改过的状态：必须把这条改动留在还原日志里，用户之后才能在应用里还原
                    data = _load()
                    data["entries"].append({"id": aid, "title": act["title"],
                                            "at": time.strftime("%Y-%m-%d %H:%M:%S"), "undo": ctx.undo})
                    _save(data)
                    note = "自动还原时有未成功的步骤：\n" + "\n".join(errs) + \
                           "\n已把这项改动记入还原日志，需要时可在这里还原。"
                out.append({"id": aid, "ok": False, "title": act["title"], "error": "改完后复验没有通过",
                            "note": note})
                continue
            data = _load()
            data["entries"].append({"id": aid, "title": act["title"],
                                    "at": time.strftime("%Y-%m-%d %H:%M:%S"), "undo": ctx.undo})
            _save(data)
            security.audit("shield_apply", id=aid, ok=True, ops=len(ctx.undo))
            out.append({"id": aid, "ok": True, "state": "on", "title": act["title"],
                        "note": act.get("risk") or ""})
    return out


def revert(ids=None) -> list:
    """按还原日志把开关恢复成收紧前的样子。ids=None 表示全部还原。"""
    results = []
    with _LOCK:
        data = _load()
        remaining = []
        for e in data["entries"]:
            if ids is not None and e.get("id") not in ids:
                remaining.append(e)
                continue
            errs = _run_undo(e.get("undo"))
            if errs:
                remaining.append(e)
                security.audit("shield_revert", id=e.get("id"), ok=False, errors="; ".join(errs))
                results.append({"id": e.get("id"), "ok": False, "error": "\n".join(errs)})
            else:
                security.audit("shield_revert", id=e.get("id"), ok=True)
                results.append({"id": e.get("id"), "ok": True, "title": e.get("title")})
        data["entries"] = remaining
        _save(data)
    return results


def status(pwsh=None, probe=None) -> list:
    """列出全部开关的当前状态。probe 已有就复用，不再起进程。"""
    with _LOCK:
        journaled = {e.get("id") for e in _load()["entries"]}
    if probe is None and any(a["probe"] for a in ACTIONS.values()):
        probe = posture.content_probe(pwsh)
    items = []
    for aid in ACTION_ORDER:
        act = ACTIONS[aid]
        it = _evaluate(act, probe)
        items.append({
            "id": aid, "title": act["title"], "scope": act["scope"], "why": act["why"], "risk": act["risk"],
            "recommended": act["recommended"], "admin": act["admin"],
            "state": _state(it), "value": it.get("value") if it.get("status") == "unknown" else "",
            "journaled": aid in journaled,
        })
    return items


# ---------------------------------------------------------------- DNS 密文验证（用户点按钮才做：会真的解析一个域名）

# 故意解析一个不存在的随机子域名：只为让系统发出一次查询，然后看 DNS 客户端服务连的是 443 还是 53。
_DNSCHECK_COMMAND = r"""
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
$servers = @(Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses } |
    ForEach-Object { $_.ServerAddresses } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
$null = Resolve-DnsName ('pf-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.www.microsoft.com') -Type A -DnsOnly
$dnsPid = (Get-CimInstance Win32_Service -Filter "Name='Dnscache'").ProcessId
$conns = @(Get-NetTCPConnection -OwningProcess $dnsPid | Where-Object { $servers -contains [string]$_.RemoteAddress } |
    ForEach-Object { @{ ip = [string]$_.RemoteAddress; port = [int]$_.RemotePort } })
$doh = @(Get-DnsClientDohServerAddress | ForEach-Object { [string]$_.ServerAddress })
@{ servers = @($servers); conns = $conns; doh = @($doh) } | ConvertTo-Json -Depth 4 -Compress
"""


def dns_check(pwsh=None) -> dict:
    """实测一次：DNS 查询是走加密连接（443）还是明文（53）。返回 encrypted=True/False/None 与依据。"""
    res = {"encrypted": None, "via": [], "servers": [], "detail": "", "ts": time.strftime("%Y-%m-%d %H:%M:%S")}
    if not pwsh or not os.path.exists(pwsh):
        res["detail"] = "找不到 PowerShell 7，无法验证。"
        return res
    try:
        r = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-Command", _DNSCHECK_COMMAND],
                           capture_output=True, encoding="utf-8", errors="replace", timeout=25,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if r.returncode != 0:
            res["detail"] = "验证命令没有跑完（退出码 %d）。" % r.returncode
            return res
        data = json.loads(r.stdout.strip() or "null")
    except Exception as e:
        res["detail"] = "验证没有完成（%s）。" % type(e).__name__
        return res
    if not isinstance(data, dict):
        res["detail"] = "验证结果读不懂。"
        return res
    servers = [str(x) for x in (data.get("servers") or [])]
    conns = [c for c in (data.get("conns") or []) if isinstance(c, dict)]
    doh = {str(x) for x in (data.get("doh") or [])}
    res["servers"] = servers
    res["via"] = sorted({"%s:%s" % (c.get("ip"), c.get("port")) for c in conns})
    if not servers:
        res["detail"] = "当前没有网卡配置了 DNS 服务器。"
        return res
    plain = [c for c in conns if int(c.get("port") or 0) == 53]
    unconf = [s for s in servers if s not in doh]
    if plain:
        res["encrypted"] = False
        res["detail"] = "抓到明文查询：DNS 服务连的是 53 端口（%s）。" % "、".join(
            "%s:%s" % (c.get("ip"), c.get("port")) for c in plain)
    elif not conns:
        # 连接是短命的，没抓到不算证据；退一步看配置
        res["encrypted"] = None if unconf else True
        res["detail"] = ("没抓到正在进行的 DNS 连接（连接很短命）。按配置：%s。" %
                         ("所有解析服务器都有加密模板" if not unconf else "这几个没有加密模板：" + "、".join(unconf)))
    elif unconf:
        res["encrypted"] = None
        res["detail"] = "这次查询走了 %s，但 %s 没有加密模板，轮到它们时会是明文。" % (
            "、".join(res["via"]), "、".join(unconf))
    else:
        res["encrypted"] = True
        res["detail"] = "这次查询只连了 %s——加密通道（443 端口），没有走明文的 53 端口。" % "、".join(res["via"])
    security.audit("dns_check", encrypted=res["encrypted"], via=",".join(res["via"]) or None)
    return res
