#Requires -Version 7.0
<#
============================================================
 PowerFocus 测试入口（run-tests）
 覆盖：PowerShell 语法 / JSON 配置契约 / Python 编译 / MCP stdio 冒烟 / 仓库卫生
 用法：pwsh -File E:\PowerFocus\tests\run-tests.ps1
       pwsh -File E:\PowerFocus\tests\run-tests.ps1 -SkipMcp
 退出码：0 = 全绿；1 = 存在 FAIL
============================================================
#>
[CmdletBinding()]
param(
    [switch]$SkipMcp,
    [int]$McpTimeoutSec = 120
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$results = [System.Collections.Generic.List[object]]::new()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail)
    $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\env.ps1')

# ---------------- 1. PowerShell 语法 ----------------
$psFiles = @(Get-ChildItem $Root -Recurse -Filter *.ps1 -File |
             Where-Object { $_.FullName -notmatch '\\(archive|__pycache__|\.git)\\' })
$bad = [System.Collections.Generic.List[string]]::new()
foreach ($f in $psFiles) {
    $tok = $null; $err = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
    } catch {
        $bad.Add("$($f.Name) -> 解析异常: $($_.Exception.Message)"); continue
    }
    if ($err -and $err.Count -gt 0) {
        $msg = ($err | Select-Object -First 3 | ForEach-Object { "L$($_.Extent.StartLineNumber): $($_.Message)" }) -join ' | '
        $bad.Add("$($f.Name) -> $msg")
    }
}
if ($bad.Count -eq 0) {
    Add-Result 'PS 语法' 'PASS' "$($psFiles.Count) 个 .ps1 全部通过"
} else {
    Add-Result 'PS 语法' 'FAIL' ($bad -join ' ;; ')
}

# ---------------- 2. JSON 配置契约 ----------------
# 内核已迁到 versions\<当前版本>\，路径随 current.json 指针解析，避免目录重构后测试假红。
$verDir = $null
$curFile = Join-Path $Root 'versions\current.json'
if (Test-Path $curFile) {
    $curVer = (Get-Content $curFile -Raw -Encoding utf8 | ConvertFrom-Json).version
    $cand = Join-Path $Root "versions\$curVer"
    if (Test-Path $cand) { $verDir = $cand }
}
if (-not $verDir) {
    $newest = Get-ChildItem (Join-Path $Root 'versions') -Directory -Filter 'v*' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if ($newest) { $verDir = $newest.FullName }
}
$jsonSpec = [ordered]@{
    (Join-Path $verDir 'model-profiles.json')  = 'powerfocus/model-profiles/v2'
    (Join-Path $verDir 'rules.json')           = $null
    (Join-Path $verDir 'scenes.json')          = $null
    (Join-Path $verDir 'authorized_apps.json') = $null
}
$jsonBad = [System.Collections.Generic.List[string]]::new()
foreach ($rel in $jsonSpec.Keys) {
    $p = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $Root $rel }
    $leaf = Split-Path $p -Leaf
    if (-not (Test-Path -LiteralPath $p)) { $jsonBad.Add("$leaf 缺少文件"); continue }
    try {
        $obj = Get-Content $p -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        $jsonBad.Add("$leaf 不是合法 JSON: $($_.Exception.Message)"); continue
    }
    $want = $jsonSpec[$rel]
    if ($want -and $obj.schema -ne $want) { $jsonBad.Add("$leaf schema=$($obj.schema) 期望 $want") }
}
if ($jsonBad.Count -eq 0) {
    Add-Result 'JSON 契约' 'PASS' "$($jsonSpec.Count) 个配置合法"
} else {
    Add-Result 'JSON 契约' 'FAIL' ($jsonBad -join ' ;; ')
}

# ---------------- 3. Python 编译 ----------------
$py = Get-DevPython
$pyTargets = @('v2-archive\mcp-server-legacy.py', 'app\server.py',
               'product\v1.00\app\server.py', 'product\v1.00\app\security.py',
               'product\v1.00\app\main.py')
if (-not $py) {
    Add-Result 'Python 编译' 'FAIL' '未找到可用 Python 解释器'
} else {
    $tmp = Join-Path $env:TEMP ("pf-compile-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $pyBad = [System.Collections.Generic.List[string]]::new()
    try {
        $i = 0
        foreach ($rel in $pyTargets) {
            $i++
            $src = Join-Path $Root $rel
            if (-not (Test-Path $src)) { $pyBad.Add("$rel 不存在"); continue }
            $outTxt = (& $py -c "import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)" $src (Join-Path $tmp "t$i.pyc") 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) { $pyBad.Add("$rel -> $outTxt") }
        }
        if ($pyBad.Count -eq 0) {
            Add-Result 'Python 编译' 'PASS' "$($pyTargets.Count) 个文件编译通过（$py）"
        } else {
            Add-Result 'Python 编译' 'FAIL' ($pyBad -join ' ;; ')
        }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------- 3b. Python 单元测试（.venv 存在才跑） ----------------
$venvPy = Join-Path $Root '.venv\Scripts\python.exe'
if (-not (Test-Path $venvPy)) {
    Add-Result 'pytest' 'SKIP' '未创建 .venv（跳过单元测试）'
} elseif (-not (Test-Path (Join-Path $Root 'tests\py'))) {
    Add-Result 'pytest' 'SKIP' '无 tests\py 目录'
} else {
    Push-Location $Root
    try {
        $ptOut = (& $venvPy -m pytest 2>&1) -join "`n"
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -eq 0) {
        $tail = (($ptOut -split "`r?`n" | Where-Object { $_ -match 'passed|failed' }) | Select-Object -Last 1)
        Add-Result 'pytest' 'PASS' $tail
    } else {
        Add-Result 'pytest' 'FAIL' (($ptOut -split "`r?`n" | Select-Object -Last 12) -join ' ;; ')
    }
}

# ---------------- 4. MCP stdio 冒烟 ----------------
$mcpPath = Join-Path $Root 'v2-archive\mcp-server-legacy.py'
if ($SkipMcp) {
    Add-Result 'MCP 冒烟' 'SKIP' '按参数跳过'
} elseif (-not $py) {
    Add-Result 'MCP 冒烟' 'FAIL' '无 Python 解释器'
} else {
    $payload = @'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"pf-selftest","version":"1.0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
'@
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $py
    $psi.ArgumentList.Add($mcpPath)
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.StandardInput.Write($payload + "`n")
        $proc.StandardInput.Close()

        if (-not $proc.WaitForExit($McpTimeoutSec * 1000)) {
            try { $proc.Kill($true) } catch {}
            Add-Result 'MCP 冒烟' 'FAIL' "超时 ${McpTimeoutSec}s 未退出"
        } else {
            $out = $outTask.GetAwaiter().GetResult()
            $err = $errTask.GetAwaiter().GetResult()
            $lines = @($out -split "`r?`n" | Where-Object { $_.Trim() })
            $init = $null; $list = $null
            foreach ($l in $lines) {
                try { $o = $l | ConvertFrom-Json } catch { continue }
                if ($o.id -eq 1) { $init = $o }
                if ($o.id -eq 2) { $list = $o }
            }
            if (-not $init -or -not $init.result.serverInfo) {
                Add-Result 'MCP 冒烟' 'FAIL' "initialize 无有效响应；stderr 尾部：$($err.Substring([Math]::Max(0,$err.Length-200)) -replace "`n", ' ')"
            } elseif (-not $list -or -not $list.result.tools) {
                Add-Result 'MCP 冒烟' 'FAIL' 'tools/list 无有效响应'
            } else {
                $names = @($list.result.tools | ForEach-Object { $_.name })
                $need = @('power_status', 'power_request', 'power_release', 'rules_list', 'rea_status',
                          'router_start', 'router_stop', 'router_status', 'list_model_profiles', 'boost_model')
                $miss = @($need | Where-Object { $names -notcontains $_ })
                $protocolOk = ($init.result.protocolVersion -eq '2025-06-18')
                if ($miss.Count -gt 0) {
                    Add-Result 'MCP 冒烟' 'FAIL' "缺少原生工具：$($miss -join ', ')"
                } else {
                    Add-Result 'MCP 冒烟' 'PASS' "协议回显$(if($protocolOk){'正确'}else{'异常'})；工具 $($names.Count) 个（原生+REA）"
                }
            }
        }
    } catch {
        Add-Result 'MCP 冒烟' 'FAIL' $_.Exception.Message
    } finally {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill($true) } catch {} }
    }
}

# ---------------- 4b. 模型路由与会话契约 ----------------
$routeBad = [System.Collections.Generic.List[string]]::new()
$presetPath = if ($verDir) { Join-Path $verDir 'models-preset.ini' } else { Join-Path $Root 'versions\v0.08\models-preset.ini' }
if (-not (Test-Path $presetPath)) {
    $routeBad.Add("缺少内核 models-preset.ini（$presetPath）")
} else {
    $globals = @{}
    $sections = [ordered]@{}
    $cur = ''
    foreach ($line in Get-Content $presetPath -Encoding utf8) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') {
            $cur = $Matches[1].Trim()
            if ($cur -ne '*' -and -not $sections.Contains($cur)) { $sections[$cur] = @{} }
            continue
        }
        if ($cur -and $t -match '^(.*?)=(.*)$') {
            $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
            if ($cur -eq '*') { $globals[$k] = $v } else { $sections[$cur][$k] = $v }
        }
    }
    foreach ($need in 'threads', 'c', 'parallel') {
        if (-not $globals.ContainsKey($need)) { $routeBad.Add("[*] 缺少 $need") }
    }
    if ($sections.Count -eq 0) { $routeBad.Add('preset 中没有任何模型 section') }
    foreach ($name in $sections.Keys) {
        $s = $sections[$name]
        if (-not $s.ContainsKey('model')) { $routeBad.Add("[$name] 缺少 model"); continue }
        if (-not (Test-Path -LiteralPath $s['model'])) { $routeBad.Add("[$name] 模型文件不存在: $($s['model'])") }
        if (-not $s.ContainsKey('n-gpu-layers')) { $routeBad.Add("[$name] 缺少 n-gpu-layers") }
    }
}
$webDir = Join-Path $Root 'product\v1.00\app\web'
$indexHtml = Join-Path $webDir 'index.html'
$appJs = Join-Path $webDir 'app.js'
if (-not (Test-Path $indexHtml)) {
    $routeBad.Add('缺少 product\v1.00\app\web\index.html')
} else {
    $html = Get-Content $indexHtml -Raw -Encoding utf8
    foreach ($needle in '/static/app.js', '/static/style.css', '__PF_TOKEN_VALUE__') {
        if ($html -notmatch [regex]::Escape($needle)) { $routeBad.Add("index.html 缺少 $needle") }
    }
    # 严格 CSP（script-src 'self' / style-src 'self'）下不允许内联脚本与内联样式
    if ($html -match '<script>') { $routeBad.Add('index.html 含内联脚本，违反 CSP') }
    if ($html -match 'style="') { $routeBad.Add('index.html 含内联样式，违反 CSP') }
}
if (-not (Test-Path $appJs)) {
    $routeBad.Add('缺少 product\v1.00\app\web\app.js')
} else {
    $js = Get-Content $appJs -Raw -Encoding utf8
    foreach ($needle in '/api/chat', '/api/boost', '/api/router', '/api/command',
                      '/api/security', '/api/selfcheck', '/api/snapshot') {
        if ($js -notmatch [regex]::Escape($needle)) { $routeBad.Add("前端缺少 $needle") }
    }
}
# 安全基线静态检查：必须存在 Host 校验与恒定时间比较
$secPy = Join-Path $Root 'product\v1.00\app\security.py'
if (-not (Test-Path $secPy)) {
    $routeBad.Add('缺少 product\v1.00\app\security.py')
} else {
    $secTxt = Get-Content $secPy -Raw -Encoding utf8
    if ($secTxt -notmatch 'compare_digest') { $routeBad.Add('鉴权未使用恒定时间比较') }
    if ($secTxt -notmatch 'def host_ok') { $routeBad.Add('缺少 Host 白名单校验') }
    if ($secTxt -notmatch 'CryptProtectData') { $routeBad.Add('缺少 DPAPI 加密') }
}
$serverPy = Join-Path $Root 'product\v1.00\app\server.py'
if ((Test-Path $serverPy) -and -not (Select-String -Path $serverPy -Pattern 'ALLOWED_ACTIONS' -Quiet)) {
    $routeBad.Add('server.py 缺少命令白名单')
}
if ($routeBad.Count -eq 0) {
    Add-Result '路由契约' 'PASS' "preset $($sections.Count) 个模型；前端/服务接口齐全"
} else {
    Add-Result '路由契约' 'FAIL' ($routeBad -join ' ;; ')
}

# ---------------- 4c. 总线鉴权离线回归（14 号：01 三分支拒绝） ----------------
# 说明：pytest 只覆盖 Python 侧；内核 .ps1 长期只有语法检查、无行为覆盖。
# 此项用 AST 从真内核提取 Invoke-CommandBusTick，桩掉 I/O，离线断言三分支文案。
$authTest = Join-Path $PSScriptRoot 'test-bus-auth.ps1'
if (-not (Test-Path -LiteralPath $authTest)) {
    Add-Result '总线鉴权' 'FAIL' '缺少 tests\test-bus-auth.ps1'
} else {
    $selfPwsh = (Get-Process -Id $PID).Path
    $authOut = ''
    Push-Location $Root
    try {
        $authOut = (& $selfPwsh -NoProfile -File $authTest 2>&1) -join "`n"
        $authExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($authExit -eq 0) {
        $tail = (($authOut -split "`r?`n" | Where-Object { $_ -match '^PASS \d+ / FAIL \d+' }) | Select-Object -Last 1)
        Add-Result '总线鉴权' 'PASS' $tail
    } else {
        $badLines = (($authOut -split "`r?`n" | Where-Object { $_ -match '\[FAIL\]|Exception|throw' }) | Select-Object -First 6) -join ' ;; '
        Add-Result '总线鉴权' 'FAIL' $(if ($badLines) { $badLines } else { ($authOut -split "`r?`n" | Select-Object -Last 6) -join ' ;; ' })
    }
}

# ---------------- 4d. 目标定位三分类离线回归（14 号：06 三分支文案） ----------------
# 说明：Get-TargetMissingReply 是纯字符串函数，AST 提取即可离线断言，
# 不需要真实 PID、不碰 commands 目录、不启动内核。
$replyTest = Join-Path $PSScriptRoot 'test-target-missing-reply.ps1'
if (-not (Test-Path -LiteralPath $replyTest)) {
    Add-Result '目标定位分级' 'FAIL' '缺少 tests\test-target-missing-reply.ps1'
} else {
    $selfPwsh = (Get-Process -Id $PID).Path
    $replyOut = ''
    Push-Location $Root
    try {
        $replyOut = (& $selfPwsh -NoProfile -File $replyTest 2>&1) -join "`n"
        $replyExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($replyExit -eq 0) {
        $tail = (($replyOut -split "`r?`n" | Where-Object { $_ -match '^PASS \d+ / FAIL \d+' }) | Select-Object -Last 1)
        Add-Result '目标定位分级' 'PASS' $tail
    } else {
        $badLines = (($replyOut -split "`r?`n" | Where-Object { $_ -match '\[FAIL\]|Exception|throw' }) | Select-Object -First 6) -join ' ;; '
        Add-Result '目标定位分级' 'FAIL' $(if ($badLines) { $badLines } else { ($replyOut -split "`r?`n" | Select-Object -Last 6) -join ' ;; ' })
    }
}
# ---------------- 4e. 心跳节拍离线回归（29 号：写周期 vs 判活窗口） ----------------
# 说明：只读解析内核 TickCount % N 与服务端 15s 判活常量，不启内核、不碰运行态。
$hbTest = Join-Path $PSScriptRoot 'test-heartbeat-cadence.ps1'
if (-not (Test-Path -LiteralPath $hbTest)) {
    Add-Result '心跳节拍' 'FAIL' '缺少 tests\test-heartbeat-cadence.ps1'
} else {
    $selfPwsh = (Get-Process -Id $PID).Path
    $hbOut = ''
    Push-Location $Root
    try {
        $hbOut = (& $selfPwsh -NoProfile -File $hbTest 2>&1) -join "`n"
        $hbExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($hbExit -eq 0) {
        $tail = (($hbOut -split "`r?`n" | Where-Object { $_ -match '^PASS \d+ / FAIL \d+' }) | Select-Object -Last 1)
        $cad = (($hbOut -split "`r?`n" | Where-Object { $_ -match '解析结果' }) | Select-Object -Last 1)
        Add-Result '心跳节拍' 'PASS' $(if ($cad) { $tail + '；' + $cad.Trim() } else { $tail })
    } else {
        $badLines = (($hbOut -split "`r?`n" | Where-Object { $_ -match 'FAIL ' }) | Select-Object -First 4) -join ' ;; '
        Add-Result '心跳节拍' 'FAIL' $(if ($badLines) { $badLines } else { ($hbOut -split "`r?`n" | Select-Object -Last 6) -join ' ;; ' })
    }
}
# ---------------- 4f. 空 action 防御离线回归（14 号：02 四类空输入 + 阴性对照） ----------------
# 说明：AST 提取 Invoke-CommandObject 整个函数定义（空 action 会在 switch 前早退，
# 不产生副作用），桩 Write-Log；断言 缺字段 / null / 纯空白 / 整条 Cmd 为 null 四类回执
# 与 WARN 落点，并用一条未知 action 作阴性对照，防"防御吞掉所有输入"。
$emptyTest = Join-Path $PSScriptRoot 'test-empty-action.ps1'
if (-not (Test-Path -LiteralPath $emptyTest)) {
    Add-Result '空 action 防御' 'FAIL' '缺少 tests\test-empty-action.ps1'
} else {
    $selfPwsh = (Get-Process -Id $PID).Path
    $emptyOut = ''
    Push-Location $Root
    try {
        $emptyOut = (& $selfPwsh -NoProfile -File $emptyTest 2>&1) -join "`n"
        $emptyExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($emptyExit -eq 0) {
        $tail = (($emptyOut -split "`r?`n" | Where-Object { $_ -match '^PASS \d+ / FAIL \d+' }) | Select-Object -Last 1)
        Add-Result '空 action 防御' 'PASS' $tail
    } else {
        $badLines = (($emptyOut -split "`r?`n" | Where-Object { $_ -match '\[FAIL\]|Exception|throw' }) | Select-Object -First 6) -join ' ;; '
        Add-Result '空 action 防御' 'FAIL' $(if ($badLines) { $badLines } else { ($emptyOut -split "`r?`n" | Select-Object -Last 6) -join ' ;; ' })
    }
}
# ---------------- 4g. EcoQoS 入口复查离线回归（14 号：03 PID 复查 + 静默跳过 + 掩码语义） ----------------
# 说明：AST 提取 rules-engine.ps1 的 Set-EcoQos 与 Invoke-RuleAction，同名桩
# PowerFocus.RulesNative（计调用次数/记录入参）与 Get-Process（missing/real/badhandle），
# 断言 不存在→静默跳过 / 存在→设置一次+INFO / 原生 false→不谎报 / 句柄失效→不抛异常
# / On/Off 的 StateMask 真的写进结构。不启内核、不对任何真实进程设置 EcoQoS。
$ecoTest = Join-Path $PSScriptRoot 'test-ecoqos-recheck.ps1'
if (-not (Test-Path -LiteralPath $ecoTest)) {
    Add-Result 'EcoQoS 复查' 'FAIL' '缺少 tests\test-ecoqos-recheck.ps1'
} else {
    $selfPwsh = (Get-Process -Id $PID).Path
    $ecoOut = ''
    Push-Location $Root
    try {
        $ecoOut = (& $selfPwsh -NoProfile -File $ecoTest 2>&1) -join "`n"
        $ecoExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($ecoExit -eq 0) {
        $tail = (($ecoOut -split "`r?`n" | Where-Object { $_ -match '^PASS \d+ / FAIL \d+' }) | Select-Object -Last 1)
        Add-Result 'EcoQoS 复查' 'PASS' $tail
    } else {
        $badLines = (($ecoOut -split "`r?`n" | Where-Object { $_ -match '\[FAIL\]|Exception|throw' }) | Select-Object -First 6) -join ' ;; '
        Add-Result 'EcoQoS 复查' 'FAIL' $(if ($badLines) { $badLines } else { ($ecoOut -split "`r?`n" | Select-Object -Last 6) -join ' ;; ' })
    }
}
# ---------------- 4h. Invoke-Native 丢参离线回归（35 号：参数名撞自动变量 $args） ----------------
# 说明：AST 提取内核 Invoke-Native 整段定义 dot-source；用真实只读命令验证参数是否落地
# （whoami /user 应出 SID 表、whoami /groups >500 字符、powercfg /getactivescheme 应含 GUID
# 且不是「参数无效」），外加失败路径留痕、空参数照旧、结构锁（参数不叫 Args + [Alias('Args')]
# + @ArgList + 无 @Args）与 4 处调用点兼容性。不调 /setactive（不改用户电源计划）。
$natTest = Join-Path $PSScriptRoot 'test-native-args.ps1'
if (-not (Test-Path -LiteralPath $natTest)) {
    Add-Result '原生命令传参' 'FAIL' '缺少 tests\test-native-args.ps1'
} else {
    $selfPwsh = (Get-Process -Id $PID).Path
    $natOut = ''
    Push-Location $Root
    try {
        $natOut = (& $selfPwsh -NoProfile -File $natTest 2>&1) -join "`n"
        $natExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $tail = (($natOut -split "`r?`n" | Where-Object { $_ -match 'RESULT: PASS=\d+ FAIL=\d+' }) | Select-Object -Last 1)
    if ($natExit -eq 0) {
        Add-Result '原生命令传参' 'PASS' $tail
    } else {
        $badLines = (($natOut -split "`r?`n" | Where-Object { $_ -match '\[FAIL\]|Exception|throw' }) | Select-Object -First 6) -join ' ;; '
        Add-Result '原生命令传参' 'FAIL' $(if ($badLines) { $badLines } else { ($natOut -split "`r?`n" | Select-Object -Last 6) -join ' ;; ' })
    }
}
# ---------------- 4i. 电源计划双守卫 + fail-closed + Restore 失败分支离线回归（36/37 号） ----------------
# 说明：AST 从真内核取 Set-PowerPlanHigh / Restore-PowerPlan；同名函数遮蔽 powercfg
# （不执行任何真实电源操作），桩 Invoke-Native（[Alias('Args')]，记录参数内容）与 Write-Log。
# 覆盖：守卫①已是高性能 0 次 / 守卫②计划缺失 0 次 / 正常切换参数含 GUID（验内容不数次数）/
# getactivescheme 失败与解析失败均 fail-closed 不切 / native 失败保留原计划 /
# Restore 成功、空计划、失败三路（37 号：失败须 WARN 且保留 OriginalPlan）；附 10 条结构锁。
$ppTest = Join-Path $PSScriptRoot 'test-power-plan-guard.ps1'
if (-not (Test-Path -LiteralPath $ppTest)) {
    Add-Result '电源计划守卫' 'FAIL' '缺少 tests\test-power-plan-guard.ps1'
} else {
    $selfPwsh2 = (Get-Process -Id $PID).Path
    $ppOut = ''
    Push-Location $Root
    try {
        $ppOut = (& $selfPwsh2 -NoProfile -File $ppTest 2>&1) -join "`n"
        $ppExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $ppTail = (($ppOut -split "`r?`n" | Where-Object { $_ -match 'RESULT: PASS=\d+ FAIL=\d+' }) | Select-Object -Last 1)
    if ($ppExit -eq 0) {
        Add-Result '电源计划守卫' 'PASS' $ppTail
    } else {
        $ppBad = (($ppOut -split "`r?`n" | Where-Object { $_ -match '^\s+FAIL |Exception|throw' }) | Select-Object -First 6) -join ' ;; '
        Add-Result '电源计划守卫' 'FAIL' $(if ($ppBad) { $ppBad } else { ($ppOut -split "`r?`n" | Select-Object -Last 6) -join ' ;; ' })
    }
}
# ---------------- 4j. MemGuard 离线行为回归（14-4 / 09-10） ----------------
# 说明：AST 提取 mem-guard 的 Invoke-GuardCycle / Write-MgCycleLog / Get-AncestorSet，
# 同名桩原生层（OpenProcess/EmptyWorkingSet 计次+可控失败）、采样与进程/网络/前台；
# 覆盖 idle 不压制、warn 选优、critical 抬上限、提交额度告警节流、原生失败不计数、
# 冷却窗、freedMB 字节整数累加、提权汇总窗口与结构锁。不启模型、不碰真实进程。
$mgTest = Join-Path $PSScriptRoot 'test-mem-guard-offline.ps1'
if (-not (Test-Path -LiteralPath $mgTest)) {
    Add-Result '内存守护离线' 'FAIL' '缺少 tests\test-mem-guard-offline.ps1'
} else {
    $selfPwsh3 = (Get-Process -Id $PID).Path
    $mgOut = ''
    Push-Location $Root
    try {
        $mgOut = (& $selfPwsh3 -NoProfile -File $mgTest 2>&1) -join "`n"
        $mgExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $mgTail = (($mgOut -split "`r?`n" | Where-Object { $_ -match 'RESULT: PASS=\d+ FAIL=\d+' }) | Select-Object -Last 1)
    if ($mgExit -eq 0) {
        Add-Result '内存守护离线' 'PASS' $mgTail
    } else {
        $mgBad = (($mgOut -split "`r?`n" | Where-Object { $_ -match '\[FAIL\]|Exception|throw' }) | Select-Object -First 6) -join ' ;; '
        Add-Result '内存守护离线' 'FAIL' $(if ($mgBad) { $mgBad } else { ($mgOut -split "`r?`n" | Select-Object -Last 6) -join ' ;; ' })
    }
}
# ---------------- 4k. 前端回归（node:test，零依赖） ----------------
# 46 号轮接入。桩在 tests/js/pf-dom-stub.mjs，断言在 tests/js/frontend.test.mjs。
# 缺 node 或缺测试文件都按 SKIP；测试红就是功能红，不许静默跳过。
$feTest = Join-Path $PSScriptRoot 'js\frontend.test.mjs'
$feNode = Get-Command node -ErrorAction SilentlyContinue
if (-not $feNode) {
    Add-Result '前端回归' 'SKIP' '缺少 node（node --test 不可用）'
} elseif (-not (Test-Path -LiteralPath $feTest)) {
    Add-Result '前端回归' 'SKIP' "缺 $feTest（46 号测试未入库）"
} else {
    $feRaw = & $feNode.Source --test $feTest 2>&1
    $feCode = $LASTEXITCODE
    $feText = ($feRaw | Out-String)
    $fePass = if ($feText -match '[#\u2139]\s+pass (\d+)') { $Matches[1] } else { '?' }
    $feFail = if ($feText -match '[#\u2139]\s+fail (\d+)') { $Matches[1] } else { '?' }
    if ($feCode -eq 0 -and $fePass -ne '?' -and $feFail -eq '0') {
        Add-Result '前端回归' 'PASS' "node --test pass=$fePass fail=$feFail；exit=$feCode"
    } else {
        $feBad = ($feText -split "`r?`n" | Where-Object { $_ -match '^\s*not ok ' -or $_ -match '^\s+error:' } | Select-Object -First 3) -join ' | '
        if (-not $feBad) { $feBad = ($feText -split "`r?`n" | Select-Object -Last 3) -join ' | ' }
        Add-Result '前端回归' 'FAIL' "exit=$feCode；pass=$fePass fail=$feFail；$feBad"
    }
}

# ---------------- 4l. 前端交互回归（48 号，node --test 真实监听器） ----------------
# 与 4k 同一套桩（tests/js/pf-dom-stub.mjs v2），但测的是交互层：navbtn 点击、
# 1-8 数字键、确认框的 resolve 语义、总览卡片→进程视图的选中链路、双击终止。
# 缺 node 或缺测试文件都 SKIP；测试红就是功能红，不许静默跳过。
$ixTest = Join-Path $PSScriptRoot 'js\interaction.test.mjs'
$ixNode = Get-Command node -ErrorAction SilentlyContinue
if (-not $ixNode) {
    Add-Result '前端交互回归' 'SKIP' '缺少 node（node --test 不可用）'
} elseif (-not (Test-Path -LiteralPath $ixTest)) {
    Add-Result '前端交互回归' 'SKIP' "缺 $ixTest（48 号测试未入库）"
} else {
    $ixRaw = & $ixNode.Source --test $ixTest 2>&1
    $ixCode = $LASTEXITCODE
    $ixText = ($ixRaw | Out-String)
    $ixPass = if ($ixText -match '[#\u2139] pass (\d+)') { $Matches[1] } else { '?' }
    $ixFail = if ($ixText -match '[#\u2139] fail (\d+)') { $Matches[1] } else { '?' }
    if ($ixCode -eq 0 -and $ixPass -ne '?' -and $ixFail -eq '0') {
        Add-Result '前端交互回归' 'PASS' "node --test pass=$ixPass fail=$ixFail；exit=$ixCode"
    } else {
        $ixBad = ($ixText -split "`r?`n" | Where-Object { $_ -match '^\s*not ok ' -or $_ -match '^\s+error:' } | Select-Object -First 3) -join ' | '
        if (-not $ixBad) { $ixBad = ($ixText -split "`r?`n" | Select-Object -Last 3) -join ' | ' }
        Add-Result '前端交互回归' 'FAIL' "exit=$ixCode；pass=$ixPass fail=$ixFail；$ixBad"
    }
}

# ---------------- 4m. I/O 优先级失败分级离线回归（14 号余项 / 73 号轮） ----------------
# 说明：AST 提取内核 Enable-IoBoostPrivilege / Get-IoFailureText / Set-IoPriority；
# 同名桩 PowerFocus.Native（OpenProcess / NtSetInformationProcess / CloseHandle，记录
# access/class/value/length 与调用次数）与 PowerFocus.Priv（EnableIoBoost 可控返回
# 0/1300/1314/其它或抛异常）、Get-Process、Write-Log。覆盖 0xC0000061→PrivilegeNotHeld、
# 0xC0000022→AccessDenied、其它 NTSTATUS→Other、句柄打开失败→AccessDenied、进程退出→Exited、
# 异常→Error、仅 High 启用特权、特权缓存幂等、finally 必关句柄与三类文案。
$ioTest = Join-Path $PSScriptRoot 'test-io-priority-grading.ps1'
if (-not (Test-Path -LiteralPath $ioTest)) {
    Add-Result 'I/O 优先级分级' 'FAIL' '缺少 tests\test-io-priority-grading.ps1'
} else {
    $selfPwsh4 = (Get-Process -Id $PID).Path
    $ioOut = ''
    Push-Location $Root
    try {
        $ioOut = (& $selfPwsh4 -NoProfile -File $ioTest 2>&1) -join "`n"
        $ioExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $ioTail = (($ioOut -split "`r?`n" | Where-Object { $_ -match 'RESULT: PASS=\d+ FAIL=\d+' }) | Select-Object -Last 1)
    if ($ioExit -eq 0) {
        Add-Result 'I/O 优先级分级' 'PASS' $ioTail
    } else {
        $ioBad = (($ioOut -split "`r?`n" | Where-Object { $_ -match '\[FAIL\]|Exception|throw' }) | Select-Object -First 6) -join ' ;; '
        Add-Result 'I/O 优先级分级' 'FAIL' $(if ($ioBad) { $ioBad } else { ($ioOut -split "`r?`n" | Select-Object -Last 6) -join ' ;; ' })
    }
}

# ---------------- 5. 仓库卫生 ----------------
if (Test-Path (Join-Path $Root '.git')) {
    $tracked = @(git -C $Root ls-files)
    # 拦的是运行态 / 密钥文件（心跳 JSON、日志、锁、令牌），不是测试脚本：
    # 旧规则裸匹配 heartbeat，会把 52 号轮的回归测试 tests/test-heartbeat-cadence.ps1 误判成泄露。
    $leak = @($tracked | Where-Object { $_ -match 'auth_token|\.log$|heartbeat[^/]*\.json$|rules_state|\.lock$' })
    $ignoredOk = (Test-Path (Join-Path $Root '.gitignore'))
    if ($leak.Count -gt 0) {
        Add-Result '仓库卫生' 'FAIL' "运行态/密钥被跟踪：$($leak -join ', ')"
    } elseif (-not $ignoredOk) {
        Add-Result '仓库卫生' 'FAIL' '缺少 .gitignore'
    } else {
        $dirty = @(git -C $Root status --porcelain).Count
        Add-Result '仓库卫生' 'PASS' "已跟踪 $($tracked.Count) 个文件；未提交改动 $dirty 个"
    }
} else {
    Add-Result '仓库卫生' 'SKIP' '当前目录不是 git 仓库'
}

# ---------------- 6. 工具对齐（判"真实工具可用"，不判"裸命令长得像不像"） ----------------
# 32 号：宿主会话会把 python 注入成沙箱别名，裸 `Get-Command python` 的 .Source 恒为空；
# 旧的 `.Source` 判据据此误报"python 未找到"。改由 env.ps1 的 Get-ToolAlignment 判定：
# 真实路径（已排除盒内）+ 实跑版本命令；裸命令现状只作诊断写进回执，不参与判死。
$align = Get-ToolAlignment
if ($align.Ok) {
    Add-Result '工具对齐' 'PASS' $align.Detail
} else {
    Add-Result '工具对齐' 'FAIL' $align.Detail
}

# ---------------- 汇总 ----------------
$sw.Stop()
$fail = @($results | Where-Object Status -eq 'FAIL')
foreach ($r in $results) {
    $color = switch ($r.Status) { 'PASS' { 'Green' } 'SKIP' { 'DarkGray' } 'FAIL' { 'Red' } default { 'Yellow' } }
    Write-Host ($r.Status.PadRight(4) + " ") -ForegroundColor $color -NoNewline
    Write-Host ("{0,-12} {1}" -f $r.Name, $r.Detail)
}
$pass = @($results | Where-Object Status -eq 'PASS').Count
Write-Host ""
Write-Host ("PASS {0} / FAIL {1} / 耗时 {2:N1}s" -f $pass, $fail.Count, $sw.Elapsed.TotalSeconds) -ForegroundColor $(if ($fail.Count) { 'Red' } else { 'Green' })

exit $(if ($fail.Count -gt 0) { 1 } else { 0 })
