# -*- coding: utf-8 -*-
"""版本号单一真源（2026-11-26 工程化补齐）。

规则（docs/VERSION_POLICY.md）：**唯一对外版本号 = GitHub Release tag**；
`product/v1.00` 是代码目录槽，`versions/v0.13` 是内核迭代槽，都不是发布版本，
不得当作 tag 对外引用。

release_version() 取值优先级：
  1. 环境变量 ``PF_RELEASE_TAG``（发版 / 打包脚本显式注入）；
  2. 打包旁或源码旁的 ``VERSION.json``（``{"release": "v0.13.0"}``）；
  3. 源码运行：``git describe --tags --always``（拿不到则回退）；
  4. ``"dev"``（开发态标识，不是发布号）。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

# 代码目录槽（内部标识，非发布版本号）。与 app_paths.DATA_SLOT 刻意解耦。
SLOT = "v1.00"

REPO_OWNER = "yang-yi-star"
REPO_NAME = "PowerFocus"

_DEV = "dev"


def _version_json_path() -> Path | None:
    """打包后看 exe 旁 VERSION.json；源码运行看 app/VERSION.json。"""
    if getattr(sys, "frozen", False):
        p = Path(sys.executable).resolve().parent / "VERSION.json"
    else:
        p = Path(__file__).resolve().parent / "VERSION.json"
    return p if p.exists() else None


def _repo_root() -> Path:
    # version.py 位于 product/v1.00/app/，仓库根向上三层
    return Path(__file__).resolve().parents[3]


def _git_describe() -> str:
    try:
        out = subprocess.run(
            ["git", "describe", "--tags", "--always", "--dirty"],
            capture_output=True, text=True, timeout=3, cwd=str(_repo_root()),
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return ""


def release_version() -> str:
    """对外发布版本号；开发态回退 ``dev``，不臆造 tag。"""
    env = (os.environ.get("PF_RELEASE_TAG") or "").strip()
    if env:
        return env
    p = _version_json_path()
    if p is not None:
        try:
            v = str(json.loads(p.read_text(encoding="utf-8-sig")).get("release") or "").strip()
            if v:
                return v
        except Exception:
            pass
    g = _git_describe()
    return g or _DEV


def repo_url() -> str:
    return "https://github.com/%s/%s" % (REPO_OWNER, REPO_NAME)


def issues_url() -> str:
    return repo_url() + "/issues"


def releases_url() -> str:
    return repo_url() + "/releases"
