$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$Exe      = 'E:\Program Files\llama.cpp\bin\llama-server.exe'
$BaseIni  = 'E:\PowerFocus\v3\models-preset.ini'
$CalibIni = 'E:\PowerFocus\v3\logs\calib-preset.ini'
$LogFile  = 'E:\PowerFocus\v3\logs\vram-calib.log'
$CsvFile  = 'E:\PowerFocus\v3\logs\vram-calib.csv'
$Maint    = 'E:\PowerFocus\v3\.maintenance'
$CalibPort = 8099
$MainPort  = 8080

function Log([string]$msg, [string]$level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
    Write-Host $line
}

function Stop-AllServers {
    Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; Log "stopped pid=$($_.Id)" } catch { }
    }
    Start-Sleep -Seconds 3
}

function Wait-Health([int]$port, [int]$timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2 | Out-Null
            return $true
        } catch {
            Start-Sleep -Milliseconds 800
        }
    }
    return $false
}

function Start-Router([string]$ini, [int]$port, [switch]$WaitReady) {
    $args = '--models-preset "{0}" --models-max 1 --sleep-idle-seconds 999999 --host 127.0.0.1 --port {1} --parallel 1' -f $ini, $port
    Start-Process -FilePath $Exe -ArgumentList $args -WindowStyle Hidden
    if ($WaitReady) { return (Wait-Health $port 90) }
    return $true
}

function Measure-Candidate([string]$modelId) {
    $body = @{
        model      = $modelId
        messages   = @(@{ role = 'user'; content = 'Write about 40 words describing a calm ocean at dawn.' })
        max_tokens = 64
        stream     = $false
        temperature = 0.7
    } | ConvertTo-Json -Depth 5

    $tps = @()
    for ($i = 1; $i -le 3; $i++) {
        try {
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$CalibPort/v1/chat/completions" `
                -Method Post -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 300
            $p = $resp.timings.predicted_per_second
            if ($p) { $tps += [double]$p }
            if ($i -eq 1) { Start-Sleep -Milliseconds 300 }
        } catch {
            return @{ ok = $false; tps = 0; error = $_.Exception.Message }
        }
    }
    if ($tps.Count -eq 0) { return @{ ok = $false; tps = 0; error = 'no timings' } }
    $sorted = $tps | Sort-Object
    $median = if ($sorted.Count -ge 3) { $sorted[1] } else { $sorted[0] }
    return @{ ok = $true; tps = [math]::Round($median, 2); error = '' }
}

function Get-VramMb {
    try {
        $out = & nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>$null
        if ($out) { return ($out -split ',')[0].Trim() }
    } catch { }
    return 'n/a'
}

# ---------------------------------------------------------------- 候选矩阵
$Jobs = @(
    @{ id = 'Qwen3-14B';    path = 'D:\Models\gguf\Qwen3-14B-Q4_K_M.gguf';                  ngls = @(18, 22, 26) }
    @{ id = 'Qwen3-8B';     path = 'D:\计算机知识库中心\90-Projects-Code\.assistant\models\qwen3-8b-q4_k_m.gguf'; ngls = @(24, 30, 99) }
    @{ id = 'Qwen2.5-7B';   path = 'D:\openhua\老D\tianet\models\qwen2.5-7b-q4_k_m.gguf';    ngls = @(20, 24, 99) }
    @{ id = 'Heita-F16';    path = 'D:\heita_work\heita-fp16.gguf';                          ngls = @(20, 24, 99) }
    @{ id = 'Qwen3-4B';     path = 'D:\heita_models\qwen3-4b-instruct-q4_k_m.gguf';          ngls = @(24, 99) }
    @{ id = 'Heita';        path = 'D:\heita_models\heita-q4_k_m.gguf';                      ngls = @(24, 99) }
    @{ id = 'Qwen2.5-0.5B'; path = 'D:\Model_Zone\qwen2.5-0.5b-instruct-q4_k_m.gguf';        ngls = @(16, 99) }
)

Log '=== 显存校准开始（router 模式） ==='

New-Item -ItemType File -Path $Maint -Force | Out-Null
Log '维护窗口已开启（看门狗暂停）'

Stop-AllServers

# ---------------------------------------------------------------- 生成校准预设
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('version = 1')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('[*]')
[void]$sb.AppendLine('threads = 16')
[void]$sb.AppendLine('threads-batch = 8')
[void]$sb.AppendLine('c = 8192')
[void]$sb.AppendLine('parallel = 1')
[void]$sb.AppendLine('flash-attn = on')
[void]$sb.AppendLine('cache-type-k = q8_0')
[void]$sb.AppendLine('cache-type-v = f16')
[void]$sb.AppendLine('')

foreach ($job in $Jobs) {
    foreach ($ngl in $job.ngls) {
        [void]$sb.AppendLine(('[{0}@{1}]' -f $job.id, $ngl))
        [void]$sb.AppendLine(('model = {0}' -f $job.path))
        [void]$sb.AppendLine(('n-gpu-layers = {0}' -f $ngl))
        [void]$sb.AppendLine('')
    }
}
Set-Content -LiteralPath $CalibIni -Value $sb.ToString() -Encoding utf8
Log "校准预设已生成: $CalibIni"

if (-not (Start-Router -ini $CalibIni -port $CalibPort -WaitReady)) {
    Log '校准服务启动失败' 'FAIL'
    exit 1
}
Log '校准服务已就绪 (port 8099)'

# ---------------------------------------------------------------- 逐候选实测
$results = @()
foreach ($job in $Jobs) {
    foreach ($ngl in $job.ngls) {
        $mid = '{0}@{1}' -f $job.id, $ngl
        Log "测试 $mid ..."
        $r = Measure-Candidate -modelId $mid
        $vram = Get-VramMb
        if ($r.ok) {
            Log ("  {0} -> {1} t/s, VRAM used {2} MiB" -f $mid, $r.tps, $vram)
            $results += [pscustomobject]@{ model = $job.id; ngl = $ngl; tps = $r.tps; vram_mb = $vram; ok = $true; note = '' }
        } else {
            Log ("  {0} -> 失败: {1}" -f $mid, $r.error) 'FAIL'
            $results += [pscustomobject]@{ model = $job.id; ngl = $ngl; tps = 0; vram_mb = $vram; ok = $false; note = $r.error }
        }
        # 卸载释放显存，保证下一次测量是干净基线
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$CalibPort/models/unload" -Method Post `
                -ContentType 'application/json' -Body (@{ model = $mid } | ConvertTo-Json) -TimeoutSec 60 | Out-Null
        } catch { }
        Start-Sleep -Seconds 2
    }
}

$results | Export-Csv -LiteralPath $CsvFile -NoTypeInformation -Encoding utf8
Log "结果已写入 $CsvFile"

# ---------------------------------------------------------------- 选出每个模型的最佳 ngl
$best = @{}
foreach ($job in $Jobs) {
    $okRows = $results | Where-Object { $_.model -eq $job.id -and $_.ok }
    if ($okRows) {
        $pick = $okRows | Sort-Object tps -Descending | Select-Object -First 1
        $best[$job.id] = $pick
        Log ("最佳: {0} ngl={1} t/s={2} VRAM={3}MiB" -f $job.id, $pick.ngl, $pick.tps, $pick.vram_mb)
    } else {
        $best[$job.id] = $null
        Log ("{0} 全部候选失败，保留原参数" -f $job.id) 'FAIL'
    }
}

# ---------------------------------------------------------------- 写回正式预设
Stop-AllServers

$final = @'
; PowerFocus 本地模型预设（llama-server router 模式）
; 由调度中心统一启动；--models-max 1 保证 8GB 显卡一次只驻留一个模型
; section 名 = OpenAI 兼容接口里的 model id，必须与 IDE 自定义模型条目一致
; n-gpu-layers 数值为 2026-11-04 显存校准实测结果

version = 1

[*]
threads = 16
threads-batch = 8
c = 8192
parallel = 1
n-gpu-layers = 99

[Qwen3.8-27B]
model = E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf
n-gpu-layers = 23
c = 8192
flash-attn = on
cache-type-k = q8_0
cache-type-v = f16
load-on-startup = true

'@

$entries = @(
    @{ id = 'Qwen3-14B';    path = 'D:\Models\gguf\Qwen3-14B-Q4_K_M.gguf'; default = 22 },
    @{ id = 'Qwen3-8B';     path = 'D:\计算机知识库中心\90-Projects-Code\.assistant\models\qwen3-8b-q4_k_m.gguf'; default = 30 },
    @{ id = 'Qwen2.5-7B';   path = 'D:\openhua\老D\tianet\models\qwen2.5-7b-q4_k_m.gguf'; default = 24 },
    @{ id = 'Heita-F16';    path = 'D:\heita_work\heita-fp16.gguf'; default = 24 },
    @{ id = 'Qwen3-4B';     path = 'D:\heita_models\qwen3-4b-instruct-q4_k_m.gguf'; default = 99 },
    @{ id = 'Heita';        path = 'D:\heita_models\heita-q4_k_m.gguf'; default = 99 },
    @{ id = 'Qwen2.5-0.5B'; path = 'D:\Model_Zone\qwen2.5-0.5b-instruct-q4_k_m.gguf'; default = 99 }
)

foreach ($e in $entries) {
    $ngl = $e.default
    if ($best[$e.id]) { $ngl = $best[$e.id].ngl }
    $final += ("[{0}]`nmodel = {1}`nn-gpu-layers = {2}`nc = 8192`nflash-attn = on`ncache-type-k = q8_0`ncache-type-v = f16`n`n" -f $e.id, $e.path, $ngl)
}

Set-Content -LiteralPath $BaseIni -Value $final -Encoding utf8
Log "正式预设已更新: $BaseIni"

# ---------------------------------------------------------------- 恢复正式服务
$routerCmd = '"E:\Program Files\llama.cpp\bin\llama-server.exe" --models-preset "E:\PowerFocus\v3\models-preset.ini" --models-max 1 --sleep-idle-seconds 600 --host 127.0.0.1 --port 8080 --parallel 1'
Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $routerCmd } | Out-Null

if (Wait-Health $MainPort 120) {
    Log '正式 router 已恢复 (port 8080)'
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:$MainPort/models/load" -Method Post `
            -ContentType 'application/json' -Body (@{ model = 'Qwen3.8-27B' } | ConvertTo-Json) -TimeoutSec 180 | Out-Null
        Log '27B 已预载'
    } catch { Log "27B 预载失败: $($_.Exception.Message)" 'FAIL' }
} else {
    Log '正式 router 恢复失败' 'FAIL'
}

Remove-Item $Maint -Force -ErrorAction SilentlyContinue
Log '维护窗口已关闭'

# 看门狗若不在则拉起
$wd = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -like '*llama-monitor.ps1*' }
if (-not $wd) {
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = '"C:\Tools\PowerShell7\pwsh.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "E:\Program Files\llama.cpp\scripts\llama-monitor.ps1"'
    } | Out-Null
    Log '看门狗已拉起'
} else {
    Log ("看门狗在运行 pid=" + $wd.ProcessId)
}

Log '=== 显存校准结束 ==='
