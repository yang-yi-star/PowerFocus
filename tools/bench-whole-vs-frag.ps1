# 整体 vs 被扯：同一 llama-server 配置，对比"独占整机"与"多应用争抢"的 tok/s
# 用法：pwsh -File bench-whole-vs-frag.ps1 -Mode frag|whole
param([ValidateSet('frag','whole')][string]$Mode = 'frag')

$ErrorActionPreference = 'Continue'
$exe   = 'E:\Program Files\llama.cpp\bin\llama-server.exe'
$model = 'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf'
$port  = 8089
$ngl   = 20
$ctx   = 2048

# ---------- 1. 清理旧的 ----------
Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" |
  Where-Object { $_.CommandLine -match "port $port" } |
  ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
Start-Sleep -Seconds 2

# ---------- 2. 起 llama-server ----------
$logDir = 'E:\PowerFocus\docs'
$stdout = Join-Path $logDir "whole-$Mode-server.out.log"
$stderr = Join-Path $logDir "whole-$Mode-server.err.log"
"起 llama-server: ngl=$ngl port=$port ctx=$ctx"
$psi = @{
  FilePath = $exe
  ArgumentList = @('-m', $model, '--host', '127.0.0.1', '--port', "$port",
                   '-ngl', "$ngl", '-c', "$ctx", '-t', '16', '--no-webui')
  RedirectStandardOutput = $stdout
  RedirectStandardError  = $stderr
  WindowStyle = 'Hidden'
  PassThru = $true
}
$proc = Start-Process @psi
"PID = $($proc.Id)"

# 等就绪
$ready = $false
for ($i = 0; $i -lt 180; $i++) {
  Start-Sleep -Seconds 2
  try { $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -TimeoutSec 3 -ErrorAction Stop
        if ($r.Content -match 'ok') { $ready = $true; break } } catch {}
  if ($i % 10 -eq 0) { "  等待就绪 $([math]::Round(($i*2)/60,1)) 分钟..." }
}
if (-not $ready) {
  "❌ 180 次探测未就绪，看日志: $stderr"
  Get-Content -LiteralPath $stderr -Tail 20 -Encoding UTF8
  exit 1
}
"✓ 就绪"

# ---------- 3. 制造竞争（仅 frag 模式） ----------
$loadProcs = @()
if ($Mode -eq 'frag') {
  "制造竞争：16 个 CPU 满核线程 + 内存占用"
  for ($i = 0; $i -lt 16; $i++) {
    $sb = { $x = 1.0; while ($true) { $x = [math]::Sqrt($x + 1.0) } }.ToString()
    $lp = Start-Process -FilePath 'C:\Tools\PowerShell7\pwsh.EXE' -ArgumentList @('-NoProfile','-Command', $sb) -WindowStyle Hidden -PassThru
    $loadProcs += $lp
  }
  "  已起 $($loadProcs.Count) 个 CPU 抢占进程"
} else {
  "整体模式：用 PowerFocus 清场，压低所有非关键进程"
  $k = 'E:\PowerFocus\versions\v0.11\电脑算力调度中心_v0.11.ps1'
  . $k
  $r = Invoke-CommandObject @{ action='request_power'; pid=$proc.Id; level='aggressive'; duration=900; reason='整体基准测试' }
  "  $r"
}

# ---------- 4. 测 3 轮 ----------
function Invoke-Gen {
  $body = @{
    prompt = '用一句话解释什么是统一内存架构。'
    n_predict = 128
    temperature = 0.2
    stream = $false
  } | ConvertTo-Json -Depth 3
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = Invoke-RestMethod -Uri "http://127.0.0.1:$port/completion" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 600
  $sw.Stop()
  return @{
    tokens = $r.tokens_predicted
    tg     = [math]::Round($r.tokens_predicted / ($r.timings.predicted_per_second | ForEach-Object { if ($_ -gt 0) { 1 } else { 1 } }), 2)
    pred_per_s = [math]::Round($r.timings.predicted_per_second, 2)
    prompt_per_s = [math]::Round($r.timings.prompt_per_second, 2)
    wall_s = [math]::Round($sw.Elapsed.TotalSeconds, 2)
  }
}

"`n=== 测速（mode=$Mode）==="
$rows = @()
for ($i = 1; $i -le 3; $i++) {
  try {
    $g = Invoke-Gen
    "  [轮 $i] tg=$($g.pred_per_s) tok/s  pp=$($g.prompt_per_s) tok/s  tokens=$($g.tokens)  wall=$($g.wall_s)s"
    $rows += $g
  } catch { "  [轮 $i] 失败: $($_.Exception.Message)" }
}

# ---------- 5. 汇总 ----------
if ($rows.Count -gt 0) {
  $avg = ($rows | Measure-Object -Property pred_per_s -Average).Average
  "`n--- mode=$Mode 平均 tg: $([math]::Round($avg,2)) tok/s（$($rows.Count) 轮）---"
  @{ mode = $Mode; ngl = $ngl; avg_tg = [math]::Round($avg,2); rows = $rows } |
    ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath (Join-Path $logDir "whole-$Mode-result.json") -Encoding UTF8
}

# ---------- 6. 收尾 ----------
if ($Mode -eq 'frag') {
  $loadProcs | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }
  "已停 $(($loadProcs).Count) 个竞争进程"
}
try {
  $k2 = 'E:\PowerFocus\versions\v0.11\电脑算力调度中心_v0.11.ps1'
  . $k2
  Invoke-CommandObject @{ action='release_power'; pid=$proc.Id } | Out-Null
  "已释放算力（还原其他进程优先级）"
} catch { "释放失败: $_" }
try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop; "已停 llama-server" } catch {}
