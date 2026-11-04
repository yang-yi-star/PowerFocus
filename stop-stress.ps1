# stop-stress.ps1 - 停止 node.exe CPU 竞争负载（按 stress-pids.txt）
$ErrorActionPreference = 'Continue'
$f = 'E:\PowerFocus\stress-pids.txt'
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
