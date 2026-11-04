# E1 模型参数扫描：固定 prompt、重启 llama-server、采集 tokens/s / 显存 / 内存
# 用法:
#   pwsh -File run-e1.ps1 -Names baseline,ngl22,ngl23,ngl24
#   pwsh -File run-e1.ps1 -RestoreOnly
param(
    [string[]]$Names = @('baseline', 'ngl22', 'ngl23', 'ngl24'),
    [switch]$RestoreOnly,
    [switch]$SkipBus,
    [int]$Tokens = 64
)

$ErrorActionPreference = 'Stop'

# 兼容 pwsh -File 传参：-Names a,b,c 会被当成一个字符串
if ($Names.Count -eq 1 -and $Names[0] -match ',') {
    $Names = $Names[0] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

$Root        = 'E:\PowerFocus\v3\e1'
$LogDir      = Join-Path $Root 'logs'
$ResultFile  = Join-Path $Root 'results.jsonl'
$SummaryFile = Join-Path $Root 'summary.txt'
$RunLog      = Join-Path $Root 'e1-run.log'

$ServerExe   = 'E:\Program Files\llama.cpp\bin\llama-server.exe'
$ModelPath   = 'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf'
$Port        = 8080
$TaskName    = 'Qwen3.8-LlamaMonitor'
$MonitorScript = 'E:\Program Files\llama.cpp\scripts\llama-monitor.ps1'
$CmdRoot     = 'E:\PowerFocus\commands'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-E1Log {
    param([string]$Message)
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $Message
    Add-Content -LiteralPath $RunLog -Value $line -Encoding utf8
    Write-Output $line
}

function Invoke-BusAction {
    param([string]$Action)
    $name = 'e1-' + $Action + '-' + (Get-Date -Format 'HHmmssfff')
    $inPath = Join-Path $CmdRoot ('in\' + $name + '.json')
    $donePath = Join-Path $CmdRoot ('done\' + $name + '.json.result.txt')
    New-Item -ItemType Directory -Force -Path (Join-Path $CmdRoot 'in') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $CmdRoot 'done') | Out-Null
    @{ action = $Action } | ConvertTo-Json | Set-Content -LiteralPath $inPath -Encoding utf8
    for ($i = 0; $i -lt 40; $i++) {
        if (Test-Path -LiteralPath $donePath) {
            return (Get-Content -LiteralPath $donePath -Raw -Encoding utf8).Trim()
        }
        Start-Sleep -Milliseconds 500
    }
    return 'BUS_TIMEOUT'
}

function Stop-LlamaServer {
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conns) {
        $pids = $conns | Select-Object -ExpandProperty OwningProcess -Unique
        foreach ($id in $pids) {
            try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
    for ($i = 0; $i -lt 60; $i++) {
        $listen = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if (-not $listen) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Stop-MonitorStack {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        try { Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null; Write-E1Log "已禁用计划任务 $TaskName" } catch { Write-E1Log "禁用计划任务失败: $($_.Exception.Message)" }
        try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop; Write-E1Log "已停止计划任务 $TaskName" } catch { Write-E1Log "停止计划任务失败: $($_.Exception.Message)" }
    }
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*llama-monitor.ps1*' } |
        ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
    $ok = Stop-LlamaServer
    Write-E1Log "停止 8080 llama-server: $ok"
    Start-Sleep -Seconds 3
}

function Restore-MonitorStack {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        try { Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null; Write-E1Log "已重新启用计划任务 $TaskName" } catch { Write-E1Log "启用计划任务失败: $($_.Exception.Message)" }
        try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop; Write-E1Log "已启动计划任务 $TaskName" } catch { Write-E1Log "启动计划任务失败: $($_.Exception.Message)" }
    } else {
        Start-Process -FilePath 'C:\Tools\PowerShell7\pwsh.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $MonitorScript + '"') -WindowStyle Hidden
        Write-E1Log '计划任务不存在，已手动启动 llama-monitor'
    }
    # 等 monitor 拉起 server 并完成加载
    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
        try {
            $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3
            if ($h.status -eq 'ok') { $ready = $true; break }
        } catch { }
        Start-Sleep -Seconds 2
    }
    Write-E1Log "恢复后 /health 就绪: $ready"
}

function Wait-Health {
    param([int]$TimeoutSec = 240, [int]$ProcId = 0)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ($ProcId -gt 0 -and -not (Get-Process -Id $ProcId -ErrorAction SilentlyContinue)) { return $false }
        try {
            $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3
            if ($h.status -eq 'ok') { return $true }
        } catch { }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Invoke-Gen {
    param([string]$Prompt, [int]$Tokens)
    $body = @{
        prompt = $Prompt
        n_predict = $Tokens
        temperature = 0.1
        top_k = 10
        top_p = 0.9
        stream = $false
        cache_prompt = $false
    } | ConvertTo-Json
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 600
    $sw.Stop()
    $t = $resp.timings
    $gen = if ($t -and $t.predicted_per_second) { [double]$t.predicted_per_second } else { 0.0 }
    $promptTps = if ($t -and $t.prompt_per_second) { [double]$t.prompt_per_second } else { 0.0 }
    return [pscustomobject]@{
        gen_tps = [math]::Round($gen, 2)
        prompt_tps = [math]::Round($promptTps, 2)
        wall_ms = [int]$sw.ElapsedMilliseconds
        tokens = if ($t) { [int]$t.predicted_n } else { 0 }
        content = if ($resp.content) { [string]$resp.content } else { '' }
    }
}

function Get-GpuInfo {
    $line = (& nvidia-smi --query-gpu=memory.total,memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
    if (-not $line) { return @{ total = 0; used = 0; free = 0; temp = 0; util = 0 } }
    $parts = $line -split ',' | ForEach-Object { $_.Trim() }
    return @{ total = [int]$parts[0]; used = [int]$parts[1]; free = [int]$parts[2]; temp = [int]$parts[3]; util = [int]$parts[4] }
}

function Get-FreeRamGB {
    $os = Get-CimInstance Win32_OperatingSystem
    return [math]::Round($os.FreePhysicalMemory / 1MB, 2)
}

$Variants = [ordered]@{
    'baseline'        = @{ ngl = '20'; fa = 'off'; ctx = '8192';  ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl22'           = @{ ngl = '22'; fa = 'off'; ctx = '8192';  ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl23'           = @{ ngl = '23'; fa = 'off'; ctx = '8192';  ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl24'           = @{ ngl = '24'; fa = 'off'; ctx = '8192';  ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'baseline_fa_on'  = @{ ngl = '20'; fa = 'on';  ctx = '8192';  ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl22_fa_on'     = @{ ngl = '22'; fa = 'on';  ctx = '8192';  ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ctx16k'          = @{ ngl = '20'; fa = 'off'; ctx = '16384'; ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ctv_q8'          = @{ ngl = '20'; fa = 'off'; ctx = '8192';  ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'threads14'       = @{ ngl = '20'; fa = 'off'; ctx = '8192';  ctk = 'q8_0'; ctv = 'f16'; t = '14'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'tb4'             = @{ ngl = '20'; fa = 'off'; ctx = '8192';  ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '4'; batch = $null; ubatch = $null; lm = $null }
    'ngl23_fa_on'     = @{ ngl = '23'; fa = 'on';  ctx = '8192';  ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl22_ctx16k'    = @{ ngl = '22'; fa = 'off'; ctx = '16384'; ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl22_ctv_q8'    = @{ ngl = '22'; fa = 'off'; ctx = '8192';  ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl22_t14'       = @{ ngl = '22'; fa = 'off'; ctx = '8192';  ctk = 'q8_0'; ctv = 'f16'; t = '14'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl22_tb4'       = @{ ngl = '22'; fa = 'off'; ctx = '8192';  ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '4'; batch = $null; ubatch = $null; lm = $null }
    'ngl23_ctv_q8'    = @{ ngl = '23'; fa = 'off'; ctx = '8192';  ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl23_fa_on_ctv_q8' = @{ ngl = '23'; fa = 'on'; ctx = '8192'; ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl24_fa_on'        = @{ ngl = '24'; fa = 'on'; ctx = '8192'; ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl25_fa_on'        = @{ ngl = '25'; fa = 'on'; ctx = '8192'; ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl26_fa_on'        = @{ ngl = '26'; fa = 'on'; ctx = '8192'; ctk = 'q8_0'; ctv = 'f16'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl24_fa_on_ctv_q8' = @{ ngl = '24'; fa = 'on'; ctx = '8192'; ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl25_fa_on_ctv_q8' = @{ ngl = '25'; fa = 'on'; ctx = '8192'; ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl26_fa_on_ctv_q8' = @{ ngl = '26'; fa = 'on'; ctx = '8192'; ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl27_fa_on_ctv_q8' = @{ ngl = '27'; fa = 'on'; ctx = '8192'; ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl18_fa_on_ctv_q8_ctx64k' = @{ ngl = '18'; fa = 'on'; ctx = '65536'; ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl19_fa_on_ctv_q8_ctx64k' = @{ ngl = '19'; fa = 'on'; ctx = '65536'; ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl20_fa_on_ctv_q8_ctx64k' = @{ ngl = '20'; fa = 'on'; ctx = '65536'; ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl21_fa_on_ctv_q8_ctx64k' = @{ ngl = '21'; fa = 'on'; ctx = '65536'; ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl22_fa_on_ctv_q8_ctx64k' = @{ ngl = '22'; fa = 'on'; ctx = '65536'; ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl23_fa_on_ctv_q8_ctx64k' = @{ ngl = '23'; fa = 'on'; ctx = '65536'; ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
    'ngl24_fa_on_ctv_q8_ctx64k' = @{ ngl = '24'; fa = 'on'; ctx = '65536'; ctk = 'q8_0'; ctv = 'q8_0'; t = '16'; tb = '8'; batch = $null; ubatch = $null; lm = $null }
}

$WarmPrompt = '请只回答两个字：测试。'
$MeasurePrompt = '请用中文简要说明什么是计算机算力调度，并给出一个生活中的类比。'

function Start-And-Measure {
    param([string]$Name, $V)

    $outLog = Join-Path $LogDir ($Name + '.out.log')
    $errLog = Join-Path $LogDir ($Name + '.err.log')
    Remove-Item -LiteralPath $outLog, $errLog -Force -ErrorAction SilentlyContinue

    $parts = @(
        '-m', ('"' + $ModelPath + '"'),
        '-ngl', $V.ngl,
        '-fa', $V.fa,
        '-c', $V.ctx,
        '--cache-type-k', $V.ctk,
        '--cache-type-v', $V.ctv,
        '-t', $V.t,
        '-tb', $V.tb,
        '--temp', '0.7',
        '--top-k', '20',
        '--top-p', '0.8',
        '--presence-penalty', '1.5',
        '--min-p', '0',
        '--host', '127.0.0.1',
        '--port', "$Port",
        '--parallel', '1',
        '--alias', 'Qwen3.8-27B'
    )
    if ($null -ne $V.batch) { $parts += @('-b', [string]$V.batch) }
    if ($null -ne $V.ubatch) { $parts += @('-ub', [string]$V.ubatch) }
    if ($null -ne $V.lm) { $parts += @('-lm', [string]$V.lm) }
    $argString = $parts -join ' '

    Write-E1Log "启动 $Name : $argString"
    $swLoad = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $ServerExe -ArgumentList $argString -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $health = Wait-Health -TimeoutSec 90 -ProcId $proc.Id
    $swLoad.Stop()
    $loadSec = [math]::Round($swLoad.Elapsed.TotalSeconds, 1)

    if (-not $health) {
        $alive = $false
        try { $alive = -not (Get-Process -Id $proc.Id -ErrorAction Stop).HasExited } catch { $alive = $false }
        $errTail = ''
        if (Test-Path -LiteralPath $errLog) { $errTail = (Get-Content -LiteralPath $errLog -Tail 40 -Encoding utf8) -join ' | ' }
        $rec = [ordered]@{
            time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            variant = $Name
            status = 'FAIL_HEALTH'
            load_sec = $loadSec
            process_alive = $alive
            args = $argString
            error = $errTail
        }
        $rec | ConvertTo-Json -Compress | Add-Content -LiteralPath $ResultFile -Encoding utf8
        Write-E1Log "$Name FAIL_HEALTH load=$loadSec alive=$alive"
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Stop-LlamaServer | Out-Null
        return
    }

    # 与生产环境对齐：llama-server 使用 High 优先级 + 高性能电源
    try {
        $procRef = Get-Process -Id $proc.Id -ErrorAction Stop
        $procRef.PriorityClass = 'High'
        Write-E1Log "$Name 已设置进程优先级 High"
    } catch {
        Write-E1Log "$Name 设置优先级失败: $($_.Exception.Message)"
    }
    try {
        powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
        Write-E1Log "$Name 已设置高性能电源计划"
    } catch {
        Write-E1Log "$Name 设置电源计划失败: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 2
    $gpu0 = Get-GpuInfo
    $ram0 = Get-FreeRamGB

    $warm = $null
    try { $warm = Invoke-Gen -Prompt $WarmPrompt -Tokens 16 } catch { Write-E1Log "$Name warmup 失败: $($_.Exception.Message)" }
    Start-Sleep -Seconds 2

    $r1 = $null
    $r2 = $null
    $errText = ''
    try { $r1 = Invoke-Gen -Prompt $MeasurePrompt -Tokens $Tokens } catch { $errText = $_.Exception.Message }
    if ($null -ne $r1) {
        $samplePath = Join-Path $LogDir ($Name + '.sample.txt')
        if ($r1.content) { Set-Content -LiteralPath $samplePath -Value $r1.content -Encoding utf8 }
        Start-Sleep -Seconds 1
        try { $r2 = Invoke-Gen -Prompt $MeasurePrompt -Tokens $Tokens } catch { $errText = $_.Exception.Message }
    }

    $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    $wsMb = if ($p) { [math]::Round($p.WorkingSet64 / 1MB, 0) } else { 0 }
    $prio = if ($p) { $p.PriorityClass.ToString() } else { 'N/A' }
    $gpu1 = Get-GpuInfo
    $ram1 = Get-FreeRamGB

    $tps1 = if ($null -ne $r1) { $r1.gen_tps } else { 0 }
    $tps2 = if ($null -ne $r2) { $r2.gen_tps } else { 0 }
    $tpsMedian = if ($tps1 -gt 0 -and $tps2 -gt 0) { [math]::Round(($tps1 + $tps2) / 2, 2) } elseif ($tps1 -gt 0) { $tps1 } else { $tps2 }
    $status = if ($tpsMedian -gt 0) { 'OK' } else { 'FAIL_GEN' }
    $promptTps = if ($r1) { $r1.prompt_tps } else { 0 }
    $warmTps = if ($warm) { $warm.gen_tps } else { 0 }

    $rec = [ordered]@{
        time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        variant = $Name
        status = $status
        load_sec = $loadSec
        gen_tokens = $Tokens
        gen_tps_run1 = $tps1
        gen_tps_run2 = $tps2
        gen_tps_median = $tpsMedian
        prompt_tps = $promptTps
        warmup_tps = $warmTps
        gpu_total_mb = $gpu1.total
        gpu_used_mb_before = $gpu0.used
        gpu_used_mb_after = $gpu1.used
        gpu_free_mb_after = $gpu1.free
        gpu_temp_c = $gpu1.temp
        free_ram_gb_before = $ram0
        free_ram_gb_after = $ram1
        proc_ws_mb = $wsMb
        priority = $prio
        args = $argString
        error = $errText
    }
    $rec | ConvertTo-Json -Compress | Add-Content -LiteralPath $ResultFile -Encoding utf8

    $line = "{0,-16} status={1,-7} load={2,5}s tps={3,6} (run1={4,6} run2={5,6}) prompt_tps={6,6} gpu={7}MB/{8}MB free_ram={9}GB" -f $Name, $status, $loadSec, $tpsMedian, $tps1, $tps2, $promptTps, $gpu1.used, $gpu1.free, $ram1
    Add-Content -LiteralPath $SummaryFile -Value $line -Encoding utf8
    Write-E1Log $line

    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Stop-LlamaServer | Out-Null
    Start-Sleep -Seconds 3
}

$restored = $false
try {
    if ($RestoreOnly) {
        Restore-MonitorStack
        if (-not $SkipBus) { Invoke-BusAction 'start_rules' | Out-Null }
        Write-E1Log 'RestoreOnly 完成'
        $restored = $true
        return
    }

    Write-E1Log "E1 开始，变体: $($Names -join ', ')"
    if (-not $SkipBus) {
        $r = Invoke-BusAction 'stop_rules'
        Write-E1Log "stop_rules: $r"
    } else {
        Write-E1Log 'SkipBus: 不操作规则引擎'
    }
    Stop-MonitorStack

    foreach ($name in $Names) {
        if (-not ($Variants.Keys -contains $name)) { Write-E1Log "未知变体: $name"; continue }
        Start-And-Measure -Name $name -V $Variants[$name]
    }
} finally {
    if (-not $restored) {
        Write-E1Log 'E1 结束，恢复 monitor 与规则引擎'
        Stop-LlamaServer | Out-Null
        Restore-MonitorStack
        if (-not $SkipBus) {
            $r2 = Invoke-BusAction 'start_rules'
            Write-E1Log "start_rules: $r2"
        } else {
            Write-E1Log 'SkipBus: 跳过规则引擎恢复'
        }
    }
}
