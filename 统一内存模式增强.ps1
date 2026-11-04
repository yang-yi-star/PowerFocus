# =============================================================
# 统一内存模式增强模块（监督修正版 v2）
# 依据：本地模型自主决策（候选B深化：性能骤降告警+上下文余量估算）
# 监督修正 v2（豆包实测 b12032 + PowerShell 行为后修正）：
#   1. /slots 无 n_past 字段，实际为 n_prompt_tokens 与 n_prompt_tokens_cache
#   2. /slots 无 tps 字段，速度改用 next_token[0].n_decoded 差分计算
#   3. /metrics 端点未启用（501），不作为数据源
#   4. POST /slots 返回 404，b12032 无在线清槽 API
#      Invoke-ContextCleanup 改用 Start-UnifiedMemoryMode 重启式释放 KV
#   5. PowerShell 双引号插值坑：$script:LlamaHost 后接冒号会被吞进变量名，
#      所有 URL 必须用 ${script:LlamaHost} 花括号显式限定
#   6. Get-GpuMemoryInfo 本机单 GPU 时返回单个哈希表而非数组，
#      空返回时 GpuFreeMB 置 -1 表示未知，避免误告警
# 集成方式：在统一内存模式.ps1 末尾追加以下行
#   . 'E:\PowerFocus\统一内存模式增强.ps1'
# =============================================================

# 功能：查询 /slots 接口获取活跃槽位已用 token 数，计算剩余上下文 token 数
# 功能：结合实测 KV 系数 0.0332 MiB/token 估算 KV 显存占用，采样 GPU 空闲显存
# 功能：输出哈希表，含 RemainingTokens、ContextUsedPct、KvCacheMB、GpuFreeMB、Healthy
# 注意：b12032 /slots 字段为 n_prompt_tokens 与 n_prompt_tokens_cache，无 n_past
function Get-ContextRemainingEstimate {
    param(
        [int]$Port = 8080,
        [double]$KvPerTokenMiB = 0.0332
    )

    $result = @{
        RemainingTokens = 0
        ContextUsedPct  = 0.0
        KvCacheMB       = 0.0
        GpuFreeMB       = -1
        Healthy         = $false
    }

    try {
        $url = "http://${script:LlamaHost}:$Port/slots"
        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 5
    }
    catch {
        Write-ToolLog -Message "查询 /slots 接口失败，端口 $Port，错误 $($_.Exception.Message)" -Level WARN
        return $result
    }

    $slot = $null
    if ($response -is [System.Array]) {
        $slot = $response | Select-Object -First 1
    }
    else {
        $slot = $response
    }
    if ($null -eq $slot) {
        Write-ToolLog -Message "未获取到活跃槽位数据，端口 $Port" -Level WARN
        return $result
    }

    # b12032 实际字段：n_prompt_tokens 当前任务输入 token 数，n_prompt_tokens_cache 缓存 token 数
    $promptTokens = 0
    $cacheTokens  = 0
    if ($null -ne $slot.PSObject.Properties['n_prompt_tokens']) {
        $promptTokens = [int]$slot.n_prompt_tokens
    }
    if ($null -ne $slot.PSObject.Properties['n_prompt_tokens_cache']) {
        $cacheTokens = [int]$slot.n_prompt_tokens_cache
    }
    $usedTokens = [Math]::Max($promptTokens, $cacheTokens)
    $nCtx = [int]$slot.n_ctx
    if ($nCtx -le 0) { $nCtx = 65536 }

    $remainingTokens = [Math]::Max(0, $nCtx - $usedTokens)
    $contextUsedPct = [Math]::Round(($usedTokens / $nCtx) * 100, 2)

    # GPU 显存采样：本机单 GPU 时返回单个哈希表，多 GPU 返回数组
    $gpuInfo = Get-GpuMemoryInfo
    $gpuFreeMB = -1
    if ($gpuInfo -is [System.Array] -and $gpuInfo.Count -gt 0) {
        $gpuFreeMB = [int]$gpuInfo[0].FreeMB
    }
    elseif ($gpuInfo -is [System.Collections.IDictionary] -and $gpuInfo.ContainsKey('FreeMB')) {
        $gpuFreeMB = [int]$gpuInfo['FreeMB']
    }
    if ($gpuFreeMB -lt 0) {
        Write-ToolLog -Message "GPU 显存信息获取失败，跳过显存健康判定" -Level WARN
    }

    # 实测系数：Qwen3.8-27B 混合架构仅 16/65 层有 KV，64K 全满 KV 实测 2176 MiB
    $kvCacheMB = [Math]::Round($usedTokens * $KvPerTokenMiB, 2)

    # 健康判定：剩余 token 大于总长 10%，且显存信息可用且空闲大于 512 MB
    $healthy = ($remainingTokens -gt ($nCtx * 0.1)) -and ($gpuFreeMB -gt 512)

    $result.RemainingTokens = $remainingTokens
    $result.ContextUsedPct  = $contextUsedPct
    $result.KvCacheMB       = $kvCacheMB
    $result.GpuFreeMB       = $gpuFreeMB
    $result.Healthy         = $healthy

    return $result
}

# 功能：维护脚本级采样队列 $script:PerfSamples 保存最近 10 次速度采样值
# 功能：当前速度低于基线速度 50% 判定为性能骤降，返回哈希表含 Degraded 等字段
# 注意：基线应取受管基线实测速度 3.7 t/s，不取滑动队列最大值，避免基线随降
function Test-PerformanceDegradation {
    param(
        [double]$CurrentTps,
        [double]$BaselineTps = 3.7,
        [double]$DegradeRatio = 0.5
    )

    if ($null -eq $script:PerfSamples) {
        $script:PerfSamples = @()
    }
    $script:PerfSamples += $CurrentTps
    if ($script:PerfSamples.Count -gt 10) {
        $script:PerfSamples = $script:PerfSamples[1..($script:PerfSamples.Count - 1)]
    }

    if ($BaselineTps -gt 0) {
        $ratio = [Math]::Round($CurrentTps / $BaselineTps, 4)
    }
    else {
        $ratio = 0.0
    }
    $degraded = ($ratio -lt $DegradeRatio)

    if ($degraded) {
        Write-ToolLog -Message "检测到性能骤降，当前速度 $CurrentTps tps，基线速度 $BaselineTps tps，比值 $ratio" -Level WARN
    }

    return @{
        Degraded    = $degraded
        CurrentTps  = $CurrentTps
        BaselineTps = $BaselineTps
        Ratio       = $ratio
        QueueLength = $script:PerfSamples.Count
    }
}

# 功能：清理上下文释放 KV 显存
# 注意：b12032 无在线清槽 API，POST /slots 返回 404，/metrics 未启用
# 注意：唯一可靠释放全部 KV 的方式是重启实例，复用 Start-UnifiedMemoryMode 的停旧起新能力
# 功能：默认仅提示，AutoRestart 为真时自动重启释放
function Invoke-ContextCleanup {
    param(
        [switch]$AutoRestart
    )

    Write-ToolLog -Message "上下文清理触发：b12032 无在线清槽 API，重启实例可释放全部 KV 显存并恢复基线速度" -Level WARN

    if ($AutoRestart) {
        Write-ToolLog -Message "自动重启统一内存模式实例以释放 KV 显存" -Level INFO
        try {
            if (Get-Command Start-UnifiedMemoryMode -ErrorAction SilentlyContinue) {
                Start-UnifiedMemoryMode
                Write-ToolLog -Message "统一内存模式实例重启完成" -Level INFO
                return $true
            }
            else {
                Write-ToolLog -Message "未找到 Start-UnifiedMemoryMode 函数，请先 dot-source 统一内存模式.ps1" -Level ERROR
                return $false
            }
        }
        catch {
            Write-ToolLog -Message "重启失败，错误 $($_.Exception.Message)" -Level ERROR
            return $false
        }
    }
    else {
        Write-ToolLog -Message "未启用自动重启，请手动执行 Start-UnifiedMemoryMode 释放 KV 显存" -Level WARN
        return $false
    }
}

# 功能：增强版权重分布监控，集成上下文余量估算与性能骤降检测
# 功能：速度来源为 /slots 的 next_token[0].n_decoded 差分，空闲时跳过测速不误告警
# 功能：告警阈值：性能骤降、上下文使用超 90%、显存空闲低于 512 MB，默认仅提示不自动清理
function Monitor-WeightDistributionEnhanced {
    param(
        [int]$SampleCount = 10,
        [int]$IntervalSec = 5,
        [double]$BaselineTps = 3.7,
        [switch]$AutoCleanup
    )

    Write-ToolLog -Message "开始增强版监控，采样 $SampleCount 次，间隔 $IntervalSec 秒，基线速度 $BaselineTps tps" -Level INFO

    $script:LastDecoded = 0
    $script:LastSampleTime = [DateTime]::MinValue

    for ($i = 1; $i -le $SampleCount; $i++) {
        $gpuInfo = Get-GpuMemoryInfo
        $sysInfo = Get-SystemMemoryInfo
        $ctxEstimate = Get-ContextRemainingEstimate -Port $script:LlamaPort

        # 速度差分：从 /slots 的 next_token[0].n_decoded 采样差值除以时间间隔
        $currentTps = 0.0
        $isProcessing = $false
        try {
            $slotUrl = "http://${script:LlamaHost}:$($script:LlamaPort)/slots"
            $slotResponse = Invoke-RestMethod -Uri $slotUrl -Method Get -TimeoutSec 5
            $slot = if ($slotResponse -is [System.Array]) { $slotResponse | Select-Object -First 1 } else { $slotResponse }
            if ($null -ne $slot) {
                if ($null -ne $slot.PSObject.Properties['is_processing']) {
                    $isProcessing = [bool]$slot.is_processing
                }
                $decodedNow = 0
                if ($null -ne $slot.PSObject.Properties['next_token'] -and $slot.next_token.Count -gt 0) {
                    $decodedNow = [int]$slot.next_token[0].n_decoded
                }
                $now = Get-Date
                if ($script:LastSampleTime -ne [DateTime]::MinValue -and $isProcessing) {
                    $elapsedSec = ($now - $script:LastSampleTime).TotalSeconds
                    $delta = $decodedNow - $script:LastDecoded
                    if ($elapsedSec -gt 0 -and $delta -gt 0) {
                        $currentTps = [Math]::Round($delta / $elapsedSec, 2)
                    }
                }
                $script:LastDecoded = $decodedNow
                $script:LastSampleTime = $now
            }
        }
        catch {
            Write-ToolLog -Message "获取槽位速度失败 $($_.Exception.Message)" -Level DEBUG
        }

        # 空闲或差分未建立时跳过测速：速度 0 可能是首轮采样或生成间隙，不能当骤降
        $perfResult = $null
        if ($isProcessing -and $currentTps -gt 0) {
            $perfResult = Test-PerformanceDegradation -CurrentTps $currentTps -BaselineTps $BaselineTps
        }

        $gpuLine = ""
        if ($gpuInfo -is [System.Array] -and $gpuInfo.Count -gt 0) {
            $gpuLine = "GPU0 总 $([Math]::Round($gpuInfo[0].TotalMB / 1024, 2)) GB 已用 $([Math]::Round($gpuInfo[0].UsedMB / 1024, 2)) GB 空闲 $([Math]::Round($gpuInfo[0].FreeMB / 1024, 2)) GB"
        }
        elseif ($gpuInfo -is [System.Collections.IDictionary] -and $gpuInfo.ContainsKey('TotalMB')) {
            $gpuLine = "GPU0 总 $([Math]::Round($gpuInfo['TotalMB'] / 1024, 2)) GB 已用 $([Math]::Round($gpuInfo['UsedMB'] / 1024, 2)) GB 空闲 $([Math]::Round($gpuInfo['FreeMB'] / 1024, 2)) GB"
        }
        else {
            $gpuLine = "GPU 显存信息不可用"
        }
        $sysLine = "系统 总 $([Math]::Round($sysInfo.TotalMB / 1024, 2)) GB 可用 $([Math]::Round($sysInfo.AvailableMB / 1024, 2)) GB 已提交 $([Math]::Round($sysInfo.CommittedMB / 1024, 2)) GB"
        $ctxLine = "上下文剩余 $([int]$ctxEstimate.RemainingTokens) tokens 使用 $([Math]::Round($ctxEstimate.ContextUsedPct, 1))% KV估算 $([Math]::Round($ctxEstimate.KvCacheMB, 1)) MB"
        $perfLine = "速度 $currentTps tps 基线 $BaselineTps tps"
        if ($null -ne $perfResult) { $perfLine += " 比值 $($perfResult.Ratio)" }

        $outputLine = "[$i/$SampleCount] $gpuLine | $sysLine | $ctxLine | $perfLine"
        Write-ToolLog -Message $outputLine -Level INFO

        $needWarn = $false
        $warnReasons = @()
        if ($null -ne $perfResult -and $perfResult.Degraded) {
            $needWarn = $true
            $warnReasons += "性能骤降"
        }
        if ($ctxEstimate.ContextUsedPct -gt 90.0) {
            $needWarn = $true
            $warnReasons += "上下文使用超过 90%"
        }
        if ($ctxEstimate.GpuFreeMB -ge 0 -and $ctxEstimate.GpuFreeMB -lt 512) {
            $needWarn = $true
            $warnReasons += "显存空闲低于 512 MB"
        }
        if ($needWarn) {
            $reasonStr = $warnReasons -join "，"
            Write-ToolLog -Message "告警 $reasonStr，可执行 Invoke-ContextCleanup 清理上下文" -Level WARN
            if ($AutoCleanup) {
                Invoke-ContextCleanup -AutoRestart
            }
        }

        if ($i -lt $SampleCount) {
            Start-Sleep -Seconds $IntervalSec
        }
    }

    Write-ToolLog -Message "增强版权重分布监控完成" -Level INFO
}
