#Requires -Version 7.0
<#
============================================================
 PowerFocus 02 号「空 action 防御」离线回归（14 号补测第 3 条）
 被测：内核 Invoke-CommandObject 的空 action 防御段
 手法：AST 从真内核提取整个函数定义 dot-source（不执行其它顶层代码），
       桩掉 Write-Log 收集日志；断言 缺字段 / null / 纯空白 / 整条 Cmd 为 null
       四类输入的回执文案、WARN 级别与落点；外加一条未知 action 作阴性对照，
       并用 AST 结构断言锁住「防御在 switch 之前、在 action 取值之后」。
 边界：不启动内核、不写 commands 目录、不碰运行态
 用法：pwsh -NoProfile -File E:\PowerFocus\tests\test-empty-action.ps1
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

# ---------- 1. AST 解析 + 取函数定义（不执行整个内核） ----------
$tok = $null; $parseErr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($KernelPath, [ref]$tok, [ref]$parseErr)
if ($parseErr -and $parseErr.Count -gt 0) { throw "内核语法错误 $($parseErr.Count) 条，先修语法再测行为" }

$fnAst = $ast.Find({
    param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-CommandObject'
}, $true)
if (-not $fnAst) { throw '内核里找不到函数 Invoke-CommandObject（被改名或删除了？先核对本测试）' }

. ([scriptblock]::Create($fnAst.Extent.Text))
Write-Host 'AST 提取：Invoke-CommandObject（定义来自真内核，非复制品）'

# ---------- 2. 桩：写在真函数之后，同作用域同名覆盖 ----------
$script:Logs = [System.Collections.Generic.List[string]]::new()
function Write-Log { param([string]$Level, [string]$Msg) $null = $script:Logs.Add("$Level|$Msg") }
function Clear-Logs { $script:Logs.Clear() }
function New-Cmd([hashtable]$H) { return [pscustomobject]$H }
function WarnCount { return @($script:Logs | Where-Object { $_ -like 'WARN|*' }).Count }
function InfoCount { return @($script:Logs | Where-Object { $_ -like 'INFO|*' }).Count }

$ExpectEmpty = 'ERROR: 命令缺少 action 字段（action 只取 JSON 正文，文件名不参与解析）'

# ---------- 3. AST 结构断言：防御必须在 switch 之前、在 action 取值之后 ----------
$guardAst = $fnAst.Find({
    param($n)
    $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -match '命令缺少 action 字段'
}, $true)
$switchAst = $fnAst.Find({
    param($n)
    $n -is [System.Management.Automation.Language.SwitchStatementAst]
}, $true)
$asgAst = $fnAst.Find({
    param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$action'
}, $true)

$h1Detail = if ($guardAst) { '找到带空 action 回执文案的 IfStatement' } else { '找不到：防御被删或回执文案被改' }
$h2Detail = if ($guardAst -and $switchAst) { "guard@$($guardAst.Extent.StartOffset) switch@$($switchAst.Extent.StartOffset)" } else { '缺 guard 或 switch' }
$h3Detail = if ($guardAst -and $asgAst) { "assign@$($asgAst.Extent.StartOffset) guard@$($guardAst.Extent.StartOffset)" } else { '缺 guard 或赋值' }
$h4Detail = if ($guardAst) { 'extent 内含 return' } else { '无 guard' }
$h5Detail = if ($guardAst) {
    $pred = if ($guardAst.Extent.Text -match 'IsNullOrWhiteSpace') { 'IsNullOrWhiteSpace' }
            elseif ($guardAst.Extent.Text -match '\.Trim\(') { 'Trim' }
            else { '其他判定（不覆盖空白）' }
    "判定=$pred"
} else { '无 guard' }

Check 'H1 防御段存在' ([bool]$guardAst) $h1Detail
Check 'H2 防御在 switch 之前' ([bool]($guardAst -and $switchAst -and ($guardAst.Extent.StartOffset -lt $switchAst.Extent.StartOffset))) $h2Detail
Check 'H3 防御在 action 取值之后' ([bool]($guardAst -and $asgAst -and ($asgAst.Extent.StartOffset -lt $guardAst.Extent.StartOffset))) $h3Detail
Check 'H4 防御段直接 return（不是只写日志再放行）' ([bool]($guardAst -and ($guardAst.Extent.Text -match 'return')) ) $h4Detail
Check 'H5 空白也纳入防御（IsNullOrWhiteSpace 或 Trim 等价判定）' ([bool]($guardAst -and ($guardAst.Extent.Text -match 'IsNullOrWhiteSpace|\.Trim\('))) $h5Detail

# ---------- 4. A：整条 Cmd 为 null（总线读到坏 JSON 的极端输入） ----------
Clear-Logs
$a = Invoke-CommandObject $null
Check 'A1 null Cmd -> 空 action 文案' ($a -eq $ExpectEmpty) $a
Check 'A2 WARN 恰好一条' (($script:Logs.Count -eq 1) -and ((WarnCount) -eq 1)) "logs=$($script:Logs.Count) warn=$(WarnCount)"
Check 'A3 WARN 文案提到空 action' ($script:Logs.Count -eq 1 -and $script:Logs[0].StartsWith('WARN|') -and $script:Logs[0] -match '空 action') $(if ($script:Logs.Count) { $script:Logs[0] } else { '无日志' })
Check 'A4 空分支不落 INFO（早退先于日志收尾行）' (($script:Logs.Count -eq 1) -and ((InfoCount) -eq 0)) "info=$(InfoCount)"

# ---------- 5. B：正文缺 action 字段 ----------
Clear-Logs
$b = Invoke-CommandObject (New-Cmd @{})
Check 'B1 缺字段 → 空 action 文案' ($b -eq $ExpectEmpty) $b
Check 'B2 一条 WARN 且无 INFO' (($script:Logs.Count -eq 1) -and ((WarnCount) -eq 1) -and ((InfoCount) -eq 0)) "logs=$($script:Logs.Count)"

# ---------- 6. C：action = null ----------
Clear-Logs
$c = Invoke-CommandObject (New-Cmd @{ action = $null })
Check 'C1 null → 空 action 文案' ($c -eq $ExpectEmpty) $c
Check 'C2 一条 WARN 且无 INFO' (($script:Logs.Count -eq 1) -and ((WarnCount) -eq 1) -and ((InfoCount) -eq 0)) "logs=$($script:Logs.Count)"

# ---------- 7. D：action 为纯空白（空格 / 制表 / 换行） ----------
Clear-Logs
$d = Invoke-CommandObject (New-Cmd @{ action = '   ' })
Check 'D1 纯空格 → 空 action 文案' ($d -eq $ExpectEmpty) $d
Clear-Logs
$d2 = Invoke-CommandObject (New-Cmd @{ action = "`t`n" })
Check 'D2 制表/换行也算空白' ($d2 -eq $ExpectEmpty) $d2
Check 'D3 两类空白与缺字段文案完全一致' (($d -eq $b) -and ($d2 -eq $b)) 'd=b 且 d2=b'

# ---------- 8. E：阴性对照——真实未知 action 必须走 default，不许被空值防御吞掉 ----------
Clear-Logs
$e = Invoke-CommandObject (New-Cmd @{ action = 'pf-no-such-action' })
Check 'E1 未知 action 仍走 default 分支' ($e -eq 'ERROR: 未知 action: pf-no-such-action') $e
Check 'E2 非空 action 打 INFO 且不报 WARN' (((InfoCount) -eq 1) -and ((WarnCount) -eq 0)) "logs=$($script:Logs.Count)"
Check 'E3 INFO 行带 action 名' ([bool]($script:Logs.Count -ge 1 -and $script:Logs[0] -match 'action=pf-no-such-action')) $(if ($script:Logs.Count) { $script:Logs[0] } else { '无日志' })

# ---------- 9. F/G：四类空输入文案一致 + 返回值恒为单字符串 ----------
Check 'F1 四类空输入回执完全相同' (($a -eq $b) -and ($b -eq $c) -and ($c -eq $d)) 'a=b=c=d'
Check 'G1 返回值为单个字符串且以 ERROR: 开头' ((-not ($a -is [array])) -and ($a -is [string]) -and $a.StartsWith('ERROR: ')) $a.GetType().Name
Check 'G2 空文案与未知 action 文案不同（防回退成 default 的空串报错）' ($a -ne $e) '空分支 != 未知分支'

Write-Host ''
Write-Host ("PASS {0} / FAIL {1}" -f $script:pass, $script:fail)
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
