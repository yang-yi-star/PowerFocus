#Requires -Version 7.0
<#
.SYNOPSIS
    算力形态 × 调度 矩阵实测脚本
.DESCRIPTION
    回答一个从未测过的问题：统一内存形态（分层共享权重）与 CPU 调度（优先级聚焦）
    叠加时，收益是线性相加、互相吃掉、还是相乘。

    四格矩阵：
        形态关(纯CPU) × 调度关    -> A 基线
        形态关(纯CPU) × 调度开    -> B  调度的独立收益
        形态开(分层)   × 调度关   -> C  形态的独立收益
        形态开(分层)   × 调度开   -> D  叠加（未知格）

    走 Ollama HTTP API（127.0.0.1:11434），用 options.num_gpu 控制 GPU 层数：
        num_gpu = 0   -> 纯 CPU，权重不出显存，无分层
        num_gpu = N   -> GPU 承担 N 层，其余 CPU，权重单份共享（统一内存形态）
    速度用 API 返回的 eval_count / eval_duration 计算，不靠外部计时。
.PARAMETER Model
    Ollama 模型名，默认 qwen3.8-27b-q4km:latest
.PARAMETER NglList
    要测的 num_gpu 档位，默认 0,20
.PARAMETER ScheduleList
    调度档位：none / gentle / aggressive，默认 none,gentle
.PARAMETER Rounds
    每格跑几轮，默认 3
.PARAMETER Tokens
    每次生成多少 token，默认 128
.PARAMETER OutFile
    结果 JSONL 路径
.NOTES
    前置要求（脚本会自检，不满足直接报错退出，不硬跑）：
      1. Ollama 服务在 127.0.0.1:11434 可达
      2. 目标模型已 pull
      3. 纯 CPU 档需要 >= 模型大小 + 2GB 可用物理内存
      4. 分层档需要 num_gpu 对应显存余量；脚本按实测可用显存自动校验并拒绝该档
    产出不可信数字比不产出更糟：任何前置不满足，直接拒绝该档并写入 skipped 记录。
#>
[CmdletBinding()]
param(
    [string]$Model = 'qwen3.8-27b-q4km:latest',
    [int[]]$NglList = @(0, 20),
    [string[]]$ScheduleList = @('none', 'gentle'),
    [int]$Rounds = 3,
    [int]$Tokens = 128,
    [string]$OutFile = 'E:\PowerFocus\matrix-results.jsonl',
    [string]$ApiBase = 'http://127.0.0.1:11434',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ------------------------------------------------------------
# 前置自检
# ------------------------------------------------------------
function Test-Preflight {
    $res = [ordered]@{ ollama = $false; model = $false; modelGB = 0; freeMemGB = 0; freeVramMB = 0; ok = $false }

    try {
        $tags = Invoke-RestMethod -Uri "$ApiBase/api/tags" -TimeoutSec 5
        $res.ollama = $true
        $m = $tags.models | Where-Object { $_.name -eq $Model }
        if ($m) { $res.model = $true; $res.modelGB = [math]::Round($m.size / 1GB, 2) }
    } catch { }

    $os = Get-CimInstance Win32_OperatingSystem
    $res.freeMemGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)

    try {
        $q = & nvidia-smi --query-gpu=memory.total,memory.used --format=csv,noheader,nounits 2>$null
        $parts = ($q -split ',')
        $res.freeVramMB = [int]$parts[0].Trim() - [int]$parts[1].Trim()
    } catch { $res.freeVramMB = -1 }

    $res.ok = ($res.ollama -and $res.model)
    return $res
}

# ------------------------------------------------------------
# 显存估计：粗略按每层权重 + KV 预算
# ------------------------------------------------------------
function Estimate-VramForLayers {
    param([double]$ModelGB, [int]$TotalLayers, [int]$GpuLayers, [int]$Ctx)
    if ($GpuLayers -le 0) { return 0 }
    # 权重按层均分（忽略 embed/output 层差异）
    $perLayerGB = $ModelGB / [double]$TotalLayers
    $weights = $perLayerGB * $GpuLayers
    # KV cache：按 8B 级经验值线性放大，q8_0 KV 约每 1K 上下文 0.055GB（8B 32K=1.8GB 的 1/32）
    $kv = ($Ctx / 1024.0) * 0.055
    # CUDA 工作区固定
    $workspace = 0.5
    return [math]::Round($weights + $kv + $workspace, 2)
}

# ------------------------------------------------------------
# 采样：生成期间 CPU / GPU
# ------------------------------------------------------------
function Start-Sampler {
    param([string]$ModelName)
    $script:samples = [System.Collections.Generic.List[object]]::new()
    $script:sampling = $true
    $script:samplerJob = Start-Job -ScriptBlock {
        param($model)
        $out = @()
        $stop = $false
        while (-not $stop) {
            $line = [ordered]@{ t = (Get-Date).ToString('HH:mm:ss') }
            try {
                $p = Get-Process -Name 'ollama' -ErrorAction SilentlyContinue |
                     Sort-Object WorkingSet64 -Descending | Select-Object -First 1
                if ($p) { $line.ollamaWorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB, 0) ; $line.ollamaCPU = [math]::Round($p.CPU, 1) }
            } catch { }
            try {
                $g = & nvidia-smi --query-gpu=memory.used,utilization.gpu,temperature.gpu,clocks.current.graphics --format=csv,noheader,nounits 2>$null
                $line.gpu = ($g -replace '\s', '')
            } catch { }
            try {
                $os = Get-CimInstance Win32_OperatingSystem
                $line.freeMemGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
            } catch { }
            $out += $line
            if (Test-Path -LiteralPath "$env:TEMP\pf_matrix_stop") { $stop = $true }
            Start-Sleep -Milliseconds 500
        }
        return $out
    } -ArgumentList $ModelName
    Remove-Item -LiteralPath "$env:TEMP\pf_matrix_stop" -Force -ErrorAction SilentlyContinue
}
function Stop-Sampler {
    New-Item -ItemType File -Path "$env:TEMP\pf_matrix_stop" -Force | Out-Null
    $script:samples = Receive-Job -Job $script:samplerJob -Wait -ErrorAction SilentlyContinue
    Remove-Job -Job $script:samplerJob -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$env:TEMP\pf_matrix_stop" -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# 调度：真复用 v0.09 内核的聚焦函数（不自己造近似版）
# 依据：v0.09 主脚本第 1901 行 `if ($MyInvocation.InvocationName -eq '.') { return }`
#       dot-source 保护位于 GUI 主循环（第 2076 行）之前，因此可以安全加载函数而不弹窗口。
# 口径（与 v0.09 的“温和聚焦”一致）：
#   调度关 = 什么都不做
#   调度开 = Start-GentleFocus：目标进程提 High + PriorityBoostEnabled + 切高性能电源计划
#   （不叠加“降级其他进程”那一档，保证矩阵是单变量，收益可归因）
# ------------------------------------------------------------
$script:KernelLoaded = $false

function Initialize-Kernel {
    if ($script:KernelLoaded) { return $true }
    $kernel = 'E:\PowerFocus\versions\v0.09\电脑算力调度中心_v0.09.ps1'
    if (-not (Test-Path -LiteralPath $kernel)) {
        throw "内核主脚本不存在: $kernel"
    }
    # 实例锁会与正在运行的托盘冲突，测试期间禁锁
    $env:PF_V3_NO_LOCK = '1'
    try {
        . $kernel 6>$null
        $script:KernelLoaded = $true
        return $true
    } catch {
        Write-Host "内核 dot-source 失败: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    } finally {
        Remove-Item Env:\PF_V3_NO_LOCK -ErrorAction SilentlyContinue
    }
}

function Set-Schedule {
    param([string]$Mode, [int]$TargetPid)
    if ($Mode -eq 'none') { return 'baseline(no-change)' }
    if (-not (Initialize-Kernel)) { return 'ERROR(kernel-load-failed)' }

    if (-not (Get-Command Start-GentleFocus -ErrorAction SilentlyContinue)) {
        return 'ERROR(function-missing)'
    }
    $target = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
    if (-not $target) { return "ERROR(no-target-pid=$TargetPid)" }
    if ($target.Name -in @('csrss', 'wininit', 'winlogon', 'services', 'lsass')) {
        return 'ERROR(protected-target)'
    }

    try {
        # 真实签名：Start-GentleFocus -ProcessId <int> -Name <string>
        Start-GentleFocus -ProcessId $TargetPid -Name $target.Name
    } catch {
        # Show-Balloon 在无托盘上下文会抛异常，属预期，不影响优先级已生效
    }
    $after = (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue).PriorityClass
    return "gentle(pid=$TargetPid prio=$after)"
}

function Clear-Schedule {
    if (-not $script:KernelLoaded) { return 'no-kernel' }
    try {
        if (Get-Command Stop-Focus -ErrorAction SilentlyContinue) { Stop-Focus }
        if (Get-Command Restore-PowerPlan -ErrorAction SilentlyContinue) { Restore-PowerPlan }
    } catch { }
    return 'restored'
}

# ------------------------------------------------------------
# 单次生成
# ------------------------------------------------------------
function Invoke-Gen {
    param([int]$NumGpu, [int]$Ctx)
    $body = @{
        model   = $Model
        prompt  = '请用一段话简要说明：为什么在显存不足的机器上，把模型部分层卸载到 CPU 仍然能提升速度。'
        stream  = $false
        options = @{
            num_gpu     = $NumGpu
            num_ctx     = $Ctx
            num_predict = $Tokens
            temperature = 0.2
        }
        keep_alive = '2m'
    } | ConvertTo-Json -Depth 4

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Invoke-RestMethod -Uri "$ApiBase/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 900
    $sw.Stop()

    $evalCount = [int]$resp.eval_count
    $evalNs = [double]$resp.eval_duration
    $loadNs = [double]$resp.load_duration
    $tps = if ($evalNs -gt 0) { [math]::Round($evalCount / ($evalNs / 1e9), 2) } else { 0 }

    return [ordered]@{
        tokens         = $evalCount
        tps            = $tps
        wallSec        = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        evalSec        = [math]::Round($evalNs / 1e9, 1)
        loadSec        = [math]::Round($loadNs / 1e9, 1)
    }
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
$pf = Test-Preflight
Write-Host "前置自检:" -ForegroundColor Cyan
Write-Host "  Ollama API     : $($pf.ollama)"
Write-Host "  模型存在       : $($pf.model)  ($($pf.modelGB) GB)"
Write-Host "  可用物理内存   : $($pf.freeMemGB) GB"
Write-Host "  可用显存       : $($pf.freeVramMB) MB"

if (-not $pf.ok) { throw "前置不满足：Ollama 不可达或模型未 pull。拒绝执行。" }

# 总层数：从 ollama show 或 GGUF 拿不到就直接按 64 估（27B 常见）
$totalLayers = 64
if (Test-Path -LiteralPath 'E:\PowerFocus\统一内存模式.ps1') {
    try {
        . 'E:\PowerFocus\统一内存模式.ps1'
        if (Get-Command Get-GgufLayerCount -ErrorAction SilentlyContinue) {
            $gguf = 'E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf'
            if (Test-Path -LiteralPath $gguf) { $totalLayers = Get-GgufLayerCount -Path $gguf }
        }
    } catch { }
}
Write-Host "  总层数(估)     : $totalLayers"

$Ctx = 8192
$records = [System.Collections.Generic.List[object]]::new()

foreach ($ngl in $NglList) {
    foreach ($sched in $ScheduleList) {
        $cell = "ngl=$ngl/sched=$sched"

        # 可行性校验
        if ($ngl -eq 0) {
            $need = $pf.modelGB + 2
            if ($pf.freeMemGB -lt $need) {
                Write-Host "[跳过] $cell  需要 $need GB 内存，只有 $($pf.freeMemGB) GB" -ForegroundColor Yellow
                $records.Add([ordered]@{ cell = $cell; status = 'skipped'; reason = "内存不足 need=$need have=$($pf.freeMemGB)" })
                continue
            }
        } else {
            $est = Estimate-VramForLayers -ModelGB $pf.modelGB -TotalLayers $totalLayers -GpuLayers $ngl -Ctx $Ctx
            if ($est -gt ($pf.freeVramMB / 1024.0) - 1) {
                Write-Host "[跳过] $cell  估计显存 $est GB，可用 $([math]::Round($pf.freeVramMB/1024,1)) GB（留 1GB 余量）" -ForegroundColor Yellow
                $records.Add([ordered]@{ cell = $cell; status = 'skipped'; reason = "显存不足 est=$est have=$([math]::Round($pf.freeVramMB/1024,1))" })
                continue
            }
        }

        $schedDesc = Set-Schedule -Mode $sched
        $runs = @()
        for ($i = 1; $i -le $Rounds; $i++) {
            Write-Host "  [$cell] 第 $i/$Rounds 轮 ..." -ForegroundColor Gray
            # 换档位：先卸载模型，确保 num_gpu 生效
            try { Invoke-RestMethod -Uri "$ApiBase/api/generate" -Method Post -ContentType 'application/json' `
                    -Body (@{ model = $Model; keep_alive = 0 } | ConvertTo-Json) -TimeoutSec 30 | Out-Null } catch { }
            Start-Sleep -Seconds 2
            Start-Sampler -ModelName $Model
            $r = Invoke-Gen -NumGpu $ngl -Ctx $Ctx
            Stop-Sampler
            $runs += $r
        }
        $median = ($runs | Sort-Object tps | Select-Object -Index ([math]::Floor($runs.Count / 2))).tps
        $rec = [ordered]@{
            cell        = $cell
            status      = 'ok'
            ngl         = $ngl
            schedule    = $sched
            schedDesc   = $schedDesc
            totalLayers = $totalLayers
            runs        = $runs
            medianTps   = $median
            freeMemGB   = $pf.freeMemGB
            freeVramMB  = $pf.freeVramMB
            time        = (Get-Date).ToString('s')
        }
        $records.Add($rec)
        Write-Host "  -> 中位 $median t/s" -ForegroundColor Green
    }
}

# 落盘
$records | ForEach-Object { ($_ | ConvertTo-Json -Depth 6 -Compress) } |
    Out-File -LiteralPath $OutFile -Encoding utf8 -Append
Write-Host "`n结果已写入 $OutFile" -ForegroundColor Cyan
$records | Where-Object { $_.status -eq 'ok' } |
    Select-Object cell, medianTps, schedDesc |
    Format-Table -AutoSize | Out-String | Write-Host
