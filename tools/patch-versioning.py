# -*- coding: utf-8 -*-
"""VERSIONING.md 补 v0.12 一行 + 更新内核指针说明。"""
from pathlib import Path
import sys

V = Path(r"E:\PowerFocus\versions\VERSIONING.md")
raw = V.read_bytes()
bom = raw.startswith(b"\xef\xbb\xbf")
t = raw.decode("utf-8-sig")

# 1) 版本表：v0.11 那行之后插入 v0.12
old_row = "| v0.11 | `versions\\v0.11\\` | dev | v0.10 派生，统一对接基线：安全引擎路线确立（ClamAV 为主体）、版本规范补齐（工具支持 `.py` 与 `prototype`。**不含 engines**，运行时引擎走 `app_paths.data_root()`） |"
new_rows = ("| v0.11 | `versions\\v0.11\\` | stable | v0.10 派生，统一对接基线：安全引擎路线确立（ClamAV 为主体）、版本规范补齐"
            "（工具支持 `.py` 与 `prototype`）、统一内存接线、KV cache 判据修正、硬编码清理、白名单补给放行。"
            "**不含 engines**，运行时引擎走 `app_paths.data_root()`。2026-11-15 转 stable |\n"
            "| v0.12 | `versions\\v0.12\\` | stable | v0.11 派生，**进程价值判据重写**：按可见窗口分级（`protect`/`active`/`busy`/`visible`/`idle`），"
            "TCP 连接不再算\"在用\"；**清场永不杀进程**，改为优先级 + EcoQoS + 工作集换出，释放时完整还原。"
            "2026-11-15 转 stable，`current.json` 指向本版 |")

if old_row not in t:
    print("⚠ 未精确匹配 v0.11 行，尝试按前缀定位")
    for line in t.splitlines():
        if line.startswith("| v0.11 |"):
            old_row = line
            break

if old_row not in t:
    print("✗ 仍未找到 v0.11 表格行")
    sys.exit(1)
t = t.replace(old_row, new_rows, 1)
print("✓ 版本表已补 v0.12")

# 2) 指针说明
old_ptr = "内核版本指针：`versions\\current.json`（截至 2026-11-15 指向 `v0.09`）。"
new_ptr = "内核版本指针：`versions\\current.json`（截至 2026-11-15 指向 `v0.12`）。"
if old_ptr in t:
    t = t.replace(old_ptr, new_ptr, 1)
    print("✓ 指针说明已更新为 v0.12")
else:
    print("⚠ 指针说明未匹配，跳过")

# 3) 产品线表里的依赖
old_dep = "| v1.00 | `product\\v1.00\\` | ≥ v0.08 |"
new_dep = "| v1.00 | `product\\v1.00\\` | ≥ v0.12 |"
if old_dep in t:
    t = t.replace(old_dep, new_dep, 1)
    print("✓ 产品线依赖已更新为 ≥ v0.12")
else:
    print("⚠ 产品线依赖未匹配，跳过")

V.write_bytes((b"\xef\xbb\xbf" if bom else b"") + t.encode("utf-8"))
print("已写回")
