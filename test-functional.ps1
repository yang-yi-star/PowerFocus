# PowerFocus 功能测试（在 pwsh 7 下运行）
$ErrorActionPreference = 'Stop'
$p = 'E:\PowerFocus\PowerFocus.ps1'
Write-Output ("pwsh version=" + $PSVersionTable.PSVersion)

# 语法预检
$tokens = $null; $errors = $null
[Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) { Write-Output 'SYNTAX ERRORS:'; $errors | ForEach-Object { Write-Output $_.Message }; exit 1 }
Write-Output 'SYNTAX OK'

# dot-source 仅加载函数（不启动托盘）
. $p

$target = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $target) { Write-Output 'FATAL: llama-server not running'; exit 1 }
Write-Output ("target pid=" + $target.Id + " prio=" + $target.PriorityClass)

# 1. 温和聚焦
Start-GentleFocus -ProcessId $target.Id -Name 'llama-server'
Start-Sleep -Seconds 2
$t1 = Get-Process -Id $target.Id
Write-Output ("after gentle: prio=" + $t1.PriorityClass + " originalPlan=" + $script:OriginalPlan)

# 2. 看门狗拉回（直接调用检查逻辑；定时器本体由 WinForms 消息泵驱动，另测）
Start-Watchdog -ProcessId $target.Id -Name 'llama-server'
try { $t1.PriorityClass = 'Normal' } catch {}
Write-Output ("manually demoted: prio=" + (Get-Process -Id $target.Id).PriorityClass)
Invoke-WatchdogCheck
Start-Sleep -Seconds 2
$t2 = Get-Process -Id $target.Id -ErrorAction SilentlyContinue
Write-Output ("after watchdog check: prio=" + $t2.PriorityClass + " (expect High)")

# 3. 目标进程退出自动解除（用不存在的 PID 模拟）
$script:TargetPid = 999999; $script:TargetName = 'nonexistent'
Invoke-WatchdogCheck
Write-Output ("after exit-sim: targetPid=" + $script:TargetPid + " (expect empty)")

# 4. 激进聚焦
Start-AggressiveFocus -ProcessId $target.Id -Name 'llama-server'
Write-Output ("aggressive demoted count=" + $script:DemotedPids.Count)
$sid = $script:DemotedPids | Select-Object -First 1
$samp = Get-Process -Id $sid -ErrorAction SilentlyContinue
if ($samp) { Write-Output ("sample " + $samp.ProcessName + " prio=" + $samp.PriorityClass + " (expect BelowNormal)") }
$tl = Get-Process -Id $target.Id
Write-Output ("target still=" + $tl.PriorityClass + " (expect High)")

# 5. 解除聚焦
Stop-Focus
Start-Sleep -Seconds 2
$t3 = Get-Process -Id $target.Id -ErrorAction SilentlyContinue
Write-Output ("after stop: targetPrio=" + $t3.PriorityClass + " demotedLeft=" + $script:DemotedPids.Count + " originalPlan=" + $script:OriginalPlan + " timer=" + $script:TimerObj)

Write-Output '=== log tail ==='
Get-Content -LiteralPath 'E:\PowerFocus\PowerFocus.log' -Tail 16
Write-Output 'TEST DONE'
