# mtp-phase2.ps1 - 停 MTP → 起基线 → 5 轮速度 + 1 轮翻译，每轮即时落盘
$ErrorActionPreference = 'Stop'
$resFile = 'E:\PowerFocus\mtp-phase2-result.txt'
$u8 = New-Object System.Text.UTF8Encoding $false
function Log([string]$s) { [System.IO.File]::AppendAllText($resFile, $s + "`r`n", $u8) }
$exe = 'E:\Program Files\llama.cpp\bin\llama-server.exe'
$model = 'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf'
$baseArgStr = '--model "{0}" --n-gpu-layers 20 --ctx-size 65536 --batch-size 512 --ubatch-size 128 --threads 32 --threads-batch 8 --cache-type-k q8_0 --cache-type-v q8_0 --host 127.0.0.1 --port 8080' -f $model
$speedPrompt = 'The quick brown fox jumps over the lazy dog. Please continue this text for me.'
$qualityPrompt = @'
Translate the following English text into Chinese. Keep technical terms accurate and complete. Output only the Chinese translation.

Text: "NVIDIA's CUDA unified memory lets GPU and CPU share a single address space, automatically migrating pages between device memory and host memory. When VRAM is insufficient, allocations spill to system RAM without crashing, at the cost of bandwidth-bound performance. On Windows, this behavior is controlled by the Sysmem Fallback policy in the NVIDIA Control Panel. Local LLM users often disable it to avoid sudden slowdowns when VRAM approaches capacity."
'@

function Round-Run {
    param([string]$Prompt, [int]$NPredict, [double]$Temp, [string]$Tag)
    $body = @{ prompt = $Prompt; n_predict = $NPredict; temperature = $Temp; stream = $false } | ConvertTo-Json
    $t0 = [DateTime]::Now
    $resp = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/completion' -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 900
    $t1 = [DateTime]::Now
    $wall = ($t1 - $t0).TotalSeconds
    $pn = [int]$resp.tokens_predicted
    if ($null -ne $resp.timings -and $resp.timings.predicted_per_second -gt 0) { $tps = [math]::Round($resp.timings.predicted_per_second, 2) } else { $tps = if ($wall -gt 0) { [math]::Round($pn / $wall, 2) } else { 0 } }
    return [pscustomobject]@{ Tag = $Tag; PredictedN = $pn; Tps = $tps; WallSec = [math]::Round($wall, 1); Content = $resp.content }
}

# 停 8080（MTP 实例）
$conn = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
if ($conn) { Log "停 MTP 实例 PID $($conn[0].OwningProcess)"; Stop-Process -Id ([int]$conn[0].OwningProcess) -Force; Start-Sleep -Seconds 3 }
Remove-Item -LiteralPath 'E:\PowerFocus\base-out.log','E:\PowerFocus\base-err.log' -Force -ErrorAction SilentlyContinue
$p = Start-Process -FilePath $exe -ArgumentList $baseArgStr -RedirectStandardOutput 'E:\PowerFocus\base-out.log' -RedirectStandardError 'E:\PowerFocus\base-err.log' -WindowStyle Hidden -PassThru
$ok = $false
for ($i = 0; $i -lt 120; $i++) {
    try { $h = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 2; if ($h.status -eq 'ok') { $ok = $true; break } } catch { Start-Sleep -Seconds 1 }
}
Start-Sleep -Seconds 2
Log "基线实例 PID=$($p.Id) health=$ok"
if (-not $ok) {
    if (Test-Path 'E:\PowerFocus\base-err.log') { Log (Get-Content -LiteralPath 'E:\PowerFocus\base-err.log' -Encoding utf8 -Tail 15 | Out-String) }
    Log 'phase2 FAILED'
    exit 1
}
Log "===== phase2: 基线测速（无投机解码） ====="
for ($i = 1; $i -le 5; $i++) {
    $r = Round-Run -Prompt $speedPrompt -NPredict 256 -Temp 0.7 -Tag "base-speed-$i"
    Log "速度轮$i : $($r.Tps) t/s (predicted=$($r.PredictedN), wall=$($r.WallSec)s)"
}
$q = Round-Run -Prompt $qualityPrompt -NPredict 512 -Temp 0.3 -Tag 'base-quality'
Log "翻译: predicted=$($q.PredictedN), wall=$($q.WallSec)s"
$q.Content | Set-Content -LiteralPath 'E:\PowerFocus\mtp-quality-base.txt' -Encoding utf8
Log '===== phase2 完成 ====='
