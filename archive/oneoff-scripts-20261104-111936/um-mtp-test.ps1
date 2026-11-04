# um-mtp-test.ps1 - MTP 投机解码加速对比验证（速度 + 质量）
$ErrorActionPreference = 'Stop'
$out = @()
$exe = 'E:\Program Files\llama.cpp\bin\llama-server.exe'
$model = 'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf'
function Get-BaseArgStr { return '--model "{0}" --n-gpu-layers 20 --ctx-size 65536 --batch-size 512 --ubatch-size 128 --threads 32 --threads-batch 8 --cache-type-k q8_0 --cache-type-v q8_0 --host 127.0.0.1 --port 8080' -f $model }
function Get-MtpArgStr { return (Get-BaseArgStr) + ' --spec-type draft-mtp --spec-draft-n-max 8' }

$speedPrompt = 'The quick brown fox jumps over the lazy dog. Please continue this text for me.'
$qualityPrompt = @'
Translate the following English text into Chinese. Keep technical terms accurate and complete. Output only the Chinese translation.

Text: "NVIDIA's CUDA unified memory lets GPU and CPU share a single address space, automatically migrating pages between device memory and host memory. When VRAM is insufficient, allocations spill to system RAM without crashing, at the cost of bandwidth-bound performance. On Windows, this behavior is controlled by the Sysmem Fallback policy in the NVIDIA Control Panel. Local LLM users often disable it to avoid sudden slowdowns when VRAM approaches capacity."
'@

function Invoke-CompletionRound {
    param([string]$Prompt, [int]$NPredict, [double]$Temp, [string]$Tag)
    $body = @{ prompt = $Prompt; n_predict = $NPredict; temperature = $Temp; stream = $false } | ConvertTo-Json
    $t0 = [DateTime]::Now
    $resp = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/completion' -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 900
    $t1 = [DateTime]::Now
    $wall = ($t1 - $t0).TotalSeconds
    $pn = [int]$resp.tokens_predicted
    if ($null -ne $resp.timings -and $resp.timings.predicted_per_second -gt 0) {
        $tps = [math]::Round($resp.timings.predicted_per_second, 2)
        $pms = [double]$resp.timings.predicted_ms
    } else {
        $tps = if ($wall -gt 0) { [math]::Round($pn / $wall, 2) } else { 0 }
        $pms = $wall * 1000
    }
    return [pscustomobject]@{ Tag = $Tag; PredictedN = $pn; PredictedMs = $pms; Tps = $tps; WallSec = [math]::Round($wall, 1); Content = $resp.content }
}

function Wait-Health {
    for ($i = 0; $i -lt 120; $i++) {
        try { $h = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 2; if ($h.status -eq 'ok') { return $true } } catch { Start-Sleep -Seconds 1 }
    }
    return $false
}

function Switch-Server {
    param([string]$ArgStr, [string]$Tag)
    # 停 8080 当前实例
    $conn = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
    if ($conn) { Stop-Process -Id ([int]$conn[0].OwningProcess) -Force; Start-Sleep -Seconds 3 }
    Remove-Item -LiteralPath "E:\PowerFocus\mtp-$Tag-out.log","E:\PowerFocus\mtp-$Tag-err.log" -Force -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $exe -ArgumentList $ArgStr -RedirectStandardOutput "E:\PowerFocus\mtp-$Tag-out.log" -RedirectStandardError "E:\PowerFocus\mtp-$Tag-err.log" -WindowStyle Hidden -PassThru
    $ok = Wait-Health
    Start-Sleep -Seconds 2
    return [pscustomobject]@{ Pid = $p.Id; Health = $ok }
}

# ---------- 阶段 A：基线（当前实例，无 spec） ----------
$out += '===== 阶段 A：基线（无投机解码） ====='
$out += "基线实例 PID: $((Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue)[0].OwningProcess)"
$out += '--- 速度 5 轮 ---'
$speedR = @()
for ($i = 1; $i -le 5; $i++) {
    $r = Invoke-CompletionRound -Prompt $speedPrompt -NPredict 256 -Temp 0.7 -Tag "base-speed-$i"
    $speedR += $r
    $out += "轮$i : $($r.Tps) t/s (predicted=$($r.PredictedN), wall=$($r.WallSec)s)"
}
$baseTpsAvg = [math]::Round(($speedR | Measure-Object -Property Tps -Average).Average, 2)
$out += "基线平均: $baseTpsAvg t/s"
$out += '--- 质量 1 轮（翻译） ---'
$qBase = Invoke-CompletionRound -Prompt $qualityPrompt -NPredict 512 -Temp 0.3 -Tag 'base-quality'
$out += "基线翻译完成: predicted=$($qBase.PredictedN), wall=$($qBase.WallSec)s"
$qBase.Content | Set-Content -LiteralPath 'E:\PowerFocus\mtp-quality-base.txt' -Encoding utf8

# ---------- 阶段 B：切换 MTP 版 ----------
$out += ''
$out += '===== 阶段 B：MTP 投机解码（--spec-type draft-mtp --spec-draft-n-max 8） ====='
$s = Switch-Server -ArgStr (Get-MtpArgStr) -Tag 'mtp'
$out += "MTP 实例: PID=$($s.Pid), health=$($s.Health)"
if (-not $s.Health) {
    $out += 'MTP 版启动失败，读取日志尾部：'
    if (Test-Path "E:\PowerFocus\mtp-mtp-err.log") { $out += Get-Content -LiteralPath "E:\PowerFocus\mtp-mtp-err.log" -Encoding utf8 -Tail 15 }
    $out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\um-mtp-result.txt' -Encoding utf8
    exit 1
}
$out += '--- 速度 5 轮 ---'
$speedM = @()
for ($i = 1; $i -le 5; $i++) {
    $r = Invoke-CompletionRound -Prompt $speedPrompt -NPredict 256 -Temp 0.7 -Tag "mtp-speed-$i"
    $speedM += $r
    $out += "轮$i : $($r.Tps) t/s (predicted=$($r.PredictedN), wall=$($r.WallSec)s)"
}
$mtpTpsAvg = [math]::Round(($speedM | Measure-Object -Property Tps -Average).Average, 2)
$out += "MTP 平均: $mtpTpsAvg t/s"
$out += '--- 质量 1 轮（翻译） ---'
$qMtp = Invoke-CompletionRound -Prompt $qualityPrompt -NPredict 512 -Temp 0.3 -Tag 'mtp-quality'
$out += "MTP 翻译完成: predicted=$($qMtp.PredictedN), wall=$($qMtp.WallSec)s"
$qMtp.Content | Set-Content -LiteralPath 'E:\PowerFocus\mtp-quality-mtp.txt' -Encoding utf8

# ---------- 汇总 ----------
$out += ''
$out += "速度对比：基线 $baseTpsAvg t/s vs MTP $mtpTpsAvg t/s（变化 $([math]::Round(($mtpTpsAvg/$baseTpsAvg-1)*100,1))%）"
$mem = Get-CimInstance Win32_OperatingSystem
$out += "当前系统可用: $([math]::Round($mem.FreePhysicalMemory/1MB,2))GB"
$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\um-mtp-result.txt' -Encoding utf8
