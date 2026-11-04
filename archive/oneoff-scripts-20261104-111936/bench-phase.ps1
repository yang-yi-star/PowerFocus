# bench-phase.ps1 v3 - 单阶段测量：3 次生成取 tokens/s 中位数；生成期间实时测 llama-server 占用核数/全机%
# 用法: pwsh -File bench-phase.ps1 -Phase baseline|gentle|aggressive
param(
    [Parameter(Mandatory = $true)][string]$Phase
)
$ErrorActionPreference = 'Stop'
$uri = 'http://127.0.0.1:8080/v1/completions'
$prompt = '请用中文写一段关于计算机算力调度原理的科普说明，要求条理清晰、逻辑完整，内容不少于两百字。'
$body = @{
    model = 'Qwen3.8-27B'
    prompt = $prompt
    max_tokens = 256
    temperature = 0.7
    top_k = 20
    top_p = 0.8
    presence_penalty = 1.5
    min_p = 0
}
$json = $body | ConvertTo-Json

function Get-Server {
    Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq 'E:\Program Files\llama.cpp\bin\llama-server.exe' } | Select-Object -First 1
}

$tpsList = @()
$wallList = @()
$coresList = @()
for ($i = 1; $i -le 3; $i++) {
    $s0 = Get-Server
    $cpu0 = if ($s0) { $s0.CPU } else { 0.0 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 600
    $sw.Stop()
    $s1 = Get-Server
    $cpu1 = if ($s1) { $s1.CPU } else { 0.0 }
    $tok = $resp.usage.completion_tokens
    $ms = $sw.ElapsedMilliseconds
    $secs = $ms / 1000.0
    $tps = [math]::Round($tok / $secs, 2)
    $cores = [math]::Round(($cpu1 - $cpu0) / $secs, 1)
    $tpsList += $tps
    $wallList += $ms
    $coresList += $cores
    Write-Output ("$Phase run$i tokens=$tok wall=$ms ms tps=$tps cores=$cores")
}

$server = Get-Server
$prio = if ($server) { $server.PriorityClass.ToString() } else { 'N/A' }
$plan = (powercfg /getactivescheme | Out-String)
if ($plan -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $planGuid = $Matches[1] } else { $planGuid = 'unknown' }
$demoted = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.PriorityClass -eq [System.Diagnostics.ProcessPriorityClass]::BelowNormal }).Count
$load = (Get-CimInstance Win32_Processor).LoadPercentage
$median = ($tpsList | Sort-Object)[1]
$avgCores = [math]::Round(($coresList | Measure-Object -Average).Average, 1)
$avgPct = [math]::Round(($avgCores / 32.0) * 100, 1)

$result = [PSCustomObject]@{
    phase = $Phase
    tps1 = $tpsList[0]; tps2 = $tpsList[1]; tps3 = $tpsList[2]
    median_tps = $median
    wall1_ms = $wallList[0]; wall2_ms = $wallList[1]; wall3_ms = $wallList[2]
    llama_cores = $avgCores
    llama_cpu_pct = $avgPct
    priority = $prio
    power_plan = $planGuid
    system_load_pct = $load
    demoted_count = $demoted
}
$result | ConvertTo-Json -Compress | Add-Content -LiteralPath 'E:\PowerFocus\bench-results.jsonl'
Write-Output ("$Phase DONE median_tps=$median llama_cores=$avgCores llama_cpu_pct=$avgPct priority=$prio plan=$planGuid sysload=$load demoted=$demoted")
