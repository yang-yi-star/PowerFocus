# watchdog-test.ps1 - 验证看门狗：聚焦+监管启动后，手动降级目标，10 秒内应被拉回 High
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. 'E:\PowerFocus\电脑算力调度中心.ps1'

$server = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq 'E:\Program Files\llama.cpp\bin\llama-server.exe' } | Select-Object -First 1
if (-not $server) { Write-Output 'ERROR no llama-server'; exit 1 }
$pid_ = $server.Id

Start-GentleFocus -ProcessId $pid_ -Name 'llama-server'
Start-Watchdog -ProcessId $pid_ -Name 'llama-server'

# 手动降级目标进程
(Get-Process -Id $pid_).PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
Write-Output ("manually demoted -> " + (Get-Process -Id $pid_).PriorityClass)

# 泵消息让 Timer 回调跑起来
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 14) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 200
}
$final = (Get-Process -Id $pid_).PriorityClass
Write-Output ("after 14s watchdog -> " + $final)
Stop-Focus
Write-Output ("after stop-focus -> " + (Get-Process -Id $pid_).PriorityClass)
