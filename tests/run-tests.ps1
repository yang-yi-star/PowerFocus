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
$jsonSpec = [ordered]@{
    'v3\model-profiles.json' = 'powerfocus/model-profiles/v2'
    'v2\rules.json'          = $null
    'v3\rules.json'          = $null
    'v2\scenes.json'         = $null
    'v2\authorized_apps.json' = $null
}
$jsonBad = [System.Collections.Generic.List[string]]::new()
foreach ($rel in $jsonSpec.Keys) {
    $p = Join-Path $Root $rel
    if (-not (Test-Path $p)) { $jsonBad.Add("$rel 缺少文件"); continue }
    try {
        $obj = Get-Content $p -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        $jsonBad.Add("$rel 不是合法 JSON: $($_.Exception.Message)"); continue
    }
    $want = $jsonSpec[$rel]
    if ($want -and $obj.schema -ne $want) { $jsonBad.Add("$rel schema=$($obj.schema) 期望 $want") }
}
if ($jsonBad.Count -eq 0) {
    Add-Result 'JSON 契约' 'PASS' "$($jsonSpec.Count) 个配置合法"
} else {
    Add-Result 'JSON 契约' 'FAIL' ($jsonBad -join ' ;; ')
}

# ---------------- 3. Python 编译 ----------------
$py = Get-DevPython
$mcpPath = Join-Path $Root 'mcp-server.py'
if (-not $py) {
    Add-Result 'Python 编译' 'FAIL' '未找到可用 Python 解释器'
} else {
    $tmp = Join-Path $env:TEMP ("pf-compile-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $outTxt = (& $py -c "import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)" $mcpPath (Join-Path $tmp 'mcp.pyc') 2>&1) -join "`n"
        if ($LASTEXITCODE -eq 0) {
            Add-Result 'Python 编译' 'PASS' "mcp-server.py 编译通过（$py）"
        } else {
            Add-Result 'Python 编译' 'FAIL' $outTxt
        }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------- 4. MCP stdio 冒烟 ----------------
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
                $need = @('power_status', 'power_request', 'power_release', 'rules_list', 'rea_status')
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

# ---------------- 6. 工具对齐（系统新版压过盒子自带旧版） ----------------
$pyPin = Get-DevPython
$nodePin = Get-DevNode
$reaPin = Get-DevRea
$cmdPy = (Get-Command python -ErrorAction SilentlyContinue).Source
$cmdNode = (Get-Command node -ErrorAction SilentlyContinue).Source
$cmdRea = (Get-Command rea -ErrorAction SilentlyContinue).Source
$bad = [System.Collections.Generic.List[string]]::new()
if (-not $pyPin -or $cmdPy -ne $pyPin) { $bad.Add("python 实际命中 $cmdPy，期望 $pyPin") }
if (-not $nodePin -or $cmdNode -ne $nodePin) { $bad.Add("node 实际命中 $cmdNode，期望 $nodePin") }
if (-not $reaPin) {
    $bad.Add('找不到全局逆向引擎')
} elseif ($cmdRea) {
    $reaDir = Split-Path -Parent $cmdRea
    if ($reaDir -ne (Split-Path -Parent $reaPin)) { $bad.Add("rea 实际命中 $cmdRea，期望 $reaPin 同目录") }
    if ($cmdRea -match 'sandbox_runtime') { $bad.Add("rea 命中盒子自带版本：$cmdRea") }
}
if ($bad.Count -gt 0) {
    Add-Result '工具对齐' 'FAIL' ($bad -join ' ;; ')
} else {
    Add-Result '工具对齐' 'PASS' "python=$pyPin；node=$nodePin；rea=$reaPin"
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
