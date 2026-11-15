# -*- coding: utf-8 -*-
"""v0.13 转 stable：MANIFEST / current.json / product MANIFEST，全部去 BOM"""
from pathlib import Path
import json, datetime, shutil, sys

STAMP = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
REPO = Path(r"E:\PowerFocus")
V13 = REPO / "versions" / "v0.13"
CUR = REPO / "versions" / "current.json"
PROD = REPO / "product" / "v1.00" / "MANIFEST.json"

def write_json_nobom(path: Path, obj):
    txt = json.dumps(obj, ensure_ascii=False, indent=2)
    path.write_bytes(txt.encode("utf-8"))

def backup(path: Path, tag: str):
    b = path.with_suffix(path.suffix + f".bak-{STAMP}-{tag}")
    shutil.copy2(path, b)
    print(f"  备份 -> {b.name}")

# 1) v0.13 MANIFEST
mf = V13 / "MANIFEST.json"
d = json.loads(mf.read_text(encoding="utf-8-sig"))
backup(mf, "stable")
d["stage"] = "stable"
d["note"] = ("v0.13 转正式版：配套应用声明机制（companion-apps.json）。"
             "用户声明「正在使用」的应用整组不压不杀——依据是这台机器上 CPU/IO/TCP/窗口四个信号都判不准「在用」："
             "QQ 收发消息时 CPU 仅 0.8%；Get-Process 的 IO 字段为空、Get-Counter 恒 0；"
             "TCP 只能证明「连着」（QQ 连腾讯、Edge 连 CDN 都连着）；窗口只能证明「点开过」（QQ 最小化照样收发）。"
             "所以「在用」必须由用户声明。清单内 QQ(24进程)/QQEX(5)/DSH(5) 共 41 个 PID 按父子链整组 protect。"
             "修 bug：foreach 循环变量不能叫 $pid（PowerShell 只读自动变量，赋值抛异常导致聚合静默失效）。")
d["updated"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
write_json_nobom(mf, d)
print(f"✓ v0.13 stage = {d['stage']}")

# 2) current.json
cd = json.loads(CUR.read_text(encoding="utf-8-sig"))
backup(CUR, "stable")
cd["version"] = "v0.13"
cd["updated"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
write_json_nobom(CUR, cd)
print(f"✓ current.json = {cd['version']}")

# 3) product MANIFEST
pd = json.loads(PROD.read_text(encoding="utf-8-sig"))
backup(PROD, "kernel13")
pd["kernel_version"] = "v0.13"
pd["kernel_required"] = ">= v0.13"
write_json_nobom(PROD, pd)
print(f"✓ product kernel_version = {pd['kernel_version']} / required = {pd['kernel_required']}")

# 4) 校验无 BOM
for p in (mf, CUR, PROD):
    raw = p.read_bytes()
    print(f"  {p.name}: BOM={raw.startswith(b'\xef\xbb\xbf')}, 可解析={bool(json.loads(raw.decode('utf-8')))}")
