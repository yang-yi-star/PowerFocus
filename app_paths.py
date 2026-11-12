# -*- coding: utf-8 -*-
"""
统一的应用数据目录（审计 S1 修复 · 2026-11-13）
=================================================

为什么需要这一层：
    之前 v0.10 各模块把 reports/ engines/ scan_settings.json 全部写在
    ``Path(__file__).parent``（程序目录），而 v1.00 的 main.py / security.py
    已经正确写 ``%LOCALAPPDATA%\\PowerFocus``。同一产品两套路径策略。
    更严重的是 PyInstaller ``--onefile`` 的程序目录其实是每次启动解压的
    临时目录，且 Microsoft Learn WACK「Install to the correct folders test」
    明令禁止应用把用户数据写进 Program Files（标准用户无写权限）。

依据：
  * https://learn.microsoft.com/en-us/windows/desktop/win_cert/windows-app-certification-kit-tests
    「The app must not store user data or app data in a Program Files folder …
     All app data exclusive to a specific user … must be stored in Users\\AppData.」
  * https://msdn.microsoft.com/en-us/visualc/bb756940
    「Per-User Application Settings Locations (UAC)」：运行时变更的设置应存
    CSIDL_APPDATA / CSIDL_LOCAL_APPDATA / CSIDL_COMMON_APPDATA。

设计约束：
  1. ``data_root()`` **纯计算，不创建任何目录** —— 启动自检必须保持只读。
     创建目录只允许在真正写入时由调用方显式调用 ``ensure()``。
  2. 写一律走新目录；读优先新目录，回退历史目录（源码版本目录）。
     **不自动搬迁、不删除任何用户文件**，符合项目一贯约定。
  3. ``POWERFOCUS_DATA_DIR`` 环境变量可覆盖，便于测试与便携部署。
  4. 打包后 ``legacy_root()`` 指向 ``_MEIPASS/versions/v0.10``，天然不存在，
     回退逻辑自动失效，不会误读临时目录。
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import List

ENV_OVERRIDE = "POWERFOCUS_DATA_DIR"
APP_NAME = "PowerFocus"
VERSION_SLOT = "v0.10"

REPO_ROOT = Path(__file__).resolve().parent


def data_root() -> Path:
    """应用数据根目录（纯计算，不创建目录）。"""
    env = (os.environ.get(ENV_OVERRIDE) or "").strip()
    if env:
        return Path(env)
    if os.name == "nt":
        base = os.environ.get("LOCALAPPDATA") or str(Path.home() / "AppData" / "Local")
        return Path(base) / APP_NAME / VERSION_SLOT
    return Path.home() / ".local" / "share" / APP_NAME / VERSION_SLOT


def legacy_root() -> Path:
    """历史数据目录：源码版本目录（只读回退用，绝不写入）。"""
    return REPO_ROOT / "versions" / VERSION_SLOT


def ensure(path: Path) -> Path:
    """显式创建目录；只允许在写入路径上调用。"""
    path.mkdir(parents=True, exist_ok=True)
    return path


def write_path(rel: str) -> Path:
    """写目标：永远落在新的数据目录，并创建父目录。"""
    p = data_root() / rel
    ensure(p.parent)
    return p


def first_existing(rel: str) -> Path:
    """读单个文件：新目录优先，历史目录回退；都不存在时返回新目录路径。"""
    new = data_root() / rel
    if new.exists():
        return new
    old = legacy_root() / rel
    if old.exists():
        return old
    return new


def existing_dirs(rel: str) -> List[Path]:
    """读目录列表：合并新目录与历史目录（去重）；都不存在时返回新目录。"""
    out: List[Path] = []
    for base in (data_root(), legacy_root()):
        d = base / rel
        if d.is_dir() and d not in out:
            out.append(d)
    return out or [data_root() / rel]


def describe() -> dict:
    """给自检报告/前端展示用，不产生任何副作用。"""
    return {
        "data_root": str(data_root()),
        "legacy_root": str(legacy_root()),
        "legacy_in_use": legacy_root().is_dir(),
        "env_override": ENV_OVERRIDE,
        "writes_to_program_dir": False,
        "policy": "写一律走 data_root；读优先 data_root，历史目录只读回退，不自动搬迁",
    }
