#Requires -Version 7.0
<#
  calibrate-models.ps1 — 本地模型参数校准器（llama.cpp + CUDA）
  设计原则：
    1. 失败优先：每次启动前记录原状态，任何异常都回滚到基线
    2. 不猜参数：只用 llama-server 自己返回的 timings 计时，不靠外部估算
    3. 全程留痕：每个候选参数一行日志，可追溯
  用法：
    pwsh -File calibrate-models.ps1                 # 校准所有待校准模型
    pwsh -File calibrate-models.ps1 -Models "qwen3-14b-q4km"
    pwsh -File calibrate-models.ps1 -RestoreOnly    # 只恢复基线服务
#>
param(
    [string[]]$Models = @(),
    [switch]$RestoreOnly,
    [switch]$SkipRestore
)

$ErrorActionPreference = 'Stop'
$ServerExe   = 'E:\Program Files\llama.cpp\bin\llama-server.exe'
$Registry    = 'E:\PowerFocus\v3\model-profiles.json'
$BaselineRec = 'E:\PowerFocus\v3\logs\baseline-server.json'
$LogDir      = 'E:\PowerFocus\v3\logs'
$LogFile     = Join-Path $LogDir ('calibration-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Port        = 8080
$MaintFlag   = 'E:\PowerFocus\v3\.maintenance'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Write-Log([string]$msg, [string]$level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $level, $msg
    $line | Tee-Object -FilePath $LogFile -Append | Out-Host
}

function Get-ServerProc {
    Get-Process llama-server -ErrorAction SilentlyContinue
}

function Stop-Server {
    $p = Get-ServerProc
    if ($p) {
        Write-Log "停止 llama-server PID=$($p.Id)（$($p.Count) 个实例）"
        $p | Stop-Process -Force
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 500
            if (-not (Get-ServerProc)) { return $true }
        }
        Write-Log '进程未在 10 秒内退出' 'WARN'
        return $false
    }
    return $true
}

function Wait-Health([int]$TimeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { return $true }
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -eq 503) { continue }   # 仍在加载
        }
        if (-not (Get-ServerProc)) { return $false }
    }
    return $false
}

function Start-Server {
    param([string]$ModelPath, [string]$Alias, [int]$Ngl, [string]$Fa, [int]$Ctx = 8192)
    Stop-Server | Out-Null
    $outLog = Join-Path $LogDir ("srv-{0}-{1}.out" -f $Alias, (Get-Date -Format 'HHmmssfff'))
    $errLog = Join-Path $LogDir ("srv-{0}-{1}.err" -f $Alias, (Get-Date -Format 'HHmmssfff'))
    $argv = @(
        '-m', "`"$ModelPath`"",
        '-ngl', $Ngl, '-fa', $Fa, '-c', $Ctx,
        '--cache-type-k', 'q8_0', '--cache-type-v', 'f16',
        '-t', 16, '-tb', 8,
        '--temp', '0.7', '--top-k', '20', '--top-p', '0.8', '--presence-penalty', '1.5', '--min-p', '0',
        '--host', '127.0.0.1', '--port', $Port, '--parallel', 1, '--alias', $Alias
    )
    $argStr = $argv -join ' '
    Write-Log "启动: $Alias ngl=$Ngl fa=$Fa ctx=$Ctx"
    $proc = Start-Process -FilePath $ServerExe -ArgumentList $argStr -PassThru `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden
    if (Wait-Health -TimeoutSec 90) {
        Write-Log "就绪: $Alias ngl=$Ngl fa=$Fa"
        return $proc
    }
    Write-Log "启动失败或超时: $Alias ngl=$Ngl fa=$Fa（见 $errLog）" 'FAIL'
    Stop-Server | Out-Null
    return $null
}

function Measure-Tps {
    param([string]$Alias)
    $body = @{
        prompt       = "请用一句话解释什么是梯度下降。"
        n_predict    = 128
        temperature  = 0
        cache_prompt = $false
        stream       = $false
    } | ConvertTo-Json -Depth 5
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/completion" -Method Post `
        -ContentType 'application/json' -Body $body -TimeoutSec 180
    $sw.Stop()
    $pt = $null
    if ($r.timings) {
        $pt = [double]$r.timings.predicted_per_second
    }
    $n = $null
    if ($r.timings) { $n = [int]$r.timings.predicted_n }
    Write-Log ("实测 {0}: {1:N2} t/s（生成 {2} token，端到端 {3:N1}s）" -f $Alias, $pt, $n, $sw.Elapsed.TotalSeconds)
    return [pscustomobject]@{ tps = [math]::Round($pt, 2); tokens = $n; wall = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function Save-Baseline {
    $p = Get-ServerProc
    if (-not $p) { Write-Log '没有正在运行的基线服务，跳过存档' 'WARN'; return }
    $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)"
    $obj = [pscustomobject]@{
        saved_at   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        pid        = $p.Id
        command    = $ci.CommandLine
        executable = $ServerExe
    }
    $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $BaselineRec -Encoding utf8
    Write-Log "基线命令已存档: $BaselineRec"
}

function Restore-Baseline {
    if (-not (Test-Path $BaselineRec)) { Write-Log '基线存档不存在，无法恢复' 'FAIL'; return $false }
    $b = Get-Content $BaselineRec -Raw -Encoding utf8 | ConvertFrom-Json
    $argStr = $b.command
    # 剔除 exe 路径，只保留参数
    $exeIdx = $argStr.IndexOf('llama-server.exe"')
    if ($exeIdx -ge 0) { $argStr = $argStr.Substring($exeIdx + 'llama-server.exe"'.Length).Trim() }
    Stop-Server | Out-Null
    $outLog = Join-Path $LogDir 'baseline-restore.out'
    $errLog = Join-Path $LogDir 'baseline-restore.err'
    Write-Log '正在恢复基线服务（27B 原命令）'
    Start-Process -FilePath $ServerExe -ArgumentList $argStr -PassThru `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog -WindowStyle Hidden | Out-Null
    if (Wait-Health -TimeoutSec 120) { Write-Log '基线已恢复正常' ; return $true }
    Write-Log '基线恢复失败，请人工检查' 'FAIL'
    return $false
}

function Get-Candidates([double]$sizeGb) {
    if ($sizeGb -lt 5)  { return @(@{ ngl = 99; fa = 'on' }, @{ ngl = 99; fa = 'off' }) }
    if ($sizeGb -lt 12) { return @(@{ ngl = 18; fa = 'on' }, @{ ngl = 22; fa = 'on' }, @{ ngl = 26; fa = 'on' }, @{ ngl = 30; fa = 'on' }) }
    return @(@{ ngl = 18; fa = 'on' }, @{ ngl = 20; fa = 'on' }, @{ ngl = 23; fa = 'on' })
}

# ================= 主流程 =================
Write-Log '校准任务开始'
# -File 方式传参时逗号列表会被当成单个字符串，这里拆开
if ($Models.Count -eq 1 -and $Models[0] -match ',') { $Models = $Models[0] -split ',' }
if ($RestoreOnly) {
    Restore-Baseline | Out-Null
    Remove-Item $MaintFlag -Force -ErrorAction SilentlyContinue
    Write-Log '维护窗口已清除'
    exit 0
}

try {
    # 开启维护窗口：看门狗暂停拉起，避免与校准实例抢 8080 端口
    New-Item -ItemType File -Force -Path $MaintFlag | Out-Null
    Write-Log '维护窗口已开启（看门狗暂停）'

    Save-Baseline
$cfg = Get-Content $Registry -Raw -Encoding utf8 | ConvertFrom-Json

if (-not $Models -or $Models.Count -eq 0) {
    $Models = @($cfg.models.PSObject.Properties | Where-Object { $_.Value.status -ne 'calibrated' } | ForEach-Object { $_.Name })
}
Write-Log ("待校准模型: {0}" -f ($Models -join ', '))

$results = @()
foreach ($key in $Models) {
    $m = $cfg.models.$key
    if (-not $m) { Write-Log "注册表中不存在 $key" 'FAIL'; continue }
    $path = $m.identity.path_hint
    if (-not (Test-Path $path)) { Write-Log "文件不存在: $path" 'FAIL'; continue }
    $alias = $m.common.alias
    if (-not $alias) { $alias = $key }

    $best = $null
    foreach ($c in Get-Candidates([double]$m.identity.size_gb)) {
        $proc = Start-Server -ModelPath $path -Alias $alias -Ngl $c.ngl -Fa $c.fa
        if (-not $proc) { continue }
        try {
            $t = Measure-Tps -Alias $alias
            if (-not $best -or $t.tps -gt $best.tps) {
                $best = [pscustomobject]@{ ngl = $c.ngl; fa = $c.fa; tps = $t.tps; tokens = $t.tokens }
            }
        } catch {
            Write-Log "测量异常 ngl=$($c.ngl): $($_.Exception.Message)" 'FAIL'
        } finally {
            Stop-Server | Out-Null
        }
    }

    if (-not $best) { Write-Log "$key 所有候选均失败，保持待校准" 'FAIL'; continue }
    Write-Log ("$key 最优: ngl={0} fa={1} → {2} t/s" -f $best.ngl, $best.fa, $best.tps)

    # 写回注册表
    $profileObj = [pscustomobject]@{
        speed_8k = [pscustomobject]@{
            ctx           = 8192
            ngl           = $best.ngl
            fa            = $best.fa
            cache_k       = 'q8_0'
            cache_v       = 'f16'
            threads       = 16
            threads_batch = 8
            measured_tps  = $best.tps
            measured_at   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            method        = 'llama-server /completion timings.predicted_per_second，固定 prompt 128 token，temp=0'
        }
    }
    # 新模型条目 profiles 为空，直接赋值会抛 "找不到属性"；统一用 Add-Member -Force
    $m | Add-Member -NotePropertyName profiles    -NotePropertyValue $profileObj -Force
    $m | Add-Member -NotePropertyName selection   -NotePropertyValue @('speed_8k') -Force
    $m | Add-Member -NotePropertyName status      -NotePropertyValue 'calibrated' -Force
    $m | Add-Member -NotePropertyName calibration -NotePropertyValue (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Force
    $results += [pscustomobject]@{ key = $key; ngl = $best.ngl; fa = $best.fa; tps = $best.tps }
}

Copy-Item $Registry ("$Registry.bak-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
$cfg.generated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$cfg.source = 'calibrate-models.ps1 实测校准（llama-server timings）'
$cfg | ConvertTo-Json -Depth 30 | Set-Content -Path $Registry -Encoding utf8
Write-Log "注册表已更新，备份: $Registry.bak-*"
}
catch {
    Write-Log "致命异常: $($_.Exception.GetType().Name): $($_.Exception.Message)" 'FAIL'
}
finally {
    if (-not $SkipRestore) { Restore-Baseline | Out-Null }
    Remove-Item $MaintFlag -Force -ErrorAction SilentlyContinue
    Write-Log '维护窗口已关闭（看门狗恢复）'
}

Write-Log ("校准结束，成功 {0} 个" -f $results.Count)
$results | Format-Table -AutoSize | Out-String | Write-Host
