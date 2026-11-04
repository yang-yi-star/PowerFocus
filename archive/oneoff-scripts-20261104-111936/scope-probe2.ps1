. 'E:\PowerFocus\统一内存模式.ps1'
. 'E:\PowerFocus\统一内存模式增强.ps1'
$out = @()

# A 测试脚本顶层定义的函数，读 $script:LlamaHost
function Debug-ScopeTop { "顶层定义函数: LlamaHost=[$($script:LlamaHost)] LlamaPort=[$($script:LlamaPort)]" }

# B 直接调用原脚本函数 Get-GpuMemoryInfo
$g = Get-GpuMemoryInfo
$out += "Get-GpuMemoryInfo 返回: 数量=$($g.Count)"
if ($g.Count -gt 0) { $out += ($g[0] | ConvertTo-Json -Compress) } else { $out += '空数组（nvidia-smi 失败或未找到）' }

# C 直接访问（模拟增强函数 URL 构造）
$url = "http://$script:LlamaHost:8080/slots"
$out += "顶层 URL=[$url]"
try { $r = Invoke-RestMethod -Uri $url -TimeoutSec 5; $out += "顶层访问 OK slots=$($r.Count)" } catch { $out += "顶层访问 FAIL $($_.Exception.Message)" }

$out += (Debug-ScopeTop)

# D 增强函数内部行为：构造等价 URL 并打印
$out += '--- 增强函数内部探针 ---'
function Probe-Enhance {
    $u1 = "http://$script:LlamaHost:8080/slots"
    $u2 = 'http://' + $script:LlamaHost + ':8080/slots'
    return "内部插值URL=[$u1] 拼接URL=[$u2] LlamaHost=[$($script:LlamaHost)]"
}
$out += (Probe-Enhance)

$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\scope-probe2.txt' -Encoding utf8
