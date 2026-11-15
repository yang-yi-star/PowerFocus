# 实测 QQ / DSH 的链路状态：连接对端、IO 活动速率、CPU 占用
$names = @('QQ','QQEX','DeepSeek Harness')

"=== 1. 进程与累计 IO 计数 ==="
$targets = foreach ($n in $names) { Get-Process -Name $n -ErrorAction SilentlyContinue }
if (-not $targets) { "未找到目标进程"; exit }

"{0,-20} {1,-7} {2,10} {3,12} {4,12} {5,10}" -f '进程','PID','内存MB','累计读MB','累计写MB','CPU秒'
'-' * 80
foreach ($p in $targets) {
    "{0,-20} {1,-7} {2,10} {3,12:N1} {4,12:N1} {5,10:N2}" -f $p.ProcessName, $p.Id,
        [math]::Round($p.WorkingSet64/1MB),
        ($p.ReadTransferCount/1MB), ($p.WriteTransferCount/1MB),
        ($p.TotalProcessorTime.TotalSeconds)
}

"`n=== 2. 采样 4 秒的 IO / CPU 速率（判断是不是真在活动）==="
$snap1 = @{}
foreach ($p in $targets) { $snap1[$p.Id] = @{ R=$p.ReadTransferCount; W=$p.WriteTransferCount; C=$p.TotalProcessorTime.TotalSeconds } }
Start-Sleep -Seconds 4
$snap2 = @{}
foreach ($p in (Get-Process -Name $names -ErrorAction SilentlyContinue)) {
    $snap2[$p.Id] = @{ R=$p.ReadTransferCount; W=$p.WriteTransferCount; C=$p.TotalProcessorTime.TotalSeconds }
}
"{0,-20} {1,-7} {2,14} {3,14} {4,14}" -f '进程','PID','读 KB/s','写 KB/s','CPU %'
'-' * 80
foreach ($id in $snap2.Keys) {
    if (-not $snap1.ContainsKey($id)) { continue }
    $r = ($snap2[$id].R - $snap1[$id].R) / 4 / 1KB
    $w = ($snap2[$id].W - $snap1[$id].W) / 4 / 1KB
    $c = ($snap2[$id].C - $snap1[$id].C) / 4 * 100
    $nm = (Get-Process -Id $id -ErrorAction SilentlyContinue).ProcessName
    "{0,-20} {1,-7} {2,14:N1} {3,14:N1} {4,14:N1}" -f $nm, $id, $r, $w, $c
}

"`n=== 3. TCP 连接（Established / Listen）==="
$pids = $targets.Id
$conns = Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -in $pids }
if (-not $conns) { "无 TCP 连接" }
else {
    "{0,-7} {1,-20} {2,-22} {3,-14} {4}" -f 'PID','本地','对端','状态','对端是否本机'
    '-' * 90
    foreach ($c in $conns | Sort-Object OwningProcess, State) {
        $localIsLoop = $c.LocalAddress -in @('127.0.0.1','::1','0.0.0.0','::')
        $remoteIsLoop = $c.RemoteAddress -in @('127.0.0.1','::1','0.0.0.0','::')
        "{0,-7} {1,-20} {2,-22} {3,-14} {4}" -f $c.OwningProcess,
            "$($c.LocalAddress):$($c.LocalPort)", "$($c.RemoteAddress):$($c.RemotePort)",
            $c.State, ($(if($remoteIsLoop){'本机/回环'}else{'外部'}))
    }
}

"`n=== 4. DSH 的父进程链（看是不是挂在 QQ 生态里）==="
$ppid = @{}
foreach ($w in (Get-CimInstance Win32_Process -Filter "Name='QQ.exe' OR Name='QQEX.exe' OR Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue)) {
    $ppid[$w.ProcessId] = $w.ParentProcessId
}
foreach ($k in $ppid.Keys) {
    $parent = Get-Process -Id $ppid[$k] -ErrorAction SilentlyContinue
    $pname = if ($parent) { $parent.ProcessName } else { '(已退出)' }
    "  PID $k -> 父 PID $($ppid[$k]) ($pname)"
}
