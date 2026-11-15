# -*- coding: utf-8 -*-
r"""CPU / GPU / 内存 / 硬盘温度采样与落盘。

设计约束
1. 只读：本模块只调用传感器读取接口，绝不写入任何硬件或电源设置。
2. 双源：优先 LibreHardwareMonitorLib.dll（pythonnet，需管理员权限），
   失败时 GPU 退回系统自带 nvidia-smi，CPU 无法兜底时如实置空，不填假值。
3. 落盘：app_paths.log_dir() 下按天切分 temp-YYYYMMDD.jsonl，每行一条采样，
   含本地时间戳、epoch、数据源与原始读数，便于事后核算「历史最高」。
4. 峰值：内存维护本次运行峰值；启动时扫描已有日志得到历史峰值。

环境变量
POWERFOCUS_LHM_DIR       LibreHardwareMonitor 安装目录（默认 E:\Program Files\LibreHardwareMonitor）
POWERFOCUS_TEMP_INTERVAL 采样间隔秒（默认 30，下限 5）
"""
from __future__ import annotations

import json
import os
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

DEFAULT_LHM_DIR = r"E:\Program Files\LibreHardwareMonitor"
LHM_DIR = Path(os.environ.get("POWERFOCUS_LHM_DIR") or DEFAULT_LHM_DIR)

try:
    INTERVAL = int(os.environ.get("POWERFOCUS_TEMP_INTERVAL") or 30)
except ValueError:
    INTERVAL = 30
if INTERVAL < 5:
    INTERVAL = 5

# 历史扫描上限，防止异常大的日志阻塞启动
_MAX_HISTORY_LINES = 500000

_LOCK = threading.RLock()
_COMPUTER = None
_LHM_ERROR: str | None = None
_SOURCE = "none"
_THREAD: threading.Thread | None = None
_STOP = threading.Event()

_STATE: dict = {
    "samples": 0,
    "current": None,
    "session_peak": {},
    "history_peak": {},
    "last_error": None,
    "log_file": None,
    "started_at": None,
}

# 只跟踪这几个关键指标的峰值，避免键爆炸
_TRACKED = ("cpu.tctl", "cpu.ccd_max", "gpu.core", "gpu.mem_junction",
            "dimm.max", "nvme.max")


def log_dir() -> Path:
    """与桌面日志、安全审计共用 app_paths 的单一真源。"""
    try:
        import app_paths
    except ImportError:
        sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
        import app_paths
    try:
        return Path(app_paths.log_dir())
    except Exception:
        return Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "PowerFocus" / "logs"


def _now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _num(v):
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


# ---------------- 数据源 1：LibreHardwareMonitorLib ----------------
def _open_lhm():
    """加载 LibreHardwareMonitorLib 并打开 Computer。失败返回 None，不抛出。"""
    global _COMPUTER, _LHM_ERROR
    if _COMPUTER is not None:
        return _COMPUTER
    try:
        import clr  # pythonnet

        if str(LHM_DIR) not in sys.path:
            sys.path.insert(0, str(LHM_DIR))
        clr.AddReference("LibreHardwareMonitorLib")
        from LibreHardwareMonitor.Hardware import Computer

        c = Computer()
        c.IsCpuEnabled = True
        c.IsGpuEnabled = True
        c.IsMemoryEnabled = True
        c.IsStorageEnabled = True
        c.IsMotherboardEnabled = True
        c.IsControllerEnabled = False
        c.IsNetworkEnabled = False
        c.IsPsuEnabled = False
        c.IsBatteryEnabled = False
        c.Open()
        _COMPUTER = c
        _LHM_ERROR = None
        return c
    except Exception as exc:
        _LHM_ERROR = "%s: %s" % (type(exc).__name__, exc)
        return None


def _read_lhm() -> dict | None:
    """枚举所有温度传感器。读取失败返回 None。"""
    c = _open_lhm()
    if c is None:
        return None
    cpu: dict = {}
    gpu: dict = {}
    igpu: dict = {}
    dimm: dict = {}
    nvme: dict = {}
    try:
        for hw in c.Hardware:
            hw.Update()
            kind = str(hw.HardwareType)
            for s in hw.Sensors:
                if str(s.SensorType) != "Temperature":
                    continue
                val = _num(s.Value)
                if val is None:
                    continue
                name = str(s.Name)
                if kind == "Cpu":
                    cpu[name] = val
                elif kind == "GpuNvidia":
                    gpu[name] = val
                elif kind == "GpuAmd":
                    igpu[name] = val
                elif kind == "Memory" and name.startswith("DIMM"):
                    dimm[name] = val
                elif kind == "Storage":
                    nvme[str(hw.Name)] = val
    except Exception as exc:
        _LHM_ERROR = "读取中断: %s: %s" % (type(exc).__name__, exc)
        return None
    return {"cpu": cpu, "gpu": gpu, "igpu": igpu, "dimm": dimm, "nvme": nvme}


# ---------------- 数据源 2：nvidia-smi 兜底 ----------------
_CREATE_NO_WINDOW = 0x08000000


def _read_nvidia() -> dict:
    import subprocess

    query = "--query-gpu=temperature.gpu,temperature.memory,power.draw,utilization.gpu"
    out: dict = {}
    try:
        p = subprocess.run(["nvidia-smi", query, "--format=csv,noheader,nounits"],
                           capture_output=True, timeout=3,
                           creationflags=_CREATE_NO_WINDOW)
        if p.returncode != 0:
            return out
        row = (p.stdout or b"").decode("utf-8", "replace").strip().splitlines()
        if not row:
            return out
        parts = [x.strip() for x in row[0].split(",")]
        if parts and parts[0] not in ("N/A", "[N/A]", ""):
            out["GPU Core"] = _num(parts[0])
        if len(parts) > 1 and parts[1] not in ("N/A", "[N/A]", ""):
            out["GPU Memory Junction"] = _num(parts[1])
    except Exception:
        pass
    return {k: v for k, v in out.items() if v is not None}


# ---------------- 采样与峰值 ----------------
def _ccd_max(cpu: dict):
    vals = [v for k, v in cpu.items() if "CCD" in k and "Limit" not in k]
    if cpu.get("CCDs Max (Tdie)") is not None:
        return cpu["CCDs Max (Tdie)"]
    return max(vals) if vals else None


def _tctl(cpu: dict):
    for k, v in cpu.items():
        if "Tctl" in k:
            return v
    return None


def _pick(d: dict, needle: str):
    for k, v in d.items():
        if needle.lower() in k.lower():
            return v
    return None


def _flat(rec: dict) -> dict:
    """把一条采样压成「关键指标 → 数值」，用于峰值比较。"""
    cpu = rec.get("cpu") or {}
    gpu = rec.get("gpu") or {}
    dimm = rec.get("dimm") or {}
    nvme = rec.get("nvme") or {}
    flat = {
        "cpu.tctl": _tctl(cpu),
        "cpu.ccd_max": _ccd_max(cpu),
        "gpu.core": _pick(gpu, "GPU Core"),
        "gpu.mem_junction": _pick(gpu, "Memory Junction"),
        "dimm.max": max([v for v in dimm.values() if v is not None], default=None),
        "nvme.max": max([v for v in nvme.values() if v is not None], default=None),
    }
    return {k: v for k, v in flat.items() if v is not None}


def _bump(peaks: dict, flat: dict, ts: str | None) -> None:
    for key, val in flat.items():
        cur = peaks.get(key)
        if cur is None or val > cur.get("value", float("-inf")):
            peaks[key] = {"value": val, "at": ts}


def _collect() -> dict:
    global _SOURCE
    rec: dict = {"ts": _now_iso(), "epoch": round(time.time(), 3)}
    lhm = _read_lhm()
    if lhm is not None and (lhm["cpu"] or lhm["gpu"]):
        rec.update(lhm)
        rec["source"] = "lhm"
        _SOURCE = "lhm"
        return rec
    gpu = _read_nvidia()
    rec.update({"cpu": {}, "gpu": gpu, "igpu": {}, "dimm": {}, "nvme": {}})
    rec["source"] = "nvidia-smi" if gpu else "none"
    _SOURCE = rec["source"]
    if _LHM_ERROR:
        rec["source_error"] = _LHM_ERROR
    return rec


def sample() -> dict | None:
    """采一条并追加写日志。返回该条记录；失败返回 None。"""
    try:
        rec = _collect()
    except Exception as exc:
        _STATE["last_error"] = "采集失败: %s: %s" % (type(exc).__name__, exc)
        return None
    try:
        d = log_dir()
        d.mkdir(parents=True, exist_ok=True)
        fp = d / ("temp-%s.jsonl" % datetime.now().strftime("%Y%m%d"))
        with _LOCK:
            _STATE["current"] = rec
            _STATE["samples"] = int(_STATE["samples"]) + 1
            _STATE["log_file"] = str(fp)
            _bump(_STATE["session_peak"], _flat(rec), rec.get("ts"))
            with fp.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception as exc:
        _STATE["last_error"] = "落盘失败: %s: %s" % (type(exc).__name__, exc)
    return rec


def scan_history() -> dict:
    """扫描已有 temp 日志，算出历史峰值。"""
    peaks: dict = {}
    d = log_dir()
    total = 0
    try:
        files = sorted(d.glob("temp-*.jsonl"))
    except OSError:
        return peaks
    for fp in files:
        try:
            with fp.open("r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    total += 1
                    if total > _MAX_HISTORY_LINES:
                        break
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    _bump(peaks, _flat(rec), rec.get("ts"))
        except OSError:
            continue
        if total > _MAX_HISTORY_LINES:
            break
    return peaks


def _loop(interval: int) -> None:
    _STATE["started_at"] = _now_iso()
    with _LOCK:
        _STATE["history_peak"] = scan_history()
    while not _STOP.is_set():
        sample()
        _STOP.wait(interval)


def start(interval: int | None = None) -> None:
    """启动后台采样线程（幂等）。"""
    global _THREAD
    with _LOCK:
        if _THREAD is not None and _THREAD.is_alive():
            return
        _STOP.clear()
        _THREAD = threading.Thread(target=_loop, args=(int(interval or INTERVAL),),
                                   name="pf-temp-sampler", daemon=True)
        _THREAD.start()


def stop() -> None:
    _STOP.set()


def current() -> dict:
    """供 HTTP 接口读取的当前状况。"""
    with _LOCK:
        return {
            "ok": _STATE["current"] is not None,
            "interval_sec": INTERVAL,
            "samples": _STATE["samples"],
            "started_at": _STATE["started_at"],
            "log_file": _STATE["log_file"],
            "log_dir": str(log_dir()),
            "lhm_dir": str(LHM_DIR),
            "lhm_available": _COMPUTER is not None,
            "lhm_error": _LHM_ERROR,
            "source": _SOURCE,
            "current": _STATE["current"],
            "session_peak": _STATE["session_peak"],
            "history_peak": _STATE["history_peak"],
            "last_error": _STATE["last_error"],
        }
