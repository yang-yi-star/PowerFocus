# -*- coding: utf-8 -*-
"""重写分级：TCP 不再算"在用"，有窗口一律可压；保留 CPU 真忙就不压。"""
from pathlib import Path
import sys

K = Path(r"E:\PowerFocus\versions\v0.12\电脑算力调度中心_v0.12.ps1")
raw = K.read_bytes()
bom = raw.startswith(b"\xef\xbb\xbf")
text = raw.decode("utf-8-sig")

start_marker = "function Get-ProcessValueRank {"
end_marker = "\n}\n"

i = text.index(start_marker)
j = text.index(end_marker, i) + len(end_marker)

NEW = '''function Get-ProcessValueRank {
    # 价值分级（2026-11-15 修正。用户口径：判断"用没用"就看后台窗口，不看进程自身指标）
    #
    #   protect = 点名保留 / 系统关键 / 自身 / Windows 服务（不压不杀，完全不碰）
    #   active  = 前台窗口所属进程（用户此刻正操作，完全不碰）
    #   busy    = CPU 真的在动（在导出/训练/编译/渲染这类真花算力的活）→ 不动，压了会拖慢
    #   visible = 有可见窗口（含最小化），或属于某可见窗口应用的子进程
    #             → 用户点开过、可能存着没保存的工作 → 降优先级，绝不杀
    #             （"开着但没点开用"的应用就是这一档：算力收走，进程留着）
    #   idle    = 无窗口 + CPU 不忙 + 不属于任何可见窗口应用
    #             → 明显的闲置后台 → 降优先级 + EcoQoS + 修剪工作集，绝不杀
    #
    # 关键修正（2026-11-15 实测后）：**TCP 连接不算"在用"**。
    #   旧判据把"有 Established/Listen 连接"当作在干活，结果 QQ、剪映、WorkBuddy、
    #   Edge 这些只是"挂在后台连着服务器"的应用全被判 busy → 完全不动，等于没清场。
    #   用户原话：「其他的基本都没点开」。挂着连接 ≠ 在用。
    #   现在只有 CPU 真在动才算 busy；TCP 只用于 list_junk 展示，不参与分级。
    #
    # 铁律：清场永远不杀进程。杀只在用户显式发 kill_process 时才发生。
    #   用户原话是「给其他应用最小的空间」，不是"杀掉其他应用"；杀进程会丢未保存状态，
    #   而"最小空间"靠 优先级 + EcoQoS + 工作集换出 就够。
    param($Process, $FgPid, $DsTree, $AuthNames, $NeverPress, $SysNames, $SvcPids, $BusySet, $TcpSet, $PpidMap, $WinIds)
    $id = [int]$Process.Id
    $name = [string]$Process.ProcessName
    if ($id -eq $PID) { return 'protect' }
    if ($DsTree.ContainsKey($id)) { return 'protect' }
    if ($name -in $NeverPress) { return 'protect' }
    if ($name -in $AuthNames) { return 'protect' }
    if ($name -in $SysNames) { return 'protect' }
    if ($SvcPids.ContainsKey($id)) { return 'protect' }   # Windows 服务进程：绝对不杀，也不压
    if ($FgPid -and $id -eq $FgPid) { return 'active' }
    # CPU 真在动 = 在干活。这一档无论有没有窗口都不压，否则会拖慢用户正在跑的导出/训练。
    if ($BusySet.ContainsKey($id)) { return 'busy' }
    # 以下才是"可以用算力收走"的范围
    if ($Process.MainWindowHandle -ne 0) { return 'visible' }
    if ($WinIds.ContainsKey($id)) { return 'visible' }    # 最小化窗口：MainWindowHandle 可能为 0，用可见窗口集合兜住
    if (Test-WindowedAncestor $id $PpidMap $WinIds) { return 'visible' }  # 同属一个可见应用（渲染/GPU 子进程），按同组处理
    return 'idle'
}
'''

text = text[:i] + NEW + text[j:]

if bom:
    K.write_bytes(b"\xef\xbb\xbf" + text.encode("utf-8"))
else:
    K.write_bytes(text.encode("utf-8"))
print("✓ 分级函数已重写")
print("新行数 =", len(text.splitlines()))
