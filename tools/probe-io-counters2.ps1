# 细分 ReadOp / WriteOp / OtherOp 的增量，判断哪一项才是"网络活动"的信号
$src = @'
using System;
using System.Runtime.InteropServices;
public struct IO_COUNTERS_ {
    public ulong ReadOperationCount; public ulong WriteOperationCount; public ulong OtherOperationCount;
    public ulong ReadTransferCount;  public ulong WriteTransferCount;  public ulong OtherTransferCount;
}
public class PfIo2 {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int p);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessIoCounters(IntPtr h, out IO_COUNTERS_ c);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    public static ulong[] Get(int pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) h = OpenProcess(0x0400, false, pid);
        if (h == IntPtr.Zero) return null;
        try {
            IO_COUNTERS_ c;
            if (!GetProcessIoCounters(h, out c)) return null;
            return new ulong[]{ c.ReadOperationCount, c.WriteOperationCount, c.OtherOperationCount,
                                c.ReadTransferCount, c.WriteTransferCount, c.OtherTransferCount };
        } finally { CloseHandle(h); }
    }
}
'@
Add-Type -TypeDefinition $src -Language CSharp

$targets = @(
    @{Id=13180; N='QQ(主)'}, @{Id=20308; N='QQ(副)'}, @{Id=5676; N='QQEX'},
    @{Id=43136; N='DSH(主)'}, @{Id=39912; N='DSH(子)'},
    @{Id=54636; N='剪映'}, @{Id=35644; N='msedge'}, @{Id=5704; N='WorkBuddy'}, @{Id=49400; N='WorkBuddy2'}
)

$s1 = @{}
foreach ($t in $targets) { $s1[$t.Id] = [PfIo2]::Get($t.Id) }

Start-Sleep -Seconds 6

"{0,-12} {1,-8} {2,10} {3,10} {4,10} {5,12} {6,12} {7,12}" -f '名称','PID','读op/s','写op/s','Other/s','读KB/s','写KB/s','OtherKB/s'
'-' * 92
foreach ($t in $targets) {
    $x = [PfIo2]::Get($t.Id); $y = $s1[$t.Id]
    if (-not $x -or -not $y) { "{0,-12} {1,-8} {2,10}" -f $t.N, $t.Id, '拿不到'; continue }
    $ro = ($x[0]-$y[0])/6; $wo = ($x[1]-$y[1])/6; $oo = ($x[2]-$y[2])/6
    $rb = ($x[3]-$y[3])/6/1KB; $wb = ($x[4]-$y[4])/6/1KB; $ob = ($x[5]-$y[5])/6/1KB
    "{0,-12} {1,-8} {2,10:N1} {3,10:N1} {4,10:N1} {5,12:N2} {6,12:N2} {7,12:N2}" -f $t.N, $t.Id, $ro, $wo, $oo, $rb, $wb, $ob
}

"`n=== 说明 ==="
"读op/写op = 文件读写操作次数；Other = 设备/同步/网络等其它 IO；*KB = 对应字节数速率"
