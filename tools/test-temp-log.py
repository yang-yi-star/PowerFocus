# -*- coding: utf-8 -*-
"""temp_log 模块自检：采两条样本、打印当前与峰值、确认日志文件真的写进去了。"""
import os
import sys
import time
from pathlib import Path

APP = r"E:\PowerFocus\product\v1.00\app"
sys.path.insert(0, APP)

import temp_log  # noqa: E402

def show(rec):
    if not rec:
        print("  采样失败")
        return
    cpu = rec.get("cpu") or {}
    gpu = rec.get("gpu") or {}
    dimm = rec.get("dimm") or {}
    print("  ts:", rec.get("ts"), "| source:", rec.get("source"))
    print("  CPU:", {k: round(v, 1) for k, v in cpu.items()})
    print("  GPU:", {k: round(v, 1) for k, v in gpu.items()})
    print("  DIMM:", {k: round(v, 1) for k, v in dimm.items()})
    if rec.get("source_error"):
        print("  source_error:", rec["source_error"])

print("[1] 第一条")
show(temp_log.sample())
time.sleep(6)
print("[2] 第二条（6 秒后，验证温度会变化而不是死值）")
show(temp_log.sample())

print("[3] current()")
st = temp_log.current()
for k in ("ok", "samples", "source", "lhm_available", "lhm_error", "log_dir", "log_file", "last_error"):
    print("  %-15s %s" % (k, st.get(k)))
print("  session_peak:", {k: (round(v['value'], 1), v['at']) for k, v in st["session_peak"].items()})
print("  history_peak:", {k: (round(v['value'], 1), v['at']) for k, v in st["history_peak"].items()})

print("[4] 日志文件核对")
fp = st.get("log_file")
if fp and Path(fp).exists():
    p = Path(fp)
    lines = p.read_text(encoding="utf-8").strip().splitlines()
    print("  文件:", p)
    print("  字节:", p.stat().st_size, "行数:", len(lines))
    print("  最后一行:", lines[-1][:220])
else:
    print("  FAIL 日志文件不存在:", fp)
