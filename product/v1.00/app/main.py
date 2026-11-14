# -*- coding: utf-8 -*-
# ============================================================
# 通用算力调度中心 · 桌面端入口（product\v1.00\app\main.py）
# 职责：拉起本地服务 → 确保内核在线 → 打开桌面窗口。
# 打包：PyInstaller --onefile --windowed（见 build\build.ps1）
# ============================================================
import ctypes
import json
import logging
import os
import socket
import subprocess
import threading
import time
import traceback
from logging.handlers import RotatingFileHandler
from pathlib import Path

import server

# ---------- 日志（审计修复：desktop.log 无限追加 → 大小轮转） ----------
# 路径对齐 app_paths.py 的规则：%LOCALAPPDATA%\<产品>\<版本槽>\logs\。
# v1.00 桌面端用版本槽 v1.00（app_paths.py 的 VERSION_SLOT=v0.10 是引擎槽，不混用）。
# 依据：https://docs.python.org/3/library/logging.handlers.html#rotatingfilehandler
#   "Rollover occurs whenever the current log file is nearly maxBytes in length"
#   backupCount 保留 .1~.N 备份，超出上限的最旧备份被挤掉。
_VERSION_SLOT = "v1.00"
_LOG_MAX_BYTES = 2 * 1024 * 1024   # 单文件上限 2MB
_LOG_BACKUPS = 5                   # desktop.log.1 ~ desktop.log.5，封顶约 12MB

_logger = logging.getLogger("powerfocus.desktop")
_logger.propagate = False
_logger.setLevel(logging.INFO)


def log_dir() -> Path:
    base = (Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "PowerFocus"
            / _VERSION_SLOT / "logs")
    try:
        base.mkdir(parents=True, exist_ok=True)
    except Exception:
        base = Path(os.environ.get("TEMP", "."))
    return base


def log(msg: str):
    try:
        if not _logger.handlers:
            # delay=True：首次 emit 才打开文件，目录回退 TEMP 时也不留空壳。
            _logger.addHandler(RotatingFileHandler(
                log_dir() / "desktop.log", maxBytes=_LOG_MAX_BYTES,
                backupCount=_LOG_BACKUPS, encoding="utf-8", delay=True))
            _logger.handlers[0].setFormatter(
                logging.Formatter("%(asctime)s %(message)s", datefmt="%Y-%m-%d %H:%M:%S"))
        _logger.info(msg)
    except Exception:
        pass


_MUTEX_HANDLE = None


def notify_already_running():
    """第二个实例被互斥量挡下时给出可见提示，避免「双击没反应」。

    --windowed 打包没有控制台，日志写了用户也看不到；这里用系统消息框
    作为唯一可见反馈。MB_TOPMOST 保证不会被其它窗口盖住。
    """
    try:
        ctypes.windll.user32.MessageBoxW(
            0,
            "电脑算力调度中心已经在运行了。\n请查看任务栏或已打开的窗口，无需重复启动。",
            "电脑算力调度中心",
            0x40 | 0x40000,  # MB_ICONINFORMATION | MB_TOPMOST
        )
    except Exception:
        pass


def single_instance() -> bool:
    """命名互斥体，防止重复打开多个窗口。"""
    global _MUTEX_HANDLE
    try:
        # 64 位进程里 HANDLE 是指针；不设 restype 会被 ctypes 截成 c_int。
        ctypes.windll.kernel32.CreateMutexW.restype = ctypes.c_void_p
        _MUTEX_HANDLE = ctypes.windll.kernel32.CreateMutexW(
            None, False, "Global\\PowerFocusDesktop_v1")
        return ctypes.windll.kernel32.GetLastError() != 183  # ERROR_ALREADY_EXISTS
    except Exception:
        return True


def find_port(start: int = 18080, tries: int = 40) -> int:
    for p in range(start, start + tries):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", p))
                return p
            except OSError:
                continue
    return start


def wait_ready(port: int, timeout: float = 12.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.4)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.2)
    return False


def kernel_alive() -> bool:
    hb = server.KERNEL_DIR / "v3_heartbeat.json"
    try:
        d = json.loads(hb.read_text(encoding="utf-8-sig"))
        ts = time.mktime(time.strptime(d.get("time", "1970-01-01 00:00:00"), "%Y-%m-%d %H:%M:%S"))
        return (time.time() - ts) < 15
    except Exception:
        return False


def ensure_kernel():
    """内核不在线时自动拉起（脱离当前进程组，桌面端退出不影响内核）。"""
    if kernel_alive():
        log("内核已在线: %s" % server.KERNEL_DIR)
        return True
    mf = server.KERNEL_DIR / "MANIFEST.json"
    entry = None
    try:
        entry = json.loads(mf.read_text(encoding="utf-8-sig")).get("entry")
    except Exception:
        pass
    if not entry:
        cand = list(server.KERNEL_DIR.glob("*_v*.ps1"))
        entry = cand[0].name if cand else None
    if not entry or not (server.KERNEL_DIR / entry).exists():
        log("未找到内核入口脚本，跳过自动启动")
        return False
    pwsh = server._pwsh()
    cmd = [pwsh, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(server.KERNEL_DIR / entry)]
    try:
        flags = 0
        if os.name == "nt":
            # 不能用 DETACHED_PROCESS：pwsh 的 WinForms 托盘在无控制台会话中会立即退出（退出码 0）
            flags = 0x08000000 | 0x00000200  # CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP
        subprocess.Popen(cmd, creationflags=flags, close_fds=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log("内核已拉起: %s (pwsh=%s)" % (entry, pwsh))
    except Exception as e:
        log("内核拉起失败: %s" % e)
        return False
    for _ in range(50):
        if kernel_alive():
            return True
        time.sleep(0.2)
    log("内核启动超时（10 秒内未见心跳）")
    return False


def log_bootstrap():
    """
    启动时在后台线程跑一次 V0.10 组件自检（只读），结果写进应用日志。
    自检含 WMI / 注册表 / 可执行文件探测，放后台避免拖慢窗口出现。
    """
    try:
        r = server.warm_bootstrap() or {}
        s = r.get("summary") or {}
        log("组件自检: available=%s startup_ok=%s 共 %s 项 / 齐全 %s 项 / 缺失 %s 项：%s"
            % (r.get("available", True), r.get("startup_ok"), s.get("total"),
               s.get("present"), s.get("missing"), r.get("startup_note") or ""))
        for c in (r.get("components") or []):
            if not c.get("present"):
                log("组件待办: %s (%s) -> %s" % (c.get("id"), c.get("install_mode"),
                                                 c.get("action") or ""))
    except Exception as e:
        log("组件自检异常（不影响启动）: %s: %s" % (type(e).__name__, e))


def main():
    if not single_instance():
        log("已有实例在运行，退出")
        notify_already_running()
        return
    import webview

    server.start_background()
    threading.Thread(target=log_bootstrap, daemon=True).start()
    port = find_port()
    threading.Thread(target=lambda: server.serve(port), daemon=True).start()
    if not wait_ready(port):
        log("本地服务启动失败")
        raise SystemExit(1)
    log("服务已就绪: http://127.0.0.1:%d" % port)
    threading.Thread(target=ensure_kernel, daemon=True).start()

    webview.create_window(
        "电脑算力调度中心 v1.00",
        "http://127.0.0.1:%d/" % port,
        width=1300, height=840, min_size=(1040, 680),
        background_color="#070b10",
    )
    webview.start(gui="edgechromium", debug=False)
    log("窗口已关闭，进程退出")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        pass
    except Exception:
        log("致命异常:\n" + traceback.format_exc())
        try:
            ctypes.windll.user32.MessageBoxW(0, traceback.format_exc()[-1200:],
                                             "电脑算力调度中心 启动失败", 0x10)
        except Exception:
            pass
