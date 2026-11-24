#requires -Version 7.0
<#
  MemGuard 离线行为回归（14-4 / 09-10）
  ---------------------------------------------------------------
  不启 llama-server、不造 1.6GB 压力进程、不碰任何真实进程优先级或工作集。
  AST 从真 versions\v0.13\lib\mem-guard.ps1 取 Invoke-GuardCycle / Write-MgCycleLog /
  Get-AncestorSet 三段定义 dot-source；其余依赖全部同名桩：
    采样  Get-MemoryStatus         -> 脚本化 mem 对象（物理% / 提交%）
    进程  Get-Process              -> 内存假进程（Refresh 可脚本化收缩）
          Get-AiModelProcesses     -> 脚本化模型列表
          Get-ParentMap            -> 脚本化父子表
          Get-ForegroundPid        -> 脚本化前台 PID
          Get-NetTCPConnection     -> 脚本化监听/连接表
          Get-CimInstance          -> 空（自我保护集合不引入真实扫描）
    原生  MemGuardNative           -> 记录 OpenProcess/EmptyWorkingSet 次数与 pid，可控失败
    日志  Write-MgLog              -> 收集到内存，不落盘
  覆盖：A idle 不压制+新应用保活 / B 模型+warn 选优压制与保护集 / C critical 窗口应用可压
       且降 Idle / D 提交额度独立告警与 60s 节流 / E 原生失败不计数不冷却 / F 冷却窗
       / G freedMB 字节整数累加（10 号）/ H 提权汇总窗口（09 号）/ I 结构锁
#>
[CmdletBinding()]
param([string]$GuardPath)

$ErrorActionPreference = 'Continue'

$Root = Split-Path -Parent $PSScriptRoot
if (-not $GuardPath) {
    $ver = 'v0.13'
    $curFile = Join-Path $Root 'versions\current.json'
    if (Test-Path -LiteralPath $curFile) {
        $v = (Get-Content -LiteralPath $curFile -Raw -Encoding utf8 | ConvertFrom-Json).version
        if ($v) { $ver = $v }
    }
    $GuardPath = Join-Path $Root "versions\$ver\lib\mem-guard.ps1"
}
if (-not (Test-Path -LiteralPath $GuardPath)) {
    "  [FAIL] mem-guard 不存在：$GuardPath"
    "RESULT: PASS=0 FAIL=1"
    exit 1
}

$script:pass = 0
$script:fail = 0
function Check([string]$Name, [bool]$Cond, [string]$Detail = '') {
    if ($Cond) { $script:pass++; "  [PASS] $Name  $Detail" }
    else { $script:fail++; "  [FAIL] $Name  $Detail" }
}

# ---------------- 解析 + 提取三段真函数 ----------------
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($GuardPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    "  [FAIL] 真文件语法错误 $($parseErrors.Count) 处（先修 mem-guard 再谈回归）"
    "RESULT: PASS=0 FAIL=1"
    exit 1
}
$script:WholeText = [IO.File]::ReadAllText($GuardPath)
$script:FnText = @{}
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($fn.Name -in @('Invoke-GuardCycle', 'Write-MgCycleLog', 'Get-AncestorSet')) {
        $script:FnText[$fn.Name] = $fn.Extent.Text
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}

# ---------------- 原生层同名桩（不执行任何真实工作集操作） ----------------
if (-not ('MemGuardNative' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class MemGuardNative {
    public static List<int> Opens = new List<int>();
    public static List<int> Trims = new List<int>();
    public static List<int> FailTrimPids = new List<int>();
    public static List<int> FailOpenPids = new List<int>();
    public static uint LastMask = 0;
    public static IntPtr OpenProcess(uint access, bool inherit, int pid) {
        LastMask = access;
        Opens.Add(pid);
        if (FailOpenPids.Contains(pid)) return IntPtr.Zero;
        return new IntPtr(1000 + pid);
    }
    public static bool CloseHandle(IntPtr h) { return true; }
    public static bool EmptyWorkingSet(IntPtr h) {
        int pid = (int)(h.ToInt64() - 1000);
        Trims.Add(pid);
        return !FailTrimPids.Contains(pid);
    }
}
"@
}

# ---------------- 数据桩 ----------------
$script:FakeMem = $null
$script:FakeModels = @()
$script:FakeParentMap = @{}
$script:FakeFgPid = 0
$script:FakeProcs = @()
$script:FakeNet = @()
$script:FakeCim = @()
$script:Logs = [System.Collections.Generic.List[object]]::new()

function Write-MgLog([string]$Level, [string]$Msg) {
    $script:Logs.Add([pscustomobject]@{ Level = $Level; Msg = $Msg })
}
function Get-MemoryStatus { return $script:FakeMem.PSObject.Copy() }
function Get-AiModelProcesses { return @($script:FakeModels) }
function Get-ParentMap { return $script:FakeParentMap }
function Get-ForegroundPid { return [int]$script:FakeFgPid }
function Get-Process {
    [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    return @($script:FakeProcs)
}
function Get-NetTCPConnection {
    [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    return @($script:FakeNet)
}
function Get-CimInstance {
    [CmdletBinding()] param([Parameter(Position = 0)][string]$ClassName, [string]$Filter, [Parameter(ValueFromRemainingArguments = $true)]$Rest)
    return @($script:FakeCim)
}

# ---------------- 真脚本的 param 同名变量（函数动态作用域会读这些） ----------------
$IntervalMs = 1000; $TrimIntervalMs = 5000
$WarnPercent = 75; $CriticalPercent = 90
$CommitWarnPercent = 88; $CommitCriticalPercent = 93
$MaxTrimPerCycle = 8; $CooldownSec = 30; $MinWorkingSetMB = 60
$SimulatePressure = $false; $SimulateModel = $false
$RaiseLogThrottleSec = 300
$CacheMs = 0
$script:SystemCritical = @('System', 'Registry', 'Idle', 'Memory Compression', 'smss', 'csrss', 'wininit', 'services', 'lsass', 'winlogon', 'fontdrvhost', 'dwm', 'MsMpEng', 'LogonUI', 'SecurityHealthService', 'WUDFHost', 'audiodg')
$script:Cooldown = @{}
$script:LastCommitLog = [datetime]::MinValue
$script:RaisePending = 0
$script:RaiseLogSlot = [datetime]::MinValue
$script:Cache = $null

# ---------------- 构造器 ----------------
function New-FakeMem {
    param([double]$Percent, [double]$CommitPercent, [double]$TotalMB = 32768, [double]$CommitTotalMB = 40960)
    $avail = [math]::Round($TotalMB * (100 - $Percent) / 100, 0)
    $commitUsed = [math]::Round($CommitTotalMB * $CommitPercent / 100, 0)
    return [pscustomobject]@{
        TotalMB       = $TotalMB
        AvailMB       = $avail
        UsedMB        = $TotalMB - $avail
        Percent       = $Percent
        CommitTotalMB = $CommitTotalMB
        CommitAvailMB = $CommitTotalMB - $commitUsed
        CommitUsedMB  = $commitUsed
        CommitPercent = $CommitPercent
    }
}

function New-FakeProc {
    param(
        [int]$Id,
        [string]$Name,
        [double]$WsMB,
        [double]$AfterMB = -1,
        [int]$Window = 0,
        [double]$AgeSec = 3600,
        [double]$CpuSec = 0,
        [string]$Priority = 'Normal'
    )
    $ws = [long][math]::Round($WsMB * 1MB)
    $after = if ($AfterMB -ge 0) { [long][math]::Round($AfterMB * 1MB) } else { $ws }
    $p = [pscustomobject]@{
        Id                 = $Id
        ProcessName        = $Name
        WorkingSet64       = $ws
        PrivateMemorySize64 = $ws
        MainWindowHandle   = $Window
        StartTime          = (Get-Date).AddSeconds(-$AgeSec)
        TotalProcessorTime = [timespan]::FromSeconds($CpuSec)
        PriorityClass      = $Priority
        AfterWs            = $after
    }
    $p | Add-Member -MemberType ScriptMethod -Name Refresh -Value { $this.WorkingSet64 = $this.AfterWs }
    return $p
}

function Reset-Native {
    [MemGuardNative]::Opens.Clear()
    [MemGuardNative]::Trims.Clear()
    [MemGuardNative]::FailTrimPids.Clear()
    [MemGuardNative]::FailOpenPids.Clear()
}
function Reset-GuardState {
    $script:Cooldown = @{}
    $script:Cache = $null
    $script:LastCommitLog = [datetime]::MinValue
    $script:RaisePending = 0
    $script:RaiseLogSlot = [datetime]::MinValue
    $script:Logs.Clear()
    Reset-Native
}
function Get-Priority([int]$Id) {
    return [string](@($script:FakeProcs | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1).PriorityClass
}
function Test-InActions($Result, [int]$Id) {
    return @($Result.actions | Where-Object { $_.pid -eq $Id }).Count -gt 0
}
function Test-InList($List, [int]$Id) { return @($List | Where-Object { $_ -eq $Id }).Count -gt 0 }

"=== 0. 抽取结果 ==="
Check 'F0 Invoke-GuardCycle 存在' ($null -ne (Get-Command Invoke-GuardCycle -CommandType Function -ErrorAction SilentlyContinue))
Check 'F1 Get-AncestorSet 存在' ($null -ne (Get-Command Get-AncestorSet -CommandType Function -ErrorAction SilentlyContinue))

# ---------------- A. 无模型：idle 不压制 + 新启动应用保活 ----------------
"=== A. 无模型 idle ==="
Reset-GuardState
$script:FakeMem = New-FakeMem -Percent 40 -CommitPercent 40
$script:FakeModels = @()
$script:FakeParentMap = @{ 1004 = 4000 }
$script:FakeFgPid = 1004
$script:FakeNet = @()
$script:FakeCim = @()
$script:FakeProcs = @(
    (New-FakeProc -Id 1001 -Name 'newapp' -WsMB 500 -AgeSec 10 -Priority 'BelowNormal'),
    (New-FakeProc -Id 1002 -Name 'oldapp' -WsMB 500 -AgeSec 600 -Priority 'BelowNormal'),
    (New-FakeProc -Id 1003 -Name 'csrss' -WsMB 500 -AgeSec 10 -Priority 'BelowNormal'),
    (New-FakeProc -Id 1004 -Name 'fgapp' -WsMB 600 -Window 4660 -AgeSec 10 -Priority 'Idle')
)
$a = Invoke-GuardCycle
Check 'A1 无模型 modelRunning=false' ($a.modelRunning -eq $false) "modelRunning=$($a.modelRunning) count=$($a.modelCount)"
Check 'A2 模式 idle' ($a.level -eq 'idle') "level=$($a.level)"
Check 'A3 零压制' (($a.trimmed -eq 0) -and ($a.freedMB -eq 0)) "trimmed=$($a.trimmed) freed=$($a.freedMB)"
Check 'A4 零原生调用' ([MemGuardNative]::Opens.Count -eq 0) "opens=$([MemGuardNative]::Opens.Count)"
Check 'A5 新启动应用提回 Normal' ((Get-Priority 1001) -eq 'Normal') "priority=$(Get-Priority 1001)"
Check 'A6 老应用不动' ((Get-Priority 1002) -eq 'BelowNormal') "priority=$(Get-Priority 1002)"
Check 'A7 系统关键进程不动' ((Get-Priority 1003) -eq 'BelowNormal') "priority=$(Get-Priority 1003)"
Check 'A8 前台只升不降且未被压制' (((Get-Priority 1004) -eq 'AboveNormal') -and (-not (Test-InActions $a 1004))) "priority=$(Get-Priority 1004)"
Check 'A9 保护集非空' ($a.protectedCount -ge 1) "protected=$($a.protectedCount)"

# ---------------- B. 模型运行 + 物理 warn：选优压制、保护集生效 ----------------
"=== B. 模型 + warn ==="
Reset-GuardState
$cores = [Environment]::ProcessorCount
$script:MaxTrimPerCycle = 2
$script:FakeMem = New-FakeMem -Percent 80 -CommitPercent 50
$script:FakeModels = @([pscustomobject]@{ PID = 900; Name = 'llama-server.exe'; CommandLine = 'llama-server -m model.gguf' })
$script:FakeParentMap = @{ 900 = 5000; 1010 = 4000 }
$script:FakeFgPid = 1010
$script:FakeNet = @([pscustomobject]@{ OwningProcess = 1011 })
$script:FakeCim = @()
$script:FakeProcs = @(
    (New-FakeProc -Id 900 -Name 'llama-server.exe' -WsMB 800 -Priority 'Normal'),
    (New-FakeProc -Id 1005 -Name 'hogbig' -WsMB 1200 -AfterMB 700 -AgeSec 3600 -CpuSec 0.5),
    (New-FakeProc -Id 1006 -Name 'hogsmall' -WsMB 300 -AfterMB 250),
    (New-FakeProc -Id 1007 -Name 'hogmin' -WsMB 50),
    (New-FakeProc -Id 1008 -Name 'hogcpu' -WsMB 900 -AgeSec 100 -CpuSec (3.2 * $cores)),
    (New-FakeProc -Id 1009 -Name 'hogwindow' -WsMB 1000 -Window 17185),
    (New-FakeProc -Id 1010 -Name 'fgapp' -WsMB 900 -Window 21845 -Priority 'Normal'),
    (New-FakeProc -Id 1011 -Name 'hognet' -WsMB 700)
)
$b = Invoke-GuardCycle
Check 'B1 检测到模型' (($b.modelRunning -eq $true) -and ($b.modelCount -eq 1)) "modelRunning=$($b.modelRunning) count=$($b.modelCount)"
Check 'B2 判定 warn' ($b.level -eq 'warn') "level=$($b.level)"
Check 'B3 按上限压制 2 个' ($b.trimmed -eq 2) "trimmed=$($b.trimmed)"
Check 'B4 freedMB 精确 550' (($b.freedMB -eq 550) -and ("$($b.freedMB)" -match '^\d+\.?\d?$')) "freed=$($b.freedMB)"
Check 'B5 动作按工作集降序且差额正确' (
    ($b.actions.Count -eq 2) -and ($b.actions[0].pid -eq 1005) -and ($b.actions[0].freedMB -eq 500) -and
    ($b.actions[1].pid -eq 1006) -and ($b.actions[1].freedMB -eq 50)
) "actions=$(($b.actions | ForEach-Object { $_.pid.ToString() + ':' + $_.freedMB }) -join ',')"
Check 'B6 模型未被压制且提 AboveNormal' (
    (-not (Test-InActions $b 900)) -and ((Get-Priority 900) -eq 'AboveNormal')
) "modelPriority=$(Get-Priority 900) inActions=$(Test-InActions $b 900)"
Check 'B7 原生只对两个候选调用' (
    ([MemGuardNative]::Opens.Count -eq 2) -and (Test-InList ([MemGuardNative]::Opens) 1005) -and (Test-InList ([MemGuardNative]::Opens) 1006)
) "opens=$([MemGuardNative]::Opens -join ',')"
Check 'B8 句柄掩码含 QUERY_INFORMATION' (([MemGuardNative]::LastMask -band 0x0400) -ne 0) "mask=$([MemGuardNative]::LastMask)"
Check 'B9 冷却表登记两进程' (($script:Cooldown.ContainsKey(1005)) -and ($script:Cooldown.ContainsKey(1006))) "cooldown=$($script:Cooldown.Keys -join ',')"
Check 'B10 小/窗口/CPU/网络进程未被压' (
    (-not (Test-InActions $b 1007)) -and (-not (Test-InActions $b 1008)) -and
    (-not (Test-InActions $b 1009)) -and (-not (Test-InActions $b 1011)) -and (-not (Test-InActions $b 1010))
) "actions=$(($b.actions | ForEach-Object { $_.pid }) -join ',')"
Check 'B11 前台也提 AboveNormal' ((Get-Priority 1010) -eq 'AboveNormal') "fgPriority=$(Get-Priority 1010)"

# ---------------- F. 冷却窗（复用 B 现场） ----------------
"=== F. 冷却窗 ==="
Reset-Native
$script:Logs.Clear()
$f1 = Invoke-GuardCycle
Check 'F1 冷却期内零压制' ($f1.trimmed -eq 0) "trimmed=$($f1.trimmed)"
Check 'F2 两进程各记一次跳过' ($f1.cooldownSkip -eq 2) "skip=$($f1.cooldownSkip)"
Check 'F3 冷却期内零原生调用' ([MemGuardNative]::Opens.Count -eq 0) "opens=$([MemGuardNative]::Opens.Count)"
$script:Cooldown[1005] = (Get-Date).AddSeconds(-40)
Reset-Native
$f2 = Invoke-GuardCycle
Check 'F4 冷却到期后只补压 1005' (($f2.trimmed -eq 1) -and (Test-InActions $f2 1005)) "trimmed=$($f2.trimmed) actions=$(($f2.actions | ForEach-Object { $_.pid }) -join ',')"
Check 'F5 未到期的 1006 仍跳过' ($f2.cooldownSkip -eq 1) "skip=$($f2.cooldownSkip)"
$script:MaxTrimPerCycle = 8

# ---------------- C. critical：窗口应用可压 + 降 Idle + 上限抬到 12 ----------------
"=== C. critical ==="
Reset-GuardState
$script:MaxTrimPerCycle = 2
$script:FakeMem = New-FakeMem -Percent 97 -CommitPercent 50
$script:FakeModels = @([pscustomobject]@{ PID = 900; Name = 'llama-server.exe'; CommandLine = 'llama-server -m model.gguf' })
$script:FakeParentMap = @{ 900 = 5000 }
$script:FakeFgPid = 1015
$script:FakeNet = @()
$script:FakeProcs = @(
    (New-FakeProc -Id 900 -Name 'llama-server.exe' -WsMB 800),
    (New-FakeProc -Id 1012 -Name 'winapp' -WsMB 1000 -AfterMB 800 -Window 39321),
    (New-FakeProc -Id 1013 -Name 'hog1' -WsMB 700 -AfterMB 600),
    (New-FakeProc -Id 1014 -Name 'hog2' -WsMB 650 -AfterMB 600),
    (New-FakeProc -Id 1015 -Name 'fgapp' -WsMB 900 -Window 43690)
)
$c = Invoke-GuardCycle
Check 'C1 判定 critical' ($c.level -eq 'critical') "level=$($c.level)"
Check 'C2 上限抬到 12：3 个全压' ($c.trimmed -eq 3) "trimmed=$($c.trimmed) maxTrim=$MaxTrimPerCycle"
Check 'C3 freedMB 精确 350' ($c.freedMB -eq 350) "freed=$($c.freedMB)"
Check 'C4 受压力窗口应用被降 Idle' ((Get-Priority 1012) -eq 'Idle') "priority=$(Get-Priority 1012)"
Check 'C5 前台仍未触碰' (-not (Test-InActions $c 1015)) "fgInActions=$(Test-InActions $c 1015)"
Check 'C6 模型仍未压制' (-not (Test-InActions $c 900)) "modelInActions=$(Test-InActions $c 900)"

# ---------------- D. 提交额度独立告警 + 60s 节流 ----------------
"=== D. 提交额度告警 ==="
Reset-GuardState
$script:MaxTrimPerCycle = 8
$script:FakeMem = New-FakeMem -Percent 45 -CommitPercent 95
$script:FakeModels = @()
$script:FakeFgPid = 0
$script:FakeParentMap = @{}
$script:FakeProcs = @((New-FakeProc -Id 1020 -Name 'bigapp' -WsMB 2000))
$d1 = Invoke-GuardCycle
$warn1 = @($script:Logs | Where-Object { $_.Level -eq 'WARN' -and $_.Msg -like '*提交告警*' }).Count
Check 'D1 提交告警独立于模型' (($d1.level -eq 'idle') -and ($d1.commitLevel -eq 'critical')) "level=$($d1.level) commit=$($d1.commitLevel)"
Check 'D2 首次落一条 WARN' ($warn1 -eq 1) "warn=$warn1 msg=$($script:Logs[0].Msg)"
$null = Invoke-GuardCycle
Check 'D3 60s 内不重复刷' (@($script:Logs | Where-Object { $_.Msg -like '*提交告警*' }).Count -eq 1) "count=$(@($script:Logs | Where-Object { $_.Msg -like '*提交告警*' }).Count)"
$script:LastCommitLog = (Get-Date).AddSeconds(-61)
$null = Invoke-GuardCycle
Check 'D4 窗口后重新告警' (@($script:Logs | Where-Object { $_.Msg -like '*提交告警*' }).Count -eq 2) "count=$(@($script:Logs | Where-Object { $_.Msg -like '*提交告警*' }).Count)"

# ---------------- E. 原生失败不计数、不冷却 ----------------
"=== E. 原生失败 ==="
Reset-GuardState
$script:FakeMem = New-FakeMem -Percent 80 -CommitPercent 50
$script:FakeModels = @([pscustomobject]@{ PID = 900; Name = 'llama-server.exe'; CommandLine = 'llama-server -m model.gguf' })
$script:FakeParentMap = @{ 900 = 5000 }
$script:FakeFgPid = 0
$script:FakeNet = @()
$script:FakeProcs = @(
    (New-FakeProc -Id 900 -Name 'llama-server.exe' -WsMB 800),
    (New-FakeProc -Id 1030 -Name 'hogfail' -WsMB 1000 -AfterMB 900),
    (New-FakeProc -Id 1031 -Name 'hogopenfail' -WsMB 900 -AfterMB 800)
)
[MemGuardNative]::FailTrimPids.Add(1030)
[MemGuardNative]::FailOpenPids.Add(1031)
$e = Invoke-GuardCycle
Check 'E1 原生 false 不计 trimmed' ($e.trimmed -eq 0) "trimmed=$($e.trimmed)"
Check 'E2 不计 freed、不产动作' (($e.freedMB -eq 0) -and ($e.actions.Count -eq 0)) "freed=$($e.freedMB) actions=$($e.actions.Count)"
Check 'E3 失败进程不进冷却' (-not $script:Cooldown.ContainsKey(1030)) "cooldown=$($script:Cooldown.Keys -join ',')"
Check 'E4 句柄失败跳过原生' (
    (Test-InList ([MemGuardNative]::Trims) 1030) -and (-not (Test-InList ([MemGuardNative]::Trims) 1031)) -and
    (Test-InList ([MemGuardNative]::Opens) 1031)
) "opens=$([MemGuardNative]::Opens -join ',') trims=$([MemGuardNative]::Trims -join ',')"

# ---------------- G. freedMB 字节整数累加（10 号） ----------------
"=== G. freedMB 精度 ==="
Reset-GuardState
$script:FakeMem = New-FakeMem -Percent 80 -CommitPercent 50
$script:FakeModels = @([pscustomobject]@{ PID = 900; Name = 'llama-server.exe'; CommandLine = 'llama-server -m model.gguf' })
$script:FakeParentMap = @{ 900 = 5000 }
$script:FakeFgPid = 0
$script:FakeNet = @()
$g1 = New-FakeProc -Id 1040 -Name 'g1' -WsMB 200
$g2 = New-FakeProc -Id 1041 -Name 'g2' -WsMB 200
$base = [long](200 * 1048576)
$g1.WorkingSet64 = $base + 104858; $g1.AfterWs = $base
$g2.WorkingSet64 = $base + 209716; $g2.AfterWs = $base
$script:FakeProcs = @($g1, $g2)
$g = Invoke-GuardCycle
Check 'G1 两段非整 MB 字节累加后仍精确 0.3' ($g.freedMB -eq 0.3) "freed=$($g.freedMB) trimmed=$($g.trimmed)"
Check 'G2 日志口径无浮点长尾' (('{0}' -f $g.freedMB) -match '^0\.3$') "text=$('{0}' -f $g.freedMB)"
Check 'G3 动作内单项仍保留 0.1 精度' (
    ($g.actions.Count -eq 2) -and (@($g.actions | Where-Object { $_.freedMB -eq 0.2 }).Count -eq 1) -and (@($g.actions | Where-Object { $_.freedMB -eq 0.1 }).Count -eq 1)
) "actions=$(($g.actions | ForEach-Object { $_.freedMB }) -join ',')"

# ---------------- H. 提权汇总窗口（09 号） ----------------
"=== H. 提权窗口汇总 ==="
$hasLogFn = ($null -ne (Get-Command Write-MgCycleLog -CommandType Function -ErrorAction SilentlyContinue))
Check 'H0 Write-MgCycleLog 存在' $hasLogFn
if ($hasLogFn) {
    $script:Logs.Clear()
    $script:RaisePending = 0
    $script:RaiseLogSlot = [datetime]::MinValue
    $t0 = [datetime]'2026-11-21 06:00:00'
    $base = @{ modelRunning = $true; memPercent = 80; commitPercent = 50; commitUsedGB = 7.8; commitLimitGB = 39.1; level = 'warn'; freedMB = 550 }
    $r1 = [pscustomobject]($base + @{ trimmed = 3; priorityRaised = 2 })
    Write-MgCycleLog $r1 -Now $t0
    Check 'H1 trimmed>0 立即落盘' (($script:Logs.Count -eq 1) -and ($script:Logs[0].Msg -like '*trimmed=3*')) "logs=$($script:Logs.Count)"
    Check 'H2 有压制时不计 pending' ($script:RaisePending -eq 0) "pending=$($script:RaisePending)"
    $r2 = [pscustomobject]($base + @{ trimmed = 0; priorityRaised = 1 })
    Write-MgCycleLog $r2 -Now $t0
    Check 'H3 首次纯提权立即汇总' (($script:Logs.Count -eq 2) -and ($script:Logs[1].Msg -like '*raised=1*')) "logs=$($script:Logs.Count) last=$($script:Logs[1].Msg)"
    $r3 = [pscustomobject]($base + @{ trimmed = 0; priorityRaised = 2 })
    Write-MgCycleLog $r3 -Now $t0.AddSeconds(5)
    Check 'H4 窗口内只累积不落盘' (($script:Logs.Count -eq 2) -and ($script:RaisePending -eq 2)) "logs=$($script:Logs.Count) pending=$($script:RaisePending)"
    $r4 = [pscustomobject]($base + @{ trimmed = 0; priorityRaised = 1 })
    Write-MgCycleLog $r4 -Now $t0.AddSeconds(9)
    Check 'H5 累积数相加' ($script:RaisePending -eq 3) "pending=$($script:RaisePending)"
    $r5 = [pscustomobject]($base + @{ trimmed = 0; priorityRaised = 1 })
    Write-MgCycleLog $r5 -Now $t0.AddSeconds(301)
    Check 'H6 窗口到期合并落一条' (
        ($script:Logs.Count -eq 3) -and ($script:Logs[2].Msg -like '*提权汇总 300s窗口 raised=4*') -and ($script:RaisePending -eq 0)
    ) "logs=$($script:Logs.Count) last=$($script:Logs[2].Msg) pending=$($script:RaisePending)"
    $r6 = [pscustomobject]($base + @{ trimmed = 0; priorityRaised = 0 })
    Write-MgCycleLog $r6 -Now $t0.AddSeconds(305)
    Check 'H7 空转不落盘' ($script:Logs.Count -eq 3) "logs=$($script:Logs.Count)"
    Check 'H8 汇总含内存与提交口径' ($script:Logs[2].Msg -like '*mem=80% commit=50%(7.8GB/39.1GB)*') "last=$($script:Logs[2].Msg)"
}

# ---------------- I. 结构锁 ----------------
"=== I. 结构锁 ==="
$cyc = [string]$script:FnText['Invoke-GuardCycle']
$logFn = [string]$script:FnText['Write-MgCycleLog']
$all = [string]$script:WholeText
$i1 = $cyc.Contains('$freedBytes = [long]0')
$i2 = $cyc.Contains('$freedBytes += ($before - $after)')
$i3n = [regex]::Matches($cyc, '\[math\]::Round\(\$freedBytes / 1MB, 1\)').Count
$i3 = $i3n -eq 1
$i4 = [bool]($cyc -match 'if \(\$ok\) \{\s*\$trimmed\+\+')
$i5n = [regex]::Matches($cyc, '\$script:Cooldown\[\$p\.Id\] = Get-Date').Count
$i5 = $i5n -eq 1
$i6 = [bool]($cyc -match '\[math\]::Max\(\$MaxTrimPerCycle, 12\)')
$i7 = [bool]($cyc -match '\$level = ''idle''')
$i8 = [bool]($all -match 'Write-MgCycleLog \$r')
$i9n = [regex]::Matches($all, '提权汇总 \{0\}s窗口').Count
$i9 = $i9n -eq 1
$i10 = [bool]($logFn -match '\(\$Now - \$script:RaiseLogSlot\)\.TotalSeconds')
$i11 = [bool]($all -match 'if \(\$Once\) \{\s*\$r = Invoke-GuardCycle')
Check 'I1 freed 以 [long] 字节起算' $i1 "found=$i1"
Check 'I2 累加原始字节差值' $i2 "found=$i2"
Check 'I3 输出处唯一 Round' $i3 "count=$i3n"
Check 'I4 trimmed++ 只在 if($ok) 内' $i4 "found=$i4"
Check 'I5 冷却登记在 if($ok) 内且仅一处' $i5 "count=$i5n"
Check 'I6 critical 上限抬到 12' $i6 "found=$i6"
Check 'I7 idle 分支显式赋值' $i7 "found=$i7"
Check 'I8 循环只经 Write-MgCycleLog 落盘' $i8 "found=$i8"
Check 'I9 提权汇总文案只有一处' $i9 "count=$i9n"
Check 'I10 汇总窗口用可注入 Now' $i10 "found=$i10"
Check 'I11 -Once 入口未被动过' $i11 "found=$i11"

"=== 汇总 ==="
"RESULT: PASS=$($script:pass) FAIL=$($script:fail)"
if ($script:fail -gt 0) { exit 1 }
exit 0
