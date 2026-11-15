# 用内核自己的判据给当前所有进程打等级，看它和你"在用"的实际差多少
$k = 'E:\PowerFocus\versions\v0.13\电脑算力调度中心_v0.13.ps1'
. $k

Add-Type -ErrorAction Stop @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WP {
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  private delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EP cb, IntPtr l);

  public static int FgPid = 0;
  public static HashSet<int> WinPids = new HashSet<int>();
  public static HashSet<int> MinPids = new HashSet<int>();

  public static void Collect() {
    WinPids.Clear(); MinPids.Clear();
    IntPtr fg = GetForegroundWindow();
    uint fp = 0; GetWindowThreadProcessId(fg, out fp); FgPid = (int)fp;
    EnumWindows(OnWin, IntPtr.Zero);
  }
  static bool OnWin(IntPtr h, IntPtr l) {
    if (!IsWindowVisible(h)) return true;
    if (GetWindowTextLength(h) == 0) return true;
    uint p = 0; GetWindowThreadProcessId(h, out p);
    if (p > 0) {
      WinPids.Add((int)p);
      if (IsIconic(h)) MinPids.Add((int)p);
    }
    return true;
  }
}
'@

[WP]::Collect()

$ctx = Get-ProcessContext
$ctx.FgPid = [WP]::FgPid
$ctx.WinIds = @{}
foreach ($p in [WP]::WinPids) { $ctx.WinIds[$p] = $true }

"前台 PID = $($ctx.FgPid)   有可见窗口的进程 = $([WP]::WinPids.Count)"
"`n{0,-24} {1,-7} {2,9} {3,-9} {4}" -f '进程', 'PID', '内存MB', '内核判定', '备注'
'-' * 96

$order = @{ protect = 0; active = 1; task = 2; semi = 3; junk = 4 }
$rows = @()
foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
    if ($p.WorkingSet64 -lt 50MB) { continue }
    $r = Get-ProcessValueRank -Process $p -FgPid $ctx.FgPid -DsTree $ctx.DsTree -AuthNames $ctx.AuthNames `
        -NeverPress $ctx.NeverPress -SysNames $ctx.SysNames -SvcPids $ctx.SvcPids `
        -BusySet $ctx.BusySet -TcpSet $ctx.TcpSet -PpidMap $ctx.PpidMap -WinIds $ctx.WinIds -CompanionPids $ctx.CompanionPids
    $rows += [pscustomobject]@{
        Name = $p.ProcessName; Id = $p.Id; MB = [math]::Round($p.WorkingSet64/1MB); Rank = $r
        HasWin = [WP]::WinPids.Contains([int]$p.Id)
        IsMin = [WP]::MinPids.Contains([int]$p.Id)
        InnerWin = ($p.MainWindowHandle -ne 0)
    }
}

$rows | Sort-Object { $order[$_.Rank] }, @{ Expression = 'MB'; Descending = $true } | Select-Object -First 45 | ForEach-Object {
    $note = ''
    if ($_.Rank -eq 'junk' -and $_.HasWin) { $note = '⚠ junk 但有可见窗口 → 会误杀' }
    elseif ($_.Rank -eq 'junk' -and $_.InnerWin) { $note = '⚠ junk 但 MainWindowHandle≠0' }
    elseif ($_.Rank -eq 'junk') { $note = '会被杀（启动>120s）' }
    elseif ($_.Rank -eq 'semi' -and -not $_.InnerWin -and $_.HasWin) { $note = '内核靠 MainWindowHandle 判，漏了最小化窗口' }
    "{0,-24} {1,-7} {2,9} {3,-9} {4}" -f $_.Name, $_.Id, $_.MB, $_.Rank, $note
}

"`n=== 等级统计 ==="
$rows | Group-Object Rank | Sort-Object { $order[$_.Name] } | ForEach-Object {
    "  {0,-8} {1,3} 个   合计 {2,6:N0} MB" -f $_.Name, $_.Count, (($_.Group | Measure-Object MB -Sum).Sum)
}

"`n=== 判定 junk 的全部名单（这些在补给时会被 Stop-Process -Force）==="
$rows | Where-Object Rank -eq 'junk' | ForEach-Object {
    "  {0,-24} PID={1,-7} {2,6}MB  可见窗口={3,-5} 最小化={4}" -f $_.Name, $_.Id, $_.MB, $_.HasWin, $_.IsMin
}

"`n=== 对照你点名的应用 ==="
foreach ($n in @('DeepSeek Harness','QQ','DoubaoWork','WorkBuddy','JianyingPro','Trae CN','msedge')) {
    $hit = $rows | Where-Object Name -eq $n
    if ($hit) { $hit | ForEach-Object { "  {0,-20} PID={1,-7} {2,6}MB → {3}" -f $_.Name, $_.Id, $_.MB, $_.Rank } }
}
