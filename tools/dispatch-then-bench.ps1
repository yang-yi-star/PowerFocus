# 调度组：先用 PowerFocus 内核的 request_power 给 ollama 补给算力，再测速
$k = 'E:\PowerFocus\versions\v0.11\电脑算力调度中心_v0.11.ps1'
. $k

$ollamaPid = (Get-Process -Name 'ollama' -ErrorAction SilentlyContinue | Select-Object -First 1).Id
if (-not $ollamaPid) { "ERROR: ollama 未运行"; exit 1 }
"ollama PID = $ollamaPid"

"`n=== 1. 调 request_power（level=aggressive, duration=600s）==="
$r = Invoke-CommandObject @{ action = 'request_power'; pid = $ollamaPid; level = 'aggressive'; duration = 600; reason = 'bench-ab 实测：给 ollama 补给整机算力' }
"返回: $r"

"`n=== 2. 补给后 ollama 优先级 ==="
(Get-Process -Id $ollamaPid).PriorityClass

"`n=== 3. 当前系统状态 ==="
$m = Get-CimInstance Win32_OperatingSystem
"可用内存: $([math]::Round($m.FreePhysicalMemory/1024,1)) MB / $([math]::Round($m.TotalVisibleMemorySize/1024,1)) MB"
& nvidia-smi --query-gpu=memory.total,memory.used,memory.free,utilization.gpu --format=csv,noheader,nounits
