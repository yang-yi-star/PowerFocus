# -*- coding: utf-8 -*-
"""把 v0.12 内核的分级函数与清场处理段按行范围重写，保持 UTF-8 BOM。"""
from pathlib import Path
import io, sys

K = Path(r"E:\PowerFocus\versions\v0.12\电脑算力调度中心_v0.12.ps1")
raw = K.read_bytes()
bom = raw.startswith(b"\xef\xbb\xbf")
text = raw.decode("utf-8-sig")
lines = text.splitlines(keepends=True)

def find_func(name):
    for i, ln in enumerate(lines):
        if ln.startswith(f"function {name} {{"):
            return i
    return -1

def func_end(start):
    """从函数起始行往下找第一个顶格 '}'"""
    for j in range(start + 1, len(lines)):
        if lines[j].rstrip("\r\n") == "}":
            return j
    return -1

RANK_NEW = '''function Get-ProcessValueRank {
    # 价值分级（2026-11-15 修正。用户口径：判断"用没用"直接看后台窗口，不看进程自身指标）
    #   protect = 点名保留 / 系统关键 / 自身 / Windows 服务（不压不杀，完全不碰）
    #   active  = 前台窗口所属进程（用户此刻正操作，完全不碰）
    #   busy    = 无窗口但确实在干活（CPU 忙 / 有活跃或监听连接）→ 不动
    #             这是唯一还用"忙"做判据的一档，因为它在真花算力，压了会伤
    #   visible = 有可见窗口（含最小化），或属于某可见窗口应用的子进程
    #             → 用户点开过、可能存着没保存的工作 → 降优先级，绝不杀
    #             （"开着窗口但没点开用"的应用正是这一档：算力要收走，进程要留着）
    #   idle    = 无窗口 + 不忙 + 无连接 + 不属于任何可见窗口应用
    #             → 明显的闲置后台 → 降优先级 + EcoQoS + 修剪工作集，绝不杀
    #
    # 铁律（2026-11-15 用户明确）：清场永远不杀进程。
    # 杀只在用户显式发 kill_process 时才发生。用户原话是「给其他应用最小的空间」，
    # 不是"杀掉其他应用"；杀进程会丢未保存状态，而"最小空间"靠
    # 优先级 + EcoQoS + 工作集换出 就能做到。
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
    if ($BusySet.ContainsKey($id)) { return 'busy' }     # CPU 真在动 = 干活，压了会伤
    if ($TcpSet.ContainsKey($id)) { return 'busy' }      # 在通信/提供服务 = 干活
    if ($Process.MainWindowHandle -ne 0) { return 'visible' }
    if ($WinIds.ContainsKey($id)) { return 'visible' }   # 最小化窗口：MainWindowHandle 可能为 0，用可见窗口集合兜住
    if (Test-WindowedAncestor $id $PpidMap $WinIds) { return 'visible' }  # 同属一个可见应用（渲染/GPU/子进程），按同组处理
    return 'idle'
}
'''

start = find_func("Get-ProcessValueRank")
end = func_end(start)
print(f"Get-ProcessValueRank 定位: L{start+1} - L{end+1}")
if start < 0 or end < 0:
    sys.exit(1)
lines[start:end+1] = RANK_NEW.splitlines(keepends=True)

# 重新定位清场处理段并替换
text2 = "".join(lines)
lines = text2.splitlines(keepends=True)

marker_start = None
for i, ln in enumerate(lines):
    if "清场：价值分级" in ln:
        marker_start = i
        break
if marker_start is None:
    print("✗ 未找到清场处理段注释行")
    sys.exit(1)

# 结束标记：$script:PowerKilled = $killed
marker_end = None
for j in range(marker_start, len(lines)):
    if "$script:PowerKilled = $killed" in lines[j]:
        marker_end = j
        break
print(f"清场处理段定位: L{marker_start+1} - L{marker_end+1}")

PURGE_NEW = '''    # 清场：价值分级 → 分级处理
    #   protect / active / busy → 完全不碰
    #   visible → 降优先级（开着但没在用，算力收走；进程留着，不丢工作进度）
    #   idle    → 降优先级 + EcoQoS 效率模式 + 修剪工作集
    # 永不 Stop-Process：这里一条杀进程的语句都不该有。
    $procs = Get-Process -ErrorAction SilentlyContinue
    $demoted = 0
    $ecoOn = 0
    $trimmed = 0
    $visibleCount = 0
    $idleCount = 0
    $hasEco = [bool](Get-Command Set-EcoQos -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        if ($p.Id -eq $PID) { continue }
        if ($p.Id -eq $TargetPid) { continue }
        $rank = Get-ProcessValueRank -Process $p -FgPid $fgPid -DsTree $dsTree -AuthNames $authNames -NeverPress $neverPress -SysNames $sysNames -SvcPids $svcPids -BusySet $busySet -TcpSet $tcpSet -PpidMap $ppidMap -WinIds $winIds
        if ($rank -in @('protect','active','busy')) { continue }

        if ($rank -eq 'visible') { $visibleCount++ } else { $idleCount++ }

        # 第一步：降优先级（记原值，Restore-PowerSupply 会写回）
        try {
            $cur = [string]$p.PriorityClass
            if ($cur -notin @('Idle','BelowNormal')) {
                $target = if ($Level -eq 'aggressive' -or $Level -eq 'godmode') { 'Idle' } else { 'BelowNormal' }
                $p.PriorityClass = $target
                $script:PowerDemoted[$p.Id] = $cur
                $demoted++
            }
        } catch {}   # 系统进程/受保护进程改不动，静默跳过

        # 第二步：只对完全闲置的进程开 EcoQoS 效率模式（限制到能效核频率档）
        if ($rank -eq 'idle' -and $hasEco) {
            try {
                if (Set-EcoQos -ProcId $p.Id -On $true) {
                    $script:PowerEcoQos += $p.Id
                    $ecoOn++
                }
            } catch {}
        }

        # 第三步：只对完全闲置的进程修剪工作集，把物理页换出去
        if ($rank -eq 'idle') {
            try {
                if ([PowerFocus.Native]::EmptyWorkingSet($p.Handle)) { $trimmed++ }
            } catch {}
        }
    }
    $script:PowerKilled = @()
'''

lines[marker_start:marker_end+1] = PURGE_NEW.splitlines(keepends=True)

out = "".join(lines)
if bom:
    K.write_bytes(b"\xef\xbb\xbf" + out.encode("utf-8"))
else:
    K.write_bytes(out.encode("utf-8"))

print("已写回，BOM =", bom)
print("新行数 =", len(out.splitlines()))
