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
# 统一走 app_paths.log_dir()：桌面日志 / 安全审计不再各写一套目录。
# 依据：https://docs.python.org/3/library/logging.handlers.html#rotatingfilehandler
_LOG_MAX_BYTES = 2 * 1024 * 1024   # 单文件上限 2MB
_LOG_BACKUPS = 5                   # desktop.log.1 ~ desktop.log.5，封顶约 12MB

_logger = logging.getLogger("powerfocus.desktop")
_logger.propagate = False
_logger.setLevel(logging.INFO)


def log_dir() -> Path:
    """桌面日志目录：与 security.audit 共用 app_paths 的单一真源。"""
    try:
        import app_paths
        return app_paths.log_dir()
    except Exception:
        base = Path(os.environ.get("TEMP", ".")) / "PowerFocus" / "logs"
        base.mkdir(parents=True, exist_ok=True)
        return base


_LOG_LOCK = threading.Lock()


def _init_logger():
    """双重检查 + 锁：多线程首次并发写日志不能各加一个 handler。"""
    if _logger.handlers:
        return
    with _LOG_LOCK:
        if _logger.handlers:
            return
        # 先设 formatter 再挂 handler，避免另一线程在两者之间就 emit。
        h = RotatingFileHandler(log_dir() / "desktop.log", maxBytes=_LOG_MAX_BYTES,
                                backupCount=_LOG_BACKUPS, encoding="utf-8", delay=True)
        h.setFormatter(logging.Formatter("%(asctime)s %(message)s",
                                         datefmt="%Y-%m-%d %H:%M:%S"))
        _logger.addHandler(h)


def log(msg: str):
    try:
        _init_logger()
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
        # WinDLL(use_last_error=True) 把 LastError 存进线程私有槽，
        # 不会被两次 FFI 调用之间的其它 ctypes 操作覆盖。
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.CreateMutexW.restype = ctypes.c_void_p
        k32.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p]
        h = k32.CreateMutexW(None, False, "Global\\PowerFocusDesktop_v1")
        if not h:
            # 创建失败不等于「首个实例」，必须按失败处理。
            return False
        _MUTEX_HANDLE = h
        return ctypes.get_last_error() != 183  # ERROR_ALREADY_EXISTS
    except Exception:
        return True


def bind_port(start: int = 18080, tries: int = 40):
    """绑定并 listen 回环端口，把 socket 直接交给 uvicorn。

    旧实现 bind 后立刻由 with 释放、再由 uvicorn 重新 bind，中间存在
    TOCTOU 窗口；现在 socket 全程持有，不再二次绑定。
    """
    for p in range(start, start + tries):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", p))
            s.listen(128)
            return p, s
        except OSError:
            s.close()
    raise RuntimeError("回环端口 %d~%d 均被占用" % (start, start + tries - 1))


def wait_ready(port: int, timeout: float = 12.0, require_kernel: bool = False) -> bool:
    """等待 HTTP 层真正就绪；桌面入口还要求内核心跳已上线。

    socket 由调用方预先 listen，TCP 探测会立刻成功却可能还没有 HTTP 服务，
    因此改为直连 /api/health（http.client 不走系统代理），并读 ``ready`` 字段。
    """
    import http.client
    deadline = time.time() + timeout
    while time.time() < deadline:
        c = None
        status, body = 0, b""
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=0.4)
            c.request("GET", "/api/health")
            r = c.getresponse()
            body = r.read()
            status = r.status
        except Exception:
            pass
        finally:
            if c is not None:
                c.close()
        if status == 200:
            try:
                if not require_kernel or json.loads(body or b"{}").get("ready") is True:
                    return True
            except (ValueError, TypeError):
                if not require_kernel:
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
        proc = subprocess.Popen(cmd, creationflags=flags, close_fds=True,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log("内核已拉起: %s (pwsh=%s)" % (entry, pwsh))
    except Exception as e:
        log("内核拉起失败: %s" % e)
        return False

    # 启动竞态修复（2026-11-14）：
    # 原实现硬等 10 秒（50 × 0.2s），在磁盘繁忙、杀软扫描、规则引擎初始化较慢的机器上
    # 会误判成「内核未响应」红条（desktop.log 2026-11-14 06:29:12 复现）。
    # 改为指数退避 + 内核进程存活检查，总上限 90 秒；正常机器仍在 1 秒内返回，
    # 且内核若提前崩掉会立刻报「进程已退出」而不是干等到超时。
    deadline = time.time() + 90
    interval = 0.5
    while time.time() < deadline:
        if kernel_alive():
            return True
        if proc.poll() is not None:
            log("内核进程已退出（退出码 %s），未写出心跳" % proc.returncode)
            return False
        time.sleep(interval)
        interval = min(interval * 1.5, 5.0)
    log("内核启动超时（90 秒内未见心跳）")
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
    # B28：先拉内核，再等「服务 + 内核」双就绪，窗口打开时不再是空壳。
    threading.Thread(target=ensure_kernel, daemon=True).start()
    port, sock = bind_port()
    threading.Thread(target=lambda: server.serve(port, sock), daemon=True).start()
    if not wait_ready(port, timeout=20.0, require_kernel=True):
        # 内核未就绪不阻断界面：health 如实回报 ready=false，用户仍能看到状态，
        # 避免「双击没反应」；但桌面启动日志必须留下告警。
        log("警告：20 秒内内核未就绪，界面仍将打开（health.ready=false）")
    log("服务已就绪: http://127.0.0.1:%d" % port)

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
