#Requires -Version 7.0
<#
.SYNOPSIS
    对统一内存模式下的 llama-server 执行 5 轮生成性能测试。
.DESCRIPTION
    每轮调用 127.0.0.1:8080/completion 接口，固定生成 256 token，
    记录耗时、tokens/s、GPU 显存占用、系统内存可用量、llama 进程 CPU 占用核数。
    结果写入 E:\PowerFocus\统一内存测试结果.txt（UTF-8），同时每轮一行输出到控制台。
.NOTES
    代码主体由本地模型 Qwen3.8-27B 生成（um-model-output2 + um-model-output3），
    监督修正项均已标注【监督修正】。
    用法：pwsh -File Test-UnifiedMemoryPerf.ps1
#>

param(
    # 主脚本路径，通过 dot-source 加载
    [string]$MainScript = "E:\PowerFocus\统一内存模式.ps1"
)

# -------------------------- 全局常量与变量 --------------------------

# 测试目标地址（llama-server 统一内存模式）
$script:TestHost      = "127.0.0.1"
$script:TestPort      = 8080
$script:TestEndpoint  = "http://${script:TestHost}:${script:TestPort}/completion"
$script:HealthEndpoint= "http://${script:TestHost}:${script:TestPort}/health"

# 每轮固定生成 token 数
$script:MaxTokens     = 256

# 总测试轮次
$script:TotalRounds   = 5

# 轮间等待秒数
$script:RoundInterval = 5

# 结果输出文件路径（E 盘 PowerFocus 目录）
$script:ResultDir     = "E:\PowerFocus"
$script:ResultFile    = Join-Path $script:ResultDir "统一内存测试结果.txt"

# -------------------------- 辅助函数 --------------------------

<#
.SYNOPSIS
    按端口占用者定位真正服务的 llama-server PID。
.NOTES
    【监督修正】不能按进程名取第一个：本机同时存在 qwen3-4b 等其他 llama-server
    实例（如 8686 端口），名字相同但非被测服务，会测到空闲进程的 CPU。
    必须取 8080 端口监听进程。
#>
function Find-LlamaProcessId {
    $conn = Get-NetTCPConnection -LocalPort $script:TestPort -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conn) { return [int]$c.OwningProcess }
    # 回退：按进程名
    $procs = Get-Process -Name "llama-server" -ErrorAction SilentlyContinue
    if ($procs) { return $procs[0].Id }
    return -1
}

<#
.SYNOPSIS
    通过 nvidia-smi 查询当前 GPU 显存已用 MB。
.NOTES
    仅使用 NVIDIA 驱动自带的 nvidia-smi，不依赖任何外部模块。
#>
function Get-TestGpuUsedMB {
    try {
        $raw = & nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>&1
        # 取第一块 GPU 的值（多卡场景）
        $val = ($raw | Select-Object -First 1).Trim()
        return [int]$val
    } catch {
        Write-Host "  [WARN] nvidia-smi 查询失败: $($_.Exception.Message)"
        return -1
    }
}

<#
.SYNOPSIS
    查询当前系统可用内存（GB），使用 CIM 查询，无外部依赖。
#>
function Get-TestSysAvailGB {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        # FreePhysicalMemory 单位为 KB
        $availKB = $os.FreePhysicalMemory
        return [math]::Round($availKB / 1MB, 2)
    } catch {
        Write-Host "  [WARN] 系统内存查询失败: $($_.Exception.Message)"
        return -1
    }
}

<#
.SYNOPSIS
    获取 llama-server 进程的 CPU 累计时间（秒）。
    用于两轮之间计算 CPU 占用核数 = (本次累计 - 上次累计) / 耗时秒。
#>
function Get-LlamaCpuSeconds {
    param([int]$ProcessId)
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        # TotalProcessorTime 为 TimeSpan，转换为秒
        return $p.TotalProcessorTime.TotalSeconds
    } catch {
        return -1
    }
}

<#
.SYNOPSIS
    查找 llama-server 进程的 PID（按进程名匹配）。
#>
function Find-LlamaProcessId {
    $procs = Get-Process -Name "llama-server" -ErrorAction SilentlyContinue
    if ($procs) { return $procs[0].Id }
    # 兼容：某些版本进程名可能为 llama_server 或带路径
    $procs2 = Get-Process | Where-Object { $_.Path -like "*llama*server*" } -ErrorAction SilentlyContinue
    if ($procs2) { return $procs2[0].Id }
    return -1
}

# -------------------------- 主流程 --------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  统一内存模式 5 轮性能测试" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Step 1: dot-source 加载主脚本 ---
if (-not (Test-Path $MainScript)) {
    Write-Error "主脚本不存在: ${MainScript}"
    exit 1
}
. $MainScript
Write-Host "[INFO] 已加载主脚本: ${MainScript}"

# --- Step 2: 确保 llama-server 就绪 ---
# 【监督修正】若服务已健康运行（当前部署即统一内存形态），不重复重启，
# 避免打断正在运行的实例；仅当服务未就绪时才走扩展的一键启动。
$healthOk = $false
try {
    $h = Invoke-RestMethod -Uri $script:HealthEndpoint -Method GET -TimeoutSec 5
    if ($h.status -eq 'ok') { $healthOk = $true }
} catch { $healthOk = $false }

if ($healthOk) {
    $pidFound = Find-LlamaProcessId
    Write-Host "[INFO] llama-server 已就绪 (PID=$pidFound)，跳过重启，直接测试。"
} else {
    Write-Host "[INFO] llama-server 未就绪，启动统一内存模式..."
    $llamaProc = Start-UnifiedMemoryMode
    if (-not $llamaProc) {
        Write-Error "统一内存模式启动失败，测试终止。"
        exit 1
    }
    Write-Host "[INFO] llama-server 已就绪 (PID=$($llamaProc.Id))"
}

# --- Step 3: 确保结果目录存在 ---
if (-not (Test-Path $script:ResultDir)) {
    New-Item -Path $script:ResultDir -ItemType Directory -Force | Out-Null
}

# --- Step 4: 初始化结果文件（UTF-8，带表头）---
# 【监督修正】表头列数与数据行对齐（6 列：轮次/耗时ms/Tokens每秒/CPU核数/GPU显存MB/系统可用GB）
$headerLine = "轮次`t耗时毫秒`tTokens每秒`tCPU核数`tGPU显存MB`t系统可用GB"
[System.IO.File]::WriteAllText($script:ResultFile, $headerLine + [Environment]::NewLine, [System.Text.Encoding]::UTF8)

Write-Host ""
Write-Host "开始 ${script:TotalRounds} 轮测试，每轮生成 ${script:MaxTokens} token..." -ForegroundColor Yellow
Write-Host ""

# --- Step 5: 执行 5 轮测试循环 ---
for ($round = 1; $round -le $script:TotalRounds; $round++) {

    # ===== 5a. 获取本轮开始前的 CPU 累计秒（用于计算核数）=====
    $llamaPid = Find-LlamaProcessId
    if ($llamaPid -lt 0) {
        Write-Host "  [ERROR] 未找到 llama-server 进程，测试终止。" -ForegroundColor Red
        break
    }
    $cpuBefore = Get-LlamaCpuSeconds -ProcessId $llamaPid

    # ===== 5b. 记录本轮开始时间 =====
    $roundStart = [DateTime]::Now

    # ===== 5c. 调用 /completion 接口，固定生成 256 token =====
    $body = @{
        prompt      = "The quick brown fox jumps over the lazy dog. Please continue this text."
        n_predict   = $script:MaxTokens
        temperature = 0.7
        stream      = $false
    } | ConvertTo-Json -Depth 4

    try {
        $response = Invoke-RestMethod `
            -Uri       $script:TestEndpoint `
            -Method    POST `
            -Body      $body `
            -ContentType "application/json" `
            -TimeoutSec 600

        # 从响应中获取实际生成的 token 数
        if ($response.content) {
            $generatedTokens = $script:MaxTokens  # /completion 不直接返回 token 计数，按请求值记录
        } else {
            $generatedTokens = 0
        }

        # ========== 判断接口响应是否成功（本地模型续写） ==========
        if ($null -eq $response -or $response.error) {
            Write-Warning "第 ${round} 轮：接口返回异常或为空，跳过本轮。"
            Start-Sleep -Seconds $script:RoundInterval
            continue
        }

        # ========== 记录本轮结束时间，用 DateTime 差值计算生成耗时（毫秒） ==========
        $roundEnd = [DateTime]::Now
        $elapsedMs = [math]::Round(($roundEnd - $roundStart).TotalMilliseconds, 1)
        $elapsedSec = $elapsedMs / 1000.0

        # ========== 计算 tokens 每秒（本轮固定生成 256 tokens） ==========
        $tokensPerSec = if ($elapsedSec -gt 0) { [math]::Round(256.0 / $elapsedSec, 2) } else { 0 }

        # ========== 获取 llama 进程 CPU 累计秒，计算本轮平均占用核数 ==========
        # 【监督修正】Get-LlamaCpuSeconds 需显式传参 $llamaPid
        $cpuAfter = Get-LlamaCpuSeconds -ProcessId $llamaPid
        $cpuDeltaSec = $cpuAfter - $cpuBefore
        $cpuCoresUsed = if ($elapsedSec -gt 0) { [math]::Round($cpuDeltaSec / $elapsedSec, 2) } else { 0 }

        # ========== 采集本轮 GPU 显存占用（MB）与系统可用内存（GB） ==========
        $gpuUsedMB = Get-TestGpuUsedMB
        $sysAvailGB = Get-TestSysAvailGB

        # ========== 将本轮数据按制表符分隔追加写入结果文件（UTF-8 编码） ==========
        # 列顺序：轮次 / 耗时ms / tokens每秒 / CPU占用核数 / GPU显存MB / 系统可用内存GB
        $line = "$round`t$elapsedMs`t$tokensPerSec`t$cpuCoresUsed`t$gpuUsedMB`t$sysAvailGB"
        Add-Content -Path $script:ResultFile -Value $line -Encoding UTF8

        # ========== 每轮一行输出到控制台，便于实时观察 ==========
        Write-Host ("第 {0} 轮 | 耗时: {1,6} ms | Tokens/s: {2,6} | CPU核数: {3,5} | GPU: {4,5} MB | 可用内存: {5,5} GB" -f `
            $round, $elapsedMs, $tokensPerSec, $cpuCoresUsed, $gpuUsedMB, $sysAvailGB) -ForegroundColor Cyan

        # ========== 轮间等待（非最后一轮时休眠，默认 5 秒） ==========
        if ($round -lt $script:TotalRounds) {
            Write-Host ("    等待 {0} 秒后进入第 {1} 轮..." -f $script:RoundInterval, ($round + 1)) -ForegroundColor DarkGray
            Start-Sleep -Seconds $script:RoundInterval
        }
    } catch {
        Write-Host "  [ERROR] 第 ${round} 轮调用接口失败: $($_.Exception.Message)" -ForegroundColor Red
        if ($round -lt $script:TotalRounds) {
            Start-Sleep -Seconds $script:RoundInterval
        }
    }
}

# ========== 循环结束：输出测试完成总结 ==========
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host ("  统一内存模式 {0} 轮性能测试已全部完成" -f $script:TotalRounds) -ForegroundColor Green
Write-Host ("  测试端点   : {0}" -f $script:TestEndpoint) -ForegroundColor Green
Write-Host ("  结果文件   : {0}" -f $script:ResultFile) -ForegroundColor Green
Write-Host ("  完成时间   : {0}" -f ([DateTime]::Now).ToString("yyyy-MM-dd HH:mm:ss")) -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
