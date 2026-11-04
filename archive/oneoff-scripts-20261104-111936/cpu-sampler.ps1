# cpu-sampler.ps1 - 每 1 秒采样指定进程 CPU%，写入 csv，直到被停止
param([string]$ProcName = 'llama-server', [string]$OutFile = 'E:\PowerFocus\cpu-samples.csv')
$ErrorActionPreference = 'Continue'
$rows = @()
$start = Get-Date
$procId = $null
$p = Get-Process -Name $ProcName -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq 'E:\Program Files\llama.cpp\bin\llama-server.exe' } | Select-Object -First 1
if ($p) { $procId = $p.Id }
while ($true) {
    $ts = (Get-Date) - $start
    $v = 0.0
    if ($procId) {
        $ctr = Get-Counter -LiteralPath "\Process(llama-server)\% Processor Time" -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue
        if ($ctr) { $v = [math]::Round($ctr.CounterSamples[0].CookedValue, 1) }
    }
    $rows += ("{0:0.0},{1}" -f $ts.TotalSeconds, $v)
    if ($rows.Count -ge 600) { break }
    Start-Sleep -Milliseconds 900
}
Set-Content -LiteralPath $OutFile -Value ($rows -join "`n") -Encoding utf8
