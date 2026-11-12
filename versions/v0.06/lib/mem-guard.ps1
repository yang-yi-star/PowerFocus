#requires -Version 7.0
<#
  PowerFocus 智能内存管理模块 (MemGuard)
  ---------------------------------------------------------------
  核心行为：
  1. 只有检测到本地 AI 模型进程运行，才启用内存压制；否则完全不压制。
  2. 压制对象仅限"后台空闲/半闲置"进程，模型与前台应用绝不触及。
  3. 通过工作集回收 + 优先级再分配，把可用内存让给当前活跃任务。
  4. 无论内存占用多高（含 97% 极端场景），前台与模型进程优先级只升不降。
  5. 未检测到模型时只做"新启动应用保活"，不做任何压制。
  6. 1 秒轻量采样（GlobalMemoryStatusEx，无进程遍历开销），压制动作可配置节流。
  7. 支持 -Once 单次执行（便于验证用例）与常驻守护两种模式。
#>
[CmdletBinding()]
param(
    [int]$IntervalMs      = 1000,
    [int]$TrimIntervalMs  = 5000,
    [int]$WarnPercent     = 75,
    [int]$CriticalPercent = 90,
    [int]$MaxTrimPerCycle = 8,
    [int]$CooldownSec     = 30,
    [int]$MinWorkingSetMB = 60,
    [switch]$SimulatePressure,
    [switch]$SimulateModel,
    [switch]$Once,
    [switch]$Json,
    [int]$Loops = 0,
    [int]$CacheMs = 0
)

$ErrorActionPreference = 'Continue'
# 版本自包含：日志/状态全部落在本版本目录内（versions\v0.05\），不跨版本污染
$script:Root      = Split-Path $PSScriptRoot -Parent
$script:LogDir    = Join-Path $script:Root 'logs'
$script:LogFile   = Join-Path $script:LogDir 'mem-guard.log'
$script:StateFile = Join-Path $script:Root 'mem-guard.state.json'
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null

Add-Type @"
using System;using System.Runtime.InteropServices;
public class MemGuardNative {
    [StructLayout(LayoutKind.Sequential)]
    public class MEMORYSTATUSEX {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
        public MEMORYSTATUSEX() { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)); }
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("psapi.dll", SetLastError=true)]
    public static extern bool EmptyWorkingSet(IntPtr h);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
"@ -ErrorAction SilentlyContinue

# ---------------- 基础能力 ----------------
function Write-MgLog([string]$Level, [string]$Msg) {
    try {
        $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Msg
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8
        if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 2MB)) {
            $keep = Get-Content $script:LogFile -Tail 1500
            $keep | Set-Content -LiteralPath $script:LogFile -Encoding utf8
        }
    } catch {}
}

function Get-MemoryStatus {
    # 零分配采样：GlobalMemoryStatusEx，耗时 < 0.1ms
    $m = [MemGuardNative+MEMORYSTATUSEX]::new()
    [void][MemGuardNative]::GlobalMemoryStatusEx($m)
    $totalMB = [math]::Round($m.ullTotalPhys / 1MB, 0)
    $availMB = [math]::Round($m.ullAvailPhys / 1MB, 0)
    [pscustomobject]@{
        TotalMB    = $totalMB
        AvailMB    = $availMB
        UsedMB     = $totalMB - $availMB
        Percent    = if ($totalMB -gt 0) { [math]::Round(($totalMB - $availMB) / $totalMB * 100, 1) } else { 0 }
    }
}

function Get-AiModelProcesses {
    # 本地推理进程识别：llama.cpp / Ollama / LM Studio / vLLM / Transformers
    $cim = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue `
        -Filter "Name='llama-server.exe' OR Name='llama-cli.exe' OR Name='ollama.exe' OR Name='ollama_llama_server.exe' OR Name='python.exe' OR Name='pythonw.exe' OR Name='LM Studio.exe' OR Name='lms.exe'"
    $found = @()
    foreach ($c in $cim) {
        $cl = [string]$c.CommandLine
        $isModel = $false
        if ($c.Name -like 'llama-*') { $isModel = $true }
        elseif ($c.Name -in @('ollama.exe','ollama_llama_server.exe','LM Studio.exe','lms.exe')) { $isModel = $true }
        elseif ($cl -match '-m\s+\S+\.gguf|--model\s+\S+\.gguf|--models-preset|--model-path|vllm|text-generation|llama_cpp|transformers') { $isModel = $true }
        if ($isModel) {
            $found += [pscustomobject]@{ PID = [int]$c.ProcessId; Name = [string]$c.Name; CommandLine = $cl }
        }
    }
    return $found
}

function Get-ForegroundPid {
    $h = [MemGuardNative]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return 0 }
    $p = 0
    [void][MemGuardNative]::GetWindowThreadProcessId($h, [ref]$p)
    return [int]$p
}

function Get-ParentMap {
    $map = @{}
    foreach ($c in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId)) {
        $map[[int]$c.ProcessId] = [int]$c.ParentProcessId
    }
    return $map
}

function Get-AncestorSet([int]$StartPid, $ParentMap) {
    $set = [System.Collections.Generic.HashSet[int]]::new()
    $cur = $StartPid
    $guard = 0
    while ($cur -gt 0 -and $guard -lt 12 -and $ParentMap.ContainsKey($cur)) {
        [void]$set.Add($cur)
        $cur = $ParentMap[$cur]
        $guard++
    }
    return $set
}

$script:SystemCritical = @('System','Registry','Idle','Memory Compression','smss','csrss','wininit','services','lsass','winlogon','fontdrvhost','dwm','MsMpEng','LogonUI','SecurityHealthService','WUDFHost','audiodg')
$script:Cooldown = @{}   # pid -> 上次压制时间

function Test-IsModelProcess([string]$Name, [string]$CommandLine) {
    if ($Name -like 'llama-*') { return $true }
    if ($Name -in @('ollama.exe','ollama_llama_server.exe','LM Studio.exe','lms.exe')) { return $true }
    if ($CommandLine -match '-m\s+\S+\.gguf|--models-preset|--model-path|vllm|llama_cpp|text-generation') { return $true }
    return $false
}

function Invoke-GuardCycle {
    param([switch]$Simulate)

    $mem    = Get-MemoryStatus
    # 重活（进程表/父子关系/模型识别）按 CacheMs 缓存，常驻模式下避免每秒全表扫描
    $nowTs0 = Get-Date
    $cacheHit = $CacheMs -gt 0 -and $script:Cache -and (($nowTs0 - $script:Cache.Ts).TotalMilliseconds -lt $CacheMs)
    if ($cacheHit) {
        $procs     = $script:Cache.Procs
        $parentMap = $script:Cache.ParentMap
        $models    = @($script:Cache.Models)
    } else {
        $procs     = Get-Process -ErrorAction SilentlyContinue
        $models    = @(Get-AiModelProcesses)
        $parentMap = Get-ParentMap
        $script:Cache = [pscustomobject]@{ Ts = $nowTs0; Procs = $procs; Models = $models; ParentMap = $parentMap }
    }
    if ($SimulateModel -and $models.Count -eq 0) {
        $models = @([pscustomobject]@{ PID = 999999; Name = 'simulated-llama-server'; CommandLine = '--models-preset sim' })
    }
    $modelRunning = $models.Count -gt 0
    if ($Simulate) { $mem.Percent = 97.0; $mem.AvailMB = [math]::Round($mem.TotalMB * 0.03, 0) }

    $fgPid     = Get-ForegroundPid

    # 保护集合：前台 + 模型 + 其祖先链 + 系统关键 + 自身
    $protect = [System.Collections.Generic.HashSet[int]]::new()
    if ($fgPid -gt 0) { [void]$protect.Add($fgPid); foreach ($a in (Get-AncestorSet $fgPid $parentMap)) { [void]$protect.Add($a) } }
    foreach ($m in $models) {
        [void]$protect.Add([int]$m.PID)
        foreach ($a in (Get-AncestorSet ([int]$m.PID) $parentMap)) { [void]$protect.Add($a) }
        # 模型的子进程（CUDA 上下文/子服务）同样受保护
        foreach ($k in @($parentMap.Keys)) { if ($parentMap[$k] -eq [int]$m.PID) { [void]$protect.Add([int]$k) } }
    }
    [void]$protect.Add($PID)

    $modelPids = @($models | ForEach-Object { [int]$_.PID })

    # 优先级保障：模型 & 前台只升不降（任何内存压力下都执行，这是要求 4）
    $raised = 0
    foreach ($id in ($modelPids + $fgPid | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
        $p = $procs | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $p) { continue }
        try {
            $cur = [string]$p.PriorityClass
            if ($cur -notin @('AboveNormal','High','RealTime')) { $p.PriorityClass = 'AboveNormal'; $raised++ }
        } catch {}
    }

    $trimmed = 0; $freedMB = 0; $skippedCooldown = 0
    $actions = @()

    if ($modelRunning) {
        $level = if ($mem.Percent -ge $CriticalPercent) { 'critical' } elseif ($mem.Percent -ge $WarnPercent) { 'warn' } else { 'normal' }
        if ($level -ne 'normal') {
            $limit = if ($level -eq 'critical') { [math]::Max($MaxTrimPerCycle, 12) } else { $MaxTrimPerCycle }
            $cores = [Environment]::ProcessorCount
            $nowTs = Get-Date
            # 有 TCP 连接/监听的进程 = 正在提供服务或通信，不压
            $netPids = [System.Collections.Generic.HashSet[int]]::new()
            try {
                foreach ($c in (Get-NetTCPConnection -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess)) {
                    if ($c) { [void]$netPids.Add([int]$c) }
                }
            } catch {}
            # 应用组保护：只要该应用有任一可见窗口，整组进程（Electron 子进程等）都不压
            $windowedNames = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($p in $procs) {
                if ($p.MainWindowHandle -ne 0) { [void]$windowedNames.Add($p.ProcessName.ToLower()) }
            }
            $fgProc = $procs | Where-Object { $_.Id -eq $fgPid } | Select-Object -First 1
            $fgName = if ($fgProc) { $fgProc.ProcessName.ToLower() } else { '' }
            $candidates = @()
            # 自我保护：PowerFocus 自身的调度中心/控制台/守护进程一律不压
            $selfPids = [System.Collections.Generic.HashSet[int]]::new()
            try {
                foreach ($c in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue -Filter "Name='pwsh.exe' OR Name='python.exe'")) {
                    if ([string]$c.CommandLine -match 'PowerFocus|电脑算力调度中心|mem-guard') { [void]$selfPids.Add([int]$c.ProcessId) }
                }
            } catch {}
            foreach ($p in $procs) {
                if ($protect.Contains([int]$p.Id)) { continue }
                if ($selfPids.Contains([int]$p.Id)) { continue }
                if ($p.ProcessName -in $script:SystemCritical) { continue }
                if ($p.WorkingSet64 -lt ($MinWorkingSetMB * 1MB)) { continue }
                # 属于有界面的应用组 = 用户开着：前台应用绝对保护；非前台仅在极端压力下允许让出
                $pname = $p.ProcessName.ToLower()
                if ($windowedNames.Contains($pname)) {
                    if ($pname -eq $fgName) { continue }           # 用户正在交互的应用：绝不触碰
                    if ($level -ne 'critical') { continue }        # 一般压力：有界面应用不碰
                }
                # 正在通信/监听端口 = 在用（如 SD WebUI、下载器、数据库），不动
                if ($netPids.Contains([int]$p.Id)) { continue }
                # CPU 活跃度：按进程存活期平均占用率判断，>3% 视为在干活
                $avgCpu = 0.0
                try {
                    $age = [math]::Max(($nowTs - $p.StartTime).TotalSeconds, 1)
                    $avgCpu = ($p.TotalProcessorTime.TotalSeconds / $age / [math]::Max($cores, 1)) * 100
                } catch {}
                if ($avgCpu -gt 3.0) { continue }
                $memMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
                # 冷却：同一进程 30s 内不重复压制
                $last = if ($script:Cooldown.ContainsKey($p.Id)) { $script:Cooldown[$p.Id] } else { [datetime]::MinValue }
                if (($nowTs - $last).TotalSeconds -lt $CooldownSec) { $skippedCooldown++; continue }
                $candidates += [pscustomobject]@{ Proc = $p; WsMB = $memMB; Cpu = $avgCpu }
            }
            $candidates = $candidates | Sort-Object WsMB -Descending | Select-Object -First $limit
            foreach ($c in $candidates) {
                $p = $c.Proc
                $before = $p.WorkingSet64
                $h = [MemGuardNative]::OpenProcess(0x0100 -bor 0x0400, $false, $p.Id)
                if ($h -eq [IntPtr]::Zero) { continue }
                $ok = [MemGuardNative]::EmptyWorkingSet($h)
                [void][MemGuardNative]::CloseHandle($h)
                $p.Refresh()
                $after = $p.WorkingSet64
                if ($ok) {
                    $trimmed++
                    $freedMB += [math]::Round(($before - $after) / 1MB, 1)
                    $script:Cooldown[$p.Id] = Get-Date
                    if ($level -eq 'critical') {
                        try { if ([string]$p.PriorityClass -notin @('Idle','BelowNormal')) { $p.PriorityClass = 'Idle' } } catch {}
                    }
                    $actions += [pscustomobject]@{ pid = $p.Id; name = $p.ProcessName; wsBeforeMB = [math]::Round($before/1MB,1); wsAfterMB = [math]::Round($after/1MB,1); freedMB = [math]::Round(($before-$after)/1MB,1) }
                }
            }
        } else {
            $level = 'normal'
        }
    } else {
        # 未检测到模型：绝不压制。只保障"刚启动的应用程序"稳定运行（要求 5）
        $level = 'idle'
        $now = Get-Date
        foreach ($p in $procs) {
            if ($protect.Contains([int]$p.Id)) { continue }
            if ($p.ProcessName -in $script:SystemCritical) { continue }
            try {
                if (($now - $p.StartTime).TotalSeconds -lt 60) {
                    if ([string]$p.PriorityClass -in @('Idle','BelowNormal')) { $p.PriorityClass = 'Normal' }
                }
            } catch {}
        }
    }

    # 清理已退出进程的冷却记录
    $live = @($procs | ForEach-Object { $_.Id })
    foreach ($k in @($script:Cooldown.Keys)) { if ($k -notin $live) { $script:Cooldown.Remove($k) } }

    return [pscustomobject]@{
        ts            = (Get-Date -Format 'HH:mm:ss')
        memPercent    = $mem.Percent
        availMB       = $mem.AvailMB
        totalMB       = $mem.TotalMB
        modelRunning  = $modelRunning
        modelCount    = $models.Count
        modelPids     = $modelPids
        level         = $level
        fgPid         = $fgPid
        protectedCount = $protect.Count
        priorityRaised = $raised
        trimmed       = $trimmed
        freedMB       = $freedMB
        cooldownSkip  = $skippedCooldown
        actions       = $actions
    }
}

function Set-MgState($s) {
    try { $s | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:StateFile -Encoding utf8 } catch {}
}

# ---------------- 入口 ----------------
if ($Once) {
    $r = Invoke-GuardCycle -Simulate:$SimulatePressure
    Set-MgState $r
    Write-MgLog 'INFO' ("单次: model={0} mem={1}% level={2} trimmed={3} freed={4}MB" -f $r.modelRunning, $r.memPercent, $r.level, $r.trimmed, $r.freedMB)
    if ($Json) { $r | ConvertTo-Json -Depth 6 } else { $r | Format-List }
    return
}

Write-MgLog 'INFO' ("MemGuard 启动 interval={0}ms warn={1}% critical={2}% trimEvery={3}ms" -f $IntervalMs, $WarnPercent, $CriticalPercent, $TrimIntervalMs)
$lastTrim = [datetime]::MinValue
$n = 0
while ($true) {
    $r = Invoke-GuardCycle -Simulate:$SimulatePressure
    if ((Get-Date) -ge $lastTrim.AddMilliseconds($TrimIntervalMs)) { $lastTrim = Get-Date; Set-MgState $r }
    if ($r.trimmed -gt 0 -or $r.priorityRaised -gt 0) {
        Write-MgLog 'INFO' ("model={0} mem={1}% level={2} trimmed={3} freed={4}MB raised={5}" -f $r.modelRunning, $r.memPercent, $r.level, $r.trimmed, $r.freedMB, $r.priorityRaised)
    }
    $n++
    if ($Loops -gt 0 -and $n -ge $Loops) { break }
    Start-Sleep -Milliseconds $IntervalMs
}
