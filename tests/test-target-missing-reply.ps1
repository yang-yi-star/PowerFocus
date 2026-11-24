#Requires -Version 7.0
<#
============================================================
 PowerFocus 06 号「目标定位失败三分类」离线回归（14 号补测第 2 条）
 被测：内核 Get-TargetMissingReply（纯字符串函数 + 一条 WARN 日志）
 手法：AST 从真内核提取函数定义 dot-source，桩掉 Write-Log 收集日志，
       六组输入断言文案分级、WARN 级别、action 名与分支互斥
 边界：不解析真实 PID、不碰 versions\<ver>\commands、不启动内核
 用法：pwsh -NoProfile -File E:\PowerFocus\tests\test-target-missing-reply.ps1
       pwsh -NoProfile -File ... -KernelPath <变异副本>   # 验证测试能抓回归
 退出码：0 = 全绿；1 = 存在 FAIL
============================================================
#>
[CmdletBinding()]
param(
    [string]$KernelPath = ''
)

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

# ---------- 0. 定位内核（跟 versions\current.json，避免目录重构后假红） ----------
$Root = Split-Path -Parent $PSScriptRoot
if (-not $KernelPath) {
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

# ---------- 1. AST 提取真函数（不执行整个内核） ----------
$tok = $null; $parseErr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($KernelPath, [ref]$tok, [ref]$parseErr)
if ($parseErr -and $parseErr.Count -gt 0) { throw "内核语法错误 $($parseErr.Count) 条，先修语法再测行为" }

$need = @('Get-TargetMissingReply')
$defs = @{}
foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($need -contains $fn.Name) { $defs[$fn.Name] = $fn.Extent.Text }
}
foreach ($n in $need) {
    if (-not $defs.ContainsKey($n)) { throw "内核里找不到函数 $n（被改名或删除了？先核对本测试）" }
    . ([scriptblock]::Create($defs[$n]))
}
Write-Host "AST 提取：$($need -join ', ')（定义来自真内核，非复制品）"

# ---------- 2. 桩：写在真函数之后，同作用域同名覆盖 ----------
$script:Logs = [System.Collections.Generic.List[string]]::new()
function Write-Log { param([string]$Level, [string]$Msg) $null = $script:Logs.Add("$Level|$Msg") }
function Clear-Logs { $script:Logs.Clear() }
# 只保留函数实际用到的字段，避免依赖内核其它对象
function New-Cmd([hashtable]$H) { return [pscustomobject]$H }

# ---------- 3. A：给了 pid 但进程不存在 ----------
Clear-Logs
$a = Get-TargetMissingReply (New-Cmd @{ pid = 999999 }) 'focus'
Check 'A1 回执为错误且指向 PID' ($a -eq 'ERROR: PID 999999 不存在（进程可能已退出，或 pid 填错）') $a
Check 'A2 提示退出/填错两种成因' ($a -match '进程可能已退出' -and $a -match 'pid 填错') $a
Check 'A3 WARN 恰好一条' ($script:Logs.Count -eq 1 -and $script:Logs[0].StartsWith('WARN|')) "logs=$($script:Logs.Count)"
Check 'A4 日志带 action 名' ($script:Logs[0] -match '\[focus\]') $script:Logs[0]

# ---------- 4. B：给了 process_name 但无匹配 ----------
Clear-Logs
$b = Get-TargetMissingReply (New-Cmd @{ process_name = 'pf-no-such-proc' }) 'set_priority'
Check 'B1 回执指向进程名' ($b -eq "ERROR: 没有进程名匹配 'pf-no-such-proc'（可能已退出，或名称拼写不符）") $b
Check 'B2 不再混说 PID' (-not ($b -match 'PID')) $b
Check 'B3 WARN 带 action 名' ($script:Logs.Count -eq 1 -and $script:Logs[0] -match '\[set_priority\]') $script:Logs[0]

# ---------- 5. C：两个字段都缺 ----------
Clear-Logs
$c = Get-TargetMissingReply (New-Cmd @{}) 'kill'
Check 'C1 缺字段文案独立' ($c -eq 'ERROR: 命令缺少 pid / process_name 字段，无法定位目标') $c
Check 'C2 WARN 恰好一条' ($script:Logs.Count -eq 1 -and $script:Logs[0].StartsWith('WARN|')) "logs=$($script:Logs.Count)"

# ---------- 6. D：action 未传 → who 回落 unknown ----------
Clear-Logs
$null = Get-TargetMissingReply (New-Cmd @{}) $null
Check 'D1 缺 action 时日志回落 unknown' ($script:Logs[0] -match '\[unknown\]') $script:Logs[0]

# ---------- 7. E/F：边界与优先级 ----------
Clear-Logs
$e = Get-TargetMissingReply (New-Cmd @{ pid = 0 }) 'focus'
Check 'E1 pid=0 视为缺字段（不误报 PID 0 不存在）' ($e -match '缺少 pid / process_name 字段') $e
Clear-Logs
$f = Get-TargetMissingReply (New-Cmd @{ pid = 999999; process_name = 'pf-no-such-proc' }) 'focus'
Check 'F1 pid 与 process_name 同时给时 pid 优先' ($f.StartsWith('ERROR: PID 999999')) $f

# ---------- 8. G：三分类互不相同 + 返回值恒为单字符串 ----------
Check 'G1 三条分支文案互不相同（防回退成一句"均未命中"）' (($a -ne $b) -and ($b -ne $c) -and ($a -ne $c)) 'a/b/c 文案两两不等'
Check 'G2 返回值为单个字符串' (-not ($a -is [array]) -and $a -is [string]) $a.GetType().Name

Write-Host ''
Write-Host ("PASS {0} / FAIL {1}" -f $script:pass, $script:fail)
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
