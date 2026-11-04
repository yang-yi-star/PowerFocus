#Requires -Version 7.0

param(
    [string]$Command,
    [switch]$NoModel
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================================
# nl-gateway.ps1 —— 自然语言网关（阶段二：自然语言控制层）
# 职责：把中文自然语言指令翻译为 JSON 命令，经命令总线指挥调度中心。
# 翻译两级：
#   1) 规则解析（nl-parser.ps1，无模型依赖，快速路径）
#   2) LLM 兜底（http://localhost:8080 主推理服务，OpenAI 兼容接口）
# 安全铁律：
#   - authorize/revoke 属敏感命令：LLM 永远无权生成；人工指令也必须二次确认
#   - LLM 输出经 action 白名单校验，防幻觉
# 用法：
#   交互模式:  pwsh -File nl-gateway.ps1
#   单次模式:  pwsh -File nl-gateway.ps1 -Command "给 llama-server 开后门"
#   纯规则:    pwsh -File nl-gateway.ps1 -Command "状态" -NoModel
# ============================================================

$script:Dir       = $PSScriptRoot
# v2 已独立到 E:\PowerFocus\v2，命令总线与授权清单随之迁移
$script:V2Dir     = Join-Path $script:Dir "v2"
$script:CmdIn     = Join-Path $script:V2Dir "commands\in"
$script:CmdOut    = Join-Path $script:V2Dir "commands\out"
$script:CmdDone   = Join-Path $script:V2Dir "commands\done"
$script:TokenFile = Join-Path $script:V2Dir ".auth_token"
$script:LlmUrl    = "http://localhost:8080/v1/chat/completions"

. (Join-Path $script:Dir "nl-parser.ps1")

# ---------- 基础工具 ----------
function Get-AuthToken {
    try { return (Get-Content -LiteralPath $script:TokenFile -Raw).Trim() } catch { return "" }
}

function Write-GwLog {
    param([string]$Msg)
    try {
        $log = Join-Path $script:Dir "nl-gateway.log"
        Add-Content -LiteralPath $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Msg" -Encoding utf8
    } catch {}
}

function Submit-Command {
    # 把命令对象写入总线并等待结果
    param([hashtable]$CmdObj, [int]$TimeoutSec = 15)
    if (-not (Test-Path -LiteralPath $script:CmdIn)) {
        return "ERROR: 命令总线目录不存在，调度中心 v2 从未运行过？请先启动 电脑算力调度中心_v2.ps1"
    }
    $id = [guid]::NewGuid().ToString("N")
    $inPath  = Join-Path $script:CmdIn "$id.json"
    $resPath = Join-Path $script:CmdDone "$id.json.result.txt"
    $CmdObj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $inPath -Encoding utf8
    Write-GwLog "提交命令: $($CmdObj | ConvertTo-Json -Compress -Depth 4)"

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        if (Test-Path -LiteralPath $resPath) {
            $r = (Get-Content -LiteralPath $resPath -Raw).Trim()
            Write-GwLog "结果: $r"
            return $r
        }
    }
    Write-GwLog "超时: 15 秒内总线无响应"
    return "ERROR: 命令总线 15 秒无响应——调度中心 v2 可能在运行但轮询关闭，或未启动"
}

function Show-StatusDigest {
    # status 命令后把 out\status.json 摘要打印给人看
    $p = Join-Path $script:CmdOut "status.json"
    if (-not (Test-Path -LiteralPath $p)) { return }
    try {
        $s = Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json
        Write-Host "── 状态摘要 ─────────────────────────"
        Write-Host "时间: $($s.time)"
        Write-Host "当前目标: $($s.target_name) (模式 $($s.focus_mode), 期望优先级 $($s.desired_priority))"
        Write-Host "被降级进程数: $($s.demoted_count)"
        Write-Host "电源计划: $(($s.power_plan -split "`n")[0])"
        if (@($s.auth_list).Count -gt 0) {
            Write-Host "授权清单: $((@($s.auth_list) | ForEach-Object { "$($_.name)($($_.level))" }) -join ', ')"
        } else { Write-Host "授权清单: (空)" }
        Write-Host "CPU 占用 Top5:"
        foreach ($c in @($s.top_cpu)) {
            Write-Host ("  {0,-24} PID {1,-8} {2,5}%  {3} MB" -f $c.name, $c.pid, $c.cpu_pct, $c.mem_mb)
        }
        Write-Host "──────────────────────────────────────"
    } catch { Write-Host "(状态摘要解析失败: $_)" }
}

# ---------- LLM 兜底解析 ----------
$script:LlmSystemPrompt = @"
你是"电脑算力调度中心"的指令解析器。把用户的中文自然语言指令转换为一个 JSON 命令对象。
只输出一个 JSON 对象，禁止输出任何解释、markdown 代码块或其他文字。
可用动作（只能从中选一个）：
{"action":"status"}
{"action":"focus","process_name":"<进程名>","mode":"gentle"}
{"action":"focus","process_name":"<进程名>","mode":"aggressive"}
{"action":"focus","process_name":"<进程名>","mode":"godmode"}
{"action":"unfocus"}
{"action":"set_priority","process_name":"<进程名>","priority":"Idle|BelowNormal|Normal|AboveNormal|High|RealTime"}
{"action":"set_power_plan","plan":"high"}
{"action":"set_power_plan","plan":"balanced"}
{"action":"trim_memory","exclude_target":true}
{"action":"set_io_priority","process_name":"<进程名>","priority":"VeryLow|Low|Normal|High"}
{"action":"set_net_qos","process_name":"<进程名>","rate_mbps":<数值Mbps，0表示撤销限速>}
{"action":"apply_scene","scene":"<场景名，如 inference/gaming/relax>"}
{"action":"list_scenes"}
禁止生成 authorize 或 revoke（这两类必须人工操作）。
进程名必须是英文进程名（如 llama-server、chrome、Code）；用户没提进程名时也不要编造。
"@

function ConvertFrom-Llm {
    param([string]$Text)
    $body = @{
        model = "local"
        messages = @(
            @{ role = "system"; content = $script:LlmSystemPrompt },
            @{ role = "user"; content = $Text }
        )
        temperature = 0.1
        max_tokens = 120
    } | ConvertTo-Json -Depth 5
    try {
        $resp = Invoke-RestMethod -Uri $script:LlmUrl -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 30
        $content = $resp.choices[0].message.content.Trim()
        # 提取第一个 { 到最后一个 } 之间的 JSON
        $s = $content.IndexOf('{'); $e = $content.LastIndexOf('}')
        if ($s -lt 0 -or $e -le $s) { return $null }
        $obj = $content.Substring($s, $e - $s + 1) | ConvertFrom-Json
        return $obj
    } catch {
        Write-Host "[LLM 不可达: $_]" -ForegroundColor DarkGray
        return $null
    }
}

function Test-CommandAllowed {
    # 命令安全校验：action 白名单 + 字段类型 + 敏感动作拦截
    param($CmdObj)
    $allowed = @('status','focus','unfocus','set_priority','set_power_plan',
                 'trim_memory','set_io_priority','set_net_qos','apply_scene','list_scenes')
    if ($null -eq $CmdObj.action) { return "ERROR: 命令缺 action 字段" }
    if ($allowed -notcontains $CmdObj.action) { return "ERROR: action '$($CmdObj.action)' 不在允许范围（authorize/revoke 必须人工确认，LLM 无权生成）" }
    if ($CmdObj.action -eq 'focus' -and $CmdObj.mode -notin @('gentle','aggressive','godmode')) { return "ERROR: focus 的 mode 非法" }
    if ($CmdObj.action -eq 'set_priority' -and $CmdObj.priority -notin @('Idle','BelowNormal','Normal','AboveNormal','High','RealTime')) { return "ERROR: 优先级值非法" }
    if ($CmdObj.action -eq 'set_power_plan' -and $CmdObj.plan -notin @('high','balanced')) { return "ERROR: 电源计划值非法" }
    if ($CmdObj.action -eq 'set_io_priority' -and $CmdObj.priority -notin @('VeryLow','Low','Normal','High')) { return "ERROR: I/O 优先级值非法" }
    if ($CmdObj.action -eq 'set_net_qos') {
        $r = 0.0
        if (-not [double]::TryParse([string]$CmdObj.rate_mbps, [ref]$r)) { return "ERROR: set_net_qos 需要 rate_mbps 数值（0=撤销限速）" }
    }
    if ($CmdObj.action -eq 'apply_scene' -and [string]::IsNullOrWhiteSpace([string]$CmdObj.scene)) { return "ERROR: apply_scene 缺 scene 名称" }
    return $null   # 通过
}

# ---------- 执行一条已解析的命令 ----------
function Invoke-Resolved {
    param([hashtable]$CmdObj)

    # 敏感命令：注入 token 前必须人工确认
    if ($CmdObj.ContainsKey('_sensitive')) {
        $token = Get-AuthToken
        if (-not $token) { Write-Host "错误: .auth_token 不存在，无法执行敏感命令" -ForegroundColor Red; return }
        if ($Command) {
            # 单次模式：一律拒绝，防止无监督修改授权
            Write-Host "拒绝: 授权变更必须在交互模式下人工确认（不带 -Command 启动网关）" -ForegroundColor Yellow
            return
        }
        $clean = @{ action = $CmdObj.action; process_name = $CmdObj.process_name }
        if ($CmdObj.level) { $clean.level = $CmdObj.level }
        Write-Host "将执行敏感命令:" -ForegroundColor Yellow
        Write-Host ($clean | ConvertTo-Json -Compress)
        $ans = Read-Host "确认？(y/N)"
        if ($ans -ne 'y') { Write-Host "已取消"; return }
        $clean.token = $token
        Write-Host (Submit-Command -CmdObj $clean)
        return
    }

    # 普通命令
    $clean = @{}
    foreach ($k in $CmdObj.Keys) { if (-not $k.StartsWith('_')) { $clean[$k] = $CmdObj[$k] } }
    # LLM 来源的命令也过一遍校验
    $bad = Test-CommandAllowed ([pscustomobject]$clean)
    if ($bad) { Write-Host $bad -ForegroundColor Red; return }

    if ($CmdObj.ContainsKey('_explain')) { Write-Host "→ $($CmdObj['_explain'])" -ForegroundColor Cyan }
    $result = Submit-Command -CmdObj $clean
    Write-Host $result
    if ($clean.action -eq 'status') { Show-StatusDigest }
}

# ---------- 解析入口 ----------
function Resolve-UserText {
    param([string]$Text)
    # 第一级：规则解析
    $rule = ConvertFrom-NaturalLanguage -Text $Text
    if ($null -ne $rule) {
        if ($rule.ContainsKey('_error')) {
            Write-Host "规则解析: $($rule['_error'])" -ForegroundColor DarkYellow
            return $null
        }
        Write-Host "[规则解析命中]" -ForegroundColor DarkGray
        return $rule
    }
    # 第二级：LLM 兜底
    if ($NoModel) {
        Write-Host "无法识别该指令（-NoModel 模式下无 LLM 兜底）" -ForegroundColor Yellow
        return $null
    }
    Write-Host "[规则未命中，尝试 LLM 解析...]" -ForegroundColor DarkGray
    $llm = ConvertFrom-Llm -Text $Text
    if ($null -eq $llm) { Write-Host "LLM 也解析失败" -ForegroundColor Yellow; return $null }
    $bad = Test-CommandAllowed $llm
    if ($bad) { Write-Host "LLM 输出被安全校验拦截: $bad" -ForegroundColor Red; return $null }
    $h = @{}
    foreach ($p in $llm.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

# ---------- 主入口 ----------
if ($Command) {
    # 单次模式：给外部 AI / 脚本调用
    $cmd = Resolve-UserText -Text $Command
    if ($cmd) { Invoke-Resolved -CmdObj $cmd }
    exit 0
}

# 交互模式
Write-Host "═══ 电脑算力调度中心 · 自然语言网关 ═══" -ForegroundColor Cyan
Write-Host "直接说人话即可。例：给 llama-server 开后门 / 看看现在什么情况 / 解除聚焦"
Write-Host "敏感命令（授权/撤销授权）会要求确认。exit 退出。"
while ($true) {
    $line = Read-Host "NL>"
    if ($line -in @('exit','q','quit')) { break }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $cmd = Resolve-UserText -Text $line
    if ($cmd) { Invoke-Resolved -CmdObj $cmd }
}
Write-Host "再见。"
