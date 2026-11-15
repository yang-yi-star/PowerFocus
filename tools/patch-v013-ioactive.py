# -*- coding: utf-8 -*-
"""v0.13 追加：用 GetProcessIoCounters 的 OtherOperationCount 速率作为"网络/设备活动"判据
依据（2026-11-15 本机实测）：
  QQ 13180 Other 20.7/s、QQ 20308 Other 6.7/s → 在收发
  DSH 43136 Other 88.8/s + 3.15 KB/s → 在联网
  msedge 35644 读op 181/s 写op 181/s 但 Other = 0 → 纯磁盘缓存，没有网络活动
  QQEX 5676 Other = 0 → 静止
所以 Other 速率能把"真的在联网/做设备 IO"和"只是在刷磁盘缓存"分开。
"""
from pathlib import Path
K = Path(r"E:\PowerFocus\versions\v0.13\电脑算力调度中心_v0.13.ps1")
raw = K.read_bytes(); bom = raw.startswith(b"\xef\xbb\xbf")
t = raw.decode("utf-8-sig")

# ---------- 1) 在 Get-BusyPidSet 之前插入 Get-IoActivePidSet ----------
anchor = "function Get-BusyPidSet"
if anchor not in t:
    print("✗ Get-BusyPidSet 锚点未找到"); raise SystemExit(1)

FUNC = r'''function Get-IoActivePidSet {
    # 用 kernel32 的 GetProcessIoCounters 测每进程的 OtherOperationCount 速率。
    #
    # 为什么必须用 P/Invoke 而不是 Get-Process：Get-Process 的 Read/WriteTransferCount
    # 对 QQ、DSH 这类进程返回空（PowerShell 的 Process 对象拿不到），
    # Get-Counter 的 IO Read/Write Bytes/sec 在这台机器上恒为 0。
    # 直接调 kernel32 才拿得到真实计数（2026-11-15 实测）。
    #
    # 为什么看 OtherOperationCount 而不是读/写字节数：
    #   Other = 网络/设备/同步类 IO（socket 收发、设备控制）
    #   Read/Write = 文件读写（含磁盘缓存）
    # 实测证据：
    #   QQ 13180  Other 20.7/s（在收发）      读op 65.5/s（也在读文件）
    #   DSH 43136 Other 88.8/s 且 3.15 KB/s（在联网）
    #   msedge    Other 0    但 读op+写op 363/s（纯磁盘缓存，没有网络）
    #   QQEX      Other 0    （静止）
    # 所以只有 Other 速率能区分"真的在联网"和"只是在刷缓存"。
    param([int]$SampleMs = 1200, [double]$MinOpsPerSec = 5.0)

    $result = @{}
    if (-not ('PfIoCounters' -as [type])) {
        try {
            Add-Type -Language CSharp -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public struct PF_IO_COUNTERS {
    public ulong ReadOperationCount;  public ulong WriteOperationCount;  public ulong OtherOperationCount;
    public ulong ReadTransferCount;   public ulong WriteTransferCount;   public ulong OtherTransferCount;
}
public class PfIoCounters {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int p);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessIoCounters(IntPtr h, out PF_IO_COUNTERS c);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    public static ulong[] Read(int pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) h = OpenProcess(0x0400, false, pid);
        if (h == IntPtr.Zero) return null;
        try {
            PF_IO_COUNTERS c;
            if (!GetProcessIoCounters(h, out c)) return null;
            return new ulong[]{ c.ReadOperationCount, c.WriteOperationCount, c.OtherOperationCount };
        } finally { CloseHandle(h); }
    }
}
'@
        } catch { Write-Log "WARN" "IO 计数器类型编译失败，跳过链路活动判据: $_"; return $result }
    }

    $p1 = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        $v = [PfIoCounters]::Read([int]$p.Id)
        if ($v) { $p1[[int]$p.Id] = $v[2] }   # 只存 OtherOperationCount
    }
    Start-Sleep -Milliseconds $SampleMs

    $sec = $SampleMs / 1000.0
    foreach ($pid_ in $p1.Keys) {
        $v = [PfIoCounters]::Read($pid_)
        if (-not $v) { continue }
        $rate = ($v[2] - $p1[$pid_]) / $sec
        if ($rate -ge $MinOpsPerSec) { $result[$pid_] = [math]::Round($rate, 1) }
    }
    return $result
}


'''
t = t.replace(anchor, FUNC + anchor, 1)
print("1) Get-IoActivePidSet 已插入")

# ---------- 2) Get-ProcessContext 里采集 ----------
old_busy = "    $ctx.BusySet = Get-BusyPidSet"
new_busy = "    $ctx.BusySet = Get-BusyPidSet\n    $ctx.IoActive = Get-IoActivePidSet"
if old_busy in t:
    t = t.replace(old_busy, new_busy, 1)
    print("2) 上下文已采集 IoActive")
else:
    print("✗ BusySet 采集行未匹配")

# ---------- 3) 判据加一档 ----------
old_rank = "    if ($BusySet.ContainsKey($id)) { return 'busy' }"
new_rank = ("    if ($BusySet.ContainsKey($id)) { return 'busy' }\n"
            "    # 有网网络/设备 IO 活动（Other 速率超阈值）= 在真的收发或做设备 IO，不压。\n"
            "    # 这一档专门为 QQ/DSH 这类消息通道设计：聊天时 CPU 几乎为 0，只有 Other IO 在动。\n"
            "    if ($IoActive -and $IoActive.ContainsKey($id)) { return 'busy' }")
if old_rank in t:
    t = t.replace(old_rank, new_rank, 1)
    print("3) 判据已加 IoActive 一档")
else:
    print("✗ 判据 busy 行未匹配")

# ---------- 4) 判据签名加参数 ----------
old_sig = "param($Process, $FgPid, $DsTree, $AuthNames, $NeverPress, $SysNames, $SvcPids, $BusySet, $TcpSet, $PpidMap, $WinIds, $CompanionPids)"
new_sig = "param($Process, $FgPid, $DsTree, $AuthNames, $NeverPress, $SysNames, $SvcPids, $BusySet, $TcpSet, $PpidMap, $WinIds, $CompanionPids, $IoActive)"
if old_sig in t:
    t = t.replace(old_sig, new_sig, 1)
    print("4) 判据签名已加 IoActive")
else:
    print("✗ 判据签名未匹配")

# ---------- 5) 调用处传参 ----------
old_call = "-WinIds $winIds -CompanionPids $companionPids"
new_call = "-WinIds $winIds -CompanionPids $companionPids -IoActive $ioActive"
if old_call in t:
    t = t.replace(old_call, new_call, 1)
    print("5) 调用处已传 IoActive")
else:
    print("✗ 调用处未匹配")

# ---------- 6) 解包变量 ----------
old_unpack = "    $companionPids = $ctx.CompanionPids"
new_unpack = "    $companionPids = $ctx.CompanionPids; $ioActive = $ctx.IoActive"
if old_unpack in t:
    t = t.replace(old_unpack, new_unpack, 1)
    print("6) 解包已补 ioActive")
else:
    print("✗ 解包行未匹配")

K.write_bytes((b"\xef\xbb\xbf" if bom else b"") + t.encode("utf-8"))
print("已写回，行数 =", len(t.splitlines()))
