# ============================================================
# 电脑算力调度中心 v2 · 阶段四：规则引擎（rules-engine.ps1）
# 基于全网备料（Process Lasso ProBalance / Process Governor /
# Microsoft RulesEngine / Windows EcoQoS 官方 API）设计：
#   - 条件 → 动作 → 自动还原（ProBalance 临时调整范式）
#   - 前台进程保护（永不降级当前前台窗口的进程）
#   - EcoQoS 效率模式（官方功率节流 API，比手动改优先级更温和）
#   - CPU 亲和性绑核（SetProcessAffinityMask）
# 铁律：本文件可被 电脑算力调度中心_v2.ps1 dot-source 复用，
#       也可独立 dot-source 测试；不修改任何既有 v1 文件。
# 注意：参数一律用 $ProcId，禁止 $Pid/$pid（只读自动变量 $PID，
#       变量名不区分大小写，赋值即抛"无法覆盖变量 Pid"）。
# 用法: . E:\PowerFocus\rules-engine.ps1
#       Start-RulesEngine           # 2s 评估循环
#       Stop-RulesEngine            # 停止
#       Invoke-RulesEngineOnce      # 单次评估（测试用）
# ============================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------- Win32 入口（EcoQoS 功率节流 / CPU 亲和性 / 前台窗口） ----------
if (-not ("PowerFocus.RulesNative" -as [type])) {
Add-Type -Namespace PowerFocus -Name RulesNative -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool SetProcessAffinityMask(System.IntPtr hProcess, System.UIntPtr dwProcessAffinityMask, out System.UIntPtr lpSystemAffinityMask);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);

[StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct PROCESS_POWER_THROTTLING_STATE {
    public uint Version;
    public uint ControlMask;
    public uint StateMask;
}
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool SetProcessInformation(System.IntPtr hProcess, int ProcessInformationClass, ref PROCESS_POWER_THROTTLING_STATE ProcessInformation, uint ProcessInformationSize);
'@
}

# ---------- 全局状态 ----------
$script:RulesRunning    = $false
$script:RuleFile        = Join-Path $PSScriptRoot "rules.json"
$script:RulesStateFile  = Join-Path $PSScriptRoot "rules_state.json"
$script:RulesLog        = Join-Path $PSScriptRoot "电脑算力调度中心_v2.log"
$script:CpuSamples      = @{}     # procId -> @{PrevTotal; PrevTime}
$script:RuleActive      = @{}     # ruleName-procId -> @{ProcId; Since; Rule; Prev}
$script:RuleConditionAt = @{}     # ruleName -> @{ProcId; Since}  条件成立起始时间
$script:RulesLoadedAt   = $null   # 规则文件重读节流
$script:CachedRules     = $null
$script:RulesSkip       = @('Idle','System','Registry','Memory Compression','csrss','dwm','explorer','winlogon','lsass','services','svchost','fontdrvhost','conhost','Taskmgr','RuntimeBroker','ShellExperienceHost','SearchHost','TextInputHost','StartMenuExperienceHost','pwsh','powershell','python','DoubaoWork','llama-server','WmiPrvSE','sihost','taskhostw','ctfmon','audiodg','smss','wininit','spoolsv','SecurityHealthService','MsMpEng','NisSrv','Secure System','SystemSettings','ApplicationFrameHost')

# ---------- 日志（优先复用调用方 v2 的 Write-Log，独立测试时自建） ----------
function Write-RuleLog {
    param([string]$Level, [string]$Msg)
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) { Write-Log -Level $Level -Msg $Msg; return }
    try {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -LiteralPath $script:RulesLog -Value "$ts [$Level] [rules] $Msg" -Encoding utf8
    } catch {}
}

# ---------- CPU% 采样（两次 TotalProcessorTime 差分，评估间隔为窗口） ----------
function Get-CpuPct {
    param([int]$ProcId, [double]$IntervalSec)
    $p = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $now = Get-Date
    $prev = $script:CpuSamples[$ProcId]
    if ($null -eq $prev) {
        $script:CpuSamples[$ProcId] = @{ PrevTotal = $p.TotalProcessorTime.TotalSeconds; PrevTime = $now }
        return 0.0
    }
    $dTotal = $p.TotalProcessorTime.TotalSeconds - $prev.PrevTotal
    $dTime  = ($now - $prev.PrevTime).TotalSeconds
    $script:CpuSamples[$ProcId] = @{ PrevTotal = $p.TotalProcessorTime.TotalSeconds; PrevTime = $now }
    if ($dTime -le 0) { return 0.0 }
    $cores = [Math]::Max(1, $env:NUMBER_OF_PROCESSORS)
    # 差分秒数 ÷ 窗口秒数 ÷ 核数，得到单进程相对整机算力的百分比
    return [Math]::Round(($dTotal / $dTime / $cores) * 100, 1)
}

# ---------- 前台进程保护（ProBalance 原则：前台进程永不降级） ----------
function Get-ForegroundPid {
    $hwnd = [PowerFocus.RulesNative]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $pidOut = 0
    [PowerFocus.RulesNative]::GetWindowThreadProcessId($hwnd, [ref]$pidOut) | Out-Null
    if ($pidOut -eq 0) { return $null }
    return $pidOut
}

# ---------- 读取规则（热更新：每分钟最多重读一次） ----------
function Read-RuleFile {
    if ($null -ne $script:RulesLoadedAt -and ((Get-Date) - $script:RulesLoadedAt).TotalSeconds -lt 60) {
        return $script:CachedRules
    }
    if (-not (Test-Path -LiteralPath $script:RuleFile)) {
        Write-RuleLog "WARN" "规则文件不存在: $script:RuleFile"
        return $null
    }
    try {
        $cfg = Get-Content -Raw -LiteralPath $script:RuleFile -Encoding utf8 | ConvertFrom-Json
        $script:CachedRules = $cfg.rules
        $script:RulesLoadedAt = Get-Date
        return $script:CachedRules
    } catch {
        Write-RuleLog "ERROR" "规则文件解析失败: $_"
        return $null
    }
}

# ---------- 匹配条件 ----------
function Test-RuleCondition {
    param($Cond, [object]$Proc, [double]$CpuPct, [double]$IntervalSec, [bool]$IsForeground)
    if ($null -eq $Proc) { return $false }
    if ($Cond.process_name -and $Proc.Name -notmatch $Cond.process_name) { return $false }
    if ($Cond.is_foreground -and -not $IsForeground) { return $false }
    if ($Cond.not_foreground -and $IsForeground) { return $false }
    if ($Cond.not_in_whitelist -and $Proc.Name -in $script:RulesSkip) { return $false }
    if ($Cond.not_authorized) {
        try {
            $authPath = Join-Path $PSScriptRoot "authorized_apps.json"
            if (Test-Path -LiteralPath $authPath) {
                $auth = Get-Content -Raw -LiteralPath $authPath -Encoding utf8 | ConvertFrom-Json
                if ($auth.apps.name -contains $Proc.Name) { return $false }
            }
        } catch {}
    }
    if ($null -ne $Cond.cpu_gt_pct -and $CpuPct -lt [double]$Cond.cpu_gt_pct) { return $false }
    if ($null -ne $Cond.cpu_lt_pct -and $CpuPct -gt [double]$Cond.cpu_lt_pct) { return $false }
    if ($null -ne $Cond.mem_gt_mb -and $Proc.WorkingSet64/1MB -lt [double]$Cond.mem_gt_mb) { return $false }
    return $true
}

# ---------- 动作执行（纯执行，不管理 RuleActive 状态；原值由调用方记录） ----------
function Invoke-RuleAction {
    param($Then, [object]$Proc)
    $procId = $Proc.Id
    switch ($Then.action) {
        'focus' {
            $mode = if ($Then.mode) { $Then.mode } else { 'aggressive' }
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if (-not $p) { return $false }
            if ($mode -eq 'godmode') { $p.PriorityClass = 'High' } else { $p.PriorityClass = 'AboveNormal' }
            Write-RuleLog "INFO" "规则动作: focus $($Proc.Name)($procId) mode=$mode"
            return $true
        }
        'demote' {
            $level = if ($Then.level) { $Then.level } else { 'below_normal' }
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if (-not $p) { return $false }
            $fg = Get-ForegroundPid
            if ($fg -and $procId -eq $fg) { return $false }   # 前台进程保护双保险
            if ($level -eq 'idle') { $p.PriorityClass = 'Idle' } else { $p.PriorityClass = 'BelowNormal' }
            Write-RuleLog "INFO" "规则动作: demote $($Proc.Name)($procId) level=$level"
            return $true
        }
        'ecoqos' {
            return Set-EcoQos -ProcId $procId -On $true
        }
        'affinity' {
            if (-not $Then.cores) { return $false }
            return Set-ProcessAffinity -ProcId $procId -Cores $Then.cores
        }
        'trim' {
            try {
                $h = (Get-Process -Id $procId -ErrorAction Stop).Handle
                [PowerFocus.Native]::EmptyWorkingSet($h) | Out-Null
                Write-RuleLog "INFO" "规则动作: trim $($Proc.Name)($procId)"
                return $true
            } catch { return $false }
        }
        'power' {
            $plan = if ($Then.plan) { $Then.plan } else { 'high' }
            if ($plan -eq 'high') {
                & powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c 2>$null | Out-Null
            } else {
                & powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e 2>$null | Out-Null
            }
            Write-RuleLog "INFO" "规则动作: power plan=$plan"
            return $true
        }
        default { Write-RuleLog "WARN" "未知规则动作: $($Then.action)"; return $false }
    }
}

# ---------- EcoQoS 效率模式（官方功率节流 API） ----------
function Set-EcoQos {
    param([int]$ProcId, [bool]$On)
    try {
        $p = Get-Process -Id $ProcId -ErrorAction Stop
        $state = New-Object PowerFocus.RulesNative+PROCESS_POWER_THROTTLING_STATE
        $state.Version = 1
        $state.ControlMask = 1          # PROCESS_POWER_THROTTLING_EXECUTION_SPEED
        $state.StateMask = if ($On) { 1 } else { 0 }
        $ok = [PowerFocus.RulesNative]::SetProcessInformation($p.Handle, 4, [ref]$state, [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($state))
        Write-RuleLog "INFO" "规则动作: ecoqos $($p.Name)($ProcId) on=$On ok=$ok"
        return $ok
    } catch {
        Write-RuleLog "WARN" "EcoQoS 失败($ProcId): $_"
        return $false
    }
}

# ---------- CPU 亲和性绑核（SetProcessAffinityMask） ----------
function Set-ProcessAffinity {
    param([int]$ProcId, [string]$Cores)
    try {
        $p = Get-Process -Id $ProcId -ErrorAction Stop
        $mask = 0
        foreach ($part in ($Cores -split ',')) {
            $part = $part.Trim()
            if ($part -match '^(\d+)-(\d+)$') {
                for ($c = [int]$matches[1]; $c -le [int]$matches[2]; $c++) { $mask = $mask -bor ([bigint]1 -shl $c) }
            } elseif ($part -match '^\d+$') {
                $mask = $mask -bor ([bigint]1 -shl [int]$part)
            }
        }
        if ($mask -eq 0) { return $false }
        $sysMask = [System.UIntPtr]::Zero
        $ok = [PowerFocus.RulesNative]::SetProcessAffinityMask($p.Handle, [System.UIntPtr]::new([uint64]$mask), [ref]$sysMask)
        Write-RuleLog "INFO" "规则动作: affinity $($p.Name)($ProcId) cores=$Cores mask=$mask ok=$ok"
        return $ok
    } catch {
        Write-RuleLog "WARN" "affinity 失败($ProcId): $_"
        return $false
    }
}

# ---------- 还原（until 条件满足或规则失配） ----------
function Restore-RuleAction {
    param([string]$Key, [object]$Proc)
    $rec = $script:RuleActive[$Key]
    if ($null -eq $rec) { return }
    try {
        $p = Get-Process -Id $rec.ProcId -ErrorAction Stop
        if ($rec.Prev) {
            $cls = [System.Diagnostics.ProcessPriorityClass]::$($rec.Prev)
            $p.PriorityClass = $cls
            Write-RuleLog "INFO" "规则还原: $($p.Name)($($rec.ProcId)) -> $($rec.Prev)"
        }
    } catch {
        if ($rec.Prev) { Write-RuleLog "WARN" "还原失败(进程可能已退出): $Key" }
    }
    $script:RuleActive.Remove($Key) | Out-Null
}

# ---------- 单次评估（每 2 秒由 Timer 调用） ----------
function Invoke-RulesEngineOnce {
    $rules = Read-RuleFile
    if (-not $rules) { return }
    $interval = 2.0
    $fgPid = Get-ForegroundPid
    $now = Get-Date
    $procs = Get-Process -ErrorAction SilentlyContinue

    foreach ($rule in $rules) {
        if (-not $rule.enabled) { continue }
        $rname = $rule.name
        # 1) 找匹配进程
        $targets = @()
        foreach ($p in $procs) {
            if ($rule.when.process_name -and $p.Name -notmatch $rule.when.process_name) { continue }
            $targets += $p
        }
        if ($targets.Count -eq 0) {
            # 规则目标不存在：条件不再成立，重置计数并还原已触发状态
            if ($script:RuleConditionAt.ContainsKey($rname)) { $script:RuleConditionAt.Remove($rname) | Out-Null }
            foreach ($key in @($script:RuleActive.Keys)) {
                if ($key -like "$rname-*") { Restore-RuleAction -Key $key -Proc $null }
            }
            continue
        }
        $target = $targets[0]
        $cpu = Get-CpuPct -ProcId $target.Id -IntervalSec $interval
        if ($null -eq $cpu) { $cpu = 0.0 }
        $isFg = ($fgPid -and $target.Id -eq $fgPid)
        $condOk = Test-RuleCondition -Cond $rule.when -Proc $target -CpuPct $cpu -IntervalSec $interval -IsForeground $isFg

        if ($condOk) {
            # 条件成立：记录/累计持续时间
            if (-not $script:RuleConditionAt.ContainsKey($rname)) {
                $script:RuleConditionAt[$rname] = @{ ProcId = $target.Id; Since = $now }
            } else {
                $rec = $script:RuleConditionAt[$rname]
                if ($rec.ProcId -ne $target.Id) { $script:RuleConditionAt[$rname] = @{ ProcId = $target.Id; Since = $now } }
            }
            $needSec = if ($rule.when.for_seconds) { [double]$rule.when.for_seconds } else { 0 }
            $since = $script:RuleConditionAt[$rname].Since
            $activeKey = "$rname-$($target.Id)"
            if ((($now - $since).TotalSeconds -ge $needSec) -and -not $script:RuleActive.ContainsKey($activeKey)) {
                # 触发前记录原值（规则状态由本函数统一管理，避免重复 key）
                $prevCls = $null
                $tp = Get-Process -Id $target.Id -ErrorAction SilentlyContinue
                if ($tp) { $prevCls = [string]$tp.PriorityClass }
                $ok = Invoke-RuleAction -Then $rule.then -Proc $target
                if ($ok) {
                    $script:RuleActive[$activeKey] = @{ ProcId = $target.Id; Since = $now; Rule = $rname; Prev = $prevCls }
                    Write-RuleLog "INFO" "规则触发: $rname -> $($target.Name)($($target.Id))"
                }
            }
        } else {
            # 条件不成立：重置计时
            if ($script:RuleConditionAt.ContainsKey($rname)) { $script:RuleConditionAt.Remove($rname) | Out-Null }
        }

        # 2) until 检查：已触发且条件满足 → 还原
        foreach ($key in @($script:RuleActive.Keys)) {
            if ($key -notlike "$rname-*") { continue }
            $rec = $script:RuleActive[$key]
            $tp = Get-Process -Id $rec.ProcId -ErrorAction SilentlyContinue
            if (-not $tp) { $script:RuleActive.Remove($key) | Out-Null; continue }
            $tcpu = Get-CpuPct -ProcId $rec.ProcId -IntervalSec $interval
            if ($null -eq $tcpu) { $tcpu = 0.0 }
            $tcond = Test-RuleCondition -Cond $rule.until -Proc $tp -CpuPct $tcpu -IntervalSec $interval -IsForeground $isFg
            if ($tcond) {
                Restore-RuleAction -Key $key -Proc $tp
            }
        }
    }
    # 状态落盘（心跳上报）
    $activeList = @()
    foreach ($key in $script:RuleActive.Keys) {
        $rec = $script:RuleActive[$key]
        $activeList += [pscustomobject]@{ rule = $rec.Rule; pid = $rec.ProcId }
    }
    $state = [pscustomobject]@{
        time = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        running = $script:RulesRunning
        foreground_pid = $fgPid
        rules_active = $activeList
    }
    try {
        $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:RulesStateFile -Encoding utf8
    } catch {}
}

# ---------- 启动 / 停止 ----------
# 设计：不建独立 Timer（System.Timers.Timer 事件线程会并发重入，
#       破坏 PowerShell runspace 输出管线——实测已踩坑）。
# 评估由 v2 命令总线 tick（单线程 2s 循环）顺带调用 Invoke-RulesEngineOnce。
function Start-RulesEngine {
    if ($script:RulesRunning) { Write-RuleLog "WARN" "规则引擎已在运行"; return }
    $script:RulesRunning = $true
    try { Invoke-RulesEngineOnce } catch { Write-RuleLog "WARN" "首次评估异常: $_" }
    Write-RuleLog "INFO" "规则引擎已启动（挂接命令总线 tick，2s 评估）: $script:RuleFile"
}

function Stop-RulesEngine {
    if (-not $script:RulesRunning) { return }
    $script:RulesRunning = $false
    # 还原全部已触发状态
    foreach ($key in @($script:RuleActive.Keys)) {
        Restore-RuleAction -Key $key -Proc $null
    }
    $script:RuleConditionAt.Clear()
    Write-RuleLog "INFO" "规则引擎已停止，全部规则状态已还原"
}
