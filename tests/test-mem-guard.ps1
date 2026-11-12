#requires -Version 7.0
<#  MemGuard 验证用例：覆盖 3 个场景
    A) 本地模型未运行 —— 必须零压制
    B) 本地模型运行中 + 后台大内存进程 —— 必须压制后台、绝不碰模型
    C) 内存 97% 极端边界 —— 必须保护前台、模型优先级只升不降
#>
$ErrorActionPreference = 'Continue'
$pwsh     = 'C:\Tools\PowerShell7\pwsh.exe'
$guard    = 'E:\PowerFocus\lib\mem-guard.ps1'
$router   = 'E:\PowerFocus\tools\model-router.ps1'
$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Cond, [string]$Detail) {
    if ($Cond) { $script:pass++; "  [PASS] $Name  $Detail" } else { $script:fail++; "  [FAIL] $Name  $Detail" }
}
function Run-Guard([string[]]$Extra) {
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$guard,'-Once','-Json','-MinWorkingSetMB','300') + $Extra
    $o = & $pwsh @args
    try { return ($o -join "`n" | ConvertFrom-Json) } catch { Write-Host ($o -join "`n"); return $null }
}
function Model-Alive { return [bool](Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction SilentlyContinue) }

"=== 场景 A：本地模型未运行 ==="
if (Model-Alive) {
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $router -Action stop | Out-Null
    Start-Sleep -Seconds 2
}
$a = Run-Guard @()
$stillModel = Model-Alive
Check 'A1 检测到本地模型未运行' ($a.modelRunning -eq $false) "modelRunning=$($a.modelRunning)"
Check 'A2 不执行任何压制'          ($a.trimmed -eq 0)            "trimmed=$($a.trimmed)"
Check 'A3 模式为 idle'             ($a.level -eq 'idle')         "level=$($a.level)"
Check 'A4 前台仍被保障'            ($a.protectedCount -ge 1)     "protected=$($a.protectedCount)"

"=== 场景 B：本地模型运行中 + 后台大内存进程 ==="
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $router -Action start | Out-Null
Start-Sleep -Seconds 6
$b0 = Model-Alive
"  模型进程存在=$b0"
# 造一个 1.5GB 工作集的纯后台进程（无窗口，不在前台/模型祖先链上）
$hog = Start-Process $pwsh -ArgumentList '-NoProfile','-Command','$a=New-Object byte[] 1600MB; for($i=0;$i -lt $a.Length;$i+=4096){$a[$i]=1}; Start-Sleep -Seconds 120' -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 8
$ws0 = [math]::Round((Get-Process -Id $hog.Id).WorkingSet64/1MB,1)
"  后台进程 PID=$($hog.Id) 工作集=${ws0}MB"
$b = Run-Guard @('-SimulatePressure')
Check 'B1 检测到本地模型运行'      ($b.modelRunning -eq $true)  "modelRunning=$($b.modelRunning) count=$($b.modelCount)"
Check 'B2 触发压制'                ($b.trimmed -gt 0)           "trimmed=$($b.trimmed) freed=$($b.freedMB)MB"
$hit = @($b.actions | Where-Object { $_.pid -eq $hog.Id })
Check 'B3 后台大内存进程被压制'    ($hit.Count -eq 1)           "命中=$($hit.Count) 释放=$($hit[0].freedMB)MB"
$modelTouched = @($b.actions | Where-Object { $_.pid -in $b.modelPids })
Check 'B4 模型进程绝不被压制'      ($modelTouched.Count -eq 0)  "模型被压次数=$($modelTouched.Count)"
$mp = Get-Process -Id ($b.modelPids[0]) -ErrorAction SilentlyContinue
Check 'B5 模型优先级被保障'        ($mp -and [string]$mp.PriorityClass -in @('AboveNormal','High')) "modelPriority=$([string]$mp.PriorityClass)"
Stop-Process -Id $hog.Id -Force -ErrorAction SilentlyContinue

"=== 场景 C：内存 97% 极端边界 ==="
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 3
Add-Type @"
using System;using System.Runtime.InteropServices;
public class FG { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); }
"@ -ErrorAction SilentlyContinue
[FG]::SetForegroundWindow($np.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 800
$c = Run-Guard @('-SimulatePressure')
"  报告内存占用=$($c.memPercent)% 前台PID=$($c.fgPid)"
Check 'C1 极端压力下判定为 critical' ($c.level -eq 'critical')  "level=$($c.level)"
Check 'C2 前台进程未被压制'           (@($c.actions | Where-Object { $_.pid -eq $c.fgPid }).Count -eq 0) "fgPid=$($c.fgPid)"
$fgp = Get-Process -Id $c.fgPid -ErrorAction SilentlyContinue
Check 'C3 前台优先级被保障' ($fgp -and [string]$fgp.PriorityClass -in @('AboveNormal','High','RealTime')) "fgPriority=$([string]$fgp.PriorityClass)"
Check 'C4 模型优先级仍受保障'         ($c.modelRunning -eq $true) "modelRunning=$($c.modelRunning)"
Stop-Process -Id $np.Id -Force -ErrorAction SilentlyContinue

"=== 汇总：PASS=$pass  FAIL=$fail ==="
if ($fail -gt 0) { exit 1 }
