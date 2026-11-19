#Requires -Version 7.0
<#
============================================================
 PowerFocus 总线鉴权离线回归（14 号「测试缺口」首条补测）
 被测：versions\v0.13 内核 Invoke-CommandBusTick 的三分支拒绝（01 号修法）
 手法：AST 从真内核提取函数定义，桩掉日志/心跳/令牌读取/命令执行器，
       在临时目录投递 4 份命令，断言回执文案、搬移结果与 WARN 留痕
 边界：不读真实 .auth_token、不碰 versions\v0.13\commands、不启动内核
 用法：pwsh -NoProfile -File E:\PowerFocus\tests\test-bus-auth.ps1
       pwsh -NoProfile -File E:\PowerFocus\tests\test-bus-auth.ps1 -Keep
 退出码：0 = 全绿；1 = 存在 FAIL
============================================================
#>
[CmdletBinding()]
param(
    [switch]$Keep,
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

$need = @('Invoke-CommandBusTick', 'Get-PriorityRank')
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
function Write-Heartbeat { }
function Get-AuthToken { return $script:StubToken }
function Invoke-CommandObject { param($CmdObj) return "OK: STUB:$($CmdObj.action)" }

# ---------- 3. 隔离运行环境（临时目录，绝不碰真实总线） ----------
$work = Join-Path $env:TEMP ('pf-test-bus-auth-' + [guid]::NewGuid().ToString('N'))
$script:CmdIn = Join-Path $work 'in'
$script:CmdDone = Join-Path $work 'done'
$null = New-Item -ItemType Directory -Path $script:CmdIn, $script:CmdDone -Force
$script:CmdBusEnabled = $true
$script:BusyProcessing = $false
$script:TickCount = 0
$script:RulesRunning = $true
$script:PowerRequest = $null
$script:StubToken = $null
Write-Host "隔离目录：$work"

function Invoke-Case {
    param([string]$Name, [string]$Json, [string]$Token)
    Get-ChildItem -LiteralPath $script:CmdIn -File -ErrorAction SilentlyContinue | Remove-Item -Force
    $script:Logs.Clear()
    $script:StubToken = $Token
    $file = Join-Path $script:CmdIn $Name
    [System.IO.File]::WriteAllText($file, $Json, [System.Text.UTF8Encoding]::new($false))
    Invoke-CommandBusTick
    $receipt = Join-Path $script:CmdDone ($Name + '.result.txt')
    $text = if (Test-Path -LiteralPath $receipt) { (Get-Content -LiteralPath $receipt -Raw -Encoding utf8).Trim() } else { '<无回执文件>' }
    [pscustomobject]@{
        Name   = $Name
        Text   = $text
        Moved  = -not (Test-Path -LiteralPath $file)
        InDone = Test-Path -LiteralPath (Join-Path $script:CmdDone $Name)
        Logs   = ($script:Logs -join ' ;; ')
    }
}

$Good = 'pf-test-token-9f3c'

# ---------- 4. 四个场景 ----------
Write-Host "`n=== 场景 A：令牌文件不可读或为空 -> 全拒 ==="
$a = Invoke-Case -Name 'pf-test-auth-a.json' -Json '{"op":"status"}' -Token $null
Check 'A1 回执指明令牌文件问题' ($a.Text -match '授权令牌文件不可读或为空') "回执=$($a.Text)"
Check 'A2 WARN 留痕'            ($a.Logs -match '授权令牌文件不可读或为空') "日志=$($a.Logs)"
Check 'A3 命令已搬入 done'       ($a.Moved -and $a.InDone) "moved=$($a.Moved) done=$($a.InDone)"

Write-Host "`n=== 场景 B：命令缺 token 字段 -> 拒 ==="
$b = Invoke-Case -Name 'pf-test-auth-b.json' -Json '{"op":"status"}' -Token $Good
Check 'B1 回执指明缺 token 字段' ($b.Text -match '命令缺少 token 字段') "回执=$($b.Text)"
Check 'B2 WARN 留痕'            ($b.Logs -match '正文缺 token 字段') "日志=$($b.Logs)"
Check 'B3 未进入执行器'          (-not ($b.Text -match 'STUB:')) "回执=$($b.Text)"

Write-Host "`n=== 场景 C：token 值不匹配 -> 拒 ==="
$c = Invoke-Case -Name 'pf-test-auth-c.json' -Json '{"token":"pf-test-token-WRONG","action":"status"}' -Token $Good
Check 'C1 回执指明 token 不匹配' ($c.Text -match 'token 不匹配') "回执=$($c.Text)"
Check 'C2 WARN 留痕'            ($c.Logs -match 'token 不匹配') "日志=$($c.Logs)"
Check 'C3 未进入执行器'          (-not ($c.Text -match 'STUB:')) "回执=$($c.Text)"

Write-Host "`n=== 场景 D：正确 token -> 放行到执行器 ==="
$d = Invoke-Case -Name 'pf-test-auth-d.json' -Json ('{"token":"' + $Good + '","action":"status"}') -Token $Good
Check 'D1 放行并回执行器结果'    ($d.Text -match 'OK: STUB:status') "回执=$($d.Text)"
Check 'D2 无鉴权 WARN'          (-not ($d.Logs -match '认证失败|被拒')) "日志=$($d.Logs)"

# ---------- 5. 收尾一致性 ----------
Write-Host "`n=== 汇总一致性 ==="
$inLeft = @(Get-ChildItem -LiteralPath $script:CmdIn -File -ErrorAction SilentlyContinue).Count
$doneFiles = @(Get-ChildItem -LiteralPath $script:CmdDone -File -ErrorAction SilentlyContinue)
$doneCmds = @($doneFiles | Where-Object { $_.Name -notlike '*.result.txt' }).Count
$doneRcpt = @($doneFiles | Where-Object { $_.Name -like '*.result.txt' }).Count
Check 'E1 in 目录已清空'        ($inLeft -eq 0) "剩余=$inLeft"
Check 'E2 4 份命令全部搬入 done' ($doneCmds -eq 4) "命令=$doneCmds"
Check 'E3 4 份回执全部落盘'      ($doneRcpt -eq 4) "回执=$doneRcpt"

Write-Host ''
Write-Host ('PASS {0} / FAIL {1}' -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
Write-Host "隔离目录：$work$(if ($Keep) { '（按 -Keep 保留）' } else { '（即将清理）' })"

if (-not $Keep) {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

exit $(if ($script:fail -gt 0) { 1 } else { 0 })
