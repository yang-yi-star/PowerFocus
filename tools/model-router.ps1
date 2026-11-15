#Requires -Version 7.0
# ============================================================
# model-router.ps1 — 本地模型路由（llama-server router 模式）启停器
# 职责：以当前内核（versions\current.json 指向）的 models-preset.ini 为唯一参数源，
#       启动/停止/查询 OpenAI 兼容路由服务。
# 铁律：
#   1. 只管理本脚本启动的进程（PID 文件 + 命令行双校验），绝不杀无关 llama-server。
#   2. 端口被他人占用时直接报错退出，不抢占、不重试。
#   3. --models-max 1：8GB 显存一次只驻留一个模型（与 v3 单模型优先约束一致）。
# 用法：
#   pwsh -File tools\model-router.ps1 -Action start [-Model Qwen3-4B] [-Port 8080]
#   pwsh -File tools\model-router.ps1 -Action stop
#   pwsh -File tools\model-router.ps1 -Action status [-Json]
#   pwsh -File tools\model-router.ps1 -Action logs [-Tail 40]
# ============================================================
param(
    [ValidateSet('start', 'stop', 'status', 'logs', 'boost', 'restore')]
    [string]$Action = 'status',
    [string]$Model = '',
    [int]$Port = 8080,
    [int]$TimeoutSec = 60,
    [int]$Tail = 40,
    [switch]$Json,
    # --- boost / restore 专用（由 v3 boost_model 按注册表档位传入）---
    [string]$ModelFile = '',
    [int]$Ngl = -1,
    [int]$Ctx = 0,
    [string]$FlashAttn = '',
    [string]$CacheTypeK = '',
    [string]$CacheTypeV = '',
    [int]$Threads = 0,
    [int]$ThreadsBatch = 0,
    [string]$Alias = '',
    [string]$CommandLine = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root      = Split-Path $PSScriptRoot -Parent
$Exe       = 'E:\Program Files\llama.cpp\bin\llama-server.exe'

function Get-KernelDir {
    # 内核参数源跟随 versions\current.json 指针；不再假设存在 v3\ 目录。
    $vers = Join-Path $Root 'versions'
    $ptr  = Join-Path $vers 'current.json'
    if (Test-Path -LiteralPath $ptr) {
        $v = (Get-Content -LiteralPath $ptr -Raw -Encoding utf8 | ConvertFrom-Json).version
        if ($v -and (Test-Path -LiteralPath (Join-Path $vers $v))) { return (Join-Path $vers $v) }
    }
    $newest = Get-ChildItem $vers -Directory -Filter 'v*' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if ($newest) { return $newest.FullName }
    return (Join-Path $Root 'v3')
}

$KernelDir = Get-KernelDir
$Preset    = Join-Path $KernelDir 'models-preset.ini'
$PidFile   = Join-Path $KernelDir 'router.pid'
$LogDir    = Join-Path $Root 'logs'
$RouterLog = Join-Path $LogDir 'router.log'
$BaseUrl   = "http://127.0.0.1:$Port"

# ---- 本地模型服务鉴权（安全基线） ----
# llama-server 默认无鉴权且 CORS 全放开：任何本机进程、任何网页都能白嫖算力，
# 甚至可能被 DNS 重绑定的网页读到推理结果。这里强制生成/复用本机密钥，
# 启动参数加 --api-key-file，CORS 只反射 localhost 来源。
$KeyFile = Join-Path $Root '.model_key'

function Initialize-ModelKey {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $k = (Get-Content -LiteralPath $Path -Raw -Encoding utf8).Trim()
        if ($k) { return $k }
    }
    $k = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $Path -Value $k -Encoding utf8 -NoNewline
    try { & icacls $Path /inheritance:r /grant:r ("{0}:(R,W)" -f $env:USERNAME) 2>$null | Out-Null } catch {}
    return $k
}

$ModelKey = Initialize-ModelKey -Path $KeyFile
$AuthHeaders = @{ Authorization = "Bearer $ModelKey" }

function Test-RouterProcess {
    # 判定「本脚本启动」的唯一指纹：命令行里的 --log-file 指向本脚本的 router.log。
    # 主 preset、boost 单模型两种启动方式都带这个参数，且路径全机唯一，不会误认他人的 llama-server。
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    $vp = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $vp -or $vp.ProcessName -ne 'llama-server') { return $null }
    try {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop).CommandLine
        $flat = [string]$cmd -replace '"', ''
        if ($flat.Contains('--log-file ' + $RouterLog)) { return $vp }
    } catch {}
    return $null
}

function Get-RouterPid {
    if (-not (Test-Path -LiteralPath $PidFile)) { return 0 }
    $raw = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue)
    $n = 0
    if ([int]::TryParse(([string]$raw).Trim(), [ref]$n)) { return $n }
    return 0
}

function Get-PortOwner {
    try {
        $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return [int]$c.OwningProcess }
    } catch {}
    return 0
}

function Test-Health {
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/health" -TimeoutSec 3 -Headers $AuthHeaders -ErrorAction Stop
        return ($r -ne $null)
    } catch { return $false }
}

function Get-LoadedModels {
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/v1/models" -TimeoutSec 5 -Headers $AuthHeaders -ErrorAction Stop
        return @($r.data | ForEach-Object { $_.id })
    } catch { return @() }
}

function Get-GpuMiB {
    try {
        $s = & nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits 2>$null | Select-Object -First 1
        if ($s -match '(\d+)\s*,\s*(\d+)') {
            return [pscustomobject]@{ used = [int]$Matches[1]; free = [int]$Matches[2] }
        }
    } catch {}
    return $null
}

function Read-PresetSections {
    # 解析 INI：返回 [*] 全局键值 + 每个 section 的键值（保留原生键名，供临时 preset 复用）
    param([string]$Path)
    $globals = [ordered]@{}
    $sections = [ordered]@{}
    $cur = $null
    $curName = ''
    foreach ($line in Get-Content -LiteralPath $Path -Encoding utf8) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $curName = $Matches[1].Trim()
            if ($curName -eq '*') { $cur = 'GLOBAL' } else { $cur = 'SECTION' }
            if ($cur -eq 'SECTION' -and -not $sections.Contains($curName)) { $sections[$curName] = [ordered]@{} }
            continue
        }
        if ($t -match '^(.*?)=(.*)$') {
            $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
            if ($cur -eq 'GLOBAL') { $globals[$k] = $v }
            elseif ($cur -eq 'SECTION') { $sections[$curName][$k] = $v }
        }
    }
    return [pscustomobject]@{ globals = $globals; sections = $sections }
}

function Get-PresetSource {
    # 通用化（任何电脑/服务器可用）：内置 models-preset.ini 只是模板，
    # 本机实际模型清单可能完全不同。查找顺序：
    #   1. <仓库根>\models-preset.local.ini   （本机私有，gitignore，优先）
    #   2. <内核目录>\models-preset.local.ini （数据目录侧本机私有）
    #   3. <内核目录>\models-preset.ini       （内置模板）
    $candidates = @(
        (Join-Path $Root 'models-preset.local.ini'),
        (Join-Path $KernelDir 'models-preset.local.ini'),
        $Preset
    )
    $src = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $src) { throw "找不到模型预设：$Preset（也可在仓库根创建 models-preset.local.ini）" }
    return $src
}

function New-EffectivePreset {
    # 存在性过滤：只把 model 文件真实存在的条目写进运行时 ini。
    # 换机后缺失的条目自动跳过而不是让 llama-server 启动失败；
    # 全部缺失时给出可操作的配置指引。全部可用时直接复用原文件（零开销）。
    param($Parsed, [string]$Source)
    $keep = @()
    foreach ($name in $Parsed.sections.Keys) {
        $mp = [string]$Parsed.sections[$name]['model']
        if ($mp -and (Test-Path -LiteralPath $mp)) { $keep += $name }
    }
    if (-not $keep) {
        throw ("预设 {0} 里的模型文件在本机都不存在。" -f $Source) +
              "请在仓库根创建 models-preset.local.ini（参照 models-preset.ini 格式），把 model 指向本机 gguf 路径。"
    }
    if (@($keep).Count -eq @($Parsed.sections.Keys).Count) { return $Source }

    $dir = Join-Path $Root 'out'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'router-preset-effective.ini'
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("; 运行时 preset（model-router.ps1 按本机文件存在性过滤生成，勿手改）")
    [void]$sb.AppendLine("version = 1")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("[*]")
    foreach ($k in $Parsed.globals.Keys) { [void]$sb.AppendLine("$k = $($Parsed.globals[$k])") }
    foreach ($name in $keep) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("[$name]")
        foreach ($k in $Parsed.sections[$name].Keys) { [void]$sb.AppendLine("$k = $($Parsed.sections[$name][$k])") }
    }
    [System.IO.File]::WriteAllText($path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    # 诊断信息走 Host（Information 流），不污染返回值——否则 $usePreset 会变成数组，
    # --models-preset 参数会被传坏（冒烟测试实证过）。
    $skipped = @($Parsed.sections.Keys) | Where-Object { $keep -notcontains $_ }
    Write-Host ("NOTE: 已跳过本机不存在的模型条目: " + ($skipped -join ', '))
    return $path
}

function New-SinglePreset {
    # 由完整 preset 派生「只含一个模型」的临时 preset（用于小模型验证，不动主配置）
    param([string]$SectionName, $Parsed)
    if (-not $Parsed.sections.Contains($SectionName)) {
        $avail = (@($Parsed.sections.Keys) -join ', ')
        throw "preset 中不存在模型 '$SectionName'。可用: $avail"
    }
    $mp = [string]$Parsed.sections[$SectionName]['model']
    if ($mp -and -not (Test-Path -LiteralPath $mp)) {
        throw "模型文件在本机不存在: $mp（请编辑 models-preset.local.ini 指向本机 gguf 路径）"
    }
    $dir = Join-Path $Root 'out'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir ("router-preset-" + ($SectionName -replace '[^\w.-]', '_') + ".ini")
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("; 临时 preset（由 model-router.ps1 生成，勿手改）")
    [void]$sb.AppendLine("version = 1")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("[*]")
    foreach ($k in $Parsed.globals.Keys) { [void]$sb.AppendLine("$k = $($Parsed.globals[$k])") }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("[$SectionName]")
    foreach ($k in $Parsed.sections[$SectionName].Keys) {
        [void]$sb.AppendLine("$k = $($Parsed.sections[$SectionName][$k])")
    }
    Set-Content -LiteralPath $path -Value $sb.ToString() -Encoding utf8 -NoNewline
    return $path
}

function Get-RouterStatus {
    $rpid = Get-RouterPid
    $proc = Test-RouterProcess -ProcessId $rpid
    $owner = Get-PortOwner
    $loaded = if ($proc) { Get-LoadedModels } else { @() }
    $gpu = Get-GpuMiB
    return [pscustomobject]@{
        running      = [bool]$proc
        pid          = if ($proc) { $proc.Id } else { 0 }
        port         = $Port
        port_listen  = ($owner -ne 0)
        port_owner   = $owner
        health       = if ($proc) { Test-Health } else { $false }
        models       = $loaded
        preset       = $Preset
        gpu_used_mb  = if ($gpu) { $gpu.used } else { $null }
        gpu_free_mb  = if ($gpu) { $gpu.free } else { $null }
        working_set_mb = if ($proc) { [math]::Round($proc.WorkingSet64 / 1MB, 1) } else { 0 }
    }
}

function Invoke-WmiStart {
    # 用 WMI Win32_Process.Create 启动：进程不挂在调用者进程树/job 上。
    # 原因（实测）：pwsh 从 agent 终端里 Start-Process 拉起的子进程会随命令结束被 job 清理；
    # WMI 创建的进程归属 WMI 提供者，可长期驻留。日志由 llama-server 的 --log-file 落盘。
    param([string]$CmdLine)
    $create = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $CmdLine }
    if ($create.ReturnValue -ne 0) { throw "WMI 启动 llama-server 失败，ReturnValue=$($create.ReturnValue)" }
    $childPid = [int]$create.ProcessId
    Set-Content -LiteralPath $PidFile -Value "$childPid" -Encoding utf8 -NoNewline
    return $childPid
}

function Wait-RouterReady {
    param([int]$ChildPid, [int]$Timeout)
    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ChildPid -ErrorAction SilentlyContinue)) { return $false }
        if (Test-Health) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Clear-FailedRouter {
    # 失败不留脏进程：只停刚拉起的这个 PID
    param([int]$ChildPid, [string]$Reason)
    try {
        $cp = Get-Process -Id $ChildPid -ErrorAction SilentlyContinue
        if ($cp) { $cp.Kill($true); $cp.WaitForExit(5000) | Out-Null }
    } catch {}
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    $tail = ''
    try { $tail = (Get-Content -LiteralPath $RouterLog -Tail 15 -ErrorAction SilentlyContinue) -join "`n" } catch {}
    throw "$Reason。日志尾部:`n$tail"
}

function Start-Router {
    $st = Get-RouterStatus
    if ($st.running) {
        $msg = "已在运行（PID $($st.pid)），无需重复启动"
        if ($Json) { $st | ConvertTo-Json -Depth 4 } else { Write-Output $msg }
        return
    }
    if (-not (Test-Path -LiteralPath $Exe)) { throw "llama-server 不存在: $Exe" }
    if (-not (Test-Path -LiteralPath $Preset)) { throw "preset 不存在: $Preset" }
    if ($st.port_listen) {
        throw "端口 $Port 已被 PID $($st.port_owner) 占用（不是本脚本启动的 router）。请先停掉占用者，本脚本不会杀无关进程"
    }

    # 通用化：预设源三层查找 + 存在性过滤（换机后缺失条目自动跳过）
    $presetSource = Get-PresetSource
    $parsed = Read-PresetSections -Path $presetSource
    if ($Model) {
        $usePreset = New-SinglePreset -SectionName $Model -Parsed $parsed
    } else {
        $usePreset = New-EffectivePreset -Parsed $parsed -Source $presetSource
    }

    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $srvArgs = @(
        '--models-preset', $usePreset,
        '--models-max', '1',
        '--host', '127.0.0.1',
        '--port', "$Port",
        '--api-key-file', $KeyFile,
        '--cors-origins', 'localhost',
        '--log-file', $RouterLog
    )

    $argLine = (($srvArgs | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $childPid = Invoke-WmiStart -CmdLine ('"' + $Exe + '" ' + $argLine)
    if (-not (Wait-RouterReady -ChildPid $childPid -Timeout $TimeoutSec)) {
        Clear-FailedRouter -ChildPid $childPid -Reason "router 健康检查失败（$TimeoutSec 秒内 /health 未就绪）"
    }

    $final = Get-RouterStatus
    if ($Json) { $final | ConvertTo-Json -Depth 4 }
    else { Write-Output "OK: router 已启动 PID $($final.pid) 端口 $Port，已加载模型: $((@($final.models) -join ', '))" }
}

function Start-Boost {
    # 按注册表档位启动「单模型」服务（不带 models-preset，直接用 --model + 实测参数）
    if (-not $ModelFile) { throw "boost 需要 -ModelFile <gguf 路径>" }
    if (-not (Test-Path -LiteralPath $ModelFile)) { throw "模型文件不存在: $ModelFile" }
    $st = Get-RouterStatus
    if ($st.port_listen) {
        if ($st.port_owner -and (Test-RouterProcess -ProcessId $st.port_owner)) {
            Stop-Router
        } else {
            throw "端口 $Port 被 PID $($st.port_owner) 占用且不是本脚本管理的 router，拒绝抢占"
        }
    }
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

    $srvArgs = @('--model', $ModelFile, '--host', '127.0.0.1', '--port', "$Port",
                 '--api-key-file', $KeyFile, '--cors-origins', 'localhost', '--log-file', $RouterLog)
    if ($Ngl -ge 0) { $srvArgs += @('--n-gpu-layers', "$Ngl") }
    if ($Ctx -gt 0) { $srvArgs += @('--ctx-size', "$Ctx") }
    if ($FlashAttn) { $srvArgs += @('--flash-attn', $FlashAttn) }
    if ($CacheTypeK) { $srvArgs += @('--cache-type-k', $CacheTypeK) }
    if ($CacheTypeV) { $srvArgs += @('--cache-type-v', $CacheTypeV) }
    if ($Threads -gt 0) { $srvArgs += @('--threads', "$Threads") }
    if ($ThreadsBatch -gt 0) { $srvArgs += @('--threads-batch', "$ThreadsBatch") }
    if ($Alias) { $srvArgs += @('--alias', $Alias) }

    $argLine = (($srvArgs | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $childPid = Invoke-WmiStart -CmdLine ('"' + $Exe + '" ' + $argLine)
    if (-not (Wait-RouterReady -ChildPid $childPid -Timeout $TimeoutSec)) {
        Clear-FailedRouter -ChildPid $childPid -Reason "boost 启动健康检查失败（$TimeoutSec 秒内 /health 未就绪）"
    }
    $final = Get-RouterStatus
    if ($Json) { $final | ConvertTo-Json -Depth 4 }
    else { Write-Output "OK: boost 已启动 PID $($final.pid) 端口 $Port，模型: $((@($final.models) -join ', '))" }
}

function Restore-RouterFromCommandLine {
    # 用回滚记录里的原始命令行重启，成功返回 PID
    if (-not $CommandLine) { throw "restore 需要 -CommandLine（rollback.json 中的 commandline）" }
    $st = Get-RouterStatus
    if ($st.port_listen -and $st.port_owner -and (Test-RouterProcess -ProcessId $st.port_owner)) { Stop-Router }
    $cl = $CommandLine
    # 原命令若没带日志参数，补上，保证回滚后的进程仍在可管范围内
    if ($cl -notmatch '--log-file') { $cl += ' --log-file "' + $RouterLog + '"' }
    if ($cl -notmatch '--api-key-file') { $cl += ' --api-key-file "' + $KeyFile + '"' }
    if ($cl -notmatch '--cors-origins') { $cl += ' --cors-origins localhost' }
    $childPid = Invoke-WmiStart -CmdLine $cl
    if (-not (Wait-RouterReady -ChildPid $childPid -Timeout $TimeoutSec)) {
        Clear-FailedRouter -ChildPid $childPid -Reason "回滚重启健康检查失败"
    }
    Write-Output "OK: 已按回滚记录重启 PID $childPid"
}

function Stop-Router {
    $rpid = Get-RouterPid
    $proc = Test-RouterProcess -ProcessId $rpid
    if (-not $proc) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        Write-Output "OK: router 未在运行（PID 文件已清理）"
        return
    }
    try {
        $proc.Kill($true)
        $proc.WaitForExit(10000) | Out-Null
    } catch { throw "停止 router (PID $rpid) 失败: $_" }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Output "OK: router (PID $rpid) 已停止"
}

switch ($Action) {
    'start'  { Start-Router }
    'stop'   { Stop-Router }
    'boost'  { Start-Boost }
    'restore' { Restore-RouterFromCommandLine }
    'status' {
        $st = Get-RouterStatus
        if ($Json) { $st | ConvertTo-Json -Depth 4; break }
        if ($st.running) {
            Write-Output "router 运行中: PID $($st.pid) 端口 $Port health=$(if($st.health){'ok'}else{'未就绪'}) 显存 used=$($st.gpu_used_mb)MB free=$($st.gpu_free_mb)MB"
            Write-Output "已加载模型: $((@($st.models) -join ', '))"
        } else {
            Write-Output "router 未运行$(if($st.port_listen){"；但端口 $Port 被 PID $($st.port_owner) 占用"}else{''})"
        }
    }
    'logs' {
        if (-not (Test-Path -LiteralPath $RouterLog)) { Write-Output "日志尚不存在: $RouterLog"; break }
        Get-Content -LiteralPath $RouterLog -Tail $Tail -Encoding utf8
    }
}
