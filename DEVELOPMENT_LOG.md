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

---

## 2026-11-04 14:35 · 停用旧工具：可行性核查（未执行删除）

### 一、为什么没有当场删除
- 实测：`bases\7729…` 下有 **3 个 node 进程 + 2 个 python 进程正在运行**（PID 25312/46944/49184/42832/66516）。此刻改名或删除，等于拔掉通电中的零件，当前会话会立即失能。
- 进一步发现：`sandbox_runtime\downloads\` 里仍存着 `7729…`（131.9MB）与 `c98c…`（65.1MB）的原始压缩包，`.cache` 下还有 node/python 缓存。**运行时的本质是“从压缩包解压出来的缓存”，不是“安装的程序”**——删掉解压目录，下次启动大概率自动解压复原。因此“卸载旧工具”这条路在物理上不成立（删了会自己长回来）。

### 二、按约定准备的工具（均已落盘，未生效）
- `tools\disable-runtime-tools.ps1`：带安全闸——检测到运行中的运行时进程就拒绝执行；只处理最新那份（按创建时间），旧的那份留作兜底；把 node/python 改名为 `*.disabled-20261104`（等于删除但可秒还原）。
- `tools\restore-runtime.ps1`：一键把 `*.disabled-20261104` 改回原名。
- 安全闸已实测：当前运行被拒绝（退出码 1），未改动任何文件。

### 三、执行步骤（需人工，因为要关编辑器）
1. 完全退出编辑器（含托盘）。
2. 运行 `disable-runtime-tools.ps1`（右键用 PowerShell 运行即可）。
3. 重新打开编辑器，观察：是否报错、是否自行恢复旧工具。
4. 若起不来，运行 `restore-runtime.ps1` 原样还原。

### 四、判断（供决策）
收益：省掉“加载一次工具开关”。风险：编辑器起不来，且极可能被压缩包自动复原而白做。建议不执行；工具已备好，由用户当场决定。

---

## 2026-11-05 02:20 · A+B 落地：模型路由 + v3 动作 + 控制台（含实测）

### 一、开发环境（可复现）
- 新建 `E:\PowerFocus\.venv`（Python 3.13.0，`.gitignore` 已忽略）；装 fastapi 0.162.0 / uvicorn 0.54.0 / pytest 9.2.0 / httpx / ruff。
- 新增 `pyproject.toml`：pytest 指向 `tests/py`；ruff 只查 `F`+`E9`（未定义名、未使用导入、语法），不强制重排既有风格。
- 清理既有 `mcp-server.py` 中未使用的 `re` / `uuid` 导入（ruff 首次检查即发现）。

### 二、A1 模型路由 `tools\model-router.ps1`
- 动作：`start / stop / status / logs / boost / restore`；参数源唯一：`v3\models-preset.ini`。
- **关键实测结论**：agent 终端用 `Start-Process` 拉起的 llama-server 会随命令结束被 job 清理（连无重定向也一样）。改为 `Invoke-CimMethod Win32_Process Create` 启动，进程归属 WMI 提供者，可长期驻留；日志改由 llama-server 自带 `--log-file` 落盘。
- 单实例与安全闸：PID 文件 + 命令行指纹双校验；**判定指纹 = 命令行里的 `--log-file` 指向本脚本的 `logs\router.log`**（主 preset 与 boost 单模型两种启动方式都带，全机唯一），绝不会误杀用户自己的 llama-server。
- 端口被他人占用直接报错退出，不抢占；健康检查失败会杀掉刚拉起的 PID 并清理 PID 文件，不留脏进程。
- `start -Model <name>` 会从完整 preset 派生 `out\router-preset-<name>.ini`，只加载该模型（低显存验证用，不动主配置）。

### 三、A2 v3 命令总线新动作
- `start_router` / `stop_router` / `router_status`：薄封装 `model-router.ps1`，不复制启动逻辑。
- `boost_model`：`model` 支持 gguf 路径或 preset 模型名 → `Resolve-ModelProfile` 命中档案 → 指定 `profile` 或按显存/ctx 自动选档。
  - **默认 dry-run**（`apply` 缺省即不执行），只输出模型/档案/档位/参数/实测 tps。
  - `apply=true` 才走 `Save-ModelRollback` → 停旧服务 → 按档位启动 → 健康检查；失败自动用 rollback 记录的原始命令行 `restore` 重启。
  - 未命中档案直接拒绝，不套用任何参数（沿用 `DEVELOPING.md` 硬约束）。

### 四、A3 MCP
- `POWERFOCUS_BUS=v3` 时总线目标切到 `v3\commands`（默认仍是 v2，保持兼容）。
- 新增原生工具 5 个：`router_start` / `router_stop` / `router_status` / `list_model_profiles` / `boost_model`；总线超时文案按目标 v2/v3 区分，超时会清理 in 文件。

### 五、B 本地控制台
- `app\server.py`（FastAPI，`127.0.0.1:18080`，避开 8080 的推理端口）：
  - `/api/chat` 流式代理到 llama-server `/v1/chat/completions`；
  - `/api/command` 只放行白名单 action（与 v3 switch 真实动作名对齐，含 `request_power`/`release_power`）；
  - `/api/router` 只读调 `model-router.ps1 -Action status -Json`；`/api/models` 汇总注册表 + preset + 已加载；`/api/boost` 走 `boost_model`。
- `app\web\index.html`：左对话右调试，原生 JS 无构建；流式渲染 `data:` 增量。

### 六、测试与自检扩展
- `tests\py\test_console.py`：白名单必须与 v3 switch 动作一一对应（本次就抓出 `power_request` → 实际是 `request_power`）；总线超时必须清理 in 文件；未知 action 返回 400。
- `tests\run-tests.ps1`：Python 编译改为 `mcp-server.py` + `app\server.py`；新增 pytest 段与「路由契约」段（preset 每节必须有 model + n-gpu-layers、`[*]` 必须有 threads/c/parallel、模型文件必须存在、前端必须引用 4 个接口）。
- `tools\dev-check.ps1`：关键文件 +4（路由器/控制台服务/页面/pyproject），端口 +18080，新增 v3 心跳与 `.venv`/ruff 检查。

### 七、实测记录（2026-11-05 02:05–02:20）
- `router start -Model Qwen2.5-0.5B`：health ok，`/v1/models` 回 `Qwen2.5-0.5B`；非流式与流式对话均正常。
- 重复 start：返回「已在运行（PID …）」，不重复拉起；`stop` 后无 llama-server 残留。
- v3 总线：`start_router` / `router_status` / `boost_model`(dry-run) / `boost_model`(apply) / `stop_router` 全部通过；apply 成功重启单模型服务。
- 控制台：`/api/health`、`/api/router`、`/api/models`、`/api/status`、`/api/command`、`/api/boost`、`/api/chat`(SSE) 全部 200；v3 未运行时 `/api/status` 12s 返回离线提示且不残留 in 文件。
- 显存：0.5B 路由实例加载后 ~560MB；停止后立刻释放。
- `run-tests`：**8 PASS / 0 FAIL**；`dev-check`：**30 PASS / 4 WARN / 0 FAIL**（WARN 为 8686 未监听、v2 心跳停在 11-04、v3 锁正在运行、工作区 42 个未提交）。

### 八、遗留与风险
- **27B 档位未实测**：验证时段 GPU 已被其他应用占用（约 7.1GB，空闲仅 753MB），8GB 卡上无法安全加载 27B；`boost_model apply` 前应先看 `router_status.gpu_free_mb`，`models-preset.ini` 里 27B 的 `load-on-startup = true` 在低余量时应去掉。
- `router_status` 的 `models` 在 JSON 里单元素时是字符串而非数组（PowerShell 序列化行为），前端按数组处理已兼容，但外部消费者需注意。
- 本次未提交 git；变更清单见 `git status`。

---

## 九、V3 接管入口 + 常驻方式修正（2026-11-05 02:27）

### 做了什么

1. **入口切到 v3**：`E:\PowerFocus\电脑算力调度中心.ps1` 原先把 `v2\电脑算力调度中心_v2.ps1` 写死，现在转发 `v3\电脑算力调度中心_v3.ps1`。桌面快捷方式与计划任务 `PowerFocusAutoV2` 都指向入口，因此整条启动链自动跟随，不需要改任务。
   - 备份：`archive\电脑算力调度中心.ps1.bak-before-v3-cutover-20261105-022702`
2. **v2 归档保留**，不再由入口启动。计划任务名保持 `PowerFocusAutoV2`（改名会丢掉已有触发器和登录自启注册）。

### 为什么

- v3 = v2 全部能力 + `lib\model-registry.ps1`（8 个模型的档位档案、实测 tps/显存余量）+ `lib\rollback.ps1`（改优先级前存档、可还原）。v2 是 1684 行，v3 是 1862 行，差异 256 处，v3 是超集。
- **v2 和 v3 的实例锁是各自独立的**（`.v2.lock` / `.v3.lock`），两个可以同时运行，同时改进程优先级、同时轮询各自命令总线 → 必打架。所以只能有一个入口活着，入口只拉 v3。

### 顺手查清的一个「v3 自己会死」误报

现象：02:06:59 启动的 v3（PID 56896）在 02:10:50 心跳断掉，日志无异常、无 `APPLICATION_RUN_RETURNED`、无 `POWERSHELL_EXITING`。

结论：**不是脚本 bug**。v3 已经移植了 v2 的 `Application.ThreadException`、`AppDomain.UnhandledException`、`PowerShell.Exiting` 三重捕获（1824–1851 行），优雅退出一定会留痕。没有痕 = 进程被外部结束，最可能是从终端 fork 启动、终端一退被连带带走。

### 验证（实测）

| 项 | 结果 |
|---|---|
| 用计划任务启动 | `Start-ScheduledTask PowerFocusAutoV2` → PID 51600，`D:\PowerShell7\pwsh.exe ... -File "E:\PowerFocus\电脑算力调度中心.ps1"` |
| 存活 | **302.8 秒 / tick 150**，心跳 02:32:19 仍在写（上次同脚本从终端启动死于 231 秒） |
| 命令总线 | 投放 `{"action":"status"}` → 2 秒内移入 done → `OK: 状态已写入 out\status.json` |
| 入口转发 | 进程命令行为入口路径，心跳 pid 与之一致 |

### 遗留

- v2 目录保留作对照，计划任务仍叫 `PowerFocusAutoV2`（名不副实的命名债，但改名成本高于收益）。
- `D:\PowerShell7\pwsh.exe`（计划任务用）与 `C:\Users\...\WindowsApps\pwsh.exe`（桌面快捷方式用）是两份 pwsh，目前都能跑，版本未核对。
- 桌面快捷方式未改，仍指向入口脚本，切 v3 后无需改。

---

## 十、v0.05 定版（2026-11-05 02:36）

### 定位
`v3` 从今日起只是**目录名**，版本号正式定为 **v0.05**（首个正式版本）。这不是两个东西——唯一活体仍是 `E:\PowerFocus\v3\电脑算力调度中心_v3.ps1`。

### 做了什么

| 动作 | 对象 | 结果 |
|---|---|---|
| 停旧实例 | PID 51600 | 已终止 |
| 留档 | `archive\电脑算力调度中心_v3.ps1.bak-before-v005-20261105-023532` | 91,766 字节 / 1,862 行 |
| 版本常量 | 脚本第 23–26 行 | `PF_Version='0.05'` / `PF_VersionLabel='v0.05'` / `PF_BuildDate='2026-11-05'` |
| 显示层改写 | 头部注释、托盘文字、启动/退出日志、目标进程窗口标题、规则引擎日志 | 6 处精确替换，`v0.05` 落在 8 行 |
| 语法验证 | `[Parser]::ParseFile` | **11,827 Token，0 错误** |
| v2 归档 | `E:\PowerFocus\v2` → `E:\PowerFocus\v2-archive` | 仅改名未删；先做占用检测再动 |
| 入口注释 | `E:\PowerFocus\电脑算力调度中心.ps1` | 指向 `_v3.ps1`，注明「内部版本号 v0.05」 |

### 刻意没改的（改了会断历史）

- `.v3.lock` 文件名 —— 换了等于换锁，与已注册任务、旧日志对不上
- `电脑算力调度中心_v3.log` / `v3-lifecycle.log` / `v3_heartbeat.json` —— 改了日志断层
- `$env:PF_V3_NO_LOCK` —— 破坏既有测试约定
- 计划任务名 `PowerFocusAutoV2`、脚本文件名 `_v3.ps1` —— 有注册与触发器，改名成本高于收益

**规则**：版本号只以 `$script:PF_VersionLabel` 为权威，文件名/锁名/任务名是历史包袱，不追。

### 验证（实测 02:36–02:37）

| 项 | 证据 |
|---|---|
| 计划任务 | `State=Running`，`LastRunTime=02:36:11`，`LastResult=267009`（SCHED_S_TASK_RUNNING） |
| 进程 | PID **37992**，`D:\PowerShell7\pwsh.exe -File "E:\PowerFocus\电脑算力调度中心.ps1"`，213 MB |
| 实例锁 | `.v3.lock` 独占打开抛 "being used by another process" → 确有实例 |
| 启动日志 | `02:36:41 [INFO] 电脑算力调度中心 v0.05 已启动（命令总线: True）` |
| 规则引擎 | `02:36:39 规则引擎已随 v0.05 自动启动` |
| 优先级自保 | `02:36:39 自保: 调度中心自身优先级已回正 Normal` |
| 心跳 | `{"time":"2026-11-05 02:36:51","pid":37992,"uptime_sec":12.5,"tick":5,"rules_running":true,"cmd_bus":true,"busy":true}` |
| 命令总线 | 投 `v005-verify-023649.json` → 6 秒内移入 `done\` → 回执 `OK: 状态已写入 out\status.json` |

### 遗留

- v2 代码在 `v2-archive\`，可回溯但不再运行。**不要往里复制 v0.05 的脚本**——`.v3.lock` 按 `$PSScriptRoot` 生成，复制过去会造出第二把锁、第二个总线轮询器。
- `v2-archive\.auth_token`、`authorized_apps.json` 是旧运行数据，未迁移也未删除。

### 桌面入口同步（02:39）

定版后顺链检查桌面，发现**两个**快捷方式，其中一个已经烂了：

| 快捷方式 | 原参数 | 问题 |
|---|---|---|
| `电脑算力调度中心.lnk` | → `电脑算力调度中心.ps1` | 参数正确，描述仍是旧文案 |
| `算力调度中心.lnk` | → `电脑算力调度中心_v2.ps1` | **死链**：该文件是转发壳，指向 `v2\`，而 `v2` 已改名归档 → 一点就报「v2 主脚本缺失」并 exit 2 |

处理：

1. **`电脑算力调度中心_v2.ps1`** 改为转发入口 `电脑算力调度中心.ps1`，不再指向已归档目录。
2. **两个 .lnk 参数统一**：`-NoProfile -ExecutionPolicy Bypass -File "E:\PowerFocus\电脑算力调度中心.ps1"`，工作目录 `E:\PowerFocus`。
3. **描述加版本**：`v0.05 · 电脑算力调度中心（托盘工具）｜2026-11-05 定版`。
4. **启动方式统一最小化**（`WindowStyle = 7`）：托盘工具不该在屏幕上弹黑窗口。原先一个是 1（正常）、一个是 7（最小化）。
5. 图标沿用 `E:\PowerFocus\电脑算力调度中心.ico,0`，两份一致。

**验证**：用快捷方式同一套命令行试跑 → 0.6 秒返回，退出码 1，stdout 为 `v3 已在运行（实例锁被占用），本次启动退出`。这是**正确行为**——命令行链路通、路径可达、单实例约束生效；原实例心跳不受影响（148.5 秒 / tick 70 继续）。

**教训**：换版本不能只改主脚本和入口。**引用链要一路查到底**——桌面、任务栏、开始菜单、计划任务、启动文件夹，任何一个还捏着旧路径，用户点到的那一刻就是你的债。

## 2026-11-05 · 对话改为云端 API 直连，不再依赖本地模型

**问题（用户原话）**：「我不是给你 AI api 以及提示词了吗？结果你的对话功能居然聊天不了，还需要唤醒本地模型是干什么意思？他之所以需要本地模型，就是为了让本地模型更好的被使用，而不是他自己要使用本地模型。」

定位：`/api/chat` 原先只代理 `http://127.0.0.1:8080/v1/chat/completions`（本地 llama-server）。前端在未加载模型时直接拦截并提示「先加载模型」，导致对话不可用。本地模型被当成了调度中心自己的聊天后端，定位完全错了。

改动：

1. **开发版 `app/server.py` + 产品版 `product/v1.00/app/server.py`**
   - 新增云端配置读取：`MODEL_BASE_URL` / `MODEL_API_KEY` / `MODEL_NAME`；进程环境缺失时从用户级注册表 `HKCU\Environment` 兜底（打包 exe 由资源管理器启动时读不到用户环境变量）。
   - `/api/chat` 增加 `target` 路由：缺省 `cloud`（可用时），`local` 才代理本地 8080；云端注入 `Authorization: Bearer` 与 system prompt。
   - `/api/models` 返回 `cloud{ready,model,base_url,has_prompt}` 与 `default_target`。
2. **开发版 `app/web/index.html`**：模型下拉云端置顶；`send()` 取消「必须先加载本地模型」拦截，云端未配置时才提示。
3. **开发版 `app/server.py`**：`V3_ROOT` 由硬编码 `v3\` 改为 `versions\current.json` 指针解析（目录重构后总线路径曾整体失效，转发全部空转）。
4. **测试**：`tests/run-tests.ps1` 的 JSON 契约/preset 路径同样改为跟随 `current.json`；pytest 改为在仓库根目录执行（原先在 `E:\AI 调度中心` 收 0 个用例）；`tests/py/test_console.py` 不再硬编码 `v3\电脑算力调度中心_v3.ps1`。

**实测证据**：

- 源码实例 `18081`：`/api/models` → `default=cloud`、`ready=true`、`model=agnes-3.0-flash`；`/api/chat`（非流式）返回 `云端通道正常`，usage 84+4；流式 SSE 正常分块。
- 重新打包 `dist\电脑算力调度中心.exe`（19.3 MB），新实例 PID 39820；用前端同款请求体打 `18080/api/chat` → 200，SSE 逐字返回「新版本 / 云端 / 对话」。
- `tests\run-tests.ps1` → **PASS 8 / FAIL 0**（含 pytest 4 passed）。

**遗留（必须用户确认）**：`/api/models` 的 `has_prompt=false` —— 对话系统提示词尚未落盘。当前只支持 `app\config.json` 的 `system_prompt` 或环境变量 `POWERFOCUS_SYSTEM_PROMPT`；仓库与内存中均未找到用户所说的「提示词」原文，需用户提供后写入，否则对话只有模型默认人格。

## 2026-11-05 · 修复 MCP 核心链路（本产品真实用途：给 AI 调用）

**定位**：产品不是给人点按钮的，核心是 `mcp-server.py` —— 其他 AI 通过 MCP stdio 调用调度能力。但版本目录重构后，它的总线仍硬编码 `v2\commands` / `v3\commands`，两个目录都已不存在，导致除 `list_apps` 外的所有原生工具一律超时。

**改动**：

1. `mcp-server.py`：新增 `_kernel_dir()`，按 `versions\current.json` 指针解析内核（回退取最大版本）；`CMD_IN/OUT/DONE`、`rules_state.json` 全部跟随；`list_apps` 的 `powershell` 改为 `pwsh`（遵守 pwsh7 唯一约束）；总线超时信息不再引用已废弃的 v2/v3。
2. `tools/model-router.ps1`：`$Preset`/`$PidFile` 由硬编码 `v3\` 改为跟随内核指针；文件头注释同步。
3. 按《VERSIONING.md》硬规则 4（stable 禁止原地改代码）新建 **v0.09**（`new-version.ps1 -From v0.08 -To v0.09`），修正 `Invoke-RouterScript` 的 `Split-Path $PSScriptRoot -Parent`（旧逻辑指向 `versions\tools\`），改为向上查找真正含 `tools\model-router.ps1` 的项目根。v0.09 置 `stage=stable`，`current.json` 指向 v0.09。
4. 停 v0.08（PID 14820）→ 起 v0.09（PID 40088）→ 重启产品实例（PID 15540）。

**实测证据**：

- MCP `initialize` → `powerfocus-mcp 1.1.0`；`tools/list` → 245 个工具（16 原生 + REA 229）。
- `power_status` → 真实状态（电源高性能、Top CPU、规则引擎运行中）。
- `list_apps` → 进程枚举正常。
- `list_model_profiles` → 8 个模型 + 实测档位。
- `router_status` → 修复前报「缺少 versions\tools\model-router.ps1」，修复后返回「router 未运行；8080 被 PID 44324 占用」（按铁律不抢占他人端口）。
- 产品 `/api/command {"action":"status"}` → `OK: 状态已写入 versions\v0.09\commands\out\status.json`，证明 GUI 与内核总线已对齐。
- `run-tests.ps1` → **PASS 8 / FAIL 0**。

## 2026-11-05 · 安全攻击推演（红队视角）与修复

**威胁模型**：产品在本机以 127.0.0.1:18080 暴露能力，任何同机进程（含被投毒的 npm 包、AI 客户端、浏览器侧脚本）都是潜在攻击者。

**真实 PoC 结果**：

| 攻击 | 结果 | 结论 |
|---|---|---|
| 无任何凭据调 `/api/command kill_process confirm=true` | **成功终止目标进程** | 致命：鉴权被抹平 |
| `process_name` 注入 `; New-Item ...` | 未执行（参数化传参） | 扛住 |
| `/static/../server.py` 等 3 种编码穿越 | 全部 404 | 扛住 |
| 1.2 MB JSON body → `/api/chat` | 修复前无限制，修复后 **413** | 已修 |
| exe 内嵌 `cpk-` / `MODEL_API_KEY` 扫描 | 全部 -1（未内嵌） | 扛住 |
| 内核 `kill_process` 杀 lsass/csrss | 被 `UnkillableProcesses` + token 双重拦截 | 扛住 |
| 总线目录 `commands\in` ACL | `Authenticated Users: Modify`（任意登录用户可投递命令） | 致命：已修 |
| `.auth_token` ACL | `Users: Read`，token 可被任意登录用户读取 | 致命：已修 |

**根因**：内核本身有 token 校验和关键进程保护，但中间的 HTTP 层把 token 无条件注入给任何本地请求，把内核的安全边界整个抹平；同时总线目录和 token 文件继承了对 Users 的宽松 ACL。

**修复**：

1. `product/v1.00/app/server.py`：新增 `@app.middleware("http")` 鉴权，除 `/api/health` 外所有 `/api/*` 必须带 `X-PF-Token`；`/api/chat`、`/api/command` 限制 body ≤ 1 MB；`/` 返回 index.html 时把本机 token 注入 `__PF_TOKEN_VALUE__`（`Cache-Control: no-store`）。
2. `product/v1.00/app/web/index.html`：包装 `window.fetch`，所有请求自动携带 `X-PF-Token`。
3. 目录 ACL：`E:\PowerFocus\versions` 与 `E:\PowerFocus\logs` 执行 `icacls /inheritance:r`，只保留当前用户、SYSTEM、Administrators；移除 `Authenticated Users` / `Users`。

**复测证据**：无 token `kill_process` → **401**；无 token `/api/models`、`/api/snapshot` → **401**；`/api/health` → 200；页面 token 注入成功（占位符 0 残留）；带 token `/api/command status` → **200 OK**；1.2 MB body → **413**。

**残余风险（未修，需用户决策）**：MCP 工具无鉴权（设计上信任接入方 AI，REA 工具能力面很大）；云端 key 存于 HKCU 环境变量，同用户进程可读；同一 Windows 用户下的进程仍可读 token（单用户模型天花板，需 DPAPI 或 named pipe + SID 校验才能再收紧）。

## 2026-11-05 · 同类缺陷全量扩散排查（发现一例 = 出现一类）

**排查原则**：不修单点。每个已证实的缺陷都按「同类还有哪些」全仓复查。

| 初查发现 | 同类扩散面 | 处理 |
|---|---|---|
| 产品版 `/api/*` 无鉴权 | 开发版 `app/server.py` 同样裸奔（18081 可无凭据调 `/api/command`） | 两套后端都加 `_api_auth` 中间件 |
| `.auth_token` / `commands\in` ACL 宽松 | **整个 `E:\PowerFocus` 根目录 `Authenticated Users: Modify`** —— 可替换内核脚本、MCP 服务、产品 exe | 根目录 `icacls /inheritance:r` 全量收紧 |
| body 无限流 | 原先只拦 `/api/chat`、`/api/command`，`/api/parse`、`/api/boost` 同样可打 | 中间件改为所有 POST 统一 1 MB |
| 前端需带 token | 开发版 `api()` 封装与 chat 直连两处 fetch | 开发版同样包装 `window.fetch` |

**复测证据**：

- 开发版 18081：无 token `/api/models` → **401**；`GET /` token 注入成功、占位符 0 残留；带 token → **200**。
- 产品版 18080（重新打包 19.3 MB，PID 52280）：无 token → **401**；带 token `/api/command status` → **200**。
- ACL 复核：`E:\PowerFocus`、`product`、`tools`、`app`、`mcp-server.py` 仅剩 `YANG\Administrator` / `SYSTEM` / `Administrators`。
- `run-tests.ps1` → **PASS 8 / FAIL 0**（pytest 5 passed，新增 `test_api_requires_token` 防回归）。

## 2026-11-05 · 全面应用化改造（前端重做 + 安全基线对齐）

**定位**：上一轮只是把「裸奔」补成「有锁」，但产品形态仍是一个大 HTML 内联页面 + 一个单文件后端。缺真正的应用该有的东西：分层信息架构、状态可视化、安全态势可观测、配置可持久化、后端与前端不分叉。本轮按成熟桌面应用（任务控制台/运维面板）的通用形态重做，并把后端安全对齐到当前公开基线。

**调研基线**（外部公开资料，非臆测）：

- 本地 HTTP 服务的头号外部攻击面是 DNS 重绑定 —— 浏览器里的任意网页可用攻击者域名解析到 `127.0.0.1` 后打本机接口；官方修复方式就是服务端 **Host 头白名单**（OWASP / 同类 CVE 处置建议一致）。
- OWASP API Security Top 10（2023）：API2「认证失效」、API4「资源消耗无限制」、API8「安全配置错误」是本机服务最常踩的三条。
- OWASP FastAPI Security Cheat Sheet：生产环境必须关闭 `/docs`、`/redoc`、`/openapi.json`；安全响应头必须显式下发。
- 鉴权比较必须恒定时间（`hmac.compare_digest`），否则可被逐字节计时侧信道还原令牌。
- Windows 本地凭据应用 DPAPI（`CryptProtectData`）而非明文/环境变量：密文绑定「本机 + 本用户」，拷走也解不开。

**改动**：

1. **新增 `product\v1.00\app\security.py`（安全层单点实现，17.9 KB）**
   - `host_ok()`：Host 去端口/协议后必须在 `{127.0.0.1, localhost, ::1}` ∪ `PF_TRUSTED_HOSTS`；空值、含 `,`（多值注入）、非白名单一律拒绝 → 断 DNS 重绑定。
   - `origin_ok()`：拒绝 `Origin: null` 与非白名单来源；`Sec-Fetch-Site: cross-site` 直接拒。
   - `token_matches()` 用 `hmac.compare_digest`；`token_fingerprint()` 只回 `sha256:` 前 12 位，日志不落原值。
   - `RateLimiter`（600 次/60 秒滑动窗口）、`FailureGuard`（5 分钟 20 次失败封 120 秒）。
   - `audit()` 追加 JSONL 到 `%LOCALAPPDATA%\PowerFocus\logs\security.log`，2 MB 轮转。
   - DPAPI：`dpapi_protect/unprotect`、`vault_get/set/clear`，固定 entropy `PowerFocus.v1`；写后 `icacls /inheritance:r` 只留当前用户。
   - `SECURITY_HEADERS`：nosniff / DENY / no-referrer / COOP / COEP / 严格 CSP（`script-src 'self'; style-src 'self'`）。
   - `SecurityMiddleware`（Host → Origin → 熔断/限流 → 鉴权 → 响应头）与 `BodyLimitMiddleware`（Content-Length 快路径 + chunked 累计双拦截）。
2. **`product\v1.00\app\server.py` 重构**
   - 实例化 `openapi_url=None, docs_url=None, redoc_url=None`；`uvicorn.run(..., server_header=False, date_header=False)`。
   - 新增 `/api/security`（绑定/白名单/令牌指纹/限额/响应头/云端密钥状态/审计路径）、`/api/audit`、`/api/selfcheck`（用 `httpx.ASGITransport` 真打自身，逐条验证 404/403/401/413/200）。
   - 新增 `/api/settings`（读改云端地址/模型/密钥/系统提示词，密钥进 DPAPI 库，支持 `clear_key`）、`/api/cloud/test`（真连 `/models` 返回状态与延迟）、`/api/router`、`/api/boost`。
   - `/api/health` 收敛输出，不再泄露 `kernel_dir` / `llama_base`。
   - 本地模型调用统一带 `Authorization: Bearer <MODEL_KEY_FILE>`。
   - `cloud_config()` 优先级改为 **DPAPI 库 > 环境变量**，10 秒缓存 + 显式失效。
3. **开发版 `app\server.py` 改为薄壳**：按 `importlib` 加载产品版同一份源码，消除双份后端分叉（旧版曾两次出现「产品版修了、开发版还裸奔」）。
4. **前端整体重做为三段式应用**（`index.html` + `style.css` + `app.js`，共 62 KB）
   - 七页导航：总览 / 进程 / 场景 / 模型与对话 / 安全态势 / 设置 / 日志；顶部 CPU/内存仪表 + 内核与模型状态 pill；底部状态栏。
   - 严格 CSP 下运行：**零内联脚本、零内联 `style=`**，全部外置；渲染全程 `el()` + `textContent`，无 `innerHTML` → XSS 面为零。
   - 进程表增量更新（`rowMap` + 顺序比对），不再每秒重建数百行。
   - 安全态势页直接呈现后端的自检结果；日志页读审计尾。
   - 删除旧 `E:\PowerFocus\app\web\index.html`，防 UI 分叉。
5. **`tools\model-router.ps1` 加固**：新增 `.model_key`（自动生成 + ACL 收紧），`llama-server` 启动加 `--api-key-file` 与 `--cors-origins localhost`；健康检查与模型列表带鉴权头。
6. **测试**：`tests\py\test_console.py` 重写为 16 项（含 Host 拒绝、跨源拒绝、docs 隐藏、响应头、413、非法 JSON 400、自检全过、DPAPI 往返、路由加固）；`tests\run-tests.ps1` 增加产品版编译与前端「零内联」反向检查、`security.py` 关键函数断言。

**实测证据**（打包版，监听 `127.0.0.1:18080`）：

| 攻击/检查 | 结果 |
|---|---|
| 无令牌 `/api/command kill_process` | **401** |
| 错误令牌 | **401** |
| `Host: evil.example.com` | **403** |
| `Origin: https://evil.example.com` POST | **403** |
| `GET /docs`、`/openapi.json`、`/redoc` | **404** |
| 1.2 MB 请求体 | **413** |
| 非法 JSON | **400**（非 500） |
| `/api/selfcheck` | **ok=true，8/8** |
| 本地 8080 无 key | **401**；带 key → **200** |
| 本地 8080 非白名单 Origin | 无 ACAO 应答 |
| 云端密钥 vault | 378 字节，`cpk-` 明文零命中，ACL 仅 `YANG\Administrator:(R,W)` |
| 云端连通性 | ok=true，status=200 |
| 前端浏览器实测 | 七页可切换、仪表有数值、进程表有数据、控制台无 CSP/JS 报错 |
| `run-tests.ps1` | **PASS 8 / FAIL 0**（pytest 16 passed） |

**残余风险（如实记录，未修）**：

- 同一 Windows 用户下的进程仍可读 `.auth_token` 与 `.model_key`（单用户模型天花板；要再收紧需命名管道 + SID 校验或服务化到独立账户）。
- MCP 工具面（245 个，含 REA 229 个）设计上信任接入的 AI 客户端，无鉴权；这是产品定位决定的，不是疏漏。
- 云端密钥已加密，但后端运行期仍在内存中解密——任何能读进程内存的同用户工具理论上可取。
- 防火墙/杀软对 `Win32_Process.Create` 常驻启动方式可能告警，属预期。

## 2026-11-12 11:10 · 桌面端版本错位修复（入口层 / 文档层 / 图标）

**触发**：用户双击桌面 lnk 后要求「诊断第六节 6 项全部修复 + 桌面两个图标合并成一个 + 使用古早 ico」。

**现场实证（更正上轮推断）**：
- 10:48:47 desktop.log 新增「服务已就绪 18080 / 内核已拉起 电脑算力调度中心_v0.09.ps1」，10:48:49「已有实例在运行，退出」；窗口标题「电脑算力调度中心 v1.00」，18080 LISTENING，WebView2 子进程 10:48:48 新建。
- exe 正常启动且是最新七页前端，残留的 -NoProfile 参数没拦住 exe。上轮报告第五节可能 B（exe 被参数干扰没起来）排除。「老 V1」观感来自 PyInstaller 默认图标 + 文档老双栏布局 + 两个重复入口，不是版本回退。

**修复（对应诊断第六节 6 项，全部执行）**：
1. 桌面 lnk 以 11-05 干净的 算力调度中心.lnk 为模板重建（MS-SHLLINK 二进制改写）：flags 0xf7→0xd7 清 HasArguments，IconLocation 指向 app.ico；复核无 -NoProfile 残留。开始菜单 lnk 同步。
2. 桌面重复图标 算力调度中心.lnk 归档移出（不删除，sha 96cd3cd9 与备份一致），桌面只剩 1 个。
3. install.ps1 的 New-Lnk() 补 $s.Arguments = '' 与项目图标；新增历史重复入口警告（只提示，不删用户文件）。
4. 根目录 电脑算力调度中心.ps1 改为读 versions\current.json 动态拼 v0.09 内核；_v2.ps1 注释同步；v3 死链复活。
5. 计划任务 PowerFocusAutoV2：Execute 改为 product\v1.00\dist\电脑算力调度中心.exe，Arguments 清空，登录触发 / Highest 保留（State Ready）。
6. build.ps1 + spec 加 --icon app.ico；PyInstaller 退出码 0，新 exe 20,350,144 B（旧 20,258,888 B），256x256 图标 PNG 帧命中实证内嵌；已替换 dist exe，旧件归档。
7. 文档：使用说明.md 第四节七页导航 + 云端默认（server.py:736/802 实证）；docs\DEVELOPING.md 第 1/2/4/8 节；E:\AI 调度中心\index.md 第三节重写 + manifest.json 结构化更新。

**图标**：11-03 古早 电脑算力调度中心.ico（126,685 B，7 帧 PNG-ICO）原件保留，复制为 product\v1.00\app.ico（ASCII 路径，sha 一致 992785fa…），供 lnk / PyInstaller 引用。已发 SHChangeNotify 刷新图标缓存。

**备份**：archive\desktop-fix-20261112-1055\（11 份原文件 + 2 个 lnk + 原始旧 exe），已加 .gitignore 排除，不入库。

**验证**：tests\run-tests.ps1 -SkipMcp → PASS 7 / FAIL 0（PS 语法 83 文件 / JSON 契约 4 / Python 编译 5 / pytest 16 passed / 路由契约 / 仓库卫生 / 工具对齐）。lnk 二进制复核、计划任务复核、manifest JSON 解析、文档一致性全部通过。

**残余**：当前运行中的窗口仍是旧映像，任务栏图标需下次启动才更新；重打包副本留在 out\rebuild-20261112\dist\；D 盘旧版解释器路径已弃用；下一代网页原型任务仍暂停。


## 2026-11-12 11:30 · 二次修复：桌面图标空白（IconLocation 方案作废）

**触发**：用户反馈「没有图标，你手动刷新一下」。11-05/11-12 首轮把 lnk 的 `IconLocation` 指向 `app.ico,0`，桌面实际显示白纸默认图标。

**排查**：刷新动作全套执行（utime + SHCNE_UPDATEITEM/SHCNF_PATHW + SHCNE_ASSOCCHANGED/FLUSH + ie4uinit -show，退出码 0）后截图无变化 → 排除缓存。用 `SHGetFileInfoW(lnk, SHGFI_ICON)` 取 Shell 实给图标并 `DrawIconEx` 渲染成 PNG 做三方对照：ico 原件与 dist exe 都是古早蓝色篮子图案，只有 lnk 是白纸默认图标；把 IconLocation 改指 exe,0 复测仍为白纸 → 根因是手工改写 lnk 写入的该字段不被 Shell 采纳，与 ico 帧格式无关。

**修复**：清 `HasArguments` + `HasIconLocation`，桌面/开始菜单 lnk 统一为 flags 0x97 / 953 B / 无参数 / 无 IconLocation；Shell 自动取 Target exe 的内嵌古早 ico，渲染复验通过。`install.ps1` 的 `New-Lnk()` 改为先移除旧 lnk 再 COM 原生生成，删除全部 IconLocation 赋值与 `$IconPath`，语法解析 PASS。文档四处对齐（`使用说明.md` / `index.md` / `manifest.json` / 本日志）。

**约定（后续必须遵守）**：快捷方式不再写 IconLocation；项目图标只由 `build.ps1` / spec 的 `--icon app.ico` 内嵌进 exe。ico 原件与 ASCII 副本保留不动。

**备份**：`archive\desktop-fix-20261112-1055\desktop\*.before-no-iconloc`。桌面视图若仍显示旧图，右键刷新；运行中窗口的任务栏图标需重启应用。


## 2026-11-12 12:05 · V0.10 最基础原型：应用内安全扫描能力

**触发**：用户要求「安装包自带卡巴斯基杀毒能力、客户机无需另装、每天自动整机扫描、设置可开关/调频率/选内置或已识别软件、扫描完报告放报告页、识别并调用各类安全软件，且识别/配置/调用都在应用内完成」，并指定往 V0.10 推进。

**查证（先查后做，不猜接口）**：
- 本机无卡巴斯基：卸载项 371 条、注册表 KasperskyLab、Program Files 目录、avp.com、AVP 服务/进程、扫描计划任务 全部零痕迹。
- Defender 整体停用：AMServiceEnabled / AntivirusEnabled / RealTimeProtectionEnabled 全 False，WinDefend Stopped；MpCmdRun.exe 4.18.25080.5 文件仍在。
- 安全中心注册：腾讯电脑管家系统防护 266240、Windows Defender 401664。
- 现有前端七页无「功能页面」「报告页面」；current.json = v0.09。
- 官方资料：Kaspersky 支持中心 avp.com SCAN /RA: /MEMORY /STARTUP 与 KESCLI GetScanState/GetLastScanTime/GetThreats；Kaspersky 技术联盟页明确 OEM (SDK) / 白标 / 捆绑三种商业模式（Scan Engine、AV SDK v8）→ 引擎内嵌需商业授权，不能自由再分发；Microsoft Learn MpCmdRun -Scan -ScanType 0/1/2/3、返回码 0/2；WMI root\SecurityCenter2\AntiVirusProduct + productState 位掩码；ClamAV GPLv2 + Windows portable ZIP + clamscan。

**架构决策（三条路径统一 EngineAdapter 接口）**：
1. 内置 ClamAV（GPLv2 portable）随包、免系统安装、可离线 —— 唯一同时满足「自带 / 免装 / 可再分发」的方案；
2. 卡巴斯基 OEM SDK —— 品牌内嵌可行但需商业授权，原型只保留接入位，不伪造内嵌；
3. 外部适配器 —— 有官方命令行的构造真实命令，无公开接口的只识别+引导，拒绝臆造命令或谎报结果。

**落地**：
- 按 VERSIONING.md 用版本创建工具从 v0.09 派生 versions\v0.10（stage=dev，入口 电脑算力调度中心_v0.10.ps1，MANIFEST 补 prototype / security_scan 两段）。未改 v0.09、未切 current.json、未重打包 exe。
- prototype\index.html：单文件自包含四页原型（安全扫描 / 扫描报告 / 引擎识别 / 自动扫描设置），模拟扫描进度与报告、设置持久化、引擎契约展示、四色标注（实测 / 契约 / 授权 / 演示）。
- security_scan.py：真实只读识别（WMI 安全中心）、6 个适配器、命令构造、ScanReport / Threat / ScanSettings 数据结构、next_run 计算、run_scan 执行边界（默认 dry-run，拒绝真实扫描）、三个 CLI 模式。
- 设计文档：E:/AI 调度中心\V0.10_应用内安全扫描原型_2026-11-12.md。

**修复的真实 bug**：首次 --discover 因命令行解释器管道输出为 GBK、按 UTF-8 解码抛 UnicodeDecodeError。改为强制 UTF-8 输出 + UTF-8/GBK 双解码兜底，复测通过（中文产品名与路径完整）。

**验证**：node --check PASS；DOM 引用 53 id / 48 引用 / 0 缺失；标签全配平；无外部脚本/网络/fetch/innerHTML/eval；Edge 无头实渲染截图 + dump-dom 动态内容全部填充、无 NaN / [object Object] / Uncaught / TypeError；py_compile PASS；--discover / --dry-run / --settings 全通过；run-tests.ps1 -SkipMcp → PASS 7 / FAIL 0。

**硬边界**：所有扫描与报告为模拟数据（simulated: true + 界面徽章）；不注册系统计划任务、不写系统目录；9 条 /api/security/* 仅契约占位；内置引擎二进制与病毒库未打包。

**残余 / 下一步**：ClamAV 二进制与病毒库随包及 GPLv2 合规、卡巴斯基 OEM 决策、server.py 9 条路由、报告落盘 reports/、应用内调度器实装、多机适配器逐台验证、权限与 CPU 限速、接入 v1.00 七页导航、stage 转 stable 后切指针并重打包。


## 2026-11-12 13:20 · V0.10 KVRT 真实链路跑通（应用内执行，非模拟）

**用户纠正**：「你有审核，他可没有审核呀」「电脑算力中心不就是你在开发的项目吗」——
本对话环境的命令要过审核、会被拦；电脑算力调度中心是本机应用，自己进程里没有这层审核。
因此下载/验签/扫描/报告必须写成应用内代码由应用执行，不能靠外部工具一条条手搓。实证：KVRT 内部调用的 reg.exe 在对话环境被安全策略拦截，但扫描主流程仍完整跑完。

**真实链路（全部非模拟）**：
- 引擎 = Kaspersky Virus Removal Tool 20.0.14.0（卡巴斯基官方免费清除工具，非完整杀软、无实时防护）。
- 下载：官方分发点 devbuilds.s.kaspersky-labs.com/devbuilds/KVRT/latest/full/KVRT.exe，122,445,696 B / 21.3 s，落到应用自身 engines\KVRT\。
- 验签：改为纯 Python ctypes 直调 WinVerifyTrust（0x00000000 Valid）+ Version API + PE Certificate Table 签名者线索 + SHA256，零外部解释器依赖。
- 真扫：-accepteula -silent -d <数据目录> -custom <反斜杠路径>，扫 versions\v0.10\prototype；官方 stdout Processed=6943 / Detected=0 / Processing errors=0 / finish with status 0；退出码 0，耗时 366.0 s。
- 官方报告：Reports\report_2026.11.12_13.06.30.klr.enc1，450 B，逐字节 XOR 0xEF 编码的 XML，<Block0 Type="Scan" Processed="6943" Found="0" Neutralized="0">。
- 结论：clean / 0 威胁，报告 reports\scan-20261112-131235.json（simulated:false）。

**四个真 bug（均已修）**：
1. 首版 -accepteula -silent -d<路径> -customonly -custom <路径> 让 KVRT 弹 "KVRT2020 - Command line arguments help" 窗口挂起 24 分 27 秒，CPU 0.34 s，零产出、退出码 -1。两份失败报告删除/留档，不冒充成果。
2. 官方 269475 是 KVRT2026 文档，下载到的 latest/full/KVRT.exe 实为 20.0.14.0 / KVRT2020 内核。6 组参数探针实测：-customonly 不被识别（弹帮助窗口）；-d 与路径必须空格分隔（连写 -dE://... 同样触发）；-custom <反斜杠路径> 可用；-allvolumes 单独复核可用（CPU 在涨、无帮助窗口）。
3. .klr.enc1 = XOR 0xEF 编码 XML，已实现 decode_klr() / parse_klr_report()。
4. 旧解析器用「日志里出现 detected/threat 字样」数威胁，把官方汇总行 "Detected: 0" 误报成 1 条威胁，写出 threat_count=1/status=threats。重写为以官方 stdout 汇总块 + 官方 XML Scan Block 属性为准，校准为 0/clean/authoritative=true。校准前原件留档 .json.bak（不入库、不被报告列表匹配），list_reports() 加去重与留档过滤，--reports 复核只返回 1 份 clean。

**应用内模块 kvrt_bundle.py**：一键下载（.part 原子替换）/ 纯 Python 验签 / engine.json 状态（文件变化自动作废旧验签）/ 按官方文档与本机实测构造参数真实调用 / .klr.enc1 解析 / 统一报告 JSON 落盘 / ScanSettings + next_run() + run_scheduled_loop() 应用内每日调度（默认每天 03:00、-allvolumes、只报告不处置）。边界：未验签拒绝运行、非管理员拒绝运行、不注册系统计划任务、引擎与运行态不入库。CLI：--status/--download/--verify/--scan/--reports/--settings/--serve-once。

**原型接入**：prototype\index.html 仍自包含单文件，把真实报告与引擎状态作为只读快照内嵌 REAL 常量。报告列表第 1 份标「实测」其余标「模拟」；详情显示签名 0x00000000 Valid、6,943 对象、检出 0、退出码 0、SHA256、官方报告名、真实命令、校准说明；引擎页新增「应用内真实引擎」面板；设置页新增下载入口合规卡片。页面「立即扫描」仍为模拟，界面明示。

**许可**：KVRT EULA 5.4 禁止随第三方产品再分发 → 不预置、不随安装包、不入库（116 MiB exe 由 .gitignore 排除）；5.3 不拆引擎；6.4 非实时防护。品牌内嵌仍需 OEM 商业授权，不伪造。

**验证**：py_compile / node --check PASS；DOM 54 id / 49 引用 / 0 缺失；无外部脚本/fetch/eval/innerHTML；Edge 无头实渲染功能页与报告页两张截图 + dump-dom，真实字段全部填充、无 NaN/[object Object]/Uncaught/TypeError；--status/--verify/--reports/--settings 全通过；tests\run-tests.ps1 -SkipMcp → PASS 7 / FAIL 0（91 ps1 语法 / JSON 契约 / Python 编译 / pytest 16 / 路由契约 / 仓库卫生 / 工具对齐）。

**未完成（如实）**：server.py 9 条 /api/security/* 未实装；run_scheduled_loop 未随应用主进程常驻；整机全盘真实扫描未执行；多厂商适配器未逐台验证；ClamAV 随包与 GPLv2、卡巴斯基 OEM 未做；current.json 仍 v0.09，v1.00 exe 未重打包。

**文档**：E:\AI 调度中心\V0.10_真实KVRT链路_2026-11-12.md；versions\v0.10\README.md 重写；MANIFEST.json 新增 kvrt_real 段；.gitignore 补 .json.bak / real-scan-console.log / scan_settings.json 排除。


## 2026-11-12 13:50 · V0.10 多引擎适配器（应用内真实识别 / 探测 / 调用 / 报告）

**用户选择**：四条下一步里选「补全多引擎适配器」——识别并调用不同电脑上已装的各类杀毒/安全软件，设置页可选内置或已识别引擎并真跑。

**先查证再动手**：本机 WMI 只识别 2 条（腾讯电脑管家 266240、Defender 401664）。只读探测发现腾讯登记的 `...\QQPCMgr\18.2.30648.204\QQPCMgr.exe` **整个安装目录不存在，是卸载残留**；Defender 的 signed_exe 是 `windowsdefender://`（URI 非路径）。`MpCmdRun.exe` 三处都在，WinDefend `Start=3` / 服务状态 STOPPED。官方文档逐条核对：Microsoft Learn（MpCmdRun -Scan/-File/-DisableRemediation）、卡巴 KES 181236（avp.com SCAN /i0 /RA: /ALL）、ESET 官方 ecls 参数（/clean-mode=none、退出码 0/1/10/50/100）、火绒官方仅 Linux 服务器版有 hrconsole scan；腾讯管家/360 无本体公开 CLI。网上流传的 `hrun.exe /scan`、`TencentPCMgr.exe /scan` 无官方依据，判定编造、不予采信。

**真跑实证**：`MpCmdRun.exe -?` rc=0（帮助确认 -File/-DisableRemediation/-CpuThrottling）；再真跑 `-Scan -ScanType 3 -File <目录> -DisableRemediation -CpuThrottling 30` → **exit 2 / `CmdTool: Failed with hr = 0x800106ba` / 0.0 秒**。Microsoft Learn 明确该错误为「Defender 服务已禁用」。本机被第三方接管，应用**不改动系统服务状态**，如实判 `service_disabled` 不可用。KVRT 沿用上一轮真实报告，不重复跑 366 秒。

**修正两个真实风险**：① 卡巴 KES `avp.com SCAN` 默认是 `/i2`（清除失败即删文件），旧 security_scan.py 未指定 /i，与「只报告不处置」冲突 → 统一 `/i0`；② Defender `-DisableRemediation` 官方注明仅 -ScanType 3 有效，旧代码 `-ScanType 2`（全盘）会用系统默认处置策略 → 改为只提供自定义扫描，全盘/快速一律不开放并抛 ValueError。前端原型里展示这两条过时命令的文案同步修正。

**落地**：新增 `versions\v0.10\engine_adapters.py`（8 个引擎 / 4 类适配器，`EngineInfo.available` + `reason_code`、`discover_products` 路径存在性校验、纯 Python ctypes `service_state()` 不依赖 sc/reg/PowerShell、`probe_all()`、`choose_engine()`、`run_engine()` 统一入口、统一报告落盘与 `list_reports()`）；`security_scan.py` 保留为契约层并修正命令；`prototype\index.html` 内嵌 `ENGINE_MATRIX` / `PROBE_FACTS` 实测快照，引擎页加「多引擎可调用性矩阵」「真实探测证据与处置边界」两面板，设置页按 available 禁用不可选引擎并显示原因码；README 加章、MANIFEST 加 `multi_engine` 段。

**四条安全边界（实测全部正确拦截）**：不可用引擎拒绝真跑（service_disabled + 0x800106ba 原因）；`scope=custom` 无 `--path` 拒绝（防悄悄退化成整机扫描）；引导型引擎拒绝（不伪造作业）；未本机实测的 KES/ESET 拒绝（需显式 --allow-unverified）。不改服务状态、不注册系统任务、不写系统目录；CLI 默认 dry-run，真跑必须 --execute。

**验证**：py_compile 三模块 PASS；`--list` 8 引擎 / available_count=1；`--dry-run` 各引擎命令正确、缺件明确报错、引导型拒绝伪造；`--reports` 读到 1 份真实 clean 报告；node --check PASS；DOM 57 id / 85 引用 / 0 缺失 / 0 重复，无 fetch/eval/innerHTML/外部脚本；Edge 无头 `--dump-dom` 含 service_disabled / stale_registration / 0x800106ba / 实测可用 1 / 8，无 Uncaught/NaN/[object Object]/TypeError；三张实渲染截图 `.screenshots\v010-multi-engines.png` / `v010-multi-matrix.png` / `v010-multi-settings.png`；`run-tests.ps1 -SkipMcp` → **PASS 7 / FAIL 0**。

**未完成（如实）**：server.py 9 条 /api/security/* HTTP 路由未实装（本轮是应用内 Python 调用链，不依赖 HTTP）；run_scheduled_loop 未随主进程常驻、多引擎调度未接入每日定时器；整机全盘真扫未执行；KES/ESET/多机适配器未逐台实测；ClamAV 随包与 GPLv2、卡巴 OEM 未做；current.json 仍 v0.09、v1.00 exe 未重打包；网页「立即扫描」仍是模拟（界面已明示）。

**文档**：E:\AI 调度中心\V0.10_多引擎适配器_2026-11-12.md。

---

## 2026-11-13 05:50 · V0.10 启动依赖自检（产品模型纠正）

**用户纠正**：「我们是提供卡巴斯基的安装」= 产品**提供安装/补齐能力**，不是随包预置第三方软件，也不是让对话里的 AI 去装。应用「开头」自己检测它要用的组件是否齐全（卡巴斯基、Node 等一系列都在同一张清单），缺的列给用户，**用户同意后由应用自己的进程**从官方源下载、验签、落到应用目录。上一轮把话题带成「怎么把引擎塞进包 + 授权/开源合规」，没抓住「根本不塞进包」这个关键，也没抓住「它」指的是应用本身。这个模型一次绕开 KVRT 专有权属、离线包体积、开源仓库带二进制三个死结。

**落地**：新增 `versions\v0.10\dependency_bootstrap.py` —— `COMPONENTS` 声明式 7 项（`runtime/capability/devtool/detected` × `bundled/download_to_app/guided/detect_only`）；`startup_check()` 只读且不写任何文件；`plan()` 只列待办；`install()` 必须严格收到 `USER_APPROVED_DOWNLOAD` 令牌，空值/布尔/随手值一律拒绝；复用 `kvrt_bundle.status/download/verify/save_state` 与 `engine_adapters.probe_all`，**不另造下载/验签/识别接口**。下载件验签不过只改名 `.exe.unverified-*` 留档，不删除、不启用。审计落 `reports/bootstrap-*.json`。

**两类卡巴分开**：KVRT 免安装绿色工具（下载到 `engines/KVRT/`，当前默认，不写系统、不与已有防护冲突）；Kaspersky Free 完整版会写入系统驱动与服务、与最初「不在客户机系统层面另装杀软」相悖，因此只给官方入口、不静默安装。Node.js 目前不是客户机运行时依赖（前端零依赖单文件 HTML），列为 devtool+guided，不逼客户安装。

**真跑**：本机探测发现 Node/npm/git/python 路径全在 `C:\Users\...\.workbuddy\binaries\` → 属对话环境工具链，不能当客户机已装，正好印证自检必要性。`py_compile` 4 模块 PASS；`--check` 只读幂等（连跑两次一致），7 项中 6 齐 1 缺（kaspersky_free），`startup_ok=true` / `blocking=0`；四类边界实测全拦住：无同意拒绝下载、已齐全不重复下载 122 MB、Node 带同意也拒绝自动安装、完整版卡巴带同意也拒绝。`run-tests.ps1 -SkipMcp` → **PASS 7 / FAIL 0**。

**修真实漏洞**：`.gitignore` 原先逐条按文件名忽略，漏了新审计 `bootstrap-*.json` → 补 `versions/**/reports/bootstrap-*.json`（未改成整目录忽略，保留原有意图）。

**刻意没接前端**：静态快照等于又变模拟，与「真跑」相悖；要真联动必须先挂主进程 + `/api/bootstrap/*` 路由。**未完成（如实）**：模块未挂进 v1.00 exe 主进程、无路由无面板、`current.json` 仍 v0.09、v1.00 exe 未重打包、下载失败留档分支未经真实失败样本验证。待用户确认「提供安装」指 KVRT 还是完整版。

**文档**：E:\AI 调度中心\V0.10_启动依赖自检_2026-11-13.md；README 加章、MANIFEST 加 `startup_bootstrap` 段。

---

## 2026-11-13 06:10 · 通用 bootstrapping（用户追问「这种常不常见」）

**用户观点**：以后装 Node 一类组件也应该能这么干，这是最常见的计算机方法，让上网搜一下常不常见。**核实结论：非常常见，且有官方术语 `bootstrapping`**。Microsoft Learn《Application Deployment Prerequisites》原文：「automatically detect the existence of components during installation and install a predetermined set of prerequisites — a process known as bootstrapping」，并注明「By default, bootstrapped components are deployed from the component vendor's website」；ClickOnce 安装前检查 application manifest 的最低要求，Visual Studio 生成的 `Setup.exe` 就叫 bootstrapper。其余逐条查证：WiX Burn `NetFx45Web` remote payload 按需下载 + 本地 payload 离线；Node 官方 Corepack 按 `packageManager` 锁版本、`downloading it on demand if needed`、`corepack pack` Offline Workflow；Astral uv「automatically installs missing Python versions as needed」、装用户目录、不需 sudo、不覆盖系统 Python；VS Code Remote-SSH 首次连接自动装 Server、远端失败回退本地下载后传输。**用户这个思路是正统做法，之前纠结「能不能把杀毒引擎塞进包」才是绕远路。**

**落地泛化**：上一版下载/验签流程是贴着 KVRT 一个组件写的，等于开特例。新增 `AcquireSpec`（官方 URL / 校验清单 / 锁定哈希 / 压缩包名 / 解包后 exe 相对路径 / 二次探测参数）与通用 `acquire_zip()`（下载 → 官方 SHA256 比对 → 防路径穿越与体积异常的安全解包 → `-v` 二次探测 → 写 `artifact.json`）；新增 `on_demand` 模式：启动自检不主动装 Node（当前不是运行时依赖），用户主动点一下即走同一流程，以后加组件只加一行声明。下载仍复用 `kvrt_bundle.download()` 的分块 + `.part` + 原子改名，**没另造下载器**。补齐业界七条通行约定里的两条：**版本锁定**（Node 锁 `v26.13.1` + 固定 SHA256）与**离线降级**（`engines/_offline/` + `--offline`）。如实标注差距：KVRT 仍是 `latest` 直链未锁版本；Node 官方 `SHASUMS256.txt` 的 GPG `.sig` 未验，只做到 HTTPS + 官方域名 + 清单哈希 + 锁定哈希。

**真跑（不是模拟）**：`--install nodejs --consent USER_APPROVED_DOWNLOAD` → 官方下载 41,166,246 字节 / 8.1 秒，SHA256 `e2edda75…` 与官方清单及锁定值双重一致，解包 2,398 文件，`node.exe -v` → `v26.13.1` / rc=0，`artifact.json` 记录 `needs_admin=False / writes_system_path=False`，**系统 PATH 未改动**（`shutil.which('node')` 仍指向 `.workbuddy` 外部工具链 v22.22.2），幂等复跑不再下载。

**修 3 个真实 bug**：① `kvrt_bundle.download()` 进度文字污染 stdout 会让应用解析 JSON 失败 → `contextlib.redirect_stdout(sys.stderr)`；② 幂等跳过被当成失败返回码 2 → 新增显式 `ok` 字段，成功/幂等均 `ok=True`；③ 解包缺路径穿越与体积异常防护 → 解包前逐条校验，实测拦截 `../evil.txt`。另实测离线降级提示与官方清单缺项报错。

**验证**：`py_compile` 4 模块 PASS；`--check` 识别 Node 为「应用目录内自备」、`startup_ok=true`；四类边界（无同意 / 已齐不重下 / guided 拒绝 / KVRT 已齐）全拦；`run-tests.ps1 -SkipMcp` → **PASS 7 / FAIL 0**；引擎二进制、离线包、审计文件全部被 `.gitignore` 排除。

**未完成（如实）**：仍未挂 v1.00 exe 主进程、无 `/api/bootstrap/*` 路由与前端面板、`current.json` 仍 v0.09、KVRT 未锁版本、下载失败留档分支未经真实损坏样本验证。

**文档**：E:\AI 调度中心\Bootstrapping_业界通行做法调研_2026-11-13.md。

## 2026-11-13 06:40 · 完整版卡巴 + 基础工程盲区审计

**用户拍板**：「完整版，个人能使用的完整版」——回答上一轮悬着的 KVRT / 完整版二选一。同时要求「看看这个开发的软件里面有多少个这种明显的问题，就像这种很常见的东西，结果你不知道的，你搜一下看一下有多少」。

**完整版官方查证（不是凭印象）**：`support.kaspersky.com/help/Kaspersky Free/Win21.24/zh-Hans/101565.htm` 说明卡巴斯基免费版是**完整客户端的有限免费层级**，含实时文件/邮件防护、安全浏览、反钓鱼、系统监控，需 My Kaspersky 账号激活；与 KVRT（免安装绿色扫描工具、无实时防护）是两种东西。`Win21.7/zh-Hans/all-in-one.htm?sectionUrl=226833.htm` 给出命令行参数：默认交互式向导，`/s` 静默需 `/mybirthdate`，而 `/pAGREETOEULA=1` / `JOINKSN_*` 等于替用户接受协议 —— **本应用一律不用**。官方免费版下载页 `www.kaspersky.com/free-antivirus` 现重定向到区域站并主推 30 天试用，第三方论坛给的 `21.24.8.522` 直链实测 **404**；卡巴官方论坛与 beta 社区给出的 `dm.s.kaspersky-labs.com/<locale>/Kaspersky4Win/<版本>/startup.exe` 格式实测 `21.26.4.406` / `21.27.6.532` 均 200。因此做候选版本 HEAD 探测 + 全失效降级官方页，不写死单一 URL。

**落地**：`dependency_bootstrap.py` 把 `kaspersky_free` 从 `guided` 升级为 `vendor_installer`。新增 `INSTALL_CONSENT_TOKEN` 第二道令牌、`probe_vendor_versions()` 候选探测、`verify_vendor_installer()` 通用 Authenticode 验签（刻意**不复用** `kvrt_bundle.verify()`，那个把产品名写死为 `Virus Removal Tool`，会误判完整版；只复用其底层 `winverifytrust / pe_version_info / authenticode_signer_hint / sha256_file`）、`acquire_vendor_installer()` 只下载不运行、`launch_vendor_wizard()` 只传可执行路径不带任何参数。自检报告 `policy.system_level_install` 显式声明 `needs_admin / writes_system_drivers / may_conflict_with_existing_av / may_require_reboot / requires_vendor_account`。`_check_kaspersky_full()` 改为卸载注册表项 + 安装目录双证据（纯 Python winreg，不依赖被沙箱拦过的 sc/reg/PowerShell），并排除 KVRT/Rescue Disk 误判。

**真跑**：`21.27.6.532` 中文区在线安装器 7,048,280 字节 / 2.9 秒，Authenticode `0x00000000`、签名者 `AO Kaspersky Lab`、产品名「卡巴斯基」、文件版本一致、SHA256 `C0C5DEC8…`，四项 checks 全 true；落 `engines/_downloads/` 且被 `.gitignore` 的 `versions/**/engines/` 挡住。六类边界全拦：无同意拒绝、有同意真下载且 `installed=false`、幂等不重下、无第二令牌拒绝、下载令牌冒充系统安装令牌被拒、非安装器组件拒绝。**实测前后本机卸载注册表项与 `avp.exe` 均为空——没有替用户装任何杀毒软件**；官方向导成功分支刻意未执行。

**基础工程盲区审计**：换用「装进 Program Files、标准用户、长期运行、开源给陌生人、能干净卸载」的视角复核，联网查 Microsoft Learn WACK / GitHub Docs 社区标准 / Python logging.handlers 等官方依据，逐条在代码里取证，共识别 **14 条**此前完全没想到的通行做法（严重 5 / 中等 6 / 轻微 3），另 4 条已知功能未完成单列不计数。最严重三条：① v0.10 全把运行态写 `ROOT/reports`、`ROOT/engines`，而 v1.00 已用 `%LOCALAPPDATA%`，策略分裂且 PyInstaller `--onefile` 程序目录是临时解压目录（WACK「Install to the correct folders test」原文禁止写 Program Files）；② 无 LICENSE 与整套开源治理文件，与用户上 GitHub 的计划直接冲突；③ exe 未签名/无 UAC manifest、卸载只删快捷方式且无注册表卸载项。文档：`E:\AI 调度中心\项目常识盲区审计_2026-11-13.md`。**本轮只完成审计，未改这 14 条的代码。**

**反思（写进结论）**：之前每轮验证视角都是「在我这个对话环境里能不能跑通」——管理员、路径可写、工具链齐全、跑一次就结束。这 14 条不是 14 个独立 bug，是同一个盲区的 14 个切面；bootstrapping 是第一个暴露点。

**验证**：`py_compile` 4 模块 PASS；`--check` 显示 7 项 6 齐 1 缺、`vendor_installer_missing=1`、`startup_ok=true`；`--list` / `--plan` 输出正确；版本失效降级实测（`21.24.8.522` 404 → 下一个可用；全部失效 → 官方页）；`run-tests.ps1 -SkipMcp` → **PASS 7 / FAIL 0**（pytest 16 passed）。

## 2026-11-13 07:20 · 修审计 S1 数据目录 + 自检接入 v1.00 主进程与前端

**用户拍板**：「先开发应用，先修 1 和 3」——14 条盲区里的 S1（运行态数据写程序目录）与清单第 ③ 项（自检挂进主进程 + 前端面板）。

**S1 数据目录（app_paths.py 新模块）**：统一数据根 `%LOCALAPPDATA%\PowerFocus\<version>`，支持 `POWERFOCUS_DATA_DIR` 覆盖（测试用）；**历史程序目录只读兼容**——`first_existing()` 先查新目录再回退旧目录，旧报告/引擎继续可用但不再写入。四模块全部改道：`kvrt_bundle`（ENGINE/STATE/REPORT/SETTINGS）、`engine_adapters`（REPORT_DIR）、`dependency_bootstrap`（engines/_offline/_downloads/审计）、v1.00 `server.py` 的 `config.json` 读写。**兼容性实测**：迁移后 KVRT（122 MB）、Node 运行时、真实扫描报告（kvrt_bundle 与 engine_adapters 双入口 list_reports）全部仍可识别；`data_root()` 默认不创建目录（首次写入才建）。

**接主进程**：`main.py` 启动即起 `warm_bootstrap` 后台线程预热自检（不拖慢窗口出现；模块不可用只记错误，`startup_ok` 恒 true 不阻塞应用）；`server.py` 实装 5 条路由：`GET /api/bootstrap/check`（5 分钟缓存）、`POST /refresh`（强制重跑，线程池）、`GET /plan`、`POST /install`（前端传 consent，服务端绝不代填，且校验 component_id 必须在清单内）、`POST /wizard`（第二道系统安装令牌 + 审计）。

**前端（真实请求，非静态快照）**：新增「组件自检」导航页——7 项组件实时渲染（就绪绿/缺失橙/**系统级红**）、summary 与数据目录展示、「同意并补齐缺失组件」「启动卡巴完整版官方安装向导」两个动作各过一道 `confirmDialog`；严格沿用项目「不 innerHTML、全 textContent」的 XSS 约束；同意令牌**从服务端响应里读**（`policy.consent_token` / `system_impact.second_consent_token`），前端不硬编码、服务端仍是唯一校验方。

**打包**：`build.ps1` 与 spec 增加 `pathex` + `--hidden-import`（dependency_bootstrap / kvrt_bundle / engine_adapters / app_paths 等）——修复「exe 只打包 app/web，v0.10 模块根本不在包里」的缺口。

**端到端真跑（HTTP 层，非 CLI）**：check 200（7 项 6 齐 1 缺，data_root=LOCALAPPDATA）；plan 200（pending=1, vendor=kaspersky_free）；install 无 consent → 拒绝；wizard 无令牌 → 拒绝；带 consent install → **幂等命中**：`app_paths.first_existing` 回退认了历史目录里已验签的官方安装器（Authenticode 0x00000000），不重复下载；静态页 200、token 注入成功、新 JS 已在服务（35,946 B，bsInstall/bsWizard 在位）。

**回归**：`run-tests.ps1 -SkipMcp` → **PASS 7 / FAIL 0**（pytest 16 passed）；`mem-guard.state.json` 运行态改动已还原不入库。

**未完成（如实）**：exe 未重打包（打包配置改了但没跑 build）；`current.json` 仍 v0.09；官方向导成功分支刻意未执行；其余 13 条盲区未修。

## 2026-11-13 08:10 · 多智能体团队协作轮（用户指令：启动团队、分角色完成应用）

**编制**：team-lead（协调/裁决/最终提交）+ release-eng（打包发布）+ oss-governance（开源治理合规）+ desktop-hardening（桌面加固）+ qa-ci（测试与 CI）。各角色只动自己的文件区域，全部不 commit，lead 统一回归后提交。

**release-eng**：真打包两次（07:21 基线 + 07:33 收编加固版，19.5 MB，增量 3.4s / 22.7s）；趟平两个环境坑（WorkBuddy 的 PYTHONPATH trash shim 拦截 os.remove 导致覆盖失败 → 打包前清空 PYTHONPATH；提权旧实例 56588 持单实例互斥锁与 dist 文件锁）；exe 级验证 frozen:true、/api/bootstrap/check 可用、manifest RT_MANIFEST 内嵌（asInvoker）、RotatingFileHandler 新路径生效；产出 docs/release-plan.md（签名两阶段：自签+TrustedPublisher 起步、对外 OV 证书；Azure 排除因个人信任路径不含中国大陆主体；MANIFEST 增补 build 字段建议）。**抓出真 bug**：exe 内 KVRT 显示 missing 与源码 6 齐 1 缺不符 → 三段链根因（frozen 下 `__file__` 在 _MEI 临时目录 → app_paths.REPO_ROOT 错位 → legacy 回退断裂），有行号、有源码/exe 对照表。

**oss-governance**：LICENSE 选 **Apache-2.0**（显式专利授权 + NOTICE 机制贴合「仓库零第三方二进制」结构）；新增根 README/CONTRIBUTING/SECURITY/CODE_OF_CONDUCT/CHANGELOG/THIRD_PARTY_NOTICES 七件；**联网核实 KVRT EULA 现行版**：5.3（禁用于创建其他检测软件）、5.4（禁与商业软件捆绑分发）——现在「用户本机经同意官方源下载」不构成分发，**未来做预装安装包立即触雷**，已在两处文档设禁；PyInstaller bootloader 例外确认不传染。

**desktop-hardening**：日志轮转 RotatingFileHandler（2MB×5）落 %LOCALAPPDATA%\PowerFocus\v1.00\logs\；UAC asInvoker manifest（正确识别 build.ps1 会重建 spec，参数必须进命令行）；卸载闭环：HKCU 卸载注册表项 + 幂等 uninstall.ps1（删数据需 -DeleteData/交互确认）；全部 Parser 零语法错误，EstimatedSize 写入干跑验证。

**qa-ci**：app_paths 12 个单测（monkeypatch/tmp_path 隔离，不碰真实用户目录）；.github/workflows/ci.yml（windows-latest + py3.13，零本机路径，复刻 run-tests 安全子集）；docs/error-codes.md 错误码提案（PF-<前缀><序号>，标注未全面落地）。

**lead 亲自修复**：release-eng 第二轮结束时修复未落地，lead 采纳其方案亲自改 app_paths.legacy_root()（frozen 下从 sys.executable 向上找 versions/v0.10 + POWERFOCUS_ROOT 覆盖；源码/写路径零变化）——**重打包后 exe 内验证恢复 6 齐 1 缺，kvrt_engine path 正确指向源码目录真实引擎**。

**回归**：pytest 33 passed（16 原 + 17 新）；run-tests.ps1 → PASS 7 / FAIL 0；mem-guard 运行态文件还原；提交 `a1a196a`（19 文件，+1414/−14）。

**留给用户的决策**：① LICENSE=Apache-2.0 如不合意可换（文本独立无依赖）；② GitHub 发布前需开 Private vulnerability reporting、替换 CHANGELOG/CoC 的 owner 占位；③ 签名路线（自签起步→OV）待定夺；④ 错误码规范仅提案未迁移。

## 2026-11-15 21:00 · v0.12.0 发版轮（用户指令：应用版本 + MCP 版本全部更新到 GitHub）

**版本判定**：按 docs/VERSION_POLICY.md 升 **MINOR → v0.12.0**（新增温度落盘 API、安全扫描 API + 2 个 MCP 工具、内核 v0.12/v0.13，均为向后兼容新增）。

**发版闭环**：① 42 个 .ps1 BOM 统一（纯编码）单列提交；② 内核 v0.11/v0.12/v0.13 三槽入库，current.json → v0.13；③ 产品端 temp_log.py + /api/temp + /api/security/scan(+status)，build.ps1 修复「打包组件错位」（写死 v0.10 → 跟随 current.json），main.py 内核拉起竞态 10s→指数退避 90s；④ MCP __version__/VERSION.json 对齐 0.12.0，默认只读工具 10→11；⑤ 本机重打 exe（19.5MB，组件目录=v0.13，SHA256 bcbf0b40…8198 记入 CHANGELOG）；⑥ 提交 9 个（编码/内核/产品/MCP/工具文档/收口/lint/版本测试/CI 自愈），tag v0.12.0 → 190fb4d。

**过程中抓出的三个真问题（均已闭环）**：
1. HOME 环境变量为空 → git 自带 ssh 读不到 ~/.ssh/config，github-443 别名解析失败；仓库级 core.sshCommand 显式指定 -F/-i 修复。
2. MCP 包 __version__ 漏改 0.11.1 → CI 门禁假红；test_version_aligned 改为不变量断言（__version__ == mcp_version == target_app_version == APP_VERSION），发版不再需要手改测试。
3. CI lint 与本地验证口径不一致（本地只扫 mcp+app，CI 还扫 tests/py、app_paths.py）——已按 CI 同口径复扫修复。

**发布流水线增强（release.yml）**：tag 删除重推时 GitHub 会把 Release 转回草稿并与 tag 脱钩——新增自愈步骤：按 tag_name 找回 Release、PATCH 关联并发布、删除错名 exe 附件（default.exe / 缺 v 前缀的旧名）；exe 统一改名 PowerFocus-vX.Y.Z-x64.exe 后上传（保留 v 前缀，首版实现误用 TrimStart 削掉 v，已修）；mcp-zip job 一并上传 LICENSE + THIRD_PARTY_NOTICES.md；CI 构建副本的 SHA256 写入 Release 说明（CI 与本机构建非同一二进制，PyInstaller 非可复现构建，CHANGELOG 分开记录）。

**最终 Release 验证（api.github.com 实查）**：tag v0.12.0 已发布（draft=false，latest=v0.12.0），附件 4 件 = PowerFocus-v0.12.0-x64.exe（CI 构建，SHA256 b48a78aa…74c82 见 Release 说明）+ PowerFocus-MCP-v0.12.0.zip（20,742 字节）+ LICENSE + THIRD_PARTY_NOTICES.md，与 v0.11.1 惯例对齐。CI 全绿（190fb4d：release.yml 两 job + ci.yml 全 success）。

**明确不入库**（.gitignore）：tools/lhm-lib（LHM 第三方库 7.6MB，用户官方源自取）、tools/ps1-bom-backup、.scan-test、pack-log*、marketing/douyin/video_hy4（59.7MB 工程）、marketing/submission（投稿草稿含本机路径）。

**遗留**：本机正在运行的 exe 仍是旧构建（改名腾位保进程，未重启）；CI exe-build 产物与本机 SHA 不同属 PyInstaller 非可复现构建，已在 Release 说明与 CHANGELOG 双向注明；`/api/health` 版本槽语义统一仍待产品决策（Unreleased 如实保留）。
