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
import ipaddress
import itertools
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import urlparse

import psutil
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
import httpx
import uvicorn

import security
import bus
import temp_log

# pythonnet 预加载（2026-11-15 修复）：CLR 首次导入要花时间，若后台温度采集线程
# 与 pywebview 的 winforms 后端在同一时刻各自首次 import clr，后到的一方会拿到
# 半初始化的 clr 模块，报 "module 'clr' has no attribute 'AddReference'" 并导致
# 界面启动失败（实测 06:50:00 崩过一次）。这里在单线程导入阶段先把它载入，消除竞态。
# 失败不致命：拿不到 CLR 只影响温度数据源，服务与界面照常。
try:
    import clr  # noqa: F401
    _CLR_PRELOADED = True
except Exception:
    _CLR_PRELOADED = False

# 统一数据目录（审计 S1）：运行态配置不再写程序目录。
try:
    import app_paths
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
    import app_paths


def _config_path() -> Path:
    """配置读取：唯一回退策略（新数据目录 → 历史数据根 → 程序目录只读）。

    写入永远走 app_paths.write_path("config.json")；这里只负责读，
    不再让 system_prompt() 与 _write_config() 各自实现一套回退。
    """
    for cand in (
        app_paths.data_root() / "config.json",
        app_paths.legacy_root() / "config.json",
        Path(__file__).resolve().parent / "config.json",
    ):
        if cand.exists():
            return cand
    return app_paths.data_root() / "config.json"


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
    # 不再回退到开发机绝对路径：换机后它不存在，会把内核解析到错误目录。
    la = os.environ.get("LOCALAPPDATA")
    if la:
        d = Path(la) / "PowerFocus"
        if (d / "versions").is_dir():
            return d
    return start  # 由 resolve_kernel 走明确的降级分支


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
    if best:
        return best
    # 全部非 stable（开发期）时不再静默回落某个写死版本——那会让应用悄悄跑在
    # 一个过时内核上，出问题还以为是新版本。改为取最高版本并显式告警。
    newest, newest_key = None, None
    for d in vers.glob("v*"):
        if not d.is_dir():
            continue
        k = _ver_key(d.name)
        if not k:
            continue
        if newest_key is None or k > newest_key:
            newest, newest_key = d, k
    if newest:
        sys.stderr.write("[PowerFocus] 警告：versions 下没有 stage=stable 的内核，"
                         "暂用最高版本 %s（开发态）\n" % newest.name)
        return newest
    return vers / "v0.07"


PF_ROOT = resolve_pf_root()
KERNEL_DIR = resolve_kernel()
BUS_IN = KERNEL_DIR / "commands" / "in"
BUS_OUT = KERNEL_DIR / "commands" / "out"
BUS_DONE = KERNEL_DIR / "commands" / "done"
TOKEN_FILE = KERNEL_DIR / ".auth_token"
# HTTP/UI 令牌与内核授权令牌解耦：免鉴权的首页会把 HTTP 令牌注入 meta，
# 同机任意本地进程都能读到它，因此它绝不能等同于内核授权令牌。
# 放在运行态数据目录，不写程序目录，也不进任何 HTTP 响应体。
_HTTP_TOKEN_FILE = (Path(os.environ.get("LOCALAPPDATA") or os.environ.get("TEMP") or ".")
                    / "PowerFocus" / "http.token")
_TOKEN_LOCK = threading.Lock()
PROFILES = KERNEL_DIR / "model-profiles.json"
SCENES = KERNEL_DIR / "scenes.json"

LLAMA_BASE = os.environ.get("POWERFOCUS_LLAMA_BASE", "http://127.0.0.1:8080")
MODEL_KEY_FILE = PF_ROOT / ".model_key"
HOST = "127.0.0.1"
PORT = int(os.environ.get("POWERFOCUS_APP_PORT", "18080"))

# 命令总线客户端：I/O 编排收敛到 bus.py，路由层只持有实例
BUS = bus.BusClient(BUS_IN, BUS_DONE, KERNEL_DIR.name)


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


def _cloud_url_ok(u: str) -> bool:
    """B27：云端 base_url 白名单，防止 SSRF 与 api_key 外泄。

    - 回环地址允许（本地 OpenAI 兼容服务），但必须是 http/https；
    - 字面 IP 必须公网可达，拒绝 169.254.169.254 / 10.x / 192.168.x；
    - 域名一律要求 https，避免把 Bearer 密钥明文发到任意主机；
    - 禁止用户名密码、query、fragment，避免凭据被拼进 URL 或参数注入。
    如实说明：DNS rebinding 到私网的域名仍有残余风险，由 https 证书校验兜底。
    """
    try:
        p = urlparse(u)
        host = (p.hostname or "").lower()
        if p.scheme not in ("http", "https") or not host:
            return False
        if p.username or p.password or p.query or p.fragment:
            return False
        if host in ("localhost", "127.0.0.1", "::1"):
            return True
        try:
            return bool(ipaddress.ip_address(host).is_global)
        except ValueError:
            return p.scheme == "https"
    except Exception:
        return False


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
    # 读取侧同样拦截：环境变量 / 旧凭据库里的地址也必须过白名单，
    # 否则只改 set_settings 挡不住 API Key 被发到内网元数据服务。
    if base and not _cloud_url_ok(base):
        base = ""
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

def _critical_processes() -> set[str]:
    """F9：系统关键进程名单单一真源，与两代内核共用同一份 JSON。

    文件缺失 / 损坏时降级到内置集合，不让应用起不来。
    """
    fallback = {
        "system", "registry", "idle", "memory compression", "smss", "csrss",
        "wininit", "services", "lsass", "winlogon", "fontdrvhost", "dwm",
        "wudfhost", "msmpeng", "logonui", "securityhealthservice", "audiodg",
    }
    try:
        p = KERNEL_DIR / "critical_processes.json"
        names = json.loads(p.read_text(encoding="utf-8-sig")).get("names") or []
        return {str(n).lower() for n in names} or fallback
    except Exception:
        return fallback


SYSTEM_CRITICAL = _critical_processes()

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
    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    # B19：64 位 HANDLE 是指针，默认 restype=c_int 会截掉高 32 位。
    k32.OpenProcess.restype = ctypes.c_void_p
    k32.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
    k32.CloseHandle.argtypes = [ctypes.c_void_p]
    k32.QueryFullProcessImageNameW.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.c_wchar_p,
        ctypes.POINTER(ctypes.c_ulong)]
    k32.GetProcessTimes.argtypes = [ctypes.c_void_p] + [
        ctypes.POINTER(ctypes.c_ulonglong)] * 4
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
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.OpenProcess.restype = ctypes.c_void_p
        k32.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        k32.CloseHandle.argtypes = [ctypes.c_void_p]
        k32.GetPriorityClass.argtypes = [ctypes.c_void_p]
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


# ---------- GPU 温度 / 降频 / 功耗（复用系统 nvidia-smi，不引入 pynvml 依赖） ----------
_GPU_CACHE: dict = {"ts": 0.0, "data": None}
_CREATE_NO_WINDOW = 0x08000000

# NVML 官方 ClocksThrottleReasons 位定义（只映射确定项；未知位原样保留十六进制，不猜）
_THROTTLE_BITS = (
    (0x0001, "GpuIdle"),
    (0x0002, "ApplicationsClocksSetting"),
    (0x0004, "SwPowerCap"),
    (0x0008, "HwSlowdown"),
    (0x0010, "SyncBoost"),
    (0x0020, "SwThermalSlowdown"),
    (0x0040, "HwThermalSlowdown"),
    (0x0080, "HwPowerBrakeSlowdown"),
    (0x0100, "DisplayClockSetting"),
)


def _parse_gpu_row(line: str) -> dict | None:
    """解析 nvidia-smi 的一行 CSV。字段缺失或为 N/A 时置 None，不填假值。"""
    parts = [p.strip() for p in line.split(",")]
    if len(parts) < 8:
        return None

    def num(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return None                     # N/A 及非数字一律 None

    thr = parts[7]
    active = None
    reasons: list[str] = []
    if thr.lower().startswith("0x"):
        try:
            active = int(thr, 16)
            for bit, name in _THROTTLE_BITS:
                if active & bit:
                    reasons.append(name)
            if active and not reasons:
                # 有活动位但不在已知表里：不猜含义，如实标注未映射，避免谎报成「无活动」
                reasons.append("Unmapped(%s)" % thr)
        except ValueError:
            active = None
    elif thr.lower() not in ("n/a", "[n/a]", "not active", ""):
        reasons.append(thr)                 # 文字形式（如 "Not Active"）原样保留

    return {
        "index": parts[0],
        "name": parts[1],
        "temp_c": num(parts[2]),
        "mem_temp_c": num(parts[3]),
        "util_percent": num(parts[4]),
        "mem_used_mb": num(parts[5]),
        "mem_total_mb": num(parts[6]),
        "throttle_hex": thr,
        "throttle_active": active,
        "throttle_reasons": reasons,
        "power_w": num(parts[8]) if len(parts) > 8 else None,
        "power_limit_w": num(parts[9]) if len(parts) > 9 else None,
    }


def gpu_thermal(force: bool = False) -> dict:
    """读 GPU 温度/降频/功耗。5 秒缓存，避免每次快照都拉子进程。

    只依赖系统自带 nvidia-smi（NVML 的 pynvml 未安装，内核本来也用这个命令）。
    无 NVIDIA GPU 或命令不可用时返回 available=False，不影响其余快照字段。
    温度只读不控：本函数不写任何硬件设置。
    """
    now = time.time()
    if not force and _GPU_CACHE["data"] is not None and now - _GPU_CACHE["ts"] < 5:
        return dict(_GPU_CACHE["data"], cached=True)

    query = ("--query-gpu=index,name,temperature.gpu,temperature.memory,"
             "utilization.gpu,memory.used,memory.total,"
             "clocks_throttle_reasons.active,power.draw,power.limit")
    result: dict = {"available": False, "gpus": [], "cached": False}
    try:
        p = subprocess.run(["nvidia-smi", query, "--format=csv,noheader,nounits"],
                           capture_output=True, timeout=3,
                           creationflags=_CREATE_NO_WINDOW)
        if p.returncode != 0:
            result["error"] = "nvidia-smi 退出码 %d" % p.returncode
        else:
            text = (p.stdout or b"").decode("utf-8", "replace")
            gpus = [g for g in (_parse_gpu_row(ln) for ln in text.splitlines() if ln.strip()) if g]
            result.update({"available": bool(gpus), "gpus": gpus})
    except FileNotFoundError:
        result["error"] = "未检测到 nvidia-smi（无 NVIDIA GPU 或未在 PATH）"
    except subprocess.TimeoutExpired:
        result["error"] = "nvidia-smi 超时（3 秒）"
    except Exception as e:
        result["error"] = "%s: %s" % (type(e).__name__, e)

    _GPU_CACHE.update({"ts": now, "data": result})
    return result


# ---------- 命令总线 ----------
def _pwsh() -> str:
    import shutil
    return shutil.which("pwsh") or shutil.which("powershell") or "pwsh.exe"


def _atomic_token(path: Path) -> str:
    """进程内加锁 + .tmp/os.replace 原子写：并发首次启动不会产出多个不同令牌。"""
    with _TOKEN_LOCK:
        try:
            tok = path.read_text(encoding="utf-8-sig").strip()
            if tok:
                return tok
        except OSError:
            pass
        tok = secrets.token_hex(16)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_name(path.name + ".tmp")
            tmp.write_text(tok, encoding="utf-8")
            os.replace(tmp, path)
            # F14：HTTP 令牌文件收回继承，只留当前用户可读。
            security.protect_file(path)
            security.audit("http_token_bootstrapped", path=str(path))
        except OSError:
            return ""
        return tok


def _token() -> str:
    """HTTP/UI 令牌：供中间件鉴权与首页 meta 注入。

    免鉴权的首页会注入它，同机任意本地进程都能读到，因此它只用于访问本机
    HTTP API，**不具备内核授权效力**，与 TOKEN_FILE 是完全不同的两个密钥。
    """
    return _atomic_token(_HTTP_TOKEN_FILE)


def _kernel_token() -> str:
    """内核授权令牌：只在服务端内部注入命令对象，绝不进入任何 HTTP 响应。"""
    try:
        return TOKEN_FILE.read_text(encoding="utf-8-sig").strip()
    except OSError:
        return ""


async def bus_call(cmd: dict, timeout: float = 30.0):
    """统一出口：注入内核授权令牌 + 审计，再交给 BusClient。

    F4：内核只对来自 commands/in 的命令做令牌校验，因此**每一条**命令
    （不只 TOKEN_ACTIONS / DESTRUCTIVE_ACTIONS）都必须在这里带令牌。
    放在这一层既覆盖 /api/router 等内部调用，也不让客户端有机会覆盖。
    F10：所有总线写操作统一在此留审计痕迹（只记 action 与结果，不记参数值）。
    """
    payload = dict(cmd)
    payload["token"] = _kernel_token()
    ok, text = await BUS.call(payload, timeout)
    security.audit("bus_command", action=str(cmd.get("action") or "-"),
                   ok=str(ok), result=str(text)[:120])
    return ok, text
async def _json_body(req: Request) -> dict:
    """统一解析 JSON 请求体：格式错就 400，绝不让解码异常冒成 500。"""
    try:
        body = await req.json()
    except Exception:
        raise HTTPException(400, "请求体不是合法 JSON")
    if not isinstance(body, dict):
        raise HTTPException(400, "请求体必须是 JSON 对象")
    return body


def kernel_alive_sync() -> bool:
    """判活的唯一实现：心跳新鲜度 + 内核进程存在性（13 号修复 2026-11-20）。

    旧实现只做 `age < 15`，三处硬伤：
      1) 判文件新鲜度而非进程存在性 —— 内核崩了文件还热着，最长 15 秒假活；
      2) 与 main.py 各写一份逐字重复的实现，改一处漏一处就会分叉；
      3) 对系统时间后调没有下界 —— 时钟被 NTP 往回校时 age 变负，
         负数当然小于 15，于是永久判活、内核再也拉不起来。

    pid 取自内核 Write-Heartbeat 写入的字段（本机 pwsh 进程 pid）。
    缺 pid 时退回纯新鲜度判定：宁可少判死，也绝不重复拉起第二个内核实例。
    47 号：pid 字段写坏（非空且不可解析，如 "abc"）同样退回新鲜度——
    字段坏了只是「没有佐证」，不等于「进程已死」；此处若判死，启动器会再拉一个内核。
    时间字段不享受这个宽容：没有可信时间就没有新鲜度，判活会变成永久假活。
    已知残留：Windows pid 会被复用，本函数无法区分「同号新进程」，
    彻底修需要再比对进程创建时间与心跳里的 start。
    """
    try:
        hb = json.loads((KERNEL_DIR / "v3_heartbeat.json").read_text(encoding="utf-8-sig"))
        ts = time.mktime(time.strptime(hb.get("time", "1970-01-01 00:00:00"), "%Y-%m-%d %H:%M:%S"))
        age = time.time() - ts
        if not (0 <= age < 15):
            return False
        try:
            pid = int(hb.get("pid") or 0)
        except (TypeError, ValueError):
            pid = 0
        if pid <= 0:
            return True
        return psutil.pid_exists(pid)
    except Exception:
        return False


async def kernel_alive() -> bool:
    """HTTP 侧判活：读心跳是同步磁盘 IO，挪进线程池，别堵事件循环。"""
    return await asyncio.to_thread(kernel_alive_sync)


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
    """健康探针：只回非敏感字段（本接口免鉴权，绝不暴露路径与密钥）。

    ready = HTTP 服务与 PowerShell 内核双就绪，供桌面启动判定使用；
    kernel_alive 保持原字段，避免破坏既有前端与 MCP 契约。
    """
    alive = await kernel_alive()
    return {
        "app": "ok", "name": PRODUCT_NAME, "version": APP_VERSION,
        "kernel_version": KERNEL_DIR.name,
        "kernel_alive": alive,
        "ready": alive,
        "frozen": _frozen(),
        "port": _ACTIVE["port"],
    }


@app.get("/api/temp")
async def temp_status():
    """温度落盘状态（免鉴权，只回温度与日志路径，不含任何密钥）。

    current      最近一条采样（CPU / GPU / 内存 / 硬盘 原始读数）
    session_peak 本次运行峰值
    history_peak 扫已有日志得到的历史峰值（首次启动时算一次）
    真实历史最高只能从落盘之后开始积累：这套接口上线之前的温度没有记录。
    """
    return {"temp": temp_log.current(),
            "note": "采样间隔 %d 秒，落盘 %s" % (temp_log.INTERVAL, temp_log.log_dir())}


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
    d["gpu"] = await asyncio.to_thread(gpu_thermal)
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
    # 客户端不得注入内核授权令牌，也不得指定幂等键：
    # 前者绕过「令牌只由后端注入」的边界，后者会让命令重放被误判为同一条。
    cmd.pop("token", None)
    cmd.pop("idempotency_id", None)
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
    # F9：服务端也参与系统关键进程硬闸，不只依赖内核名单。
    if action in ("kill_process", "stress_process", "suspend_process", "resume_process"):
        if str(cmd.get("process_name") or "").lower() in SYSTEM_CRITICAL:
            raise HTTPException(400, "系统关键进程，拒绝操作")
    if action in TOKEN_ACTIONS:
        tok = _kernel_token()
        if not tok:
            raise HTTPException(400, "本机 token 缺失，无法修改授权清单")
        cmd["token"] = tok
    if action in DESTRUCTIVE_ACTIONS:
        if not body.get("confirm"):
            raise HTTPException(400, "破坏性操作必须带 confirm=true")
        tok = _kernel_token()
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

    # B11：messages 必须是对象数组并限量，否则 dict / 字符串会让 m.get 抛 500。
    msgs = body.get("messages") or []
    if not isinstance(msgs, list) or len(msgs) > 50 or any(
            not isinstance(m, dict) or len(str(m.get("content") or "")) > 32_000
            for m in msgs):
        raise HTTPException(400, "messages 必须是 <=50 条、每条 <=32k 字符的对象数组")

    if target == "cloud":
        if not cloud_ready():
            raise HTTPException(503, "云端 API 未配置：需要 BASE_URL / MODEL / API_KEY")
        cfg = cloud_config()
        if not body.get("model") or body.get("model") == "__cloud__":
            body["model"] = cfg["model"]
        prompt = system_prompt()
        if prompt and not any(m.get("role") == "system" for m in msgs):
            body["messages"] = [{"role": "system", "content": prompt}] + msgs
        url = cfg["base_url"] + "/chat/completions"
        headers = {"Authorization": "Bearer " + cfg["api_key"]}
    else:
        url = LLAMA_BASE + "/v1/chat/completions"
        headers = llama_headers()

    security.audit("chat", target=target, stream=str(bool(body.get("stream"))))
    if not body.get("stream"):
        async with httpx.AsyncClient(timeout=httpx.Timeout(None, connect=8)) as c:
            r = await c.post(url, json=body, headers=headers)
            if r.status_code != 200:
                # B27：不回显上游正文，它可能含密钥或内网拓扑。
                return JSONResponse({"error": "上游模型服务返回错误",
                                    "status": r.status_code}, status_code=502)
            return JSONResponse(r.json(), status_code=r.status_code)

    async def gen():
        async with httpx.AsyncClient(timeout=httpx.Timeout(None, connect=8)) as c:
            async with c.stream("POST", url, json=body, headers=headers) as r:
                if r.status_code != 200:
                    yield ("data: " + json.dumps({"error": "上游模型服务返回错误",
                                                  "status": r.status_code},
                                                 ensure_ascii=False) + "\n\n").encode("utf-8")
                    return
                async for chunk in r.aiter_bytes():
                    yield chunk

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


@app.get("/api/models")
async def models():
    # B12：profiles 被手工改成 list / 字符串时不能在 try 外 .get 导致 500。
    items = []
    try:
        cfg = json.loads(PROFILES.read_text(encoding="utf-8-sig"))
        models_cfg = cfg.get("models") if isinstance(cfg, dict) else None
        if not isinstance(models_cfg, dict):
            models_cfg = {}
        for key, entry in models_cfg.items():
            if not isinstance(entry, dict):
                continue
            ident = entry.get("identity") if isinstance(entry.get("identity"), dict) else {}
            common = entry.get("common") if isinstance(entry.get("common"), dict) else {}
            items.append({"key": key, "alias": common.get("alias") or key,
                          "arch": ident.get("architecture"), "size_gb": ident.get("size_gb")})
    except Exception:
        items = []
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
    """本地模型路由状态：无论成败都返回一致正文，不回显内核原始文本。"""
    ok, text = await bus_call({"action": "router_status"}, timeout=20)
    data = None
    try:
        data = json.loads(text) if text else None
    except Exception:
        data = None
    return {"ok": ok, "text": "", "data": data,
            "error": "" if ok else "内核路由状态不可用"}


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
        if u and not _cloud_url_ok(u):
            raise HTTPException(400, "base_url 指向不允许的地址（内网 / 元数据 / 明文域名）")
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
    except Exception:
        # B27：异常字符串可能含目标主机 / 凭据片段，不回显给前端。
        return {"ok": False, "latency_ms": int((time.time() - t0) * 1000),
                "detail": "连接失败（详情已写入本机日志）"}
    count = None
    try:
        count = len((r.json() or {}).get("data") or [])
    except Exception:
        pass
    return {"ok": r.status_code == 200, "status": r.status_code,
            "latency_ms": int((time.time() - t0) * 1000),
            "model_count": count,
            "detail": "" if r.status_code == 200 else "上游返回错误（正文不回显）"}


# ---------------------------------------------------------------------------
# V0.10 组件自检 / bootstrapping（应用进程内真跑，不依赖外部 AI 对话环境）
# ---------------------------------------------------------------------------
_BOOTSTRAP_CACHE: dict = {"ts": 0.0, "data": None, "error": ""}


def _py_component_dir(name: str) -> Path:
    """
    定位 Python 组件所在版本目录（如 dependency_bootstrap / kvrt_bundle 等）。

    历史原因：这 4 个组件是 v0.10 引入的，而发布内核 current 指向 v0.09，
    所以早期代码写死了 versions/v0.10。v0.11 也已包含这些组件，写死 v0.10
    会让 v0.11 的能力永远用不上，且版本越往后越错。

    现在的口径：KERNEL_DIR 优先；不存在则扫 versions/ 下所有包含该组件的
    目录，取版本号最大的那个；再兜底 v0.10（保持历史行为）。
    """
    if (KERNEL_DIR / (name + ".py")).exists():
        return KERNEL_DIR
    vers = PF_ROOT / "versions"
    best, best_key = None, None
    if vers.is_dir():
        for d in vers.iterdir():
            if not d.is_dir():
                continue
            m = re.match(r"^v0\.(\d+)$", d.name)
            if not m:
                continue
            if not (d / (name + ".py")).exists():
                continue
            k = int(m.group(1))
            if best_key is None or k > best_key:
                best, best_key = d, k
    return best or (vers / "v0.10")


def _bootstrap():
    """延迟导入：模块由 PyInstaller --hidden-import 收进 PYZ，源码运行则从当前内核版本找。"""
    try:
        import dependency_bootstrap
    except ImportError:
        d = _py_component_dir("dependency_bootstrap")
        if str(d) not in sys.path:
            sys.path.insert(0, str(d))
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
    用户点「同意下载」后由前端传入意图；服务端现场签发一次性令牌并立即消费。
    真下载在线程池执行，不阻塞事件循环。
    """
    body = await _json_body(req)
    if not isinstance(body, dict):
        raise HTTPException(400, "请求体必须是 JSON 对象")
    cid = str(body.get("component_id") or "").strip()
    if not cid:
        raise HTTPException(400, "缺少 component_id")
    if str(body.get("consent") or "") != "yes":
        raise HTTPException(400, "缺少用户显式同意")
    # 只允许清单里的 id，避免把任意字符串传进 install()
    try:
        known = [c.id for c in _bootstrap().COMPONENTS]
    except Exception:
        known = []
    if known and cid not in known:
        raise HTTPException(400, "未知组件：%s" % cid)
    # F8：令牌在此现场签发并立即被 install() 消费，不下发浏览器、不进源码。
    consent = _bootstrap().mint_consent("download")
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
    if not cid:
        raise HTTPException(400, "缺少 component_id")
    if str(body.get("install_consent") or "") != "yes":
        raise HTTPException(400, "缺少用户对系统级安装的第二道显式同意")
    token = _bootstrap().mint_consent("install")
    out = await asyncio.to_thread(_bootstrap().launch_vendor_wizard, cid, token)
    security.audit("bootstrap_wizard", component=cid,
                   launched=str(bool(out.get("launched"))),
                   reason=str(out.get("reason") or "")[:160])
    return out


# ---------------------------------------------------------------------------
# 安全扫描：复用 versions/v0.10 已跑通的 kvrt_bundle 链路
#   1. run_scan 需管理员权限 + 引擎已验签，不满足会抛 RuntimeError，原样透出
#   2. 默认 process_level=0（只报告，不处置）；要处置必须显式 disinfect_confirm=yes
#   3. 扫描可达数分钟，故后台线程执行 + 状态轮询，不在 HTTP 请求里等
#   4. 单飞：同一时刻只允许一个扫描任务
# ---------------------------------------------------------------------------
_SCAN_LOCK = threading.Lock()
_SCAN_STATE: dict = {"running": False, "started": "", "finished": "",
                     "result": None, "error": "", "scope": "", "path": "",
                     "verdict": None}


def _kvrt():
    """延迟导入 kvrt_bundle：PyInstaller 已 --hidden-import 收进 PYZ，源码运行从当前内核版本找。"""
    try:
        import kvrt_bundle
    except ImportError:
        d = _py_component_dir("kvrt_bundle")
        if str(d) not in sys.path:
            sys.path.insert(0, str(d))
        import kvrt_bundle
    return kvrt_bundle


def _judge_scan(scan: dict, parsed: dict) -> dict:
    """把 exit_code 与产出组合成明确结论。

    实测教训（2026-11-15）：扫一个只有 3 个 txt 的空目录时，KVRT 退出码为 0
    但 stdout 是 `finish with status -1`、files_scanned=0。若只看退出码就会
    把「没扫成」误报成「干净」。这里逐级区分，宁可说 inconclusive 也不说 clean。
    """
    stdout = str(scan.get("stdout") or "")
    try:
        processed = int(parsed.get("files_scanned") or 0)
    except Exception:
        processed = 0
    try:
        found = int(parsed.get("threat_count") or 0)
    except Exception:
        found = 0

    if scan.get("timed_out"):
        return {"verdict": "timeout", "processed": processed, "found": found,
                "reason": "扫描超时，结论不可用"}
    if "status -1" in stdout:
        return {"verdict": "failed", "processed": processed, "found": found,
                "reason": "KVRT 异常退出（finish with status -1），本次扫描未生效，不能判定为安全"}
    if scan.get("exit_code") not in (0,):
        return {"verdict": "failed", "processed": processed, "found": found,
                "reason": "KVRT 退出码 %r，扫描未正常完成" % scan.get("exit_code")}
    if processed == 0:
        return {"verdict": "inconclusive", "processed": 0, "found": found,
                "reason": "扫描完成但未统计到任何对象（目标可能为空、不可读或格式不支持），不能判定为安全"}
    if found > 0:
        return {"verdict": "threats", "processed": processed, "found": found,
                "reason": "扫描 %d 个对象，发现 %d 项威胁" % (processed, found)}
    return {"verdict": "clean", "processed": processed, "found": found,
            "reason": "扫描 %d 个对象，未发现威胁" % processed}


def _scan_worker(scope: str, path: str, level: int, timeout: int,
                 accept_eula: bool = False) -> None:
    try:
        k = _kvrt()
        req = k.ScanRequest(scope=scope, custom_path=path, process_level=level,
                            timeout_sec=timeout, accept_eula=bool(accept_eula))
        out = k.run_scan(req)
        try:
            parsed = k.parse_kvrt_output(str(req.data_dir), out.get("stdout", "") or "")
        except Exception as e:
            parsed = {"available": False, "error": "%s: %s" % (type(e).__name__, e)}
        _SCAN_STATE.update({"result": {"scan": out, "parsed": parsed},
                            "verdict": _judge_scan(out, parsed)})
    except Exception as e:
        _SCAN_STATE.update({"error": "%s: %s" % (type(e).__name__, e)})
    finally:
        _SCAN_STATE["running"] = False
        _SCAN_STATE["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")


@app.get("/api/security/scan/status")
async def security_scan_status():
    """只读扫描状态：引擎是否就绪 + 当前进度 + 上次结果。"""
    try:
        info = await asyncio.to_thread(_kvrt().status)
    except Exception as e:
        info = {"available": False, "error": "%s: %s" % (type(e).__name__, e)}
    return {"ok": True, "engine": info, "running": _SCAN_STATE["running"],
            "started": _SCAN_STATE["started"], "finished": _SCAN_STATE["finished"],
            "scope": _SCAN_STATE["scope"], "path": _SCAN_STATE["path"],
            "error": _SCAN_STATE["error"], "result": _SCAN_STATE["result"],
            "eula_url": info.get("eula_url") or "https://support.kaspersky.com/8530",
            "download_channel": info.get("download_channel") or
            "Kaspersky official devbuild · KVRT latest（非消费级下载页）"}


@app.post("/api/security/scan")
async def security_scan_start(req: Request):
    """
    发起真实扫描。默认只报告不处置。
    body: {scope: custom|core|allvolumes, path, process_level: 0-3,
           timeout_sec, disinfect_confirm: "yes", accept_eula: true}
    accept_eula 必须是 JSON 布尔 true；缺省或 false 一律 400，不代替用户接受 KVRT EULA。
    """
    body = await _json_body(req)
    if not isinstance(body, dict):
        raise HTTPException(400, "请求体必须是 JSON 对象")
    # KVRT EULA 必须由用户本人显式确认；不接受字符串、1、"yes" 之类的模糊值。
    if body.get("accept_eula") is not True:
        raise HTTPException(
            400,
            "必须先由用户本人勾选并同意 KVRT EULA（accept_eula=true）；"
            "本应用不代替用户接受协议。EULA: https://support.kaspersky.com/8530")
    with _SCAN_LOCK:
        if _SCAN_STATE["running"]:
            raise HTTPException(409, "已有扫描任务在进行中，请等待完成或查看状态")
        scope = str(body.get("scope") or "custom").strip().lower()
        if scope not in ("custom", "core", "allvolumes"):
            raise HTTPException(400, "scope 只能是 custom / core / allvolumes")
        target = str(body.get("path") or "").strip()
        if scope == "custom":
            if not target:
                raise HTTPException(400, "scope=custom 时必须提供 path")
            if not os.path.isabs(target):
                raise HTTPException(400, "path 必须是绝对路径")
        else:
            target = ""
        try:
            level = int(body.get("process_level") or 0)
        except Exception:
            raise HTTPException(400, "process_level 必须是整数")
        if level not in (0, 1, 2, 3):
            raise HTTPException(400, "process_level 只能是 0/1/2/3")
        # 处置是不可逆动作：必须第二道显式同意
        if level != 0 and str(body.get("disinfect_confirm") or "") != "yes":
            raise HTTPException(400, "启用处置（process_level>0）必须显式传 disinfect_confirm=yes")
        try:
            timeout = int(body.get("timeout_sec") or 3600)
        except Exception:
            timeout = 3600
        timeout = max(30, min(timeout, 14400))
        _SCAN_STATE.update({"running": True, "result": None, "error": "",
                            "scope": scope, "path": target,
                            "started": time.strftime("%Y-%m-%d %H:%M:%S"),
                            "finished": ""})
    threading.Thread(target=_scan_worker, args=(scope, target, level, timeout, True),
                     daemon=True, name="pf-scan").start()
    security.audit("security_scan_start", scope=scope, path=target,
                   process_level=str(level), eula="accepted_by_user")
    return {"ok": True, "started": True, "scope": scope, "path": target,
            "process_level": level, "timeout_sec": timeout,
            "accept_eula": True,
            "note": "扫描在后台执行，用 GET /api/security/scan/status 查进度"}


def start_background():
    threading.Thread(target=SNAP.run, daemon=True).start()
    # 温度采样线程：与快照线程并列，互不阻塞；源不可用时只记录、不影响服务。
    try:
        temp_log.start()
        security.audit("temp_sampler_started", interval=str(temp_log.INTERVAL),
                       log_dir=str(temp_log.log_dir()))
    except Exception as e:
        security.audit("temp_sampler_failed", error="%s: %s" % (type(e).__name__, e))


def serve(port: int = PORT, sock=None):
    _ACTIVE["port"] = int(port)
    # server_header=False / date_header=False：不回 Server 指纹，减少侦察信息。
    # 传入已 listen 的 socket 时直接交给 uvicorn，消除「先探测再重绑」的 TOCTOU。
    config = uvicorn.Config(app, host=HOST, port=port, log_level="warning",
                            server_header=False, date_header=False)
    uv_server = uvicorn.Server(config)
    if sock is not None:
        uv_server.run(sockets=[sock])
    else:
        uv_server.run()


def serve_only(start: int = 18080, tries: int = 40):
    """无窗口调试入口：与桌面端共用端口顺延 + _ACTIVE 契约（B29）。

    刻意不再实现一遍 uvicorn.run(app, port=PORT)：那条老路径绕过
    bind_port，多实例会互相抢端口，_ACTIVE 也永远是假的初始值。
    """
    start_background()
    for p in range(start, start + tries):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind((HOST, p))
            s.listen(128)
            serve(p, s)
            return
        except OSError:
            s.close()
    raise SystemExit("回环端口 %d~%d 均被占用" % (start, start + tries - 1))


if __name__ == "__main__":
    serve_only()
