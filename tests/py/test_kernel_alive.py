# -*- coding: utf-8 -*-
"""13 号 / 47 号回归：内核判活 = 心跳新鲜度 + 内核进程存在性。

为什么要有这份测试：
    旧实现只有 `(time.time() - ts) < 15`，三类必错场景没有护栏——
      · 内核进程被杀、心跳文件还热着 → 最长 15 秒假活（前端以为一切正常）；
      · 系统时钟被 NTP 往回校，age 变负 → 负数小于 15 → 永久判活，内核再也拉不起来；
      · 与 main.py 各写一份逐字重复的实现，改一处漏一处就会分叉。

47 号补充（pid 字段容错）：
    心跳里的 pid 是**可选佐证**，不是唯一依据。缺字段 / null / 0 时按新鲜度判活，
    理由：宁可少判死，也绝不重复拉起第二个内核实例。
    但原实现里 `int(hb["pid"])` 抛异常会落到最外层 `except → False`，
    于是「pid 字段写坏」被当成「进程已死」——同一个不确定状态，两条相反结论。
    47 号把不可解析的 pid 归零（= 退回新鲜度），并在这里钉死行为表：
        pid 缺失 / null / 0 / 不可解析     → 只看新鲜度
        pid 可解析且 > 0                   → 还必须 psutil.pid_exists(pid)
    时间字段仍保持「不可解析即判死」：时间是判活的可信锚点，没有它就没有新鲜度可言，
    判活会变成永久假活（比判死危险得多）。两侧故意不对称，测试里各钉一条。

隔离原则：
    全部走 tmp_path，monkeypatch server.KERNEL_DIR，绝不触碰真实心跳文件；
    绝不启动、也绝不杀掉任何真实内核进程。
"""
import asyncio
import json
import os
import sys
import time
from pathlib import Path

import psutil
import pytest

ROOT = Path(__file__).resolve().parents[2]
APP_DIR = ROOT / "product" / "v1.00" / "app"
sys.path.insert(0, str(APP_DIR))
import server  # noqa: E402


# ---------------------------------------------------------------- 工具

_UNSET = object()


def _write_beat(root: Path, *, age_sec: float = 0.0, pid=_UNSET,
                drop_pid: bool = False, encoding: str = "utf-8") -> dict:
    """在 root 下写一份心跳；age_sec 为负数表示心跳时间在未来（模拟时钟后调）。"""
    stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - age_sec))
    hb = {"time": stamp, "tick": 42, "cmd_bus": True, "rules_running": 0, "busy": False}
    if not drop_pid:
        hb["pid"] = os.getpid() if pid is _UNSET else pid
    (root / "v3_heartbeat.json").write_text(json.dumps(hb), encoding=encoding)
    return hb


def _dead_pid() -> int:
    """找一个当前确实不存在的 pid（不 fork 进程、不碰任何真实进程）。"""
    for cand in (4_000_001, 4_000_002, 3_999_999, 999_998):
        if not psutil.pid_exists(cand):
            return cand
    pytest.skip("找不到可用作「已死」的 pid")


@pytest.fixture()
def hb_root(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "KERNEL_DIR", tmp_path)
    return tmp_path


# ---------------------------------------------------------------- 代码形态（红→绿开关）

def test_module_is_the_product_copy():
    """测的必须是产品版 server.py；被同名副本骗过去 = 假绿。"""
    mod = Path(server.__file__).resolve()
    assert APP_DIR.resolve() in mod.parents, f"import server 命中了 {mod}，不是产品版"
    assert hasattr(server, "kernel_alive_sync"), "缺少 server.kernel_alive_sync（13 号补丁未落地）"


def test_main_py_has_no_second_copy():
    """main.py 里不允许再出现第二份判活实现（有 mktime 就是又写了一遍）。"""
    src = (ROOT / "product" / "v1.00" / "app" / "main.py").read_text(encoding="utf-8")
    assert "mktime" not in src, "main.py 仍在自己算心跳时间，判活逻辑又分叉了"
    assert "server.kernel_alive_sync()" in src, "main.py 没有转发到唯一实现"


def test_server_py_old_expression_gone():
    src = (ROOT / "product" / "v1.00" / "app" / "server.py").read_text(encoding="utf-8")
    assert "return (time.time() - ts) < 15" not in src, "旧式无下界判定仍留在 server.py"


def test_async_wrapper_does_not_block():
    """判活读盘必须在线程池里跑（server.py 是 async，别堵事件循环）。"""
    src = (ROOT / "product" / "v1.00" / "app" / "server.py").read_text(encoding="utf-8")
    assert "asyncio.to_thread(kernel_alive_sync)" in src


# ---------------------------------------------------------------- 判活语义：新鲜度

def test_alive_when_heartbeat_fresh_and_pid_alive(hb_root):
    _write_beat(hb_root, age_sec=0)
    assert server.kernel_alive_sync() is True


def test_dead_when_heartbeat_stale(hb_root):
    _write_beat(hb_root, age_sec=60)
    assert server.kernel_alive_sync() is False


def test_dead_when_heartbeat_time_in_future(hb_root):
    """13 号核心修复点 2：时钟被后调，age 为负 → 必须判死，而不是恒活。"""
    _write_beat(hb_root, age_sec=-120)
    assert server.kernel_alive_sync() is False


def test_dead_when_heartbeat_missing(hb_root):
    assert not (hb_root / "v3_heartbeat.json").exists()
    assert server.kernel_alive_sync() is False


def test_dead_when_heartbeat_corrupt(hb_root):
    (hb_root / "v3_heartbeat.json").write_text("{不是 JSON", encoding="utf-8")
    assert server.kernel_alive_sync() is False


def test_dead_when_time_field_malformed(hb_root):
    """时间是可信锚点：不可解析就没有新鲜度可言，判死（与 pid 侧的宽容故意不对称）。"""
    (hb_root / "v3_heartbeat.json").write_text(
        json.dumps({"time": "not-a-time", "pid": os.getpid()}), encoding="utf-8"
    )
    assert server.kernel_alive_sync() is False


def test_reads_heartbeat_with_bom(hb_root):
    """PowerShell 的 Out-File/Set-Content 默认带 BOM，读侧必须吃 utf-8-sig。"""
    _write_beat(hb_root, age_sec=0, encoding="utf-8-sig")
    assert server.kernel_alive_sync() is True


# ---------------------------------------------------------------- 判活语义：进程存在性

def test_dead_when_heartbeat_fresh_but_pid_gone(hb_root):
    """13 号核心修复点 1：文件热着但进程没了，必须判死（旧实现这里会假活）。"""
    _write_beat(hb_root, age_sec=0, pid=_dead_pid())
    assert server.kernel_alive_sync() is False


def test_alive_when_pid_given_as_numeric_string(hb_root):
    """pid 可能是被字符串化的（ConvertTo-Json / 手写 / 旧内核），能解析就按数字用。"""
    _write_beat(hb_root, age_sec=0, pid=str(os.getpid()))
    assert server.kernel_alive_sync() is True


# ---------------------------------------------------------------- 47 号：pid 容错（不可解析 ≠ 已死）

def test_missing_pid_falls_back_to_freshness(hb_root):
    """心跳没 pid 时宁可相信文件新鲜，也绝不判定已死——否则会拉起第二个内核实例。"""
    _write_beat(hb_root, age_sec=0, drop_pid=True)
    assert server.kernel_alive_sync() is True


def test_null_pid_falls_back_to_freshness(hb_root):
    _write_beat(hb_root, age_sec=0, pid=None)
    assert server.kernel_alive_sync() is True


def test_zero_pid_falls_back_to_freshness(hb_root):
    _write_beat(hb_root, age_sec=0, pid=0)
    assert server.kernel_alive_sync() is True


@pytest.mark.parametrize("bad_pid", ["abc", "", {}, [], "12abc"])
def test_unparsable_pid_falls_back_to_freshness(hb_root, bad_pid):
    """47 号核心修复点：pid 写坏只是「没有佐证」，不是「进程已死」。

    改前非空且不可解析的值会走 int() 抛异常 → 最外层 except → False
    （判死 → 启动器可能再拉一个内核）；改后归零 → 只看新鲜度 → 新鲜时判活。
    """
    _write_beat(hb_root, age_sec=0, pid=bad_pid)
    assert server.kernel_alive_sync() is True


def test_unparsable_pid_still_dies_when_stale(hb_root):
    """容错不等于永久假活：坏 pid + 过期心跳，照样判死。"""
    _write_beat(hb_root, age_sec=60, pid="abc")
    assert server.kernel_alive_sync() is False


# ---------------------------------------------------------------- 双入口一致性

def test_async_wrapper_matches_sync(hb_root):
    """HTTP 侧（async）与启动器侧（sync）必须同结论，不能一个说活一个说死。"""
    _write_beat(hb_root, age_sec=0)
    assert asyncio.run(server.kernel_alive()) is server.kernel_alive_sync()
