# 增强模块集成实测 v2（带调试输出）
$ErrorActionPreference = 'Stop'
$out = @()

# 1 语法校验
$errs = $null
$tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile('E:\PowerFocus\统一内存模式增强.ps1', [ref]$tokens, [ref]$errs) | Out-Null
if ($errs.Count -eq 0) { $out += '语法校验: 通过' } else { $out += "语法校验: 失败 $($errs.Count) 处"; $errs | ForEach-Object { $out += "  $($_.Extent.StartLineNumber): $($_.Message)" } }

# 2 dot-source 两个模块
. 'E:\PowerFocus\统一内存模式.ps1'
. 'E:\PowerFocus\统一内存模式增强.ps1'
$out += "dot-source 后 script:LlamaHost=[$($script:LlamaHost)] LlamaPort=[$($script:LlamaPort)]"

# 3 函数存在性
foreach ($f in 'Get-ContextRemainingEstimate','Test-PerformanceDegradation','Invoke-ContextCleanup','Monitor-WeightDistributionEnhanced') {
    if (Get-Command $f -ErrorAction SilentlyContinue) { $out += "函数 $f : 存在" } else { $out += "函数 $f : 缺失!" }
}

# 4 实测 Get-ContextRemainingEstimate
$est = Get-ContextRemainingEstimate -Port 8080
$out += '=== Get-ContextRemainingEstimate 实测 ==='
$out += ($est | ConvertTo-Json -Compress)

# 5 实测 Test-PerformanceDegradation
$t1 = Test-PerformanceDegradation -CurrentTps 3.6 -BaselineTps 3.7
$out += "降速检测 3.6 vs 3.7: Degraded=$($t1.Degraded) Ratio=$($t1.Ratio) 队列=$($t1.QueueLength)"
$t2 = Test-PerformanceDegradation -CurrentTps 1.2 -BaselineTps 3.7
$out += "降速检测 1.2 vs 3.7: Degraded=$($t2.Degraded) Ratio=$($t2.Ratio) 队列=$($t2.QueueLength)"

# 6 实测 Monitor 增强版短跑 2 轮
$out += '=== Monitor 增强版短跑 2 轮 ==='
Monitor-WeightDistributionEnhanced -SampleCount 2 -IntervalSec 2 -BaselineTps 3.7

$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\um-enhance-test-result.txt' -Encoding utf8
