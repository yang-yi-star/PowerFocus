# -*- coding: utf-8 -*-
# ============================================================
# 通用算力调度中心 · 桌面端后端（product\v1.00\app\server.py）
# 定位：面向任意应用/进程的通用调度入口，不绑定任何单一应用。
# 分工：Python 负责采集与交互；所有写操作转发给 PowerShell 内核命令总线。
# 铁律：
#   1. 只监听 127.0.0.1，不暴露局域网。
#   2. 写操作只放行白名单 action，禁止任意透传。
#   3. 破坏性动作（kill/stress）必须 confirm=true，后端自动注入本机 token。
#   4. 不做 PPL 系统关键进程的任何操作。
# ============================================================
import asyncio
import ctypes
import ctypes.wintypes as wt
import itertools
import json
import os
import re
import sys
import threading
import time
from pathlib import Path

import psutil
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
import httpx
import uvicorn

import security

# 统一数据目录（审计 S1）：运行态配置不再写程序目录。
try:
    import app_paths
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
    import app_paths


def _config_path() -> Path:
    """配置读取：新数据目录优先，程序目录里的历史 config.json 只读回退。"""
    new = app_paths.data_root() / "config.json"
    if new.exists():
        return new
    old = Path(__file__).resolve().parent / "config.json"
    return old if old.exists() else new


APP_VERSION = "1.00"
PRODUCT_NAME = "电脑算力调度中心"

# ---------- 路径解析（源码运行 / PyInstaller 打包均可用） ----------
def _frozen() -> bool:
    return getattr(sys, "frozen", False)


def _app_home() -> Path:
    """exe 所在目录，或源码 product\v1.00 目录。"""
    if _frozen():
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


def _resource_dir() -> Path:
    r"""静态资源目录：打包后在 _MEIPASS，源码在 app\web。"""
    if _frozen() and hasattr(sys, "_MEIPASS"):
        return Path(sys._MEIPASS) / "web"
    return Path(__file__).resolve().parent / "web"


def resolve_pf_root() -> Path:
    """定位 PowerFocus 根目录（含 versions\）。"""
    env = os.environ.get("POWERFOCUS_ROOT")
    if env and (Path(env) / "versions").is_dir():
        return Path(env)
    start = _app_home()
    for cand in [start] + list(start.parents):
        if (cand / "versions").is_dir():
            return cand
    return Path(r"E:\PowerFocus")


def _ver_key(name: str):
    m = re.match(r"v(\d+)\.(\d+)$", name)
    return (int(m.group(1)), int(m.group(2))) if m else None


def resolve_kernel() -> Path:
    """解析当前内核版本目录：current.json 指针优先，否则取 stable 最高版本。"""
    root = resolve_pf_root()
    vers = root / "versions"
    ptr = vers / "current.json"
    if ptr.exists():
        try:
            v = str(json.loads(ptr.read_text(encoding="utf-8-sig")).get("version") or "")
            if v and (vers / v).is_dir():
                return vers / v
        except Exception:
            pass
    best, best_key = None, None
    for d in vers.glob("v*"):
        if not d.is_dir():
            continue
        k = _ver_key(d.name)
        if not k:
            continue
        mf = d / "MANIFEST.json"
        try:
            stage = json.loads(mf.read_text(encoding="utf-8-sig")).get("stage") if mf.exists() else "dev"
        except Exception:
            stage = "dev"
        if stage != "stable":
            continue
        if best_key is None or k > best_key:
            best, best_key = d, k
    return best or (vers / "v0.07")


PF_ROOT = resolve_pf_root()
KERNEL_DIR = resolve_kernel()
BUS_IN = KERNEL_DIR / "commands" / "in"
BUS_OUT = KERNEL_DIR / "commands" / "out"
BUS_DONE = KERNEL_DIR / "commands" / "done"
TOKEN_FILE = KERNEL_DIR / ".auth_token"
PROFILES = KERNEL_DIR / "model-profiles.json"
SCENES = KERNEL_DIR / "scenes.json"

LLAMA_BASE = os.environ.get("POWERFOCUS_LLAMA_BASE", "http://127.0.0.1:8080")
MODEL_KEY_FILE = PF_ROOT / ".model_key"
HOST = "127.0.0.1"
PORT = int(os.environ.get("POWERFOCUS_APP_PORT", "18080"))


# ---------- 云端对话（默认通道）：不依赖任何本地模型 ----------
def _user_env(name):
    """进程环境没有时，从用户级环境变量（注册表）兜底读取。"""
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Environment") as k:
            v, _ = winreg.QueryValueEx(k, name)
            return str(v or "")
    except Exception:
        return ""


def _cfg(name):
    return os.environ.get(name, "") or _user_env(name)


_vault_cache = {"ts": 0.0, "data": {}}


def cloud_config():
    """云端凭据解析优先级：DPAPI 加密库 > 用户级环境变量。

    环境变量是明文，能被同用户任意进程读走；加密库才是「静态存储安全」。
    这里只读取、不缓存密钥到日志或错误信息里。"""
    now = time.time()
    if now - _vault_cache["ts"] > 10:
        try:
            _vault_cache["data"] = security.vault_get()
        except Exception:
            _vault_cache["data"] = {}
        _vault_cache["ts"] = now
    v = _vault_cache["data"] or {}
    base = (str(v.get("base_url") or "") or _cfg("MODEL_BASE_URL")).rstrip("/")
    key = str(v.get("api_key") or "") or _cfg("MODEL_API_KEY")
    model = str(v.get("model") or "") or _cfg("MODEL_NAME")
    source = "vault" if v.get("api_key") else ("env" if _cfg("MODEL_API_KEY") else "")
    return {"base_url": base, "api_key": key, "model": model, "source": source}


def invalidate_cloud_cache():
    _vault_cache["ts"] = 0.0


def cloud_ready():
    c = cloud_config()
    return bool(c["base_url"] and c["api_key"] and c["model"])


def llama_headers() -> dict:
    """本地模型服务已启用 --api-key-file：无令牌的本地/浏览器调用一律 401。"""
    try:
        key = MODEL_KEY_FILE.read_text(encoding="utf-8-sig").strip()
    except Exception:
        key = ""
    return {"Authorization": "Bearer " + key} if key else {}


def system_prompt():
    """提示词来源：app\\config.json 的 system_prompt > 环境变量 POWERFOCUS_SYSTEM_PROMPT。"""
    try:
        cfg_path = _config_path()
        if cfg_path.exists():
            cfg = json.loads(cfg_path.read_text(encoding="utf-8-sig"))
            if cfg.get("system_prompt"):
                return str(cfg["system_prompt"])
    except Exception:
        pass
    return os.environ.get("POWERFOCUS_SYSTEM_PROMPT", "")

# 白名单：通用调度能力，不绑定应用
ALLOWED_ACTIONS = {
    "status", "focus", "unfocus", "set_priority", "set_power_plan",
    "trim_memory", "set_io_priority", "set_net_qos", "apply_scene",
    "list_scenes", "list_apps", "request_power", "release_power",
    "list_requests", "mem_guard", "router_status", "list_model_profiles",
    "model_identity", "start_router", "stop_router", "boost_model",
    "suspend_process", "resume_process", "authorize", "revoke",
}
DESTRUCTIVE_ACTIONS = {"kill_process", "stress_process"}
TOKEN_ACTIONS = {"authorize", "revoke", "suspend_process", "resume_process"}   # 内核要求 token，由后端自动注入

SYSTEM_CRITICAL = {
    "system", "registry", "idle", "memory compression", "smss", "csrss",
    "wininit", "services", "lsass", "winlogon", "fontdrvhost", "dwm",
    "wudfhost", "msmpeng", "logonui", "securityhealthservice", "audiodg",
}

_ACTIVE = {"port": PORT}   # 运行期实际监听端口（可能因占用而顺延）
_seq = itertools.count(1)
# 生产环境不暴露接口地图：/docs、/redoc、/openapi.json 全部关闭。
app = FastAPI(title=PRODUCT_NAME, version=APP_VERSION,
              openapi_url=None, docs_url=None, redoc_url=None)

_MW_HOLDER = {}


class _SecurityMW(security.SecurityMiddleware):
    """持有实例引用，供 /api/selfcheck 清零自身触发的限流计数。"""

    def __init__(self, app, **kwargs):
        super().__init__(app, **kwargs)
        _MW_HOLDER["security"] = self


# 安全中间件：最后添加的最先执行 → SecurityMiddleware 在最外层先验 Host。
app.add_middleware(security.BodyLimitMiddleware, limit=1_048_576)
app.add_middleware(_SecurityMW, token_provider=lambda: _token(),
                   exempt={"/api/health"})

_web = _resource_dir()
if _web.is_dir():
    app.mount("/static", StaticFiles(directory=str(_web)), name="static")


# ---------- 进程快照（后台 1 秒采样，API 读缓存） ----------
# ---------- 原生进程枚举（psutil.process_iter 在本机 415 进程下约 3 秒/轮，不可用） ----------
class _PMC(ctypes.Structure):
    _fields_ = [
        ("cb", ctypes.c_ulong), ("PageFaultCount", ctypes.c_ulong),
        ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
        ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t),
    ]


class _PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [
        ("dwSize", ctypes.c_ulong), ("cntUsage", ctypes.c_ulong),
        ("th32ProcessID", ctypes.c_ulong), ("th32DefaultHeapID", ctypes.c_size_t),
        ("th32ModuleID", ctypes.c_ulong), ("cntThreads", ctypes.c_ulong),
        ("th32ParentProcessID", ctypes.c_ulong), ("pcPriClassBase", ctypes.c_long),
        ("dwFlags", ctypes.c_ulong), ("szExeFile", ctypes.c_wchar * 260),
    ]


def enum_parent_map():
    """Toolhelp 快照一次遍历拿到 pid → 父 pid 映射，约 2-5ms。"""
    k32 = ctypes.windll.kernel32
    k32.CreateToolhelp32Snapshot.restype = ctypes.c_void_p
    h = k32.CreateToolhelp32Snapshot(0x00000002, 0)   # TH32CS_SNAPPROCESS
    if not h or int(h) == -1:
        return {}
    m = {}
    try:
        pe = _PROCESSENTRY32W()
        pe.dwSize = ctypes.sizeof(_PROCESSENTRY32W)
        if k32.Process32FirstW(ctypes.c_void_p(h), ctypes.byref(pe)):
            while True:
                m[int(pe.th32ProcessID)] = int(pe.th32ParentProcessID)
                if not k32.Process32NextW(ctypes.c_void_p(h), ctypes.byref(pe)):
                    break
    finally:
        k32.CloseHandle(ctypes.c_void_p(h))
    return m


def enum_win_processes():
    """一次 EnumProcesses + 每进程 3 个查询，整轮约 30-60ms。返回 pid/name/cpu_s/rss。"""
    k32 = ctypes.windll.kernel32
    psapi = ctypes.windll.psapi
    arr = (ctypes.c_ulong * 8192)()
    need = ctypes.c_ulong(0)
    if not psapi.EnumProcesses(arr, ctypes.sizeof(arr), ctypes.byref(need)):
        return []
    count = need.value // ctypes.sizeof(ctypes.c_ulong)
    out = []
    for pid in arr[:count]:
        if pid in (0, 4):
            continue
        h = k32.OpenProcess(0x1000 | 0x0400 | 0x0010, False, int(pid))  # LIMIT|QUERY_INFO|VM_READ
        if not h:
            continue
        try:
            name = ""
            buf = ctypes.create_unicode_buffer(512)
            ln = ctypes.c_ulong(512)
            if k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(ln)):
                name = buf.value.rsplit("\\", 1)[-1]
            c = ctypes.c_ulonglong(); e = ctypes.c_ulonglong()
            kt = ctypes.c_ulonglong(); ut = ctypes.c_ulonglong()
            if not k32.GetProcessTimes(h, ctypes.byref(c), ctypes.byref(e),
                                       ctypes.byref(kt), ctypes.byref(ut)):
                continue
            pmc = _PMC(); pmc.cb = ctypes.sizeof(_PMC)
            rss = 0
            if psapi.GetProcessMemoryInfo(h, ctypes.byref(pmc), ctypes.sizeof(_PMC)):
                rss = int(pmc.WorkingSetSize)
            out.append({"pid": int(pid), "name": name or ("pid-%d" % pid),
                        "cpu_s": (kt.value + ut.value) / 10_000_000.0, "rss": rss})
        finally:
            k32.CloseHandle(h)
    return out


class Snapshot:
    def __init__(self):
        self.lock = threading.Lock()
        self.data = {"time": "", "cpu": 0.0, "mem_percent": 0.0, "mem_used_mb": 0,
                     "mem_total_mb": 0, "processes": [], "foreground_pid": 0}
        self._last = None
        self._prev = {}       # pid -> (累计 CPU 秒, 采样时刻)；用差值算占用率，比 cpu_percent 快百倍
        self._prev_ts = 0.0

    @staticmethod
    def _priority(pid: int) -> str:
        k32 = ctypes.windll.kernel32
        h = k32.OpenProcess(0x0400, False, pid)
        if not h:
            return ""
        try:
            v = k32.GetPriorityClass(h)
        finally:
            k32.CloseHandle(h)
        return {0x40: "Idle", 0x4000: "Normal", 0x8000: "High",
                0x10000: "RealTime", 0x4000 | 0x8000: "AboveNormal",
                0x4000 | 0x2000: "BelowNormal"}.get(v, "")

    @staticmethod
    def _foreground() -> int:
        try:
            u32 = ctypes.windll.user32
            hwnd = u32.GetForegroundWindow()
            if not hwnd:
                return 0
            pid = wt.DWORD()
            u32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            return int(pid.value)
        except Exception:
            return 0

    def sample(self):
        vm = psutil.virtual_memory()
        ncpu = psutil.cpu_count(logical=True) or 1
        now = time.monotonic()
        dt = max(now - self._prev_ts, 0.001)
        prev = self._prev
        cur = {}
        procs = []
        for item in enum_win_processes():
            pid = item["pid"]
            total = item["cpu_s"]
            old = prev.get(pid)
            pct = ((total - old) / dt * 100.0) if old is not None else 0.0
            cur[pid] = total
            procs.append({
                "pid": pid,
                "name": item["name"],
                "cpu": round(min(max(pct, 0.0), 100.0 * ncpu), 1),
                "mem_mb": round(item["rss"] / 1048576, 1),
                "status": "",
            })
        self._prev = cur
        self._prev_ts = now
        fg = self._foreground()
        for item in procs:
            if item["pid"] == fg:
                item["foreground"] = True
                item["priority"] = self._priority(item["pid"])
        # 父子关系（Toolhelp 一次遍历），用于像任务管理器那样按应用归组
        ppids = enum_parent_map()
        name_by_pid = {p["pid"]: p["name"] for p in procs}
        for p in procs:
            p["ppid"] = int(ppids.get(p["pid"], 0))
            p["critical"] = p["name"].lower() in SYSTEM_CRITICAL
        root_cache = {}

        def root_of(pid, depth=0):
            """沿父链上溯到应用根进程；父进程已退出时以自己为根。"""
            if pid in root_cache:
                return root_cache[pid]
            pp = ppids.get(pid, 0)
            if depth > 24 or not pp or pp == pid or pp not in name_by_pid:
                root_cache[pid] = pid
                return pid
            r = root_of(pp, depth + 1)
            root_cache[pid] = r
            return r

        child_count = {}
        for p in procs:
            pp = p["ppid"]
            if pp and pp in name_by_pid:
                child_count[pp] = child_count.get(pp, 0) + 1
        for p in procs:
            r = root_of(p["pid"])
            p["root"] = r
            p["root_name"] = name_by_pid.get(r, p["name"])
        # 展示集合取全量：只要没有进程启停，行位置就完全不动（任务管理器同理）
        top = procs
        top.sort(key=lambda x: (x["root_name"].lower(),
                                0 if x["pid"] == x["root"] else 1,
                                x["name"].lower(), x["pid"]))
        for item in top:
            if item["pid"] != fg:
                item["priority"] = self._priority(item["pid"])
        for item in top:
            item["children"] = child_count.get(item["pid"], 0)
        snap = {
            "time": time.strftime("%H:%M:%S"),
            "cpu": round(psutil.cpu_percent(None), 1),
            "mem_percent": round(vm.percent, 1),
            "mem_used_mb": int(vm.used / 1048576),
            "mem_total_mb": int(vm.total / 1048576),
            "foreground_pid": fg,
            "process_count": len(procs),
            "processes": top,
        }
        with self.lock:
            self.data = snap
            self._last = procs

    def run(self):
        psutil.cpu_percent(None)
        while True:
            try:
                self.sample()
            except Exception:
                pass
            time.sleep(1.5)

    def get(self):
        with self.lock:
            return dict(self.data)

    def all_processes(self):
        with self.lock:
            return list(self._last or [])


SNAP = Snapshot()


# ---------- 命令总线 ----------
def _pwsh() -> str:
    import shutil
    return shutil.which("pwsh") or shutil.which("powershell") or "pwsh.exe"


def _token() -> str:
    try:
        tok = TOKEN_FILE.read_text(encoding="utf-8-sig").strip()
        if tok:
            return tok
    except Exception:
        pass
    # 内核尚未生成时由后端补一份：首次启动不会因为缺 token 直接 503。
    try:
        import secrets as _secrets
        TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
        tok = _secrets.token_hex(16)
        TOKEN_FILE.write_text(tok, encoding="utf-8")
        security.audit("token_bootstrapped", path=str(TOKEN_FILE))
        return tok
    except Exception:
        return ""


async def bus_call(cmd: dict, timeout: float = 30.0):
    name = "ui-%d-%d" % (int(time.time() * 1000), next(_seq))
    in_path = BUS_IN / (name + ".json")
    done_path = BUS_DONE / (name + ".json.result.txt")
    try:
        BUS_IN.mkdir(parents=True, exist_ok=True)
        in_path.write_text(json.dumps(cmd, ensure_ascii=False), encoding="utf-8")
    except Exception as e:
        return False, "命令总线写入失败: %s" % e
    deadline = time.time() + timeout
    while time.time() < deadline:
        if done_path.exists():
            try:
                return True, done_path.read_text(encoding="utf-8-sig").strip()
            except Exception as e:
                return False, "读取结果失败: %s" % e
        await asyncio.sleep(0.2)
    try:
        in_path.unlink(missing_ok=True)
    except Exception:
        pass
    return False, "命令总线超时（%.0f 秒）：内核未运行？请启动 %s" % (timeout, KERNEL_DIR.name)


async def _json_body(req: Request) -> dict:
    """统一解析 JSON 请求体：格式错就 400，绝不让解码异常冒成 500。"""
    try:
        body = await req.json()
    except Exception:
        raise HTTPException(400, "请求体不是合法 JSON")
    if not isinstance(body, dict):
        raise HTTPException(400, "请求体必须是 JSON 对象")
    return body


async def kernel_alive() -> bool:
    try:
        hb = json.loads((KERNEL_DIR / "v3_heartbeat.json").read_text(encoding="utf-8-sig"))
        ts = time.mktime(time.strptime(hb.get("time", "1970-01-01 00:00:00"), "%Y-%m-%d %H:%M:%S"))
        return (time.time() - ts) < 15
    except Exception:
        return False


# ---------- 自然语言规则解析（无模型依赖的快速路径） ----------
def _proc_alias_map():
    """别名（小写）→ 真实进程名（保留空格与大小写），供内核 Get-Process -Name 精确匹配。"""
    m = {}
    for p in SNAP.all_processes():
        raw = str(p.get("name") or "").strip()
        if not raw:
            continue
        base = re.sub(r"\.(exe|com|bat|cmd|scr)$", "", raw).strip()
        if len(base) < 3:
            continue
        m.setdefault(base.lower(), base)
        head = base.split(" ")[0]
        if len(head) >= 3:
            m.setdefault(head.lower(), base)
    return m


def _match_target(text: str):
    t = text.lower()
    amap = _proc_alias_map()
    for alias in sorted(amap, key=len, reverse=True):
        if alias in t:
            return amap[alias]
    return None


PRI_LABEL = {"RealTime": "实时", "High": "高", "AboveNormal": "高于正常",
             "Normal": "正常", "BelowNormal": "低于正常", "Idle": "空闲"}


def parse_nl(text: str):
    """中文自然语言 → 命令对象；无法识别返回 None。"""
    if not text or not text.strip():
        return None
    t = text.strip()
    low = t.lower()
    target = _match_target(t)

    if re.search(r"状态|情况|怎么样|负载|占用|体检|概况|status", low):
        return {"action": "status", "_explain": "查询整机与调度状态"}
    if re.search(r"解除(聚焦)?|取消(聚焦)?|放开|别.{0,4}聚焦|停止聚焦|恢复(正常|默认)", t):
        return {"action": "unfocus", "_explain": "解除聚焦，所有进程恢复正常调度"}
    if target and re.search(r"(?:清理?|回收|释放).{1,12}?内存", low):
        return {"action": "trim_memory", "exclude_target": True,
                "_explain": "整机内存修剪（内核不支持只回收 %s，已对全机空闲进程修剪）" % target}
    if re.search(r"(?:清理?|回收|释放).{0,12}?内存|内存整理|trim", low):
        return {"action": "trim_memory", "exclude_target": True, "_explain": "回收空闲进程工作集内存"}
    if re.search(r"高性能|性能模式|满血", t):
        return {"action": "set_power_plan", "plan": "high", "_explain": "切换高性能电源计划"}
    if re.search(r"平衡|节能|省电", t):
        return {"action": "set_power_plan", "plan": "balanced", "_explain": "切换平衡/节能电源计划"}
    if re.search(r"场景", t) and not re.search(r"切换|应用|进入|用", t):
        return {"action": "list_scenes", "_explain": "列出可用场景"}
    m = re.search(r"(?:切换到?|应用|进入|用)(.{1,12})场景", t)
    if m and not target:
        raw = m.group(1).strip()
        alias = {"游戏": "gaming", "推理": "inference", "模型": "inference",
                 "放松": "relax", "还原": "relax", "日常": "relax", "省电": "relax"}
        scene = alias.get(raw, raw)
        return {"action": "apply_scene", "scene": scene,
                "_explain": "切换场景 %s" % scene}

    if target:
        if re.search(r"杀掉|结束|终止|关闭|关掉|kill", low):
            return {"action": "kill_process", "process_name": target,
                    "_explain": "强制终止 %s（破坏性，需确认）" % target,
                    "_risk": "high", "_destructive": True}
        if re.search(r"冻结|挂起|暂停|suspend", low):
            return {"action": "suspend_process", "process_name": target, "_explain": "冻结 %s" % target}
        if re.search(r"恢复运行|解冻|恢复进程|resume", low):
            return {"action": "resume_process", "process_name": target, "_explain": "恢复 %s" % target}
        # 优先级要先判，否则"优先级"里的"优先"会被当成聚焦
        if re.search(r"优先级|priority", low):
            pri = None
            for kw, val in [(r"实时|realtime", "RealTime"),
                            (r"高于正常|above\s*normal", "AboveNormal"),
                            (r"最高|高优|高|(?<![a-z])high(?![a-z])", "High"),
                            (r"最低|空闲|(?<![a-z])idle(?![a-z])", "Idle"),
                            (r"低于正常|below\s*normal|低", "BelowNormal"),
                            (r"正常|普通|(?<![a-z])normal(?![a-z])", "Normal")]:
                if re.search(kw, low):
                    pri = val
                    break
            if pri:
                return {"action": "set_priority", "process_name": target, "priority": pri,
                        "_explain": "把 %s 优先级设为 %s" % (target, PRI_LABEL.get(pri, pri))}
            # 命中"优先级"但没识别出级别时不再降级为聚焦，避免误操作
            return None
        if re.search(r"聚焦|加速|提速|保障|优先|focus", low):
            mode = "gentle"
            if re.search(r"极限|终极|开挂|全力|god", low):
                mode = "godmode"
            elif re.search(r"强制|激进|压过|立刻", low):
                mode = "aggressive"
            return {"action": "focus", "process_name": target, "mode": mode,
                    "_explain": "聚焦 %s（%s 模式）" % (target, mode)}
        if re.search(r"限速|网络限制|qos", low):
            m2 = re.search(r"(\d+(?:\.\d+)?)\s*(?:mbps|兆)", low)
            if m2:
                return {"action": "set_net_qos", "process_name": target,
                        "rate_mbps": float(m2.group(1)),
                        "_explain": "限制 %s 网速 %s Mbps" % (target, m2.group(1))}
    return None


# ---------- API ----------
@app.get("/")
async def index():
    page = _web / "index.html"
    if not page.exists():
        raise HTTPException(404, "界面资源缺失")
    html = page.read_text(encoding="utf-8")
    html = html.replace("__PF_TOKEN_VALUE__", _token())
    return HTMLResponse(html, headers={"Cache-Control": "no-store"})


@app.get("/api/health")
async def health():
    """健康探针：只回非敏感字段（本接口免鉴权，绝不暴露路径与密钥）。"""
    return {
        "app": "ok", "name": PRODUCT_NAME, "version": APP_VERSION,
        "kernel_version": KERNEL_DIR.name,
        "kernel_alive": await kernel_alive(),
        "frozen": _frozen(),
        "port": _ACTIVE["port"],
    }


_model_cache = {"ts": 0.0, "data": []}


@app.get("/api/snapshot")
async def snapshot():
    d = SNAP.get()
    d["kernel_version"] = KERNEL_DIR.name
    d["kernel_alive"] = await kernel_alive()
    now = time.time()
    if now - _model_cache["ts"] > 5:  # 模型状态 5 秒一查，避免每秒打本地服务
        try:
            async with httpx.AsyncClient(timeout=1.0) as c:
                r = await c.get(LLAMA_BASE + "/v1/models", headers=llama_headers())
                _model_cache["data"] = ((r.json().get("data") or []) if r.status_code == 200 else [])
        except Exception:
            _model_cache["data"] = []
        _model_cache["ts"] = now
    d["model_loaded"] = _model_cache["data"]
    return d


@app.get("/api/processes")
async def processes(q: str = ""):
    items = SNAP.all_processes()
    if q:
        ql = q.lower()
        items = [i for i in items if ql in i["name"].lower() or ql == str(i["pid"])]
    items.sort(key=lambda x: (-x["cpu"], -x["mem_mb"]))
    return {"count": len(items), "items": items[:120]}


@app.post("/api/parse")
async def parse(req: Request):
    body = await _json_body(req)
    text = str(body.get("text") or "")
    cmd = parse_nl(text)
    if not cmd:
        if re.search(r"优先级|priority", text, re.I):
            return {"hit": False, "text": text,
                    "hint": "请说明优先级级别：实时 / 高 / 高于正常 / 正常 / 低于正常 / 空闲。"}
        hint = ""
        m = re.search(r"(?:给|把|让|对)\s*([A-Za-z0-9_\-]{3,})", text)
        if m:
            hint = "没找到正在运行的进程「%s」，请先确认该程序已启动。" % m.group(1)
        return {"hit": False, "text": text, "hint": hint}
    return {"hit": True, "command": cmd, "text": text}


@app.post("/api/command")
async def command(req: Request):
    body = await _json_body(req)
    action = str(body.get("action") or "")
    if action not in ALLOWED_ACTIONS and action not in DESTRUCTIVE_ACTIONS:
        raise HTTPException(400, "action 不在白名单: %s" % action)
    cmd = {k: v for k, v in body.items() if not k.startswith("_")}
    cmd["action"] = action
    # 统一目标名格式：内核用 Get-Process -Name，需去掉 .exe 后缀
    if "process_name" in cmd and cmd["process_name"]:
        cmd["process_name"] = re.sub(r"\.(exe|com|bat|cmd|scr)$", "",
                                     str(cmd["process_name"]), flags=re.I)
    try:
        timeout = float(body.get("_timeout") or 30)
    except (TypeError, ValueError):
        timeout = 30.0
    timeout = max(1.0, min(timeout, 600.0))
    if action in TOKEN_ACTIONS:
        tok = _token()
        if not tok:
            raise HTTPException(400, "本机 token 缺失，无法修改授权清单")
        cmd["token"] = tok
    if action in DESTRUCTIVE_ACTIONS:
        if not body.get("confirm"):
            raise HTTPException(400, "破坏性操作必须带 confirm=true")
        tok = _token()
        if not tok:
            raise HTTPException(400, "本机 token 缺失，无法执行破坏性操作")
        cmd["token"] = tok
        timeout = 60
    ok, text = await bus_call(cmd, timeout=timeout)
    return {"ok": ok, "text": text}


@app.post("/api/chat")
async def chat(req: Request):
    body = await _json_body(req)
    target = str(body.pop("target", "") or "").lower()
    if target not in ("cloud", "local"):
        target = "cloud" if cloud_ready() else "local"
    body.setdefault("stream", True)

    if target == "cloud":
        if not cloud_ready():
            raise HTTPException(503, "云端 API 未配置：需要 BASE_URL / MODEL / API_KEY")
        cfg = cloud_config()
        if not body.get("model") or body.get("model") == "__cloud__":
            body["model"] = cfg["model"]
        prompt = system_prompt()
        msgs = body.get("messages") or []
        if prompt and not any(m.get("role") == "system" for m in msgs):
            body["messages"] = [{"role": "system", "content": prompt}] + msgs
        url = cfg["base_url"] + "/chat/completions"
        headers = {"Authorization": "Bearer " + cfg["api_key"]}
    else:
        url = LLAMA_BASE + "/v1/chat/completions"
        headers = llama_headers()

    if not body.get("stream"):
        async with httpx.AsyncClient(timeout=httpx.Timeout(None, connect=8)) as c:
            r = await c.post(url, json=body, headers=headers)
            if r.status_code != 200:
                return JSONResponse({"error": r.text[:800], "status": r.status_code}, status_code=502)
            return JSONResponse(r.json(), status_code=r.status_code)

    async def gen():
        async with httpx.AsyncClient(timeout=httpx.Timeout(None, connect=8)) as c:
            async with c.stream("POST", url, json=body, headers=headers) as r:
                if r.status_code != 200:
                    detail = (await r.aread()).decode("utf-8", "ignore")[:800]
                    yield ("data: " + json.dumps({"error": detail, "status": r.status_code},
                                                 ensure_ascii=False) + "\n\n").encode("utf-8")
                    return
                async for chunk in r.aiter_bytes():
                    yield chunk

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@app.get("/api/models")
async def models():
    cfg = {}
    try:
        cfg = json.loads(PROFILES.read_text(encoding="utf-8-sig"))
    except Exception:
        pass
    items = []
    for key, entry in (cfg.get("models") or {}).items():
        ident = entry.get("identity") or {}
        items.append({"key": key, "alias": (entry.get("common") or {}).get("alias") or key,
                      "arch": ident.get("architecture"), "size_gb": ident.get("size_gb")})
    loaded = []
    try:
        async with httpx.AsyncClient(timeout=2) as c:
            r = await c.get(LLAMA_BASE + "/v1/models", headers=llama_headers())
            if r.status_code == 200:
                loaded = [d.get("id") for d in (r.json().get("data") or [])]
    except Exception:
        pass
    cfg = cloud_config()
    return {"models": items, "loaded": loaded,
            "cloud": {"ready": cloud_ready(), "model": cfg["model"],
                      "base_url": cfg["base_url"], "has_prompt": bool(system_prompt()),
                      "source": cfg["source"]},
            "default_target": "cloud" if cloud_ready() else "local"}


@app.get("/api/router")
async def router_status_api():
    """本地模型路由状态：转发内核 router_status，附上原始文本便于排查。"""
    ok, text = await bus_call({"action": "router_status"}, timeout=20)
    data = None
    try:
        data = json.loads(text) if text else None
    except Exception:
        data = None
    return {"ok": ok, "text": "" if ok else text, "data": data}


@app.post("/api/boost")
async def boost(req: Request):
    """模型加速：dry_run 只出方案，apply 才真正调参。"""
    body = await _json_body(req)
    mode = str(body.get("mode") or "dry_run").lower()
    if mode not in ("dry_run", "apply"):
        raise HTTPException(400, "mode 只能是 dry_run 或 apply")
    cmd = {"action": "boost_model", "mode": mode}
    model = str(body.get("model") or "").strip()
    if model:
        cmd["model"] = model
    ok, text = await bus_call(cmd, timeout=60)
    return {"ok": ok, "text": text}


@app.get("/api/scenes")
async def scenes():
    """场景列表（含说明），供前端卡片展示。"""
    try:
        cfg = json.loads(SCENES.read_text(encoding="utf-8-sig"))
        items = cfg.get("scenes") if isinstance(cfg, dict) else None
        if not isinstance(items, dict):
            items = cfg if isinstance(cfg, dict) else {}
        out = []
        for name, val in items.items():
            if name.startswith("_"):
                continue
            desc = ""
            if isinstance(val, dict):
                desc = str(val.get("desc") or "")
            out.append({"name": name, "desc": desc})
        return {"scenes": out}
    except Exception:
        return {"scenes": []}


# ---------- 安全态势 / 审计 / 自检 / 设置 ----------
@app.get("/api/security")
async def security_status():
    """只读安全态势：给界面一个「现在到底防住了什么」的可核对清单。"""
    tok = _token()
    cfg = cloud_config()
    mw = _MW_HOLDER.get("security")
    return {
        "bind": {"host": HOST, "port": _ACTIVE["port"], "loopback_only": HOST in ("127.0.0.1", "::1")},
        "host_guard": {"enabled": True, "allowed": sorted(security.trusted_hostnames())},
        "token": {"ready": bool(tok), "fingerprint": security.token_fingerprint(tok),
                  "path": str(TOKEN_FILE)},
        "docs": {"disabled": app.docs_url is None and app.openapi_url is None and app.redoc_url is None},
        "limits": {"body_bytes": 1_048_576,
                   "requests_per_min": getattr(getattr(mw, "limiter", None), "limit", 600),
                   "auth_fail_threshold": getattr(getattr(mw, "failures", None), "threshold", 20)},
        "headers": sorted(h[0].decode() for h in security.SECURITY_HEADERS),
        "cloud_key": {"encrypted": bool(security.vault_get().get("api_key")), "source": cfg["source"]},
        "audit_log": str(security.audit_path()),
        "vault_path": str(security.vault_path()),
    }


@app.get("/api/audit")
async def audit_log(limit: int = 40):
    return {"items": security.audit_tail(limit), "path": str(security.audit_path())}


@app.post("/api/selfcheck")
async def selfcheck():
    """主动攻击复测：用内部 ASGI 客户端真的去打自己的接口，看是否被拦。

    这是「以跳过验证为耻，以主动测试为荣」的落地：不是读代码猜结论，
    是让中间件自己跑一遍并回报状态码。"""
    checks = []

    def add(name, want, got):
        checks.append({"name": name, "expect": want, "actual": got, "pass": got == want})

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://127.0.0.1") as c:
        try:
            r = await c.get("/openapi.json")
            add("接口地图未暴露 (/openapi.json)", 404, r.status_code)
            r = await c.get("/docs")
            add("文档页未暴露 (/docs)", 404, r.status_code)
            r = await c.get("/api/health", headers={"Host": "evil.example.com"})
            add("伪造 Host（DNS 重绑定）被拒", 403, r.status_code)
            r = await c.get("/api/models")
            add("无令牌访问被拒", 401, r.status_code)
            r = await c.get("/api/models", headers={"X-PF-Token": "deadbeef"})
            add("错误令牌被拒", 401, r.status_code)
            r = await c.post("/api/command", headers={"Origin": "https://evil.example.com"},
                             json={"action": "status"})
            add("跨源 POST 被拒", 403, r.status_code)
            r = await c.post("/api/parse", content=b"x" * 1_200_000,
                             headers={"Content-Type": "application/json",
                                      "X-PF-Token": _token()})
            add("超大请求体被拒", 413, r.status_code)
            r = await c.get("/api/security", headers={"X-PF-Token": _token()})
            add("携带令牌可正常访问", 200, r.status_code)
        except Exception as e:
            checks.append({"name": "自检执行", "expect": "完成", "actual": str(e)[:160], "pass": False})
        finally:
            mw = _MW_HOLDER.get("security")
            if mw:
                mw.reset("127.0.0.1")
    security.audit("selfcheck", passed=sum(1 for x in checks if x["pass"]), total=len(checks))
    return {"ok": all(x["pass"] for x in checks), "checks": checks}


def _write_config(patch: dict) -> None:
    cur = {}
    try:
        if _config_path().exists():
            cur = json.loads(_config_path().read_text(encoding="utf-8-sig")) or {}
    except Exception:
        cur = {}
    cur.update(patch)
    cfg_path = app_paths.write_path("config.json")
    cfg_path.write_text(json.dumps(cur, ensure_ascii=False, indent=2), encoding="utf-8")


@app.get("/api/settings")
async def get_settings():
    cfg = cloud_config()
    return {
        "cloud": {"base_url": cfg["base_url"], "model": cfg["model"],
                  "has_key": bool(cfg["api_key"]), "source": cfg["source"]},
        "system_prompt": system_prompt(),
        "token_fingerprint": security.token_fingerprint(_token()),
        "kernel_dir": str(KERNEL_DIR),
        "app_dir": str(Path(__file__).resolve().parent),
    }


@app.post("/api/settings")
async def set_settings(req: Request):
    """保存设置：API Key 走 DPAPI 加密库，其余进 config.json（非密文）。"""
    body = await _json_body(req)
    if not isinstance(body, dict):
        raise HTTPException(400, "请求体必须是 JSON 对象")
    v = security.vault_get()
    changed = []
    if "base_url" in body:
        u = str(body.get("base_url") or "").strip().rstrip("/")
        if u and not re.match(r"^https?://", u, re.I):
            raise HTTPException(400, "base_url 必须以 http:// 或 https:// 开头")
        v["base_url"] = u
        changed.append("base_url")
    if "model" in body:
        v["model"] = str(body.get("model") or "").strip()
        changed.append("model")
    if body.get("api_key"):
        v["api_key"] = str(body["api_key"]).strip()
        changed.append("api_key")
    if body.get("clear_key"):
        v.pop("api_key", None)
        changed.append("clear_key")
    if changed:
        if v:
            security.vault_set(v)
        else:
            security.vault_clear()
        invalidate_cloud_cache()
    if "system_prompt" in body:
        _write_config({"system_prompt": str(body.get("system_prompt") or "")})
        changed.append("system_prompt")
    security.audit("settings_changed", fields=", ".join(changed) or "-")
    return {"ok": True, "changed": changed, "cloud_ready": cloud_ready()}


@app.post("/api/cloud/test")
async def cloud_test():
    """用当前凭据真连一次云端 /models，验证 API Key 是否可用。"""
    cfg = cloud_config()
    if not (cfg["base_url"] and cfg["api_key"]):
        raise HTTPException(503, "云端凭据不完整（需要 base_url 与 api_key）")
    t0 = time.time()
    try:
        async with httpx.AsyncClient(timeout=20) as c:
            r = await c.get(cfg["base_url"] + "/models",
                            headers={"Authorization": "Bearer " + cfg["api_key"]})
    except Exception as e:
        return {"ok": False, "latency_ms": int((time.time() - t0) * 1000),
                "detail": "连接失败：%s" % e}
    count = None
    try:
        count = len((r.json() or {}).get("data") or [])
    except Exception:
        pass
    return {"ok": r.status_code == 200, "status": r.status_code,
            "latency_ms": int((time.time() - t0) * 1000),
            "model_count": count,
            "detail": "" if r.status_code == 200 else r.text[:200]}


# ---------------------------------------------------------------------------
# V0.10 组件自检 / bootstrapping（应用进程内真跑，不依赖外部 AI 对话环境）
# ---------------------------------------------------------------------------
_BOOTSTRAP_CACHE: dict = {"ts": 0.0, "data": None, "error": ""}


def _bootstrap():
    """延迟导入：模块由 PyInstaller --hidden-import 收进 PYZ，源码运行则从 versions/v0.10 找。"""
    try:
        import dependency_bootstrap
    except ImportError:
        v010 = PF_ROOT / "versions" / "v0.10"
        if str(v010) not in sys.path:
            sys.path.insert(0, str(v010))
        import dependency_bootstrap
    return dependency_bootstrap


def bootstrap_report(force: bool = False) -> dict:
    """
    返回启动自检报告。5 分钟缓存，避免每次打开页面都重跑 WMI / 注册表探测。
    自检本身只读；模块不可用也不能阻塞应用启动。
    """
    now = time.time()
    if not force and _BOOTSTRAP_CACHE["data"] is not None and now - _BOOTSTRAP_CACHE["ts"] < 300:
        return dict(_BOOTSTRAP_CACHE["data"], cached=True)
    try:
        d = _bootstrap().startup_check()
        _BOOTSTRAP_CACHE.update({"ts": now, "data": d, "error": ""})
        return dict(d, cached=False)
    except Exception as e:
        _BOOTSTRAP_CACHE["error"] = "%s: %s" % (type(e).__name__, e)
        return {"available": False, "error": _BOOTSTRAP_CACHE["error"],
                "components": [], "startup_ok": True, "cached": False,
                "startup_note": "组件自检模块不可用，应用其余功能不受影响"}


def warm_bootstrap() -> dict:
    """主进程启动时在后台线程预热一次，避免拖慢窗口出现；返回报告供写日志。"""
    return bootstrap_report(force=True)


@app.get("/api/bootstrap/check")
async def bootstrap_check():
    return bootstrap_report()


@app.post("/api/bootstrap/refresh")
async def bootstrap_refresh():
    return await asyncio.to_thread(bootstrap_report, True)


@app.get("/api/bootstrap/plan")
async def bootstrap_plan():
    try:
        return await asyncio.to_thread(_bootstrap().plan)
    except Exception as e:
        raise HTTPException(503, "自检模块不可用：%s: %s" % (type(e).__name__, e))


@app.post("/api/bootstrap/install")
async def bootstrap_install(req: Request):
    """
    用户点「同意下载」后由前端传入 consent；服务端绝不自动补令牌。
    真下载在线程池执行，不阻塞事件循环。
    """
    body = await _json_body(req)
    if not isinstance(body, dict):
        raise HTTPException(400, "请求体必须是 JSON 对象")
    cid = str(body.get("component_id") or "").strip()
    consent = str(body.get("consent") or "")
    if not cid:
        raise HTTPException(400, "缺少 component_id")
    # 只允许清单里的 id，避免把任意字符串传进 install()
    try:
        known = [c.id for c in _bootstrap().COMPONENTS]
    except Exception:
        known = []
    if known and cid not in known:
        raise HTTPException(400, "未知组件：%s" % cid)
    out = await asyncio.to_thread(_bootstrap().install, cid, consent, False, False)
    security.audit("bootstrap_install", component=cid,
                   executed=str(bool(out.get("executed"))),
                   reason=str(out.get("reason") or "")[:160])
    return out


@app.post("/api/bootstrap/wizard")
async def bootstrap_wizard(req: Request):
    """
    启动厂商交互式安装向导（系统级动作）。必须第二道令牌，且前端须先弹确认框。
    应用不代接受 EULA / 隐私政策 / KSN，不传 /s。
    """
    body = await _json_body(req)
    if not isinstance(body, dict):
        raise HTTPException(400, "请求体必须是 JSON 对象")
    cid = str(body.get("component_id") or "").strip()
    token = str(body.get("install_consent") or "")
    if not cid:
        raise HTTPException(400, "缺少 component_id")
    out = await asyncio.to_thread(_bootstrap().launch_vendor_wizard, cid, token)
    security.audit("bootstrap_wizard", component=cid,
                   launched=str(bool(out.get("launched"))),
                   reason=str(out.get("reason") or "")[:160])
    return out


def start_background():
    threading.Thread(target=SNAP.run, daemon=True).start()


def serve(port: int = PORT):
    _ACTIVE["port"] = int(port)
    # server_header=False / date_header=False：不回 Server 指纹，减少侦察信息。
    uvicorn.run(app, host=HOST, port=port, log_level="warning",
                server_header=False, date_header=False)


if __name__ == "__main__":
    start_background()
    uvicorn.run(app, host=HOST, port=PORT, log_level="info",
                server_header=False, date_header=False)
