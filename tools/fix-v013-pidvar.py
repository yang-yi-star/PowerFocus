# -*- coding: utf-8 -*-
"""修 v0.13：$pid 是 PowerShell 只读自动变量（当前进程 ID），
用作 foreach 循环变量会抛 "无法覆盖变量 PID" 异常，导致配套应用聚合整段失效。"""
from pathlib import Path
K = Path(r"E:\PowerFocus\versions\v0.13\电脑算力调度中心_v0.13.ps1")
raw = K.read_bytes(); bom = raw.startswith(b"\xef\xbb\xbf")
t = raw.decode("utf-8-sig")

old = """    foreach ($nm in $ctx.CompanionApps) {
        $want = $nm.ToLower()
        foreach ($pid in $ctx.NameMap.Keys) {
            $cur = $ctx.NameMap[$pid]
            if ($cur -and ($cur.ToLower() -eq $want -or $cur.ToLower() -eq ($want + '.exe'))) {
                # BFS 整棵子树
                $stack = @($pid)"""
new = """    foreach ($nm in $ctx.CompanionApps) {
        $want = $nm.ToLower()
        # 注意：循环变量不能叫 $pid —— 那是 PowerShell 只读自动变量（当前进程 ID），
        # 赋值会抛 "无法覆盖变量 PID"，整个聚合静默失效（2026-11-15 实测踩过）
        foreach ($cpid in $ctx.NameMap.Keys) {
            $cur = $ctx.NameMap[$cpid]
            if ($cur -and ($cur.ToLower() -eq $want -or $cur.ToLower() -eq ($want + '.exe'))) {
                # BFS 整棵子树
                $stack = @($cpid)"""

if old not in t:
    print("✗ 锚点未匹配")
    for i, line in enumerate(t.splitlines(), 1):
        if "foreach ($pid in $ctx.NameMap.Keys)" in line or "NameMap.Keys" in line:
            print(f"  L{i}: {line}")
    raise SystemExit(1)

t = t.replace(old, new, 1)
print("✓ 循环变量已改为 $cpid")

# 全文再查一遍是否还有 $pid 被当赋值目标
import re
hits = [(i, l) for i, l in enumerate(t.splitlines(), 1)
        if re.search(r'\$pid\s*=', l, re.I) or re.search(r'foreach\s*\(\s*\$pid\s+in', l, re.I)]
if hits:
    print("⚠ 仍有 $pid 赋值目标：")
    for i, l in hits:
        print(f"  L{i}: {l.strip()}")
else:
    print("✓ 全文已无对 $pid 的赋值")

K.write_bytes((b"\xef\xbb\xbf" if bom else b"") + t.encode("utf-8"))
print("已写回，行数 =", len(t.splitlines()))
