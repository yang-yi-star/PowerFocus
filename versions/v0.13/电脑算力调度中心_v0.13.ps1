#Requires -Version 7.0
# ============================================================
# 电脑算力调度中心 v0.13 —— 全机资源调度中枢（首个正式版本，v2 基础上升级）
# 修复项（相对 v1）:
#   1. Stop-Focus 还原目标进程原始优先级（v1 永久遗留 High）
#   2. 降级进程记录原始优先级，恢复写回原值（v1 一律设回 Normal）
#   3. powercfg 等 native 命令检查 $LASTEXITCODE（v1 静默失败）
#   4. 进程列表改为 500ms 两次采样差分的实时 CPU%（v1 是累计 CPU 秒）
#   5. 日志超 5MB 自动归档
#   6. watchdog 按目标期望优先级守护（支持 High / RealTime）
#   7. 自启任务名改英文 PowerFocusAutoV2（规避 schtasks 中文任务名编码坑）
# 新增:
#   A. 授权"开后门"机制: authorized_apps.json 授权清单 + .auth_token 密钥
#      GodMode = High/RealTime 优先级 + PriorityBoostEnabled + 高性能电源 + watchdog 守护
#   B. JSON 命令总线: 轮询 E:\PowerFocus\v3\commands\in\*.json，执行后移入 done\
#      动作: focus / unfocus / status / authorize / revoke / set_priority / set_power_plan
#      status 结果写 E:\PowerFocus\v3\commands\out\status.json（供自然语言层读取）
# 铁律: 本文件为新建版本，原 电脑算力调度中心.ps1 保持不动。
# ============================================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ===== 版本标识（v0.05 = 首个正式版本，2026-11-05）=====
$script:PF_Version      = '0.13'
$script:PF_VersionLabel = 'v0.13'
$script:PF_BuildDate    = '2026-11-15'
# ===== Gate 0 · 螺丝一：v3 单实例锁（目录级独占句柄，进程退出由系统自动释放）=====
# 说明：FileShare.None 的独占句柄比 PID 文件可靠——不存在 TOCTOU 竞态，也不怕残留死文件。
# 测试需绕过时设 $env:PF_V3_NO_LOCK=1（仅供只读测试，勿用于正常启动）。
if (-not $env:PF_V3_NO_LOCK) {
    $script:V3LockPath = Join-Path $PSScriptRoot ".v3.lock"
    try {
        $fs = [System.IO.File]::Open($script:V3LockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        $fs.SetLength(0)
        $fs.Write([System.Text.Encoding]::UTF8.GetBytes("$PID`n$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"))
        $fs.Flush()
        $script:V3LockStream = $fs
    } catch {
        Write-Host "v3 已在运行（实例锁被占用），本次启动退出" -ForegroundColor Yellow
        exit 1
    }
}

# ===== Gate 0 · 螺丝二：目录隔离（无需开关，日志/状态/命令总线一律落在脚本所在目录）=====
# 本文件所有路径均基于 $PSScriptRoot，不会再写回 E:\PowerFocus 根目录或 v2 目录。

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 阶段三：内存修剪与 I/O 优先级的 Win32 入口
# EmptyWorkingSet: 把进程工作集换出到页面文件（压制其物理内存占用）
# NtQuery/NtSetInformationProcess(ProcessIoPriority=0x21): 读写磁盘 I/O 优先级（VeryLow=0/Low=1/Normal=2/High=3）
Add-Type -Namespace PowerFocus -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("psapi.dll")]
public static extern bool EmptyWorkingSet(System.IntPtr hProcess);
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern int NtQueryInformationProcess(System.IntPtr hProcess, int infoClass, ref int info, int length, ref int returnLength);
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern int NtSetInformationProcess(System.IntPtr hProcess, int infoClass, ref int info, int length);
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern int NtSuspendProcess(System.IntPtr hProcess);
[System.Runtime.InteropServices.DllImport("ntdll.dll")]
public static extern int NtResumeProcess(System.IntPtr hProcess);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr OpenProcess(uint access, bool inherit, int pid);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool CloseHandle(System.IntPtr h);
'@

# 不可终止的系统关键进程（杀之会导致蓝屏/重启，任何情况下都拒绝）
# F9：与 Python 服务端共用同一份名单真源；文件缺失时用内置兜底。
$script:UnkillableProcesses = @('System','Registry','Idle','Memory Compression','smss','csrss','wininit','services','lsass','winlogon','fontdrvhost','WUDFHost','dwm','MsMpEng')
$criticalFile = Join-Path $PSScriptRoot 'critical_processes.json'
if (Test-Path -LiteralPath $criticalFile) {
    try {
        $names = (Get-Content -LiteralPath $criticalFile -Raw -Encoding utf8 | ConvertFrom-Json).names
        if ($names -and @($names).Count -gt 0) { $script:UnkillableProcesses = @($names) }
    } catch { Write-Warning "关键进程名单读取失败，使用内置兜底: $_" }
}

# ---------- 全局状态 ----------
$script:TargetPid              = $null
$script:TargetName             = ""
$script:FocusMode              = "gentle"          # gentle | aggressive | godmode
$script:TargetDesiredPriority  = [System.Diagnostics.ProcessPriorityClass]::High
$script:TargetOriginalPriority = $null             # 目标进程聚焦前的优先级（字符串）
$script:TargetOriginalIoPriority = $null           # 阶段三：目标进程 GodMode 前的 I/O 优先级（int，$null=未记录/查询失败）
$script:DesiredIoPriority = $null                  # 阶段三：期望 I/O 优先级（int；$null=不守护）
$script:OriginalPlan           = $null
$script:DemotedPids            = @{}               # PID -> 原优先级字符串
$script:TimerObj               = $null             # watchdog 定时器
$script:CmdTimerObj            = $null             # 命令总线轮询定时器
$script:CmdBusEnabled          = $true
$script:BusyProcessing         = $false
$script:TrayIcon               = $null
$script:PowerRequest           = $null             # 阶段五：算力申请（补给焦点：pid/name/level/expiry/reason）
$script:PowerDemoted           = @{}               # 阶段五：补给时被压进程 PID -> 原优先级字符串
$script:PowerKilled            = @()               # 阶段五增强：本次补给清理的"明显无用"进程记录（pid/name）
$script:PowerEcoQos           = @{}
$script:PowerEcoQos           = @{}               # 2026-11-15：补给时开了 EcoQoS 的 PID -> $true，释放时要逐个关掉
$script:CompanionFile         = $null            # 2026-11-15：配套应用清单（下方按 $PSScriptRoot 赋值）

# ---------- 统一内存（整机算力池）参数 ----------
# 语义：把整机视为一个算力池，GPU 显存与系统内存共同服务本地模型。
# 下面两个预留量是给"别的应用也必须活着"留的余地——
# 用户要求"给其他应用最小的空间，给本地模型最大的空间"，不是把别的应用饿死。
#
# 【为什么是"绝对量 + 比例"而不是"两个绝对量"】
#   nvidia-smi 的 memory.free 已经扣掉了"当前已占用"（含已运行进程的 CUDA 上下文、
#   Windows DWM 显示合成）。但新进程启动时要**再新分配**一份 CUDA 上下文，
#   这一份 free 里没有预扣，所以必须单独留。
#   - CUDA 上下文 = 绝对量。NVIDIA 开发者论坛实测约 300MB，Windows 上因 WDDM
#     托管会略高，留 512MB 是稳健值；它不随显存总量缩放（8GB 与 48GB 卡同样是这份）。
#   - 计算/图缓冲 = 比例。NVIDIA NIM 默认 gpu_memory_utilization=0.9（留 10% 给
#     CUDA graph 编译与采样器预热），CUDA graph 在部分架构上要吃掉 1–5GB；
#     社区推荐 15% 安全线。按比例推导，48GB 卡就自动留 7.2GB，2GB 卡就留 300MB。
#   参考：NVIDIA NIM LLM Troubleshooting / NVIDIA Developer Forums #335106 /
#         orca-class VRAM sizing guides (2026)
$script:CudaReservedMB   = 512     # CUDA 上下文固定占用（绝对量，不随显存缩放）
$script:ComputeReservePct = 15     # 计算/图缓冲占空闲显存的比例（%）
$script:ComputeReserveMB = 0       # 0 = 按 ComputeReservePct 动态推导；>0 = 强制固定值（调试用）
$script:MaxGpuLayersSafe = 0       # 0 = 按显存自动推导（适配任意机器）；>0 = 硬钳层数上限
                                   # 8GB 显存机器若出现 OOM，可显式改为 20（原实测值）

# llama-server 端口：默认 8080，可用环境变量 POWERFOCUS_LLAMA_PORT 覆盖。
# 不写死在四处调用点，是因为换模型/换实例时端口会变；写死会让 model_identity / boost
# 在非 8080 实例上直接失效（它们都靠这个端口定位 llama-server）。
$script:LlamaPort = if ($env:POWERFOCUS_LLAMA_PORT) { [int]$env:POWERFOCUS_LLAMA_PORT } else { 8080 }
$script:LlamaBase = "http://127.0.0.1:$($script:LlamaPort)"

$script:LogDir   = $PSScriptRoot
$script:LogFile  = Join-Path $script:LogDir "电脑算力调度中心_v3.log"
$script:CmdDir   = Join-Path $script:LogDir "commands"
$script:CmdIn    = Join-Path $script:CmdDir "in"
$script:CmdOut   = Join-Path $script:CmdDir "out"
$script:CmdDone  = Join-Path $script:CmdDir "done"
$script:AuthFile = Join-Path $script:LogDir "authorized_apps.json"
$script:CompanionFile = Join-Path $script:LogDir "companion-apps.json"
$script:TokenFile= Join-Path $script:LogDir ".auth_token"
$script:SceneFile= Join-Path $script:LogDir "scenes.json"
$script:ModelProfileFile = Join-Path $script:LogDir "model-profiles.json"
$script:LifecycleLog = Join-Path $script:LogDir "v3-lifecycle.log"
$script:HeartbeatFile = Join-Path $script:LogDir "v3_heartbeat.json"
$script:ScriptStartTime = Get-Date
$script:TickCount = 0
$global:PF_LifecycleLog = $script:LifecycleLog

# 回滚框架（只记录状态，不重启进程）
$rbModule = Join-Path $PSScriptRoot "lib\rollback.ps1"
if (Test-Path -LiteralPath $rbModule) { . $rbModule }

# 多模型注册表（GGUF 身份识别 + 档案解析）
$mrModule = Join-Path $PSScriptRoot "lib\model-registry.ps1"
if (Test-Path -LiteralPath $mrModule) { . $mrModule }

$script:Whitelist = @('Idle','System','Registry','Memory Compression','csrss','dwm','explorer','winlogon','lsass','services','svchost','fontdrvhost','conhost','Taskmgr','RuntimeBroker','ShellExperienceHost','SearchHost','TextInputHost','StartMenuExperienceHost','pwsh','powershell','python','DoubaoWork','llama-server')
# 白名单里并非都不能作为"算力补给目标"。上面这批是"不许压/不许杀"，
# 但 llama-server / python / pwsh 恰恰是最需要算力的对象，补给它们时应放行。
$script:SupplyableNames = @('llama-server','python','pwsh','powershell','DoubaoWork')

# 高性能电源计划标准 GUID
$script:HighPerfGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"

# ---------- 基础设施 ----------
function Write-Log {
    param([string]$Level, [string]$Msg)
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        # 修复#5: 日志轮转，超 5MB 归档
        $item = Get-Item -LiteralPath $script:LogFile -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt 5MB) {
            Move-Item -LiteralPath $script:LogFile -Destination "$($script:LogFile).bak" -Force
        }
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -LiteralPath $script:LogFile -Value "$ts [$Level] $Msg" -Encoding utf8
    } catch { Write-Host "日志写入失败: $_" }
}

# 生命周期日志：启动/退出/异常/消息循环返回，独立于主日志（移植自 v2）
function Write-Lifecycle {
    param([string]$Event, [string]$Detail = "")
    try {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $up = [math]::Round(((Get-Date) - $script:ScriptStartTime).TotalSeconds, 1)
        Add-Content -LiteralPath $script:LifecycleLog -Value "$ts [$Event] pid=$PID uptime_sec=$up $Detail" -Encoding utf8
    } catch {}
}

# 心跳：每 5 个 tick 写 PID/运行时长/tick/规则状态（移植自 v2）
function Write-Heartbeat {
    try {
        $now = Get-Date
        $hb = [ordered]@{
            time = $now.ToString("yyyy-MM-dd HH:mm:ss")
            pid = $PID
            start = $script:ScriptStartTime.ToString("yyyy-MM-dd HH:mm:ss")
            uptime_sec = [math]::Round(($now - $script:ScriptStartTime).TotalSeconds, 1)
            tick = $script:TickCount
            rules_running = [bool]$script:RulesRunning
            cmd_bus = [bool]$script:CmdBusEnabled
            busy = [bool]$script:BusyProcessing
        }
        $hb | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:HeartbeatFile -Encoding utf8
    } catch {}
}

# ---------- 优先级语义函数（必须在启动自保之前定义） ----------
# 教训（10:18 实测）：启动自保在 L102 调用 Get-PriorityRank，若函数定义在其后，
# 脚本按行执行时函数尚未定义，自保会被 catch 吞掉（日志报"不被识别"）。
function Get-PriorityClassFromString {
    param([string]$Name)
    switch ($Name) {
        'Idle'        { return [System.Diagnostics.ProcessPriorityClass]::Idle }
        'BelowNormal' { return [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
        'Normal'      { return [System.Diagnostics.ProcessPriorityClass]::Normal }
        'AboveNormal' { return [System.Diagnostics.ProcessPriorityClass]::AboveNormal }
        'High'        { return [System.Diagnostics.ProcessPriorityClass]::High }
        'RealTime'    { return [System.Diagnostics.ProcessPriorityClass]::RealTime }
        default       { return $null }
    }
}

function Get-PriorityRank {
    # 优先级语义排序。绝不能直接用数值 -lt 比较：
    # Windows 枚举值 BELOW_NORMAL=16384 / NORMAL=32 / HIGH=128，
    # 数值大小与优先级次序无关（16384 > 32 但 BelowNormal 低于 Normal）。
    param($Cls)
    switch ($Cls) {
        ([System.Diagnostics.ProcessPriorityClass]::Idle)       { return 0 }
        ([System.Diagnostics.ProcessPriorityClass]::BelowNormal) { return 1 }
        ([System.Diagnostics.ProcessPriorityClass]::Normal)      { return 2 }
        ([System.Diagnostics.ProcessPriorityClass]::AboveNormal) { return 3 }
        ([System.Diagnostics.ProcessPriorityClass]::High)        { return 4 }
        ([System.Diagnostics.ProcessPriorityClass]::RealTime)    { return 5 }
        default { return -1 }
    }
}

# ---------- 阶段四：规则引擎加载（必须在脚本顶层 dot-source） ----------
# 教训（10:00 实测）：在命令处理函数内 dot-source，函数会注册到函数作用域，
# 函数返回即销毁，命令总线 tick（脚本作用域）将找不到 Invoke-RulesEngineOnce，
# 规则评估永不执行。故引擎函数必须在此（脚本顶层）加载。
$script:RulesEngineLoaded = $false
if (Test-Path -LiteralPath (Join-Path $script:LogDir "rules-engine.ps1")) {
    . (Join-Path $script:LogDir "rules-engine.ps1")
    $script:RulesEngineLoaded = $true
    Write-Log "INFO" "阶段四规则引擎已加载（rules-engine.ps1，脚本作用域）"
    # 规则引擎随 v2 常驻：rules.json 存在即自动启动（避免重启后心跳文件遗留 running=true 假象）
    try {
        if (Get-Command Start-RulesEngine -ErrorAction SilentlyContinue) {
            Start-RulesEngine
            Write-Log "INFO" "规则引擎已随 v0.05 自动启动"
        }
    } catch { Write-Log "WARN" "规则引擎自动启动失败: $_" }
} else {
    Write-Log "WARN" "rules-engine.ps1 不存在，阶段四功能不可用（start_rules 等动作会报错）"
}

# ---------- 自保：调度中心自身必须保持 Normal ----------
# 教训（10:0x 实测）：豆包环境子进程常为 BelowNormal，Start-Process 的子进程
# 会继承父进程优先级类，v2 重启后可能全程 BelowNormal。启动时强制回正。
try {
    $self = Get-Process -Id $PID
    if ((Get-PriorityRank $self.PriorityClass) -lt (Get-PriorityRank ([System.Diagnostics.ProcessPriorityClass]::Normal))) {
        $self.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
        Write-Log "INFO" "自保: 调度中心自身优先级已回正 Normal（原 $($self.PriorityClass)）"
    } else {
        Write-Log "INFO" "自保: 启动时优先级 $($self.PriorityClass)，正常"
    }
} catch { Write-Log "WARN" "自保检查异常: $_" }


function Show-Balloon {
    param([string]$Title, [string]$Msg)
    try { if ($script:TrayIcon) { $script:TrayIcon.ShowBalloonTip(3000, $Title, $Msg, [System.Windows.Forms.ToolTipIcon]::Info) } } catch {}
}

# ---------- 阶段五：算力申请-补给（应用主动借算力） ----------
# 机制：应用/游戏缺算力时通过命令总线或 MCP 申请 → 调度中心把其他应用算力
# 让给它（清场压低），申请者提升；超时/进程退出/显式释放自动还原。
# 铁律：DeepSeek 全家（含附属进程树）、系统白名单、授权清单、前台进程、
#       豆包自身与输入法一律不压。
function Get-DeepSeekTreePids {
    # 返回 DeepSeek Harness 及其全部后代的 PID 集合（点名保留，绝不动）
    try {
        $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
        $set = @{}
        foreach ($r in $all | Where-Object { $_.Name -match '^DeepSeek Harness\.exe$' }) {
            $set[[int]$r.ProcessId] = $true
        }
        $changed = $true
        while ($changed) {
            $changed = $false
            foreach ($p in $all) {
                if ($set.ContainsKey([int]$p.ParentProcessId) -and -not $set.ContainsKey([int]$p.ProcessId)) {
                    $set[[int]$p.ProcessId] = $true
                    $changed = $true
                }
            }
        }
        return $set
    } catch { return @{} }
}

# ---------- 阶段五增强：进程价值判断（有用/无用 → 分级处理） ----------
# 用户拍板（11-03）：① 分级：压全部 + 杀明显无用；② 交互中 / 点名保留 / 后台干活都算有用，只清真正空闲的。
$script:BusyCpuThreshold    = 2.0   # 进程近期 CPU 单核占用 % 超过该值 = 在干活（下载/训练/渲染/编译，视为有用）
$script:JunkMinUptimeSec    = 120   # 启动不足该秒数的进程不杀（防杀刚打开的应用）

function Get-LastInputSeconds {
    # 距上次键盘/鼠标输入多少秒（系统级，GetLastInputInfo）——判断用户是否"正在交互"
    try {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class LastInputInfo {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static uint GetIdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(lii);
        if (!GetLastInputInfo(ref lii)) return 0;
        uint now = (uint)Environment.TickCount;
        return (now - lii.dwTime) / 1000;
    }
}
"@ -ErrorAction Stop
        return [LastInputInfo]::GetIdleSeconds()
    } catch { return 0 }
}

function Get-IoActivePidSet {
    # 用 kernel32 的 GetProcessIoCounters 测每进程的 OtherOperationCount 速率。
    #
    # 为什么必须用 P/Invoke 而不是 Get-Process：Get-Process 的 Read/WriteTransferCount
    # 对 QQ、DSH 这类进程返回空（PowerShell 的 Process 对象拿不到），
    # Get-Counter 的 IO Read/Write Bytes/sec 在这台机器上恒为 0。
    # 直接调 kernel32 才拿得到真实计数（2026-11-15 实测）。
    #
    # 为什么看 OtherOperationCount 而不是读/写字节数：
    #   Other = 网络/设备/同步类 IO（socket 收发、设备控制）
    #   Read/Write = 文件读写（含磁盘缓存）
    # 实测证据：
    #   QQ 13180  Other 20.7/s（在收发）      读op 65.5/s（也在读文件）
    #   DSH 43136 Other 88.8/s 且 3.15 KB/s（在联网）
    #   msedge    Other 0    但 读op+写op 363/s（纯磁盘缓存，没有网络）
    #   QQEX      Other 0    （静止）
    # 所以只有 Other 速率能区分"真的在联网"和"只是在刷缓存"。
    # 阈值 3/s：实测 QQ 副进程稳态只有 5.0/s，5.0 会卡线导致抖动掉出；
    # 3.0 留出安全边际，同时 WorkBuddy(2.8)/QQEX(0)/msedge(0) 仍在阈值外。
    param([int]$SampleMs = 1200, [double]$MinOpsPerSec = 3.0)

    $result = @{}
    if (-not ('PfIoCounters' -as [type])) {
        try {
            Add-Type -Language CSharp -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public struct PF_IO_COUNTERS {
    public ulong ReadOperationCount;  public ulong WriteOperationCount;  public ulong OtherOperationCount;
    public ulong ReadTransferCount;   public ulong WriteTransferCount;   public ulong OtherTransferCount;
}
public class PfIoCounters {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int p);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessIoCounters(IntPtr h, out PF_IO_COUNTERS c);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    public static ulong[] Read(int pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) h = OpenProcess(0x0400, false, pid);
        if (h == IntPtr.Zero) return null;
        try {
            PF_IO_COUNTERS c;
            if (!GetProcessIoCounters(h, out c)) return null;
            return new ulong[]{ c.ReadOperationCount, c.WriteOperationCount, c.OtherOperationCount };
        } finally { CloseHandle(h); }
    }
}
'@
        } catch { Write-Log "WARN" "IO 计数器类型编译失败，跳过链路活动判据: $_"; return $result }
    }

    $p1 = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        $v = [PfIoCounters]::Read([int]$p.Id)
        if ($v) { $p1[[int]$p.Id] = $v[2] }   # 只存 OtherOperationCount
    }
    Start-Sleep -Milliseconds $SampleMs

    $sec = $SampleMs / 1000.0
    foreach ($pid_ in $p1.Keys) {
        $v = [PfIoCounters]::Read($pid_)
        if (-not $v) { continue }
        $rate = ($v[2] - $p1[$pid_]) / $sec
        if ($rate -ge $MinOpsPerSec) { $result[$pid_] = [math]::Round($rate, 1) }
    }

    # 这里刻意不做"按进程名扩成整个应用"。
    # 试过一次：Edge 有 28 个进程，只要其中一个有网络活动，整组就全保，
    # 结果清场从 81 个掉到 30 个，"该压的压不动"。
    # 应用级保护归 companion-apps.json（它按父子链聚合，语义明确）；
    # 这里的 IO 判据只保护"这一个进程此刻真在干活"，不替应用做决定。
    return $result
}


function Get-BusyPidSet {
    # 正在干活的进程 PID 集合：基于 PerfProc 瞬时 CPU 采样（两次查询取第二次，避开首次 0 值）
    $set = @{}
    try {
        $null = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 1000
        $perf = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction SilentlyContinue
        foreach ($pf in $perf) {
            if ($pf.IDProcess -gt 0 -and [double]$pf.PercentProcessorTime -ge $script:BusyCpuThreshold) {
                $set[[int]$pf.IDProcess] = $true
            }
        }
    } catch {}
    return $set
}

function Get-TCPActivePids {
    # 有活跃 TCP 连接（Established 正在通信 / Listen 正在提供服务）的进程 PID 集合
    # 服务类进程（如 ollama 监听 11434）常无 Established 连接，但 Listen = 在提供服务 = 有用
    $set = @{}
    try {
        Get-NetTCPConnection -ErrorAction SilentlyContinue |
            Where-Object { $_.State -in @('Established','Listen') -and $_.OwningProcess -gt 0 } |
            ForEach-Object { $set[[int]$_.OwningProcess] = $true }
    } catch {}
    return $set
}

function Test-WindowedAncestor {
    # 进程的祖先链中是否有"有可见窗口"的进程？
    # 浏览器/QQ/夸克等的渲染/GPU/辅助子进程无窗口，但属于用户正在用的应用 → 绝不杀
    param([int]$ProcId, $PpidMap, $WinIds)
    $cur = $ProcId
    for ($i = 0; $i -lt 16; $i++) {
        if (-not $PpidMap.ContainsKey($cur)) { return $false }
        $par = [int]$PpidMap[$cur]
        if ($WinIds.ContainsKey($par)) { return $true }
        if ($par -le 0 -or $par -eq $cur) { return $false }
        $cur = $par
    }
    return $false
}

function Get-ProcessValueRank {
    # 价值分级（2026-11-15 修正。用户口径：判断"用没用"就看后台窗口 + 用户声明的配套应用）
    #
    #   protect   = 配套应用组 / 自身 / 系统关键 / 白名单 / 授权 / Windows 服务 / DeepSeek
    #               （完全不动）
    #   active    = 前台窗口所属进程（用户此刻正操作，完全不碰）
    #   busy      = CPU 真的在动（导出/训练/编译/渲染）→ 不动，压了会拖慢
    #   visible   = 有可见窗口（含最小化），或属于某可见窗口应用的子进程
    #               → 降优先级，绝不杀（用户点开过，可能存着没保存的工作）
    #   idle      = 无窗口 + CPU 不忙 + 不属于任何可见窗口应用
    #               → 降优先级 + EcoQoS + 修剪工作集，绝不杀
    #
    # 【配套应用】用户声明"正在使用"的应用，写 companion-apps.json。
    #   为什么必须靠声明而不是自动推断：这台机器上四个信号全部判不准——
    #     CPU：QQ 收发消息时仅 0.8%，DSH 0.4%，聊天几乎不耗 CPU
    #     IO ：Get-Process 的 Read/WriteTransferCount 为空，Get-Counter 恒 0
    #     TCP：只能证明"连着"。QQ 连腾讯 36.155.x，Edge 连 CDN 443，挂着的也连
    #     窗口：只能证明"点开过"。QQ 最小化照样在收发
    #   用户原话：「QQ 连的是我手机，DSH 用它连着 QQ，用 DSH 里面的人跟我 QQ 聊天。
    #             其他几个都没在用，就这 QQ 和 DSH 在用」——这是声明，不是指标。
    #
    # 【TCP 不再算"在用"】旧判据把"有连接"当在干活，结果 QQ/剪映/WorkBuddy/Edge
    #   全因挂着服务器连接被判 busy → 完全不动，等于没清场。
    #   现在 TCP 只用于展示，不参与分级。
    #
    # 铁律：清场永远不杀进程。杀只在用户显式发 kill_process 时才发生。
    param($Process, $FgPid, $DsTree, $AuthNames, $NeverPress, $SysNames, $SvcPids, $BusySet, $TcpSet, $PpidMap, $WinIds, $CompanionPids, $IoActive)
    $id = [int]$Process.Id
    $name = [string]$Process.ProcessName
    if ($id -eq $PID) { return 'protect' }
    if ($CompanionPids -and $CompanionPids.ContainsKey($id)) { return 'protect' }   # 用户声明的配套应用整组
    if ($DsTree.ContainsKey($id)) { return 'protect' }
    if ($name -in $NeverPress) { return 'protect' }
    if ($name -in $AuthNames) { return 'protect' }
    if ($name -in $SysNames) { return 'protect' }
    if ($SvcPids.ContainsKey($id)) { return 'protect' }   # Windows 服务进程：绝对不杀，也不压
    if ($FgPid -and $id -eq $FgPid) { return 'active' }
    # CPU 真在动 = 在干活。这一档无论有没有窗口都不压，否则会拖慢用户正在跑的导出/训练。
    if ($BusySet.ContainsKey($id)) { return 'busy' }
    # 有网网络/设备 IO 活动（Other 速率超阈值）= 在真的收发或做设备 IO，不压。
    # 这一档专门为 QQ/DSH 这类消息通道设计：聊天时 CPU 几乎为 0，只有 Other IO 在动。
    if ($IoActive -and $IoActive.ContainsKey($id)) { return 'busy' }
    # 以下才是"可以收算力"的范围
    if ($Process.MainWindowHandle -ne 0) { return 'visible' }
    if ($WinIds.ContainsKey($id)) { return 'visible' }    # 最小化窗口：MainWindowHandle 可能为 0，用可见窗口集合兜住
    if (Test-WindowedAncestor $id $PpidMap $WinIds) { return 'visible' }  # 同属一个可见应用（渲染/GPU 子进程），按同组处理
    return 'idle'
}

function Get-ProcessContext {
    # 一次性采集价值判断所需全部上下文（补给清场 / list_junk 共用，避免判定逻辑漂移）
    $ctx = @{}
    $ctx.FgPid = Get-ForegroundPid
    $ctx.DsTree = Get-DeepSeekTreePids
    $ctx.AuthNames = @()
    try { $auth = Get-Content -Raw -LiteralPath $script:AuthFile -Encoding utf8 | ConvertFrom-Json; $ctx.AuthNames = @($auth.apps.name) } catch {}
    $ctx.NeverPress = @('DoubaoWork','msedgewebview2','wetype','wetype_renderer','ChsIME','ctfmon','SearchHost')
    $ctx.SysNames = $script:Whitelist + @(
        'System','Registry','Memory Compression','csrss','dwm','winlogon','lsass','services','svchost',
        'fontdrvhost','conhost','smss','wininit','spoolsv','audiodg','WmiPrvSE','MsMpEng','NisSrv',
        'SearchHost','ShellExperienceHost','RuntimeBroker','sihost','taskhostw','ApplicationFrameHost',
        'SecurityHealthService','TextInputHost','StartMenuExperienceHost','explorer','Taskmgr','ctfmon',
        'wetype','ChsIME','msedgewebview2',
        'LsaIso','Secure System','WUDFHost','WmiApSrv','wlanext','NgcIso','nvcontainer','NVDisplay.Container',
        'atieclxx','atiesrxx','SearchFilterHost','SearchProtocolHost','WebExperienceHostApp','ShellHost',
        'smartscreen','UserOOBEBroker','AggregatorHost','dllhost','unsecapp','tailscaled','cncmd',
        'OpenConsole','RadeonSoftware')
    $ctx.SvcPids = @{}
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -gt 0 -and $_.State -eq 'Running' } |
        ForEach-Object { $ctx.SvcPids[[int]$_.ProcessId] = $true }
    $ctx.BusySet = Get-BusyPidSet
    $ctx.IoActive = Get-IoActivePidSet
    $ctx.TcpSet  = Get-TCPActivePids

    # 一次 Win32_Process 查询同时拿到 父子关系 + 进程名，避免查两遍
    $ctx.PpidMap = @{}
    $ctx.NameMap = @{}
    $childrenOf = @{}
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
        $cid = [int]$_.ProcessId; $ppid = [int]$_.ParentProcessId
        $ctx.PpidMap[$cid] = $ppid
        $ctx.NameMap[$cid] = [string]$_.Name
        if (-not $childrenOf.ContainsKey($ppid)) { $childrenOf[$ppid] = @() }
        $childrenOf[$ppid] += $cid
    }

    # 配套应用（用户声明正在使用）：按父子链聚合整组 PID
    # 依据：这台机器上 CPU/IO/TCP/窗口四个信号都判不准"在用"——
    #   QQ 聊天时 CPU 仅 0.8%；Get-Process 的 IO 字段为空、Get-Counter 恒 0；
    #   TCP 只能证明"连着"（QQ 连腾讯、Edge 连 CDN 都连着）；
    #   窗口只能证明"点开过"（QQ 最小化照样在收发）。
    # 所以"在用"只能由用户声明，写在 companion-apps.json。
    $ctx.CompanionApps = @()
    $ctx.CompanionPids = @{}
    if (Test-Path -LiteralPath $script:CompanionFile) {
        try {
            $cj = Get-Content -LiteralPath $script:CompanionFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $ctx.CompanionApps = @($cj.apps | ForEach-Object { [string]$_.name })
        } catch { Write-Log "WARN" "companion-apps.json 解析失败: $_" }
    } else {
        # 文件缺失时兜底：至少保住消息通道，不要让用户以为在跑全机清场
        $ctx.CompanionApps = @('QQ', 'QQEX', 'DeepSeek Harness')
    }
    foreach ($nm in $ctx.CompanionApps) {
        $want = $nm.ToLower()
        # 注意：循环变量不能叫 $pid —— 那是 PowerShell 只读自动变量（当前进程 ID），
        # 赋值会抛 "无法覆盖变量 PID"，整个聚合静默失效（2026-11-15 实测踩过）
        foreach ($cpid in $ctx.NameMap.Keys) {
            $cur = $ctx.NameMap[$cpid]
            if ($cur -and ($cur.ToLower() -eq $want -or $cur.ToLower() -eq ($want + '.exe'))) {
                # BFS 整棵子树
                $stack = @($cpid)
                while ($stack.Count -gt 0) {
                    $x = $stack[0]
                    if ($stack.Count -gt 1) { $stack = $stack[1..($stack.Count-1)] } else { $stack = @() }
                    if ($ctx.CompanionPids.ContainsKey($x)) { continue }
                    $ctx.CompanionPids[$x] = $true
                    if ($childrenOf.ContainsKey($x)) { foreach ($c in $childrenOf[$x]) { $stack += $c } }
                }
            }
        }
    }

    $ctx.WinIds = @{}
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { $ctx.WinIds[[int]$_.Id] = $true }
    return $ctx
}

function Invoke-PowerSupply {
    param([int]$TargetPid, [string]$Level, [int]$DurationSec, [string]$Reason)
    $tp = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
    if (-not $tp) { return "ERROR: 申请目标进程不存在 (PID $TargetPid)" }
    if ($tp.Name -in $script:Whitelist -and $tp.Name -notin $script:SupplyableNames) { return "ERROR: $($tp.Name) 属系统关键进程（白名单），拒绝申请" }
    # 焦点切换：先释放旧申请，把算力让给新缺算力的
    if ($script:PowerRequest) { Restore-PowerSupply | Out-Null }
    $script:PowerDemoted = @{}
    $script:PowerEcoQos  = @{}
    $ctx = Get-ProcessContext
    $fgPid = $ctx.FgPid; $dsTree = $ctx.DsTree; $authNames = $ctx.AuthNames
    $neverPress = $ctx.NeverPress; $sysNames = $ctx.SysNames; $svcPids = $ctx.SvcPids
    $busySet = $ctx.BusySet; $tcpSet = $ctx.TcpSet; $ppidMap = $ctx.PpidMap; $winIds = $ctx.WinIds
    $companionPids = $ctx.CompanionPids; $ioActive = $ctx.IoActive
    # 清场：价值分级 → 分级处理
    #   protect / active / busy → 完全不碰
    #   visible → 降优先级（开着但没在用，算力收走；进程留着，不丢工作进度）
    #   idle    → 降优先级 + EcoQoS 效率模式 + 修剪工作集
    # 永不 Stop-Process：这里一条杀进程的语句都不该有。
    $procs = Get-Process -ErrorAction SilentlyContinue
    $demoted = 0
    $ecoOn = 0
    $trimmed = 0
    $visibleCount = 0
    $idleCount = 0
    $hasEco = [bool](Get-Command Set-EcoQos -ErrorAction SilentlyContinue)
    foreach ($p in $procs) {
        if ($p.Id -eq $PID) { continue }
        if ($p.Id -eq $TargetPid) { continue }
        $rank = Get-ProcessValueRank -Process $p -FgPid $fgPid -DsTree $dsTree -AuthNames $authNames -NeverPress $neverPress -SysNames $sysNames -SvcPids $svcPids -BusySet $busySet -TcpSet $tcpSet -PpidMap $ppidMap -WinIds $winIds -CompanionPids $companionPids -IoActive $ioActive
        if ($rank -in @('protect','active','busy')) { continue }

        if ($rank -eq 'visible') { $visibleCount++ } else { $idleCount++ }

        # 第一步：降优先级（记原值，Restore-PowerSupply 会写回）
        try {
            $cur = [string]$p.PriorityClass
            if ($cur -notin @('Idle','BelowNormal')) {
                $target = if ($Level -eq 'aggressive' -or $Level -eq 'godmode') { 'Idle' } else { 'BelowNormal' }
                $p.PriorityClass = $target
                $script:PowerDemoted[$p.Id] = $cur
                $demoted++
            }
        } catch {}   # 系统进程/受保护进程改不动，静默跳过

        # 第二步：只对完全闲置的进程开 EcoQoS 效率模式（限制到能效核频率档）
        if ($rank -eq 'idle' -and $hasEco) {
            try {
                if (Set-EcoQos -ProcId $p.Id -On $true) {
                    $script:PowerEcoQos[[int]$p.Id] = $true
                    $ecoOn++
                }
            } catch {}
        }

        # 第三步：只对完全闲置的进程修剪工作集，把物理页换出去
        if ($rank -eq 'idle') {
            try {
                if ([PowerFocus.Native]::EmptyWorkingSet($p.Handle)) { $trimmed++ }
            } catch {}
        }
    }
    $script:PowerKilled = @()
    # 提升申请者
    $tp.Refresh()
    try {
        if ($Level -eq 'godmode') { $tp.PriorityClass = 'High'; $tp.PriorityBoostEnabled = $true }
        elseif ($Level -eq 'aggressive') { $tp.PriorityClass = 'High' }
        else { $tp.PriorityClass = 'AboveNormal' }
    } catch { return "ERROR: 提升申请者失败: $_" }
    $now = Get-Date
    $script:PowerRequest = [pscustomobject]@{
        pid = $TargetPid; name = $tp.Name; level = $Level; reason = $Reason
        since = $now; expiry = $now.AddSeconds([Math]::Max(30, $DurationSec))
        demoted = $script:PowerDemoted.Count; killed = 0; visible = $visibleCount; idle = $idleCount; eco = $ecoOn; trimmed = $trimmed
    }
    $detail = "开着但没在用的应用 $visibleCount 个、彻底闲置的后台 $idleCount 个"
    if ($ecoOn -gt 0) { $detail += "，其中 $ecoOn 个进 EcoQoS 效率模式" }
    if ($trimmed -gt 0) { $detail += "，$trimmed 个工作集已换出" }
    Write-Log "INFO" "算力补给: $($tp.Name)($TargetPid) level=$Level duration=$DurationSec reason=$Reason，压低 $($script:PowerDemoted.Count) 进程（visible=$visibleCount idle=$idleCount eco=$ecoOn trim=$trimmed），未杀任何进程"
    return "OK: 算力已补给 $($tp.Name) (PID $TargetPid) level=$Level，持续 $DurationSec 秒。压低 $($script:PowerDemoted.Count) 个进程：$detail。未杀任何进程（前台/DeepSeek/系统关键/授权/豆包/调度中心完全不碰）。"
}

function Restore-PowerSupply {
    if (-not $script:PowerRequest) { return "OK: 当前无算力申请" }
    $req = $script:PowerRequest
    try {
        $tp = Get-Process -Id $req.pid -ErrorAction SilentlyContinue
        if ($tp) { $tp.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal }
    } catch {}
    foreach ($kv in $script:PowerDemoted.GetEnumerator()) {
        try {
            $p = Get-Process -Id $kv.Key -ErrorAction SilentlyContinue
            if ($p) { $cls = Get-PriorityClassFromString $kv.Value; if ($cls) { $p.PriorityClass = $cls } }
        } catch {}
    }
    # 先关 EcoQoS 效率模式，再还原优先级——否则闲置进程留在能效核档位上
    $ecoRestored = 0
    $hasEco = [bool](Get-Command Set-EcoQos -ErrorAction SilentlyContinue)
    if ($hasEco -and $script:PowerEcoQos.Count -gt 0) {
        foreach ($ecoPid in $script:PowerEcoQos.Keys) {
            try {
                if (Set-EcoQos -ProcId ([int]$ecoPid) -On $false) { $ecoRestored++ }
            } catch {}
        }
    }
    $n = $script:PowerDemoted.Count
    $script:PowerRequest = $null
    $script:PowerDemoted = @{}
    $script:PowerEcoQos  = @{}
    $script:PowerKilled = @()
    Write-Log "INFO" "算力释放: $($req.name)($($req.pid))，还原 $n 进程，关闭 EcoQoS $ecoRestored 个"
    return "OK: 算力已释放，还原 $n 个进程、关闭 EcoQoS $ecoRestored 个（$($req.name) 已回 Normal）"
}

function Invoke-Native {
    # 修复#3: 统一执行 native 命令并检查 $LASTEXITCODE，失败返回 $false
    param([string]$Exe, [string[]]$Args, [string]$What)
    & $Exe @Args | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "WARN" "native 命令失败 (exit=$LASTEXITCODE): $What"
        return $false
    }
    return $true
}

function Get-PriorityString {
    param($PriorityClass)
    if ($null -eq $PriorityClass) { return "Unknown" }
    return [string]$PriorityClass
}

# ---------- 阶段三：磁盘 I/O 优先级（ProcessIoPriority = 0x21）----------
$script:IoPriorityValue = @{ VeryLow = 0; Low = 1; Normal = 2; High = 3 }

function Get-IoPriority {
    param([int]$ProcessId)
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        $val = 2
        $retLen = 0
        $nt = [PowerFocus.Native]::NtQueryInformationProcess($p.Handle, 0x21, [ref]$val, 4, [ref]$retLen)
        if ($nt -ne 0) { return $null }
        return $val
    } catch { return $null }
}

function Set-IoPriority {
    # 返回 $true=成功，$false=失败（权限不足/进程退出）
    param([int]$ProcessId, [int]$Value)
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        $val = $Value
        $nt = [PowerFocus.Native]::NtSetInformationProcess($p.Handle, 0x21, [ref]$val, 4)
        return ($nt -eq 0)
    } catch { return $false }
}

function ConvertFrom-IoPriorityName {
    param([string]$Name)
    if ($script:IoPriorityValue.ContainsKey($Name)) { return $script:IoPriorityValue[$Name] }
    return $null
}

function ConvertTo-IoPriorityName {
    param([int]$Value)
    foreach ($k in $script:IoPriorityValue.Keys) {
        if ($script:IoPriorityValue[$k] -eq $Value) { return $k }
    }
    return "Unknown($Value)"
}

# ---------- 阶段三：内存修剪（EmptyWorkingSet）----------
function Invoke-MemoryTrim {
    # 把非白名单、非目标进程的工作集换出，释放物理内存给目标
    # 页面换出是异步的：先记录修剪前 WorkingSet，等待换出完成后统一回读差值，避免恒报 0 MB
    param([int]$ExcludePid = 0)
    $trimmed = 0
    $targets = @()
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq $ExcludePid) { continue }
        if ($p.Id -eq $PID) { continue }
        if ($script:Whitelist -contains $p.ProcessName) { continue }
        try {
            $before = $p.WorkingSet64
            if ([PowerFocus.Native]::EmptyWorkingSet($p.Handle)) {
                $trimmed++
                $targets += @{ Pid = $p.Id; Before = $before }
            }
        } catch {}   # 系统进程/受保护进程会失败，静默跳过
    }
    $freedBytes = [long]0
    if ($targets.Count -gt 0) {
        Start-Sleep -Milliseconds 900   # 等待异步页面换出完成
        foreach ($t in $targets) {
            try {
                $q = Get-Process -Id $t.Pid -ErrorAction SilentlyContinue
                if ($q -and $q.WorkingSet64 -lt $t.Before) {
                    $freedBytes += ($t.Before - $q.WorkingSet64)
                }
            } catch {}
        }
    }
    return @{ Trimmed = $trimmed; FreedMB = [math]::Round($freedBytes / 1MB, 1) }
}

# ---------- 进程选择（实时 CPU%） ----------
# ============================================================
# 统一内存模式（整机算力池）—— 2026-11-15 接线
# 来源：仓库根 `统一内存模式.ps1`（854 行，此前为孤儿资产：
#       产品 server.py 零引用、六个内核版本零引用、MCP 工具零引用）
#
# 移植范围：只移植"硬件探测 + 层分配算法"四段纯计算逻辑。
# 明确不移植 `Start-UnifiedMemoryMode`——那是 llama-server 启动器，
# 接进内核会把产品变成 llama.cpp 外壳，与"通用算力池、给任何电脑用"的定位冲突。
#
# 可移植性改造（相对原实现）：
#   原 `MaxGpuLayersSafe = 20` 是 RTX 5060 8GB 的实测硬编码，对大显存机器是错误压制。
#   改为 `MaxGpuLayersSafe = 0` 表示"按显存自动推导"，>0 时才硬钳（小显存机器可显式填 20 保守）。
# ============================================================

function Get-GpuMemoryInfo {
    [CmdletBinding()]
    param()

    $nvidiaSmi = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        Write-Log "WARN" "未找到 nvidia-smi，显卡显存不可探测"
        return @()
    }

    $raw = & $nvidiaSmi.Source --query-gpu=index,memory.total,memory.used,memory.free --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "WARN" "nvidia-smi 查询失败（exit=$LASTEXITCODE）"
        return @()
    }

    $result = @()
    foreach ($line in $raw) {
        $p = $line -split ',' | ForEach-Object { $_.Trim() }
        if ($p.Count -ge 4) {
            $result += @{
                Index   = [int]$p[0]
                TotalMB = [int]$p[1]
                UsedMB  = [int]$p[2]
                FreeMB  = [int]$p[3]
            }
        }
    }
    # -NoEnumerate 原样输出数组，既防止单元素被解包成 hashtable，
    # 又不会在外层多套一层数组（`return ,$result` 会多套一层，
    # 导致多卡机器上 $gpu[0] 拿到的是内层数组而不是第一张卡）。
    Write-Output -NoEnumerate $result
}

function Get-SystemMemoryInfo {
    [CmdletBinding()]
    param()

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) { return @{ TotalMB = 0; AvailableMB = 0; CommittedMB = 0 } }

    # TotalVisibleMemorySize / FreePhysicalMemory 单位均为 KB
    $totalKB = [long]$os.TotalVisibleMemorySize
    $availKB = [long]$os.FreePhysicalMemory
    return @{
        TotalMB     = [math]::Round($totalKB / 1024, 1)
        AvailableMB = [math]::Round($availKB / 1024, 1)
        CommittedMB = [math]::Round(($totalKB - $availKB) / 1024, 1)
    }
}

function Get-GgufLayerCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    # 按值类型跳过 GGUF 元数据值（含数组），保证流位置不偏移
    function Skip-GgufValue {
        param($br, [int]$type)
        switch ($type) {
            0  { $br.ReadByte()   | Out-Null }   # UINT8
            1  { $br.ReadByte()   | Out-Null }   # INT8
            2  { $br.ReadUInt16() | Out-Null }   # UINT16
            3  { $br.ReadInt16()  | Out-Null }   # INT16
            4  { $br.ReadUInt32() | Out-Null }   # UINT32
            5  { $br.ReadInt32()  | Out-Null }   # INT32
            6  { $br.ReadSingle() | Out-Null }   # FLOAT32
            7  { $br.ReadByte()   | Out-Null }   # BOOL
            8  { $sLen = $br.ReadUInt64(); if ($sLen -lt 64MB) { $br.ReadBytes([int]$sLen) | Out-Null } }  # STRING
            9  { $eType = $br.ReadUInt32(); $eCnt = $br.ReadUInt64()
                 for ($k = 0; $k -lt $eCnt; $k++) { Skip-GgufValue $br $eType } }                          # ARRAY
            10 { $br.ReadUInt64() | Out-Null }   # UINT64
            11 { $br.ReadInt64()  | Out-Null }   # INT64
            12 { $br.ReadDouble() | Out-Null }   # FLOAT64
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
                    if ($vtype -eq 4) { $found = [int]$br.ReadUInt32() } else { $found = [int]$br.ReadInt64() }
                    break
                }
                Skip-GgufValue -br $br -type $vtype
            }

            if ($found -le 0 -or $found -ge 512) { return 0 }
            return $found
        } finally { $fs.Dispose() }
    } catch {
        Write-Log "WARN" "解析 GGUF 层数异常：$($_.Exception.Message)"
        return 0
    }
}

function Calculate-OptimalLayerSplit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ModelPath,
        [Parameter(Mandatory = $true)][int]$GpuFreeMB
    )

    $fi = Get-Item -LiteralPath $ModelPath -ErrorAction Stop
    $modelSizeMB = [math]::Round($fi.Length / 1MB, 2)

    $totalLayers = [int](Get-GgufLayerCount -Path $ModelPath)
    if ($totalLayers -le 0) {
        Write-Log "WARN" "无法解析模型总层数，回退为按每 200MB 一层估算"
        $totalLayers = [math]::Max(1, [math]::Floor($modelSizeMB / 200))
    }

    $perLayerMB = [math]::Round($modelSizeMB / $totalLayers, 2)

    # GPU 可用显存 = 空闲显存 − CUDA 上下文（绝对量）− 计算/图缓冲（按比例推导）
    # 说明：memory.free 已扣"当前已占用"，这里只预扣"新进程启动才要新分配"的两项。
    $reserveMB = if ($script:ComputeReserveMB -gt 0) {
        # 显式固定值（调试用，强制忽略比例）
        [double]$script:ComputeReserveMB
    } else {
        # 按比例推导：Pct% 空闲显存，并设 256MB 下限（极小显存机器也要有缓冲）
        [math]::Max(256.0, [math]::Round($GpuFreeMB * $script:ComputeReservePct / 100, 1))
    }
    $gpuUsableMB = $GpuFreeMB - $script:CudaReservedMB - $reserveMB
    if ($gpuUsableMB -lt 0) { $gpuUsableMB = 0 }

    $maxGpuLayers = [math]::Floor($gpuUsableMB / $perLayerMB)
    # 硬钳仅在显式配置 >0 时生效（0 = 按显存自动推导，适配任意大小的机器）
    if ($script:MaxGpuLayersSafe -gt 0 -and $maxGpuLayers -gt $script:MaxGpuLayersSafe) {
        $maxGpuLayers = $script:MaxGpuLayersSafe
    }
    if ($maxGpuLayers -lt 0) { $maxGpuLayers = 0 }
    # 保证 CPU 至少留 1 层
    if ($maxGpuLayers -ge $totalLayers) { $maxGpuLayers = $totalLayers - 1 }

    # ---- 关于"少层 offload 反而更慢"的更正 ----
    # 曾按"少于 20% 就判 0 层"写过一条规则，实测数据证明那是错的，已撤销。
    # 三份独立基准（RTX 5060 Ti 14B/48 层、0.6B/28 层、SmolLM2/32 层）一致显示：
    #   -ngl 8/48（16.7%）→ 3.58 tok/s  vs 全 CPU 2.89 tok/s   = +24%
    #   -ngl 4/28（14.3%）→ 52.5 tok/s  vs 全 CPU 37.3 tok/s   = +41%
    # 结论：只要有一层上 GPU 就比全 CPU 快，能上几层上几层。
    # 真正的瓶颈不是"权重在 CPU"，而是"KV cache 在 CPU"——它每个 token 都要重读。
    # 但 layer 模式下 KV cache 跟着层走，无法独立控制，所以这里的取舍是：
    #   GPU 层能装多少装多少，不去人为压到 0。
    $splitWarn = ''
    if ($maxGpuLayers -eq 0 -and $gpuUsableMB -lt $perLayerMB) {
        $splitWarn = "可用显存 $([math]::Round($gpuUsableMB,1))MB 装不下一层" + `
                     "（每层 $perLayerMB MB），只能全 CPU 推理"
    } elseif ($maxGpuLayers -gt 0 -and $maxGpuLayers -lt 4) {
        $splitWarn = "仅能上 $maxGpuLayers 层（占比 $([math]::Round(($maxGpuLayers/$totalLayers)*100,1))%）；" + `
                     "虽然比全 CPU 快，但 KV cache 大部分仍在 CPU，长上下文会明显掉速"
    }

    $gpuRatio = if ($totalLayers -gt 0) { $maxGpuLayers / $totalLayers } else { 0 }

    return @{
        GpuLayers   = [int]$maxGpuLayers
        CpuLayers   = [int]($totalLayers - $maxGpuLayers)
        TotalLayers = [int]$totalLayers
        PerLayerMB  = $perLayerMB
        ModelSizeMB = $modelSizeMB
        GpuUsableMB = [math]::Round($gpuUsableMB, 1)
        ReserveMB   = [math]::Round($reserveMB, 1)
        CudaMB      = $script:CudaReservedMB
        GpuRatio    = [math]::Round($gpuRatio, 3)
        Warn        = $splitWarn
    }
}

function Get-UnifiedMemoryPlan {
    [CmdletBinding()]
    param([string]$ModelPath = '')

    # 不加 @()：Get-GpuMemoryInfo 已用 -NoEnumerate 保证返回真实数组，
    # 再套一层 @() 会把它当成单个对象，形成 [[...]] 双层结构。
    $gpu = Get-GpuMemoryInfo
    $mem = Get-SystemMemoryInfo

    $plan = [ordered]@{
        collected_at   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        gpu_count      = @($gpu).Count
        gpu            = $gpu
        memory         = $mem
        layer_plan     = $null
        reserving      = @{
            cuda_mb       = $script:CudaReservedMB
            compute_pct   = $script:ComputeReservePct
            compute_fixed = $script:ComputeReserveMB
            hard_cap      = $script:MaxGpuLayersSafe
        }
        note           = ''
    }

    if (@($gpu).Count -eq 0) {
        $plan.note = '未检测到 NVIDIA GPU 或 nvidia-smi 不可用；层分配不可计算'
        return $plan
    }
    if ([string]::IsNullOrWhiteSpace($ModelPath)) {
        $plan.note = '未指定模型路径；仅返回硬件现状'
        return $plan
    }
    if (-not (Test-Path -LiteralPath $ModelPath)) {
        $plan.note = "模型文件不存在: $ModelPath"
        return $plan
    }

    $plan.layer_plan = Calculate-OptimalLayerSplit -ModelPath $ModelPath -GpuFreeMB $gpu[0].FreeMB
    $plan.note = "已按 GPU#$($gpu[0].Index) 空闲 $($gpu[0].FreeMB)MB 计算层分配"
    return $plan
}

function Get-CpuSnapshot {
    $snap = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq 0) { continue }
        try {
            $snap[$p.Id] = @{
                Name = $p.ProcessName
                CpuSec = $p.TotalProcessorTime.TotalSeconds
                MemMB  = [math]::Round($p.WorkingSet64 / 1MB, 1)
            }
        } catch {}
    }
    return @{ Time = (Get-Date); Data = $snap }
}

function Get-ProcList {
    # 修复#4: 两次采样差分得到实时 CPU%（占全部逻辑核心的百分比）
    $s1 = Get-CpuSnapshot
    Start-Sleep -Milliseconds 500
    $s2 = Get-CpuSnapshot
    $dt = ($s2.Time - $s1.Time).TotalSeconds
    if ($dt -le 0) { $dt = 0.5 }
    $cores = [Environment]::ProcessorCount

    $rows = foreach ($id in $s2.Data.Keys) {
        if (-not $s1.Data.ContainsKey($id)) { continue }
        $d2 = $s2.Data[$id]; $d1 = $s1.Data[$id]
        $cpuPct = [math]::Round((($d2.CpuSec - $d1.CpuSec) / $dt / $cores) * 100, 1)
        if ($cpuPct -lt 0) { $cpuPct = 0.0 }
        [PSCustomObject]@{
            Name = $d2.Name; PID = [int]$id
            CpuPct = $cpuPct; Mem = $d2.MemMB
        }
    }
    return @($rows | Sort-Object CpuPct -Descending)
}

function Show-ProcPicker {
    $win = New-Object System.Windows.Window
    $win.Title = "选择目标进程 - 电脑算力调度中心 v0.13"
    $win.Width = 600; $win.Height = 500
    $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $win.ResizeMode = [System.Windows.ResizeMode]::CanResize

    $grid = New-Object System.Windows.Controls.Grid
    $row1 = New-Object System.Windows.Controls.RowDefinition; $row1.Height = [System.Windows.GridLength]::Auto
    $row2 = New-Object System.Windows.Controls.RowDefinition; $row2.Height = [System.Windows.GridLength]::Auto
    $grid.RowDefinitions.Add($row1); $grid.RowDefinitions.Add($row2)

    $lv = New-Object System.Windows.Controls.ListView
    $lv.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $gv = New-Object System.Windows.Controls.GridView
    $gv.AllowsColumnReorder = $true
    foreach ($col in @(@('进程名',180,'Name'), @('PID',70,'PID'), @('CPU %',90,'CpuPct'), @('内存 MB',100,'Mem'))) {
        $gc = New-Object System.Windows.Controls.GridViewColumn
        $gc.Header = $col[0]; $gc.Width = $col[1]
        $gc.DisplayMemberBinding = (New-Object System.Windows.Data.Binding($col[2]))
        $gv.Columns.Add($gc)
    }
    $lv.View = $gv
    [System.Windows.Controls.Grid]::SetRow($lv, 0)

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $txtInput = New-Object System.Windows.Controls.TextBox
    $txtInput.Width = 270; $txtInput.Margin = (New-Object System.Windows.Thickness(5))
    $txtInput.ToolTip = "输入进程名（默认建议: llama-server）"
    $btnRefresh = New-Object System.Windows.Controls.Button
    $btnRefresh.Content = "刷新"; $btnRefresh.Width = 60; $btnRefresh.Margin = (New-Object System.Windows.Thickness(5))
    $btnOk = New-Object System.Windows.Controls.Button
    $btnOk.Content = "确定"; $btnOk.Width = 60; $btnOk.Margin = (New-Object System.Windows.Thickness(5))
    $btnCancel = New-Object System.Windows.Controls.Button
    $btnCancel.Content = "取消"; $btnCancel.Width = 60; $btnCancel.Margin = (New-Object System.Windows.Thickness(5))
    $panel.Children.Add($txtInput) | Out-Null
    $panel.Children.Add($btnRefresh) | Out-Null
    $panel.Children.Add($btnOk) | Out-Null
    $panel.Children.Add($btnCancel) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($panel, 1)
    $grid.Children.Add($lv) | Out-Null
    $grid.Children.Add($panel) | Out-Null
    $win.Content = $grid

    function Refresh-LV {
        $lv.ItemsSource = @(Get-ProcList)
    }
    Refresh-LV

    $script:PickResult = $null
    $btnRefresh.Add_Click({ Refresh-LV })
    $btnOk.Add_Click({
        $sel = $lv.SelectedItem
        if ($sel) {
            $script:PickResult = @{ Name = $sel.Name; PID = [int]$sel.PID }
        } else {
            $nm = $txtInput.Text.Trim()
            if ($nm) {
                $proc = Get-Process -Name $nm -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($proc) { $script:PickResult = @{ Name = $proc.ProcessName; PID = $proc.Id } }
                else { [System.Windows.MessageBox]::Show("未找到进程: $nm", "提示"); return }
            } else {
                [System.Windows.MessageBox]::Show("请选择或输入进程名", "提示"); return
            }
        }
        $win.Close()
    })
    $btnCancel.Add_Click({ $win.Close() })
    $win.Add_KeyDown({ param($s, $e) if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $win.Close() } })

    $win.ShowDialog() | Out-Null
    return $script:PickResult
}

# ---------- 电源计划 ----------
function Set-PowerPlanHigh {
    try {
        $cur = powercfg /getactivescheme 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Log "WARN" "powercfg /getactivescheme 失败 (exit=$LASTEXITCODE)"
            $script:OriginalPlan = $null
        } elseif ($cur -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $script:OriginalPlan = $Matches[1]
            Write-Log "INFO" "原电源计划 GUID: $script:OriginalPlan"
        } else {
            $script:OriginalPlan = $null
            Write-Log "WARN" "未能解析当前电源计划 GUID"
        }
        if (Invoke-Native -Exe "powercfg" -Args @('/setactive', $script:HighPerfGuid) -What "切换高性能电源计划") {
            Write-Log "INFO" "电源计划已切换为高性能"
        } else {
            Write-Log "WARN" "本机可能不存在高性能电源计划（OEM 精简系统），跳过电源优化"
        }
    } catch { Write-Log "WARN" "电源计划切换异常: $_" }
}

function Restore-PowerPlan {
    if ($script:OriginalPlan) {
        Invoke-Native -Exe "powercfg" -Args @('/setactive', $script:OriginalPlan) -What "恢复电源计划" | Out-Null
        Write-Log "INFO" "电源计划已恢复: $script:OriginalPlan"
        $script:OriginalPlan = $null
    }
}

# ---------- 聚焦核心 ----------
# 记录目标原始优先级并设定期望优先级（修复#1/#6 的核心）
function Set-TargetFocus {
    param([int]$ProcessId, [string]$Name, $DesiredPriority)
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Log "ERROR" "目标进程不存在: $Name (PID $ProcessId)"
        return $false
    }
    # 只在第一次聚焦时记录原值，GodMode 升级重入时不覆盖
    if ($null -eq $script:TargetOriginalPriority) {
        $script:TargetOriginalPriority = Get-PriorityString $proc.PriorityClass
        Write-Log "INFO" "记录 $Name 原始优先级: $($script:TargetOriginalPriority)"
    }
    $script:TargetDesiredPriority = $DesiredPriority
    try {
        $proc.PriorityClass = $DesiredPriority
        try { $proc.PriorityBoostEnabled = $true } catch {}
        Write-Log "INFO" "聚焦: $Name (PID $ProcessId) 优先级 -> $DesiredPriority"
        return $true
    } catch {
        # 无权限提升（如目标是管理员进程）——降一档尝试 High
        if ($DesiredPriority -eq [System.Diagnostics.ProcessPriorityClass]::RealTime) {
            try {
                $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
                $script:TargetDesiredPriority = [System.Diagnostics.ProcessPriorityClass]::High
                Write-Log "WARN" "RealTime 设置失败（权限不足），已降为 High: $Name"
                return $true
            } catch {}
        }
        Write-Log "ERROR" "设置优先级失败: $Name ($_)"
        return $false
    }
}

function Start-GentleFocus {
    param([int]$ProcessId, [string]$Name)
    $script:TargetPid = $ProcessId
    $script:TargetName = $Name
    if (Set-TargetFocus -ProcessId $ProcessId -Name $Name -DesiredPriority ([System.Diagnostics.ProcessPriorityClass]::High)) {
        Show-Balloon "电脑算力调度中心" "已对 $Name 执行温和聚焦"
    }
    Set-PowerPlanHigh
}

function Start-AggressiveFocus {
    param([int]$ProcessId, [string]$Name)
    Start-GentleFocus -ProcessId $ProcessId -Name $Name
    try {
        $script:DemotedPids = @{}
        foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
            if ($p.Id -eq $ProcessId) { continue }
            if ($script:Whitelist -contains $p.ProcessName) { continue }
            $orig = Get-PriorityString $p.PriorityClass
            # 修复#2: 原本就低优先级的进程不动，避免"恢复"时反被抬高
            if ($orig -eq 'BelowNormal' -or $orig -eq 'Idle') { continue }
            try {
                $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
                $script:DemotedPids[[int]$p.Id] = $orig
            } catch {}
        }
        Write-Log "INFO" "激进聚焦: 已降级 $($script:DemotedPids.Count) 个进程为 BelowNormal（原值已记录）"
        Show-Balloon "电脑算力调度中心" "激进聚焦已生效，降级 $($script:DemotedPids.Count) 个进程"
    } catch {
        Write-Log "ERROR" "激进聚焦降级失败: $_"
    }
}

# 开后门机制：GodMode = 期望优先级 + PriorityBoost + 高性能电源 + watchdog 守护
function Start-GodModeFocus {
    param([int]$ProcessId, [string]$Name, [string]$Level)
    $script:TargetPid = $ProcessId
    $script:TargetName = $Name
    $desired = [System.Diagnostics.ProcessPriorityClass]::High
    if ($Level -eq 'realtime') {
        $desired = [System.Diagnostics.ProcessPriorityClass]::RealTime
        Write-Log "WARN" "GodMode(realtime): $Name 将获得 RealTime 优先级，系统可能短暂卡顿"
    }
    if (Set-TargetFocus -ProcessId $ProcessId -Name $Name -DesiredPriority $desired) {
        Show-Balloon "电脑算力调度中心" "GodMode($Level) 已对 $Name 生效"
    }
    # 阶段三：GodMode 附加磁盘 I/O 优先级 High（记录原值，解除时还原）
    if ($null -eq $script:TargetOriginalIoPriority) {
        $script:TargetOriginalIoPriority = Get-IoPriority -ProcessId $ProcessId
        if ($null -ne $script:TargetOriginalIoPriority) {
            Write-Log "INFO" "记录 $Name 原始 I/O 优先级: $(ConvertTo-IoPriorityName $script:TargetOriginalIoPriority)"
        }
    }
    if (Set-IoPriority -ProcessId $ProcessId -Value 3) {
        $script:DesiredIoPriority = 3
        Write-Log "INFO" "GodMode: $Name 磁盘 I/O 优先级 -> High"
    } else {
        Write-Log "WARN" "GodMode: $Name I/O 优先级设置失败（权限不足或进程受保护），仅保留 CPU 优先级倾斜"
    }
    Set-PowerPlanHigh
}

function Invoke-WatchdogCheck {
    $tp = $script:TargetPid
    if (-not $tp) { return }
    $proc = Get-Process -Id $tp -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Log "WARN" "目标进程 $script:TargetName (PID $tp) 已退出，自动解除聚焦"
        Show-Balloon "电脑算力调度中心" "目标进程 $script:TargetName 已退出，聚焦已自动解除"
        Stop-Focus
        return
    }
    if ($proc.PriorityClass -ne $script:TargetDesiredPriority) {
        try {
            $proc.PriorityClass = $script:TargetDesiredPriority
            Write-Log "INFO" "监管: $script:TargetName 优先级被外力改动，已拉回 $($script:TargetDesiredPriority)"
        } catch {}
    }
    # 阶段三：GodMode 时同步守护磁盘 I/O 优先级
    if ($null -ne $script:DesiredIoPriority) {
        $curIo = Get-IoPriority -ProcessId $tp
        if ($null -ne $curIo -and $curIo -lt $script:DesiredIoPriority) {
            if (Set-IoPriority -ProcessId $tp -Value $script:DesiredIoPriority) {
                Write-Log "INFO" "监管: $script:TargetName I/O 优先级被外力压低，已拉回 $(ConvertTo-IoPriorityName $script:DesiredIoPriority)"
            }
        }
    }
}

function Start-Watchdog {
    param([int]$ProcessId, [string]$Name)
    $script:TargetPid = $ProcessId
    $script:TargetName = $Name
    Stop-Watchdog
    # WinForms Timer：回调跑在 UI 线程（消息泵），保证脚本块有运行空间
    $script:TimerObj = New-Object System.Windows.Forms.Timer
    $script:TimerObj.Interval = 10000
    $script:TimerObj.add_Tick({ param($s, $e) Invoke-WatchdogCheck })
    $script:TimerObj.Start()
    Write-Log "INFO" "监管已启动: 每 10 秒检查 $Name（守护优先级: $($script:TargetDesiredPriority)）"
}

function Stop-Watchdog {
    if ($script:TimerObj) {
        try { $script:TimerObj.Dispose() } catch {}
        $script:TimerObj = $null
    }
}

function Stop-Focus {
    try {
        Stop-Watchdog
        Restore-PowerPlan
        # 修复#1: 还原目标进程的原始优先级
        if ($script:TargetPid -and $script:TargetOriginalPriority) {
            $tp = Get-Process -Id $script:TargetPid -ErrorAction SilentlyContinue
            if ($tp) {
                $origClass = Get-PriorityClassFromString $script:TargetOriginalPriority
                if ($origClass) {
                    try {
                        $tp.PriorityClass = $origClass
                        Write-Log "INFO" "目标 $script:TargetName 优先级已还原为 $($script:TargetOriginalPriority)"
                    } catch { Write-Log "WARN" "还原目标优先级失败: $_" }
                }
            }
        }
        # 阶段三: 还原目标进程原始 I/O 优先级
        if ($script:TargetPid -and ($null -ne $script:TargetOriginalIoPriority)) {
            if (Set-IoPriority -ProcessId $script:TargetPid -Value $script:TargetOriginalIoPriority) {
                Write-Log "INFO" "目标 I/O 优先级已还原为 $(ConvertTo-IoPriorityName $script:TargetOriginalIoPriority)"
            } else {
                Write-Log "WARN" "还原目标 I/O 优先级失败"
            }
        }
        # 修复#2: 被降级进程写回各自原始优先级
        $n = $script:DemotedPids.Count
        foreach ($dp in $script:DemotedPids.Keys) {
            try {
                $p = Get-Process -Id $dp -ErrorAction Stop
                $p.PriorityClass = Get-PriorityClassFromString $script:DemotedPids[$dp]
            } catch {}
        }
        if ($n -gt 0) { Write-Log "INFO" "已按原值恢复 $n 个进程优先级" }
        $script:DemotedPids = @{}
        $script:TargetPid = $null
        $script:TargetName = ""
        $script:TargetOriginalPriority = $null
        $script:TargetOriginalIoPriority = $null
        $script:DesiredIoPriority = $null
        $script:TargetDesiredPriority = [System.Diagnostics.ProcessPriorityClass]::High
        Show-Balloon "电脑算力调度中心" "聚焦已解除，系统已按原值恢复"
    } catch {
        Write-Log "ERROR" "解除聚焦异常: $_"
        Show-Balloon "电脑算力调度中心" "解除聚焦时出错: $_"
    }
}

# ---------- 授权清单（开后门机制的准入层） ----------
function Initialize-SecurityArtifacts {
    try {
        # 本机密钥：首次运行生成，authorize/revoke 必须携带
        if (-not (Test-Path -LiteralPath $script:TokenFile)) {
            [guid]::NewGuid().ToString("N") | Set-Content -LiteralPath $script:TokenFile -Encoding ascii
            Write-Log "INFO" "已生成本机授权密钥 .auth_token"
        }
        # F14：令牌文件收回继承，只留当前用户可读（其他本机账户不可读）。
        # 如实说明：同一用户下的进程仍可读，这不是沙箱隔离。
        try {
            if ($env:USERNAME) {
                & icacls $script:TokenFile /inheritance:r /grant:r "$env:USERNAME:(R)" | Out-Null
            }
        } catch { Write-Warning "授权密钥 ACL 加固失败（不阻塞启动）: $_" }
        if (-not (Test-Path -LiteralPath $script:AuthFile)) {
            @{ apps = @() } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:AuthFile -Encoding utf8
            Write-Log "INFO" "已创建授权清单 authorized_apps.json"
        }
        foreach ($d in @($script:CmdIn, $script:CmdOut, $script:CmdDone)) {
            if (-not (Test-Path -LiteralPath $d)) {
                New-Item -ItemType Directory -Path $d -Force | Out-Null
            }
        }
        # 阶段三：默认场景文件（不存在时生成，用户可自行编辑扩展）
        if (-not (Test-Path -LiteralPath $script:SceneFile)) {
            $defaultScenes = [ordered]@{
                _说明 = "场景模式预设：apply_scene 动作按 steps 顺序执行。禁止在 steps 中使用 authorize/revoke。"
                scenes = [ordered]@{
                    inference = [ordered]@{
                        desc = "本地推理模式：llama-server GodMode + I/O High + 内存修剪 + 高性能电源"
                        steps = @(
                            @{ action = 'focus'; process_name = 'llama-server'; mode = 'godmode' },
                            @{ action = 'set_io_priority'; process_name = 'llama-server'; priority = 'High' },
                            @{ action = 'trim_memory'; exclude_target = $true },
                            @{ action = 'set_power_plan'; plan = 'high' }
                        )
                    }
                    gaming = [ordered]@{
                        desc = "游戏模式：高性能电源 + 后台内存修剪（游戏进程自行选择后 focus）"
                        steps = @(
                            @{ action = 'set_power_plan'; plan = 'high' },
                            @{ action = 'trim_memory' }
                        )
                    }
                    relax = [ordered]@{
                        desc = "还原模式：解除全部聚焦 + 平衡电源"
                        steps = @(
                            @{ action = 'unfocus' },
                            @{ action = 'set_power_plan'; plan = 'balanced' }
                        )
                    }
                }
            }
            $defaultScenes | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:SceneFile -Encoding utf8
            Write-Log "INFO" "已生成默认场景文件 scenes.json"
        }
    } catch { Write-Log "ERROR" "初始化安全工件失败: $_" }
}

function Get-AuthToken {
    try { return (Get-Content -LiteralPath $script:TokenFile -Raw).Trim() } catch { return "" }
}

function Get-AuthList {
    try {
        $raw = Get-Content -LiteralPath $script:AuthFile -Raw -Encoding utf8
        return ($raw | ConvertFrom-Json)
    } catch {
        return @{ apps = @() }
    }
}

function Save-AuthList {
    param($List)
    $List | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:AuthFile -Encoding utf8
}

function Test-AppAuthorized {
    param([string]$ProcName)
    $list = Get-AuthList
    foreach ($a in @($list.apps)) {
        if ($a.name -eq $ProcName) { return $a }
    }
    return $null
}

function Add-AppAuthorization {
    param([string]$ProcName, [string]$Level)
    $list = Get-AuthList
    $exists = $false
    foreach ($a in @($list.apps)) { if ($a.name -eq $ProcName) { $a.level = $Level; $exists = $true } }
    if (-not $exists) {
        $entry = @{ name = $ProcName; level = $Level; added = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }
        $apps = @($list.apps) + @($entry)
        $list = @{ apps = $apps }
    }
    Save-AuthList $list
    Write-Log "INFO" "授权更新: $ProcName -> $Level"
}

function Remove-AppAuthorization {
    param([string]$ProcName)
    $list = Get-AuthList
    $kept = @($list.apps | Where-Object { $_.name -ne $ProcName })
    Save-AuthList @{ apps = $kept }
    Write-Log "INFO" "授权撤销: $ProcName"
}

# ---------- 命令总线 ----------
function Get-TopCpuRows {
    param([int]$Count = 5)
    try {
        $rows = Get-ProcList
        return @($rows | Select-Object -First $Count)
    } catch { return @() }
}

function New-StatusReport {
    $planRaw = (powercfg /getactivescheme 2>$null | Out-String).Trim()
    $report = [ordered]@{
        time             = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        target_name      = $script:TargetName
        target_pid       = $script:TargetPid
        focus_mode       = $script:FocusMode
        desired_priority = [string]$script:TargetDesiredPriority
        original_priority= $script:TargetOriginalPriority
        desired_io_priority = $(if ($null -ne $script:DesiredIoPriority) { ConvertTo-IoPriorityName $script:DesiredIoPriority } else { $null })
        demoted_count    = $script:DemotedPids.Count
        power_plan       = $planRaw
        auth_list        = @()
        rules_active     = @()
        foreground_pid   = $null
        top_cpu          = @()
    }
    try {
        $list = Get-AuthList
        $report.auth_list = @($list.apps)
    } catch {}
    # 阶段四：规则引擎状态（心跳上报）
    try {
        $rulesStatePath = Join-Path $script:LogDir "rules_state.json"
        if (Test-Path -LiteralPath $rulesStatePath) {
            $rs = Get-Content -Raw -LiteralPath $rulesStatePath -Encoding utf8 | ConvertFrom-Json
            $report.rules_active = @($rs.rules_active)
            $report.foreground_pid = $rs.foreground_pid
        }
    } catch {}
    # 阶段五：算力申请（补给焦点）
    try {
        if ($script:PowerRequest) {
            $pr = $script:PowerRequest
            $remain = [Math]::Max(0, [int](($pr.expiry - (Get-Date)).TotalSeconds))
            $report.power_request = [ordered]@{
                name = $pr.name; pid = $pr.pid; level = $pr.level
                reason = $pr.reason; remaining_sec = $remain; demoted_count = $pr.demoted
                killed_count = [int]$pr.killed
            }
        } else {
            $report.power_request = $null
        }
    } catch {}
    foreach ($r in (Get-TopCpuRows -Count 5)) {
        $report.top_cpu += @{ name = $r.Name; pid = $r.PID; cpu_pct = $r.CpuPct; mem_mb = $r.Mem }
    }
    return $report
}

function Resolve-TargetFromCommand {
    # 优先用 pid，其次用 process_name 第一个匹配
    param($Cmd)
    if ($Cmd.pid) {
        $p = Get-Process -Id ([int]$Cmd.pid) -ErrorAction SilentlyContinue
        if ($p) { return @{ Name = $p.ProcessName; PID = $p.Id } }
        return $null
    }
    if ($Cmd.process_name) {
        $p = Get-Process -Name ([string]$Cmd.process_name) -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p) { return @{ Name = $p.ProcessName; PID = $p.Id } }
    }
    return $null
}

# ---------- 阶段三：场景模式 ----------
$script:SceneAllowedActions = @('focus','unfocus','set_priority','set_power_plan','trim_memory','set_io_priority','set_net_qos','status')

function Invoke-SceneApply {
    # 按 scenes.json 中场景的 steps 顺序执行（直接调内部命令对象，不经文件总线）
    param([string]$SceneName)
    if (-not (Test-Path -LiteralPath $script:SceneFile)) { return "ERROR: scenes.json 不存在" }
    try {
        $cfg = Get-Content -LiteralPath $script:SceneFile -Raw -Encoding utf8 | ConvertFrom-Json
    } catch { return "ERROR: scenes.json 解析失败: $_" }
    $scene = $cfg.scenes.$SceneName
    if (-not $scene) {
        $avail = (@($cfg.scenes.PSObject.Properties.Name) -join ', ')
        return "ERROR: 场景 '$SceneName' 不存在。可用: $avail"
    }
    $results = @()
    $i = 0
    foreach ($step in @($scene.steps)) {
        $i++
        $h = @{}
        foreach ($p in $step.PSObject.Properties) { $h[$p.Name] = $p.Value }
        if ($h.ContainsKey('action') -and $script:SceneAllowedActions -notcontains $h['action']) {
            $results += "步骤$i 拒绝: 场景内禁止使用 action '$($h['action'])'"
            continue
        }
        try {
            $results += Invoke-CommandObject ([pscustomobject]$h)
        } catch {
            $results += "步骤$i 异常: $_"
        }
    }
    Write-Log "INFO" "场景 [$SceneName] 已应用（$i 步）"
    return "场景 [$SceneName] 执行完毕（$($scene.desc)）:`n" + (($results | ForEach-Object { "  · $_" }) -join "`n")
}

# ===== 外挂模块：Geek Uninstaller 桥接（彻底卸载能力，不改动主流程）=====
$script:GeekBridgePath = Join-Path $PSScriptRoot 'lib\geek-bridge.ps1'
if (Test-Path -LiteralPath $script:GeekBridgePath) {
    try {
        . $script:GeekBridgePath
        Write-Log "INFO" "Geek 桥接模块已加载（彻底卸载能力就绪）"
    } catch {
        Write-Log "WARN" "Geek 桥接模块加载失败: $_"
    }
} else {
    Write-Log "WARN" "未找到 Geek 桥接模块: $($script:GeekBridgePath)"
}

# ---------- v3：本地模型路由（tools\model-router.ps1 的薄封装，不复制启动逻辑） ----------
function Invoke-RouterScript {
    param([hashtable]$Params)
    # 内核可位于 versions\<版本>\，tools 属于跨版本共享目录：向上找到真正含 tools\model-router.ps1 的根。
    $pfRoot = $PSScriptRoot
    while ($pfRoot -and -not (Test-Path -LiteralPath (Join-Path $pfRoot 'tools\model-router.ps1'))) {
        $parent = Split-Path $pfRoot -Parent
        if (-not $parent -or $parent -eq $pfRoot) { break }
        $pfRoot = $parent
    }
    $routerScript = Join-Path $pfRoot 'tools\model-router.ps1'
    if (-not (Test-Path -LiteralPath $routerScript)) { return [pscustomobject]@{ ok = $false; text = "ERROR: 缺少 $routerScript" } }
    $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) { $pwshExe = 'pwsh.exe' }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $routerScript)
    foreach ($k in $Params.Keys) { $argList += @("-$k", [string]$Params[$k]) }
    try {
        $out = & $pwshExe @argList 2>&1 | Out-String
        return [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); text = $out.Trim() }
    } catch {
        return [pscustomobject]@{ ok = $false; text = "ERROR: router 脚本执行异常: $_" }
    }
}

function Get-PresetModelPath {
    # 从 models-preset.ini 取某个 section 的 model 路径（section 名即 OpenAI 模型 id）
    param([string]$PresetFile, [string]$SectionName)
    $cur = ''
    foreach ($line in Get-Content -LiteralPath $PresetFile -Encoding utf8) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') { $cur = $Matches[1].Trim(); continue }
        if ($cur -and ($cur -eq $SectionName) -and $t -match '^model\s*=\s*(.+)$') { return $Matches[1].Trim() }
    }
    return $null
}

function Invoke-CommandObject {
    param($Cmd)
    $action = [string]$Cmd.action
    Write-Log "INFO" "命令总线收到 action=$action"

    switch ($action) {
        'status' {
            $rep = New-StatusReport
            $outPath = Join-Path $script:CmdOut "status.json"
            if (-not (Test-Path -LiteralPath $script:CmdOut)) {
                New-Item -ItemType Directory -Path $script:CmdOut -Force | Out-Null
            }
            $rep | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $outPath -Encoding utf8
            return "OK: 状态已写入 $outPath"
        }
        'unified-plan' {
            $plan = Get-UnifiedMemoryPlan -ModelPath ([string]$Cmd.model_path)
            if (-not (Test-Path -LiteralPath $script:CmdOut)) {
                New-Item -ItemType Directory -Path $script:CmdOut -Force | Out-Null
            }
            $outPath = Join-Path $script:CmdOut "unified-plan.json"
            $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outPath -Encoding utf8BOM
            if ($plan.layer_plan) {
                return "OK: GPU层=$($plan.layer_plan.GpuLayers) CPU层=$($plan.layer_plan.CpuLayers) 总层=$($plan.layer_plan.TotalLayers) -> $outPath"
            }
            return "OK: 硬件现状已写入 $outPath（$($plan.note)）"
        }
        'unfocus' {
            Stop-Focus
            return "OK: 聚焦已解除"
        }
        'focus' {
            $t = Resolve-TargetFromCommand $Cmd
            if (-not $t) { return "ERROR: 找不到目标进程（pid/process_name 均未命中）" }
            $auth = Test-AppAuthorized -ProcName $t.Name
            if (-not $auth) {
                Write-Log "WARN" "拒绝聚焦: $($t.Name) 不在授权清单"
                return "ERROR: $($t.Name) 不在授权清单中，请先执行 authorize（需 token）"
            }
            $mode = [string]$Cmd.mode
            if (-not $mode) { $mode = "gentle" }
            if ($mode -eq 'godmode') {
                $level = [string]$auth.level
                if ($level -ne 'realtime') { $level = 'high' }
                Start-GodModeFocus -ProcessId $t.PID -Name $t.Name -Level $level
                Start-Watchdog -ProcessId $t.PID -Name $t.Name
                return "OK: GodMode($level) 已启动于 $($t.Name) (PID $($t.PID))"
            }
            $script:FocusMode = $mode
            if ($mode -eq 'aggressive') {
                Start-AggressiveFocus -ProcessId $t.PID -Name $t.Name
            } else {
                Start-GentleFocus -ProcessId $t.PID -Name $t.Name
            }
            Start-Watchdog -ProcessId $t.PID -Name $t.Name
            return "OK: 聚焦($mode)已启动于 $($t.Name) (PID $($t.PID))"
        }
        'authorize' {
            $token = Get-AuthToken
            if ([string]$Cmd.token -ne $token) {
                Write-Log "WARN" "authorize 拒绝: token 校验失败"
                return "ERROR: token 校验失败，拒绝修改授权清单"
            }
            $pn = [string]$Cmd.process_name
            if (-not $pn) { return "ERROR: 缺少 process_name" }
            $lv = [string]$Cmd.level
            if ($lv -ne 'realtime') { $lv = 'high' }
            Add-AppAuthorization -ProcName $pn -Level $lv
            return "OK: 已授权 $pn (级别 $lv)"
        }
        'revoke' {
            $token = Get-AuthToken
            if ([string]$Cmd.token -ne $token) {
                return "ERROR: token 校验失败，拒绝修改授权清单"
            }
            $pn = [string]$Cmd.process_name
            if (-not $pn) { return "ERROR: 缺少 process_name" }
            Remove-AppAuthorization -ProcName $pn
            return "OK: 已撤销 $pn 的授权"
        }
        'set_priority' {
            $t = Resolve-TargetFromCommand $Cmd
            if (-not $t) { return "ERROR: 找不到目标进程" }
            $cls = Get-PriorityClassFromString ([string]$Cmd.priority)
            if (-not $cls) { return "ERROR: 无效优先级，可用: Idle/BelowNormal/Normal/AboveNormal/High/RealTime" }
            try {
                $p = Get-Process -Id $t.PID -ErrorAction Stop
                $p.PriorityClass = $cls
                Write-Log "INFO" "set_priority: $($t.Name) -> $cls"
                return "OK: $($t.Name) 优先级已设为 $cls"
            } catch { return "ERROR: 设置失败（可能权限不足）: $_" }
        }
        # ---------- v0.06：进程强制控制（破坏性操作，必须带 token） ----------
        'kill_process' {
            $t = Resolve-TargetFromCommand $Cmd
            if (-not $t) { return "ERROR: 找不到目标进程（pid/process_name 均未命中）" }
            if ($t.PID -eq $PID) { return "ERROR: 拒绝终止调度中心自身" }
            if ($t.Name -in $script:UnkillableProcesses) {
                Write-Log "WARN" "kill_process 拒绝: $($t.Name) 属系统关键进程"
                return "ERROR: $($t.Name) 是系统关键进程（杀之会蓝屏/重启），已拒绝"
            }
            if ([string]$Cmd.token -ne (Get-AuthToken)) {
                Write-Log "WARN" "kill_process token 校验失败"
                return "ERROR: token 校验失败，拒绝终止进程"
            }
            try {
                Stop-Process -Id $t.PID -Force -ErrorAction Stop
                Write-Log "INFO" "kill_process: 强制终止 $($t.Name)($($t.PID))"
                return "OK: 已强制终止 $($t.Name) (PID $($t.PID))"
            } catch { return "ERROR: 终止失败（可能受 PPL 保护或权限不足）: $_" }
        }
        'suspend_process' {
            $t = Resolve-TargetFromCommand $Cmd
            if (-not $t) { return "ERROR: 找不到目标进程（pid/process_name 均未命中）" }
            if ($t.PID -eq $PID) { return "ERROR: 拒绝挂起调度中心自身" }
            if ($t.Name -in $script:UnkillableProcesses) {
                return "ERROR: $($t.Name) 是系统关键进程，已拒绝挂起"
            }
            if ([string]$Cmd.token -ne (Get-AuthToken)) { return "ERROR: token 校验失败，拒绝挂起进程" }
            $h = [PowerFocus.Native]::OpenProcess(0x0800, $false, $t.PID)
            if ($h -eq [IntPtr]::Zero) { return "ERROR: 打开进程失败（权限不足或受保护）err=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
            $rc = [PowerFocus.Native]::NtSuspendProcess($h)
            [PowerFocus.Native]::CloseHandle($h) | Out-Null
            if ($rc -ne 0) { return "ERROR: 挂起失败 rc=$rc" }
            Write-Log "INFO" "suspend_process: $($t.Name)($($t.PID)) 已冻结"
            return "OK: $($t.Name) (PID $($t.PID)) 已挂起（进程冻结，不响应任何操作；用 resume_process 恢复）"
        }
        'resume_process' {
            $t = Resolve-TargetFromCommand $Cmd
            if (-not $t) { return "ERROR: 找不到目标进程（pid/process_name 均未命中）" }
            if ([string]$Cmd.token -ne (Get-AuthToken)) { return "ERROR: token 校验失败，拒绝恢复进程" }
            $h = [PowerFocus.Native]::OpenProcess(0x0800, $false, $t.PID)
            if ($h -eq [IntPtr]::Zero) { return "ERROR: 打开进程失败（权限不足或受保护）" }
            $rc = [PowerFocus.Native]::NtResumeProcess($h)
            [PowerFocus.Native]::CloseHandle($h) | Out-Null
            if ($rc -ne 0) { return "ERROR: 恢复失败 rc=$rc" }
            Write-Log "INFO" "resume_process: $($t.Name)($($t.PID)) 已恢复"
            return "OK: $($t.Name) (PID $($t.PID)) 已恢复运行"
        }
        'stress_process' {
            $t = Resolve-TargetFromCommand $Cmd
            if (-not $t) { return "ERROR: 找不到目标进程（pid/process_name 均未命中）" }
            if ($t.PID -eq $PID) { return "ERROR: 拒绝压制调度中心自身" }
            if ($t.Name -in $script:UnkillableProcesses) { return "ERROR: $($t.Name) 是系统关键进程，已拒绝压制" }
            if ([string]$Cmd.token -ne (Get-AuthToken)) { return "ERROR: token 校验失败，拒绝压制进程" }
            $mode = if ([string]$Cmd.mode -eq 'crash') { 'crash' } else { 'freeze' }
            $p = Get-Process -Id $t.PID -ErrorAction SilentlyContinue
            if (-not $p) { return "ERROR: 目标进程已不存在" }
            $ws0 = $p.WorkingSet64
            try { $p.PriorityClass = 'Idle' } catch {}
            $h = [PowerFocus.Native]::OpenProcess(0x0100 -bor 0x0400 -bor 0x0800, $false, $t.PID)
            if ($h -eq [IntPtr]::Zero) { return "ERROR: 打开进程失败（权限不足或受保护）" }
            $trimOk = 0
            for ($i = 0; $i -lt 8; $i++) {
                if ([PowerFocus.Native]::EmptyWorkingSet($h)) { $trimOk++ }
                Start-Sleep -Milliseconds 150
            }
            if ($mode -eq 'crash') {
                [PowerFocus.Native]::NtSuspendProcess($h) | Out-Null
            }
            [PowerFocus.Native]::CloseHandle($h) | Out-Null
            Start-Sleep -Milliseconds 500
            $p2 = Get-Process -Id $t.PID -ErrorAction SilentlyContinue
            if (-not $p2) {
                Write-Log "INFO" "stress_process: $($t.Name)($($t.PID)) 在压制过程中已退出"
                return "OK: $($t.Name) (PID $($t.PID)) 在压制过程中已经崩掉/退出"
            }
            $ws1 = $p2.WorkingSet64
            $resp = $p2.Responding
            Write-Log "INFO" "stress_process[$mode]: $($t.Name)($($t.PID)) WS $([math]::Round($ws0/1MB,1))MB->$([math]::Round($ws1/1MB,1))MB Responding=$resp"
            $tail = if ($mode -eq 'crash') { '进程已被冻结且工作集压到最低（表现为完全无响应/假死）' } else { "工作集 $([math]::Round($ws0/1MB,1))MB -> $([math]::Round($ws1/1MB,1))MB，优先级压到 Idle" }
            return "OK: $($t.Name) (PID $($t.PID)) 已压制（EmptyWorkingSet $trimOk/8 次，Responding=$resp）：$tail"
        }
        # ---------- v0.06：智能内存管理（MemGuard 接入命令总线） ----------
        'mem_guard' {
            $mgScript = Join-Path $PSScriptRoot 'lib\mem-guard.ps1'
            if (-not (Test-Path -LiteralPath $mgScript)) { return "ERROR: 找不到 lib\mem-guard.ps1，版本资产不完整" }
            $mgState = Join-Path $PSScriptRoot 'mem-guard.state.json'
            $op = [string]$Cmd.op
            if (-not $op) { $op = 'status' }
            # 只认本版本目录的守护进程，绝不误杀其他版本
            $mgProcs = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
                         Where-Object { $_.CommandLine -and $_.CommandLine -match 'mem-guard\.ps1' -and $_.CommandLine -match ([regex]::Escape($PSScriptRoot)) })
            switch ($op) {
                'status' {
                    $guard = if ($mgProcs.Count -gt 0) { "守护中（PID $(($mgProcs | ForEach-Object { $_.ProcessId }) -join ',')）" } else { '未运行' }
                    if (-not (Test-Path -LiteralPath $mgState)) { return "OK: MemGuard $guard；尚无状态快照，用 op=once 生成" }
                    try { $s = Get-Content -LiteralPath $mgState -Raw -Encoding utf8 | ConvertFrom-Json } catch { return "ERROR: 状态文件解析失败: $_" }
                    return "OK: MemGuard $guard | 模型=$($s.modelRunning)(PID $(($s.modelPids) -join ',')) 内存=$($s.memPercent)% 可用=$($s.availMB)MB 级别=$($s.level) 已压制=$($s.trimmed) 释放=$($s.freedMB)MB"
                }
                'once' {
                    $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
                    if (-not $pwshExe) { $pwshExe = 'pwsh.exe' }
                    $out = & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $mgScript -Once -Json 2>&1 | Out-String
                    try { $s = $out | ConvertFrom-Json } catch { return "ERROR: mem-guard 输出解析失败: $out" }
                    Write-Log "INFO" "mem_guard once: model=$($s.modelRunning) mem=$($s.memPercent)% trimmed=$($s.trimmed) freed=$($s.freedMB)MB"
                    return "OK: 单轮执行完成 | 模型=$($s.modelRunning) 内存=$($s.memPercent)% 级别=$($s.level) 已压制=$($s.trimmed) 释放=$($s.freedMB)MB 保护=$($s.protectedCount)"
                }
                'start' {
                    if ($mgProcs.Count -gt 0) { return "OK: MemGuard 已在运行（PID $(($mgProcs | ForEach-Object { $_.ProcessId }) -join ',')），不重复启动" }
                    $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
                    if (-not $pwshExe) { $pwshExe = 'pwsh.exe' }
                    $argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$mgScript`" -IntervalMs 1000 -CacheMs 5000"
                    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "`"$pwshExe`" $argLine" }
                    if ($r.ReturnValue -ne 0) { return "ERROR: 启动失败 ReturnValue=$($r.ReturnValue)" }
                    Write-Log "INFO" "mem_guard start: PID=$($r.ProcessId)"
                    return "OK: MemGuard 守护已启动（PID $($r.ProcessId)）"
                }
                'stop' {
                    if ($mgProcs.Count -eq 0) { return "OK: MemGuard 本就未运行" }
                    $ids = @($mgProcs | ForEach-Object { [int]$_.ProcessId })
                    foreach ($id in $ids) { try { Stop-Process -Id $id -Force -ErrorAction Stop } catch {} }
                    Write-Log "INFO" "mem_guard stop: $($ids -join ',')"
                    return "OK: 已停止 MemGuard 守护（PID $($ids -join ',')）"
                }
                default { return "ERROR: op 只支持 status / once / start / stop" }
            }
        }
        'set_power_plan' {
            $plan = [string]$Cmd.plan
            $listHint = ""
            try { $listHint = (powercfg /list 2>$null | Out-String).Trim() } catch {}
            if ($plan -eq 'high') {
                if (Invoke-Native -Exe "powercfg" -Args @('/setactive', $script:HighPerfGuid) -What "切换高性能") { return "OK: 已切到高性能" }
                else { return "ERROR: 切高性能失败（本机可能无此计划）。可用计划:`n$listHint" }
            } elseif ($plan -eq 'balanced') {
                if (Invoke-Native -Exe "powercfg" -Args @('/setactive', '381b4222-f694-41f0-9685-ff5bb260df2e') -What "切换平衡") { return "OK: 已切到平衡" }
                else { return "ERROR: 切平衡失败（本机可能无此计划）。可用计划:`n$listHint" }
            }
            return "ERROR: plan 只支持 high / balanced"
        }
        'trim_memory' {
            $excl = 0
            if ($Cmd.exclude_target -eq $true -and $script:TargetPid) { $excl = [int]$script:TargetPid }
            $r = Invoke-MemoryTrim -ExcludePid $excl
            return "OK: 内存修剪完成——进程 $($r.Trimmed) 个，释放物理内存约 $($r.FreedMB) MB"
        }
        'set_io_priority' {
            $t = Resolve-TargetFromCommand $Cmd
            if (-not $t) { return "ERROR: 找不到目标进程（pid/process_name 均未命中）" }
            $v = ConvertFrom-IoPriorityName ([string]$Cmd.priority)
            if ($null -eq $v) { return "ERROR: I/O 优先级只支持 VeryLow/Low/Normal/High" }
            if (Set-IoPriority -ProcessId $t.PID -Value $v) {
                return "OK: $($t.Name) (PID $($t.PID)) 磁盘 I/O 优先级 -> $([string]$Cmd.priority)"
            }
            return "ERROR: I/O 优先级设置失败（权限不足或进程受保护）"
        }
        'set_net_qos' {
            $pn = [string]$Cmd.process_name
            if (-not $pn) { return "ERROR: 缺少 process_name" }
            if (-not (Get-Command New-NetQosPolicy -ErrorAction SilentlyContinue)) {
                return "ERROR: 本机无 NetQoS 模块，无法设置网络限速"
            }
            $rate = 0.0
            if (-not [double]::TryParse([string]$Cmd.rate_mbps, [ref]$rate)) {
                return "ERROR: 缺少或非法 rate_mbps（0 或缺省表示撤销限速）"
            }
            try {
                if ($rate -le 0) {
                    Remove-NetQosPolicy -Name "PowerFocus_$pn" -Confirm:$false -ErrorAction Stop
                    return "OK: 已撤销 $pn 的网络限速策略"
                }
                New-NetQosPolicy -Name "PowerFocus_$pn" -AppPathName "$pn.exe" -ThrottleRateMbitsPerSecond $rate -ErrorAction Stop | Out-Null
                return "OK: $pn 网络限速 $rate Mbps（策略 PowerFocus_$pn，撤销时 rate_mbps=0）"
            } catch {
                return "ERROR: 网络 QoS 设置失败（通常需要管理员权限运行调度中心）: $_"
            }
        }
        'apply_scene' {
            $sn = [string]$Cmd.scene
            if (-not $sn) { return "ERROR: 缺少 scene 名称（可用 list_scenes 查询）" }
            return Invoke-SceneApply -SceneName $sn
        }
        'list_scenes' {
            if (-not (Test-Path -LiteralPath $script:SceneFile)) { return "ERROR: scenes.json 不存在" }
            try {
                $cfg = Get-Content -LiteralPath $script:SceneFile -Raw -Encoding utf8 | ConvertFrom-Json
            } catch { return "ERROR: scenes.json 解析失败: $_" }
            $lines = foreach ($p in $cfg.scenes.PSObject.Properties) { "$($p.Name) —— $($p.Value.desc)" }
            return "可用场景:`n" + (($lines | ForEach-Object { "  · $_" }) -join "`n")
        }
        # ---------- v3：模型加速 profile（只读；boost_model 入口下一步实现） ----------
        'list_model_profiles' {
            if (-not (Test-Path -LiteralPath $script:ModelProfileFile)) {
                return "ERROR: model-profiles.json 不存在: $($script:ModelProfileFile)"
            }
            try {
                $cfg = Get-Content -LiteralPath $script:ModelProfileFile -Raw -Encoding utf8 | ConvertFrom-Json
            } catch { return "ERROR: model-profiles.json 解析失败: $_" }

            if (-not $cfg.models) {
                # 兼容 v1 单模型结构
                $lines = foreach ($p in $cfg.profiles.PSObject.Properties) {
                    $a = $p.Value.args
                    $m = $p.Value.measured
                    "  · $($p.Name) [$($p.Value.label)] ngl=$($a.ngl) fa=$($a.fa) ctx=$($a.ctx) tps=$($m.tps) 显存余=$($m.gpu_free_mb)MB"
                }
                return "可用模型 profile（v1 单模型档案）:`n" + ($lines -join "`n")
            }

            $out = @("模型注册表 v2（$(@($cfg.models.PSObject.Properties).Count) 个模型）:")
            foreach ($m in $cfg.models.PSObject.Properties) {
                $id = $m.Value.identity
                $out += "[$($m.Name)] arch=$($id.architecture) layers=$($id.layers) type=$($id.file_type) size=$($id.size_gb)GB 实测=$($m.Value.measured_at)"
                foreach ($p in $m.Value.profiles.PSObject.Properties) {
                    $a = $p.Value.args
                    $ms = $p.Value.measured
                    $out += "  · $($p.Name) [$($p.Value.label)] ngl=$($a.ngl) fa=$($a.fa) ctx=$($a.ctx) tps=$($ms.tps) 显存余=$($ms.gpu_free_mb)MB"
                }
            }
            return ($out -join "`n")
        }
        # 只读：识别当前 llama-server 实例的模型身份并解析档案（不重启、不改参数）
        'model_identity' {
            $proc = Get-LlamaServerProcess -ErrorAction SilentlyContinue
            if (-not $proc) { return "未找到 llama-server 进程（端口 $($script:LlamaPort)）" }
            $cmd = ""
            try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction SilentlyContinue).CommandLine } catch {}
            $modelPath = $null
            foreach ($pat in @('--model[=\s]+"?([^"\s]+\.gguf)"?', '-m[=\s]+"?([^"\s]+\.gguf)"?')) {
                $mm = [regex]::Match([string]$cmd, $pat)
                if ($mm.Success) { $modelPath = $mm.Groups[1].Value; break }
            }
            if (-not $modelPath) { return "PID $($proc.Id) 命令行中未找到模型路径（--model / -m）" }
            $id = Get-ModelIdentity -ModelPath $modelPath
            if (-not $id) { return "模型识别失败（GGUF 头不可读）: $modelPath" }
            $res = Resolve-ModelProfile -ProfilesPath $script:ModelProfileFile -ModelPath $modelPath
            $ftText = if ($id.file_type -and $id.file_type -ne 'UNKNOWN') { $id.file_type } else { 'n/a（未读取，不参与匹配）' }
            $s = "模型: $modelPath`narch=$($id.architecture) layers=$($id.layers) type=$ftText size=$($id.size_gb)GB"
            if ($res) {
                $s += "`n命中档案: $($res.key)（可选档位 $(@($res.entry.profiles.PSObject.Properties).Count) 个）"
            } else {
                $s += "`n未命中档案：按规则禁止套用任何 profile"
            }
            return $s
        }
        # ---------- v3：模型路由启停 / 按注册表档位加速 ----------
        'start_router' {
            $p = @{ Action = 'start' }
            if ($Cmd.model) { $p['Model'] = [string]$Cmd.model }
            if ($Cmd.port) { $p['Port'] = [int]$Cmd.port }
            $p['TimeoutSec'] = if ($Cmd.timeout_sec) { [int]$Cmd.timeout_sec } else { 60 }
            return (Invoke-RouterScript -Params $p).text
        }
        'stop_router' {
            return (Invoke-RouterScript -Params @{ Action = 'stop' }).text
        }
        'router_status' {
            $p = @{ Action = 'status' }
            if ($Cmd.port) { $p['Port'] = [int]$Cmd.port }
            return (Invoke-RouterScript -Params $p).text
        }
        'boost_model' {
            # 硬约束：模型必须命中 model-profiles.json 的 identity，否则拒绝套用任何参数。
            # 默认 dry-run；apply=true 才真正重启服务，失败按 rollback.json 的命令行还原。
            $modelArg = [string]$Cmd.model
            if (-not $modelArg) { return "ERROR: 缺少 model（gguf 路径或 models-preset.ini 中的模型名）" }

            $presetFile = Join-Path $script:LogDir 'models-preset.ini'
            $modelPath = $modelArg
            if ($modelArg -notmatch '\.gguf$') {
                if (-not (Test-Path -LiteralPath $presetFile)) { return "ERROR: models-preset.ini 不存在" }
                $modelPath = Get-PresetModelPath -PresetFile $presetFile -SectionName $modelArg
                if (-not $modelPath) {
                    $names = @(Get-Content -LiteralPath $presetFile -Encoding utf8 |
                               Where-Object { $_ -match '^\[' } |
                               ForEach-Object { $_.Trim().Trim('[', ']') })
                    return "ERROR: preset 中不存在模型 '$modelArg'。可用: $($names -join ', ')"
                }
            }
            if (-not (Test-Path -LiteralPath $modelPath)) { return "ERROR: 模型文件不存在: $modelPath" }

            $res = Resolve-ModelProfile -ProfilesPath $script:ModelProfileFile -ModelPath $modelPath
            if (-not $res) { return "ERROR: 模型未命中档案（identity 不匹配），按硬约束禁止套用任何档位: $modelPath" }

            $profileName = [string]$Cmd.profile
            $profObj = $null
            if ($profileName) {
                $names = @($res.entry.profiles.PSObject.Properties.Name)
                if ($names -notcontains $profileName) { return "ERROR: 档位 '$profileName' 不存在。可用: $($names -join ', ')" }
                $profObj = $res.entry.profiles.$profileName
            } else {
                $freeMb = 0
                try {
                    $sm = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null | Select-Object -First 1
                    if ("$sm" -match '(\d+)') { $freeMb = [int]$Matches[1] }
                } catch {}
                $ctx = 8192
                if ($Cmd.ctx) { $ctx = [int]$Cmd.ctx }
                $sel = Select-ModelProfile -ModelEntry $res.entry -GpuFreeMb $freeMb -Ctx $ctx
                if (-not $sel) { return "ERROR: 没有匹配当前显存/上下文的档位（gpu_free=${freeMb}MB ctx=$ctx）" }
                $profileName = $sel.name
                $profObj = $sel.profile
            }

            $a = $profObj.args
            $aliasName = if ($res.entry.common.alias) { [string]$res.entry.common.alias } else { [string]$res.key }
            $ctxUsed = if ($Cmd.ctx) { [int]$Cmd.ctx } else { [int]$a.ctx }
            $nglUsed = if ($Cmd.ngl) { [int]$Cmd.ngl } else { [int]$a.ngl }
            $plan = @(
                "模型: $modelPath",
                "档案: $($res.key) / 档位: $profileName [$($profObj.label)]",
                "参数: ngl=$nglUsed fa=$($a.fa) ctx=$ctxUsed kv=$($a.cache_type_k)/$($a.cache_type_v) threads=$($a.threads)",
                "实测: tps=$($profObj.measured.tps) 显存余=$($profObj.measured.gpu_free_mb)MB"
            )

            if ($Cmd.apply -ne $true) {
                return "DRY-RUN（未改动任何进程；加 apply=true 才执行）`n" + ($plan -join "`n")
            }

            $rb = Save-ModelRollback -Reason "boost_model:$($res.key)/$profileName"
            $p = @{
                Action = 'boost'; ModelFile = $modelPath; Port = $script:LlamaPort; TimeoutSec = 90
                Ngl = $nglUsed; Ctx = $ctxUsed; Alias = $aliasName
            }
            if ($a.fa) { $p['FlashAttn'] = [string]$a.fa }
            if ($a.cache_type_k) { $p['CacheTypeK'] = [string]$a.cache_type_k }
            if ($a.cache_type_v) { $p['CacheTypeV'] = [string]$a.cache_type_v }
            if ($a.threads) { $p['Threads'] = [int]$a.threads }
            if ($a.threads_batch) { $p['ThreadsBatch'] = [int]$a.threads_batch }

            $r = Invoke-RouterScript -Params $p
            if ($r.ok) { return "OK: boost 完成`n" + ($plan -join "`n") + "`n" + $r.text }

            if ($rb -and $rb.commandline) {
                $rr = Invoke-RouterScript -Params @{ Action = 'restore'; CommandLine = [string]$rb.commandline; TimeoutSec = 90 }
                return "ERROR: boost 失败，已按回滚记录尝试重启原服务`nboost 输出: $($r.text)`n回滚输出: $($rr.text)"
            }
            return "ERROR: boost 失败（原无端口 $($script:LlamaPort) 服务可回滚）`n$($r.text)"
        }
        # ---------- 阶段四：规则引擎 / EcoQoS / 亲和性 ----------
        'start_rules' {
            if (-not (Get-Command Start-RulesEngine -ErrorAction SilentlyContinue)) {
                return "ERROR: 规则引擎未加载（rules-engine.ps1 缺失或加载失败）"
            }
            Start-RulesEngine
            return "OK: 规则引擎已启动（rules.json 条件自动化 + 心跳上报）"
        }
        'stop_rules' {
            if (-not (Get-Command Stop-RulesEngine -ErrorAction SilentlyContinue)) {
                return "ERROR: 规则引擎未加载（rules-engine.ps1 缺失或加载失败）"
            }
            Stop-RulesEngine
            return "OK: 规则引擎已停止，规则状态已还原"
        }
        'list_rules' {
            $rf = Join-Path $script:LogDir "rules.json"
            if (-not (Test-Path -LiteralPath $rf)) { return "ERROR: rules.json 不存在（阶段四规则文件）" }
            try {
                $cfg = Get-Content -LiteralPath $rf -Raw -Encoding utf8 | ConvertFrom-Json
            } catch { return "ERROR: rules.json 解析失败: $_" }
            $lines = foreach ($r in $cfg.rules) { "$($r.name) [$(if($r.enabled){'启用'}else{'停用'})] —— $($r.desc)" }
            return "规则清单:`n" + (($lines | ForEach-Object { "  · $_" }) -join "`n")
        }
        'apply_rules' {
            $rf = Join-Path $script:LogDir "rules.json"
            if (-not (Test-Path -LiteralPath $rf)) { return "ERROR: rules.json 不存在" }
            if (-not (Get-Command Read-RuleFile -ErrorAction SilentlyContinue)) {
                return "ERROR: 规则引擎未加载（rules-engine.ps1 缺失或加载失败）"
            }
            $script:RulesLoadedAt = $null   # 强制重读
            $n = @(Read-RuleFile).Count
            return "OK: 规则已重载 $n 条"
        }
        'set_ecoqos' {
            $t = Resolve-TargetFromCommand $Cmd
            if (-not $t) { return "ERROR: 找不到目标进程（pid/process_name 均未命中）" }
            if (-not (Get-Command Set-EcoQos -ErrorAction SilentlyContinue)) {
                return "ERROR: 规则引擎未加载（rules-engine.ps1 缺失或加载失败）"
            }
            $on = $true
            if ([string]$Cmd.on -eq 'false' -or [string]$Cmd.on -eq 'off') { $on = $false }
            if (Set-EcoQos -ProcId $t.PID -On $on) {
                return "OK: $($t.Name) (PID $($t.PID)) EcoQoS 效率模式 $(if($on){'开启'}else{'关闭'})"
            }
            return "ERROR: EcoQoS 设置失败（权限不足或进程受保护）"
        }
        'set_affinity' {
            $t = Resolve-TargetFromCommand $Cmd
            if (-not $t) { return "ERROR: 找不到目标进程（pid/process_name 均未命中）" }
            if (-not (Get-Command Set-ProcessAffinity -ErrorAction SilentlyContinue)) {
                return "ERROR: 规则引擎未加载（rules-engine.ps1 缺失或加载失败）"
            }
            $cores = [string]$Cmd.cores
            if (-not $cores) { return "ERROR: 缺少 cores（如 0,2-3 或 all）" }
            if ($cores -eq 'all') {
                $total = [Environment]::ProcessorCount
                $cores = "0-$($total-1)"
            }
            if (Set-ProcessAffinity -ProcId $t.PID -Cores $cores) {
                return "OK: $($t.Name) (PID $($t.PID)) 已绑定核心 $cores"
            }
            return "ERROR: 亲和性设置失败（权限不足或进程受保护）"
        }
        # ---------- 阶段五：算力申请-补给（应用主动借算力） ----------
        'request_power' {
            $t = Resolve-TargetFromCommand $Cmd
            if (-not $t) { return "ERROR: 找不到申请目标（pid/process_name 均未命中）" }
            $level = if ([string]$Cmd.level) { [string]$Cmd.level } else { 'gentle' }
            if ($level -notin @('gentle','aggressive','godmode')) { return "ERROR: level 仅支持 gentle/aggressive/godmode" }
            $dur = if ([int]$Cmd.duration -gt 0) { [int]$Cmd.duration } else { 300 }
            $reason = [string]$Cmd.reason
            return Invoke-PowerSupply -TargetPid $t.PID -Level $level -DurationSec $dur -Reason $reason
        }
        'release_power' {
            return Restore-PowerSupply
        }
        'list_requests' {
            if (-not $script:PowerRequest) { return "当前无算力申请" }
            $r = $script:PowerRequest
            $remain = [Math]::Max(0, [int](($r.expiry - (Get-Date)).TotalSeconds))
            return "当前算力申请: $($r.name) (PID $($r.pid)) level=$($r.level) reason=$($r.reason) 剩余 $remain 秒，已压 $($r.demoted) 进程，清理 $($r.killed) 个无用进程"
        }
        # ---------- 阶段五增强：价值判断（只读列出"明显无用"候选，供审计） ----------
        'list_junk' {
            # 与补给清场同一套判定，只列不杀——透明展示"哪些是明显无用的"
            try {
                $ctx = Get-ProcessContext
                $cands = @()
                foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
                    if ($p.Id -eq $PID) { continue }
                    $rank = Get-ProcessValueRank -Process $p -FgPid $ctx.FgPid -DsTree $ctx.DsTree -AuthNames $ctx.AuthNames -NeverPress $ctx.NeverPress -SysNames $ctx.SysNames -SvcPids $ctx.SvcPids -BusySet $ctx.BusySet -TcpSet $ctx.TcpSet -PpidMap $ctx.PpidMap -WinIds $ctx.WinIds
                    if ($rank -eq 'junk') { $cands += "$($p.ProcessName)(PID $($p.Id)) 内存$([math]::Round($p.WorkingSet64/1MB))MB" }
                }
                if ($cands.Count -eq 0) { return "当前无「明显无用」进程候选（判定：无窗口+CPU空闲+无网络连接+无有窗口祖先+非系统关键+非点名保留）" }
                return ("候选可清理「明显无用」进程（共 $($cands.Count) 个，判定同补给清场，只读不杀）:`n" + ($cands -join "`n"))
            } catch { return "ERROR: list_junk 执行异常: $_" }
        }
        # ---------- 彻底卸载：Geek Uninstaller 桥接 ----------
        'list_apps' {
            try {
                if (-not (Get-Command Get-GeekAppList -ErrorAction SilentlyContinue)) {
                    return "ERROR: Geek 桥接模块未加载，请检查 $script:GeekBridgePath"
                }
                $filter = [string]$Cmd.filter
                $apps = Get-GeekAppList -Filter $filter
                if (-not $apps) { return "ERROR: 无匹配应用（filter=$filter）" }
                $sorted = $apps | Sort-Object Name
                $lines = $sorted | Select-Object -First 80 | ForEach-Object {
                    "  " + $_.Id + "  |  " + $_.Name + "  |  " + $_.Version
                }
                $more = ""
                if ($sorted.Count -gt 80) { $more = "`n  ...（共 $($sorted.Count) 个，仅显示前 80）" }
                return ("已登记应用（共 $($sorted.Count) 个。ID 即 Uninstall 子键名，用于 uninstall_app）:`n" + ($lines -join "`n") + $more)
            } catch { return "ERROR: list_apps 异常: $_" }
        }
        'uninstall_app' {
            if (-not (Get-Command Invoke-GeekUninstall -ErrorAction SilentlyContinue)) {
                return "ERROR: Geek 桥接模块未加载"
            }
            return Invoke-GeekUninstall -Cmd $Cmd -Logger { param($m) Write-Log "INFO" $m }
        }
        default {
            return "ERROR: 未知 action: $action"
        }
    }
}

function Invoke-CommandBusTick {
    if (-not $script:CmdBusEnabled) { return }
    if ($script:BusyProcessing) { return }
    $script:BusyProcessing = $true
    $script:TickCount++
    if (($script:TickCount % 5) -eq 0) { Write-Heartbeat }
    try {
        # 自保：调度中心自身优先级不得低于 Normal（每 tick 检查，防被外部压低）
        try {
            $selff = Get-Process -Id $PID -ErrorAction SilentlyContinue
            if ($selff -and (Get-PriorityRank $selff.PriorityClass) -lt (Get-PriorityRank ([System.Diagnostics.ProcessPriorityClass]::Normal))) {
                $selff.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
                Write-Log "WARN" "自保: 自身优先级被压至 $($selff.PriorityClass)，已回正 Normal"
            }
        } catch { Write-Log "WARN" "自保检查异常: $_" }
        # 阶段四：规则引擎评估（单线程，随命令总线 tick，绝无重入）
        if ($script:RulesRunning) {
            try { if (Get-Command Invoke-RulesEngineOnce -ErrorAction SilentlyContinue) { Invoke-RulesEngineOnce } } catch {}
        }
        # 阶段五：算力申请超时/进程退出自动释放
        if ($script:PowerRequest) {
            try {
                if ((Get-Date) -gt $script:PowerRequest.expiry) {
                    Restore-PowerSupply | Out-Null
                    Write-Log "INFO" "算力申请超时，自动释放"
                } elseif (-not (Get-Process -Id $script:PowerRequest.pid -ErrorAction SilentlyContinue)) {
                    Restore-PowerSupply | Out-Null
                    Write-Log "INFO" "算力申请进程已退出，自动释放"
                }
            } catch { Write-Log "WARN" "申请释放检查异常: $_" }
        }
        $files = @(Get-ChildItem -LiteralPath $script:CmdIn -Filter *.json -File -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime)
        foreach ($f in $files) {
            $resultText = ""
            try {
                $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding utf8
                $cmdObj = $raw | ConvertFrom-Json
                # F4：命令总线全局鉴权。任何能写 commands/in 的本地进程
                # 都必须持有本机 .auth_token；内核内部直接调用
                # Invoke-CommandObject 不经过这里，行为不变。
                $expected = Get-AuthToken
                if (-not $expected -or [string]$cmdObj.token -ne $expected) {
                    $resultText = "ERROR: 命令总线认证失败：缺少或错误的内核授权令牌"
                } else {
                    $resultText = Invoke-CommandObject $cmdObj
                }
            } catch {
                $resultText = "ERROR: 命令解析/执行异常: $_"
                Write-Log "ERROR" "命令文件 $($f.Name) 执行异常: $_"
            }
            # 写结果 + 移入 done
            # 回执只写结果正文：首行时间戳会让服务端 json.loads 恒失败。
            # 先写 .tmp 再原子替换，避免服务端读到半截空文件把 ERROR 误判为成功。
            try {
                $resultPath = Join-Path $script:CmdDone ($f.Name + ".result.txt")
                $tmpPath = $resultPath + ".tmp"
                $resultText | Set-Content -LiteralPath $tmpPath -Encoding utf8
                Move-Item -LiteralPath $tmpPath -Destination $resultPath -Force
                Move-Item -LiteralPath $f.FullName -Destination (Join-Path $script:CmdDone $f.Name) -Force
            } catch { Write-Log "ERROR" "结果落盘失败: $_" }
            Write-Log "INFO" "命令 $($f.Name) 完成: $resultText"
        }
    } finally {
        $script:BusyProcessing = $false
    }
}

# ---------- v0.07：MemGuard 守护自动拉起 ----------
function Get-MemGuardProcess {
    # 只认本版本目录的守护进程，绝不误认其他版本
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -match 'mem-guard\.ps1' -and $_.CommandLine -match ([regex]::Escape($PSScriptRoot)) })
}

function Start-MemGuardGuard {
    $mgScript = Join-Path $PSScriptRoot 'lib\mem-guard.ps1'
    if (-not (Test-Path -LiteralPath $mgScript)) {
        Write-Log "WARN" "MemGuard 模块缺失，跳过自动守护"
        return $null
    }
    $running = @(Get-MemGuardProcess)
    if ($running.Count -gt 0) {
        Write-Log "INFO" "MemGuard 守护已存在 (PID $($running[0].ProcessId))，不重复拉起"
        return $running[0].ProcessId
    }
    $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) { $pwshExe = 'pwsh.exe' }
    $argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$mgScript`" -IntervalMs 1000 -CacheMs 5000"
    try {
        $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "`"$pwshExe`" $argLine" }
        if ($r.ReturnValue -ne 0) {
            Write-Log "ERROR" "MemGuard 自动拉起失败 ReturnValue=$($r.ReturnValue)"
            return $null
        }
        Write-Log "INFO" "MemGuard 守护已自动拉起 (PID $($r.ProcessId))"
        return $r.ProcessId
    } catch {
        Write-Log "ERROR" "MemGuard 自动拉起异常: $_"
        return $null
    }
}

function Start-CommandBus {
    Stop-CommandBus
    $script:CmdTimerObj = New-Object System.Windows.Forms.Timer
    $script:CmdTimerObj.Interval = 2000
    $script:CmdTimerObj.add_Tick({ param($s, $e) Invoke-CommandBusTick })
    $script:CmdTimerObj.Start()
    Write-Log "INFO" "命令总线已启动: 每 2 秒轮询 $script:CmdIn"
}

function Stop-CommandBus {
    if ($script:CmdTimerObj) {
        try { $script:CmdTimerObj.Dispose() } catch {}
        $script:CmdTimerObj = $null
    }
}

# ---------- 自启 / 日志 / 菜单 ----------
function Toggle-Autostart {
    try {
        $task = Get-ScheduledTask -TaskName "PowerFocusAutoV2" -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName "PowerFocusAutoV2" -Confirm:$false
            Write-Log "INFO" "开机自启已关闭"
            Show-Balloon "电脑算力调度中心" "开机自启已关闭"
        } else {
            $scriptPath = $PSCommandPath
            if (-not $scriptPath) { $scriptPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "电脑算力调度中心_v2.ps1" }
            $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
            if (-not $pwshExe) { $pwshExe = "pwsh.exe" }
            $tr = "`"$pwshExe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
            # 修复#7: 英文任务名，规避 schtasks 中文编码坑
            schtasks /Create /TN "PowerFocusAutoV2" /TR $tr /SC ONLOGON /RL HIGHEST /F | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Log "ERROR" "schtasks 创建自启任务失败 (exit=$LASTEXITCODE)"
                Show-Balloon "电脑算力调度中心" "自启创建失败，详见日志"
                return
            }
            Write-Log "INFO" "开机自启已开启: $scriptPath"
            Show-Balloon "电脑算力调度中心" "开机自启已开启"
        }
    } catch {
        Write-Log "ERROR" "自启切换失败: $_"
        Show-Balloon "电脑算力调度中心" "自启切换失败: $_"
    }
}

function Open-Log {
    try {
        if (Test-Path -LiteralPath $script:LogFile) { Start-Process notepad.exe -ArgumentList "`"$script:LogFile`"" }
        else { Show-Balloon "电脑算力调度中心" "日志文件尚不存在" }
    } catch { Show-Balloon "电脑算力调度中心" "打开日志失败: $_" }
}

function Open-AuthFile {
    try {
        if (Test-Path -LiteralPath $script:AuthFile) { Start-Process notepad.exe -ArgumentList "`"$script:AuthFile`"" }
        else { Show-Balloon "电脑算力调度中心" "授权清单尚不存在" }
    } catch { Show-Balloon "电脑算力调度中心" "打开授权清单失败: $_" }
}

function Update-AutoMenuText {
    try {
        $task = Get-ScheduledTask -TaskName "PowerFocusAutoV2" -ErrorAction SilentlyContinue
        if ($task) { $script:MiAuto.Text = "开机自启: 开" } else { $script:MiAuto.Text = "开机自启: 关" }
    } catch { $script:MiAuto.Text = "开机自启: 关" }
}

# ===== 主入口（被 dot-source 时只加载函数，不启动托盘）=====
if ($MyInvocation.InvocationName -eq '.') { return }

Write-Lifecycle "SCRIPT_START" "path=$PSCommandPath"
Initialize-SecurityArtifacts

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Shield
$tray.Text = "电脑算力调度中心 v0.13"
$tray.Visible = $true
$script:TrayIcon = $tray

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miSelect = New-Object System.Windows.Forms.ToolStripMenuItem
$miSelect.Text = "选择目标进程"
$miSelect.Add_Click({
    try {
        $result = Show-ProcPicker
        if ($result) {
            $script:TargetPid = $result.PID
            $script:TargetName = $result.Name
            Write-Log "INFO" "已选定目标进程: $($result.Name) (PID $($result.PID))"
            Show-Balloon "电脑算力调度中心" "目标: $($result.Name)"
        }
    } catch { Write-Log "ERROR" "选择进程失败: $_"; Show-Balloon "电脑算力调度中心" "操作失败: $_" }
})

$miStart = New-Object System.Windows.Forms.ToolStripMenuItem
$miStart.Text = "开始聚焦"
$miStart.Add_Click({
    try {
        if (-not $script:TargetPid) { Show-Balloon "电脑算力调度中心" "请先选择目标进程"; return }
        $proc = Get-Process -Id $script:TargetPid -ErrorAction SilentlyContinue
        if (-not $proc) { Show-Balloon "电脑算力调度中心" "目标进程不存在，请重新选择"; return }
        if ($script:FocusMode -eq "gentle") {
            Start-GentleFocus -ProcessId $script:TargetPid -Name $script:TargetName
        } else {
            Start-AggressiveFocus -ProcessId $script:TargetPid -Name $script:TargetName
        }
        Start-Watchdog -ProcessId $script:TargetPid -Name $script:TargetName
        Write-Log "INFO" "聚焦已启动 (模式: $script:FocusMode)"
    } catch { Write-Log "ERROR" "启动聚焦失败: $_"; Show-Balloon "电脑算力调度中心" "启动聚焦失败: $_" }
})

$miGod = New-Object System.Windows.Forms.ToolStripMenuItem
$miGod.Text = "GodMode 开后门（需在授权清单）"
$miGod.Add_Click({
    try {
        if (-not $script:TargetPid) { Show-Balloon "电脑算力调度中心" "请先选择目标进程"; return }
        $proc = Get-Process -Id $script:TargetPid -ErrorAction SilentlyContinue
        if (-not $proc) { Show-Balloon "电脑算力调度中心" "目标进程不存在，请重新选择"; return }
        $auth = Test-AppAuthorized -ProcName $proc.ProcessName
        if (-not $auth) {
            Show-Balloon "电脑算力调度中心" "$($proc.ProcessName) 不在授权清单，请先编辑 authorized_apps.json 或发 authorize 命令"
            return
        }
        $level = [string]$auth.level
        if ($level -ne 'realtime') { $level = 'high' }
        Start-GodModeFocus -ProcessId $script:TargetPid -Name $script:TargetName -Level $level
        Start-Watchdog -ProcessId $script:TargetPid -Name $script:TargetName
    } catch { Write-Log "ERROR" "GodMode 启动失败: $_"; Show-Balloon "电脑算力调度中心" "GodMode 失败: $_" }
})

$miStop = New-Object System.Windows.Forms.ToolStripMenuItem
$miStop.Text = "解除聚焦"
$miStop.Add_Click({ Stop-Focus })

$miToggle = New-Object System.Windows.Forms.ToolStripMenuItem
$miToggle.Text = "聚焦强度: 温和"
$miToggle.Add_Click({
    if ($script:FocusMode -eq "gentle") {
        $script:FocusMode = "aggressive"
        $miToggle.Text = "聚焦强度: 激进"
    } else {
        $script:FocusMode = "gentle"
        $miToggle.Text = "聚焦强度: 温和"
    }
    Write-Log "INFO" "聚焦强度切换为 $script:FocusMode"
    Show-Balloon "电脑算力调度中心" "当前模式: $(if ($script:FocusMode -eq 'gentle') { '温和' } else { '激进' })"
})

$miCmdBus = New-Object System.Windows.Forms.ToolStripMenuItem
$miCmdBus.Text = "命令总线: 开"
$miCmdBus.Add_Click({
    if ($script:CmdBusEnabled) {
        $script:CmdBusEnabled = $false
        Stop-CommandBus
        $miCmdBus.Text = "命令总线: 关"
    } else {
        $script:CmdBusEnabled = $true
        Start-CommandBus
        $miCmdBus.Text = "命令总线: 开"
    }
    Write-Log "INFO" "命令总线切换为 $script:CmdBusEnabled"
})

$miLog = New-Object System.Windows.Forms.ToolStripMenuItem
$miLog.Text = "打开日志"
$miLog.Add_Click({ Open-Log })

$miAuth = New-Object System.Windows.Forms.ToolStripMenuItem
$miAuth.Text = "打开授权清单"
$miAuth.Add_Click({ Open-AuthFile })

$miAuto = New-Object System.Windows.Forms.ToolStripMenuItem
$miAuto.Text = "开机自启: 关"
$miAuto.Add_Click({ Toggle-Autostart; Update-AutoMenuText })

$miExit = New-Object System.Windows.Forms.ToolStripMenuItem
$miExit.Text = "退出"
$miExit.Add_Click({
    try { Stop-Focus } catch {}
    try { Stop-CommandBus } catch {}
    try { $tray.Visible = $false; $tray.Dispose() } catch {}
    Write-Lifecycle "MENU_EXIT" "user clicked exit"
    Write-Log "INFO" "电脑算力调度中心 v0.13 已退出"
    [System.Windows.Forms.Application]::Exit()
})

$menu.Items.Add($miSelect) | Out-Null
$menu.Items.Add($miStart) | Out-Null
$menu.Items.Add($miGod) | Out-Null
$menu.Items.Add($miStop) | Out-Null
$menu.Items.Add($miToggle) | Out-Null
$menu.Items.Add($miCmdBus) | Out-Null
$menu.Items.Add($miLog) | Out-Null
$menu.Items.Add($miAuth) | Out-Null
$menu.Items.Add($miAuto) | Out-Null
$menu.Items.Add($miExit) | Out-Null
$tray.ContextMenuStrip = $menu

Update-AutoMenuText
Write-Log "INFO" "电脑算力调度中心 v0.13 已启动（命令总线: $script:CmdBusEnabled）"
Write-Lifecycle "SCRIPT_READY" "tray started"
Start-CommandBus
Start-MemGuardGuard | Out-Null
Write-Heartbeat

# 隐藏窗体承载消息泵
$form = New-Object System.Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
$form.Show()
$form.Hide()

# 捕获 UI 线程未处理异常（移植自 v2）
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    $detail = ""
    try {
        if ($e -and $e.Exception) { $detail = $e.Exception.ToString() }
        Add-Content -LiteralPath $global:PF_LifecycleLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [UI_THREAD_EXCEPTION] pid=$PID exception=$detail" -Encoding utf8
    } catch {}
    try { Write-Log "ERROR" "UI 线程异常: $detail" } catch {}
})

# 捕获进程级未处理异常（能落盘就说明不是外部强杀）
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    $detail = ""
    try {
        if ($e -and $e.ExceptionObject) { $detail = $e.ExceptionObject.ToString() }
        Add-Content -LiteralPath $global:PF_LifecycleLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [UNHANDLED_EXCEPTION] pid=$PID exception=$detail" -Encoding utf8
    } catch {}
    try { Write-Log "ERROR" "未处理异常: $detail" } catch {}
})

# PowerShell 引擎退出事件：优雅退出会留下记录
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    try {
        Add-Content -LiteralPath $global:PF_LifecycleLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [POWERSHELL_EXITING] pid=$PID" -Encoding utf8
    } catch {}
} | Out-Null

try {
    [System.Windows.Forms.Application]::Run($form)
} catch {
    try { Write-Lifecycle "FATAL_APPLICATION_RUN" "$_" } catch {}
    try { Write-Log "ERROR" "主消息循环异常: $_" } catch {}
} finally {
    try { Write-Lifecycle "APPLICATION_RUN_RETURNED" "exitcode=$([Environment]::ExitCode)" } catch {}
    try { Stop-CommandBus } catch {}
    try { $tray.Visible = $false; $tray.Dispose() } catch {}
}
