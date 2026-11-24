# tests\test-power-plan-guard.ps1 —— 36 号轮建、37 号轮扩
# 目的：把 04 电源计划双守卫 + 36 号轮 fail-closed + 37 号轮 Restore 失败分支钉成离线回归；不碰真实电源计划。
# 用法：
#   pwsh -NoProfile -File tests\test-power-plan-guard.ps1
#   pwsh -NoProfile -File tests\test-power-plan-guard.ps1 -KernelPath <变异副本>
# 末行固定格式：RESULT: PASS=<n> FAIL=<n>（run-tests 4i 依赖）
#
# 两条硬约束（35 号轮教训）：
#   ① 桩 Invoke-Native 也必须写 [Alias('Args')][string[]]$ArgList，否则桩自身丢参、断言全假；
#   ② 必须验参数内容（/setactive + GUID），不能只数调用次数。

[CmdletBinding()]
param([string]$KernelPath = '')

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($KernelPath)) {
    $KernelPath = Join-Path $PSScriptRoot '..\versions\v0.13\电脑算力调度中心_v0.13.ps1'
}
if (-not (Test-Path -LiteralPath $KernelPath)) {
    Write-Host "FATAL kernel not found: $KernelPath"
    exit 2
}

$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($KernelPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    Write-Host "FATAL parse_errors=$($parseErrors.Count)"
    $parseErrors | ForEach-Object { Write-Host "  $($_.Message)" }
    exit 2
}

$fns = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -in @('Set-PowerPlanHigh', 'Restore-PowerPlan')
    }, $true)
if ($fns.Count -ne 2) {
    Write-Host "FATAL expected 2 functions, got $($fns.Count)"
    exit 2
}

$setText = ($fns | Where-Object { $_.Name -eq 'Set-PowerPlanHigh' }).Extent.Text
$resText = ($fns | Where-Object { $_.Name -eq 'Restore-PowerPlan' }).Extent.Text

Write-Host "kernel=$KernelPath"
Write-Host "functions=2 parse_errors=0"

# ---------------- 桩环境 ----------------
$script:HighPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:BalancedGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:OriginalPlan = $null
$script:Logs = [System.Collections.Generic.List[string]]::new()
$script:NativeCalls = [System.Collections.Generic.List[object]]::new()
$script:PcfgCalls = [System.Collections.Generic.List[string]]::new()
$script:NativeReturn = $true
$script:PowerMode = 'ok'      # ok | fail | noguid
$script:ListHasHigh = $true
$script:CurrentGuid = $script:BalancedGuid

function Write-Log {
    param([string]$Level, [string]$Msg)
    $script:Logs.Add("$Level|$Msg")
}

# 同名函数遮蔽 powercfg.exe（命令优先级：Function > Application），不执行任何真实电源操作
function powercfg {
    param([Parameter(ValueFromRemainingArguments = $true)]$Rest)
    $line = ($Rest -join ' ')
    $script:PcfgCalls.Add($line)
    if ($line -like '*getactivescheme*') {
        switch ($script:PowerMode) {
            'ok' { "电源方案 GUID: $($script:CurrentGuid)  (当前)"; $global:LASTEXITCODE = 0 }
            'fail' { $global:LASTEXITCODE = 1 }
            'noguid' { "输出里没有 GUID"; $global:LASTEXITCODE = 0 }
        }
    }
    elseif ($line -like '*list*') {
        if ($script:ListHasHigh) { "电源方案 GUID: $($script:HighPerfGuid)  (高性能)" }
        else { "电源方案 GUID: $($script:BalancedGuid)  (平衡)" }
        $global:LASTEXITCODE = 0
    }
    else { $global:LASTEXITCODE = 0 }
}

function Invoke-Native {
    param([string]$Exe, [Alias('Args')][string[]]$ArgList, [string]$What)
    $script:NativeCalls.Add([pscustomobject]@{ Exe = $Exe; Args = @($ArgList); What = $What })
    return $script:NativeReturn
}

# 从真内核里 dot-source 两个函数（共享同一个 script 作用域，$script: 变量互通）
. ([scriptblock]::Create(($fns | ForEach-Object { $_.Extent.Text }) -join "`r`n"))

# ---------------- 断言框架 ----------------
$script:Pass = 0; $script:Fail = 0; $script:FailList = @()
function Assert([string]$Name, [bool]$Cond, [string]$Detail = '') {
    if ($Cond) { $script:Pass++; Write-Host "  PASS $Name" }
    else { $script:Fail++; $script:FailList += $Name; Write-Host "  FAIL $Name  $Detail" }
}
function Reset-State {
    $script:OriginalPlan = $null
    $script:Logs.Clear()
    $script:NativeCalls.Clear()
    $script:PcfgCalls.Clear()
    $script:NativeReturn = $true
    $script:PowerMode = 'ok'
    $script:ListHasHigh = $true
    $script:CurrentGuid = $script:BalancedGuid
}
function Get-Logs([string]$Level) { @($script:Logs | Where-Object { $_ -like "$Level|*" }) }
function Get-LogText { ($script:Logs -join ' ;; ') }

# ---------------- A 已是高性能 ----------------
Write-Host '--- A 已是高性能 ---'
Reset-State
$script:CurrentGuid = $script:HighPerfGuid
Set-PowerPlanHigh
Assert 'A1 native 0 次' ($script:NativeCalls.Count -eq 0) "count=$($script:NativeCalls.Count)"
Assert 'A2 INFO 含「已是高性能」恰一条' (@(Get-Logs INFO | Where-Object { $_ -like '*已是高性能*' }).Count -eq 1) (Get-LogText)
Assert 'A3 OriginalPlan 清空' ($null -eq $script:OriginalPlan) "orig=$script:OriginalPlan"
Assert 'A4 无 WARN' ((Get-Logs WARN).Count -eq 0) (Get-LogText)
Assert 'A5 守卫① 先返回：只查了 getactivescheme' ($script:PcfgCalls.Count -eq 1 -and $script:PcfgCalls[0] -like '*getactivescheme*') "calls=$($script:PcfgCalls -join ';')"

# ---------------- B 计划缺失 ----------------
Write-Host '--- B 本机无高性能计划 ---'
Reset-State
$script:ListHasHigh = $false
Set-PowerPlanHigh
Assert 'B1 native 0 次' ($script:NativeCalls.Count -eq 0) "count=$($script:NativeCalls.Count)"
Assert 'B2 INFO 含「本机无高性能电源计划」' (@(Get-Logs INFO | Where-Object { $_ -like '*本机无高性能电源计划*' }).Count -eq 1) (Get-LogText)
Assert 'B3 OriginalPlan 清空' ($null -eq $script:OriginalPlan)
Assert 'B4 无 WARN' ((Get-Logs WARN).Count -eq 0) (Get-LogText)
Assert 'B5 查过 /list' ($script:PcfgCalls.Count -ge 2 -and ($script:PcfgCalls | Where-Object { $_ -like '*list*' }).Count -eq 1) "calls=$($script:PcfgCalls -join ';')"

# ---------------- C 正常切换 ----------------
Write-Host '--- C 正常切换 ---'
Reset-State
Set-PowerPlanHigh
Assert 'C1 native 恰 1 次' ($script:NativeCalls.Count -eq 1) "count=$($script:NativeCalls.Count)"
Assert 'C2 参数[0]=/setactive' ($script:NativeCalls.Count -eq 1 -and $script:NativeCalls[0].Args[0] -eq '/setactive') $(if ($script:NativeCalls.Count) { ($script:NativeCalls[0].Args -join '|') })
Assert 'C3 参数[1]=高性能 GUID（验内容不数次数）' ($script:NativeCalls.Count -eq 1 -and $script:NativeCalls[0].Args[1] -eq $script:HighPerfGuid)
Assert 'C4 What 含「切换高性能」' ($script:NativeCalls.Count -eq 1 -and $script:NativeCalls[0].What -like '*切换高性能*')
Assert 'C5 OriginalPlan=当前平衡 GUID' ($script:OriginalPlan -eq $script:BalancedGuid) "orig=$script:OriginalPlan"
Assert 'C6 INFO 含「原电源计划 GUID」' (@(Get-Logs INFO | Where-Object { $_ -like '*原电源计划 GUID*' }).Count -eq 1)
Assert 'C7 INFO 含「已切换为高性能」' (@(Get-Logs INFO | Where-Object { $_ -like '*已切换为高性能*' }).Count -eq 1) (Get-LogText)
Assert 'C8 无 WARN' ((Get-Logs WARN).Count -eq 0) (Get-LogText)

# ---------------- D getactivescheme 失败（fail-closed）----------------
Write-Host '--- D getactivescheme 失败 ---'
Reset-State
$script:PowerMode = 'fail'
Set-PowerPlanHigh
Assert 'D1 native 0 次（查不到当前方案就不切）' ($script:NativeCalls.Count -eq 0) "count=$($script:NativeCalls.Count)"
Assert 'D2 WARN 恰一条' ((Get-Logs WARN).Count -eq 1) (Get-LogText)
Assert 'D3 WARN 含 exit=1 与 getactivescheme 失败' (@(Get-Logs WARN | Where-Object { $_ -like '*getactivescheme 失败*' -and $_ -like '*exit=1*' }).Count -eq 1) (Get-LogText)
Assert 'D4 OriginalPlan 空' ($null -eq $script:OriginalPlan)
Assert 'D5 无「已切换为高性能」' (@(Get-Logs INFO | Where-Object { $_ -like '*已切换为高性能*' }).Count -eq 0) (Get-LogText)

# ---------------- E 解析不出 GUID（fail-closed）----------------
Write-Host '--- E 解析不出 GUID ---'
Reset-State
$script:PowerMode = 'noguid'
Set-PowerPlanHigh
Assert 'E1 native 0 次' ($script:NativeCalls.Count -eq 0) "count=$($script:NativeCalls.Count)"
Assert 'E2 WARN 含「未能解析当前电源计划 GUID」' (@(Get-Logs WARN | Where-Object { $_ -like '*未能解析当前电源计划 GUID*' }).Count -eq 1) (Get-LogText)
Assert 'E3 OriginalPlan 空' ($null -eq $script:OriginalPlan)
Assert 'E4 无「已切换为高性能」' (@(Get-Logs INFO | Where-Object { $_ -like '*已切换为高性能*' }).Count -eq 0)

# ---------------- F native 返回 false ----------------
Write-Host '--- F native 失败 ---'
Reset-State
$script:NativeReturn = $false
Set-PowerPlanHigh
Assert 'F1 native 1 次' ($script:NativeCalls.Count -eq 1) "count=$($script:NativeCalls.Count)"
Assert 'F2 WARN 含「切换高性能电源计划失败」' (@(Get-Logs WARN | Where-Object { $_ -like '*切换高性能电源计划失败*' }).Count -eq 1) (Get-LogText)
Assert 'F3 无「已切换为高性能」' (@(Get-Logs INFO | Where-Object { $_ -like '*已切换为高性能*' }).Count -eq 0)
Assert 'F4 OriginalPlan 保留（切失败仍可还原）' ($script:OriginalPlan -eq $script:BalancedGuid) "orig=$script:OriginalPlan"

# ---------------- G Restore 成功路径 ----------------
Write-Host '--- G Restore 成功 ---'
Reset-State
$script:OriginalPlan = $script:BalancedGuid
Restore-PowerPlan
Assert 'G1 native 恰 1 次' ($script:NativeCalls.Count -eq 1) "count=$($script:NativeCalls.Count)"
Assert 'G2 参数 /setactive + 原 GUID' ($script:NativeCalls.Count -eq 1 -and $script:NativeCalls[0].Args[0] -eq '/setactive' -and $script:NativeCalls[0].Args[1] -eq $script:BalancedGuid) $(if ($script:NativeCalls.Count) { ($script:NativeCalls[0].Args -join '|') })
Assert 'G3 INFO 含「电源计划已恢复」' (@(Get-Logs INFO | Where-Object { $_ -like '*电源计划已恢复*' }).Count -eq 1) (Get-LogText)
Assert 'G4 OriginalPlan 清空' ($null -eq $script:OriginalPlan)
Assert 'G5 Restore 不查 powercfg' ($script:PcfgCalls.Count -eq 0) "calls=$($script:PcfgCalls -join ';')"

# ---------------- H Restore 空原计划 ----------------
Write-Host '--- H Restore 空原计划 ---'
Reset-State
Restore-PowerPlan
Assert 'H1 0 次 native' ($script:NativeCalls.Count -eq 0) "count=$($script:NativeCalls.Count)"
Assert 'H2 0 条日志' ($script:Logs.Count -eq 0) (Get-LogText)

# ---------------- H3-H7 Restore 失败路径（37 号修）----------------
Write-Host '--- H3-H7 Restore 失败 ---'
Reset-State
$script:OriginalPlan = $script:BalancedGuid
$script:NativeReturn = $false
Restore-PowerPlan
Assert 'H3 native 恰 1 次（失败说明确实尝试过）' ($script:NativeCalls.Count -eq 1) "count=$($script:NativeCalls.Count)"
Assert 'H4 参数 /setactive + 原 GUID' ($script:NativeCalls.Count -eq 1 -and $script:NativeCalls[0].Args[0] -eq '/setactive' -and $script:NativeCalls[0].Args[1] -eq $script:BalancedGuid) $(if ($script:NativeCalls.Count) { ($script:NativeCalls[0].Args -join '|') })
Assert 'H5 WARN 恰一条且含「恢复电源计划失败」' (@(Get-Logs WARN | Where-Object { $_ -like '*恢复电源计划失败*' }).Count -eq 1 -and (Get-Logs WARN).Count -eq 1) (Get-LogText)
Assert 'H6 无 INFO「电源计划已恢复」' (@(Get-Logs INFO | Where-Object { $_ -like '*电源计划已恢复*' }).Count -eq 0) (Get-LogText)
Assert 'H7 OriginalPlan 保留（唯一重试依据）' ($script:OriginalPlan -eq $script:BalancedGuid) "orig=$(if ($null -eq $script:OriginalPlan) { '<null>' } else { $script:OriginalPlan })"

# ---------------- I 结构锁 ----------------
Write-Host '--- I 结构 ---'
Assert 'I1 Set-PowerPlanHigh 内 native 调用恰 1 处' (([regex]::Matches($setText, 'Invoke-Native -Exe "powercfg"')).Count -eq 1)
$iGuard1 = $setText.IndexOf('if ($cur -match [regex]::Escape($script:HighPerfGuid))')
$iGuard2 = $setText.IndexOf('if ($listAll -notmatch [regex]::Escape($script:HighPerfGuid))')
$iNative = $setText.IndexOf('Invoke-Native -Exe "powercfg"')
Assert 'I2 守卫① 位于 native 之前' ($iGuard1 -ge 0 -and $iNative -ge 0 -and $iGuard1 -lt $iNative) "g1=$iGuard1 native=$iNative"
Assert 'I3 守卫② 位于 native 之前' ($iGuard2 -ge 0 -and $iNative -ge 0 -and $iGuard2 -lt $iNative) "g2=$iGuard2 native=$iNative"
Assert 'I4 getactivescheme 失败分支以 return 收尾' ([regex]::IsMatch($setText, '(?s)if \(\$LASTEXITCODE -ne 0\)\s*\{[^{}]*?return'))
Assert 'I5 解析失败分支以 return 收尾' ([regex]::IsMatch($setText, '(?s)未能解析当前电源计划 GUID[^{}]*?return'))
Assert 'I6 Restore 内 native 调用恰 1 处' (([regex]::Matches($resText, 'Invoke-Native')).Count -eq 1)
Assert 'I7 两函数均已提取到正文' ($setText.Length -gt 200 -and $resText.Length -gt 100) "set=$($setText.Length) res=$($resText.Length)"
# 37 号结构锁：按返回值分支 + 清空只在成功分支内
Assert 'I8 Restore 以 Invoke-Native 返回值做 if 分支' ($resText.Contains('if (Invoke-Native -Exe "powercfg"')) 'expect if (Invoke-Native ...)'
Assert 'I9 else 分支存在且写 WARN' ($resText.Contains('} else {') -and $resText.Contains('恢复电源计划失败') -and $resText.Contains('"WARN"')) "else=$($resText.Contains('} else {'))"
$iInfo = $resText.IndexOf('电源计划已恢复')
$iNull = $resText.IndexOf('$script:OriginalPlan = $null')
$iWarn = $resText.IndexOf('恢复电源计划失败')
Assert 'I10 清空只发生在成功分支（INFO 之后、WARN 之前）' ([regex]::Matches($resText, [regex]::Escape('$script:OriginalPlan = $null')).Count -eq 1 -and $iInfo -ge 0 -and $iNull -gt $iInfo -and $iWarn -gt $iNull) "info=$iInfo null=$iNull warn=$iWarn"

# ---------------- 汇总 ----------------
Write-Host ''
Write-Host "RESULT: PASS=$($script:Pass) FAIL=$($script:Fail)"
if ($script:Fail -gt 0) {
    Write-Host "FAILED: $($script:FailList -join ', ')"
    exit 1
}
exit 0
