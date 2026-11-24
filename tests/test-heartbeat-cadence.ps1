# 29 号离线回归：心跳写周期必须远小于服务端判活窗口（防 13 号判死链复发）
#
# 症状链：心跳每 5 个 tick（tick=2s）写一次 = 10s；服务端 kernel_alive 只判
#         (now - hb.time) < 15s。一旦某次写慢或丢一拍，余量只剩 5s，服务端判死
#         并 ensure_kernel 再拉一个内核 -> 双内核同扫 commands\in。
#
# 本测试只读源码、解析常量，不启内核、不碰运行态；支持 -KernelPath 做变异验证。
#
# 用法：
#   pwsh -File tests\test-heartbeat-cadence.ps1
#   pwsh -File tests\test-heartbeat-cadence.ps1 -KernelPath <变异副本>
#
param(
    [string]$KernelPath,
    [string]$ServerPath
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

if (-not $KernelPath) {
    $cur = Get-Content (Join-Path $Root 'versions\current.json') -Raw | ConvertFrom-Json
    $ver = [string]$cur.version
    $KernelPath = Join-Path $Root ("versions\{0}\电脑算力调度中心_{0}.ps1" -f $ver)
}
if (-not $ServerPath) {
    $ServerPath = Join-Path $Root 'product\v1.00\app\server.py'
}

$script:Pass = 0
$script:Fail = 0
$script:Lines = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Cond, [string]$Id, [string]$Msg)
    if ($Cond) {
        $script:Pass++
        $script:Lines.Add("  PASS $Id  $Msg")
    } else {
        $script:Fail++
        $script:Lines.Add("  FAIL $Id  $Msg")
    }
}

foreach ($p in @($KernelPath, $ServerPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "源码不存在: $p" }
}

$kt = Get-Content -LiteralPath $KernelPath -Raw
$st = Get-Content -LiteralPath $ServerPath -Raw

# A. 心跳写点：每 N 个 tick 写一次
$mBeat = [regex]::Match($kt, 'TickCount\s*%\s*(\d+)\s*\)\s*-eq\s*0\s*\)\s*\{\s*Write-Heartbeat')
Assert-True ($mBeat.Success) 'A1' '内核存在「TickCount % N == 0 -> Write-Heartbeat」写点'
$N = if ($mBeat.Success) { [int]$mBeat.Groups[1].Value } else { 0 }
Assert-True ($N -ge 1) 'A2' "N 为正整数（实测 N=$N）"

# B. tick 周期由命令总线定时器决定
$mTick = [regex]::Match($kt, 'CmdTimerObj\.Interval\s*=\s*(\d+)')
Assert-True ($mTick.Success) 'B1' '内核存在 CmdTimerObj.Interval 赋值'
$M = if ($mTick.Success) { [int]$mTick.Groups[1].Value } else { 0 }
Assert-True ($M -eq 2000) 'B2' "总线 tick 周期仍为 2000ms（实测 $M ms；改它属于另一议题，本测试只守心跳节拍）"

# C. 服务端判活窗口（兼容两代实现：13 号 0<=age<W / 旧式 (time.time()-ts)<W）
$mNew = [regex]::Match($st, 'if\s+not\s+\(0\s*<=\s*age\s*<\s*(\d+)\)')
$mOld = [regex]::Match($st, '\(time\.time\(\)\s*-\s*ts\)\s*<\s*(\d+)')
Assert-True ($mNew.Success -or $mOld.Success) 'C1' '服务端存在判活窗口（0<=age<W 或旧式 (time.time()-ts)<W）'
$W = if ($mNew.Success) { [int]$mNew.Groups[1].Value } elseif ($mOld.Success) { [int]$mOld.Groups[1].Value } else { 0 }
Assert-True ($W -ge 10) 'C2' "判活窗口 W >= 10s（实测 W=$W s）"

# D. 节拍与窗口的余量关系
$periodMs = $N * $M
$periodSec = [math]::Round($periodMs / 1000.0, 1)
$slack = $W - $periodSec
Assert-True ($W -gt 0 -and $periodSec -le ($W / 2.0)) 'D1' `
    ("写周期 {0}s <= 判活窗口 {1}s 的一半（至少能连续丢 1 拍仍判活；当前余量 {2}s）" -f $periodSec, $W, $slack)
Assert-True ($periodSec -le 6) 'D2' ("写周期 {0}s <= 6s 硬上限（29 号原值为 10s）" -f $periodSec)

# E. 心跳本身不能丢
Assert-True ($kt -match 'function\s+Write-Heartbeat') 'E1' '内核仍定义 Write-Heartbeat'
$mFn = [regex]::Match($kt, '(?s)function\s+Write-Heartbeat\s*\{.*?\n\}')
Assert-True ($mFn.Success -and ($mFn.Value -match 'catch')) 'E2' 'Write-Heartbeat 体内仍有 try/catch（写失败不得抛出中断主循环）'

# F. 一致性输出
$script:Lines.Add('')
$script:Lines.Add(("  解析结果: 写点 N={0} tick={1}ms 写周期={2}s 判活窗口={3}s 余量={4}s" -f $N, $M, $periodSec, $W, $slack))

$script:Lines | ForEach-Object { $_ }
"PASS $script:Pass / FAIL $script:Fail"
if ($script:Fail -gt 0) { exit 1 }
exit 0
