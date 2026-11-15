# -*- coding: utf-8 -*-
from pathlib import Path
V = Path(r"E:\PowerFocus\versions\VERSIONING.md")
raw = V.read_bytes(); bom = raw.startswith(b"\xef\xbb\xbf")
t = raw.decode("utf-8-sig")

anchor = "| v0.12 |"
line_idx = None
for i, line in enumerate(t.splitlines()):
    if line.startswith(anchor):
        line_idx = i
        break
if line_idx is None:
    print("✗ 未找到 v0.12 行"); raise SystemExit(1)

lines = t.splitlines()
row = ("| v0.13 | `versions\\v0.13\\` | stable | v0.12 派生，**配套应用声明机制**（`companion-apps.json`）："
       "用户声明「正在使用」的应用按父子链整组 protect 不压不杀。依据是 CPU/IO/TCP/窗口四个信号在本机实测全部判不准「在用」"
       "（QQ 聊天时 CPU 0.8%，IO 计数恒 0，TCP 挂着的也连，窗口只证明点开过）。"
       "实测覆盖 41 个 PID（QQ 24 + QQEX 5 + DSH 5 + 附属）。"
       "修 bug：`$pid` 是只读自动变量不能当循环变量。2026-11-15 转 stable，`current.json` 指向本版 |")
lines.insert(line_idx + 1, row)
t = "\n".join(lines) + ("\n" if t.endswith("\n") else "")
print("✓ 已插入 v0.13 行")

t = t.replace("（截至 2026-11-15 指向 `v0.12`）", "（截至 2026-11-15 指向 `v0.13`）", 1)
t = t.replace("| v1.00 | `product\\v1.00\\` | ≥ v0.12 |", "| v1.00 | `product\\v1.00\\` | ≥ v0.13 |", 1)
V.write_bytes((b"\xef\xbb\xbf" if bom else b"") + t.encode("utf-8"))
print("已写回")
