# start-stress.ps1 - 启动 node.exe CPU 竞争负载（24 个进程，独立 js 文件）
$ErrorActionPreference = 'Stop'
$node = (Get-Command node -ErrorAction Stop).Source
$js = 'E:\PowerFocus\stress.js'
# 先清理残留 node 竞争进程
if (Test-Path -LiteralPath 'E:\PowerFocus\stress-pids.txt') {
    Get-Content -LiteralPath 'E:\PowerFocus\stress-pids.txt' | ForEach-Object { try { Stop-Process -Id ([int]$_) -Force -ErrorAction Stop } catch {} }
}
$pids = @()
for ($i = 0; $i -lt 24; $i++) {
    $p = Start-Process -FilePath $node -ArgumentList $js -WindowStyle Hidden -PassThru
    $pids += $p.Id
}
$pids | Set-Content -LiteralPath 'E:\PowerFocus\stress-pids.txt'
Start-Sleep -Seconds 6
$alive = @(Get-Process -Name 'node' -ErrorAction SilentlyContinue).Count
Set-Content -LiteralPath 'E:\PowerFocus\stress-check.txt' -Value ("started=" + $pids.Count + " alive=" + $alive) -Encoding utf8
