# v0.06 破坏性 action 实测：kill / suspend / resume / stress / 保护名单
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$kernel = Join-Path $root 'versions\v0.09'
$token = ''
try { $token = (Get-Content (Join-Path $kernel '.auth_token') -Raw).Trim() } catch {}
if (-not $token) { 'ERROR: token 文件读取失败（请先启动一次内核）'; exit 1 }
$cmdIn = Join-Path $kernel 'commands\in'
$cmdDone = Join-Path $kernel 'commands\done'
$sw = [Diagnostics.Stopwatch]::StartNew()

function Send-Cmd([string]$name, [hashtable]$body) {
    $body['token'] = $token
    $f = Join-Path $cmdIn ("probe-" + $name + "-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".json")
    ($body | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $f -Encoding utf8
    $base = [IO.Path]::GetFileNameWithoutExtension($f)
    $rf = Join-Path $cmdDone ($base + ".json.result.txt")
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $rf) {
            $t0 = (Get-Date)
            Start-Sleep -Milliseconds 200
            return (Get-Content -LiteralPath $rf -Raw)
        }
        Start-Sleep -Milliseconds 300
    }
    return "TIMEOUT: 未在 20 秒内拿到结果"
}

function New-TestProcess($n) {
    return Start-Process 'C:\Tools\PowerShell7\pwsh.exe' -ArgumentList '-NoProfile','-Command',"`$e=0; while(`$true){`$e+=1; Start-Sleep -Milliseconds 20}" -PassThru -WindowStyle Hidden
}

'===== 1) kill_process ====='
$a = New-TestProcess 1; Start-Sleep -Seconds 2
"目标 PID=$($a.Id) 存活=$([bool](Get-Process -Id $a.Id -ErrorAction SilentlyContinue))"
Send-Cmd 'kill' @{ action='kill_process'; pid=$a.Id }
Start-Sleep -Milliseconds 800
"结果存活=$([bool](Get-Process -Id $a.Id -ErrorAction SilentlyContinue))"

'===== 2) suspend_process ====='
$b = New-TestProcess 2; Start-Sleep -Seconds 2
$c0 = (Get-Process -Id $b.Id).TotalProcessorTime
Send-Cmd 'suspend' @{ action='suspend_process'; pid=$b.Id }
Start-Sleep -Seconds 2
$c1 = (Get-Process -Id $b.Id).TotalProcessorTime
"挂起期间 CPU 增量=$([math]::Round(($c1-$c0).TotalSeconds,3))s（≈0 即冻结成功）"

'===== 3) resume_process ====='
Send-Cmd 'resume' @{ action='resume_process'; pid=$b.Id }
Start-Sleep -Seconds 2
$c2 = (Get-Process -Id $b.Id).TotalProcessorTime
"恢复后 CPU 增量=$([math]::Round(($c2-$c1).TotalSeconds,3))s（>0 即恢复成功）"
Stop-Process -Id $b.Id -Force -ErrorAction SilentlyContinue

'===== 4) stress_process (crash 模式) ====='
$d = New-TestProcess 4; Start-Sleep -Seconds 2
$ws0 = (Get-Process -Id $d.Id).WorkingSet64
"压制前 WS=$([math]::Round($ws0/1MB,1))MB"
Send-Cmd 'stress' @{ action='stress_process'; pid=$d.Id; mode='crash' }
Start-Sleep -Seconds 1
$d2 = Get-Process -Id $d.Id -ErrorAction SilentlyContinue
if ($d2) {
    "压制后 WS=$([math]::Round($d2.WorkingSet64/1MB,1))MB Responding=$($d2.Responding)"
    Send-Cmd 'resume2' @{ action='resume_process'; pid=$d.Id } | Out-Null
    Stop-Process -Id $d.Id -Force -ErrorAction SilentlyContinue
} else { '压制后进程已退出（崩掉）' }

'===== 5) 保护名单（对 lsass 投 kill） ====='
Send-Cmd 'protect' @{ action='kill_process'; process_name='lsass' }
"lsass 仍存活=$([bool](Get-Process lsass -ErrorAction SilentlyContinue))"

'===== 6) 无 token 投 kill（应被拒绝） ====='
$e = New-TestProcess 6; Start-Sleep -Seconds 2
$f = Join-Path $cmdIn ("probe-notoken-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".json")
(@{ action='kill_process'; pid=$e.Id } | ConvertTo-Json) | Set-Content -LiteralPath $f -Encoding utf8
$base2 = [IO.Path]::GetFileNameWithoutExtension($f)
$rf2 = Join-Path $cmdDone ($base2 + ".json.result.txt")
$dl = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $dl -and -not (Test-Path -LiteralPath $rf2)) { Start-Sleep -Milliseconds 300 }
if (Test-Path -LiteralPath $rf2) { Get-Content -LiteralPath $rf2 -Raw } else { 'TIMEOUT' }
"进程仍存活=$([bool](Get-Process -Id $e.Id -ErrorAction SilentlyContinue))（应为 True：token 缺失被拒）"
Stop-Process -Id $e.Id -Force -ErrorAction SilentlyContinue

"总耗时 $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
