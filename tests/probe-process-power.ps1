# 进程控制能力实测：只针对自己创建的测试进程，不触碰真实业务程序
$ErrorCount = 0
Add-Type @"
using System;using System.Runtime.InteropServices;
public class PP {
 [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
 [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
 [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint acc, bool inh, int pid);
 [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
 [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr h);
}
"@

function Get-TestProcInfo($p) {
    return "PID=$($p.Id) 状态=$($p.Responding) 内存WS=$([math]::Round($p.WorkingSet64/1MB,1))MB CPU=$([math]::Round($p.TotalProcessorTime.TotalSeconds,2))s 优先级=$($p.PriorityClass)"
}

# 1) 起一个可观测的测试进程：持续累加内存，便于观察压制效果
$code = '$b=@(); while($true){ $b += ("x"*4096); Start-Sleep -Milliseconds 30 }'
$p = Start-Process 'C:\Tools\PowerShell7\pwsh.exe' -ArgumentList '-NoProfile','-Command',$code -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
"【测试进程】$(Get-TestProcInfo $p)"

# 2) 挂起 / 恢复（NtSuspendProcess）
$h = [PP]::OpenProcess(0x0800 -bor 0x1000, $false, $p.Id)   # PROCESS_SUSPEND_RESUME | QUERY_LIMITED
if ($h -ne [IntPtr]::Zero) {
    $r1 = [PP]::NtSuspendProcess($h)
    Start-Sleep -Milliseconds 800
    $before = (Get-Process -Id $p.Id).TotalProcessorTime
    Start-Sleep -Seconds 2
    $after = (Get-Process -Id $p.Id).TotalProcessorTime
    "【挂起】NtSuspendProcess=$r1 挂起期间 CPU 增量=$([math]::Round(($after-$before).TotalSeconds,3))s (≈0 表示已冻结)"
    $r2 = [PP]::NtResumeProcess($h)
    Start-Sleep -Milliseconds 500
    $b2 = (Get-Process -Id $p.Id).TotalProcessorTime
    Start-Sleep -Seconds 2
    $a2 = (Get-Process -Id $p.Id).TotalProcessorTime
    "【恢复】NtResumeProcess=$r2 恢复后 CPU 增量=$([math]::Round(($a2-$b2).TotalSeconds,3))s"
    [PP]::CloseHandle($h) | Out-Null
} else {
    "【挂起】OpenProcess 失败 err=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    $ErrorCount++
}

# 3) 内存压制（EmptyWorkingSet 循环 + Idle 优先级）
$p2 = Get-Process -Id $p.Id
$ws0 = $p2.WorkingSet64
$p2.PriorityClass = 'Idle'
$h2 = [PP]::OpenProcess(0x0100, $false, $p.Id)
if ($h2 -ne [IntPtr]::Zero) {
    $ok = 0
    for ($i = 0; $i -lt 10; $i++) { if ([PP]::EmptyWorkingSet($h2)) { $ok++ }; Start-Sleep -Milliseconds 200 }
    [PP]::CloseHandle($h2) | Out-Null
    $ws1 = (Get-Process -Id $p.Id).WorkingSet64
    "【内存压制】EmptyWorkingSet 成功 $ok/10 次；工作集 $([math]::Round($ws0/1MB,1))MB -> $([math]::Round($ws1/1MB,1))MB；优先级已压到 Idle"
} else { "【内存压制】OpenProcess 失败"; $ErrorCount++ }

# 4) 强杀（TerminateProcess / Stop-Process -Force）
try {
    Stop-Process -Id $p.Id -Force -ErrorAction Stop
    Start-Sleep -Milliseconds 600
    $alive = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if ($alive) { "【强杀】失败：进程仍存活"; $ErrorCount++ } else { "【强杀】成功：测试进程已被强制终止" }
} catch { "【强杀】异常: $_"; $ErrorCount++ }

"=== 结论：失败项 $ErrorCount 个 ==="
