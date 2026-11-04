# ============================================================
# net-anon.ps1 — 匿名/代理助手（配合电脑算力调度中心 v2）
# 功能：系统代理切换 / 出口 IP 检测（国内可达源）/ 经代理验证出口 / Tailscale 提示
#
# 用法：
#   net-anon.ps1 status                    查看系统代理状态 + 当前出口 IP
#   net-anon.ps1 proxy -Host 127.0.0.1 -Port 1080   开启系统代理（SOCKS/HTTP 由代理软件决定）
#   net-anon.ps1 proxy off                 关闭系统代理
#   net-anon.ps1 verify -Host 127.0.0.1 -Port 1080  经代理检测出口 IP（对比是否变化）
#   net-anon.ps1 tailscale                 检查 Tailscale 状态（可配 exit node 走远程出口）
#   net-anon.ps1 -Json                     输出 JSON（配合命令总线）
#
# 诚实声明：
#   - 本工具只做"系统代理开关 + 出口 IP 验证"，匿名性取决于你使用的代理/VPN 服务本身。
#   - 国内网络环境：Tor 直连常被墙需网桥；境外代理服务可用性不稳定，如实检测显示。
#   - 出口 IP 检测使用多个国内可达源（ip-api.com / myip.ipip.net），失败会如实报"检测失败"。
# ============================================================
[CmdletBinding()]
param(
    [Parameter(Position=0)][ValidateSet('status','proxy','verify','tailscale')]
    [string]$Action = 'status',
    [string]$ProxyHost = '',
    [int]$Port = 0,
    [switch]$Json
)

$ErrorActionPreference = 'SilentlyContinue'
$jsonMode = ($Json -or $Action -eq 'status')
$out = @{ tool = 'net-anon'; ok = $false; action = $Action; message = ''; data = @{} }

function Get-ExitIp {
    # 多源出口 IP 检测（国内可达优先）；返回 @{ip=..;source=..} 或 $null
    $sources = @(
        @{ url = 'http://ip-api.com/json/'; parse = 'query' },
        @{ url = 'http://myip.ipip.net/'; parse = 'regex' },
        @{ url = 'https://api.ip.sb/ip'; parse = 'raw' }
    )
    foreach ($s in $sources) {
        try {
            $resp = Invoke-RestMethod -Uri $s.url -TimeoutSec 6
            if ($s.parse -eq 'query') { if ($resp.query) { return @{ ip = [string]$resp.query; source = $s.url } } }
            elseif ($s.parse -eq 'regex') { $m = [regex]::Match([string]$resp, '(\d+\.\d+\.\d+\.\d+)'); if ($m.Success) { return @{ ip = $m.Groups[1].Value; source = $s.url } } }
            else { if ($resp -match '\d+\.\d+\.\d+\.\d+') { return @{ ip = $matches[0]; source = $s.url } } }
        } catch {}
    }
    return $null
}

function Get-ProxyState {
    $p = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    return @{ enabled = [bool]$p.ProxyEnable; server = $p.ProxyServer }
}

function Set-ProxyState([bool]$Enable, [string]$Server) {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty -Path $path -Name ProxyEnable -Value ([int]$Enable)
    if ($Enable -and $Server) { Set-ItemProperty -Path $path -Name ProxyServer -Value $Server }
}

try {
    switch ($Action) {
        'status' {
            $ps = Get-ProxyState
            $exit = Get-ExitIp
            $out.data.proxy = $ps
            if ($exit) { $out.data.exit_ip = $exit.ip; $out.data.exit_source = $exit.source }
            else { $out.data.exit_ip = $null; $out.data.exit_source = $null; $out.data.exit_error = '出口 IP 检测失败（网络受限或源不可达）' }
            $out.ok = $true
            $out.message = "系统代理=$($ps.server) 启用=$($ps.enabled) 出口IP=$($exit.ip)"
            if (-not $jsonMode) {
                Write-Output "== 匿名状态 =="
                Write-Output "  系统代理: $(if($ps.enabled){'已启用 → ' + $ps.server}else{'未启用'})"
                if ($exit) { Write-Output "  当前出口 IP: $($exit.ip)  （源: $($exit.source)）" }
                else { Write-Output "  当前出口 IP: 检测失败（网络受限）" }
            }
        }
        'proxy' {
            if ($ProxyHost -eq 'off') {
                Set-ProxyState $false ''
                $out.ok = $true
                $out.message = '系统代理已关闭'
                if (-not $jsonMode) { Write-Output "OK: $($out.message)" }
            } else {
                if (-not $ProxyHost -or $Port -le 0) { throw 'proxy 需要 -Host <地址> -Port <端口>，或用 proxy off 关闭' }
                Set-ProxyState $true "$($ProxyHost):$Port"
                $out.ok = $true
                $out.message = "系统代理已设为 $($ProxyHost):$Port"
                if (-not $jsonMode) { Write-Output "OK: $($out.message)" }
            }
        }
        'verify' {
            if (-not $ProxyHost -or $Port -le 0) { throw 'verify 需要 -Host <地址> -Port <端口>' }
            # 直连出口 vs 经代理出口
            $direct = Get-ExitIp
            $viaProxy = $null
            try {
                $r = & curl.exe -s -m 10 --proxy "socks5://$($ProxyHost):$Port" http://ip-api.com/json/ 2>$null
                $r | Out-Null
                if ($LASTEXITCODE -eq 0 -and $r) { $viaProxy = $r | ConvertFrom-Json; $viaProxy = @{ ip = $viaProxy.query; source = 'via proxy' } }
                else { $viaProxy = $null }
            } catch {}
            $out.data.direct_ip = $direct.ip
            $out.data.proxy_ip = $viaProxy.ip
            $changed = $direct.ip -ne $viaProxy.ip
            $out.data.changed = $changed
            $out.ok = $true
            $out.message = "直连 $($direct.ip) → 代理 $($viaProxy.ip) $(if($changed){'IP 已变化 ✓'}else{'IP 未变化（代理可能无效）'})"
            if (-not $jsonMode) {
                Write-Output "== 代理验证 =="
                Write-Output "  直连出口: $($direct.ip)"
                Write-Output "  经代理:   $(if($viaProxy){$viaProxy.ip}else{'代理不可达（检测失败）'})"
                if ($changed) { Write-Output "  结论: IP 已变化，代理生效" } else { Write-Output "  结论: IP 未变化——代理无效或未真正转发（诚实标注）" }
            }
        }
        'tailscale' {
            $ts = & tailscale status 2>$null | Out-String
            if ($LASTEXITCODE -eq 0 -and $ts) {
                $out.data.tailscale = ($ts -split "`n" | Select-Object -First 8)
                $out.ok = $true
                $out.message = 'Tailscale 已安装并运行（见 status 输出）'
                if (-not $jsonMode) { Write-Output "== Tailscale 状态 =="; Write-Output $ts.Trim() }
            } else {
                $out.ok = $false
                $out.message = 'Tailscale 未运行或不在 PATH（诚实标注）'
                if (-not $jsonMode) { Write-Output "Tailscale: 未运行或不在 PATH（可使用 tailscale up / exit node 配置出口 IP）" }
            }
            if (-not $jsonMode) { Write-Output "提示: 在 Tailscale admin 配置 exit node 后，出口 IP 可走远程节点（Tailscale 是合法的组网/VPN 方案）" }
        }
    }
} catch {
    $out.message = "ERROR: $($_.Exception.Message)"
    if (-not $jsonMode) { Write-Output $out.message }
}
if ($jsonMode) { Write-Output ($out | ConvertTo-Json -Depth 5 -Compress) }
