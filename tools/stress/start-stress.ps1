# start-stress.ps1 - 启动 node.exe CPU 竞争负载（24 个进程，独立 js 文件）
# 2026-11-15 根目录清理：脚本与 stress.js 一并迁至 tools\stress\，路径改为相对本脚本
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$node = (Get-Command node -ErrorAction Stop).Source
$js = Join-Path $dir 'stress.js'
$pidsFile = Join-Path $dir 'stress-pids.txt'
# 先清理残留 node 竞争进程
if (Test-Path -LiteralPath $pidsFile) {
    Get-Content -LiteralPath $pidsFile | ForEach-Object { try { Stop-Process -Id ([int]$_) -Force -ErrorAction Stop } catch {} }
}
$pids = @()
for ($i = 0; $i -lt 24; $i++) {
    $p = Start-Process -FilePath $node -ArgumentList $js -WindowStyle Hidden -PassThru
    $pids += $p.Id
}
$pids | Set-Content -LiteralPath $pidsFile
Start-Sleep -Seconds 6
$alive = @(Get-Process -Name 'node' -ErrorAction SilentlyContinue).Count
Set-Content -LiteralPath (Join-Path $dir 'stress-check.txt') -Value ("started=" + $pids.Count + " alive=" + $alive) -Encoding utf8
