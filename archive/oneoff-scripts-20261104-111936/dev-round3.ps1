# dev-round3.ps1 - 让本地模型按决策+纠偏编写增强模块完整代码
$ErrorActionPreference = 'Stop'
$out = @()

$sys = @'
你是资深 PowerShell 工具开发者。你负责为统一内存模式模块编写增强代码。上一轮你已自主决定实施性能骤降告警与上下文余量估算方向，现在按该设计编写完整可运行的 PowerShell 代码。代码必须与本机现有模块风格一致，可直接追加到现有脚本中。本任务要求直接输出代码，不要输出思考过程，不要输出解释性文字。
'@

$usr = @'
任务：为统一内存模式模块编写三个新函数和一个改造函数，全部使用 PowerShell 7 语法，中文注释，UTF-8 编码。

现有模块约定：
1 日志函数 Write-ToolLog，签名 Write-ToolLog -Message 消息 -Level 级别，级别取值 INFO WARN ERROR DEBUG
2 脚本级变量用 $script: 前缀，LlamaHost 为 127.0.0.1，LlamaPort 为 8080
3 函数命名风格为动词-名词，参考现有函数 Get-GpuMemoryInfo、Get-SystemMemoryInfo、Monitor-WeightDistribution
4 现有函数 Get-GpuMemoryInfo 返回数组，每项含 Index TotalMB UsedMB FreeMB 字段
5 现有函数 Get-SystemMemoryInfo 返回哈希表，含 TotalMB AvailableMB CommittedMB 字段

本机已实测关键事实，估算必须采用：
1 Qwen3.8-27B 混合架构 65 层中仅 16 层有注意力 KV 缓存，其余 49 层无 KV
2 64K 上下文 KV 缓存全满实测为 2176 MiB，即每 token KV 开销约 0.0332 MiB
3 服务 8080 为 27B 实例，8686 为 qwen3-4b 实例，8686 严禁触碰
4 llama-server 的 GET /slots 接口返回槽位数组，每项含 n_past 已用 token 数和 n_ctx 槽位总长，n_past 是上下文余量的权威数据源

请编写以下代码：

函数一 Get-ContextRemainingEstimate
功能：查询 /slots 接口获取活跃槽位的 n_past 与 n_ctx，计算剩余可用上下文 token 数。同时调用 Get-GpuMemoryInfo 采样显存，用每 token 0.0332 MiB 的实测系数估算当前 KV 缓存显存占用。输出哈希表，含 RemainingTokens 剩余上下文 token 数、ContextUsedPct 上下文使用百分比、KvCacheMB 估算 KV 占用 MB、GpuFreeMB 当前显存空闲 MB、Healthy 健康布尔值。
接口：参数可选 Port 端口号默认 8080，可选 KvPerTokenMiB 默认 0.0332
注意：健康判定为剩余 token 大于总长的 10% 且显存空闲大于 512 MB 时 Healthy 为真。查询 /slots 失败时返回 Healthy 为假并在日志记录 WARN。

函数二 Test-PerformanceDegradation
功能：维护一个脚本级历史采样队列 $script:PerfSamples，保存最近 10 次生成速度采样值，数组长度超限时移除最旧。输入当前速度值与基线速度值，当当前速度低于基线速度的 50% 时判定为性能骤降，返回哈希表含 Degraded 布尔值、CurrentTps、BaselineTps、Ratio。每次调用把当前速度写入队列，并返回队列长度。
接口：参数 CurrentTps 当前速度，BaselineTps 基线速度，DegradeRatio 阈值系数默认 0.5

函数三 Invoke-ContextCleanup
功能：调用 llama-server 的 POST /slots 接口，请求体含 slot_id 与 cache_prompt 为 false，清空指定槽位的上下文缓存以释放 KV 显存。接口调用失败时记录 ERROR 日志并返回假，成功返回真。若 POST /slots 返回非成功状态码同样视为失败。
接口：参数 SlotId 槽位 ID 默认 0，Port 端口号默认 8080
注意：清空前记录 WARN 日志提示上下文将被清空。此操作不可逆，代码中必须注释说明。

改造函数四 Monitor-WeightDistribution 增强版
功能：在现有显存采样输出基础上，每轮调用 Get-ContextRemainingEstimate 与 Test-PerformanceDegradation。输出行增加上下文剩余 token 数与性能告警状态。当检测到性能骤降或上下文使用超过 90% 或显存空闲低于 512 MB 时，记录 WARN 日志并提示可调用 Invoke-ContextCleanup，但不自动执行清理，等待人工确认。
要求：保留原有参数 SampleCount 与 IntervalSec，原有输出格式尽量保留，新增信息追加在行尾。

输出要求：
1 只输出四个函数的完整 PowerShell 代码，函数之间用空行分隔
2 每个函数前用三行注释说明功能
3 不要输出任何解释文字、测试代码或调用示例
4 全部使用简体中文注释
5 不要使用括号解释，用冒号替代
'@

$body = @{
    model = 'qwen3.8-27b'
    messages = @(
        @{ role = 'system'; content = $sys },
        @{ role = 'user'; content = $usr }
    )
    max_tokens = 4096
    temperature = 0.3
    stream = $false
} | ConvertTo-Json -Depth 6

$out += "请求发送: $(Get-Date -Format 'HH:mm:ss')"
$resp = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/chat/completions' -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 2400
$out += "响应到达: $(Get-Date -Format 'HH:mm:ss')"
$out += "finish_reason: $($resp.choices[0].finish_reason)"
$out += "usage: $($resp.usage | ConvertTo-Json -Compress)"
$answer = $resp.choices[0].message.content
$out += "输出长度: $($answer.Length) 字符"
$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\dev-round3-meta.txt' -Encoding utf8
$answer | Set-Content -LiteralPath 'E:\PowerFocus\dev-round3-out.txt' -Encoding utf8
'完成'
