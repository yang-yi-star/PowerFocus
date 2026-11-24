#Requires -Version 7.0
<#
============================================================
 PowerFocus 03 号「EcoQoS 入口 PID 复查」离线回归（14 号补测第 3 条 / 34 号轮）
 被测：versions\<ver>\rules-engine.ps1 的 Set-EcoQos
       （入口 Get-Process 复查 → 取不到静默 return $false → 命中才调 SetProcessInformation）
       及 Invoke-RuleAction 的 'ecoqos' 分支委派
 手法：AST 从真规则引擎提取两个函数定义并 dot-source（非复制品）；
       Add-Type 自带同名 PowerFocus.RulesNative 桩（计调用次数 / 可控返回值 / 记录入参）；
       桩 Get-Process 返回 missing / 真实进程 / 假句柄三种
 边界：不对任何真实进程设置 EcoQoS、不启内核、不碰命令总线、不写生产日志
 用法：pwsh -NoProfile -File E:\PowerFocus\tests\test-ecoqos-recheck.ps1
       pwsh -NoProfile -File ... -RulesPath <变异副本>    # 验证能抓回归
 退出码：0 = 全绿；1 = 存在 FAIL
============================================================
#>
[CmdletBinding()]
param([string]$RulesPath = '')

$ErrorActionPreference = 'Stop'
$script:pass = 0
$script:fail = 0

function Check {
    param([string]$Name, [bool]$Cond, [string]$Detail)
    if ($Cond) {
        $script:pass++
        Write-Host ('  [PASS] ' + $Name + '  ' + $Detail)
    } else {
        $script:fail++
        Write-Host ('  [FAIL] ' + $Name + '  ' + $Detail) -ForegroundColor Red
    }
}

# ---------- 0. 定位规则引擎（跟 versions\current.json，避免目录重构后假红） ----------
$Root = Split-Path -Parent $PSScriptRoot
if (-not $RulesPath) {
    $verName = 'v0.13'
    $curFile = Join-Path $Root 'versions\current.json'
    if (Test-Path -LiteralPath $curFile) {
        $v = (Get-Content $curFile -Raw -Encoding utf8 | ConvertFrom-Json).version
        if ($v) { $verName = $v }
    }
    $RulesPath = Join-Path $Root "versions\$verName\rules-engine.ps1"
}
if (-not (Test-Path -LiteralPath $RulesPath)) { throw "规则引擎不存在：$RulesPath" }
Write-Host "被测规则引擎：$RulesPath"

# ---------- 1. AST 提取真函数（不执行整个规则引擎） ----------
$tok = $null; $parseErr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($RulesPath, [ref]$tok, [ref]$parseErr)
if ($parseErr -and $parseErr.Count -gt 0) { throw "规则引擎语法错误 $($parseErr.Count) 条，先修语法再测行为" }

$need = @('Set-EcoQos', 'Invoke-RuleAction')
$defs = @{}
foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($need -contains $fn.Name -and -not $defs.ContainsKey($fn.Name)) { $defs[$fn.Name] = $fn.Extent.Text }
}
foreach ($n in $need) {
    if (-not $defs.ContainsKey($n)) { throw "规则引擎里找不到函数 $n（被改名或删除了？先核对本测试）" }
    . ([scriptblock]::Create($defs[$n]))
}
Write-Host "AST 提取：$($need -join ' / ')（定义来自真规则引擎，非复制品）"

# ---------- 2. 桩：EcoQoS 原生层（同名类型替换，只在本测试进程内） ----------
if ('PowerFocus.RulesNative' -as [type]) { throw '需要干净会话：已存在真实 PowerFocus.RulesNative，无法桩替换' }
Add-Type -TypeDefinition @'
namespace PowerFocus {
    public static class RulesNative {
        public static int SetInfoCalls = 0;
        public static bool SetInfoResult = true;
        public static int LastClass = 0;
        public static uint LastSize = 0;
        public static uint LastStateMask = 4294967295;
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        public struct PROCESS_POWER_THROTTLING_STATE { public uint Version; public uint ControlMask; public uint StateMask; }
        public static bool SetProcessInformation(System.IntPtr hProcess, int ProcessInformationClass, ref PROCESS_POWER_THROTTLING_STATE pi, uint size) {
            SetInfoCalls++; LastClass = ProcessInformationClass; LastSize = size; LastStateMask = pi.StateMask; return SetInfoResult;
        }
    }
}
'@

$script:Logs = [System.Collections.Generic.List[string]]::new()
$script:GetCalls = 0
$script:ProcMode = 'missing'

function Write-RuleLog { param([string]$Level, [string]$Msg) $null = $script:Logs.Add("$Level|$Msg") }

# 桩 Get-Process：只服务 -Id 一种取法，按场景返回
function Get-Process {
    [CmdletBinding()]
    param([int]$Id, [string[]]$Name)
    $script:GetCalls++
    switch ($script:ProcMode) {
        'missing'   { return $null }
        'real'      { return [System.Diagnostics.Process]::GetProcessById($PID) }
        'badhandle' { return [pscustomobject]@{ Name = 'pf-raced'; Id = $Id; Handle = 'not-a-handle' } }
        default     { return $null }
    }
}

function Reset-State {
    param([string]$Mode)
    $script:GetCalls = 0
    $script:ProcMode = $Mode
    $script:Logs.Clear()
    [PowerFocus.RulesNative]::SetInfoCalls = 0
    [PowerFocus.RulesNative]::SetInfoResult = $true
}

# ---------- 3. A：PID 不存在 → 静默跳过 ----------
Reset-State 'missing'
$a = Set-EcoQos -ProcId 999999 -On $true
Check 'A1 取不到进程时返回 $false' ($false -eq $a) "return=$a"
Check 'A2 完全静默（0 条日志，不写 WARN）' ($script:Logs.Count -eq 0) "logs=$($script:Logs.Count)"
Check 'A3 未调用原生设置（0 次）' ([PowerFocus.RulesNative]::SetInfoCalls -eq 0) "calls=$([PowerFocus.RulesNative]::SetInfoCalls)"
Check 'A4 复查只取一次（不重试）' ($script:GetCalls -eq 1) "getCalls=$($script:GetCalls)"

# ---------- 4. B：PID 存在 → 设置一次 + INFO 留痕 ----------
Reset-State 'real'
$b = Set-EcoQos -ProcId $PID -On $true
Check 'B1 设置成功时返回 $true' ($true -eq $b) "return=$b"
Check 'B2 原生设置恰好调用 1 次' ([PowerFocus.RulesNative]::SetInfoCalls -eq 1) "calls=$([PowerFocus.RulesNative]::SetInfoCalls)"
Check 'B3 INFO 恰好一条且形如「规则动作: ecoqos 名称(pid) on=True ok=True」' ($script:Logs.Count -eq 1 -and $script:Logs[0] -match ('^INFO\|规则动作: ecoqos .+\(' + $PID + '\) on=True ok=True$')) "$($script:Logs -join ';')"
Check 'B4 日志带 ProcId（可反查回目标）' ($script:Logs.Count -eq 1 -and $script:Logs[0].Contains("($PID)")) "$($script:Logs -join ';')"
Check 'B5 API 契约：ProcessInformationClass=4、结构大小=12' ([PowerFocus.RulesNative]::LastClass -eq 4 -and [PowerFocus.RulesNative]::LastSize -eq 12) "class=$([PowerFocus.RulesNative]::LastClass) size=$([PowerFocus.RulesNative]::LastSize)"
Check 'B6 StateMask=1（开启语义写进结构）' ([PowerFocus.RulesNative]::LastStateMask -eq 1) "mask=$([PowerFocus.RulesNative]::LastStateMask)"

# ---------- 5. C：PID 存在但原生返回 false → 尊重结果、不升格为 WARN ----------
Reset-State 'real'
[PowerFocus.RulesNative]::SetInfoResult = $false
$c = Set-EcoQos -ProcId $PID -On $true
Check 'C1 原生失败时返回 $false（不谎报成功）' ($false -eq $c) "return=$c"
Check 'C2 仍为 INFO ok=False，不写 WARN' ($script:Logs.Count -eq 1 -and $script:Logs[0].StartsWith('INFO|') -and $script:Logs[0] -match 'ok=False') "$($script:Logs -join ';')"

# ---------- 6. D：取到后句柄失效（退出竞态）→ 捕获、不抛异常 ----------
Reset-State 'badhandle'
$threw = $false
$d = $null
try { $d = Set-EcoQos -ProcId 424242 -On $true } catch { $threw = $true }
Check 'D1 句柄失效不抛出且返回布尔 $false' ((-not $threw) -and ($d -is [bool]) -and (-not $d)) "threw=$threw return=$d type=$(if ($null -eq $d) { 'null' } else { $d.GetType().Name })"
Check 'D2 记一条 WARN 含"EcoQoS 失败"' ($script:Logs.Count -eq 1 -and $script:Logs[0].StartsWith('WARN|') -and $script:Logs[0] -match 'EcoQoS 失败\(424242\)') "$($script:Logs -join ';')"
Check 'D3 在进入原生调用前就被拦下（0 次）' ([PowerFocus.RulesNative]::SetInfoCalls -eq 0) "calls=$([PowerFocus.RulesNative]::SetInfoCalls)"

# ---------- 7. F：On=$false 关模式也走同一条链 ----------
Reset-State 'real'
$f = Set-EcoQos -ProcId $PID -On $false
Check 'F1 关闭模式同样返回原生结果' ($true -eq $f) "return=$f"
Check 'F2 关闭模式也只调 1 次' ([PowerFocus.RulesNative]::SetInfoCalls -eq 1) "calls=$([PowerFocus.RulesNative]::SetInfoCalls)"
Check 'F3 日志如实记录 on=False' ($script:Logs.Count -eq 1 -and $script:Logs[0] -match 'on=False') "$($script:Logs -join ';')"
Check 'F4 StateMask=0（关闭语义写进结构）' ([PowerFocus.RulesNative]::LastStateMask -eq 0) "mask=$([PowerFocus.RulesNative]::LastStateMask)"

# ---------- 8. E：结构断言（锁住 03 修法本体，防被挪走/放宽） ----------
$t = $defs['Set-EcoQos']
$iGet    = $t.IndexOf('Get-Process -Id $ProcId')
$mGuard  = [regex]::Match($t, '(?s)if\s*\(\s*-\s*not\s*\$p\s*\)\s*\{\s*return\s+\$false\s*\}')
$iGuard  = if ($mGuard.Success) { $mGuard.Index } else { -1 }
$iNative = $t.IndexOf('New-Object PowerFocus.RulesNative')
Check 'E1 入口复查行 + 静默 return 守卫同时在' ($iGet -ge 0 -and $iGuard -ge 0) "get=$iGet guard=$iGuard"
Check 'E2 守卫条件是「取不到 $p」即 return $false' ($mGuard.Success) 'if (-not $p) { return $false }'
Check 'E3 守卫整块早于原生对象构造（TOCTOU 窗口在入口处关掉）' ($iGuard -ge 0 -and $iNative -gt $iGuard) "guard=$iGuard native=$iNative"
Check 'E4 复查带 -ErrorAction SilentlyContinue（访问拒绝也按不存在处理）' ($iGet -ge 0 -and $t.Substring($iGet, [Math]::Min(90, $t.Length-$iGet)) -match 'SilentlyContinue') 'SilentlyContinue'
Check 'E5 守卫之前没有 WARN（不把退出当异常报）' ($iGuard -ge 0 -and $t.Substring(0, $iGuard) -notmatch 'Write-RuleLog\s+"WARN"') 'guard 前无 WARN'
Check 'E6 函数内无循环 / 无退避等待（不重试）' ($t -notmatch '(?m)^\s*(for|foreach|while|do)\b' -and $t -notmatch 'Start-Sleep') 'no loop / no sleep'
$act = $defs['Invoke-RuleAction']
Check 'E7 ecoqos 分支委派 Set-EcoQos -On $true' ($act -match "(?s)'ecoqos'\s*\{\s*return\s+Set-EcoQos\s+-ProcId\s+\`$procId\s+-On\s+\`$true\s*\}") 'branch delegate'

Write-Host ''
Write-Host ("PASS {0} / FAIL {1}" -f $script:pass, $script:fail)
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
