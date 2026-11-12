# -*- coding: utf-8 -*-
"""app_paths 数据目录策略测试。

覆盖：默认数据根解析（Windows LOCALAPPDATA）/ POWERFOCUS_DATA_DIR 覆盖 /
      first_existing 新目录优先与历史目录回退 / 两处都无时的行为 /
      existing_dirs 合并去重 / data_root 纯计算不创建目录。

隔离原则：所有环境变量走 monkeypatch，所有磁盘写入走 tmp_path，
         绝不触碰真实 %LOCALAPPDATA%。legacy_root 通过 monkeypatch
         替换模块级 REPO_ROOT 指向临时目录。
"""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

import app_paths  # noqa: E402


# ---------------- 默认数据根解析 ----------------

def test_default_data_root_uses_localappdata(monkeypatch, tmp_path):
    """无环境变量覆盖时，Windows 下根 = %LOCALAPPDATA%\\PowerFocus\\v0.10。"""
    monkeypatch.delenv(app_paths.ENV_OVERRIDE, raising=False)
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "la"))
    root = app_paths.data_root()
    if os.name == "nt":
        assert root == tmp_path / "la" / "PowerFocus" / "v0.10"
    else:
        assert root == Path.home() / ".local" / "share" / "PowerFocus" / "v0.10"


def test_default_data_root_falls_back_when_localappdata_missing(monkeypatch):
    """LOCALAPPDATA 未定义时按 WACK 约定回退到用户 AppData\\Local。"""
    monkeypatch.delenv(app_paths.ENV_OVERRIDE, raising=False)
    monkeypatch.delenv("LOCALAPPDATA", raising=False)
    root = app_paths.data_root()
    if os.name == "nt":
        assert root == Path.home() / "AppData" / "Local" / "PowerFocus" / "v0.10"


def test_env_override_wins(monkeypatch, tmp_path):
    """POWERFOCUS_DATA_DIR 覆盖优先级最高，且不拼接 APP_NAME/版本槽。"""
    override = tmp_path / "portable-data"
    monkeypatch.setenv(app_paths.ENV_OVERRIDE, str(override))
    assert app_paths.data_root() == override


def test_env_override_blank_is_ignored(monkeypatch, tmp_path):
    """空串/纯空格的覆盖视为未设置，回落默认解析。"""
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "la"))
    monkeypatch.setenv(app_paths.ENV_OVERRIDE, "   ")
    root = app_paths.data_root()
    assert root == tmp_path / "la" / "PowerFocus" / "v0.10"


def test_data_root_is_pure_computation(monkeypatch, tmp_path):
    """data_root 只算不建：调用后目录不得被创建（启动自检保持只读）。"""
    override = tmp_path / "never-created" / "deep"
    monkeypatch.setenv(app_paths.ENV_OVERRIDE, str(override))
    assert app_paths.data_root() == override
    assert not override.exists()


# ---------------- first_existing ----------------

def test_first_existing_prefers_new_dir(monkeypatch, tmp_path):
    """新目录已有该文件：直接返回新目录路径，不碰历史目录。"""
    monkeypatch.setenv(app_paths.ENV_OVERRIDE, str(tmp_path / "new"))
    new_root = tmp_path / "new"
    rel = "reports/a.json"
    f = new_root / rel
    f.parent.mkdir(parents=True)
    f.write_text("{}", encoding="utf-8")
    assert app_paths.first_existing(rel) == f


def test_first_existing_falls_back_to_legacy(monkeypatch, tmp_path):
    """新目录没有、历史目录有：只读回退到历史目录。"""
    monkeypatch.setenv(app_paths.ENV_OVERRIDE, str(tmp_path / "new"))
    monkeypatch.setattr(app_paths, "REPO_ROOT", tmp_path / "fake-repo")
    legacy = tmp_path / "fake-repo" / "versions" / app_paths.VERSION_SLOT
    rel = "scan_settings.json"
    f = legacy / rel
    f.parent.mkdir(parents=True)
    f.write_text("{}", encoding="utf-8")
    got = app_paths.first_existing(rel)
    assert got == f
    assert tmp_path / "new" not in got.parents  # 未在新目录里创建任何东西


def test_first_existing_returns_new_path_when_both_missing(monkeypatch, tmp_path):
    """两处都无：返回新目录路径（写目标落点），不抛异常。"""
    monkeypatch.setenv(app_paths.ENV_OVERRIDE, str(tmp_path / "new"))
    monkeypatch.setattr(app_paths, "REPO_ROOT", tmp_path / "fake-repo")
    rel = "missing.json"
    assert app_paths.first_existing(rel) == tmp_path / "new" / rel


# ---------------- existing_dirs ----------------

def test_existing_dirs_merges_and_dedups(monkeypatch, tmp_path):
    """新目录与历史目录都存在时按顺序合并；同一目录不重复。"""
    monkeypatch.setenv(app_paths.ENV_OVERRIDE, str(tmp_path / "new"))
    monkeypatch.setattr(app_paths, "REPO_ROOT", tmp_path / "fake-repo")
    for base in (tmp_path / "new", tmp_path / "fake-repo" / "versions" / app_paths.VERSION_SLOT):
        (base / "engines").mkdir(parents=True)
    got = app_paths.existing_dirs("engines")
    assert got == [tmp_path / "new" / "engines",
                   tmp_path / "fake-repo" / "versions" / app_paths.VERSION_SLOT / "engines"]


def test_existing_dirs_returns_new_dir_when_none_exists(monkeypatch, tmp_path):
    """两处都不存在：返回新目录路径作为唯一候选。"""
    monkeypatch.setenv(app_paths.ENV_OVERRIDE, str(tmp_path / "new"))
    monkeypatch.setattr(app_paths, "REPO_ROOT", tmp_path / "fake-repo")
    assert app_paths.existing_dirs("engines") == [tmp_path / "new" / "engines"]


# ---------------- write / ensure ----------------

def test_write_path_creates_parent_under_data_root(monkeypatch, tmp_path):
    """write_path 落点必须在新数据根下，并显式创建父目录。"""
    monkeypatch.setenv(app_paths.ENV_OVERRIDE, str(tmp_path / "new"))
    p = app_paths.write_path("reports/sub/a.json")
    assert p == tmp_path / "new" / "reports" / "sub" / "a.json"
    assert p.parent.is_dir()


def test_describe_reflects_policy(monkeypatch, tmp_path):
    """describe() 给自检报告用：无副作用，字段与策略一致。"""
    monkeypatch.setenv(app_paths.ENV_OVERRIDE, str(tmp_path / "new"))
    d = app_paths.describe()
    assert d["env_override"] == app_paths.ENV_OVERRIDE
    assert d["writes_to_program_dir"] is False
    assert Path(d["data_root"]) == app_paths.data_root()


# ---------------- legacy_root：POWERFOCUS_ROOT 覆盖与 frozen 探测 ----------------
# 背景：2026-11-13 实测 frozen onefile 下 __file__ 指向 _MEI 临时目录，
# REPO_ROOT 失真导致 KVRT 引擎历史目录回退失效（exe 内误报缺失）。

def _clear_root_env(monkeypatch):
    monkeypatch.delenv(app_paths.ENV_ROOT_OVERRIDE, raising=False)
    monkeypatch.setattr(sys, "frozen", False, raising=False)


def test_powerfocus_root_env_overrides_legacy(monkeypatch, tmp_path):
    """POWERFOCUS_ROOT 显式指定仓库根时优先级最高（含源码运行）。"""
    _clear_root_env(monkeypatch)
    monkeypatch.setattr(app_paths, "REPO_ROOT", tmp_path / "fake-repo")
    monkeypatch.setenv(app_paths.ENV_ROOT_OVERRIDE, str(tmp_path / "explicit-root"))
    assert app_paths.legacy_root() == tmp_path / "explicit-root" / "versions" / app_paths.VERSION_SLOT


def test_powerfocus_root_blank_is_ignored(monkeypatch, tmp_path):
    """空串/纯空格的 POWERFOCUS_ROOT 视为未设置，回落默认解析。"""
    _clear_root_env(monkeypatch)
    monkeypatch.setattr(app_paths, "REPO_ROOT", tmp_path / "fake-repo")
    monkeypatch.setenv(app_paths.ENV_ROOT_OVERRIDE, "   ")
    assert app_paths.legacy_root() == tmp_path / "fake-repo" / "versions" / app_paths.VERSION_SLOT


def test_frozen_detection_finds_versions_ancestor(monkeypatch, tmp_path):
    """frozen 下从 sys.executable 向上逐级找含 versions/<slot> 的祖先。"""
    _clear_root_env(monkeypatch)
    repo = tmp_path / "deploy" / "repo"
    (repo / "versions" / app_paths.VERSION_SLOT).mkdir(parents=True)
    exe_dir = tmp_path / "deploy" / "repo" / "product" / "v1.00" / "dist"
    exe_dir.mkdir(parents=True)
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", str(exe_dir / "app.exe"))
    assert app_paths.legacy_root() == repo / "versions" / app_paths.VERSION_SLOT


def test_frozen_without_ancestor_keeps_old_behavior(monkeypatch, tmp_path):
    """frozen 但祖先里没有 versions/<slot>：回落 REPO_ROOT（旧行为，回退自然失效）。"""
    _clear_root_env(monkeypatch)
    fake_repo = tmp_path / "fake-repo"
    monkeypatch.setattr(app_paths, "REPO_ROOT", fake_repo)
    exe_dir = tmp_path / "standalone" / "bin"
    exe_dir.mkdir(parents=True)
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", str(exe_dir / "app.exe"))
    assert app_paths.legacy_root() == fake_repo / "versions" / app_paths.VERSION_SLOT


def test_not_frozen_is_unaffected_by_frozen_logic(monkeypatch, tmp_path):
    """非 frozen（源码运行）行为零变化：不触发向上探测，直接用 REPO_ROOT。"""
    _clear_root_env(monkeypatch)
    monkeypatch.setattr(app_paths, "REPO_ROOT", tmp_path / "fake-repo")
    # 即使 exe 路径附近恰好有 versions/<slot>，非 frozen 也不采用
    stray = tmp_path / "stray" / "versions" / app_paths.VERSION_SLOT
    stray.mkdir(parents=True)
    monkeypatch.setattr(sys, "executable", str(tmp_path / "stray" / "app.exe"))
    assert app_paths.legacy_root() == tmp_path / "fake-repo" / "versions" / app_paths.VERSION_SLOT
