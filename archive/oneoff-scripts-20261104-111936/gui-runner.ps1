# gui-runner.ps1 - 等效调用算力调度中心的聚焦函数（与托盘"开始聚焦"同一代码路径）
param([Parameter(Mandatory = $true)][string]$Action)  # gentle | aggressive | stop
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. 'E:\PowerFocus\电脑算力调度中心.ps1'

$server = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq 'E:\Program Files\llama.cpp\bin\llama-server.exe' } | Select-Object -First 1
if (-not $server) { Set-Content -LiteralPath 'E:\PowerFocus\gui-runner-out.txt' -Value "ERROR llama-server not running" -Encoding utf8; exit 1 }
$pid_ = $server.Id

switch ($Action) {
    'gentle' {
        Start-GentleFocus -ProcessId $pid_ -Name 'llama-server'
        Set-Content -LiteralPath 'E:\PowerFocus\gui-runner-out.txt' -Value "gentle focused pid=$pid_ priority=$($server.PriorityClass)" -Encoding utf8
    }
    'aggressive' {
        Start-AggressiveFocus -ProcessId $pid_ -Name 'llama-server'
        $demoted = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.PriorityClass -eq [System.Diagnostics.ProcessPriorityClass]::BelowNormal }).Count
        Set-Content -LiteralPath 'E:\PowerFocus\gui-runner-out.txt' -Value "aggressive focused pid=$pid_ priority=$($server.PriorityClass) demoted_total=$demoted" -Encoding utf8
    }
    'stop' {
        Stop-Focus
        $demoted = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.PriorityClass -eq [System.Diagnostics.ProcessPriorityClass]::BelowNormal }).Count
        Set-Content -LiteralPath 'E:\PowerFocus\gui-runner-out.txt' -Value "focus stopped priority=$($server.PriorityClass) demoted_total=$demoted" -Encoding utf8
    }
}
