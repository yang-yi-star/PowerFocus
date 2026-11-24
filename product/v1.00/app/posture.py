# -*- coding: utf-8 -*-
"""网络暴露面体检（隐私防护 P0，只读）。

回答两个问题：这台电脑在网上有多显眼；本应用自己往外连过谁。

做什么：读注册表、列 TCP 连接、读本应用的自启项、汇总审计日志里的外联事件。
不做什么：不改任何注册表 / 防火墙 / 网络设置；不自动探测公网 IP；不切换代理；
          不 import 任何网络库（本文件被测试锁死：出现 httpx/urllib/socket/requests 即红）。
          收紧动作是 P1，代理 / VPN 改道不在本产品范围。

取值依据（官方文档，查过再用，不凭记忆）：
  - 防火墙三配置文件：
      HKLM\\SYSTEM\\CurrentControlSet\\Services\\SharedAccess\\Parameters\\FirewallPolicy\\
        {DomainProfile,StandardProfile,PublicProfile}\\EnableFirewall  （1 = 开）
  - 远程桌面：HKLM\\SYSTEM\\CurrentControlSet\\Control\\Terminal Server\\fDenyTSConnections（1 = 已关闭）
  - 远程协助：HKLM\\SYSTEM\\CurrentControlSet\\Control\\Remote Assistance\\fAllowToGetHelp（1 = 允许）
  - LLMNR / mDNS：HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\DNSClient\\EnableMulticast（0 = 关闭；缺省 = 开启）
      https://learn.microsoft.com/ko-kr/answers/questions/2119006/mdns
      Win11 另见同键 mDNSEnabled（1 = 显式开启）：https://learn.microsoft.com/en-us/answers/questions/2195980/
  - NetBIOS over TCP/IP：
      HKLM\\SYSTEM\\CurrentControlSet\\Services\\NetBT\\Parameters\\Interfaces\\Tcpip_*\\NetbiosOptions（2 = 禁用；0/1/缺省视为开启）
  - Wi-Fi 随机硬件地址：
      HKLM\\SOFTWARE\\Microsoft\\WlanSvc\\Interfaces\\<GUID>\\RandomMacState  REG_BINARY 01 00 00 00 = 开
      https://learn.microsoft.com/en-us/windows/apps/develop/settings/settings-windows-11
  - 广告 ID：HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo\\Enabled（0 = 关）
  - 定位：HKLM / HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location\\Value（Deny = 拒绝）

不确定就报 unknown，绝不猜：任何一项读失败 / 缺键 / 抛异常，状态都是 unknown，且不计分。
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import subprocess
import time

try:
    import winreg
except ImportError:  # 非 Windows（CI 兜底）：所有检查按「未知」回报
    winreg = None

HKLM = getattr(winreg, "HKEY_LOCAL_MACHINE", None)
HKCU = getattr(winreg, "HKEY_CURRENT_USER", None)

# 本应用的名称线索：用来找「是谁把我拉起来的」
APP_HINTS = ("算力调度", "powerfocus")

# 本应用会外联的去处——如实清单，与 server.py / versions/v0.13 的实际代码一致。
# 每条都写清「什么时候才会发生」，没有一条是静默外联。
APP_OUTBOUND_DECLARED = (
    {"what": "和你配置的云模型对话", "host": "你在「模型与对话」里填的服务地址",
     "when": "聊天目标选了「云端」时；注意：配过云密钥后默认就是云端", "kind": "chat_cloud"},
    {"what": "下载卡巴斯基 KVRT 扫描引擎", "host": "devbuilds.s.kaspersky-labs.com",
     "when": "你勾选同意 EULA 后的首次扫描", "kind": "scan"},
    {"what": "下载卡巴斯基完整版安装器", "host": "dm.s.kaspersky-labs.com",
     "when": "只在组件自检里点了安装", "kind": "bootstrap"},
    {"what": "下载 Node.js", "host": "nodejs.org",
     "when": "只在组件自检里点了安装", "kind": "bootstrap"},
    {"what": "检测公网 IP", "host": "api.ipify.org",
     "when": "只在你点了「检测一次公网 IP」", "kind": "exitip"},
)

# 审计日志里哪些事件算「本应用外联」
_AUDIT_KINDS = {
    "chat": "chat",
    "bootstrap_install": "bootstrap",
    "bootstrap_wizard": "bootstrap",
    "security_scan_start": "scan",
    "exitip_check": "exitip",
}


# ---------------------------------------------------------------- 注册表读取（唯一入口，测试替换这里）

def _read_value(root, path, name):
    if winreg is None or root is None:
        return None
    try:
        with winreg.OpenKey(root, path, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as k:
            return winreg.QueryValueEx(k, name)
    except OSError:
        return None


def read_dword(root, path, name):
    r = _read_value(root, path, name)
    try:
        return None if r is None else int(r[1])
    except (TypeError, ValueError):
        return None


def read_str(root, path, name):
    r = _read_value(root, path, name)
    return None if r is None or r[1] is None else str(r[1])


def read_bytes(root, path, name):
    r = _read_value(root, path, name)
    return None if r is None or not isinstance(r[1], bytes) else r[1]


def enum_subkeys(root, path):
    if winreg is None or root is None:
        return []
    try:
        with winreg.OpenKey(root, path, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as k:
            n = winreg.QueryInfoKey(k)[0]
            return [winreg.EnumKey(k, i) for i in range(n)]
    except OSError:
        return []


def enum_values(root, path):
    if winreg is None or root is None:
        return []
    try:
        with winreg.OpenKey(root, path, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as k:
            n = winreg.QueryInfoKey(k)[1]
            return [winreg.EnumValue(k, i)[:2] for i in range(n)]
    except OSError:
        return []


# ---------------------------------------------------------------- 检查项

def _item(cid, title, status, value, detail="", advice="", severity="mid", **extra):
    d = {"id": cid, "title": title, "status": status, "value": value,
         "detail": detail, "advice": advice, "severity": severity}
    d.update(extra)
    return d


_FIREWALL_BASE = r"SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy"
_FIREWALL_PROFILES = (("DomainProfile", "域网络"), ("StandardProfile", "专用网络"), ("PublicProfile", "公用网络"))


def check_firewall():
    parts, off, unknown = [], [], []
    for key, label in _FIREWALL_PROFILES:
        v = read_dword(HKLM, _FIREWALL_BASE + "\\" + key, "EnableFirewall")
        if v is None:
            unknown.append(label)
            parts.append(label + "=未知")
        elif v:
            parts.append(label + "=开")
        else:
            off.append(label)
            parts.append(label + "=关")
    title = "Windows 防火墙"
    if off:
        return _item("firewall", title, "warn", " / ".join(parts),
                     "这些网络类型的防火墙是关的：" + "、".join(off) + "。关着时同网络的设备可以直接连进来。",
                     "设置 → 隐私和安全性 → Windows 安全中心 → 防火墙和网络保护，把对应类型打开。", "high")
    if unknown:
        return _item("firewall", title, "unknown", " / ".join(parts),
                     "有网络类型的防火墙状态读取不到：" + "、".join(unknown), "", "high")
    return _item("firewall", title, "ok", " / ".join(parts), "域 / 专用 / 公用三类网络的防火墙都已开启。", "", "high")


_NETCAT_COMMAND = (
    "$x = @(Get-NetConnectionProfile | ForEach-Object { "
    "@{ name = [string]$_.Name; cat = [int]$_.NetworkCategory; v4 = [string]$_.IPv4Connectivity } }); "
    "ConvertTo-Json -Compress -InputObject $x"
)
_NETCAT_NAMES = {0: "公用", 1: "专用", 2: "域"}


def check_network_category(pwsh=None):
    title = "当前网络类型"
    if not pwsh or not os.path.exists(pwsh):
        return _item("netcat", title, "unknown", "--",
                     "找不到 PowerShell 7，读取不到当前网络类型。", "", "low")
    data = None
    try:
        r = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-Command", _NETCAT_COMMAND],
                           capture_output=True, text=True, timeout=8,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if r.returncode == 0:
            data = json.loads(r.stdout.strip() or "null")
    except Exception:
        data = None
    if data is None:
        return _item("netcat", title, "unknown", "--", "网络类型读取失败（命令未返回）。", "", "low")
    if isinstance(data, dict):
        data = [data]
    nets = []
    for n in data if isinstance(data, list) else []:
        try:
            cat = int(n.get("cat"))
        except (TypeError, ValueError, AttributeError):
            cat = -1
        nets.append({"name": str((n or {}).get("name") or ""), "category": _NETCAT_NAMES.get(cat, "未知"),
                     "ipv4": str((n or {}).get("v4") or "")})
    if not nets:
        return _item("netcat", title, "info", "未联网", "当前没有已连接的网络。", "", "low")
    value = "；".join("%s（%s）" % (x["name"] or "未命名网络", x["category"]) for x in nets)
    return _item("netcat", title, "info", value,
                 "「公用」= 对同网段设备隐藏自己，最安全；「专用」= 允许被发现和共享，只该在家里或可信网络用。",
                 "", "low", rows=nets)


def check_rdp():
    v = read_dword(HKLM, r"SYSTEM\CurrentControlSet\Control\Terminal Server", "fDenyTSConnections")
    port = read_dword(HKLM, r"SYSTEM\CurrentControlSet\Control\Terminal Server", "PortNumber")
    title = "远程桌面"
    if v is None:
        return _item("rdp", title, "unknown", "--", "读取不到远程桌面开关状态。", "", "high")
    if v:
        return _item("rdp", title, "ok", "已关闭", "其他电脑不能远程连进这台电脑。", "", "high")
    return _item("rdp", title, "warn", "已开启" + ("（端口 %d）" % port if port else ""),
                 "网络里其他电脑可以尝试远程登录这台电脑。",
                 "不用就关掉：设置 → 系统 → 远程桌面。", "high")


def check_remote_assist():
    v = read_dword(HKLM, r"SYSTEM\CurrentControlSet\Control\Remote Assistance", "fAllowToGetHelp")
    title = "远程协助"
    if v is None:
        return _item("rasat", title, "unknown", "--", "读取不到远程协助开关状态。", "", "mid")
    if not v:
        return _item("rasat", title, "ok", "已关闭", "", "", "mid")
    return _item("rasat", title, "warn", "已允许", "别人收到你的邀请文件后可以远程操作这台电脑。",
                 "不用就关掉：设置 → 系统 → 关于 → 高级系统设置 → 远程 → 取消「允许远程协助」。", "mid")


def check_name_resolution():
    pol_key = r"SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
    pol = read_dword(HKLM, pol_key, "EnableMulticast")
    mdns = read_dword(HKLM, pol_key, "mDNSEnabled")
    nb_base = r"SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces"
    ifaces = enum_subkeys(HKLM, nb_base)
    nb_on = nb_off = 0
    for i in ifaces:
        if read_dword(HKLM, nb_base + "\\" + i, "NetbiosOptions") == 2:
            nb_off += 1
        else:
            nb_on += 1
    parts = []
    if pol == 0:
        parts.append("多播名称解析=已关闭")
    elif pol is None:
        parts.append("多播名称解析=默认开启")
    else:
        parts.append("多播名称解析=开启")
    if mdns == 1:
        parts.append("mDNS=显式开启")
    parts.append("NetBIOS over TCP/IP=" + ("%d 开 / %d 关" % (nb_on, nb_off) if ifaces else "无接口信息"))
    title = "名称广播（LLMNR / mDNS / NetBIOS）"
    value = "，".join(parts)
    if pol == 0 and nb_on == 0:
        return _item("naming", title, "ok", value, "多播解析已关闭，NetBIOS 已在所有接口禁用。", "", "mid")
    if pol is None and not ifaces:
        return _item("naming", title, "unknown", value, "策略值和网卡信息都读取不到。", "", "mid")
    return _item("naming", title, "warn", value,
                 "这些协议会把电脑名和本地 IP 广播给同一网络里的所有设备，在公共 Wi-Fi 上等于自我介绍。",
                 "组策略「关闭多播名称解析」（EnableMulticast=0）；网卡 → IPv4 → 高级 → WINS → 禁用 NetBIOS over TCP/IP。"
                 "注意：家里靠电脑名找 NAS 或共享打印机的，关掉后会找不到，要改用 IP。", "mid")


def check_mac_random():
    base = r"SOFTWARE\Microsoft\WlanSvc\Interfaces"
    ifaces = enum_subkeys(HKLM, base)
    title = "Wi-Fi 随机硬件地址"
    if not ifaces:
        return _item("macrand", title, "unknown", "--",
                     "没有读取到 Wi-Fi 接口（台式机，或权限不足）。", "", "low")
    on = off = unk = 0
    for i in ifaces:
        b = read_bytes(HKLM, base + "\\" + i, "RandomMacState")
        if b is None:
            unk += 1
        elif b[:1] == b"\x01":
            on += 1
        else:
            off += 1
    value = "%d 开 / %d 关" % (on, off) + (" / %d 未知" % unk if unk else "")
    if off:
        return _item("macrand", title, "warn", value,
                     "关着时 Wi-Fi 探针请求带的是网卡真实 MAC，商场 / 机场的探针可以凭它追踪你。",
                     "设置 → 网络和 Internet → WLAN → 随机硬件地址：开。", "low")
    if on and not unk:
        return _item("macrand", title, "ok", value, "连 Wi-Fi 时使用随机地址。", "", "low")
    return _item("macrand", title, "unknown", value, "接口的状态值读取不到。", "", "low")


def check_adid():
    v = read_dword(HKCU, r"SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo", "Enabled")
    title = "广告 ID"
    if v is None:
        return _item("adid", title, "unknown", "--", "读取不到广告 ID 开关。", "", "low")
    if v == 0:
        return _item("adid", title, "ok", "已关闭", "", "", "low")
    return _item("adid", title, "warn", "已开启", "应用可以凭广告 ID 跨应用追踪你的使用习惯。",
                 "设置 → 隐私和安全性 → 常规 → 关闭「让应用使用广告 ID」。", "low")


def check_location():
    path = r"SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"
    machine = read_str(HKLM, path, "Value")
    user = read_str(HKCU, path, "Value")
    title = "定位服务"
    if machine == "Deny":
        return _item("location", title, "ok", "已拒绝（系统级）", "", "", "low")
    if user == "Deny":
        return _item("location", title, "ok", "已拒绝（当前用户）", "", "", "low")
    if user == "Allow" or machine == "Allow":
        return _item("location", title, "warn", "已允许", "应用可以读取你的位置。",
                     "不用就关掉：设置 → 隐私和安全性 → 位置。", "low")
    return _item("location", title, "unknown", "--", "读取不到定位权限状态。", "", "low")


def _startup_folders():
    out = []
    appdata = os.environ.get("APPDATA")
    programdata = os.environ.get("ProgramData")
    if appdata:
        out.append(os.path.join(appdata, "Microsoft", "Windows", "Start Menu", "Programs", "Startup"))
    if programdata:
        out.append(os.path.join(programdata, "Microsoft", "Windows", "Start Menu", "Programs", "StartUp"))
    return out


def _decode_task_file(data):
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data.decode("utf-16", errors="ignore")
    return data.decode("utf-8", errors="ignore")


def check_autostart():
    """本应用的自启项：启动文件夹、Run 键、计划任务（含运行权限）。只读。"""
    entries, partial = [], False
    for folder in _startup_folders():
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for n in names:
            if any(h in n.lower() for h in APP_HINTS):
                entries.append({"kind": "启动文件夹", "name": n, "run_level": "当前用户", "target": ""})
    for root, label in ((HKCU, "当前用户"), (HKLM, "所有用户")):
        for n, val in enum_values(root, r"SOFTWARE\Microsoft\Windows\CurrentVersion\Run"):
            text = "%s %s" % (n, val)
            if any(h in text.lower() for h in APP_HINTS):
                entries.append({"kind": "注册表 Run", "name": str(n), "run_level": label, "target": str(val)})
    tasks_dir = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "Tasks")
    for dirpath, _dirs, files in os.walk(tasks_dir):
        for f in files:
            p = os.path.join(dirpath, f)
            try:
                with open(p, "rb") as fh:
                    text = _decode_task_file(fh.read())
            except OSError:
                partial = True
                continue
            if not any(h in text.lower() for h in APP_HINTS):
                continue
            m = re.search(r"<RunLevel>(\w+)</RunLevel>", text)
            c = re.search(r"<Command>([^<]+)</Command>", text)
            level = "最高权限" if (m and m.group(1) == "HighestAvailable") else (m.group(1) if m else "未标注")
            entries.append({"kind": "计划任务", "name": os.path.relpath(p, tasks_dir), "run_level": level,
                            "target": c.group(1) if c else ""})
    title = "本应用的自启项"
    if not entries:
        return _item("autostart", title, "info", "没有", "没有发现任何开机自动拉起本应用的条目。", "", "low",
                     rows=[], partial=partial)
    value = "%d 项：%s" % (len(entries), "；".join("%s %s（%s）" % (e["kind"], e["name"], e["run_level"]) for e in entries))
    return _item("autostart", title, "info", value,
                 "安装脚本本身不创建计划任务，这些条目是应用自己看不见的。不需要就删掉；"
                 "要开机自启请用安装脚本的 -AutoStart（普通权限）。", "", "low", rows=entries, partial=partial)


def check_chat_default(chat_default=None):
    title = "对话默认发往"
    if chat_default == "cloud":
        return _item("chatdefault", title, "warn", "云端",
                     "只要配置过云端密钥，对话默认就发给你填的云模型服务商，而不是本机。隐私默认值反了。",
                     "在「模型与对话」把目标切到本地；P1 会把默认改为本地优先、云端需手选。", "mid")
    if chat_default == "local":
        return _item("chatdefault", title, "ok", "本机", "对话默认不离开这台电脑。", "", "mid")
    return _item("chatdefault", title, "unknown", "--", "读取不到对话默认目标。", "", "mid")


def _is_public(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return bool(a.is_global) and not a.is_multicast


def _proc_name(pid, resolver=None):
    try:
        if resolver:
            return str(resolver(pid))
        import psutil
        return psutil.Process(pid).name()
    except Exception:
        return "(已退出或无法读取)"


def check_outbound(conn_iter=None, proc_name=None):
    """已建立的外联：远端是公网地址的 TCP 连接，按「程序 → 地址」聚合，最多 20 行。只读。"""
    title = "谁在往外连"
    try:
        if conn_iter is not None:
            conns = list(conn_iter())
        else:
            import psutil
            conns = psutil.net_connections(kind="tcp")
    except Exception as e:
        return _item("outbound", title, "unknown", "--",
                     "读取连接失败（%s）。普通权限下可能读不到其他账户的进程。" % type(e).__name__, "", "low", rows=[])
    rows, names, denied = {}, {}, 0
    for c in conns:
        if str(getattr(c, "status", "")) != "ESTABLISHED":
            continue
        ra = getattr(c, "raddr", None)
        ip, port = getattr(ra, "ip", None), getattr(ra, "port", None)
        if not ip or not _is_public(str(ip)):
            continue
        pid = getattr(c, "pid", None)
        if pid is None:
            denied += 1
            name = "(权限不足)"
        else:
            name = names.get(pid)
            if name is None:
                name = _proc_name(pid, proc_name)
                names[pid] = name
        key = (name, str(ip), int(port or 0))
        rows[key] = rows.get(key, 0) + 1
    top = sorted(rows.items(), key=lambda kv: (-kv[1], kv[0]))[:20]
    value = "%d 个「程序 → 地址」" % len(rows) + ("（%d 条读不到归属）" % denied if denied else "")
    return _item("outbound", title, "info", value,
                 "只列已建立、对方是公网地址的连接；浏览器、输入法、杀毒软件、系统更新在这里出现都正常，"
                 "不认识的名字才值得查。", "", "low",
                 rows=[{"proc": k[0], "ip": k[1], "port": k[2], "count": v} for k, v in top])


def summarize_app_outbound(audit_items=None):
    out = {"chat_cloud": 0, "chat_local": 0, "bootstrap": 0, "scan": 0, "exitip": 0, "last": {}}
    for a in audit_items or []:
        if not isinstance(a, dict):
            continue
        ev = str(a.get("event") or "")
        kind = _AUDIT_KINDS.get(ev)
        if kind == "chat":
            kind = "chat_cloud" if str(a.get("target") or "") == "cloud" else "chat_local"
        if not kind:
            continue
        out[kind] = int(out.get(kind, 0)) + 1
        out["last"].setdefault(kind, a.get("ts"))  # audit_tail 新→旧，首条即最近
    return out


# ---------------------------------------------------------------- 汇总

_CHECKS = (
    ("firewall", "check_firewall", "high"),
    ("netcat", None, "low"),             # 带 pwsh 参数，collect 里单独调用
    ("rdp", "check_rdp", "high"),
    ("rasat", "check_remote_assist", "mid"),
    ("naming", "check_name_resolution", "mid"),
    ("macrand", "check_mac_random", "low"),
    ("adid", "check_adid", "low"),
    ("location", "check_location", "low"),
    ("autostart", "check_autostart", "low"),
    ("chatdefault", None, "mid"),        # 带 chat_default 参数
    ("outbound", None, "low"),           # 带连接参数
)
# 存函数名而不是函数对象：测试替换模块属性后 collect 才能真的用到替身
_TITLES = {
    "firewall": "Windows 防火墙", "netcat": "当前网络类型", "rdp": "远程桌面", "rasat": "远程协助",
    "naming": "名称广播（LLMNR / mDNS / NetBIOS）", "macrand": "Wi-Fi 随机硬件地址", "adid": "广告 ID",
    "location": "定位服务", "autostart": "本应用的自启项", "chatdefault": "对话默认发往", "outbound": "谁在往外连",
}


def collect(pwsh=None, audit_items=None, conn_iter=None, proc_name=None, chat_default=None):
    """跑全部检查。单项抛异常只影响该项（变 unknown），绝不让整页失败。返回可直接 JSON 化的 dict。"""
    checks = []
    for cid, fname, _sev in _CHECKS:
        try:
            if cid == "netcat":
                item = check_network_category(pwsh=pwsh)
            elif cid == "chatdefault":
                item = check_chat_default(chat_default)
            elif cid == "outbound":
                item = check_outbound(conn_iter=conn_iter, proc_name=proc_name)
            else:
                item = globals()[fname]()
        except Exception as e:
            item = _item(cid, _TITLES.get(cid, cid), "unknown", "--",
                         "读取失败（%s）。" % type(e).__name__, "", _sev)
        checks.append(item)
    ok = sum(1 for c in checks if c["status"] == "ok")
    warn = [c for c in checks if c["status"] == "warn"]
    unknown = sum(1 for c in checks if c["status"] == "unknown")
    score = round(100.0 * ok / (ok + len(warn))) if (ok + len(warn)) else None
    if warn:
        summary = "%d 项需要注意：%s" % (len(warn), "、".join(c["title"] for c in warn))
    else:
        summary = "已检查的项目里没有发现明显暴露项" if ok else "没有可下结论的项目"
    if unknown:
        summary += "；%d 项读取不到" % unknown
    return {
        "read_only": True,
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "score": score,
        "summary": summary,
        "checks": checks,
        "app_outbound": {
            "declared": [dict(x) for x in APP_OUTBOUND_DECLARED],
            "events": summarize_app_outbound(audit_items),
            "events_window": "审计日志最近 200 条内",
        },
    }
