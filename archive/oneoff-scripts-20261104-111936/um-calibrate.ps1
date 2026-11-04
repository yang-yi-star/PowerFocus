# um-calibrate.ps1 - 校准一轮：按端口定位 PID，测真实 CPU 占用核数
$ErrorActionPreference = 'Stop'
$out = @()

$endpoint = 'http://127.0.0.1:8080/completion'
$pid_ = (Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess
$out += "被测 PID: $pid_ (端口 8080 监听者)"

$p = Get-Process -Id $pid_ -ErrorAction Stop
$cpu1 = $p.TotalProcessorTime.TotalSeconds
$t1 = [DateTime]::Now

$body = @{ prompt = 'The quick brown fox jumps over the lazy dog. Please continue this text.'; n_predict = 256; temperature = 0.7; stream = $false } | ConvertTo-Json
$resp = Invoke-RestMethod -Uri $endpoint -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 600

$t2 = [DateTime]::Now
$p2 = Get-Process -Id $pid_ -ErrorAction Stop
$cpu2 = $p2.TotalProcessorTime.TotalSeconds

$elapsedSec = ($t2 - $t1).TotalSeconds
$cpuDelta = $cpu2 - $cpu1
$cores = [math]::Round($cpuDelta / $elapsedSec, 2)
$tps = [math]::Round(256 / $elapsedSec, 2)
$gpu = (& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | Select-Object -First 1).Trim()
$sys = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 2)

$out += "耗时秒: $([math]::Round($elapsedSec,1)) | CPU累计增量: $([math]::Round($cpuDelta,1))s | 占用核数: $cores"
$out += "Tokens/s: $tps | GPU显存MB: $gpu | 系统可用GB: $sys"
$line = "校准`t$([math]::Round($elapsedSec*1000,1))`t$tps`t$cores`t$gpu`t$sys"
[System.IO.File]::WriteAllText('E:\PowerFocus\统一内存测试-校准.txt', $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\um-calibrate-console.txt' -Encoding utf8
