# ============================================================
# net-diag.ps1 — 网络诊断小工具（配合电脑算力调度中心 v2）
# 一键检查：网卡状态 / IPv4 / DNS / 默认网关 / 外网连通 / 延迟丢包 / 路由
#
# 用法：
#   net-diag.ps1              完整诊断（人类报告）
#   net-diag.ps1 -Json        输出 JSON（配合命令总线/其他 AI）
#   net-diag.ps1 -Targets "www.baidu.com,github.com"   自定义连通目标
#
# 诚实说明：诊断只反映当前网络现状；github.com 等境外目标在境内可能
# 超时/丢包（属网络环境限制，如实显示，不美化）。
# ============================================================
[CmdletBinding()]
param(
    [string]$Targets = 'www.baidu.com,www.qq.com,github.com',
    [switch]$Json
)

$ErrorActionPreference = 'SilentlyContinue'
$diag = [ordered]@{
    tool = 'net-diag'; time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); ok = $true
    adapters = @(); ipv4 = @(); dns = @(); gateway = $null; connectivity = @(); summary = @()
}
$lines = @()

function Add-Line([string]$s) { $script:lines += $s }

try {
    # 1. 网卡状态
    Add-Line "== 网络适配器 =="
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disconnected' })
    foreach ($a in $adapters) {
        $diag.adapters += [ordered]@{ name = $a.Name; status = $a.Status; speed = "$($a.LinkSpeed)" }
        Add-Line ("  {0,-24} {1,-10} {2}" -f $a.Name, $a.Status, $a.LinkSpeed)
    }
    if ($adapters.Count -eq 0) { Add-Line "  （未发现活动网卡）" }

    # 2. IPv4 配置（找第一个有 IPv4 的活动接口）
    Add-Line "== IPv4 / 网关 / DNS =="
    $cfg = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4Address })
    foreach ($c in $cfg) {
        $gw = $c.IPv4DefaultGateway | Select-Object -First 1
        $dnsList = @($c.DNSServer | Select-Object -ExpandProperty ServerAddresses)
        $diag.ipv4 += [ordered]@{ iface = $c.InterfaceAlias; ip = $c.IPv4Address[0].IPAddress; gateway = $(if ($gw) { $gw.NextHop } else { $null }); dns = $dnsList -join ',' }
        Add-Line ("  {0}: IP={1} 网关={2} DNS={3}" -f $c.InterfaceAlias, $c.IPv4Address[0].IPAddress, $(if ($gw) { $gw.NextHop } else { '无' }), ($dnsList -join ','))
        if (-not $diag.gateway -and $gw) { $diag.gateway = $gw.NextHop }
    }
    $gwAddr = $diag.gateway

    # 3. 默认网关延迟
    if ($gwAddr) {
        $g = Test-Connection -ComputerName $gwAddr -Count 2 -ErrorAction SilentlyContinue
        $gl = if ($g) { ($g | Measure-Object -Property ResponseTime -Average).Average } else { $null }
        $diag.gateway_latency_ms = [math]::Round($gl, 1)
        Add-Line ("默认网关 {0} 延迟: {1} ms" -f $gwAddr, $(if ($null -ne $gl) { [math]::Round($gl,1) } else { '不通' }))
    }

    # 4. 外网连通 + 延迟丢包（关键目标）
    Add-Line "== 外网连通（ping 4 次采样）=="
    foreach ($t in ($Targets -split ',' | Where-Object { $_ })) {
        $p = Test-Connection -ComputerName $t -Count 4 -ErrorAction SilentlyContinue
        if ($p) {
            $avg = ($p | Measure-Object -Property ResponseTime -Average).Average
            $loss = 4 - $p.Count
            $diag.connectivity += [ordered]@{ target = $t; reachable = $true; avg_ms = [math]::Round($avg,1); loss = $loss }
            Add-Line ("  {0,-20} 通  平均 {1} ms 丢包 {2}/4" -f $t, [math]::Round($avg,1), $loss)
        } else {
            $diag.connectivity += [ordered]@{ target = $t; reachable = $false; avg_ms = $null; loss = 4 }
            Add-Line ("  {0,-20} 不通（超时/被墙，如实标注）" -f $t)
        }
    }

    # 5. DNS 解析（关键域名）
    Add-Line "== DNS 解析 =="
    foreach ($t in ($Targets -split ',' | Where-Object { $_ })) {
        $d = Resolve-DnsName -Name $t -Type A -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | Select-Object -First 1
        $diag.dns += [ordered]@{ domain = $t; ip = $(if ($d) { $d.IPAddress } else { '解析失败' }) }
        Add-Line ("  {0,-20} -> {1}" -f $t, $(if ($d) { $d.IPAddress } else { '解析失败' }))
    }

    # 6. 默认路由摘要
    $route = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 2)
    if ($route) {
        $diag.default_routes = @($route | ForEach-Object { "$($_.InterfaceAlias) via $($_.NextHop)" })
        Add-Line "== 默认路由 =="
        foreach ($rt in $diag.default_routes) { Add-Line "  $rt" }
    }

    $diag.summary = $lines
    if (-not $Json) { $lines | ForEach-Object { Write-Output $_ } }
} catch {
    $diag.ok = $false
    $diag.error = $_.Exception.Message
    if (-not $Json) { Write-Output "ERROR: $($_.Exception.Message)" }
}
if ($Json) { Write-Output ($diag | ConvertTo-Json -Depth 5 -Compress) }
