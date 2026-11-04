# sample-gen.ps1 - 单次生成，用进程 CPU 差值法测量 llama-server 平均占用核数/全机占比
param([Parameter(Mandatory = $true)][string]$Phase)
$ErrorActionPreference = 'Stop'
$uri = 'http://127.0.0.1:8080/v1/completions'
$body = @{ model = 'Qwen3.8-27B'; prompt = '请用中文写一段关于计算机算力调度原理的科普说明，要求条理清晰、逻辑完整，内容不少于两百字。'; max_tokens = 256; temperature = 0.7; top_k = 20; top_p = 0.8; presence_penalty = 1.5; min_p = 0 }
$json = $body | ConvertTo-Json

function Get-Server {
    Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq 'E:\Program Files\llama.cpp\bin\llama-server.exe' } | Select-Object -First 1
}

$s0 = Get-Server
$c0 = if ($s0) { $s0.CPU } else { 0.0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$resp = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 600
$sw.Stop()
$s1 = Get-Server
$c1 = if ($s1) { $s1.CPU } else { 0.0 }

$tok = $resp.usage.completion_tokens
$secs = $sw.ElapsedMilliseconds / 1000.0
$tps = [math]::Round($tok / $secs, 2)
$cores = [math]::Round(($c1 - $c0) / $secs, 1)
$pct = [math]::Round(($cores / 32.0) * 100, 1)
$result = "phase=$Phase tps=$tps tokens=$tok wall_ms=$($sw.ElapsedMilliseconds) llama_cores=$cores llama_cpu_pct=$pct"
$result | Add-Content -LiteralPath 'E:\PowerFocus\cpu-sample-results.txt' -Encoding utf8
Set-Content -LiteralPath 'E:\PowerFocus\last-sample.txt' -Value $result -Encoding utf8
Write-Output $result
