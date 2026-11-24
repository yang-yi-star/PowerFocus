#Requires -Version 7.0
<#
============================================================
 PowerFocus 35 号「Invoke-Native 丢参」离线回归（35 号轮）
 被测：versions\<ver>\电脑算力调度中心_v<ver>.ps1 的 Invoke-Native
 背景：原签名 param([string]$Exe, [string[]]$Args, [string]$What)。
       PowerShell 的 $args 是"未绑定参数数组"自动变量，会遮蔽同名参数：
       -Args @('/user') 确实进了 $PSBoundParameters，但函数体里的 $Args 恒为空，
       于是 & $Exe @Args 永远无参执行。实测（2026-11-21 03:2x）：
         whoami /user            → 18 字符 yang\administrator（应 225 字符含 SID 表）
         whoami /groups          → 18 字符（应 2,536 字符）
         powercfg /getactivescheme → exit=1「参数无效 -- 键入 "/?" 得到帮助」
       业务后果：4 处 powercfg /setactive 全被拒（exit=1）——
         Set-PowerPlanHigh 报「切换失败（可能是权限或策略限制）」假因、
         Restore-PowerPlan 空转、set_power_plan 命令永久返回 ERROR。
 修法：param 改 [Alias('Args')][string[]]$ArgList，函数体 @ArgList（调用点一字不改）。
 手法：AST 从真内核提取 Invoke-Native 整段定义并 dot-source（非复制品）；
       桩 Write-Log 收集日志；用 whoami / powercfg 真实只读命令验证参数是否真的落地。
 边界：不调 /setactive（绝不改用户电源计划）、不启内核、不碰命令总线、不写生产日志。
 用法：pwsh -NoProfile -File E:\PowerFocus\tests\test-native-args.ps1
       pwsh -NoProfile -File ... -KernelPath <变异副本>
 退出码：0 = 全绿；1 = 存在 FAIL
============================================================
#>
[CmdletBinding()]
param([string]$KernelPath = '')

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

# ---------- 0. 定位内核 ----------
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

# ---------- 1. AST 提取真函数 ----------
$tok = $null; $parseErr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($KernelPath, [ref]$tok, [ref]$parseErr)
if ($parseErr -and $parseErr.Count -gt 0) { throw "内核语法错误 $($parseErr.Count) 条，先修语法再测行为" }

$fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Invoke-Native' }, $true) | Select-Object -First 1
if (-not $fn) { throw '内核里找不到函数 Invoke-Native（被改名或删除了？先核对本测试）' }

$script:Logs = [System.Collections.Generic.List[object]]::new()
function Write-Log { param($Level, $Msg) $script:Logs.Add([pscustomobject]@{ Level = $Level; Msg = $Msg }) }
Invoke-Expression $fn.Extent.Text

$bare = (& whoami.exe 2>&1 | Out-String).Trim()

function Invoke-Case {
    param([string]$Exe, [string[]]$ArgList, [string]$What)
    $script:Logs.Clear()
    $script:Throw = ''
    $script:LastNativeOutput = ''
    try { $ret = Invoke-Native -Exe $Exe -Args $ArgList -What $What }
    catch { $ret = $null; $script:Throw = $_.Exception.Message }
    return $ret
}

Write-Host ''
Write-Host '== A. 参数真的传进 native（whoami /user）=='
$r = Invoke-Case 'whoami.exe' @('/user') 'SID 表'
Check 'A1 返回 true' ($null -ne $r -and $r -eq $true) ("ret={0}" -f $r)
Check 'A2 输出含 SID' ($script:LastNativeOutput -match 'SID') ("len={0}" -f $script:LastNativeOutput.Length)
Check 'A3 输出长度 > 100（裸 whoami 只有 18）' ($script:LastNativeOutput.Length -gt 100) ("len={0}" -f $script:LastNativeOutput.Length)
Check 'A4 与裸 whoami 输出不同' ($script:LastNativeOutput -ne $bare) ("bare='{0}'" -f $bare)
Check 'A5 无异常' ($script:Throw -eq '') $script:Throw

Write-Host ''
Write-Host '== B. 多元素数组（whoami /groups）=='
$r = Invoke-Case 'whoami.exe' @('/groups') '组表'
Check 'B1 返回 true' ($null -ne $r -and $r -eq $true) ("ret={0}" -f $r)
Check 'B2 输出长度 > 500' ($script:LastNativeOutput.Length -gt 500) ("len={0}" -f $script:LastNativeOutput.Length)

Write-Host ''
Write-Host '== C. 真实业务命令（powercfg /getactivescheme，只读）=='
$r = Invoke-Case 'powercfg' @('/getactivescheme') '读当前电源计划'
Check 'C1 返回 true' ($null -ne $r -and $r -eq $true) ("ret={0}" -f $r)
Check 'C2 输出含方案 GUID' ($script:LastNativeOutput -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') $script:LastNativeOutput
Check 'C3 不是「参数无效」' (-not ($script:LastNativeOutput -match '参数无效|Invalid')) $script:LastNativeOutput

Write-Host ''
Write-Host '== D. 失败路径仍要留痕（whoami /bogusflag）=='
$r = Invoke-Case 'whoami.exe' @('/bogusflag') '故意失败'
Check 'D1 返回 false' ($null -ne $r -and $r -eq $false) ("ret={0}" -f $r)
$warn = @($script:Logs | Where-Object { $_.Level -eq 'WARN' })
Check 'D2 WARN 恰一条且带 What' ($warn.Count -eq 1 -and $warn[0].Msg -match '故意失败') ("count={0}" -f $warn.Count)
Check 'D3 WARN 含 exit=1' ($warn.Count -eq 1 -and $warn[0].Msg -match 'exit=1') ($(if ($warn.Count) { $warn[0].Msg } else { '' }))

Write-Host ''
Write-Host '== E. 空参数仍照旧（无参调用不炸）=='
$r = Invoke-Case 'whoami.exe' @() '无参对照'
Check 'E1 返回 true' ($null -ne $r -and $r -eq $true) ("ret={0}" -f $r)
Check 'E2 输出等于裸 whoami' ($script:LastNativeOutput -eq $bare) ("got='{0}'" -f $script:LastNativeOutput)

Write-Host ''
Write-Host '== F. 结构锁（防再次踩自动变量坑）=='
$paramNames = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
Check 'F1 参数不叫 Args' (-not ($paramNames -contains 'Args')) ('names=' + ($paramNames -join ','))
$aliasHit = @($fn.Body.ParamBlock.Parameters | Where-Object {
        @($_.Attributes | Where-Object { $_.Extent.Text -match "Alias\('Args'\)" }).Count -gt 0
    })
Check 'F2 有 [Alias(''Args'')] 保住调用点' ($aliasHit.Count -eq 1) ("hit={0}" -f $aliasHit.Count)
# 只看代码、不把注释里提到的 @Args 算进来（否则修好的代码也会被自己的注释误判）
$bodyText = (($fn.Body.Extent.Text -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
Check 'F3 函数体用 @ArgList 展开' ($bodyText -match '@ArgList\b') ''
Check 'F4 函数体不再出现 @Args' (-not ($bodyText -match '@Args\b')) ''
Check 'F5 仍写 $script:LastNativeOutput' ($bodyText -match '\$script:LastNativeOutput\s*=') ''

Write-Host ''
Write-Host '== G. 既有调用点仍兼容 -Args =='
$callLines = @(Select-String -LiteralPath $KernelPath -Pattern 'Invoke-Native -Exe' -SimpleMatch)
$argsLines = @($callLines | Where-Object { $_.Line -match '-Args @\(' })
Check 'G1 全部调用点都用 -Args 传参' ($callLines.Count -ge 4 -and $argsLines.Count -eq $callLines.Count) ("calls={0} withArgs={1}" -f $callLines.Count, $argsLines.Count)

Write-Host ''
Write-Host ('RESULT: PASS={0} FAIL={1}' -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
