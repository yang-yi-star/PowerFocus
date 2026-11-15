#Requires -Version 7.0
# ============================================================
# nl-parser.ps1 —— 自然语言规则解析器（NL 网关的函数库）
# 快速路径：不依赖任何模型，正则规则把中文指令映射为命令 JSON。
# 返回约定:
#   成功 → [hashtable] 命令对象（不含 token，token 由网关注入）
#   失败 → $null
# 说明字段: 返回 hashtable 附 "_explain" 键（人可读的解释）
# 本文件为纯函数库，供 dot-source。
# ============================================================

function Get-MatchingProcessName {
    # 从指令文本中匹配一个正在运行的进程名（最长名优先，避免 "python" 抢了 "llama-server" 里不含的——
    # 实际风险是短名子串误命中，如 "svchost" 匹配 "host"，所以只做整词/完整子串匹配且最长优先）
    param([string]$Text)
    $names = @(Get-Process -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty ProcessName -Unique |
               Sort-Object Length -Descending)
    foreach ($n in $names) {
        if ($n.Length -lt 3) { continue }   # 过短名字易误命中，跳过
        if ($Text.IndexOf($n, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $n }
    }
    return $null
}

function Get-PriorityKeyword {
    # 从文本提取优先级关键词
    param([string]$Text)
    if ($Text -match '实时|realtime|real\s*time') { return 'RealTime' }
    if ($Text -match '最高|highest|\bhigh\b|高优先') { return 'High' }
    if ($Text -match '高于正常|abovenormal|above\s*normal') { return 'AboveNormal' }
    if ($Text -match '正常|\bnormal\b') { return 'Normal' }
    if ($Text -match '低于正常|belownormal|below\s*normal') { return 'BelowNormal' }
    if ($Text -match '最低|\bidle\b|空闲') { return 'Idle' }
    return $null
}

function ConvertFrom-NaturalLanguage {
    # 规则解析主入口：中文自然语言 → 命令 hashtable
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    $proc = Get-MatchingProcessName $t

    # ---- 1. 状态查询 ----
    if ($t -match '状态|怎么样|什么情况|看看现在|当前.*(资源|负载|占用)|status') {
        return @{
            action = 'status'
            _explain = "查询调度中心与整机状态"
        }
    }

    # ---- 2. 解除聚焦 ----
    # 注意：'解除'一词太宽（会截胡"解除限速"），这里只认聚焦语境
    if ($t -match '解除聚焦|取消聚焦|放开|恢复正常|别.*聚焦|停止聚焦|聚焦.*解除|stop\s*focus') {
        return @{
            action = 'unfocus'
            _explain = "解除聚焦，所有进程按原值还原"
        }
    }

    # ---- 3. 撤销授权（比授权判断更靠前，避免"取消授权"被"授权"规则截胡）----
    if ($t -match '撤销授权|取消授权|移出清单|收回权限|revoke') {
        if (-not $proc) { return @{ _error = "想撤销谁？指令里没认出进程名"; _needProcess = $true } }
        return @{
            action = 'revoke'
            process_name = $proc
            _explain = "撤销 $proc 的授权（需人工确认）"
            _sensitive = $true
        }
    }

    # ---- 4. 授权（加入清单）----
    if ($t -match '授权|加入清单|加入白名单|永久.*(权限|后门)') {
        if (-not $proc) { return @{ _error = "想授权谁？指令里没认出进程名"; _needProcess = $true } }
        $level = 'high'
        if ($t -match '实时|realtime') { $level = 'realtime' }
        return @{
            action = 'authorize'
            process_name = $proc
            level = $level
            _explain = "把 $proc 加入授权清单（级别 $level，需人工确认）"
            _sensitive = $true
        }
    }

    # ---- 5. 阶段三：磁盘 I/O 优先级（必须排在聚焦规则之前，否则"优先级"被聚焦正则截胡）----
    if ($t -match '\bio\b\s*优先|i/o\s*优先|磁盘(读写)?优先') {
        if (-not $proc) { return @{ _error = "要设谁的 I/O 优先级？指令里没认出进程名"; _needProcess = $true } }
        $ioName = $null
        if ($t -match '最高|high') { $ioName = 'High' }
        elseif ($t -match '最低|very\s*low') { $ioName = 'VeryLow' }
        elseif ($t -match '压低|调低|降低|low') { $ioName = 'Low' }
        elseif ($t -match '正常|normal') { $ioName = 'Normal' }
        if (-not $ioName) { return @{ _error = "听不出 I/O 优先级档位（最高/正常/压低/最低）"; _needPriority = $true } }
        return @{
            action = 'set_io_priority'
            process_name = $proc
            priority = $ioName
            _explain = "把 $($proc) 磁盘 I/O 优先级设为 $ioName"
        }
    }

    # ---- 6. 聚焦类（开后门 = GodMode）----
    if ($t -match '开后门|神模式|godmode|全部?算力|最大算力|最高调度|全力.*(跑|干|冲)') {
        if (-not $proc) { return @{ _error = "想给谁开后门？指令里没认出进程名"; _needProcess = $true } }
        return @{
            action = 'focus'
            process_name = $proc
            mode = 'godmode'
            _explain = "对 $proc 开后门（GodMode：最高优先级+性能电源+守护）"
        }
    }
    if ($t -match '激进|压制(其他|别的)?(进程|程序)|独占') {
        if (-not $proc) { return @{ _error = "想激进聚焦谁？指令里没认出进程名"; _needProcess = $true } }
        return @{
            action = 'focus'
            process_name = $proc
            mode = 'aggressive'
            _explain = "对 $proc 激进聚焦（同时压制其他进程）"
        }
    }
    if ($t -match '聚焦|专注|加速|优先(级)?\s*(给|让)?|火力全开|focus') {
        if ($t -match '优先级') {
            # "把 X 优先级设为 Y" 走 set_priority，不落进聚焦
            $pri = Get-PriorityKeyword $t
            if ($pri -and $proc) {
                return @{
                    action = 'set_priority'
                    process_name = $proc
                    priority = $pri
                    _explain = "把 $proc 优先级设为 $pri"
                }
            }
            if (-not $proc) { return @{ _error = "要设谁的优先级？指令里没认出进程名"; _needProcess = $true } }
            return @{ _error = "听不出目标优先级（实时/高/正常/低…）"; _needPriority = $true }
        }
        if (-not $proc) { return @{ _error = "想聚焦谁？指令里没认出进程名"; _needProcess = $true } }
        return @{
            action = 'focus'
            process_name = $proc
            mode = 'gentle'
            _explain = "对 $proc 温和聚焦"
        }
    }

    # ---- 6. 单独的优先级设置 ----
    if ($t -match '优先级|priority') {
        $pri = Get-PriorityKeyword $t
        if ($pri -and $proc) {
            return @{
                action = 'set_priority'
                process_name = $proc
                priority = $pri
                _explain = "把 $proc 优先级设为 $pri"
            }
        }
        if (-not $proc) { return @{ _error = "要设谁的优先级？指令里没认出进程名"; _needProcess = $true } }
        return @{ _error = "听不出目标优先级（实时/高/正常/低…）"; _needPriority = $true }
    }

    # ---- 7. 电源计划 ----
    if ($t -match '高性能|性能拉满|火力全开.*电源') {
        return @{
            action = 'set_power_plan'
            plan = 'high'
            _explain = "切换到高性能电源计划"
        }
    }
    if ($t -match '平衡电源|省电|balanced') {
        return @{
            action = 'set_power_plan'
            plan = 'balanced'
            _explain = "切换到平衡电源计划"
        }
    }

    # ---- 8. 阶段三：场景模式 ----
    if ($t -match '有哪些场景|列出场景|什么场景|list\s*scenes') {
        return @{ action = 'list_scenes'; _explain = "列出可用场景" }
    }
    if ($t -match '推理模式|inference') {
        return @{ action = 'apply_scene'; scene = 'inference'; _explain = "应用场景 [inference]：llama-server 全力 + 内存修剪 + 高性能电源" }
    }
    if ($t -match '游戏模式|gaming') {
        return @{ action = 'apply_scene'; scene = 'gaming'; _explain = "应用场景 [gaming]：高性能电源 + 后台内存修剪" }
    }
    if ($t -match '还原模式|放松模式|全部还原|relax') {
        return @{ action = 'apply_scene'; scene = 'relax'; _explain = "应用场景 [relax]：解除聚焦 + 平衡电源" }
    }
    if ($t -match '应用场景|切换场景|进入场景|场景模式') {
        # 提取场景名：取已知场景名匹配，或取英文单词
        foreach ($sn in @('inference','gaming','relax')) {
            if ($t.IndexOf($sn, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return @{ action = 'apply_scene'; scene = $sn; _explain = "应用场景 [$sn]" }
            }
        }
        return @{ _error = "听不出场景名（推理/游戏/还原，或场景文件里自定义的英文名）"; _needScene = $true }
    }

    # ---- 10. 阶段三：内存修剪 ----
    if ($t -match '修剪.*内存|释放.*内存|清[理空除].*内存|腾出.*内存|内存.*(清理|释放|修剪|腾出)|memory\s*trim') {
        return @{
            action = 'trim_memory'
            exclude_target = $true
            _explain = "修剪非白名单进程工作集，释放物理内存"
        }
    }

    # ---- 11. 阶段三：网络限速 ----
    if ($t -match '限速| throttle|net\s*qos') {
        if ($t -match '取消.*限速|解除.*限速|撤销.*限速') {
            if (-not $proc) { return @{ _error = "要解除谁的限速？指令里没认出进程名"; _needProcess = $true } }
            return @{ action = 'set_net_qos'; process_name = $proc; rate_mbps = 0; _explain = "解除 $proc 的网络限速" }
        }
        if (-not $proc) { return @{ _error = "要限速谁？指令里没认出进程名"; _needProcess = $true } }
        $m = [regex]::Match($t, '(\d+(\.\d+)?)')
        if (-not $m.Success) { return @{ _error = "没听出限速数值（Mbps），例：给 chrome 限速 2 兆"; _needRate = $true } }
        return @{
            action = 'set_net_qos'
            process_name = $proc
            rate_mbps = [double]$m.Groups[1].Value
            _explain = "把 $($proc) 网络限速为 $($m.Groups[1].Value) Mbps（需管理员权限）"
        }
    }

    # ---- 12. 未识别 ----
    return $null
}

# dot-source 保护（本文件纯函数库，无主入口，防御性保留）
if ($MyInvocation.InvocationName -eq '.') { return }
