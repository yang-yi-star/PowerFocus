# um-restart64k.ps1 - 64K 上下文落地：重启 27B 并验证
$ErrorActionPreference = 'Stop'
$out = @()
$out += "pwsh: $($PSVersionTable.PSVersion.ToString())"

# 1. dot-source 扩展
. 'E:\PowerFocus\统一内存模式.ps1'

# 2. 启动（内部会先按 8080 端口停旧实例）
$proc = Start-UnifiedMemoryMode
if (-not $proc) { $out += '启动失败：Start-UnifiedMemoryMode 返回 null'; $out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\um-restart64k-result.txt' -Encoding utf8; exit 1 }
$out += "新 PID: $($proc.Id)"

# 3. 等 /health 就绪（最长 120 秒）
$healthOk = $false
for ($i = 0; $i -lt 120; $i++) {
    try {
        $h = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 3
        if ($h.status -eq 'ok') { $healthOk = $true; break }
    } catch { Start-Sleep -Seconds 1 }
}
$out += "health 就绪: $healthOk (等待 $i 秒)"

# 4. 验证进程命令行与内存
$p = Get-Process -Id $proc.Id
$cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)").CommandLine
$out += "命令行: $cmd"
$out += "进程内存 RSS: $([math]::Round($p.WorkingSet64/1GB,2)) GB"
$mem = Get-CimInstance Win32_OperatingSystem
$out += "系统可用内存: $([math]::Round($mem.FreePhysicalMemory/1MB,2)) GB / 总 $([math]::Round($mem.TotalVisibleMemorySize/1MB,2)) GB"
$gpu = (& nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits | Select-Object -First 1).Trim()
$out += "GPU 显存 used/free(MB): $gpu"

# 5. 快速一轮生成验证（256 token）
if ($healthOk) {
    $body = @{ prompt = 'The quick brown fox jumps over the lazy dog. Please continue this text.'; n_predict = 256; temperature = 0.7; stream = $false } | ConvertTo-Json
    $t1 = [DateTime]::Now
    $resp = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/completion' -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 600
    $t2 = [DateTime]::Now
    $el = ($t2 - $t1).TotalSeconds
    $out += "验证生成: $([math]::Round($el,1)) 秒 / 256 token = $([math]::Round(256/$el,2)) t/s"
    $len = if ($resp.content) { $resp.content.Length } else { 0 }
    $out += "响应文本长度: $len"
    $mem2 = Get-CimInstance Win32_OperatingSystem
    $out += "生成后系统可用内存: $([math]::Round($mem2.FreePhysicalMemory/1MB,2)) GB"
} else {
    $out += 'health 未就绪，跳过生成验证'
}

$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\um-restart64k-result.txt' -Encoding utf8
