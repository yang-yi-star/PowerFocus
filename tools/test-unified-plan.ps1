# ============================================================
# 统一内存接线 — 真跑验证（不做 mock）
# 用法：pwsh -NoProfile -File tools\test-unified-plan.ps1
#
# 验证目标：把仓库根 `统一内存模式.ps1` 的层分配算法接进 v0.11 内核后，
#          四个函数在真实机器上是否给出与手算一致的答案。
# ============================================================

$ErrorActionPreference = 'Stop'

$Kernel = 'E:\PowerFocus\versions\v0.11\电脑算力调度中心_v0.11.ps1'
$Model  = 'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf'

if (-not (Test-Path -LiteralPath $Kernel)) { throw "内核不存在: $Kernel" }

# dot-source：只加载函数，不启动托盘（内核第 2127 行有 dot-source 保护）
. $Kernel

$fail = 0
function Assert-True($cond, $label) {
    if ($cond) { "  [PASS] $label" }
    else { "  [FAIL] $label"; $script:fail++ }
}

"============================================================"
"1. Get-GpuMemoryInfo"
"============================================================"
$gpu = Get-GpuMemoryInfo
$gpu | ConvertTo-Json -Depth 3
Assert-True (@($gpu).Count -ge 1) "探测到至少 1 张 NVIDIA GPU"
Assert-True ($gpu[0].TotalMB -eq 8151) "GPU0 显存总量 = 8151 MB（RTX 5060 Laptop 8GB）"

""
"============================================================"
"2. Get-SystemMemoryInfo"
"============================================================"
$mem = Get-SystemMemoryInfo
$mem | ConvertTo-Json
Assert-True ($mem.TotalMB -gt 30000) "系统内存总量 > 30 GB（本机 32GB）"
Assert-True ([math]::Abs(($mem.TotalMB - $mem.AvailableMB) - $mem.CommittedMB) -le 1) "Committed ≈ Total − Available（容差 1MB，两者各自四舍五入）"

""
"============================================================"
"3. Get-GgufLayerCount（GGUF v3 二进制头解析）"
"============================================================"
if (Test-Path -LiteralPath $Model) {
    $layers = Get-GgufLayerCount -Path $Model
    "层数 = $layers"
    Assert-True ($layers -gt 0 -and $layers -lt 512) "解析出的层数在合理区间 (1..511)"
    Assert-True ($layers -gt 20) "27B 模型层数应远大于 20（否则说明解析失败回退）"
} else {
    "  [SKIP] 模型文件不存在: $Model"
}

""
"============================================================"
"4. Calculate-OptimalLayerSplit（手算对照）"
"============================================================"
if (Test-Path -LiteralPath $Model) {
    $free = $gpu[0].FreeMB
    $size = (Get-Item -LiteralPath $Model).Length / 1MB
    $usable = $free - $script:CudaReservedMB - $script:ComputeReserveMB
    $per = if ($layers -gt 0) { [math]::Round($size / $layers, 2) } else { $size }
    $expect = [math]::Floor([math]::Max(0, $usable) / $per)

    $plan = Calculate-OptimalLayerSplit -ModelPath $Model -GpuFreeMB $free
    $plan | ConvertTo-Json -Depth 3

    "手算对照: free=$free  预留=$($script:CudaReservedMB)+$($script:ComputeReserveMB)"
    "          usable=$usable MB  每层≈$per MB  -> 期望 GPU 层 = $expect"
    Assert-True ($plan.GpuUsableMB -eq $usable) "GpuUsableMB 与手算一致（$usable）"
    Assert-True ($plan.GpuLayers -eq $expect) "GpuLayers 与手算一致（$expect）"
    Assert-True (($plan.GpuLayers + $plan.CpuLayers) -eq $plan.TotalLayers) "Gpu+Cpu 层数 = 总层数"
    Assert-True ($plan.GpuLayers -lt $plan.TotalLayers) "CPU 至少保留 1 层"
    Assert-True ($script:MaxGpuLayersSafe -eq 0) "MaxGpuLayersSafe = 0（按显存自动推导，未硬钳）"
} else {
    "  [SKIP] 模型文件不存在"
}

""
"============================================================"
"5. Get-UnifiedMemoryPlan（无模型路径）"
"============================================================"
$p1 = Get-UnifiedMemoryPlan
$p1 | ConvertTo-Json -Depth 5
Assert-True ($p1.layer_plan -eq $null) "未给模型路径时 layer_plan 为空"
Assert-True (-not [string]::IsNullOrWhiteSpace($p1.note)) "给出说明文字而非静默"

""
"============================================================"
"6. Get-UnifiedMemoryPlan（有模型路径）"
"============================================================"
if (Test-Path -LiteralPath $Model) {
    $p2 = Get-UnifiedMemoryPlan -ModelPath $Model
    $p2 | ConvertTo-Json -Depth 6
    Assert-True ($null -ne $p2.layer_plan) "给了模型路径时产出 layer_plan"
    Assert-True ($p2.gpu_count -eq @($gpu).Count) "gpu_count 与探测结果一致"
}

""
"============================================================"
if ($fail -eq 0) { "全部断言通过（0 失败）" } else { "FAIL: $fail 项未通过" }
"============================================================"
exit $fail
