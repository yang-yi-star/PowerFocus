#Requires -Version 7.0
<#
.SYNOPSIS
    电脑算力调度中心 - 统一内存模式扩展模块
.DESCRIPTION
    在 Windows + NVIDIA 显卡机器上等效实现 Apple 统一内存推理方式：
    GGUF 模型权重整体通过 mmap 驻留系统内存，GPU 承担尽可能多的层计算，
    CPU 承担剩余层计算，CPU 与 GPU 共享同一份物理权重页。
.NOTES
    文件名：E:\PowerFocus\统一内存模式.ps1
    编码：UTF-8
    代码主体由本地模型 Qwen3.8-27B 生成（三部分流式产出合并），
    监督修正项均已标注【监督修正】。
    集成方式：. "E:\PowerFocus\统一内存模式.ps1"  （dot-source）
#>

# ============================================================
# 全局配置区
# ============================================================

# 工具根目录
$script:ToolRoot = "E:\PowerFocus"

# llama.cpp 可执行文件路径【监督修正：改为本机真实路径】
$script:LlamaServerPath = "E:\Program Files\llama.cpp\bin\llama-server.exe"

# GGUF 模型文件路径【监督修正：改为本机真实路径】
$script:ModelPath = "E:\Model_Zone\Qwen3.8-27B-UD-Q4_K_M\Qwen3.8-27B-UD-Q4_K_M.gguf"

# llama-server 监听地址与端口
$script:LlamaHost = "127.0.0.1"
$script:LlamaPort = 8080

# 上下文长度
$script:CtxSize = 65536

# CUDA 上下文预留显存（MB），用于 cuDNN/cuBLAS 工作区
$script:CudaReservedMB = 512

# 计算缓冲区与 KV 预留显存（MB）【监督修正：额外安全余量，防止层数过高 OOM】
$script:ComputeReserveMB = 1024

# 本机实测安全 GPU 层数上限【监督修正：RTX 5060 8GB 实测 -ngl 20 满负荷（约 7.5GB），
# 21 层以上有 OOM 风险，按实测结果钳制】
$script:MaxGpuLayersSafe = 20

# 看门狗轮询间隔（秒）
$script:WatchdogIntervalSec = 5

# 日志文件路径（UTF-8）
$script:LogFilePath = Join-Path $script:ToolRoot "统一内存模式_日志.txt"

# 进程白名单（保留现有工具配置）
$script:ProcessWhitelist = @(
    "llama-server",
    "PowerShell",
    "pwsh",
    "explorer",
    "dwm",
    "NVIDIA Container",
    "nvidia-smi"
)

# 统一内存模式运行时状态
$script:UnifiedMemoryState = @{
    Running        = $false
    OriginalArgs   = $null
    Process        = $null
    StartTime      = [DateTime]::MinValue
    OutputReader   = $null
    ErrorReader    = $null
    GpuLayers      = 0
    CpuLayers      = 0
    TotalLayers    = 0
}

# ============================================================
# 区域一：现有工具核心函数（本地模型产出）
# ============================================================

<#
.SYNOPSIS
    设置进程白名单，供聚焦与看门狗使用。
.DESCRIPTION
    将用户指定的进程名数组写入脚本级白名单变量。
.PARAMETER Names
    进程名数组（不含 .exe 后缀亦可）。
#>
function Set-ProcessWhitelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string[]]$Names
    )

    # 去除 .exe 后缀并统一小写，便于后续匹配
    $cleaned = @()
    foreach ($n in $Names) {
        $cleaned += ($n -replace '\.exe$','').ToLowerInvariant()
    }
    $script:ProcessWhitelist = $cleaned
    Write-ToolLog "进程白名单已更新：[$($cleaned -join ', ')]"
}

<#
.SYNOPSIS
    温和聚焦模式。
.DESCRIPTION
    将非白名单进程的优先级降为 BelowNormal，不杀进程、不冻结，
    仅降低调度优先级以让 llama-server 获得更多 CPU 时间片。
.PARAMETER DryRun
    为 $true 时仅打印操作，不实际修改。
#>
function Start-GentleFocus {
    [CmdletBinding()]
    param(
        [switch]$DryRun
    )

    Write-ToolLog "=== 温和聚焦启动 ==="

    # 获取所有用户态进程（排除 System Idle / System）
    $allProcs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -gt 4 -and $_.Name -ne 'System' }

    foreach ($proc in $allProcs) {
        # 白名单匹配（不区分大小写）
        $inWhitelist = $script:ProcessWhitelist |
            Where-Object { $proc.Name.ToLowerInvariant() -like "*$_*" }
        if ($inWhitelist) { continue }

        try {
            if ($DryRun) {
                Write-Host "  [温和] 将降低 $($proc.ProcessName) (PID $($proc.Id)) → BelowNormal" -ForegroundColor DarkGray
            } else {
                $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
                Write-ToolLog "  [温和] $($proc.ProcessName) PID=$($proc.Id) → BelowNormal"
            }
        } catch {
            # 某些受保护进程无法修改，静默跳过
            Write-ToolLog "  [温和] 跳过 $($proc.ProcessName) PID=$($proc.Id)（无权限）"
        }
    }

    Write-ToolLog "=== 温和聚焦完成 ==="
}

<#
.SYNOPSIS
    激进聚焦模式。
.DESCRIPTION
    将非白名单进程优先级降为 Idle，最大程度让出 CPU 给推理进程。
.PARAMETER DryRun
    为 $true 时仅打印操作。
#>
function Start-AggressiveFocus {
    [CmdletBinding()]
    param(
        [switch]$DryRun
    )

    Write-ToolLog "=== 激进聚焦启动 ==="

    $allProcs = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -gt 4 -and $_.Name -ne 'System' }

    foreach ($proc in $allProcs) {
        $inWhitelist = $script:ProcessWhitelist |
            Where-Object { $proc.Name.ToLowerInvariant() -like "*$_*" }
        if ($inWhitelist) { continue }

        try {
            if ($DryRun) {
                Write-Host "  [激进] 将降低 $($proc.ProcessName) (PID $($proc.Id)) → Idle" -ForegroundColor DarkYellow
            } else {
                $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle
                Write-ToolLog "  [激进] $($proc.ProcessName) PID=$($proc.Id) → Idle"
            }
        } catch {
            Write-ToolLog "  [激进] 跳过 $($proc.ProcessName) PID=$($proc.Id)（无权限）"
        }
    }

    Write-ToolLog "=== 激进聚焦完成 ==="
}

<#
.SYNOPSIS
    看门狗守护（本地模型产出版本）。
.DESCRIPTION
    后台循环监控 llama-server 进程存活状态；若进程意外退出，
    自动记录日志并尝试重启（最多 $MaxRestart 次）。
.PARAMETER MaxRestart
    最大自动重启次数，默认 3。
#>
function Start-Watchdog {
    [CmdletBinding()]
    param(
        [int]$MaxRestart = 3
    )

    Write-ToolLog "=== 看门狗启动（最大重启 $MaxRestart 次）==="

    $restartCount = 0

    # 使用 Job 运行后台循环，避免阻塞主线程
    $job = Start-Job -ScriptBlock {
        param($interval, $maxR, $port)
        $r = 0
        while ($r -lt $maxR) {
            Start-Sleep -Seconds $interval
            # 检查 8080 端口是否有 llama-server 监听【监督修正：按端口判断，
            # 避免被 8686 等其他 llama-server 实例干扰存活判断】
            $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
            if (-not $conn) {
                $r++
                # 写入标记文件通知主脚本
                $flagFile = Join-Path "E:\PowerFocus" ".watchdog_restart_flag"
                Set-Content -Path $flagFile -Value $r -Encoding utf8
                break
            }
        }
    } -ArgumentList $script:WatchdogIntervalSec, $MaxRestart, $script:LlamaPort

    # 等待 Job 完成（进程存活则 Job 会自然超时退出）
    Wait-Job -Job $job -Timeout (($MaxRestart * $script:WatchdogIntervalSec) + 10) | Out-Null
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

    # 检查是否需要重启
    $flagFile = Join-Path $script:ToolRoot ".watchdog_restart_flag"
    if (Test-Path $flagFile) {
        $count = Get-Content $flagFile -Encoding utf8 | ForEach-Object { [int]$_ }
        Remove-Item $flagFile -Force
        Write-ToolLog "看门狗检测到 llama-server 退出，尝试第 $count 次重启…"
        if ($count -le $MaxRestart) {
            Start-UnifiedMemoryMode -GpuLayers $script:UnifiedMemoryState.GpuLayers
        }
    }

    Write-ToolLog "=== 看门狗结束 ==="
}

<#
.SYNOPSIS
    日志写入函数（本地模型产出版本）。
.DESCRIPTION
    将带时间戳的消息追加写入 UTF-8 编码的日志文件，同时输出到控制台。
.PARAMETER Message
    要写入的日志内容。
.PARAMETER Level
    日志级别：INFO / WARN / ERROR / DEBUG，默认 INFO。
#>
function Write-ToolLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","DEBUG")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "[$timestamp] [$Level] $Message"

    # 控制台输出（按级别着色）
    switch ($Level) {
        "INFO"  { Write-Host $line -ForegroundColor Gray }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "DEBUG" { Write-Host $line -ForegroundColor DarkGray }
    }

    # 追加写入 UTF-8 日志文件（显式指定编码）
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($script:LogFilePath, "$line`r`n", $utf8NoBom)
}

# ============================================================
# 区域二：统一内存模式 —— 新增函数（本地模型产出 + 监督修正）
# ============================================================

<#
.SYNOPSIS
    检测 GPU 显存总量与当前占用。
.DESCRIPTION
    调用 nvidia-smi 查询所有 NVIDIA 显卡的显存总量、已用、空闲（单位 MB）。
.OUTPUTS
    哈希表数组，每项含 Index / TotalMB / UsedMB / FreeMB。
#>
function Get-GpuMemoryInfo {
    [CmdletBinding()]
    param()

    # 定位 nvidia-smi
    $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        Write-ToolLog "未找到 nvidia-smi，请确认 NVIDIA 驱动已安装。" "ERROR"
        return @()
    }

    # 查询显存信息（无单位、CSV 格式）
    $raw = & $nvidiaSmi.Source `
        --query-gpu=index,memory.total,memory.used,memory.free `
        --format=csv,noheader,nounits 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-ToolLog "nvidia-smi 查询失败：$raw" "ERROR"
        return @()
    }

    $result = @()
    foreach ($line in $raw) {
        $parts = $line -split ',' | ForEach-Object { $_.Trim() }
        if ($parts.Count -ge 4) {
            $result += @{
                Index   = [int]$parts[0]
                TotalMB = [int]$parts[1]
                UsedMB  = [int]$parts[2]
                FreeMB  = [int]$parts[3]
            }
        }
    }

    return $result
}

<#
.SYNOPSIS
    检测系统内存总量与当前可用量。
.DESCRIPTION
    通过 CIM 查询 Win32_OperatingSystem 获取物理内存总量与可用量（MB）。
.OUTPUTS
    哈希表：TotalMB / AvailableMB / CommittedMB。
#>
function Get-SystemMemoryInfo {
    [CmdletBinding()]
    param()

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) {
        Write-ToolLog "无法获取系统内存信息。" "ERROR"
        return @{ TotalMB = 0; AvailableMB = 0; CommittedMB = 0 }
    }

    # TotalVisibleMemorySize 单位为 KB
    $totalKB     = [long]$os.TotalVisibleMemorySize
    $availableKB = [long]$os.FreePhysicalMemory
    $committedKB = $totalKB - $availableKB

    return @{
        TotalMB     = [math]::Round($totalKB / 1024, 1)
        AvailableMB = [math]::Round($availableKB / 1024, 1)
        CommittedMB = [math]::Round($committedKB / 1024, 1)
    }
}

<#
.SYNOPSIS
    从 GGUF 文件解析模型总层数【监督修正：替换为规范 GGUF v3 元数据解析】。
.DESCRIPTION
    按 GGUF 二进制规范读取头部：magic + version + tensor_count + kv_count，
    遍历键值对查找 *.n_layer（UINT32/INT64）返回层数，解析失败返回 0。
.PARAMETER Path
    GGUF 文件路径。
.OUTPUTS
    总层数（int），解析失败返回 0。
#>
function Get-GgufLayerCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # 按值类型跳过 GGUF 元数据值（含数组），保证流位置不偏移【监督修正】
    function Skip-GgufValue {
        param($br, [int]$type)
        switch ($type) {
            0  { $br.ReadByte() | Out-Null }                    # UINT8
            1  { $br.ReadByte() | Out-Null }                    # INT8
            2  { $br.ReadUInt16() | Out-Null }                  # UINT16
            3  { $br.ReadInt16() | Out-Null }                   # INT16
            4  { $br.ReadUInt32() | Out-Null }                  # UINT32
            5  { $br.ReadInt32() | Out-Null }                   # INT32
            6  { $br.ReadSingle() | Out-Null }                  # FLOAT32
            7  { $br.ReadByte() | Out-Null }                    # BOOL
            8  { $sLen = $br.ReadUInt64(); if ($sLen -lt 64MB) { $br.ReadBytes([int]$sLen) | Out-Null } } # STRING
            9  { $eType = $br.ReadUInt32(); $eCnt = $br.ReadUInt64(); for ($k = 0; $k -lt $eCnt; $k++) { Skip-GgufValue $br $eType } } # ARRAY
            10 { $br.ReadUInt64() | Out-Null }                  # UINT64
            11 { $br.ReadInt64() | Out-Null }                   # INT64
            12 { $br.ReadDouble() | Out-Null }                  # FLOAT64
            default { $br.ReadByte() | Out-Null }
        }
    }

    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $br = New-Object System.IO.BinaryReader($fs)

            # GGUF magic: "GGUF" 小端 = 0x46554747
            $magic = $br.ReadUInt32()
            if ($magic -ne 0x46554747) { return 0 }

            # version / tensor_count / kv_count
            $version   = $br.ReadUInt32() | Out-Null
            $tensorCnt = $br.ReadUInt64() | Out-Null
            $kvCount   = $br.ReadUInt64()

            $found = 0
            for ($i = 0; $i -lt $kvCount; $i++) {
                $keyLen = $br.ReadUInt64()
                if ($keyLen -gt 4096) { break }   # 防御异常长度
                $keyBytes = $br.ReadBytes([int]$keyLen)
                $key = [System.Text.Encoding]::UTF8.GetString($keyBytes)
                $vtype = $br.ReadUInt32()

                # 层数字段：通用 *.n_layer、*.block_count（Qwen 系）或 general.layer_count
                $isLayerKey = ($key -like '*.n_layer') -or ($key -like '*.block_count') -or ($key -eq 'general.layer_count')

                if ($isLayerKey -and ($vtype -eq 4 -or $vtype -eq 11)) {
                    # type 4 = UINT32, type 11 = INT64
                    if ($vtype -eq 4) { $found = [int]$br.ReadUInt32() }
                    else              { $found = [int]$br.ReadInt64() }
                    break
                }

                Skip-GgufValue -br $br -type $vtype
            }

            if ($found -le 0 -or $found -ge 512) { return 0 }
            return $found
        } finally { $fs.Dispose() }
    } catch {
        Write-ToolLog "解析 GGUF 层数异常：$($_.Exception.Message)" "WARN"
        return 0
    }
}

<#
.SYNOPSIS
    根据显存余量计算可卸载到 GPU 的最大层数。
.DESCRIPTION
    核心算法：
      每层权重大小 ≈ 模型文件大小(MB) / 总层数
      GPU 可用显存 = 当前空闲显存 - CUDA 预留 - 计算缓冲区预留
      最大 GPU 层数 = floor(GPU 可用显存 / 每层大小)
    同时钳制在实测安全上限内（8GB 显存机 = 20 层），并保证 CPU 至少 1 层。
.PARAMETER ModelPath
    GGUF 模型文件完整路径。
.PARAMETER GpuFreeMB
    GPU 当前空闲显存（MB），来自 Get-GpuMemoryInfo。
.OUTPUTS
    哈希表：GpuLayers / CpuLayers / TotalLayers / PerLayerMB / ModelSizeMB。
#>
function Calculate-OptimalLayerSplit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModelPath,

        [Parameter(Mandatory = $true)]
        [int]$GpuFreeMB
    )

    # 读取模型文件大小（MB）
    $fileInfo = Get-Item -LiteralPath $ModelPath -ErrorAction Stop
    $modelSizeMB = [math]::Round($fileInfo.Length / 1MB, 2)

    # 从 GGUF 文件头解析总层数
    $totalLayers = [int](Get-GgufLayerCount -Path $ModelPath)

    if ($totalLayers -le 0) {
        Write-ToolLog "无法解析模型总层数，回退为按每 200MB 一层估算。" "WARN"
        $totalLayers = [math]::Max(1, [math]::Floor($modelSizeMB / 200))
    }

    # 每层平均大小
    $perLayerMB = [math]::Round($modelSizeMB / $totalLayers, 2)

    # GPU 可用显存（扣除 CUDA 预留与计算缓冲区预留）
    $gpuUsableMB = $GpuFreeMB - $script:CudaReservedMB - $script:ComputeReserveMB
    if ($gpuUsableMB -lt 0) { $gpuUsableMB = 0 }

    # 最大可卸载层数（按每层大小），并钳制到实测安全上限
    $maxGpuLayers = [math]::Floor($gpuUsableMB / $perLayerMB)
    if ($maxGpuLayers -gt $script:MaxGpuLayersSafe) { $maxGpuLayers = $script:MaxGpuLayersSafe }
    if ($maxGpuLayers -lt 0) { $maxGpuLayers = 0 }
    if ($maxGpuLayers -ge $totalLayers) { $maxGpuLayers = $totalLayers - 1 }

    $cpuLayers = $totalLayers - $maxGpuLayers

    $result = @{
        GpuLayers   = [int]$maxGpuLayers
        CpuLayers   = [int]$cpuLayers
        TotalLayers = [int]$totalLayers
        PerLayerMB  = $perLayerMB
        ModelSizeMB = $modelSizeMB
    }

    Write-ToolLog "层数分配：GPU=$($result.GpuLayers) CPU=$($result.CpuLayers) 总=$($result.TotalLayers) 每层≈$($result.PerLayerMB)MB（安全上限 $($script:MaxGpuLayersSafe)）"
    return $result
}

<#
.SYNOPSIS
    生成带 mmap 与最优层数的 llama-server 启动参数数组。
.DESCRIPTION
    统一内存模式核心参数（b12032 实际验证版）：
      --n-gpu-layers N：将前 N 层卸载到 GPU（CUDA）
      --ctx-size N    ：上下文长度（当前 65536=64K，模型原生 262144）
      --cache-type-k/v：KV 缓存量化（当前 q8_0，qwen35 混合架构仅 16/65 层有 KV，
                        64K 实际 KV 仅约 2.17GB，见 llama_server 日志 KV buffer size）
      mmap 为默认开启，b12032 不接受 --mmap 参数（仅认 --no-mmap）
.PARAMETER GpuLayers
    卸载到 GPU 的层数。
.OUTPUTS
    字符串数组，可直接展开传给 llama-server.exe。
#>
function Build-LlamaServerArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$GpuLayers
    )

    # 【监督修正】数组元素逐行书写（原产出将多个参数写在同一行导致语法错误）
    $args = @(
        # --- 模型与内存映射（统一内存模式核心）---
        "--model"
        $script:ModelPath
        # 【监督修正：b12032 不接受 --mmap（mmap 默认开启，仅认 --no-mmap），删除以免启动秒退】
        "--n-gpu-layers"
        "$GpuLayers"
        # --- 上下文与批处理 ---
        "--ctx-size"
        "$($script:CtxSize)"
        "--batch-size"
        "512"
        "--ubatch-size"
        "128"
        # --- 线程（CPU 部分使用所有逻辑核心）---
        "--threads"
        "$([Environment]::ProcessorCount)"
        "--threads-batch"
        "8"
        # --- KV 缓存量化（降低内存压力）---
        "--cache-type-k"
        "q8_0"
        "--cache-type-v"
        "q8_0"
        # --- 服务监听 ---
        "--host"
        $script:LlamaHost
        "--port"
        "$($script:LlamaPort)"
        # --- 日志级别 ---
        "--verbose"
    )

    return $args
}

<#
.SYNOPSIS
    一键启动统一内存模式下的 llama-server。
.DESCRIPTION
    若已有 llama-server 在运行则先停止（避免端口冲突与显存占满导致层数误算），
    重新检测显存/内存 → 计算层数分配 → 生成参数 → 启动进程 → 等待端口就绪。
.PARAMETER GpuLayers
    可选，手动指定 GPU 层数；不传则自动计算。
#>
function Start-UnifiedMemoryMode {
    [CmdletBinding()]
    param(
        [int]$GpuLayers = -1
    )

    Write-ToolLog "========== 统一内存模式：启动流程 =========="

    # 步骤 0：若 8080 端口已有 llama-server 在运行，先停止【监督修正：
    # 只停本服务端口监听者，避免误杀 8686 等其他 llama-server 实例（如 qwen3-4b）；
    # 先停再算层数，否则显存被旧实例占满会导致层数误算为 0】
    $existingConn = Get-NetTCPConnection -LocalPort $script:LlamaPort -State Listen -ErrorAction SilentlyContinue
    if ($existingConn) {
        $oldPid = [int]$existingConn[0].OwningProcess
        Write-ToolLog "检测到 8080 已有 llama-server (PID $oldPid)，先终止…"
        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    # 步骤 1：检测 GPU 显存（停止旧实例后重新探测）
    $gpuInfo = @(Get-GpuMemoryInfo)
    if ($gpuInfo.Count -eq 0) {
        Write-ToolLog "未检测到 NVIDIA GPU，统一内存模式不可用。" "ERROR"
        return
    }

    # 取第一块显卡的空闲显存（多卡场景可扩展）
    $primaryGpu = $gpuInfo[0]
    Write-ToolLog "GPU[$($primaryGpu.Index)] 总量=$($primaryGpu.TotalMB)MB 已用=$($primaryGpu.UsedMB)MB 空闲=$($primaryGpu.FreeMB)MB"

    # 步骤 2：检测系统内存
    $memInfo = Get-SystemMemoryInfo
    Write-ToolLog "系统内存 总量=$($memInfo.TotalMB)MB 可用=$($memInfo.AvailableMB)MB 已提交=$($memInfo.CommittedMB)MB"

    # 步骤 3：计算最优层数分配
    if ($GpuLayers -ge 0) {
        # 用户手动指定
        $split = @{ GpuLayers = $GpuLayers; CpuLayers = 0; TotalLayers = 0; PerLayerMB = 0; ModelSizeMB = 0 }
        Write-ToolLog "使用手动指定 GPU 层数：$GpuLayers"
    } else {
        $split = Calculate-OptimalLayerSplit -ModelPath $script:ModelPath -GpuFreeMB $primaryGpu.FreeMB
    }

    # 步骤 4：生成启动参数
    $llamaArgs = Build-LlamaServerArgs -GpuLayers $split.GpuLayers
    Write-ToolLog "llama-server 参数：$($llamaArgs -join ' ')"

    # 步骤 5：启动进程
    if (-not (Test-Path -LiteralPath $script:LlamaServerPath)) {
        Write-ToolLog "llama-server.exe 不存在：$($script:LlamaServerPath)" "ERROR"
        return
    }

    # 记录原始参数（用于恢复）
    $script:UnifiedMemoryState.OriginalArgs = $llamaArgs
    $script:UnifiedMemoryState.GpuLayers    = [int]$split.GpuLayers
    $script:UnifiedMemoryState.CpuLayers    = [int]$split.CpuLayers
    $script:UnifiedMemoryState.TotalLayers  = [int]$split.TotalLayers

    # 启动 llama-server（后台、不等待）
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName    = $script:LlamaServerPath
    $psi.Arguments   = ($llamaArgs -join ' ')
    $psi.UseShellExecute = $false
    # 【监督修正：不重定向 stdout/stderr，否则子进程写满管道缓冲会阻塞加载】
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError  = $false
    $psi.CreateNoWindow = $true

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)

        # 【监督修正：pwsh 7/.NET Core 的 StreamReader 无 BeginOutputReadLine，
        # 且 stdout/stderr 无日志消费方，删除本地模型产出的异步读取装饰】

        # 将进程对象写入状态字典，供后续函数引用【本地模型续写】
        $script:UnifiedMemoryState.Process    = $proc
        $script:UnifiedMemoryState.StartTime  = [DateTime]::Now

        # 等待端口就绪（最多 180 秒）【监督修正：64K 上下文首次冷启动加载更慢】
        $portReady = $false
        for ($i = 0; $i -lt 180; $i++) {
            Start-Sleep -Seconds 1
            try {
                $tcp = New-Object System.Net.Sockets.TcpClient
                $tcp.Connect($script:LlamaHost, $script:LlamaPort)
                $tcp.Close()
                $portReady = $true
                break
            } catch {
                # 端口尚未就绪，继续等待
            }
        }

        if (-not $portReady) {
            Write-ToolLog -Level "ERROR" -Message "llama-server 在 60 秒内未监听端口 ${script:LlamaPort}，统一内存模式启动失败。"
            $proc.Kill()
            $script:UnifiedMemoryState.Running = $false
            return $null
        }

        # 写入运行状态标记【本地模型续写】
        $script:UnifiedMemoryState.Running = $true
        Write-ToolLog -Level "INFO" -Message "统一内存模式已启动，llama-server PID=$($proc.Id)，端口=${script:LlamaPort}。"

        # 返回进程对象
        return $proc
    } catch {
        Write-ToolLog -Level "ERROR" -Message "启动 llama-server 出错：$($_.Exception.Message)"
        return $null
    }
}

<#
.SYNOPSIS
    循环采样模型权重在 GPU 显存与系统内存中的驻留分布（本地模型产出）。
.DESCRIPTION
    按指定次数与间隔，每次调用 nvidia-smi 获取显存占用，同时查询系统可用内存，
    据此推算模型权重分别驻留在 GPU 显存和系统内存中的大致比例。
#>
function Monitor-WeightDistribution {
    param(
        [int]$SampleCount = 10,
        [int]$IntervalSec = 3
    )

    Write-ToolLog -Level "INFO" -Message "开始采样权重分布，共 ${SampleCount} 次，间隔 ${IntervalSec} 秒。"

    for ($i = 1; $i -le $SampleCount; $i++) {

        # --- GPU 显存占用（MB）【监督修正：@() 包裹保证数组语义，单卡时不丢索引】---
        $gpuInfo = @(Get-GpuMemoryInfo)
        $gpuUsedMB   = $gpuInfo[0].UsedMB
        $gpuTotalMB  = $gpuInfo[0].TotalMB

        # --- 系统内存可用量（GB）【监督修正：字段名为 AvailableMB/TotalMB】---
        $sysInfo    = Get-SystemMemoryInfo
        $sysAvailGB = [math]::Round($sysInfo.AvailableMB / 1024, 2)
        $sysTotalGB = [math]::Round($sysInfo.TotalMB / 1024, 2)

        # --- 推算权重分布 ---
        # 模型文件总大小（MB），用于估算权重总量
        if (Test-Path $script:ModelPath) {
            $modelSizeMB = [math]::Round((Get-Item $script:ModelPath).Length / 1MB, 1)
        } else {
            $modelSizeMB = 0
        }

        # GPU 上驻留的权重估算（MB）：取显存占用中扣除框架开销后的部分
        $frameworkOverheadMB = 256
        $gpuWeightMB = [math]::Max(0, $gpuUsedMB - $frameworkOverheadMB)
        $gpuWeightPct = if ($modelSizeMB -gt 0) { [math]::Round(($gpuWeightMB / $modelSizeMB) * 100, 1) } else { 0 }

        # 系统内存中驻留的权重估算（GB）
        $sysWeightGB = [math]::Max(0, ($modelSizeMB - $gpuWeightMB) / 1024)
        $sysWeightPct = [math]::Round(100 - $gpuWeightPct, 1)

        # --- 输出当前采样行 ---
        $line = ("[{0}/{1}] GPU显存: {2} MB (权重≈{3} MB, {4}%) | 系统内存可用: {5} GB (权重≈{6} GB, {7}%)" -f `
            $i, $SampleCount, $gpuUsedMB, $gpuWeightMB, $gpuWeightPct, $sysAvailGB, $sysWeightGB, $sysWeightPct)
        Write-Host $line

        # 日志记录
        Write-ToolLog -Level "DEBUG" -Message $line

        if ($i -lt $SampleCount) {
            Start-Sleep -Seconds $IntervalSec
        }
    }

    Write-ToolLog -Level "INFO" -Message "权重分布采样完成。"
}

<#
.SYNOPSIS
    单次采样并显示当前 GPU 显存占用与系统内存占用概况（本地模型产出）。
#>
function Show-MemoryStatus {
    # GPU 显存（MB）【监督修正：@() 包裹保证数组语义】
    $gpuInfo = @(Get-GpuMemoryInfo)
    $gpuUsedMB  = $gpuInfo[0].UsedMB
    $gpuTotalMB = $gpuInfo[0].TotalMB

    # 系统内存（GB）【监督修正：字段名为 AvailableMB/TotalMB】
    $sysInfo    = Get-SystemMemoryInfo
    $sysAvailGB = [math]::Round($sysInfo.AvailableMB / 1024, 2)
    $sysTotalGB = [math]::Round($sysInfo.TotalMB / 1024, 2)
    $sysUsedGB  = [math]::Round($sysTotalGB - $sysAvailGB, 2)

    # 格式化输出
    $statusLine = ("GPU显存占用: {0} MB / {1} MB | 系统内存占用: {2} GB / {3} GB (可用 {4} GB)" -f `
        $gpuUsedMB, $gpuTotalMB, $sysUsedGB, $sysTotalGB, $sysAvailGB)

    Write-Host $statusLine
    Write-ToolLog -Level "INFO" -Message $statusLine

    # 返回结构化数据供调用方使用
    return @{
        GpuUsedMB      = $gpuUsedMB
        GpuTotalMB     = $gpuTotalMB
        SysAvailGB     = $sysAvailGB
        SysTotalGB     = $sysTotalGB
        SysUsedGB      = $sysUsedGB
    }
}

<#
.SYNOPSIS
    停止统一内存模式下的 llama-server 进程，清理状态并恢复原参数（本地模型产出）。
#>
function Stop-UnifiedMemoryMode {

    if (-not $script:UnifiedMemoryState -or -not $script:UnifiedMemoryState.Process) {
        Write-ToolLog -Level "WARN" -Message "当前无运行中的统一内存模式，无需停止。"
        return
    }

    $proc = $script:UnifiedMemoryState.Process

    if ($proc -and -not $proc.HasExited) {
        Write-ToolLog -Level "INFO" -Message "正在停止 llama-server (PID=$($proc.Id))..."
        try {
            # 优先使用 Kill 确保进程终止
            $proc.Kill()
            $proc.WaitForExit(10000)
            if (-not $proc.HasExited) {
                Write-ToolLog -Level "WARN" -Message "进程未在 10 秒内退出，尝试强制结束。"
                [System.Diagnostics.Process]::Kill($proc.Id)
            }
        } catch {
            Write-ToolLog -Level "ERROR" -Message "停止 llama-server 时出错: $($_.Exception.Message)"
        }

        # 释放异步读取器资源
        if ($script:UnifiedMemoryState.OutputReader) {
            try { $script:UnifiedMemoryState.OutputReader.Dispose() } catch {}
        }
        if ($script:UnifiedMemoryState.ErrorReader) {
            try { $script:UnifiedMemoryState.ErrorReader.Dispose() } catch {}
        }

        Write-ToolLog -Level "INFO" -Message "llama-server 已停止。"
    } else {
        Write-ToolLog -Level "WARN" -Message "llama-server 进程已不存在，跳过停止操作。"
    }

    # 恢复原参数（如果保存了原始参数）
    if ($script:UnifiedMemoryState.OriginalArgs) {
        Write-ToolLog -Level "INFO" -Message "已记录原始启动参数，可供后续恢复使用：$($script:UnifiedMemoryState.OriginalArgs -join ' ')"
    }

    # 清理状态字典
    $script:UnifiedMemoryState.Running    = $false
    $script:UnifiedMemoryState.Process    = $null
    $script:UnifiedMemoryState.OutputReader = $null
    $script:UnifiedMemoryState.ErrorReader  = $null
    Write-ToolLog -Level "INFO" -Message "统一内存模式状态已清理。"
}

# ============================================================
# 区域三：命令行入口（dot-source 时不执行）
# 用法：pwsh -File 统一内存模式.ps1 start|stop|status|monitor|test [-GpuLayers N] [-Samples N]
# ============================================================
if ($MyInvocation.InvocationName -ne '.') {
    $action = if ($args.Count -ge 1) { [string]$args[0] } else { "status" }
    $gpuLayersArg = -1
    $samplesArg = 10
    for ($i = 1; $i -lt $args.Count; $i++) {
        if ($args[$i] -eq '-GpuLayers' -and $i + 1 -lt $args.Count) { $gpuLayersArg = [int]$args[$i+1]; $i++ }
        if ($args[$i] -eq '-Samples'   -and $i + 1 -lt $args.Count) { $samplesArg  = [int]$args[$i+1]; $i++ }
    }

    switch ($action) {
        "start"   { $p = Start-UnifiedMemoryMode -GpuLayers $gpuLayersArg; if ($p) { Write-Host "已启动，PID=$($p.Id)" } }
        "stop"    { Stop-UnifiedMemoryMode }
        "status"  { Show-MemoryStatus }
        "monitor" { Monitor-WeightDistribution -SampleCount $samplesArg }
        "test"    { Write-Host "请运行独立测试脚本 Test-UnifiedMemoryPerf.ps1" }
        default   { Write-Host "用法: pwsh -File 统一内存模式.ps1 start|stop|status|monitor|test [-GpuLayers N] [-Samples N]" }
    }
}
