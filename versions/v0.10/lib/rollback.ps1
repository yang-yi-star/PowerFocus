# ============================================================
# v3 回滚框架（Gate 0 螺丝三）
# 职责：加速前备份 llama-server 的进程状态与参数；失败时按记录还原。
# 铁律：Save 只读不写；Restore 默认 dry-run，只有 -Apply 才动优先级/电源计划；
#       本模块永不重启进程，重启动作留给 boost_model 显式执行。
# ============================================================

$script:RollbackDir = Join-Path (Split-Path $PSScriptRoot -Parent) "rollback"
$script:RollbackFile = Join-Path $script:RollbackDir "rollback.json"
$script:RollbackLog = Join-Path $script:RollbackDir "rollback.log"

function Write-RollbackLog {
    param([string]$Event, [string]$Detail = "")
    try {
        if (-not (Test-Path -LiteralPath $script:RollbackDir)) {
            New-Item -ItemType Directory -Path $script:RollbackDir -Force | Out-Null
        }
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [$Event] $Detail"
        Add-Content -LiteralPath $script:RollbackLog -Value $line -Encoding utf8
        if (Get-Command Write-Lifecycle -ErrorAction SilentlyContinue) {
            try { Write-Lifecycle "ROLLBACK_$Event" $Detail } catch {}
        }
    } catch {}
}

function Get-LlamaServerProcess {
    param([int]$ProcessId = 0)
    if ($ProcessId -gt 0) { return Get-Process -Id $ProcessId -ErrorAction SilentlyContinue }
    try {
        $conn = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) { return Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue }
    } catch {}
    return Get-Process -Name "llama-server" -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Save-ModelRollback {
    param([int]$ProcessId = 0, [string]$Reason = "manual")

    $p = Get-LlamaServerProcess -ProcessId $ProcessId
    if (-not $p) {
        Write-RollbackLog "SAVE_FAILED" "reason=$Reason 未找到 llama-server 进程"
        return $null
    }

    $cmdline = ""
    try { $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction Stop).CommandLine } catch {}
    $exePath = ""
    try { $exePath = $p.Path } catch {}
    $plan = ""
    try { $plan = (powercfg /getactivescheme 2>$null) -join ' ' } catch {}

    $rec = [ordered]@{
        saved_at       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        reason         = $Reason
        pid            = $p.Id
        name           = $p.ProcessName
        exe_path       = $exePath
        priority       = "$($p.PriorityClass)"
        cpu_affinity   = "$($p.ProcessorAffinity)"
        working_set_mb = [math]::Round($p.WorkingSet64 / 1MB, 1)
        commandline    = $cmdline
        power_plan     = $plan
    }

    try {
        if (-not (Test-Path -LiteralPath $script:RollbackDir)) {
            New-Item -ItemType Directory -Path $script:RollbackDir -Force | Out-Null
        }
        $rec | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:RollbackFile -Encoding utf8
    } catch {
        Write-RollbackLog "SAVE_FAILED" "写入 rollback.json 失败: $_"
        return $null
    }

    Write-RollbackLog "SAVE" "reason=$Reason pid=$($p.Id) priority=$($rec.priority) ws=$($rec.working_set_mb)MB"
    return [pscustomobject]$rec
}

function Get-ModelRollback {
    if (-not (Test-Path -LiteralPath $script:RollbackFile)) { return $null }
    try { return Get-Content -Raw -LiteralPath $script:RollbackFile -Encoding utf8 | ConvertFrom-Json } catch { return $null }
}

function Restore-ModelRollback {
    param([switch]$Apply)

    $rec = Get-ModelRollback
    if (-not $rec) {
        Write-RollbackLog "RESTORE_FAILED" "无 rollback.json 可还原"
        return $false
    }

    $plan = @()
    $proc = Get-Process -Id $rec.pid -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-RollbackLog "RESTORE_SKIPPED" "pid=$($rec.pid) 已不在，需由 boost_model 按 commandline 重启"
        return $false
    }

    if ("$($proc.PriorityClass)" -ne $rec.priority) {
        $plan += "priority: $($proc.PriorityClass) -> $($rec.priority)"
    }
    $curPlan = ""
    try { $curPlan = (powercfg /getactivescheme 2>$null) -join ' ' } catch {}
    if ($rec.power_plan -and $curPlan -and ($curPlan -ne $rec.power_plan)) {
        $plan += "power_plan: 需要还原为保存时的计划"
    }

    if ($plan.Count -eq 0) {
        Write-RollbackLog "RESTORE_NOOP" "pid=$($rec.pid) 状态与备份一致"
        return $true
    }

    if (-not $Apply) {
        Write-RollbackLog "RESTORE_DRYRUN" ("将执行: " + ($plan -join "; "))
        return $true
    }

    try {
        $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$($rec.priority)
    } catch { Write-RollbackLog "RESTORE_PARTIAL" "优先级还原失败: $_" }
    Write-RollbackLog "RESTORE" ("已还原: " + ($plan -join "; "))
    return $true
}
