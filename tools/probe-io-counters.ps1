# 测 GetProcessIoCounters（kernel32）能否拿到 Get-Process 拿不到的 IO 计数
$src = @'
using System;
using System.Runtime.InteropServices;

public struct IO_COUNTERS_ {
    public ulong ReadOperationCount;
    public ulong WriteOperationCount;
    public ulong OtherOperationCount;
    public ulong ReadTransferCount;
    public ulong WriteTransferCount;
    public ulong OtherTransferCount;
}

public class PfIo {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetProcessIoCounters(IntPtr h, out IO_COUNTERS_ c);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    // 0x1000 = PROCESS_QUERY_LIMITED_INFORMATION, 0x0400 = PROCESS_QUERY_INFORMATION
    public static string Get(int pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) h = OpenProcess(0x0400, false, pid);
        if (h == IntPtr.Zero) return "OPEN_FAIL:" + Marshal.GetLastWin32Error();
        try {
            IO_COUNTERS_ c;
            if (!GetProcessIoCounters(h, out c)) return "IO_FAIL:" + Marshal.GetLastWin32Error();
            return string.Format("{0}|{1}|{2}|{3}|{4}|{5}",
                c.ReadOperationCount, c.WriteOperationCount, c.OtherOperationCount,
                c.ReadTransferCount, c.WriteTransferCount, c.OtherTransferCount);
        } finally { CloseHandle(h); }
    }
}
'@
Add-Type -TypeDefinition $src -Language CSharp

function Get-Io($pid_) {
    $r = [PfIo]::Get($pid_)
    if ($r -like '*_FAIL:*') { return $null }
    $f = $r -split '\|'
    return @{ R=[uint64]$f[3]; W=[uint64]$f[4]; O=[uint64]$f[5]; ROp=[uint64]$f[0]; WOp=[uint64]$f[1] }
}

$targets = @(13180, 20308, 5676, 43136, 39912, 54636, 35644)  # QQ×2, QQEX, DSH×2, 剪映, edge
$names = @{}
foreach ($t in $targets) { $p = Get-Process -Id $t -ErrorAction SilentlyContinue; if ($p) { $names[$t] = $p.ProcessName } }

"=== 第 1 次采样 ==="
"{0,-8} {1,-18} {2,14} {3,14} {4,10}" -f 'PID','名称','读字节','写字节','Other'
'-' * 60
$s1 = @{}
foreach ($t in $targets) {
    $io = Get-Io $t
    if (-not $io) { "{0,-8} {1,-18} {2,14}" -f $t, ($names[$t]), '拿不到'; continue }
    $s1[$t] = $io
    "{0,-8} {1,-18} {2,14:N0} {3,14:N0} {4,10:N0}" -f $t, ($names[$t]), $io.R, $io.W, $io.O
}

Start-Sleep -Seconds 5
"`n=== 第 2 次采样（5 秒后）+ 增量 ==="
"{0,-8} {1,-18} {2,12} {3,12} {4,12} {5,12}" -f 'PID','名称','读增KB/s','写增KB/s','操作增/s','判定'
'-' * 78
foreach ($t in $targets) {
    $io = Get-Io $t
    if (-not $io -or -not $s1.ContainsKey($t)) { continue }
    $dR = ($io.R - $s1[$t].R) / 5 / 1KB
    $dW = ($io.W - $s1[$t].W) / 5 / 1KB
    $dOp = ($io.ROp + $io.WOp - $s1[$t].ROp - $s1[$t].WOp) / 5
    $verdict = if (($dOp -gt 1) -or ($dR + $dW -gt 1)) { '有活动' } else { '静止' }
    "{0,-8} {1,-18} {2,12:N2} {3,12:N2} {4,12:N1} {5,12}" -f $t, ($names[$t]), $dR, $dW, $dOp, $verdict
}
