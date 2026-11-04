# dev-round1.ps1 - 让本地模型自主决策统一内存模块的下一步开发方向
$ErrorActionPreference = 'Stop'
$out = @()

$sys = @'
你是资深本地大模型部署工程师与 PowerShell 工具开发者。你的任务是分析你现有的一套自研小程序，并自主决定下一步如何增强开发。你拥有独立的工程判断，外部候选列表仅供参考，你有权采纳、修改或否定其中任何一项，也有权提出自己的新方向。
'@

$usr = @'
背景：
你维护两个自研小程序，运行在 Windows 11 本机，开发语言为 PowerShell 7。
小程序一：统一内存模式模块，文件路径 E:\PowerFocus\统一内存模式.ps1。它模拟苹果统一内存推理：GGUF 模型权重 mmap 驻留系统内存，GPU 承担尽可能多的层计算，CPU 承担剩余层，CPU 与 GPU 共享同一份物理权重页。
小程序二：电脑算力调度中心托盘工具，文件路径 E:\PowerFocus\电脑算力调度中心.ps1。WPF 托盘程序，可对目标进程执行 CPU 优先级聚焦、看门狗守护、电源计划切换、白名单管理、开机自启。

统一内存模式模块现有能力清单：
1 自动层数分配函数 Calculate-OptimalLayerSplit，根据 GPU 空闲显存自动计算可卸载到 GPU 的最大层数，每层大小按模型文件大小除以 GGUF 总层数估算，钳制在实测安全上限 20 层
2 GGUF 元数据解析函数 Get-GgufLayerCount，按 GGUF v3 二进制规范读取总层数
3 启动管理函数 Start-UnifiedMemoryMode，启动前先按 8080 端口停旧实例，生成带最优层数与 KV 缓存 q8 量化的 llama-server 参数，等待端口就绪最长 180 秒
4 停止与状态函数 Stop-UnifiedMemoryMode、Show-MemoryStatus
5 权重分布监控函数 Monitor-WeightDistribution，循环采样 GPU 显存与系统内存，推算权重驻留比例
6 看门狗函数 Start-Watchdog，轮询端口，进程意外退出自动重启最多 3 次
7 日志函数 Write-ToolLog，UTF-8 带时间戳级别日志

电脑算力调度中心现有能力清单：
1 托盘 UI 与目标进程选择
2 温和聚焦：非白名单进程优先级降为 BelowNormal
3 激进聚焦：非白名单进程优先级降为 Idle
4 看门狗定时器：定期检查目标进程存活
5 电源计划切换：高性能计划
6 白名单管理与开机自启
7 日志文件

本机环境事实：
1 硬件：AMD Ryzen 9 8940HX 16核32线程，RTX 5060 Laptop 8GB 显存，系统内存 32GB
2 模型：Qwen3.8-27B Q4_K_M 约15.33GB，GGUF 元数据 context_length 262144 原生 256K，nextn_predict_layers 1 自带 MTP 头，混合架构 65 层中仅 16 层有注意力 KV 缓存
3 服务：llama-server b12032，8080 端口 27B 实例，8686 端口 qwen3-4b 实例必须保留
4 当前配置：64K 上下文，KV 缓存 q8_0，GPU 20 层 CPU 45 层，实测生成速度约 3.2 到 4.4 t/s
5 已实测结论：MTP 投机解码在本机因 GPU 仅卸载 20 层，draft 推理落在 CPU，实测反而减速约 16% 到 39%，已放弃

外部候选方向供你参考，你有权采纳、修改或否定：
候选A：NVIDIA 控制面板 CUDA Sysmem Fallback 策略检查与建议固化，防止显存溢出时性能骤降 5 到 10 倍
候选B：性能骤降告警与上下文余量估算
候选C：双实例 GPU 时间片调度
候选D：远期观望项：子层分片、Windows ML 对接

任务：
1 请先给出你对现有两个小程序的价值判断，指出最值得增强的薄弱环节
2 自主决定下一步开发方向，可以来自候选列表，也可以是你自己提出的新方向，给出你的理由
3 针对你选定的方向，给出具体增强设计，包括新增函数名、功能描述、接口、与其他函数的协作方式、优先级排序
4 给出验证方案，说明如何在本机实测确认增强有效

输出要求：
1 只输出最终决策内容，不要输出思考过程
2 使用编号列表组织
3 全部使用简体中文
4 不要使用括号解释，用冒号替代
5 不要输出代码，只输出设计与决策
'@

$body = @{
    model = 'qwen3.8-27b'
    messages = @(
        @{ role = 'system'; content = $sys },
        @{ role = 'user'; content = $usr }
    )
    max_tokens = 3072
    temperature = 0.4
    stream = $false
} | ConvertTo-Json -Depth 6

$out += "请求发送: $(Get-Date -Format 'HH:mm:ss')"
$resp = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/chat/completions' -Method POST -Body $body -ContentType 'application/json' -TimeoutSec 2400
$out += "响应到达: $(Get-Date -Format 'HH:mm:ss')"
$out += "finish_reason: $($resp.choices[0].finish_reason)"
$out += "usage: $($resp.usage | ConvertTo-Json -Compress)"
$answer = $resp.choices[0].message.content
$out += "输出长度: $($answer.Length) 字符"
$out -join "`n" | Set-Content -LiteralPath 'E:\PowerFocus\dev-round1-meta.txt' -Encoding utf8
$answer | Set-Content -LiteralPath 'E:\PowerFocus\dev-round1-out.txt' -Encoding utf8
'完成'
