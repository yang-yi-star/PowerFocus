# v0.13 补给实测：压得动 / 不杀任何进程 / 能完整还原
$k = 'E:\PowerFocus\versions\v0.13\电脑算力调度中心_v0.13.ps1'
# exe 正常运行时持有 .v3.lock，只读测试要绕过，否则 dot-source 直接 exit 1
$env:PF_V3_NO_LOCK = '1'
. $k

$tid = $null
Write-Host "`n=== 0. 起一个空闲 pwsh 当申请目标 ===" -ForegroundColor Cyan
$tid = (Start-Process -FilePath 'C:\Tools\PowerShell7\pwsh.EXE' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 600') -WindowStyle Hidden -PassThru).Id
Start-Sleep -Seconds 2
Write-Host "  目标 PID = $tid"

function SnapPids { (Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) }
function SnapPriority($names) {
    $r = @{}
    foreach ($n in $names) {
        $p = Get-Process -ProcessName $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p) { $r[$n] = [string]$p.PriorityClass }
    }
    return $r
}
$watch = @('QQ','QQEX','DeepSeek Harness','JianyingPro','WorkBuddy','msedge','Trae CN')

Write-Host "`n=== 1. 补给前快照 ===" -ForegroundColor Cyan
$before = SnapPriority $watch
$before | Format-Table -AutoSize
$pidBefore = SnapPids
Write-Host "  进程总数 = $($pidBefore.Count)"

Write-Host "`n=== 2. 申请算力（aggressive / 600s）===" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
$out = Invoke-CommandObject @{ action = 'request_power'; pid = $tid; level = 'aggressive'; duration = 600; reason = 'v0.13 判据实测' }
$sw.Stop()
Write-Host "  耗时 $([math]::Round($sw.Elapsed.TotalSeconds,1)) 秒"
Write-Host "  返回：$out" -ForegroundColor Yellow

Write-Host "`n=== 3. 补给后快照 ===" -ForegroundColor Cyan
$after = SnapPriority $watch
$after | Format-Table -AutoSize
$pidAfter = SnapPids
Write-Host "  进程总数 = $($pidAfter.Count)"

Write-Host "`n=== 4. 有没有被杀 ===" -ForegroundColor Cyan
$gone = @($pidBefore | Where-Object { $_ -notin $pidAfter })
if ($gone.Count -eq 0) {
    Write-Host "  ✓ 没有任何进程被杀（PID 集合完全一致）" -ForegroundColor Green
} else {
    Write-Host "  ✗ 消失了 $($gone.Count) 个 PID：" -ForegroundColor Red
    foreach ($g in $gone) { Write-Host "    PID $g" }
}

Write-Host "`n=== 5. 优先级变化 ===" -ForegroundColor Cyan
foreach ($n in $watch) {
    $b = $before[$n]; $a = $after[$n]
    if ($b -ne $a) { Write-Host ("  {0,-14} {1,-12} → {2}" -f $n, $b, $a) -ForegroundColor Green }
    else { Write-Host ("  {0,-14} {1,-12} （未变）" -f $n, $b) -ForegroundColor DarkGray }
}

Write-Host "`n=== 6. 释放算力 ===" -ForegroundColor Cyan
$rel = Invoke-CommandObject @{ action = 'release_power'; pid = $tid }
Write-Host "  返回：$rel" -ForegroundColor Yellow
Start-Sleep -Seconds 2

Write-Host "`n=== 7. 还原后快照 ===" -ForegroundColor Cyan
$restored = SnapPriority $watch
$restored | Format-Table -AutoSize
$ok = $true
foreach ($n in $watch) {
    if ($before[$n] -ne $restored[$n]) { $ok = $false; Write-Host ("  ✗ {0}: 原 {1} → 现 {2}" -f $n, $before[$n], $restored[$n]) -ForegroundColor Red }
}
if ($ok) { Write-Host "  ✓ 优先级全部还原" -ForegroundColor Green }

# 收尾
try { Stop-Process -Id $tid -Force -ErrorAction Stop } catch {}
Write-Host "`n已停目标进程 $tid"
