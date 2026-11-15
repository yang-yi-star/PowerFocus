# ============================================================
# net-qos.ps1 — 网络服务质量（QoS）管理小工具
# 基于微软 NetQoS 模块：按应用/端口限速出站、DSCP 优先级标记、策略查询/清除
# 配合电脑算力调度中心 v2 使用（输出 JSON 供命令总线/其他工具读取）
#
# 用法：
#   net-qos.ps1 list                    列出当前 QoS 策略
#   net-qos.ps1 throttle -App <exe路径> -RateMbps 5        按应用限速出站 5 Mbps
#   net-qos.ps1 throttle -Port 80 -RateMbps 10            按端口限速出站 10 Mbps
#   net-qos.ps1 dscp -App <exe路径> -Dscp 46              应用出站标记 DSCP 46（高优先级）
#   net-qos.ps1 remove -Name <策略名>                      删除指定策略
#   net-qos.ps1 remove -All                                清除全部策略
#   net-qos.ps1 json                                       JSON 模式输出（配合总线）
#
# 说明（微软官方文档限制，诚实标注）：
#   NetQoS 策略只能限制/标记【出站】流量；入站带宽限制需要第三方（如 NetLimiter）。
#   需要管理员权限（当前已确认管理员）。
# ============================================================
[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('list','throttle','dscp','remove','json')]
    [string]$Action = 'list',
    [string]$App,            # 应用可执行文件路径（如 C:\Program Files\xxx\app.exe）
    [int]$Port = 0,          # 端口号
    [double]$RateMbps = 0,   # 限速 Mbps
    [int]$Dscp = 0,          # DSCP 值 0-63
    [string]$Name = '',      # 策略名
    [switch]$All,            # 清除全部
    [switch]$Json            # JSON 输出
)

$ErrorActionPreference = 'Stop'
$jsonMode = ($Json -or $Action -eq 'json')
$out = @{ tool = 'net-qos'; ok = $false; action = $Action; message = ''; policies = @() }

try {
    if (-not (Get-Command New-NetQosPolicy -ErrorAction SilentlyContinue)) {
        $out.message = 'NetQoS 模块不可用（此 Windows 版本不支持）'
        if ($jsonMode) { Write-Output ($out | ConvertTo-Json -Depth 4 -Compress); exit 1 }
        Write-Output "ERROR: $($out.message)"
        exit 1
    }

    switch ($Action) {
        'list' {
            $p = @(Get-NetQosPolicy -ErrorAction SilentlyContinue)
            $out.policies = @($p | ForEach-Object {
                [ordered]@{
                    name = $_.Name; app = $_.AppPathNameMatchCondition; port = $_.PortMatchCondition
                    dscp = $_.DscpAction; throttle_bps = $_.ThrottleRateActionBitsPerSecond
                }
            })
            $out.ok = $true
            $out.message = "当前 QoS 策略 $($p.Count) 条"
            if (-not $jsonMode) {
                Write-Output "== 当前 QoS 策略（$($p.Count) 条）=="
                foreach ($x in $out.policies) {
                    $line = "  $($x.name):"
                    if ($x.app) { $line += " 应用=$($x.app)" }
                    if ($x.port) { $line += " 端口=$($x.port)" }
                    if ($x.dscp) { $line += " DSCP=$($x.dscp)" }
                    if ($x.throttle_bps) { $line += " 限速=$([math]::Round($x.throttle_bps/1MB,2)) Mbps" }
                    Write-Output $line
                }
            }
        }
        'throttle' {
            if (-not $App -and $Port -le 0) { throw 'throttle 需要 -App <exe路径> 或 -Port <端口>' }
            if ($RateMbps -le 0) { throw 'throttle 需要 -RateMbps <数值>' }
            $n = if ($Name) { $Name } else {
                if ($App) { "QoS限速-$([IO.Path]::GetFileNameWithoutExtension($App))-$($RateMbps)Mbps" }
                else { "QoS限速-端口$Port-$($RateMbps)Mbps" }
            }
            $args = @{ Name = $n; ThrottleRateActionBitsPerSecond = [int64]($RateMbps * 1e6) }
            if ($App) { $args.AppPathNameMatchCondition = (Resolve-Path -LiteralPath $App).Path }
            if ($Port -gt 0) { $args.PortMatchCondition = $Port }
            New-NetQosPolicy @args -ErrorAction Stop | Out-Null
            $out.ok = $true
            $out.message = "已创建限速策略「$n」：$($RateMbps) Mbps 出站"
            if (-not $jsonMode) { Write-Output "OK: $($out.message)" }
        }
        'dscp' {
            if (-not $App) { throw 'dscp 需要 -App <exe路径>' }
            if ($Dscp -lt 0 -or $Dscp -gt 63) { throw 'DSCP 取值 0-63' }
            $n = if ($Name) { $Name } else { "QoS标记-$([IO.Path]::GetFileNameWithoutExtension($App))-DSCP$Dscp" }
            New-NetQosPolicy -Name $n -AppPathNameMatchCondition (Resolve-Path -LiteralPath $App).Path -DscpAction $Dscp -ErrorAction Stop | Out-Null
            $out.ok = $true
            $out.message = "已创建 DSCP 标记策略「$n」：DSCP=$Dscp"
            if (-not $jsonMode) { Write-Output "OK: $($out.message)" }
        }
        'remove' {
            if ($All) {
                $cnt = @(Get-NetQosPolicy -ErrorAction SilentlyContinue).Count
                Remove-NetQosPolicy -Confirm:$false -ErrorAction SilentlyContinue
                $out.ok = $true
                $out.message = "已清除全部 QoS 策略（$cnt 条）"
            } else {
                if (-not $Name) { throw 'remove 需要 -Name <策略名> 或 -All' }
                Remove-NetQosPolicy -Name $Name -Confirm:$false -ErrorAction Stop
                $out.ok = $true
                $out.message = "已删除策略「$Name」"
            }
            if (-not $jsonMode) { Write-Output "OK: $($out.message)" }
        }
        'json' {
            $p = @(Get-NetQosPolicy -ErrorAction SilentlyContinue)
            $out.policies = @($p | ForEach-Object {
                [ordered]@{
                    name = $_.Name; app = $_.AppPathNameMatchCondition; port = $_.PortMatchCondition
                    dscp = $_.DscpAction; throttle_bps = $_.ThrottleRateActionBitsPerSecond
                }
            })
            $out.ok = $true
            $out.message = "当前 QoS 策略 $($p.Count) 条"
        }
    }
} catch {
    $out.message = "ERROR: $($_.Exception.Message)"
    if (-not $jsonMode) { Write-Output $out.message }
}
if ($jsonMode) { Write-Output ($out | ConvertTo-Json -Depth 4 -Compress) }
