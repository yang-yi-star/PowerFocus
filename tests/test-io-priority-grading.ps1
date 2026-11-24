#Requires -Version 7.0
<#
============================================================
 PowerFocus 05 号「I/O 优先级失败分级」离线回归（14 号余项 / 73 号轮）
 被测：versions\<ver>\电脑算力调度中心_v<ver>.ps1 的
       Enable-IoBoostPrivilege / Get-IoFailureText / Set-IoPriority
 手法：AST 从真内核提取三个函数整段定义并 dot-source（非复制品）；
       Add-Type 自带同名 PowerFocus.Native / PowerFocus.Priv 桩：
       - OpenProcess 可返回有效句柄或零，记录 access
       - NtSetInformationProcess 可返回指定 NTSTATUS，记录 info class / value / length
       - CloseHandle 计次
       - EnableIoBoost 可返回 0 / 1300 / 1314 / 其它，或抛异常
       桩 Get-Process（存在 / 已退出）与 Write-Log。
 覆盖：0xC0000061→PrivilegeNotHeld、0xC0000022→AccessDenied、其它 NTSTATUS→Other、
       句柄打开失败→AccessDenied、进程已退出→Exited、异常→Error、
       仅 High 启用特权、特权缓存幂等、finally 必关句柄、三类文案。
 边界：不碰真实进程 I/O、不启用真实令牌特权、不启内核、不写生产日志。
 用法：pwsh -NoProfile -File E:\PowerFocus\tests\test-io-priority-grading.ps1
       pwsh -NoProfile -File ... -KernelPath <变异副本>
 退出码：0 = 全绿；1 = 存在 FAIL
============================================================
#>
[CmdletBinding()]
param([string]$KernelPath = '')

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0

function Check {
    param([string]$Name, [bool]$Cond, [string]$Detail = '')
    if ($Cond) {
        $script:Pass++
        Write-Host ('  [PASS] ' + $Name + '  ' + $Detail)
    } else {
        $script:Fail++
        Write-Host ('  [FAIL] ' + $Name + '  ' + $Detail) -ForegroundColor Red
    }
}

# ---------- 0. 定位当前内核（跟 versions\current.json，避免目录重构后假红） ----------
$Root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($KernelPath)) {
    $verName = 'v0.13'
    $curFile = Join-Path $Root 'versions\current.json'
    if (Test-Path -LiteralPath $curFile) {
        $v = (Get-Content $curFile -Raw -Encoding utf8 | ConvertFrom-Json).version
        if ($v) { $verName = $v }
    }
    $KernelPath = Join-Path $Root "versions\$verName\电脑算力调度中心_$verName.ps1"
}
if (-not (Test-Path -LiteralPath $KernelPath)) { throw "内核不存在：$KernelPath" }
Write-Host "被测内核：$KernelPath"

# ---------- 1. AST 提取三个真函数 ----------
$tok = $null; $parseErr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($KernelPath, [ref]$tok, [ref]$parseErr)
if ($parseErr -and $parseErr.Count -gt 0) { throw "内核语法错误 $($parseErr.Count) 条，先修语法再测行为" }

$need = @('Enable-IoBoostPrivilege', 'Get-IoFailureText', 'Set-IoPriority')
$defs = @{}
foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($need -contains $fn.Name -and -not $defs.ContainsKey($fn.Name)) { $defs[$fn.Name] = $fn.Extent.Text }
}
foreach ($n in $need) {
    if (-not $defs.ContainsKey($n)) { throw "内核里找不到函数 $n（被改名或删除了？先核对本测试）" }
}
$enableText = $defs['Enable-IoBoostPrivilege']
$textText   = $defs['Get-IoFailureText']
$setText    = $defs['Set-IoPriority']

. ([scriptblock]::Create($enableText))
. ([scriptblock]::Create($textText))
. ([scriptblock]::Create($setText))
Write-Host "AST 提取：$($need -join ' / ')（定义来自真内核，非复制品）"

# ---------- 2. 同名原生层桩（只在本测试进程内） ----------
foreach ($t in @('PowerFocus.Native', 'PowerFocus.Priv')) {
    if ($t -as [type]) { throw "需要干净会话：已存在真实 $t，无法桩替换" }
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace PowerFocus {
    public static class Native {
        public static IntPtr NextHandle = new IntPtr(0x1234);
        public static int NextNt = 0;
        public static bool ThrowOnSet = false;
        public static int OpenCalls = 0;
        public static int SetCalls = 0;
        public static int CloseCalls = 0;
        public static uint LastOpenAccess = 0;
        public static bool LastOpenInherit = false;
        public static int LastOpenPid = 0;
        public static int LastInfoClass = 0;
        public static int LastValue = -1;
        public static int LastInfoLength = 0;
        public static IntPtr OpenProcess(uint access, bool inherit, int pid) {
            OpenCalls++; LastOpenAccess = access; LastOpenInherit = inherit; LastOpenPid = pid;
            return NextHandle;
        }
        public static bool CloseHandle(IntPtr h) { CloseCalls++; return true; }
        public static int NtSetInformationProcess(IntPtr h, int infoClass, ref int info, int length) {
            SetCalls++; LastInfoClass = infoClass; LastValue = info; LastInfoLength = length;
            if (ThrowOnSet) throw new InvalidOperationException("pf-stub-set-throw");
            return NextNt;
        }
    }
    public static class Priv {
        public static int NextResult = 0;
        public static bool ThrowNext = false;
        public static int Calls = 0;
        public static int EnableIoBoost() {
            Calls++;
            if (ThrowNext) throw new InvalidOperationException("pf-stub-priv-throw");
            return NextResult;
        }
    }
}
'@

# ---------- 3. 桩 Get-Process / Write-Log 与状态重置 ----------
$script:Logs = [System.Collections.Generic.List[string]]::new()
$script:ProcMode = 'real'   # real | missing

function Write-Log {
    param([string]$Level, [string]$Msg)
    $script:Logs.Add("$Level|$Msg")
}

function Get-Process {
    [CmdletBinding()]
    param([int]$Id)
    switch ($script:ProcMode) {
        'missing' { return $null }
        'real'    { return [pscustomobject]@{ Id = $Id; Name = 'pf-stub' } }
        default   { return $null }
    }
}

$script:IoBoostPrivState = $null
$script:LastIoFailure = $null
$script:LastIoNt = $null
$script:LastIoError = $null

function Reset-IoState {
    param([string]$Mode = 'real')
    $script:Logs.Clear()
    $script:ProcMode = $Mode
    $script:IoBoostPrivState = $null
    $script:LastIoFailure = $null
    $script:LastIoNt = $null
    $script:LastIoError = $null
    [PowerFocus.Native]::NextHandle = [IntPtr]0x1234
    [PowerFocus.Native]::NextNt = 0
    [PowerFocus.Native]::ThrowOnSet = $false
    [PowerFocus.Native]::OpenCalls = 0
    [PowerFocus.Native]::SetCalls = 0
    [PowerFocus.Native]::CloseCalls = 0
    [PowerFocus.Native]::LastOpenAccess = 0
    [PowerFocus.Native]::LastOpenInherit = $false
    [PowerFocus.Native]::LastOpenPid = 0
    [PowerFocus.Native]::LastInfoClass = 0
    [PowerFocus.Native]::LastValue = -1
    [PowerFocus.Native]::LastInfoLength = 0
    [PowerFocus.Priv]::NextResult = 0
    [PowerFocus.Priv]::ThrowNext = $false
    [PowerFocus.Priv]::Calls = 0
}

# ---------- 4. A 组：文案映射（纯函数） ----------
Write-Host "`n[A] Get-IoFailureText 文案"
$script:LastIoFailure = 'Exited'
Check 'A1 Exited 文案为「目标进程已退出」' ((Get-IoFailureText) -eq '目标进程已退出') (Get-IoFailureText)

$script:LastIoFailure = 'PrivilegeNotHeld'
$t = Get-IoFailureText
Check 'A2 PrivilegeNotHeld 文案含 0xC0000061' ($t.Contains('0xC0000061')) $t
Check 'A3 PrivilegeNotHeld 文案含 SeIncreaseBasePriorityPrivilege' ($t.Contains('SeIncreaseBasePriorityPrivilege')) $t

$script:LastIoFailure = 'AccessDenied'
$t = Get-IoFailureText
Check 'A4 AccessDenied 文案含 0xC0000022' ($t.Contains('0xC0000022')) $t
Check 'A5 AccessDenied 文案含「拒绝访问」' ($t.Contains('拒绝访问')) $t

$script:LastIoFailure = 'Error'
Check 'A6 Error 文案为「调用异常」' ((Get-IoFailureText) -eq '调用异常') (Get-IoFailureText)

$script:LastIoFailure = 'Other:0xC000000D'
$t = Get-IoFailureText
Check 'A7 Other 文案保留原始 NTSTATUS' ($t.Contains('Other:0xC000000D')) $t
Check 'A8 Other 文案标注「未知失败」' ($t.Contains('未知失败')) $t

$script:LastIoFailure = 'Weird'
Check 'A9 未登记值回落为「未知失败（Weird）」' ((Get-IoFailureText) -eq '未知失败（Weird）') (Get-IoFailureText)
$script:LastIoFailure = $null
Check 'A10 空值回落为「未知失败（）」' ((Get-IoFailureText) -eq '未知失败（）') (Get-IoFailureText)
Check 'A11 文案不再使用旧的混装句「权限不足或进程受保护」' (-not $textText.Contains('权限不足或进程受保护')) $textText

# ---------- 5. B 组：Enable-IoBoostPrivilege ----------
Write-Host "`n[B] Enable-IoBoostPrivilege 特权启用"
Reset-IoState
[PowerFocus.Priv]::NextResult = 0
$b = Enable-IoBoostPrivilege
Check 'B1 ret=0 返回 true' ($b -eq $true) "return=$b"
Check 'B2 ret=0 状态为 Enabled' ($script:IoBoostPrivState -eq 'Enabled') $script:IoBoostPrivState
Check 'B3 ret=0 只落一条 INFO' ($script:Logs.Count -eq 1 -and $script:Logs[0] -like 'INFO|*I/O 提升特权已启用*') ($script:Logs -join ';')
Check 'B4 ret=0 原生调用 1 次' ([PowerFocus.Priv]::Calls -eq 1) "calls=$([PowerFocus.Priv]::Calls)"
$b = Enable-IoBoostPrivilege
Check 'B5 缓存幂等：二次调用返回 true 且不重调原生' ($b -eq $true -and [PowerFocus.Priv]::Calls -eq 1) "return=$b calls=$([PowerFocus.Priv]::Calls)"
Check 'B6 缓存幂等：二次调用不重复落日志' ($script:Logs.Count -eq 1) "logs=$($script:Logs.Count)"

Reset-IoState
[PowerFocus.Priv]::NextResult = 1300
$b = Enable-IoBoostPrivilege
Check 'B7 ret=1300 返回 false 且状态 NotHeld' ($b -eq $false -and $script:IoBoostPrivState -eq 'NotHeld') "return=$b state=$($script:IoBoostPrivState)"
Check 'B8 ret=1300 只落 INFO 且含「未分配」和 ret=1300' ($script:Logs.Count -eq 1 -and $script:Logs[0] -like 'INFO|*未分配*ret=1300*') ($script:Logs -join ';')

Reset-IoState
[PowerFocus.Priv]::NextResult = 1314
$b = Enable-IoBoostPrivilege
Check 'B9 ret=1314 返回 false 且状态 NotHeld' ($b -eq $false -and $script:IoBoostPrivState -eq 'NotHeld') "return=$b state=$($script:IoBoostPrivState)"

Reset-IoState
[PowerFocus.Priv]::NextResult = -1
$b = Enable-IoBoostPrivilege
Check 'B10 其它 ret 返回 false 且状态 Failed' ($b -eq $false -and $script:IoBoostPrivState -eq 'Failed') "return=$b state=$($script:IoBoostPrivState)"
Check 'B11 其它 ret 只落一条 WARN 且含 ret=-1' ($script:Logs.Count -eq 1 -and $script:Logs[0] -like 'WARN|*失败*ret=-1*') ($script:Logs -join ';')

Reset-IoState
[PowerFocus.Priv]::ThrowNext = $true
$b = Enable-IoBoostPrivilege
Check 'B12 原生抛异常返回 false 且状态 Failed' ($b -eq $false -and $script:IoBoostPrivState -eq 'Failed') "return=$b state=$($script:IoBoostPrivState)"
Check 'B13 原生抛异常落一条 WARN 且含「异常」' ($script:Logs.Count -eq 1 -and $script:Logs[0] -like 'WARN|*异常*') ($script:Logs -join ';')

# ---------- 6. C 组：Set-IoPriority 失败分级 ----------
Write-Host "`n[C] Set-IoPriority 失败分级"
Reset-IoState 'missing'
$r = Set-IoPriority -ProcessId 999999 -Value 2
Check 'C1 进程不存在返回 false' ($r -eq $false) "return=$r"
Check 'C2 进程不存在分类 Exited' ($script:LastIoFailure -eq 'Exited') $script:LastIoFailure
Check 'C3 进程不存在 LastIoNt 为空' ($null -eq $script:LastIoNt) "nt=$($script:LastIoNt)"
Check 'C4 进程不存在不碰原生（Open/Set/Close 全 0）' ([PowerFocus.Native]::OpenCalls -eq 0 -and [PowerFocus.Native]::SetCalls -eq 0 -and [PowerFocus.Native]::CloseCalls -eq 0) "open=$([PowerFocus.Native]::OpenCalls) set=$([PowerFocus.Native]::SetCalls) close=$([PowerFocus.Native]::CloseCalls)"
Check 'C5 进程不存在文案正确' ((Get-IoFailureText) -eq '目标进程已退出') (Get-IoFailureText)

Reset-IoState
[PowerFocus.Native]::NextHandle = [IntPtr]::Zero
$r = Set-IoPriority -ProcessId $PID -Value 1
Check 'C6 OpenProcess 返回零时返回 false' ($r -eq $false) "return=$r"
Check 'C7 OpenProcess 返回零分类 AccessDenied' ($script:LastIoFailure -eq 'AccessDenied') $script:LastIoFailure
Check 'C8 OpenProcess 返回零不进入 NtSet' ([PowerFocus.Native]::OpenCalls -eq 1 -and [PowerFocus.Native]::SetCalls -eq 0) "open=$([PowerFocus.Native]::OpenCalls) set=$([PowerFocus.Native]::SetCalls)"
Check 'C9 OpenProcess 返回零不调 CloseHandle' ([PowerFocus.Native]::CloseCalls -eq 0) "close=$([PowerFocus.Native]::CloseCalls)"

Reset-IoState
[PowerFocus.Native]::NextNt = -1073741727
$r = Set-IoPriority -ProcessId $PID -Value 3
Check 'C10 0xC0000061 返回 false' ($r -eq $false) "return=$r"
Check 'C11 0xC0000061 分类 PrivilegeNotHeld' ($script:LastIoFailure -eq 'PrivilegeNotHeld') $script:LastIoFailure
Check 'C12 0xC0000061 保留 LastIoNt' ($script:LastIoNt -eq -1073741727) "nt=$($script:LastIoNt)"
Check 'C13 High 请求把 Value=3 / class=0x21 / length=4 传给原生' ([PowerFocus.Native]::LastValue -eq 3 -and [PowerFocus.Native]::LastInfoClass -eq 0x21 -and [PowerFocus.Native]::LastInfoLength -eq 4) "value=$([PowerFocus.Native]::LastValue) class=$([PowerFocus.Native]::LastInfoClass) len=$([PowerFocus.Native]::LastInfoLength)"
Check 'C14 OpenProcess 使用 0x1F0FFF 全权限' ([PowerFocus.Native]::LastOpenAccess -eq 0x1F0FFF) "access=0x$('{0:X}' -f [PowerFocus.Native]::LastOpenAccess)"
Check 'C15 失败也走 finally 关句柄 1 次' ([PowerFocus.Native]::CloseCalls -eq 1) "close=$([PowerFocus.Native]::CloseCalls)"
Check 'C16 High 请求启用特权 1 次' ([PowerFocus.Priv]::Calls -eq 1) "privCalls=$([PowerFocus.Priv]::Calls)"
Check 'C17 0xC0000061 文案含 0xC0000061' ((Get-IoFailureText).Contains('0xC0000061')) (Get-IoFailureText)

Reset-IoState
[PowerFocus.Native]::NextNt = -1073741790
$r = Set-IoPriority -ProcessId $PID -Value 1
Check 'C18 0xC0000022 返回 false' ($r -eq $false) "return=$r"
Check 'C19 0xC0000022 分类 AccessDenied' ($script:LastIoFailure -eq 'AccessDenied') $script:LastIoFailure
Check 'C20 0xC0000022 保留 LastIoNt' ($script:LastIoNt -eq -1073741790) "nt=$($script:LastIoNt)"
Check 'C21 低优先级请求不启用特权（Priv 0 次）' ([PowerFocus.Priv]::Calls -eq 0) "privCalls=$([PowerFocus.Priv]::Calls)"
Check 'C22 0xC0000022 文案含 0xC0000022' ((Get-IoFailureText).Contains('0xC0000022')) (Get-IoFailureText)
Check 'C23 0xC0000022 失败也关句柄 1 次' ([PowerFocus.Native]::CloseCalls -eq 1) "close=$([PowerFocus.Native]::CloseCalls)"

Reset-IoState
[PowerFocus.Native]::NextNt = -1073741811
$r = Set-IoPriority -ProcessId $PID -Value 2
Check 'C24 其它 NTSTATUS 返回 false' ($r -eq $false) "return=$r"
Check 'C25 其它 NTSTATUS 分类 Other:0xC000000D' ($script:LastIoFailure -eq 'Other:0xC000000D') $script:LastIoFailure
Check 'C26 Other 文案保留 NTSTATUS' ((Get-IoFailureText).Contains('Other:0xC000000D')) (Get-IoFailureText)
Check 'C27 Normal 请求不启用特权（Priv 0 次）' ([PowerFocus.Priv]::Calls -eq 0) "privCalls=$([PowerFocus.Priv]::Calls)"
Check 'C28 其它 NTSTATUS 失败也关句柄 1 次' ([PowerFocus.Native]::CloseCalls -eq 1) "close=$([PowerFocus.Native]::CloseCalls)"

Reset-IoState
[PowerFocus.Native]::NextNt = 0
[PowerFocus.Priv]::NextResult = 1300
$r = Set-IoPriority -ProcessId $PID -Value 3
Check 'C29 NtSet 成功时返回 true（特权未持有不谎报失败）' ($r -eq $true) "return=$r"
Check 'C30 NtSet 成功时 LastIoFailure 清空' ($null -eq $script:LastIoFailure) "fail=$($script:LastIoFailure)"
Check 'C31 NtSet 成功时 LastIoNt 清空' ($null -eq $script:LastIoNt) "nt=$($script:LastIoNt)"
Check 'C32 NtSet 成功也关句柄 1 次' ([PowerFocus.Native]::CloseCalls -eq 1) "close=$([PowerFocus.Native]::CloseCalls)"
Check 'C33 High 请求即使特权 NotHeld 也调用 1 次' ([PowerFocus.Priv]::Calls -eq 1 -and $script:IoBoostPrivState -eq 'NotHeld') "calls=$([PowerFocus.Priv]::Calls) state=$($script:IoBoostPrivState)"

Reset-IoState
[PowerFocus.Native]::NextNt = 0
$r = Set-IoPriority -ProcessId $PID -Value 1
Check 'C34 降级请求成功返回 true' ($r -eq $true) "return=$r"
Check 'C35 降级请求不启用特权（Priv 0 次）' ([PowerFocus.Priv]::Calls -eq 0) "privCalls=$([PowerFocus.Priv]::Calls)"
Check 'C36 降级请求成功也关句柄 1 次' ([PowerFocus.Native]::CloseCalls -eq 1) "close=$([PowerFocus.Native]::CloseCalls)"

Reset-IoState
[PowerFocus.Native]::ThrowOnSet = $true
$r = Set-IoPriority -ProcessId $PID -Value 2
Check 'C37 NtSet 抛异常返回 false' ($r -eq $false) "return=$r"
Check 'C38 NtSet 抛异常分类 Error' ($script:LastIoFailure -eq 'Error') $script:LastIoFailure
Check 'C39 NtSet 抛异常不写日志（由调用方分级）' ($script:Logs.Count -eq 0) "logs=$($script:Logs.Count)"
Check 'C40 NtSet 抛异常仍走 finally 关句柄 1 次' ([PowerFocus.Native]::CloseCalls -eq 1) "close=$([PowerFocus.Native]::CloseCalls)"
Check 'C41 NtSet 抛异常文案为「调用异常」' ((Get-IoFailureText) -eq '调用异常') (Get-IoFailureText)

# ---------- 7. D 组：结构锁 ----------
Write-Host "`n[D] 结构锁"
Check 'D1 Set-IoPriority 开头同时重置 LastIoFailure 与 LastIoNt' ($setText -match '(?s)param\(\[int\]\$ProcessId, \[int\]\$Value\).*?\$script:LastIoFailure = \$null.*?\$script:LastIoNt = \$null') 'reset pair'
Check 'D2 仅 $Value -gt 2 时调用 Enable-IoBoostPrivilege' ($setText -match 'if \(\$Value -gt 2\) \{ Enable-IoBoostPrivilege') 'gt guard'
Check 'D3 OpenProcess 权限为 0x1F0FFF' ($setText -match 'OpenProcess\(0x1F0FFF') 'access'
Check 'D4 NtSet 使用 ProcessIoPriority=0x21 / length=4' ($setText -match 'NtSetInformationProcess\(\$h, 0x21, \[ref\]\$val, 4\)') 'ntset'
Check 'D5 finally 块内调用 CloseHandle($h)' ($setText -match '(?s)finally \{.*?CloseHandle\(\$h\)') 'finally close'
Check 'D6 两个 NTSTATUS 常量 -1073741727 / -1073741790 均在' ($setText.Contains('-1073741727') -and $setText.Contains('-1073741790')) 'nt constants'
$labelHits = @('Exited', 'PrivilegeNotHeld', 'AccessDenied', 'Error', 'default') |
    ForEach-Object { $textText.Contains("'$_'") -or ($_ -eq 'default' -and $textText.Contains('default')) }
Check 'D7 文案函数覆盖 Exited/PrivilegeNotHeld/AccessDenied/Error/default' (($labelHits -notcontains $false)) 'switch labels'
Check 'D8 特权函数缓存 IoBoostPrivState' ($enableText -match 'if \(\$script:IoBoostPrivState\) \{ return') 'cache guard'
Check 'D9 特权函数同时识别 1300 与 1314' ($enableText -match '\$r -eq 1300 -or \$r -eq 1314') 'notheld codes'
Check 'D10 特权函数对其它 ret 走 Failed + WARN' ($enableText -match '(?s)else \{.*?IoBoostPrivState = ''Failed''.*?Write-Log "WARN"') 'failed branch'

# ---------- 8. 汇总 ----------
Write-Host ''
Write-Host ("RESULT: PASS={0} FAIL={1}" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
