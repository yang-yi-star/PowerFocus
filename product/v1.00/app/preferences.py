# -*- coding: utf-8 -*-
"""应用偏好（非敏感）落盘 ``%LOCALAPPDATA%\\PowerFocus\\v0.10\\preferences.json``。

与云端凭据库（DPAPI vault）严格分开：这里只放界面与行为偏好，**不存任何密钥**。

字段：
  ``autostart``         开机自启（注册表 HKCU Run 的开关；实测状态由后端另回 ``autostart_active``）
  ``close_action``      关闭窗口时：``exit`` 直接退出 / ``tray`` 收到系统托盘
  ``poll_interval_ms``  快照轮询间隔（500–10000 ms）
  ``onboarded``        首次引导是否已完成
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

try:
    import app_paths
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
    import app_paths

DEFAULTS: dict = {
    "autostart": False,
    "close_action": "exit",
    "poll_interval_ms": 1000,
    "onboarded": False,
}

_CLOSE_ACTIONS = ("exit", "tray")
_MIN_INTERVAL, _MAX_INTERVAL = 500, 10000


def _path() -> Path:
    return app_paths.write_path("preferences.json")


def _validate(d: dict) -> dict:
    out = dict(DEFAULTS)
    for k in DEFAULTS:
        if k in d:
            out[k] = d[k]
    out["autostart"] = bool(out["autostart"])
    if out["close_action"] not in _CLOSE_ACTIONS:
        out["close_action"] = DEFAULTS["close_action"]
    try:
        out["poll_interval_ms"] = int(out["poll_interval_ms"])
    except (TypeError, ValueError):
        out["poll_interval_ms"] = DEFAULTS["poll_interval_ms"]
    out["poll_interval_ms"] = max(_MIN_INTERVAL, min(_MAX_INTERVAL, out["poll_interval_ms"]))
    out["onboarded"] = bool(out["onboarded"])
    return out


def load() -> dict:
    """读取偏好；文件损坏 / 缺字段一律回退默认，不把异常抛给界面。"""
    out = dict(DEFAULTS)
    try:
        p = app_paths.first_existing("preferences.json")
        if p.exists():
            data = json.loads(p.read_text(encoding="utf-8-sig"))
            if isinstance(data, dict):
                out.update({k: data[k] for k in DEFAULTS if k in data})
    except Exception:
        pass
    return _validate(out)


def save(patch: dict) -> dict:
    """合并写入；只接受 schema 内字段，未知键忽略。原子写（.tmp + replace）。"""
    cur = load()
    for k in DEFAULTS:
        if k in patch:
            cur[k] = patch[k]
    cur = _validate(cur)
    p = _path()
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(cur, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, p)
    return cur
