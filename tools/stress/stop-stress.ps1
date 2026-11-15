# stop-stress.ps1 - 停止 node.exe CPU 竞争负载（按 stress-pids.txt）
# 2026-11-15 根目录清理：路径改为相对本脚本
$ErrorActionPreference = 'Continue'
$f = Join-Path $PSScriptRoot 'stress-pids.txt'
if (Test-Path -LiteralPath $f) {
    $pids = Get-Content -LiteralPath $f
    foreach ($id in $pids) {
        try { Stop-Process -Id ([int]$id) -Force -ErrorAction Stop } catch {}
    }
    Remove-Item -LiteralPath $f -Force
    Write-Output ("stopped " + $pids.Count + " stress processes")
} else {
    Write-Output 'no stress pid file'
}
