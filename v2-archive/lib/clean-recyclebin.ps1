# PowerFocus - daily recycle bin cleaner
# Scope: C: only (per user decision 2026-11-04; D: and E: left untouched)
# Called by scheduled task "PowerFocusClearRecycleBin" every day at 03:00
#
# NOTE: Clear-RecycleBin is NOT used. It aborts with
#   "The system cannot find the path specified"
# when the bin contains orphaned $I metadata entries, leaving everything in place.
# We purge the SID subfolders directly instead. Remove-Item performs a true delete
# here (verified 2026-11-04: recycle bin file count unchanged after Remove-Item).

$ErrorActionPreference = 'Continue'

$logPath = 'E:\PowerFocus\logs\recyclebin-clean.log'
$logDir  = Split-Path -Parent $logPath
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Get-RecycleBinSizeMB {
    param([string]$Drive)
    $root = '{0}:\$Recycle.Bin' -f $Drive
    if (-not (Test-Path -LiteralPath $root)) { return 0 }
    $m = Get-ChildItem -LiteralPath $root -Force -Recurse -File -ErrorAction SilentlyContinue |
         Measure-Object -Property Length -Sum
    if ($m.Sum) { return [math]::Round($m.Sum / 1MB, 2) }
    return 0
}

$stamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$before = Get-RecycleBinSizeMB -Drive 'C'
$root   = 'C:\$Recycle.Bin'
$deleted = 0
$failed  = 0
$failedSample = @()

if (Test-Path -LiteralPath $root) {
    $sidDirs = Get-ChildItem -LiteralPath $root -Force -Directory -ErrorAction SilentlyContinue
    foreach ($sid in $sidDirs) {
        # Keep the SID folder itself; purge only its contents.
        $items = Get-ChildItem -LiteralPath $sid.FullName -Force -ErrorAction SilentlyContinue
        foreach ($it in $items) {
            try {
                Remove-Item -LiteralPath $it.FullName -Force -Recurse -ErrorAction Stop
                $deleted++
            } catch {
                $failed++
                if ($failedSample.Count -lt 3) { $failedSample += $_.Exception.Message }
            }
        }
    }
}

Start-Sleep -Seconds 1
$after = Get-RecycleBinSizeMB -Drive 'C'
$freed = [math]::Round($before - $after, 2)
$status = 'OK'
if ($failed -gt 0) { $status = 'WARN' }
if ($before -gt 0 -and $freed -le 0 -and $failed -gt 0) { $status = 'ERR' }

$detail = 'deleted={0} failed={1}' -f $deleted, $failed
if ($failedSample.Count -gt 0) { $detail += ' | ' + ($failedSample -join ' ; ') }

$line = '{0}  {1,-4}  before={2}MB after={3}MB freed={4}MB  {5}' -f $stamp, $status, $before, $after, $freed, $detail
Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
