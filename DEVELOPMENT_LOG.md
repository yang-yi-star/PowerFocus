# 电脑算力调度中心 · 开发日志（DEVELOPMENT_LOG.md）

> **本文件是本项目唯一权威开发日志，追加式（append-only），最新条目在文件底部。**
> **给任何 AI 的阅读指引**：本文件位于 `E:\PowerFocus\DEVELOPMENT_LOG.md`（绝对路径，UTF-8 编码）。
> 全机 AI 资产台账 `E:\AI 调度中心\index.md` 与 `manifest.json` 已登记本文件位置——任何 AI 先读台账、再读本日志，即可了解项目全部历史与现状。
> 配套代码目录：`E:\PowerFocus\`。台账生成时间：2026-11-03。

---

## 2026-11-03 04:56 · v1 评审（电脑算力调度中心.ps1）

评审对象：`E:\PowerFocus\电脑算力调度中心.ps1`（约 370 行，托盘算力聚焦工具）。

发现的问题（按严重度）：
1. **[严重]** `Stop-Focus` 不还原目标进程优先级——聚焦后永久遗留 High，watchdog 还会强行拉回。
2. **[严重]** 激进模式降级进程恢复时一律设回 Normal，覆盖原始优先级（原本 BelowNormal/Idle 的进程反被抬高）。
3. **[严重]** `powercfg` native 命令失败被 try/catch 静默吞掉（PowerShell native 命令不抛异常），高性能计划 GUID 不存在时无任何日志。
4. 进程列表按"累计 CPU 秒"排序，非实时占用率，找不到"现在谁在吃算力"。
5. 日志无轮转，无限增长。
6. watchdog 硬编码拉回 High，无法支持其他优先级档位。
7. 自启任务名含中文，schtasks 有编码坑。

设计正确的部分（保留）：托盘常驻 + 温和/激进两档 + 10s watchdog + 退出恢复 + dot-source 保护 + 系统进程白名单。

## 2026-11-03 04:58 · v2 修复版（电脑算力调度中心_v2.ps1）

按用户铁律**新建文件**，不覆盖 v1。修复上述全部 7 项：
1. 聚焦前记录 `$TargetOriginalPriority`，`Stop-Focus` 写回原值。
2. `DemotedPids` 改为 `PID → 原优先级` 哈希表；原本就低优先级的进程不动。
3. 新增 `Invoke-Native` 统一检查 `$LASTEXITCODE`。
4. 进程列表改 500ms 两次 `TotalProcessorTime` 采样差分 → 实时 CPU%。
5. 日志超 5MB 自动归档 `.bak`。
6. watchdog 按 `$TargetDesiredPriority` 守护，支持 High/RealTime。
7. 自启任务名改英文 `PowerFocusAutoV2`。

同批新增两大机制（架构阶段一）：
- **授权"开后门"机制**：`authorized_apps.json` 准入清单（已有 llama-server 预置）+ `.auth_token` 本机密钥（首次运行自动生成）。清单外目标一律拒绝。GodMode = High/RealTime 优先级 + PriorityBoostEnabled + 高性能电源 + watchdog 守护。
- **JSON 命令总线**：轮询 `E:\PowerFocus\commands\in\*.json`（2s），动作 `focus/unfocus/status/authorize/revoke/set_priority/set_power_plan`；结果写 `done\*.result.txt`；`status` 快照写 `commands\out\status.json`。authorize/revoke 必须携带 token。

验证：Parser 语法 OK；dot-source 12 个关键函数全部定义；功能 smoke test（授权命中/拒绝、优先级映射）全过。**未启动常驻进程**（用户手动启动托盘验证）。

架构规划（四阶段）：①修复+命令总线 → ②自然语言层 → ③资源维度扩展 → ④规则引擎。GPU 说明：Windows 无按进程 GPU 优先级公开 API，只能间接倾斜，不画饼。

## 2026-11-03 05:07 · 阶段二：自然语言控制层（nl-gateway.ps1 + nl-parser.ps1）

新建文件：
- `E:\PowerFocus\nl-parser.ps1` —— 规则解析函数库（离线快速路径）：9 类中文句型 → 命令 JSON（status/unfocus/授权/撤销/GodMode 开后门/激进聚焦/温和聚焦/优先级/电源计划），进程名自动从运行中进程匹配（最长名优先）。
- `E:\PowerFocus\nl-gateway.ps1` —— NL 网关，两种模式：
  - 交互模式：`pwsh -File nl-gateway.ps1`（说人话，敏感命令二次确认）
  - 单次模式：`-Command "..."`（供外部 AI / 脚本调用）
- 翻译两级：规则解析优先 → LLM 兜底（`http://localhost:8080/v1/chat/completions`，OpenAI 兼容，system prompt 内约束 schema，temperature 0.1）。`-NoModel` 可强制纯规则。

安全设计：
- `authorize/revoke` 属敏感命令：**LLM 永远无权生成**；人工指令必须交互模式二次确认；单次模式一律拒绝；执行前注入 `.auth_token`。
- LLM 输出过 action/mode/priority/plan 白名单校验（`Test-CommandAllowed`），防幻觉。

测试：两文件 Parser OK；9 条规则句型全命中；命令直测（未授权 focus 拒绝、非法参数拒绝、未知 action 拒绝）全过；**总线文件全链路往返打通**（in → 处理 → done+result → out/status.json 十字段含 Top5 CPU）。

开发中逮到并修复的 bug：
- nl-gateway 初版 `param()` 放在 `[Console]::OutputEncoding` 之后——PowerShell 要求 param 是首个可执行语句，已修正。
- v2 的 status 写盘前未确保 out 目录存在（dot-source 场景不跑初始化会炸）——v2 已加防御性 `New-Item -Force`。
- 测试 helper 一处 `(expected)` 笔误导致运行时错误（测试脚本自身问题，非项目代码）。

实测备注：测试时 8080 主推理服务未在线，LLM 兜底路径待用户起服务后自动生效；规则路径零依赖。

## 2026-11-03 05:17 · 开发日志体系建立

- 创建本文件（`E:\PowerFocus\DEVELOPMENT_LOG.md`），补录 v1 评审 / v2 / 阶段二全部历史。
- 在全机 AI 台账 `E:\AI 调度中心\index.md`（第三节 PowerFocus 表 + 定位说明）和 `manifest.json`（新增 dev_log 字段）登记本文件，达成"**任何 AI 读台账 → 知日志位置 → 读日志知全部开发史**"。
- 日志纪律：此后每次开发（新文件/新动作/修复/决策/测试结果）都必须追加条目到本文件底部，append-only。

（后续条目追加于此线之下）

## 2026-11-03 05:17-05:30 · 阶段三：资源维度扩展与场景模式

本轮目标：让调度中心从"CPU 优先级倾斜"升级为**多资源维度调度**，并为任何 AI 提供可读开发日志。

### 一、开发日志体系（本轮新增）
- 创建 `E:\PowerFocus\DEVELOPMENT_LOG.md`（本文件），补录全部历史。
- 台账登记：`E:\AI 调度中心\index.md` 第三节 + `manifest.json` 新增 `dev_log` 字段。**任何 AI 读台账 → 知日志 → 知全部开发史。**
- 日志纪律：append-only，最新在底部，每次开发必记。

### 二、v2 新增动作（命令总线，编辑 电脑算力调度中心_v2.ps1）

| 动作 | 机制 | 说明 |
|---|---|---|
| `trim_memory` | psapi!EmptyWorkingSet | 修剪非白名单/非目标进程工作集，释放物理内存给目标 |
| `set_io_priority` | ntdll!NtSetInformationProcess(ProcessIoPriority=0x21) | VeryLow/Low/Normal/High 四档磁盘 I/O 优先级 |
| `set_net_qos` | NetQosPolicy 模块 | 按进程限速（rate_mbps，0=撤销）；**需管理员权限**，失败明确报错 |
| `apply_scene` | scenes.json 步骤序列 | 一键场景；场景内禁止 authorize/revoke（白名单强制） |
| `list_scenes` | — | 列出可用场景 |

- **GodMode 升级**：附加 I/O 优先级 High（记录原值 `$TargetOriginalIoPriority`，Stop-Focus 还原原值——延续"原值还原"铁律）；watchdog 同步守护 I/O 优先级。
- **status 快照**新增 `desired_io_priority` 字段。
- 默认场景文件 `E:\PowerFocus\scenes.json`（不存在时自动生成）：`inference`（llama-server GodMode+IO High+内存修剪+高性能）/ `gaming`（高性能+修剪）/ `relax`（全部还原）。用户可直接编辑扩展场景。

### 三、NL 层同步（nl-parser.ps1 / nl-gateway.ps1）
- 新句型：场景（"进入推理模式"/"有哪些场景"/"应用场景 X"）、内存（"释放/清理/修剪内存"）、I/O（"磁盘优先级压低/最高"）、限速（"给 X 限速 2 兆"/"解除 X 的限速"）。
- `Test-CommandAllowed` 白名单扩至 10 个动作；set_io_priority / set_net_qos / apply_scene 字段级校验。
- LLM system prompt 同步 13 个动作（authorize/revoke 依旧禁止）。

### 四、开发中逮到并修复的 bug（测试驱动）
1. **规则截胡**：unfocus 正则的宽泛 `解除` 会截胡"解除限速"→ 收紧为 `解除聚焦|取消聚焦|...`。
2. **规则截胡 2**："磁盘优先级压低"被聚焦正则的 `优先(级)?` 截胡 → I/O 规则整块提前到聚焦规则之前。
3. **句型漏配**："释放一下内存"因正则要求紧邻而漏配 → 放宽为 `释放.*内存|清[理空除].*内存` 等。
4. **计数少报**：EmptyWorkingSet 后立即回读 WorkingSet64，页面换出是异步的导致 0 计数 → 计数以 API 返回值为准，释放量为"立即回读估计值"（实际释放体现在后续内存压力下降）。
5. **诊断增强**：set_power_plan 失败时附 `powercfg /list` 输出（本机实测无标准平衡计划 GUID，属环境现实非 bug）。

### 五、测试证据（dot-source 直测，未启动常驻进程）
- 三文件 Parser 全 OK。
- `list_scenes` 正确列出 3 场景；未知场景/非法 I/O 档位正确拒绝。
- **I/O 优先级实测生效**：对当前 pwsh 进程 NtSet(Normal) 返回 0，NtQuery 读回 2 (Normal)——读写链路验证成功。
- **内存修剪实测生效**：对自身进程 EmptyWorkingSet 后工作集 167MB→7MB；外部进程探测 382 个中 353 个成功；总线调用 trim_memory 报告 179 个进程。
- relax 场景执行成功（unfocus OK；本机无平衡计划如实报错并附可用计划清单）。
- NL 句型重测：IO/内存/场景/限速/解除聚焦全部命中。

### 六、当前项目边界与待办
- 网络限速需管理员权限运行调度中心才可用（普通权限下明确报错）。
- 本机电源计划集合不全（无标准平衡/高性能 GUID 时对应动作会报错并列出可用计划）。
- v2 托盘 UI 与 nl-gateway 交互模式仍未实机启动验证（需用户手动跑）。
- 阶段四（规则引擎：条件自动化/心跳上报）未开工。

## 2026-11-03 10:10 · 阶段四：规则引擎（全网备料驱动开发）✅ 已交付

### 一、备料（用户令"全面性开发，上网找案例/原型/资料/论文验证和使用"）
三批检索 + ProBalance 官方算法文档全文精读，可借鉴机制：
- **ProBalance（Process Lasso）**：后台进程 CPU 超阈值且持续超时 → 临时降 BelowNormal；三原则 Temporary/Marginal/Selective（前台进程与"没惹事"的进程永不碰）；官方警示"不要手动把重要进程拉 High/RealTime，反向压制更安全"——与本项目 GodMode 互补，规则引擎即"自动防御"维度。
- **EcoQoS 效率模式（Microsoft Learn 官方 API）**：`SetProcessInformation` + `PROCESS_POWER_THROTTLING_EXECUTION_SPEED` → 进程分类 EcoQoS，系统降频/调度到能效核。比手动改优先级更优雅的后台压制档位。
- **CPU 亲和性**：`SetProcessAffinityMask`（Process Lasso 持久亲和性规则、ProBalanceDropOneRandomCore 思路）。
- **开源原型**：Process Governor（Python 规则引擎）/ PLimit（.NET EcoQoS）/ Better Task Manager（per-process 监控）/ Process Hacker（持久化优先级）。
- **论文**：Stanford SMART（优先级+份额统一定义）、动态优先级调度、优先级反转等——份额制/动态优先级留作阶段五素材。
- **规则引擎范式**：Microsoft RulesEngine / PSRule（JSON 规则+优先级+多输入）——与 scenes.json/命令总线同构。

### 二、新增文件
| 文件 | 说明 |
|---|---|
| `E:\PowerFocus\rules-engine.ps1` | 规则引擎本体（377 行）：条件→动作→自动还原 + 心跳 + 热更新 |
| `E:\PowerFocus\rules.json` | 规则定义：`inference-godmode`（llama-server 吃算力自动 GodMode，闲置还原）+ `restrain-background-cpu`（非前台/非白名单/非授权后台进程持续高 CPU 降级还原） |
| `E:\PowerFocus\rules_state.json` | 引擎心跳（time/running/foreground_pid/rules_active，2s 更新） |
| `E:\PowerFocus\rules.json.bak` | 规则原版备份（自测版曾临时覆盖，已恢复原版） |

### 三、机制设计（ProBalance 范式）
- **when 条件**：`process_name`(正则) / `cpu_gt_pct` / `cpu_lt_pct` / `mem_gt_mb` / `is_foreground` / `not_foreground` / `not_in_whitelist` / `not_authorized` + `for_seconds` 持续判定（ProBalance 的"持续超时"）。
- **then 动作**：`focus`(godmode/aggressive) / `demote`(idle/below_normal) / `ecoqos` / `affinity`(cores) / `trim` / `power`。
- **until 条件**满足 → **自动还原原值**（Temporary 原则；还原记录的是触发前原始优先级，不是写死 Normal）。
- **前台进程保护**：`GetForegroundWindow` 拿前台 PID，规则永不降级前台进程（Selective 原则双保险：条件层 + 动作层）。
- **热更新**：rules.json 每 60s 重读；`apply_rules` 命令强制重载。
- **心跳**：每 2s 写 rules_state.json（含 foreground_pid），供任何 AI/上层读取规则引擎状态。

### 四、v2 集成（编辑 电脑算力调度中心_v2.ps1）
- 新命令动作：`start_rules` / `stop_rules` / `list_rules` / `apply_rules` / `set_ecoqos` / `set_affinity`（6 个）。
- **引擎在脚本顶层 dot-source**（函数注册进脚本作用域）；评估挂接**命令总线 tick**（单线程 2s，绝无重入）。
- `status.json` 新增 `rules_active` / `foreground_pid` 字段。
- **自保机制**：v2 启动时自身 < Normal 回正 + **每 tick 复查**（防被外部压低；豆包环境子进程常继承 BelowNormal，`Start-Process` 创建的子进程继承父优先级类——实测 v2 重启后全程 BelowNormal，必须自保）。

### 五、验证记录（10:00-10:08 全链路实测）
- 三文件 Parser 全 OK。
- **触发-心跳-还原链路**：selftest 规则（匹配 pwsh 必降级）→ 10:04:10 `demote pwsh(700) level=idle` 触发 → 心跳 `rules_active` 记录 → 10:04:18 stop_rules 还原 `pwsh(700) -> Idle`（原值还原正确）。
- **EcoQoS 官方 API 实测**：ollama(11472) on/off 均 `ok=True`（SetProcessInformation 调用成功）。
- **亲和性实测**：ollama 绑核 0-3 `mask=15 ok=True`；恢复 0-31 `mask=4294967295 ok=True`。
- **生产规则运行**：inference-godmode + restrain-background-cpu 双启用，空闲期不误触发（rules_active=[]，心跳 10:08:57 running=true）。
- **自保生效**：v2 PID 12944 启动回正 Normal，6s 后仍 Normal（tick 维持）。

### 六、踩坑记录（铁律：诚实记录）
1. **`$Pid` 只读自动变量**：`param([int]$Pid)` 赋值即抛"无法覆盖变量 Pid"（变量名不区分大小写，$PID 为只读）。→ 参数统一改 `$ProcId`。
2. **System.Timers.Timer 事件线程并发**：Timer Elapsed 事件线程执行评估时与 PowerShell runspace 主线程冲突，破坏输出管线（现象：子进程/直测输出仅剩最后一行，中间全丢）。→ **废弃独立 Timer，评估挂接命令总线 tick（单线程）**。
3. **函数内 dot-source 作用域陷阱**：命令处理函数内 dot-source 引擎 → 函数注册于函数作用域，函数返回即销毁 → tick（脚本作用域）找不到 `Invoke-RulesEngineOnce`，评估永不执行（心跳停在启动时刻）。→ **引擎必须脚本顶层 dot-source**。
4. **Windows 优先级枚举数值无次序**：`BELOW_NORMAL=16384 > NORMAL=32`（数值上"更低"的优先级值反而更大），`-lt` 直接比较恒 False → 自保静默失效（日志误报"正常"）。→ 新增 `Get-PriorityRank` 语义排序（Idle=0…RealTime=5）。watchdog 用 `-ne`（枚举等价比较）不受影响。
5. **`cpu_gt_pct=0` 在 PowerShell 为 falsy**：`$Cond.cpu_gt_pct -and ...` 中 0 直接跳过检查（语义变成"无条件"）。→ 改用 `$null -ne` 显式判断。
6. **规则状态重复 key**：Invoke-RuleAction 内 key（`"$procId-demote"`）与评估层 key（`"$rname-$id"`）命名不一致 → 心跳出现重复条目。→ Invoke-RuleAction 改为纯动作执行，状态统一由评估层管理。

### 七、当前边界与待办
- **已交付**：规则引擎（条件自动化/心跳/前台保护/热更新）+ EcoQoS + 亲和性 + 自保 + 6 个命令动作，全链路实机验证通过。
- **待办**：① MCP 化命令总线（Tools 原语让任何 AI 客户端直接调调度中心——备料已查 MCP 规范，下阶段做）；② `net_qos` 仍需管理员权限未验证；③ 份额制/动态优先级（论文素材）留作阶段五。


---

## 阶段五：MCP 命令总线 + 算力申请-补给机制（2026-11-03 10:19-10:26）

### 一、目标（用户原话）
「不止任何 AI 客户端可以直接调用，最重要的是让它主动被调用，让应用调用它。比如游戏或者其他应用非常缺算力的话，它就要给它补充，把其他应用的算力先给那个缺算力的。」

### 二、设计
- 入站：Python MCP server（stdio JSON-RPC 2024-11-05 官方规范）做翻译层，AI 客户端直接调调度中心。
- 出站/主动：应用写一行命令总线 JSON 即可申请算力（request_power），无需走 MCP；调度中心清场压低其他进程、把算力补给给申请者，先补最缺的那个；超时/进程退出自动还原。

### 三、开发
- 新文件 `E:\PowerFocus\mcp-server.py`：纯标准库 Python；stdio UTF-8；bus_call 写 `commands\in\mcp-<ts>-<seq>.json` → 轮询 done 同名 .result.txt（15s 超时，v2 未响应给明确提示）；10 工具（power_request / power_release / power_status / power_list_requests / rules_list / rules_start / rules_stop / focus / unfocus / list_apps）；JSON-RPC 分发（initialize 记录 _initialized、未初始化 -32000、未知工具 -32602、异常 isError、notifications 静默）；isError = 文本以 `ERROR:` 或 `命令总线超时` 开头；工具命名全小写下划线（客户端兼容保守）。
- v2 集成（编辑 电脑算力调度中心_v2.ps1）：
  - 全局 `$script:PowerRequest`（pid/name/level/reason/since/expiry/demoted）/ `$script:PowerDemoted`（被压进程 PID→原优先级哈希表）。
  - `Get-DeepSeekTreePids`（`^DeepSeek Harness\.exe$` 正则 + 树遍历收集全部后代，铁律保护）。
  - `Invoke-PowerSupply`（先释放旧申请 → 清场压低其他（跳过自身/申请者/前台/DeepSeek 树/白名单 `$script:Whitelist`/授权清单 `$script:AuthFile`/`$neverPress`('DoubaoWork','msedgewebview2','wetype','ChsIME','ctfmon','SearchHost')/已 Idle/BelowNormal）→ 提升申请者（gentle=AboveNormal+压 Other 为 BelowNormal；aggressive=High+压 Idle；godmode=High+PriorityBoost）→ 30s 下限、默认 300s → 写日志）。
  - `Restore-PowerSupply`（申请者回 Normal、每个被压进程还原其原优先级 `Get-PriorityClassFromString`、置空状态）。
  - 3 个新命令动作：request_power（支持 pid/process_name+level/duration/reason，level 白名单 gentle/aggressive/godmode，走 Resolve-TargetFromCommand）/ release_power / list_requests（显示剩余秒数）。
  - `status.json` 新增 `power_request` 字段（name/pid/level/reason/remaining_sec/demoted_count）。
  - tick 自动释放：每 2s 检查一次，申请超时或申请进程已退出则 Restore-PowerSupply 并写日志。

### 四、实测证据（10:19-10:26 全链路）
- 补给链路（stage5-supply-test2/3.txt）：cmd PID 2460 申请 gentle 40s → 「OK 已压低 75 个其他应用（DeepSeek/系统关键/授权/前台/豆包/调度中心未动）」→ 申请者 AboveNormal → 抽样被压进程确实 BelowNormal → DeepSeek 8 实例 0 被压 → status.power_request 正确（remaining_sec=34/demoted_count=75）→ 测试进程退出 → 下一 tick 日志「算力申请进程已退出，自动释放」→ power_request=null、list_requests=「当前无算力申请」。
- MCP 协议（stage5-mcp-test1/3.txt）：initialize 握手（protocolVersion 2024-11-05 / serverInfo powerfocus-mcp 1.0.0）→ tools/list（10 工具齐全，含 inputSchema）→ tools/call power_status（isError=false 完整状态）→ MCP 端到端申请 power_request(cmd 7332 gentle 30s) →「OK 已压低 72 个其他应用」→ power_release →「OK 已还原 72 个进程（cmd 已回 Normal）」。
- 规则引擎随 v2 自动启动（心跳 running=true 持续更新）。

### 五、踩坑记录（铁律：诚实记录）
1. **启动自保函数定义顺序 bug**：Get-PriorityRank / Get-PriorityClassFromString 定义在启动自保调用（L102 附近）之后 → 脚本按行执行，启动自保 catch 报「术语 Get-PriorityRank 不被识别」（tick 自保仍生效所以最终优先级正常，但启动日志留 WARN）。→ 两个函数连同注释块移到启动自保之前。
2. **DeepSeek PID 16164 被历史清场误压至 Idle**（10:18 诊断实测）——违反「点名保留绝不可动」铁律 → 当场恢复 Normal，后续实测 DeepSeek 8 实例 0 被压。
3. **规则引擎重启假象**：v2 重启后 rules_state.json 遗留 running=true（心跳停更，实际未运行）→ v2 启动时若 rules.json 存在则自动 Start-RulesEngine，心跳随 v2 常驻更新。
4. **notepad 测试目标秒退**（Win11 UWP 存根，Start-Process 返回的存根进程立即退出）→ Resolve-TargetFromCommand 找不到 → 换 cmd 常驻（ping 127.0.0.1 -t）重测。
5. **工具进程 PowerShell 5.1.26100.9711**（无 Test-Json、无三元 `?:`）已规避；工具输出通道偶发吞 stdout → 一律写文件再 Read 回读。

### 六、当前边界与待办
- **已交付**：MCP server（10 工具 stdio 协议实测通过）+ 申请-补给机制（申请/释放/清单/超时与进程退出自动还原，保护集铁律全验证）+ 3 个 bug 修复（优先级函数顺序/DeepSeek 16164/规则引擎自动启动）。
- **待办**：① MCP 客户端接入（豆包桌面/Claude Desktop/自定义宿主配置）需用户拍板连接方式；② 补给机制与规则引擎并行时是否互相牵制（restrain-background-cpu 可能二次压被补进程、inference-godmode 可能拉走申请者）尚未实测；③ net_qos 仍需管理员权限未验证；④ 份额制/动态优先级（论文素材）留作后续。

### 七、阶段五增强：价值分级清场（11:03-11:08 实测闭环）
**需求转折**（用户拍板）：质疑「前台进程一刀切不碰」——「你要先判断哪个是现在有用的、哪个是没用的，然后才把没用的去掉、腾出更多」。动作力度 =「分级：压全部 + 杀明显无用」；有用标准 =「交互中 + 点名保留 + 后台跑任务（下载/训练/渲染/编译/网络活跃）都算有用，只清真正空闲的」。

**实现**（v2，Show-Balloon 与 Invoke-Native 之间区域）：
- 全局 PowerKilled（记录本次清理的无用进程）；status/list_requests 的 power_request 增 killed_count；补给返回文本附「清理 N 个明显无用进程（…）」。
- 新判定函数：Get-LastInputSeconds（GetLastInputInfo 交互检测）、Get-BusyPidSet（PerfProc 两次采样 CPU≥2%）、Get-TCPActivePids（Established + **Listen**——监听端口=在提供服务，ollama 等无 Est 连接的服务进程不算无用）、Test-WindowedAncestor（沿父链找有可见窗口的祖先——浏览器/QQ/夸克渲染子进程无窗但属于在用应用，**绝不杀**）、Get-ProcessValueRank（protect 绝对不动/active 前台不动/task 干活不动/semi 有窗非前台→压/junk 无窗+不忙+无连接+无有窗祖先→启动>120s 杀否则压）、Get-ProcessContext（清场/list_junk 共用的上下文采集，防判定漂移）。
- 清场按 rank 处理：junk 先收集再统一杀前检查（StartTime>120s 才杀，刚启动只压），被杀进程写日志。
- 新只读动作 list_junk：同一套判定列候选，只读不杀，透明审计。
- 系统关键名单扩充：LsaIso/Secure System/WUDFHost/WmiApSrv/wlanext/NgcIso/nvcontainer/NVDisplay.Container/atieclxx/atiesrxx/SearchFilterHost/SearchProtocolHost/WebExperienceHostApp/ShellHost/smartscreen/UserOOBEBroker/AggregatorHost/dllhost/unsecapp/tailscaled/cncmd/OpenConsole/RadeonSoftware；neverPress 增加 wetype_renderer。

**关键失败与修复（诚实记录）**：
1. 首次 list_junk 只读审计 89 个候选是错的——混入 LsaIso（凭据隔离）、Secure System、WUDFHost、ollama（本地模型服务）、19 个 msedge 子进程、11 个夸克、QQ、输入法 wetype_renderer、OpenConsole/cmd/PING/node。根因：① 浏览器/应用子进程无窗口判 junk；② 监听端口服务进程无 Established 连接判 junk；③ 系统安全进程不在名单。→ 修复：TCP 补 Listen、加 Test-WindowedAncestor（有窗口祖先=有用不动）、扩充名单、抽 Get-ProcessContext 共用。收紧后复测 **89 → 11**：只剩测试残留 cmd/PING、douyin_guard 常驻、OpenConsole×5（随后并入保护名单）、RadeonSoftware（并入名单）。
2. **killed_count 显示 bug**：PowerRequest.killed 存的是数字，status 又对它做 @().Count → 实际杀 4 显示 1。→ 修：killed 直接存数字，status 取 [int]。

**实测证据（stage5-junk-test.txt / stage5-killed-fix.txt）**：
- 真实补给（gentle 40s）：申请者 AboveNormal；**清理 4 个明显无用进程**（cmd 残留/douyin_guard 抖音守护/PING×2 测试残留）；DeepSeek 10 实例 0 被压；豆包系 46 进程全存活；释放还原 2 进程、申请者回 Normal；日志逐条记录清理。
- 复测：系统无残留时 killed_count=0 正确；挂窗闲置 3 进程被压；释放还原 3。
- 保护集全验证：DeepSeek/系统关键/授权/前台/豆包/调度中心/输入法/wetype_renderer 全程未动。

**当前边界与待办**：① MCP 客户端接入方式未拍板；② 补给与规则引擎并行互牵制未实测；③ net_qos 管理员权限未验证；④ 份额制/动态优先级留后续；⑤ list_junk 收窄后若用户仍有认为不该杀的类别需确认。
---

## 2026-11-04 07:05 · 主入口升级：v2 覆盖 v1（用户指令“新版明确优于旧版则直接覆盖”）

### 一、决策依据
- 功能对比：v1 托盘 7 项（选择目标/开始聚焦/解除聚焦/强度/日志/自启/退出）v2 全部保留，且为严格超集（另加 GodMode、命令总线、授权清单、规则引擎、算力申请-补给、价值分级清场、MCP 桥接）。
- 自启任务核查：仅存在 `PowerFocusAutoV2`（Ready），无中文旧任务，无双实例冲突。

### 二、执行
- 备份：`E:\PowerFocus\archive\电脑算力调度中心_v1_backup_20261104-070509.ps1`、`电脑算力调度中心_v2_backup_20261104-070509.ps1`。
- 覆盖：v2 内容复制到主入口 `电脑算力调度中心.ps1`；SHA256 一致（289AADF8…0296），Parser 语法 0 错误。
- 自启任务 `PowerFocusAutoV2` 已由 v2 路径改为指向主入口：`D:\PowerShell7\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "E:\PowerFocus\电脑算力调度中心.ps1"`。
- `电脑算力调度中心_v2.ps1` 保留为同内容源副本，不再作为启动入口。

### 三、启动验证（07:05:10 启动，PID 12896）
- 进程存活；日志 07:05:24 自保 Normal、07:05:27 启动成功、07:05:27 命令总线启动。
- 命令总线往返：07:05:18 写入 status → 07:05:30 返回 OK；07:06:35 二次 status → 07:06:36 OK。
- 规则引擎心跳：07:05:24 起 running=true，2s 持续更新。
- 时序说明（非 bug）：首次验证脚本在写入命令后 6 秒即检查，早于 v2 初始化完成（07:05:27），首次读结果为 MISSING；二次检查正常。

### 四、待办
- 托盘图标与右键菜单的真人目视验证（自动化无法确认托盘可见性）。
- 11-04 02:35-02:43 的卸载能力（`lib\app-purger.ps1` / `lib\geek-bridge.ps1` / `list_apps` / `uninstall_app`）仍未记入本日志，且 `app-purger.ps1` 未被接线，待用户拍板后补记/接线。
---

## 2026-11-04 07:20 · 补记：11-04 02:35-02:43 卸载能力（原日志缺失，依据证据重建）

### 一、补记说明
- 本条为事后补记：原日志在 2026-11-03 11:08 后直接空白，缺失 11-04 凌晨开发记录。
- 依据证据：文件 LastWriteTime、v2 运行日志第 310-338 行、`commands\done\wb-listapps-024346.json.result.txt`。
- 未找到任何代码注释、临时脚本或文档记录能证明设计讨论过程，以下只记录可验证事实，不补写动机。

### 二、时间线（证据）
- 02:05:16 / 02:07:19 / 02:12:16 三次 v2 启动（日志 310-327 行），无新功能日志。
- 02:13:29 `wb-verify2-021329` status 命令 → OK（命令总线往返验证）。
- 02:35:19 新建 `E:\PowerFocus\lib\app-purger.ps1`（12,380 字节）。
- 02:42:08 新建 `E:\PowerFocus\lib\geek-bridge.ps1`（4,418 字节）。
- 02:43:05 修改 `电脑算力调度中心_v2.ps1`：顶层 dot-source geek-bridge（1030-1041 行）+ 新增 `list_apps` / `uninstall_app` 动作（1284-1307 行）。
- 02:43:24 启动日志「Geek 桥接模块已加载（彻底卸载能力就绪）」。
- 02:43:47 `list_apps` 实测：列出 43 个已登记应用（全部为 Python 3.10/3.11/3.12/3.13 组件），命令总线往返成功。

### 三、两模块设计（代码阅读结论）
- `geek-bridge.ps1`：`Get-GeekPath`（4 个候选路径 + C:\ 深 3 层搜索）；`Get-GeekAppList`（HKCU/HKLM/WOW6432 三个 Uninstall 根，ID=注册表子键名）；`Invoke-GeekUninstall`（app_id 精确优先、app 名称精确→模糊；拦截 VC++/.NET/Windows Driver Package；调用 `geek.exe --uninstall-app-id`，依赖 Geek 自身确认窗口作为安全闸门）。
- `app-purger.ps1`：`Get-InstalledAppList` / `Test-PurgeGuard`（保护 Windows 路径与运行库/Edge/Update/WDK，安装目录过短拦截）/ `Get-AppResidual`（进程、目录、注册表、服务、计划任务、快捷方式六类残留扫描）/ `Invoke-AppPurge`（默认 `dry_run=true`，显式 false 才执行；MSI 静默、`/S|/silent|/quiet` 才自动，否则转人工；按六类清理）。
- **关键事实：`app-purger.ps1` 当前没有任何文件 dot-source 或引用它，属于未接线模块**；v2 实际生效的是 geek-bridge 通道。

### 四、影响与现状
- `list_apps` / `uninstall_app` 已可用；`list_apps` 有实测证据。
- `uninstall_app` 仅有代码路径，**无实际卸载实测证据**（截至本次补记）。
- MCP 工具清单（10 工具）、`nl-parser.ps1` 句型、`commands\README.md` 均**未同步**这两个新动作。
- 两套卸载实现并行：app-purger（自清理，未接线）vs geek-bridge（借 Geek，已接线）。

### 五、待办
- 用户拍板：app-purger 接线、替代/补充 geek-bridge，或归档。
- 若保留 app-purger，必须补 `dry_run` 预览实测 + 受保护组件拦截实测。
- `uninstall_app` 需要一次非系统组件的真实卸载实测才能算验收。

---

## 2026-11-04 09:25 · v3 实验启动 + E1 模型参数扫描（27B / RTX 5060 8GB / 32GB）

### 一、v3 实验副本（v2 未改动）
- 按用户令「v2 是应用的先前版本，从 v2 上做实验、增强，开发 v3」：
  - 复制主入口 `电脑算力调度中心.ps1` → `电脑算力调度中心_v3.ps1`；
  - SHA256 一致（`289AADF8A684E323BBA846B70246FBB4B09409DCC2930FA59F87E62461980296`），v2 保持不动。
- v3 实验目录 `E:\PowerFocus\v3\e1\`；扫描脚本 `run-e1.ps1`，原始数据 `results.jsonl`，汇总 `summary.txt`，每组 stdout/stderr 在 `logs\`。
- 实验期间停用 `Qwen3.8-LlamaMonitor` 计划任务与 monitor，结束后恢复；v2 在实验期间未运行（见第四节）。

### 二、E1 方法
- 固定 prompt、每组先 warmup 16 token，再跑 2 次 64 token（最终 3 组跑 128 token），取 `/completion` 的 `timings.predicted_per_second`。
- 每组统一：llama-server High 优先级 + 高性能电源；变量只改 `-ngl / -fa / -c / -ctk / -ctv / -t / -tb`。
- 每组重启 llama-server；加载时间 6.5~8.7 秒（页缓存热），首组 17.2 秒（冷）。

### 三、关键结果（128 token 复测）
| 配置 | t/s | 显存余量 | 系统内存余量 |
|---|---|---|---|
| 原配置：`-ngl 20 -fa off -c 8192 -ctk q8_0 -ctv f16` | 2.80~2.98（64 token） | 566~675MB | 1.0~1.54GB |
| **8K 速度档：`-ngl 23 -fa on -c 8192 -ctk q8_0 -ctv f16`** | **3.78** | **383MB** | **3.28GB** |
| 8K 安全档：`-ngl 22 -fa on -c 8192 -ctk q8_0 -ctv f16` | 3.72（64 token） | 770MB | 1.73GB |
| 8K 高密度档：`-ngl 24 -fa on -c 8192 -ctk q8_0 -ctv q8_0` | 3.68 | 238MB | 3.38GB |
| **64K 安全档：`-ngl 19 -fa on -c 65536 -ctk q8_0 -ctv q8_0`** | **3.46（64 token）** | **414MB** | **1.88GB** |
| 64K 最高档：`-ngl 20 -fa on -c 65536 -ctk q8_0 -ctv q8_0` | 3.52 | 210MB | 1.57GB |
| 16K 档：`-ngl 22 -fa off -c 16384 -ctk q8_0 -ctv f16` | 2.92 | 80MB | 1.53GB |

### 四、硬结论（v3 必须知道的规则）
1. **`-fa on` 是本机关键开关**：不仅不掉速，反而释放显存。`-ngl 23` 从 FA off 的 43MB 余量 → FA on 的 656MB（64 token）/383MB（128 token）。
2. **`-ctv q8_0` 必须搭配 `-fa on`**：否则启动直接失败——`quantized V cache requires flash_attn to be enabled`。实测 `-fa off + ctv q8` 两组均 FAIL_HEALTH。
3. **不是 GPU 层数越多越好**：`-ngl 24` 之后性能回落；`-ngl 25/26` 约 3.1 t/s，`-ngl 27` 2.42 t/s。甜点在 23~24。
4. **上下文不是越大越快**：`-c 16384` 在 ngl22/FA off 下只有 2.92 t/s、显存仅余 80MB；64K 要用 `ngl19/20 + FA + ctv q8` 才是可用形态。
5. **线程/批处理**：`-t 14` 3.77 与 `-t 16` 3.72 在噪声内；`-tb 4` 生成 3.66 但 prompt 处理从 15.84 → 9.65 t/s，**默认保留 `-t 16 -tb 8`**。
6. **实测口径**：原配置实际命令行是 `-c 8192`，不是台账写的 64K；64K 是候选档，不是当前运行态。

### 五、当前运行态（E1 结束后已恢复）
- llama-server：PID 21680，High，原始参数 `-ngl 20 -fa off -c 8192 -ctk q8_0 -ctv f16 -t 16 -tb 8`，8080 `/health` 正常。
- v2：实验期间发现原 v2（PID 12896）在 08:12 后已退出，规则心跳停在 08:12:39；09:23:31 通过计划任务 `PowerFocusAutoV2` 重启，PID 48840，启动耗时约 34 秒（启动时 BelowNormal，自保回正 Normal）；09:24 起规则心跳恢复，命令总线 `status` 往返 OK。
- 该现象记为待查：v2 在 08:12 后无声退出，日志无错误条目；不排除外部终止或托盘/WPF 异常，v3 需要补崩溃日志/退出原因记录。

### 六、v3 下一步
- 把本节两套 profile 落成 `v3\model-profiles.json`（8K 速度档、8K 安全档、64K 安全档、64K 最高档），并给 v3 加 `boost_model` 入口：自动发现 8080/模型、按显存余量选档、重启 llama-server、退出还原。
- E2 清场策略对比（降级/暂停/修剪/杀）与 E3 任意应用加速，按原计划继续。

### 七、v3 已落地的第一个只读入口（09:30）
- `v3\model-profiles.json` 已生成：6 个 profile（speed_8k / safe_8k / dense_8k / long_64k_safe / long_64k_max / baseline_original），含实测 t/s、显存余量、内存余量、选择规则与硬约束。
- `电脑算力调度中心_v3.ps1` 新增 `$script:ModelProfileFile` 与命令动作 `list_model_profiles`（只读）；dot-source 实测返回：
  - speed_8k → ngl=23 fa=on ctx=8192 tps=3.78 显存余=383MB
  - long_64k_safe → ngl=19 fa=on ctx=65536 tps=3.46 显存余=414MB
- `boost_model`（自动发现/重启/应用/还原）尚未实现，下一步做。
- 注意：v3 已不再与 v2 哈希一致（新增了 profile 入口），这是预期的 v3 增强。

---

## 2026-11-04 10:30 · v2 无声退出排查结论 + 生命周期日志增强

### 一、排查证据（08:12 前后）
- v2 主日志 `电脑算力调度中心_v2.log` 在 07:06:36 后没有任何 08:xx 记录，无退出/异常/ERROR 条目。
- `rules_state.json` 最后一次心跳 `2026-11-04 08:12:39`（running=true，rules_active=[]），此后停更；说明进程最后存活/最后 tick 约在 08:12:39。
- Windows 事件日志：
  - Application：08:18 的 `AppHangB1`/WER 1001 属于 `DoubaoWork.exe`，08:06 的属于 `biubiu.exe`；**没有 pwsh / PowerShell / 电脑算力调度中心 的 Application Error 或 AppHang 记录**。
  - System：08:00-08:30 仅有 IsolatedUserMode、DCOM 10016、BITS/QuarkUpdater 服务事件；**无资源耗尽、无电源/重启事件**。
  - Security：无 4688/4689（进程创建/终止审核未开启）。
  - TaskScheduler/Operational：日志 `IsEnabled=False`，无任务历史。
  - Kernel-Process/Operational：无事件（未启用）。
  - Resource-Exhaustion-Detector/Resolver：07:00-09:00 无事件。
  - PowerShell/Operational：08:09-08:15 的 4100/4104 警告来自 CodeBuddy 的 safe-delete 包装命令，不是 v2。
- 命令总线目录：07:30-08:40 无新命令、无 done 结果；08:12 前后没有可触发异常的外部命令。
- 结论：**从现有系统日志无法证明 v2 是崩溃、被系统资源耗尽杀死，还是被外部 Stop-Process 终止；历史根因无法确定。最可能是外部终止或 UI 消息循环无日志退出。** 唯一精确证据是 08:12:39 的最后心跳。

### 二、已补的日志能力（v2，不改业务逻辑）
- 新增 `E:\PowerFocus\v2-lifecycle.log`：启动、tray ready、菜单退出、UI 线程异常、进程级未处理异常、PowerShell 退出、Application.Run 返回（含 exitcode）。
- 新增 `E:\PowerFocus\v2_heartbeat.json`：每 5 个命令总线 tick（约 10 秒）写 PID / 启动时间 / uptime / tick / rules_running / cmd_bus / busy；进程消失时可定位最后存活时刻。
- 异常捕获：
  - `[System.Windows.Forms.Application]::add_ThreadException`：捕获 WinForms 定时器/菜单回调的 UI 线程异常。
  - `[AppDomain]::CurrentDomain.add_UnhandledException`：捕获进程级未处理异常。
  - `Register-EngineEvent PowerShell.Exiting`：优雅退出留痕。
  - watchdog tick、命令总线 tick 均加 try/catch，异常写生命周期日志，不再静默。
  - `Application.Run($form)` 加 try/catch/finally；正常/异常返回都会记录 exitcode。
- 备份：`archive\电脑算力调度中心_v2_backup_20261104-102417.ps1`。
- 已重启 v2 验证：新 PID 41688，`v2-lifecycle.log` 记录 `SCRIPT_START` / `SCRIPT_READY`；`v2_heartbeat.json` 正常更新；命令总线 `status` 往返 OK；规则心跳正常。

### 三、遗留与下一步
- 历史根因仍无法确定；若下次是外部强杀，进程内日志仍不会落盘。下一步加 `v2-runner.ps1`（父进程等待子进程退出并记录 exitcode/uptime）或启用 TaskScheduler/Operational 历史，才能区分“正常退出/异常退出/外部终止”。
- v3 尚未同步本次日志增强；下一步把 lifecycle/heartbeat/异常捕获移植到 v3。
- 发现一个 v3 的副作用 bug：09:27 用 dot-source 测试 `list_model_profiles` 时，v3 顶层 `rules-engine`/自保代码在 dot-source guard 之前执行，写入了 v2 日志和规则状态；v3 应把 guard 提前到顶层初始化之前，或加 `-NoInit` 开关。
- `v2_heartbeat.json` 当前在 tick 开始时写入，正常时 `busy=true`；后续把心跳移到 tick 末尾，便于区分“正常忙”与“卡死”。

---

## 2026-11-04 11:09 · v2 独立成目录 + v3 分离 + 根目录清场

### 一、结构变更（已生效）
- **v2 真身迁入独立目录** `E:\PowerFocus\v2\`：`LogDir` 改为 `$PSScriptRoot`，日志 / 心跳 / 规则状态 / 命令总线 / 授权清单 / scenes.json / rules.json / rules-engine.ps1 / lib 全部随之下沉，互不共享。
- **v3 迁入独立目录** `E:\PowerFocus\v3\`：同样改为 `$PSScriptRoot` 寻址；日志改名为 `电脑算力调度中心_v3.log`，`model-profiles.json` 改为同级引用（不再写 `v3\v3\`）。
- **根目录改为单入口**：`电脑算力调度中心.ps1` 变成 20 行转发壳 → `v2\电脑算力调度中心_v2.ps1`；桌面快捷方式与计划任务 `PowerFocusAutoV2` 无需改动。
- `电脑算力调度中心_v2.ps1`（根）改为兼容转发壳，旧快捷方式「算力调度中心.lnk」继续可用；根目录不再保存第二份 v2 源码。
- 根目录 `电脑算力调度中心_v3.ps1` 归档到 `archive\retired-20261104-111102\`，根目录不再出现 v3 文件。
- 根目录旧状态/配置（rules.json、rules_state.json、authorized_apps.json、scenes.json、.auth_token、v2_heartbeat.json、v2-lifecycle.log、旧日志、rules-engine.ps1、rules.json.bak）归档到 `archive\legacy-root-20261104-111251\`，消除“第二真相”。
- 客户端同步：`mcp-server.py` 与 `nl-gateway.ps1` 的命令总线路径改指 `v2\commands\`；`diag-engine.ps1` 改指 `v2\rules-engine.ps1` 与 `v2\rules_state.json`。

### 二、v3 已落地的 Gate 0 能力（真实写入，非计划）
- **单实例锁**：`FileShare.None` 独占句柄锁 `v3\.v3.lock`，进程退出由系统释放；实测第二实例被拒绝、释放后可再次加锁（PASS）。
- **目录隔离**：全部路径基于 `$PSScriptRoot`，`grep` 确认无残留绝对根路径（仅注释与历史实验脚本）。
- 预留 `$env:PF_V3_NO_LOCK=1` 供只读测试绕过锁。

### 三、验收证据
- 计划任务重启后 v2 = PID 18128；`v2\v2_heartbeat.json` 持续更新（uptime 225s / tick 110 / rules_running=true / cmd_bus=true）。
- `v2\电脑算力调度中心_v2.log` 记录：规则引擎已加载并启动（规则来源 `E:\PowerFocus\v2\rules.json`）、命令总线轮询 `E:\PowerFocus\v2\commands\in`。
- 命令总线往返：`status` 命令 → `done\*.result.txt` 生成，`out\status.json` 更新（两次均 PASS）。
- 根目录旧心跳停在 11:08:37，旧命令总线 `out\status.json` 停在 10:26:42，确认无写入。
- `mcp-server.py` initialize 握手返回 `powerfocus-mcp 1.0.0`（PASS）；`nl-gateway.ps1 -Command "状态" -NoModel` 返回状态摘要（PASS）。
- llama-server（PID 21680，High，8080）全程未受影响。
- 顺带修复：`nl-gateway.ps1` 存在重复 `param()` 块，每次运行报非终止错误，已删除重复段。

### 四、遗留
- v2 仍无单实例锁：根入口与兼容壳同时启动会出现两个 v2 实例，建议下一步补锁。
- v3 尚未做运行时联调（dot-source 会自动拉起规则引擎，需在停机窗口做）。
- 根目录旧诊断产物（188 个 .txt、17 个 .log、截图、测试 json/meta）已归档到 `archive\diagnostics-20261104-111733\`（218 个文件，实测 12.4 MB）；保留 `um-prompt.txt`（`run-um-gen.ps1` 的输入）与 `nl-gateway.log`（活跃日志）。

---

## 2026-11-04 11:17 · 根目录诊断产物归档

- 归档位置：`E:\PowerFocus\archive\diagnostics-20261104-111733\`，共 218 个文件。
- 范围：`.txt`（188）、旧 `.log`（16）、截图 `.png`（5）、测试产物 `.json/.jsonl/.meta`（10）。
- 保留：`um-prompt.txt`（唯一被 `run-um-gen.ps1` 读取的输入）、`nl-gateway.log`（11:12 仍在追加）、图标源 `powerfocus-icon-1024.png` / `-src.jpg` / `icon-item*.xml`。
- 根目录文件数由 280+ 降至 63，v2 心跳与命令总线未受影响。
- 剩余待办：47 个 `.ps1` 中有约 30 个是一次性实验脚本（`dev-round*`、`mtp-phase*`、`um-*`、`scope-probe*`、`ai-env-check*`、`gen-test`、`monitor-live-test*`），可另行归档；`start-stress.ps1` / `stop-stress.ps1` / `stress.js` 属压测工具，保留待用。

---

## 2026-11-04 11:19 · 一次性实验脚本归档

- 归档位置：`E:\PowerFocus\archive\oneoff-scripts-20261104-111936\`，共 30 个 `.ps1`。
- 归档清单：`ai-env-check(2)`、`bench-phase`、`cpu-sampler`、`dev-round1-3`、`gen-test`、`gguf-kv-params`、`gpu-type-probe`、`gui-runner`、`monitor-live-test(2)`、`mtp-phase1-2`、`run-um-gen`、`sample-gen`、`scope-probe(2)`、`stream-gen`、`um-calibrate`、`um-debug(-run)`、`um-enhance-regress`、`um-enhance-test1-3`、`um-mtp-test`、`um-restart64k`、`um-validate`。
- 引用检查：保留脚本中仅 `build-ai-center.ps1` 硬编码引用 `um-restart64k.ps1`，已同步删除该索引条目（第 30 行）与 programs 列表项，避免索引死链。
- 根目录 `.ps1` 由 47 个降至 17 个，文件总数由 63 降至 33。
- 保留的 17 个 `.ps1`：两个入口壳、`nl-gateway`/`nl-parser`、`统一内存模式(增强)`、`Test-UnifiedMemoryPerf`、`net-qos`/`net-diag`/`net-anon`、`build-ai-center`、`diag-engine`、`start-stress`/`stop-stress`、`test-autostart`、`test-functional`、`watchdog-test`（另有 `mcp-server.py` 保留）。
- `build-ai-center.ps1` 语法校验通过；v2 心跳正常。

---

## 2026-11-04 11:25 · v2 单实例锁 + v3 生命周期移植 + 回滚框架

### 一、v2 单实例锁（已生效）
- `v2\电脑算力调度中心_v2.ps1` 第 23-37 行新增 `FileShare.None` 独占句柄锁 `v2\.v2.lock`，测试可用 `$env:PF_V2_NO_LOCK=1` 绕过。
- 两个根目录转发壳补 `exit $LASTEXITCODE` 透传，锁拒绝时退出码从 0 修正为 1。
- 实测：旧实例 18128 于 11:22:17 记录 `APPLICATION_RUN_RETURNED exitcode=0` 后退出；新实例 15192 于 11:22:33 启动并接管；第二次启动被拒，`exitcode=1`。

### 二、v3 补齐生命周期与心跳（移植自 v2）
- 新增 `$script:LifecycleLog`（`v3-lifecycle.log`）、`$script:HeartbeatFile`（`v3_heartbeat.json`）、`$script:ScriptStartTime`、`$script:TickCount`。
- 新增 `Write-Lifecycle` / `Write-Heartbeat` 两个函数（原 v3 缺失，属对 v2 的功能倒退）。
- 接入点：`SCRIPT_START`、`SCRIPT_READY`、`MENU_EXIT`、`UI_THREAD_EXCEPTION`、`UNHANDLED_EXCEPTION`、`POWERSHELL_EXITING`、`FATAL_APPLICATION_RUN`、`APPLICATION_RUN_RETURNED`；心跳每 5 tick 写入。
- 托盘标题与启动/退出日志文本由 “v2” 修正为 “v3”。

### 三、v3 回滚框架（Gate 0 螺丝三落地）
- 新增 `v3\lib\rollback.ps1`：`Save-ModelRollback`（只读记录 PID/命令行/优先级/CPU 亲和性/工作集/电源计划到 `v3\rollback\rollback.json`）、`Get-ModelRollback`、`Restore-ModelRollback`（默认 dry-run，`-Apply` 才还原优先级；永不重启进程）。
- 日志独立写 `v3\rollback\rollback.log`，进程内同时写生命周期 `ROLLBACK_*` 条目。
- 实测：备份 llama-server PID 21680（High / 79.3MB）成功；dry-run 判定 `RESTORE_NOOP`（状态与备份一致）。

### 四、验收
- 五个脚本语法全部通过。
- dot-source v3（`PF_V3_NO_LOCK=1`）后 `Write-Lifecycle` / `Write-Heartbeat` / `Save-ModelRollback` 均可用。
- 隔离验证：v3 dot-source 后 v2 日志最后写入仍为 11:22:37，未被污染；v2 心跳 11:25:57 / pid 15192 / tick 100 正常。

### 五、遗留
- `boost_model` 仍未实现：需先定“发现实例 → 按显存选档 → 重启 llama-server → 失败自动还原”的接口与停机策略，再动代码。

---

## 2026-11-04 11:36 · v3 多模型注册表（model-profiles v2）

### 一、档案结构升级
- `v3\model-profiles.json` 升级为 `powerfocus/model-profiles/v2`：`hardware`（含 fingerprint）+ `global_rules` + `models` 分桶；现有 Qwen3.8-27B 全量迁入 `models["qwen3.8-27b-q4km"]`，6 个档位实测数据无损保留（tps/显存余/加载耗时）。
- 通用规则与模型专属规则分离：`global_rules` 5 条（量化缓存必须配 FA、-tb 4 拖慢、改 ngl/fa 必须重启、加速前必须备份、未命中身份禁止套档），模型内 `rules` 2 条（8K 甜点 23~24、64K 档 19~20）。

### 二、新增 `v3\lib\model-registry.ps1`
- `Read-GGUFMetadata`：直接解析 GGUF v3 头部二进制（magic/version/kv 对），读 `general.architecture`、`*.block_count`；不加载模型。
- `Get-ModelIdentity`：返回 arch / layers / file_type / size_gb。
- `Resolve-ModelProfile`：按 arch + layers + size（±1%）匹配档案条目，返回该模型的 profile 集与硬件信息。
- `Select-ModelProfile`：解析 selection 规则（仅支持 `ctx`/`gpu_free_mb` 的比较与 `and`），不使用 Invoke-Expression。
- 进程内缓存（路径+大小+mtime）。

### 三、实测发现与修正
- **`general.file_type` 不可信**：Qwen3.8-27B-UD-Q4_K_M 实际报 `15`（MOSTLY_Q6_K），与文件名标签 Q4_K_M（枚举 12）不一致（UD 混合量化）。若拿它做身份硬匹配会永远命中不了，已改为仅供参考、不参与匹配。
- **解析性能**：初版顺序读完 metadata（含 15 万条 tokenizer 词表）耗时 7018ms；改为 arch+layers 齐即提前退出后降至 **37ms**，缓存命中 1ms。
- `model_identity` 原先只识别 `--model`，而实际进程用 `-m`；已同时支持 `--model` / `-m` / `=` 三种写法。

### 四、验收
- `list_model_profiles`：正确输出 v2 注册表（1 模型 / 6 档，含实测 tps）。
- `model_identity`：识别 PID 21680 的模型路径 → arch=qwen35 layers=65 size=15.33GB → 命中 `qwen3.8-27b-q4km`（6 档可选）。
- 选档实测：显存 800/8K→`safe_8k`；显存 400/64K→`long_64k_max`；显存 200/8K→`safe_8k`（default 兜底）。
- 未识别模型（非 GGUF 文件）→ `Resolve-ModelProfile` 返回 null，按规则拒绝套档。
- v2 心跳正常（pid 15192 / tick 350），未受影响。

### 五、遗留
- `boost_model` 仍缺：多模型识别与选档链路已就绪，但“重启 llama-server + 失败回滚”仍需确定自动重启权限与停机窗口。

---

## 2026-11-04 12:39 · 内置 REA 逆向引擎（任何 AI 连调度中心即可调用）

### 一、来源核实（先查后装）
- 用户所指“Rea 技术”= **REA（Reverse Engineer Anything）**：MIT 协议的 MCP 服务器，把 Ghidra / Hopper / IDA / Apktool / JADX 等逆向工具封装成标准 MCP 工具。
- 官方来源三处一致：GitHub `morluto/rea`、官网 rea.tools、npm 包 `rea-agents`。
- 实测核实：`git ls-remote` 仓库真实存在且分支活跃；`npm view rea-agents` 返回 v6.8.0、MIT、bin=`rea`/`rea-agents`，无仿冒迹象。

### 二、安装与环境体检
- `npm install --global rea-agents` → `rea 6.8.0`，bin 落 `%APPDATA%\npm\{rea,rea-agents}.{cmd,ps1}`。
- Node v26.13.0 满足官方要求（22.23.4+/24.22.1+/26.12.1+）。
- `rea doctor` 关键结论：
  - **Ghidra 12.1.4（D:\ghidra_12.1.4_PUBLIC）+ JDK 25 全部 healthy**，原生反编译可用；
  - Hopper（macOS 专属）、IDA、JADX、Kuna 未配置 —— 平台限制或需用户自备，不影响内置静态分析能力。
  - 10 个 AI 客户端（Claude Code / Codex / Cursor / Gemini CLI / VS Code / Copilot / WorkBuddy 等）均未注册 REA。

### 三、集成方式（改 `mcp-server.py`，309 → 540 行）
- 新增 `ReaProxy` 类：以 `rea --mcp` 子进程为后端，实现 stdio JSON-RPC 客户端（initialize / tools/list / tools/call），读线程与写锁分离，请求-响应用 id+Event 配对。
- 惰性启动：首次 `tools/list` 或 REA 工具调用才拉起子进程；启动失败进入 60 秒冷却，不拖垮主服务。
- 工具命名：REA 的 229 个工具统一加前缀 `rea__`，与原生 10 个工具零冲突；描述统一加 `[REA 逆向]` 标记。
- 新增 `rea_status` 探针：返回就绪状态、版本、工具数、可执行路径、错误与 stderr 尾部。
- `initialize` 改为回显客户端协议版本（支持 2024-11-05 / 2025-03-26 / 2025-06-18），并在 `instructions` 里声明 REA 可用。
- 退出：`atexit` 终止 REA 子进程。

### 四、实测（端到端）
- `tools/list`：总 240 = 原生 11（含 rea_status）+ REA 229，耗时 **0.39s**。
- `rea_status`：就绪 / rea 6.8.0 / 229 工具。
- 真实调用 `rea__inspect_model_artifact` 解析 `Qwen3.8-27B-UD-Q4_K_M.gguf`（15GB）头部 → 返回 7950 字符 Evidence JSON，成功。
- 服务正常退出 rc=0，REA 子进程无残留。

### 五、使用
- 任何 AI 只要把 MCP 指向 `E:\PowerFocus\mcp-server.py`，`tools/list` 即自动获得 229 项逆向能力；无需另行安装或配置 REA。
- 典型入口：`rea__inspect_model_artifact`（GGUF/safetensors 元数据，与多模型注册表互补）、`rea__inspect_gpu_code_objects`（CUDA CUBIN/PTX）、`rea__inspect_desktop_application`、`rea__analyze_javascript_application`。
- 也可直接给各 AI 客户端单独注册 REA：`rea setup`（交互式，会改各客户端配置并备份）。

### 六、遗留
- npm 安装已正常结束（added 150 packages in 9m，无残留进程）——上条“等待 registry 收尾”已排除。
- 未给本机 10 个 AI 客户端注册 REA —— 当前采用“统一走调度中心 MCP 转发”的方案，避免散改多份配置；如需要客户端直连可执行 `rea setup`（会备份原配置）。

---

## 2026-11-04 12:42 · REA 直连注册到全部本机 AI 客户端

### 一、执行
- `rea setup --all-detected --yes`（先跑 `--dry-run` 核对 15 项动作；未加 `--install-hopper`，Windows 上 Hopper 不可用）。
- 首次命令退出码 1，原因是 Grok Bot 属托管账户客户端，官方明确不支持写入账户存储；其余动作全部生效，复跑 dry-run 得到 `plannedActions: []`。

### 二、落地核对（11 个客户端）
| 客户端 | 配置文件 | REA 命中 | 备份 |
|---|---|---|---|
| Claude Code | `.claude.json` | 是 | 有 |
| Codex | `.codex\config.toml` | 是 | 有 |
| Cursor | `.cursor\mcp.json` | 是 | 新建 |
| Gemini CLI | `.gemini\settings.json` | 是 | 有 |
| OpenCode | `.config\opencode\opencode.json` | 是 | 有 |
| GitHub Copilot CLI | `.copilot\mcp-config.json` | 是 | 新建 |
| VS Code | `AppData\Roaming\Code\User\mcp.json` | 是 | 新建 |
| WorkBuddy | `.workbuddy\mcp.json` | 是 | 有 |
| Pi | `.pi\agent\mcp.json` | 是 | 新建 |
| Hermes | `AppData\Local\hermes\config.yaml` | 是 | 有 |
| DeepSeek Harness | `.dsh\cordis.patch.yml` | 是 | 新建 |

- 注册命令：`node <npm-global>\node_modules\rea-agents\scripts\rea.mjs mcp`，并注入 `GHIDRA_INSTALL_DIR=D:\ghidra_12.1.4_PUBLIC`、`JAVA_HOME=E:\Java\jdk-25`。
- Skill 安装 4 处均存在：`.agents\skills\`、`.claude\skills\`、`.workbuddy\skills\`、`hermes\skills\` 下的 `reverse-engineer-anything`（版本 49 / 229 工具 / aligned）。

### 三、体检
- `rea doctor`：`healthy: true`、`environment_healthy: true`，可用提供者 `ghidra`（12.1.4，configured）。
- 仍未可用：Hopper（macOS 专属）、IDA（需 `REA_IDA_MCP_CONFIG`）、JADX（需自备 jar）、Kuna（需自备可执行）；不影响内置静态分析。

### 四、生效条件与遗留
- 各客户端需**重启**后才会加载新 MCP 注册。
- Grok Bot 需在聊天内手动添加自定义 MCP：名称 `rea`，命令 `npx -y rea-agents@6.8.0 mcp`，且必须运行在该 Bot 的计算机上（本地 stdio 不会被挂载）。
---

## 2026-11-04 13:59 · 开发环境基线（git + 自检 + 测试 + 规范）

### 一、版本控制
- `E:\PowerFocus` 执行 `git init -b main`，首次提交 `63b93f6`，跟踪 **387 个文件**，工作区 0 改动。
- 全局 git 身份未配置，按安全规矩不改全局 config，改用行内 `git -c user.name=... -c user.email=... commit`。
- 新增 `.gitignore`：忽略 `logs\`、`out\`、`*.log`、`*.lock`、心跳、`rules_state.json`、三个命令总线、`v3\rollback\*.{json,log}`、`archive\**\*.{png,log}`、`__pycache__`，以及 `.auth_token`/`*.token`/`*.secret`/`*.key`。
- 新增 `.gitattributes`（`.ps1` CRLF、`.py/.json/.md` LF、图片二进制）与 `.editorconfig`（UTF-8 锁定）。
- 实测：`v3\.auth_token`、`v3\v3-lifecycle.log`、`v2\rules_state.json`、`v3\commands\done\` 均被正确忽略。

### 二、目录补齐（不搬家）
- 用户明确选择「原地补齐」：现有脚本全是 `E:\PowerFocus\` 绝对路径，桌面快捷方式与计划任务 `PowerFocusAutoV2` 指向根转发壳，硬搬会打断正在运行的 v2。
- 仅新增三个目录：`tools\`（开发者工具）、`tests\`（测试入口）、`docs\`（规范文档）。根目录 33 个文件未动。

### 三、`tools\dev-check.ps1`（环境自检）
四组检查：工具链 / 关键文件 / 运行态 / 版本控制。实测 `PASS 23 / WARN 5 / FAIL 0`：
- 端口 8080 监听中（llama-server PID 6024）；8686 未监听（轻量实例未启）。
- v2 心跳存活：pid=24992、tick=810、距今 2s（v2 正在运行）。
- `v3\.v3.lock` 为空文件：改用 `FileShare.None` 探测，判定「无进程持有 → 陈旧锁」，不再误报 v3 在跑。
- GPU：RTX 5060 Laptop 8151MiB / 已用 5692 / 空闲 2208。
- 5 个 WARN 全部是执行器沙箱造成的别名差异，见第五节。

### 四、`tests\run-tests.ps1`（唯一测试入口）
五类检查，实测 **5/5 PASS，耗时 2.7s**：
1. PS 语法：35 个 `.ps1` 走 `Parser::ParseFile` 全通过。
2. JSON 契约：`model-profiles.json` schema=`powerfocus/model-profiles/v2`，rules/scenes/authorized_apps 合法。
3. Python 编译：`py_compile mcp-server.py` 通过（`D:\Python313\python.exe`）。
4. MCP stdio 冒烟：`initialize` + `tools/list`，协议版本回显正确，原生 5 个必需工具齐全。
5. 仓库卫生：387 个跟踪文件中无 `auth_token`/`*.log`/心跳/锁泄漏。

### 五、实测发现：沙箱 PATH 污染（重要）
- 本机真实版本：Node **v26.13.0**（`C:\Program Files\nodejs`）、rea-agents **6.8.0**（`%APPDATA%\npm`）、Python **3.13.0**（`D:\Python313`）。
- agent 沙箱内 PATH 上的版本：Node **v22.23.2**、rea **6.7.0**、Python **3.13.16**（`...\sandbox_runtime\...`），且 bypass 沙箱开关也无效——变量来自执行器自身运行时。
- 由此解释了一个此前记录不了的差异：`tools/list` 本次报 **218** 个工具（11 原生 + 207），而 12:39 的日志记录是 **240**（11 + 229）。原因是 `mcp-server.py` 的 `_find_rea()` 优先取 PATH，命中了沙箱版 6.7.0（207 工具），而非全局 6.8.0（229 工具）。**不是 REA 坏了，是解释器/静态资源被替换。**
- 处理：`dev-check` 现在把这类差异报成 `WARN node 别名` / `WARN rea 别名`；规范文档要求脚本内一律写绝对路径。

### 六、`docs\DEVELOPING.md`（开发规范）
十节：定位与三条硬约束 / 目录规范表 / 工具链与固定解释器（含沙箱污染说明）/ 运行与调试入口 / 测试规范 / 日志与产物分离 / 配置与密钥 / 版本与归档 / 提交规范 / 排障顺序。

### 七、遗留
- `_find_rea()` 的优先级要不要改成「先 `%APPDATA%\npm\rea.cmd`，后 PATH」——本轮按用户「只做环境、暂不开发功能」的口径未改代码，待定。
- `boost_model` 仍缺三项决策：能否自动重启 llama-server、允许多长停机窗口、tps 掉多少算失败回滚。
- `model-assets.json`（29 个模型 / 159.12GB）仍未接线（上次挂起项）。
- 无 pytest / 无 CI；当前是「脚本级自检 + 冒烟」，够用但未形成回归用例库。

---

## 2026-11-04 14:03 · 修复 `_find_rea()` 优先级（沙箱版 REA 静默缩水）

### 一、问题
- `mcp-server.py` 的 `_find_rea()` 先取 `shutil.which("rea")`，再退回 `%APPDATA%\npm\rea.cmd`。
- 在豆包/WorkBuddy 等 agent 沙箱托管的环境里，PATH 上的 `rea` 指向 `...\sandbox_runtime\...\node\rea.ps1`（**6.7.0 / 207 工具**），全局安装的 6.8.0（**229 工具**）因为排在后面永远命中不了。
- 后果：`tools/list` 从 240 静默掉到 218，且不报错——客户端只看到工具少了 22 个，没有任何提示。

### 二、修复
- 优先级改为：`POWERFOCUS_REA` 环境变量 → `%APPDATA%\npm` 下的 `rea.cmd` / `rea-agents.cmd` / `rea.ps1` / `rea-agents.ps1` → 固定兜底路径 → 最后才回退 PATH。
- 只改定位顺序，不改代理逻辑、超时、冷却策略；原生工具与 REA 工具命名不变。

### 三、验收（本机实跑）
- `tests\run-tests.ps1`：**5/5 PASS，1.4s**，MCP 冒烟工具数 **240**（11 原生 + 229 REA），与 12:39 基线一致（此前为 218）。
- `rea_status`：服务 **6.8.0**，可执行文件 `C:\Users\Administrator.医院\AppData\Roaming\npm\rea.cmd`，状态就绪。
- PS 语法 35 个文件全通过；JSON 契约 5 个配置合法（含另一会话新增 4 个 `identity_only` 档案后的 `model-profiles.json`）。

### 四、观察（未修，留待定）
- `rea_status` 在「先调它、后调 tools/list」的顺序下报 `工具数: 0`——代理此时还没缓存工具清单，数字是滞后值。计数本身不影响功能，但会误导排查；如需要可让 `rea_status` 实时向 REA 拉一次 `tools/list` 再报数。

### 五、提交
- `fix: _find_rea 优先全局 npm 安装，避免沙箱版 REA 静默缩水`

---

## 2026-11-04 14:10 · 工具全面对齐（系统新版压过盒子自带旧版）

### 一、目标
把执行时用到的旧版工具全部换成系统里的真实新版，且不依赖调用方（人和 AI）记得写绝对路径。

### 二、新增 `tools\env.ps1`（统一工具定位）
- 解析顺序：Python `D:\Python313` → 3.12 → 3.11 → 3.10；Node `C:\Program Files\nodejs`；逆向引擎 `%APPDATA%\npm\rea.cmd`。
- `Add-PathFront`：**先摘掉旧位置，再插到 PATH 队首**。裸敲 `python` / `node` / `rea` 便命中新版，无需改调用习惯。
- 顺带设置 `POWERFOCUS_REA`、`JAVA_HOME`（`E:\Java\jdk-25`）、`GHIDRA_INSTALL_DIR`（`D:\ghidra_12.1.4_PUBLIC`），逆向引擎开箱可用。
- dot-source 即生效：`. E:\PowerFocus\tools\env.ps1`。

### 三、接线
- `tools\dev-check.ps1`、`tests\run-tests.ps1` 开头 dot-source `env.ps1`，删掉各自重复的查找函数（原来两处副本，现统一一处）。
- `tests\run-tests.ps1` 新增第 6 项「工具对齐」：实测裸命令 `python` / `node` / `rea` 是否真的命中系统新版，命中盒子自带版本直接 FAIL。

### 四、踩到的坑（第一版判断写错，当场修）
- 初版用 `if (PATH 中不含该目录) 才前插`。实测 FAIL：这些目录本来就散落在 PATH 里（只是排在盒子条目之后），`-notcontains` 判定为「已存在」→ 不前移 → 裸命令仍命中沙箱版。
- 改为「先移除同名目录，再插队首」后一次通过。教训：**顺序问题不能只判断存在性**。

### 五、验收（实跑）
- `run-tests.ps1`：**6/6 PASS，1.2s**。
  - 工具对齐：`python=D:\Python313\python.exe`；`node=C:\Program Files\nodejs\node.exe`；`rea=%APPDATA%\npm\rea.cmd`。
  - MCP 冒烟：240 个工具（11 原生 + 229 逆向），协议回显正确。
- `dev-check.ps1`：**PASS 24 / WARN 2 / FAIL 0**。原先三条沙箱别名 WARN 全部消失，只剩「8686 未监听」「工作区有未提交改动」两条正常提示。

### 六、能力边界（诚实说明）
- 能改：本进程与子进程的 PATH 顺序、脚本里用哪个解释器、调度中心拉起哪份逆向引擎。
- 不能改：执行器（豆包/WorkBuddy 盒子）启动时注入的初始 PATH。因此裸命令只在 dot-source 之后才对齐；未加载 `env.ps1` 的会话仍会看到旧版。

### 七、遗留
- `model-profiles.json` 仍由并行会话改动（4 个 `identity_only` 档案），本提交未包含。
- `rea_status` 在 `tools/list` 之前调用会报「工具数 0」（缓存未填充），功能无碍，是否实时拉取待定。

---

## 2026-11-04 14:21 · 运行时体检 + 去绝对路径改造

### 一、体检结论（只读实测，未改任何软件文件）
1. 运行时真身：`…\DoubaoWork\User Data\sandbox_runtime\bases\` 下两个版本目录（2026-10-16、2026-10-21 各建一次）。**不是每次启动重建**，只有运行时版本变化才新建。
2. 内装版本：Node 22.23.2、Python 3.13.16、一份 pwsh；目录里自带的 `rea.cmd` 把 `_prog` 绑到 `%dp0%\node.exe`，即**逆向引擎被焊死在旧 Node 上**，这是工具数缩水的物理原因。
3. 进程链：助手终端 pwsh ← Trae CN.exe ← Trae CN.exe。启动参数为 `-NoLogo -NoProfile -NonInteractive`，**不加载 PowerShell 配置文件**。
4. 注入方式：用进程级环境变量 `__TRAE_PATH_<哈希>` 备份并还原 PATH；当前会话实测裸命令已命中系统新版，说明**接管是条件性的，不是常态**。

### 二、官方文档查证（非臆测）
- Trae 官方《常见问题》：外部环境变量需写进 shell 配置文件，Windows 用 `$PROFILE`；给出的写法是 `$env:MY_ENV="1234"`。→ 结论：该渠道对用户自己的终端有效，**对 `-NoProfile` 启动的助手进程无效**。
- Node 官方下载页：推荐 `winget install Schniz.fnm` + `fnm install 26`（版本管理器方案）。本机未装。
- 逆向引擎官方安装页：`npx rea-agents@latest setup` / `npx -y … mcp`，即“不写路径、按需拉最新”。
- Python 官方：Windows 启动器 `py`，`py -3.13` 指定版本。

### 三、按“不要绝对路径”重写 `tools\env.ps1`
- 删除全部写死盘符的候选清单（原版含 `D:\Python313\python.exe` 等硬编码）。
- 改为：Python 走官方 `py` 启动器报告的真实解释器；Node 读注册表 `HKLM\SOFTWARE\Node.js\InstallPath`；逆向引擎读 `%APPDATA%\npm`。
- 行为改为**按需纠正**：先测裸命令命中谁，未命中 `sandbox_runtime` 就一动不动；命中才前移目录。
- `JAVA_HOME` / `GHIDRA_INSTALL_DIR` 改为目录探测 + 只填空值。
- 顺带修正一处认知偏差：运行时不叫“豆包盒子”，进程链实测归属 Trae CN。

### 四、验收
- `run-tests.ps1`：**6/6 PASS，3.1s**；工具对齐项显示 `python=D:\Python313\python.exe`、`node=C:\Program Files\nodejs\node.exe`、`rea=%APPDATA%\npm\rea.ps1`。
- 全脚本已无写死盘符（除项目自身数据目录外）。

### 五、遗留
- 若日后确实需要“换 Node 版本”，官方路径是 `winget install Schniz.fnm`，不是改 PATH 拼字符串；本次不动。
- `model-profiles.json` 仍属并行会话改动，未纳入本提交。
