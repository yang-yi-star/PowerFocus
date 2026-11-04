# mtp-phase1.ps1 - 测当前 8080（MTP 版）5 轮速度 + 1 轮翻译，每轮即时落盘
$ErrorActionPreference = 'Stop'
$resFile = 'E:\PowerFocus\mtp-phase1-result.txt'
$speedPrompt = 'The quick brown fox jumps over the lazy dog. Please continue this text for me.'
$qualityPrompt = @'
Translate the following English text into Chinese. Keep technical terms accurate and complete. Output only the Chinese translation.

Text: "NVIDIA's CUDA unified memory lets GPU and CPU share a single address space, automatically migrating pages between device memory and host memory. When VRAM is insufficient, allocations spill to system RAM without crashing, at the cost of bandwidth-bound performance. On Windows, this behavior is controlled by the Sysmem Fallback policy in the NVIDIA Control Panel. Local LLM users often disable it to avoid sudden slowdowns when VRAM approaches capacity."
'@
$u8 = New-Object System.Text.UTF8Encoding $false
function Log([string]$s) { [System.IO.File]::AppendAllText($resFile, $s + "`r`n", $u8) }

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

$pid0 = (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue)[0].OwningProcess
Log "===== phase1: MTP 版测速（8080 PID=$pid0, --spec-type draft-mtp --spec-draft-n-max 8） ====="
for ($i = 1; $i -le 5; $i++) {
    $r = Round-Run -Prompt $speedPrompt -NPredict 256 -Temp 0.7 -Tag "mtp-speed-$i"
    Log "速度轮$i : $($r.Tps) t/s (predicted=$($r.PredictedN), wall=$($r.WallSec)s)"
}
$q = Round-Run -Prompt $qualityPrompt -NPredict 512 -Temp 0.3 -Tag 'mtp-quality'
Log "翻译: predicted=$($q.PredictedN), wall=$($q.WallSec)s"
$q.Content | Set-Content -LiteralPath 'E:\PowerFocus\mtp-quality-mtp.txt' -Encoding utf8
Log '===== phase1 完成 ====='
