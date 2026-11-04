# um-validate.ps1 - 统一内存模式扩展 集成验证
$ErrorActionPreference = 'Stop'
$out = @()
$out += "pwsh 版本: $($PSVersionTable.PSVersion.ToString())"

# 1. 语法校验（两个文件）
foreach ($f in @('E:\PowerFocus\统一内存模式.ps1','E:\PowerFocus\Test-UnifiedMemoryPerf.ps1')) {
    $errs = $null; $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errs)
    $out += "$f : 语法错误 $($errs.Count) 个"
    if ($errs.Count) { $out += ($errs | Select-Object -First 5 | ForEach-Object { "  $($_.Message)" }) }
}

# 2. dot-source 加载
try {
    . 'E:\PowerFocus\统一内存模式.ps1'
    $fns = 'Start-UnifiedMemoryMode','Stop-UnifiedMemoryMode','Show-MemoryStatus','Monitor-WeightDistribution','Get-GpuMemoryInfo','Get-SystemMemoryInfo','Calculate-OptimalLayerSplit','Get-GgufLayerCount','Build-LlamaServerArgs'
    $missing = @($fns | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missing.Count -eq 0) { $out += "dot-source: OK，9 个关键函数全部加载" } else { $out += "dot-source: 缺失函数 [$($missing -join ',')]" }
} catch { $out += "dot-source 异常: $($_.Exception.Message)" }

# 3. 只读探针：GGUF 层数解析 + GPU/内存检测（不启动、不停服务）
try {
    $layers = Get-GgufLayerCount -Path 'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf'
    $out += "GGUF 层数解析: $layers"
} catch { $out += "GGUF 解析异常: $($_.Exception.Message)" }
$g = @(Get-GpuMemoryInfo)
if ($g.Count) { $out += "GPU[$($g[0].Index)] 总=$($g[0].TotalMB)MB 已用=$($g[0].UsedMB)MB 空闲=$($g[0].FreeMB)MB" }
else { $out += "GPU 检测失败" }
$m = Get-SystemMemoryInfo
$out += "内存 总=$($m.TotalMB)MB 可用=$($m.AvailableMB)MB"

$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\um-validate-result.txt' -Encoding utf8
