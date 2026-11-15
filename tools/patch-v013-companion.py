# -*- coding: utf-8 -*-
"""v0.13：加配套应用（companion）机制
1. Get-ProcessContext 里加载 companion-apps.json，按父子链把整组 PID 聚合进 CompanionPids
2. Get-ProcessValueRank 增加 CompanionPids 参数，命中即 protect
3. Invoke-PowerSupply 调用处传参
"""
from pathlib import Path
import sys, re

K = Path(r"E:\PowerFocus\versions\v0.13\电脑算力调度中心_v0.13.ps1")
raw = K.read_bytes()
bom = raw.startswith(b"\xef\xbb\xbf")
t = raw.decode("utf-8-sig")

# ---------- 1) 重写 Get-ProcessContext ----------
start = t.index("function Get-ProcessContext {")
end = t.index("\n}\n", start) + len("\n}\n")

CTX = '''function Get-ProcessContext {
    # 一次性采集价值判断所需全部上下文（补给清场 / list_junk 共用，避免判定逻辑漂移）
    $ctx = @{}
    $ctx.FgPid = Get-ForegroundPid
    $ctx.DsTree = Get-DeepSeekTreePids
    $ctx.AuthNames = @()
    try { $auth = Get-Content -Raw -LiteralPath $script:AuthFile -Encoding utf8 | ConvertFrom-Json; $ctx.AuthNames = @($auth.apps.name) } catch {}
    $ctx.NeverPress = @('DoubaoWork','msedgewebview2','wetype','wetype_renderer','ChsIME','ctfmon','SearchHost')
    $ctx.SysNames = $script:Whitelist + @(
        'System','Registry','Memory Compression','csrss','dwm','winlogon','lsass','services','svchost',
        'fontdrvhost','conhost','smss','wininit','spoolsv','audiodg','WmiPrvSE','MsMpEng','NisSrv',
        'SearchHost','ShellExperienceHost','RuntimeBroker','sihost','taskhostw','ApplicationFrameHost',
        'SecurityHealthService','TextInputHost','StartMenuExperienceHost','explorer','Taskmgr','ctfmon',
        'wetype','ChsIME','msedgewebview2',
        'LsaIso','Secure System','WUDFHost','WmiApSrv','wlanext','NgcIso','nvcontainer','NVDisplay.Container',
        'atieclxx','atiesrxx','SearchFilterHost','SearchProtocolHost','WebExperienceHostApp','ShellHost',
        'smartscreen','UserOOBEBroker','AggregatorHost','dllhost','unsecapp','tailscaled','cncmd',
        'OpenConsole','RadeonSoftware')
    $ctx.SvcPids = @{}
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -gt 0 -and $_.State -eq 'Running' } |
        ForEach-Object { $ctx.SvcPids[[int]$_.ProcessId] = $true }
    $ctx.BusySet = Get-BusyPidSet
    $ctx.TcpSet  = Get-TCPActivePids

    # 一次 Win32_Process 查询同时拿到 父子关系 + 进程名，避免查两遍
    $ctx.PpidMap = @{}
    $ctx.NameMap = @{}
    $childrenOf = @{}
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
        $cid = [int]$_.ProcessId; $ppid = [int]$_.ParentProcessId
        $ctx.PpidMap[$cid] = $ppid
        $ctx.NameMap[$cid] = [string]$_.Name
        if (-not $childrenOf.ContainsKey($ppid)) { $childrenOf[$ppid] = @() }
        $childrenOf[$ppid] += $cid
    }

    # 配套应用（用户声明正在使用）：按父子链聚合整组 PID
    # 依据：这台机器上 CPU/IO/TCP/窗口四个信号都判不准"在用"——
    #   QQ 聊天时 CPU 仅 0.8%；Get-Process 的 IO 字段为空、Get-Counter 恒 0；
    #   TCP 只能证明"连着"（QQ 连腾讯、Edge 连 CDN 都连着）；
    #   窗口只能证明"点开过"（QQ 最小化照样在收发）。
    # 所以"在用"只能由用户声明，写在 companion-apps.json。
    $ctx.CompanionApps = @()
    $ctx.CompanionPids = @{}
    if (Test-Path -LiteralPath $script:CompanionFile) {
        try {
            $cj = Get-Content -LiteralPath $script:CompanionFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $ctx.CompanionApps = @($cj.apps | ForEach-Object { [string]$_.name })
        } catch { Write-Log "WARN" "companion-apps.json 解析失败: $_" }
    } else {
        # 文件缺失时兜底：至少保住消息通道，不要让用户以为在跑全机清场
        $ctx.CompanionApps = @('QQ', 'QQEX', 'DeepSeek Harness')
    }
    foreach ($nm in $ctx.CompanionApps) {
        $want = $nm.ToLower()
        foreach ($pid in $ctx.NameMap.Keys) {
            $cur = $ctx.NameMap[$pid]
            if ($cur -and ($cur.ToLower() -eq $want -or $cur.ToLower() -eq ($want + '.exe'))) {
                # BFS 整棵子树
                $stack = @($pid)
                while ($stack.Count -gt 0) {
                    $x = $stack[0]
                    if ($stack.Count -gt 1) { $stack = $stack[1..($stack.Count-1)] } else { $stack = @() }
                    if ($ctx.CompanionPids.ContainsKey($x)) { continue }
                    $ctx.CompanionPids[$x] = $true
                    if ($childrenOf.ContainsKey($x)) { foreach ($c in $childrenOf[$x]) { $stack += $c } }
                }
            }
        }
    }

    $ctx.WinIds = @{}
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { $ctx.WinIds[[int]$_.Id] = $true }
    return $ctx
}
'''
t = t[:start] + CTX + t[end:]
print("1) Get-ProcessContext 已重写（含 CompanionPids 聚合）")

# ---------- 2) 判据加 CompanionPids ----------
rank_start = t.index("function Get-ProcessValueRank {")
rank_end = t.index("\n}\n", rank_start) + len("\n}\n")

RANK = '''function Get-ProcessValueRank {
    # 价值分级（2026-11-15 修正。用户口径：判断"用没用"就看后台窗口 + 用户声明的配套应用）
    #
    #   protect   = 配套应用组 / 自身 / 系统关键 / 白名单 / 授权 / Windows 服务 / DeepSeek
    #               （完全不动）
    #   active    = 前台窗口所属进程（用户此刻正操作，完全不碰）
    #   busy      = CPU 真的在动（导出/训练/编译/渲染）→ 不动，压了会拖慢
    #   visible   = 有可见窗口（含最小化），或属于某可见窗口应用的子进程
    #               → 降优先级，绝不杀（用户点开过，可能存着没保存的工作）
    #   idle      = 无窗口 + CPU 不忙 + 不属于任何可见窗口应用
    #               → 降优先级 + EcoQoS + 修剪工作集，绝不杀
    #
    # 【配套应用】用户声明"正在使用"的应用，写 companion-apps.json。
    #   为什么必须靠声明而不是自动推断：这台机器上四个信号全部判不准——
    #     CPU：QQ 收发消息时仅 0.8%，DSH 0.4%，聊天几乎不耗 CPU
    #     IO ：Get-Process 的 Read/WriteTransferCount 为空，Get-Counter 恒 0
    #     TCP：只能证明"连着"。QQ 连腾讯 36.155.x，Edge 连 CDN 443，挂着的也连
    #     窗口：只能证明"点开过"。QQ 最小化照样在收发
    #   用户原话：「QQ 连的是我手机，DSH 用它连着 QQ，用 DSH 里面的人跟我 QQ 聊天。
    #             其他几个都没在用，就这 QQ 和 DSH 在用」——这是声明，不是指标。
    #
    # 【TCP 不再算"在用"】旧判据把"有连接"当在干活，结果 QQ/剪映/WorkBuddy/Edge
    #   全因挂着服务器连接被判 busy → 完全不动，等于没清场。
    #   现在 TCP 只用于展示，不参与分级。
    #
    # 铁律：清场永远不杀进程。杀只在用户显式发 kill_process 时才发生。
    param($Process, $FgPid, $DsTree, $AuthNames, $NeverPress, $SysNames, $SvcPids, $BusySet, $TcpSet, $PpidMap, $WinIds, $CompanionPids)
    $id = [int]$Process.Id
    $name = [string]$Process.ProcessName
    if ($id -eq $PID) { return 'protect' }
    if ($CompanionPids -and $CompanionPids.ContainsKey($id)) { return 'protect' }   # 用户声明的配套应用整组
    if ($DsTree.ContainsKey($id)) { return 'protect' }
    if ($name -in $NeverPress) { return 'protect' }
    if ($name -in $AuthNames) { return 'protect' }
    if ($name -in $SysNames) { return 'protect' }
    if ($SvcPids.ContainsKey($id)) { return 'protect' }   # Windows 服务进程：绝对不杀，也不压
    if ($FgPid -and $id -eq $FgPid) { return 'active' }
    # CPU 真在动 = 在干活。这一档无论有没有窗口都不压，否则会拖慢用户正在跑的导出/训练。
    if ($BusySet.ContainsKey($id)) { return 'busy' }
    # 以下才是"可以收算力"的范围
    if ($Process.MainWindowHandle -ne 0) { return 'visible' }
    if ($WinIds.ContainsKey($id)) { return 'visible' }    # 最小化窗口：MainWindowHandle 可能为 0，用可见窗口集合兜住
    if (Test-WindowedAncestor $id $PpidMap $WinIds) { return 'visible' }  # 同属一个可见应用（渲染/GPU 子进程），按同组处理
    return 'idle'
}
'''
t = t[:rank_start] + RANK + t[rank_end:]
print("2) Get-ProcessValueRank 已加 CompanionPids")

# ---------- 3) 调用处传参 ----------
old_call = "        $rank = Get-ProcessValueRank -Process $p -FgPid $fgPid -DsTree $dsTree -AuthNames $authNames -NeverPress $neverPress -SysNames $sysNames -SvcPids $svcPids -BusySet $busySet -TcpSet $tcpSet -PpidMap $ppidMap -WinIds $winIds"
new_call = "        $rank = Get-ProcessValueRank -Process $p -FgPid $fgPid -DsTree $dsTree -AuthNames $authNames -NeverPress $neverPress -SysNames $sysNames -SvcPids $svcPids -BusySet $busySet -TcpSet $tcpSet -PpidMap $ppidMap -WinIds $winIds -CompanionPids $companionPids"
if old_call in t:
    t = t.replace(old_call, new_call, 1)
    print("3) 补给调用处已传 CompanionPids")
else:
    print("✗ 补给调用处未匹配")
    for line in t.splitlines():
        if "Get-ProcessValueRank -Process" in line:
            print("   ", line.strip()[:160])

# 变量解包处补一行
old_unpack = "    $busySet = $ctx.BusySet; $tcpSet = $ctx.TcpSet; $ppidMap = $ctx.PpidMap; $winIds = $ctx.WinIds"
new_unpack = "    $busySet = $ctx.BusySet; $tcpSet = $ctx.TcpSet; $ppidMap = $ctx.PpidMap; $winIds = $ctx.WinIds\n    $companionPids = $ctx.CompanionPids"
if old_unpack in t:
    t = t.replace(old_unpack, new_unpack, 1)
    print("4) 变量解包已补 companionPids")
else:
    print("✗ 解包行未匹配")
    for line in t.splitlines():
        if "$busySet = $ctx.BusySet" in line:
            print("   ", line.strip()[:160])

# ---------- 4) 全局变量声明 ----------
anchor = "$script:PowerEcoQos           = @{}"
if anchor in t:
    t = t.replace(anchor, anchor + "\n$script:CompanionFile         = $null            # 2026-11-15：配套应用清单路径（下方按 $PSScriptRoot 赋值）", 1)
    print("5) 已加 CompanionFile 占位声明")

K.write_bytes((b"\xef\xbb\xbf" if bom else b"") + t.encode("utf-8"))
print("已写回，行数 =", len(t.splitlines()))
