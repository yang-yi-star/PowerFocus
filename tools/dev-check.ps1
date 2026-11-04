#Requires -Version 7.0
<#
============================================================
 PowerFocus 开发环境自检（dev-check）
 用法：pwsh -File E:\PowerFocus\tools\dev-check.ps1
       pwsh -File E:\PowerFocus\tools\dev-check.ps1 -Json
 退出码：0 = 通过（可含 WARN）；1 = 存在 FAIL
============================================================
#>
[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$items = [System.Collections.Generic.List[object]]::new()

function Add-Item {
    param([string]$Group, [string]$Name, [string]$Status, [string]$Detail)
    $items.Add([pscustomobject]@{ Group = $Group; Name = $Name; Status = $Status; Detail = $Detail })
}

. (Join-Path $PSScriptRoot 'env.ps1')

# ---------------- 一、工具链 ----------------
$psv = $PSVersionTable.PSVersion
Add-Item '工具链' 'pwsh' $(if ($psv.Major -ge 7) { 'PASS' } else { 'FAIL' }) "$psv（要求 7+，禁用 Windows PowerShell 5.1）"

$py = Get-DevPython
if ($py) {
    $pyv = (& $py --version 2>&1) -join ''
    Add-Item '工具链' 'python' 'PASS' "$pyv  @ $py"
} else {
    Add-Item '工具链' 'python' 'FAIL' '未找到 D:\Python313 或本机 Python 3.11/3.12'
}
$shim = (Get-Command python -ErrorAction SilentlyContinue).Source
if ($shim -and $shim -match 'sandbox_runtime') {
    Add-Item '工具链' 'python 别名' 'WARN' "PATH 上的 python 指向沙箱：$shim；脚本内请显式使用绝对路径"
} elseif ($shim) {
    Add-Item '工具链' 'python 别名' 'PASS' $shim
}

$nodeSys = 'C:\Program Files\nodejs\node.exe'
if (Test-Path $nodeSys) {
    Add-Item '工具链' 'node' 'PASS' "$((& $nodeSys --version) -join '') @ $nodeSys"
    $nodePath = (Get-Command node -ErrorAction SilentlyContinue).Source
    if ($nodePath -and $nodePath -match 'sandbox_runtime') {
        Add-Item '工具链' 'node 别名' 'WARN' "PATH 上的 node 指向沙箱（$(& node --version)）：$nodePath"
    }
} else {
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    Add-Item '工具链' 'node' $(if ($nodeCmd) { 'WARN' } else { 'FAIL' }) $(if ($nodeCmd) { "仅 PATH 版本 $(& node --version)，未见 C:\Program Files\nodejs" } else { '未安装（REA / MCP 生态需要）' })
}

$reaPkg = Join-Path $env:APPDATA 'npm\node_modules\rea-agents\package.json'
if (Test-Path $reaPkg) {
    $reaVer = (Get-Content $reaPkg -Raw -Encoding utf8 | ConvertFrom-Json).version
    Add-Item '工具链' 'rea（全局）' 'PASS' "$reaVer @ $env:APPDATA\npm\rea.cmd"
} else {
    Add-Item '工具链' 'rea（全局）' 'WARN' '未安装 rea-agents（MCP 将缺少 rea__ 工具）'
}
$reaPath = (Get-Command rea -ErrorAction SilentlyContinue).Source
if ($reaPath -and $reaPath -match 'sandbox_runtime') {
    Add-Item '工具链' 'rea 别名' 'WARN' "PATH 上的 rea 是沙箱版 $(& rea --version 2>$null)：$reaPath（MCP 的 _find_rea 会优先命中它）"
}

$git = (Get-Command git -ErrorAction SilentlyContinue)
Add-Item '工具链' 'git' $(if ($git) { 'PASS' } else { 'FAIL' }) $(if ($git) { (& git --version) } else { '未安装' })

$llama = 'E:\Program Files\llama.cpp\bin\llama-server.exe'
Add-Item '工具链' 'llama-server' $(if (Test-Path $llama) { 'PASS' } else { 'WARN' }) $llama

# ---------------- 二、关键文件 ----------------
$required = [ordered]@{
    'MCP 服务'      = 'mcp-server.py'
    'v2 主脚本'     = 'v2\电脑算力调度中心_v2.ps1'
    'v3 主脚本'     = 'v3\电脑算力调度中心_v3.ps1'
    '根转发壳'      = '电脑算力调度中心.ps1'
    '模型注册表'    = 'v3\model-profiles.json'
    '模型档案模块'  = 'v3\lib\model-registry.ps1'
    '回滚模块'      = 'v3\lib\rollback.ps1'
    '规则引擎'      = 'v2\rules-engine.ps1'
    '开发日志'      = 'DEVELOPMENT_LOG.md'
    '测试入口'      = 'tests\run-tests.ps1'
    '规范文档'      = 'docs\DEVELOPING.md'
}
foreach ($k in $required.Keys) {
    $p = Join-Path $Root $required[$k]
    Add-Item '关键文件' $k $(if (Test-Path $p) { 'PASS' } else { 'FAIL' }) $required[$k]
}

# ---------------- 三、运行态 ----------------
foreach ($port in 8080, 8686) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) {
        $pname = (Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        Add-Item '运行态' "端口 $port" 'PASS' "监听中 PID=$($conn.OwningProcess) $pname"
    } else {
        Add-Item '运行态' "端口 $port" 'WARN' '未监听（推理服务未启动）'
    }
}

$hb = Join-Path $Root 'v2\v2_heartbeat.json'
if (Test-Path $hb) {
    try {
        $h = Get-Content $hb -Raw -Encoding utf8 | ConvertFrom-Json
        $alive = $null -ne (Get-Process -Id $h.pid -ErrorAction SilentlyContinue)
        $age = [math]::Round(((Get-Date) - (Get-Item $hb).LastWriteTime).TotalSeconds, 0)
        Add-Item '运行态' 'v2 心跳' $(if ($alive) { 'PASS' } else { 'WARN' }) "pid=$($h.pid) tick=$($h.tick) 心跳距今 ${age}s"
    } catch {
        Add-Item '运行态' 'v2 心跳' 'WARN' "无法解析：$($_.Exception.Message)"
    }
} else {
    Add-Item '运行态' 'v2 心跳' 'WARN' '无心跳文件（v2 未运行）'
}

$lock = Join-Path $Root 'v3\.v3.lock'
if (Test-Path $lock) {
    try {
        $fs = [System.IO.File]::Open($lock, 'Open', 'ReadWrite', 'None')
        $fs.Dispose()
        Add-Item '运行态' 'v3 单实例锁' 'PASS' '锁文件存在但无进程持有（陈旧文件，可忽略）'
    } catch {
        Add-Item '运行态' 'v3 单实例锁' 'WARN' '锁被独占占用：v3 正在运行'
    }
} else {
    Add-Item '运行态' 'v3 单实例锁' 'PASS' '无锁，v3 未占用'
}

$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) {
    try {
        $line = (& nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free --format=csv,noheader) -join ' '
        Add-Item '运行态' 'GPU' 'PASS' $line
    } catch {
        Add-Item '运行态' 'GPU' 'WARN' 'nvidia-smi 调用失败'
    }
} else {
    Add-Item '运行态' 'GPU' 'WARN' '无 nvidia-smi'
}

# ---------------- 四、版本控制 ----------------
if (Test-Path (Join-Path $Root '.git')) {
    $branch = (git -C $Root branch --show-current)
    $last = (git -C $Root log -1 --oneline 2>$null)
    $dirty = @(git -C $Root status --porcelain)
    Add-Item '版本控制' '仓库' 'PASS' "分支 $branch；最近提交：$(if ($last) { $last } else { '（空仓）' })"
    Add-Item '版本控制' '工作区' $(if ($dirty.Count -eq 0) { 'PASS' } else { 'WARN' }) "未提交改动 $($dirty.Count) 个文件"
    $leak = @(git -C $Root ls-files | Where-Object { $_ -match 'auth_token|\.log$|heartbeat|rules_state' })
    Add-Item '版本控制' '敏感/运行态入库' $(if ($leak.Count -eq 0) { 'PASS' } else { 'FAIL' }) $(if ($leak.Count -eq 0) { '无泄漏' } else { ($leak -join ', ') })
} else {
    Add-Item '版本控制' '仓库' 'FAIL' '未执行 git init'
}

# ---------------- 输出 ----------------
$fail = @($items | Where-Object Status -eq 'FAIL')
$warn = @($items | Where-Object Status -eq 'WARN')

if ($Json) {
    [pscustomobject]@{
        time   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        root   = $Root
        pass   = @($items | Where-Object Status -eq 'PASS').Count
        warn   = $warn.Count
        fail   = $fail.Count
        items  = $items
    } | ConvertTo-Json -Depth 4
} else {
    $group = $null
    foreach ($i in $items) {
        if ($i.Group -ne $group) { $group = $i.Group; Write-Host ""; Write-Host "[$group]" -ForegroundColor Cyan }
        $color = switch ($i.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
        $tag = $i.Status.PadRight(4)
        Write-Host "  " -NoNewline
        Write-Host $tag -ForegroundColor $color -NoNewline
        Write-Host " $($i.Name.PadRight(16)) $($i.Detail)"
    }
    Write-Host ""
    Write-Host ("PASS {0} / WARN {1} / FAIL {2}" -f @($items | Where-Object Status -eq 'PASS').Count, $warn.Count, $fail.Count) -ForegroundColor $(if ($fail.Count) { 'Red' } else { 'Green' })
}

exit $(if ($fail.Count -gt 0) { 1 } else { 0 })
