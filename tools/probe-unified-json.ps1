# 探针：检查 Get-UnifiedMemoryPlan 的 JSON 形状（必须在 pwsh 7 下跑）
# 用法：pwsh -NoProfile -File tools\probe-unified-json.ps1

$ErrorActionPreference = 'Stop'

$k = 'E:\PowerFocus\versions\v0.11\电脑算力调度中心_v0.11.ps1'
$m = 'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf'

"当前 PowerShell 版本: $($PSVersionTable.PSVersion)"
""

. $k

"--- A. 无模型路径 ---"
$p0 = Get-UnifiedMemoryPlan
"gpu 元素数        : $(@($p0.gpu).Count)"
"gpu[0] 是数组?    : $(($p0.gpu[0] -is [array]))   <- 必须 False"
"gpu[0].FreeMB     : $($p0.gpu[0].FreeMB)          <- 必须数字"
"gpu_count         : $($p0.gpu_count)"
"layer_plan        : $($p0.layer_plan)"
""

"--- B. 有模型路径 ---"
$p1 = Get-UnifiedMemoryPlan -ModelPath $m
"gpu 元素数        : $(@($p1.gpu).Count)"
"gpu[0] 是数组?    : $(($p1.gpu[0] -is [array]))   <- 必须 False"
"layer_plan GPU层  : $($p1.layer_plan.GpuLayers)"
"layer_plan CPU层  : $($p1.layer_plan.CpuLayers)"
"layer_plan 总层   : $($p1.layer_plan.TotalLayers)"
"layer_plan 可用MB : $($p1.layer_plan.GpuUsableMB)"
""

"--- C. 序列化后前 16 行（应看到 `"gpu`: [ { 单层，不该是 [ [ { ---"
($p1 | ConvertTo-Json -Depth 8) -split "`n" | Select-Object -First 16

""
"--- D. 判定 ---"
$okA = (-not ($p0.gpu[0] -is [array])) -and ($p0.gpu[0].FreeMB -ne $null)
$okB = (-not ($p1.gpu[0] -is [array])) -and ($null -ne $p1.layer_plan)
if ($okA -and $okB) { "形状正确：单层数组 + 可读字段" } else { "形状仍有问题" }
