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

# ---------------- 5. 仓库卫生 ----------------
if (Test-Path (Join-Path $Root '.git')) {
    $tracked = @(git -C $Root ls-files)
    $leak = @($tracked | Where-Object { $_ -match 'auth_token|\.log$|heartbeat|rules_state|\.lock$' })
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

# ---------------- 6. 工具对齐（裸命令不得命中盒子自带旧版） ----------------
$resolved = [ordered]@{
    python = (Get-Command python -ErrorAction SilentlyContinue).Source
    node   = (Get-Command node -ErrorAction SilentlyContinue).Source
    rea    = (Get-Command rea -ErrorAction SilentlyContinue).Source
}
$bad = [System.Collections.Generic.List[string]]::new()
foreach ($k in $resolved.Keys) {
    if (-not $resolved[$k]) { $bad.Add("$k 未找到") }
    elseif (Test-InBox $resolved[$k]) { $bad.Add("$k 命中盒子自带版本：$($resolved[$k])") }
}
if ($bad.Count -gt 0) {
    Add-Result '工具对齐' 'FAIL' ($bad -join ' ;; ')
} else {
    Add-Result '工具对齐' 'PASS' "python=$($resolved.python)；node=$($resolved.node)；rea=$($resolved.rea)"
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
