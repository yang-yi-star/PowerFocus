# 03 · CTO（陈工）：故障实证、版本治理与第一步动作边界

> 岗位：CTO / 人格代号 陈工 ｜ 取证时点：2026-11-19 晚（Asia/Shanghai）｜ 环境：Windows，pwsh 7.6.4
> 本轮性质：P0 集团级推演，只出方案不改代码。以下结论均挂文件行号、日志行或实测值；未证实处显式标"假设"。

## ① 一句话结论

现网 UI 链路（前端 → `/api/command` → `bus_call` 注入令牌 → 文件总线 → 内核）令牌闭环是通的；六类故障里真正这周值得动代码的只有**电源计划失败误诊断**和**规则动作 PID 竞态守卫**两项，其余要么是历史遗留写入方问题、要么是权限边界限制；文件总线第一步不动结构，版本目录这周只做归档与备份二进制清理。

## ② 代码实证（行号列表，均为本人亲读）

**服务端令牌注入路径（`E:\PowerFocus\product\v1.00\app\server.py`）**

- L75 `APP_VERSION = "1.00"`；L173 `TOKEN_FILE = KERNEL_DIR / ".auth_token"`（内核令牌）；L177-178 `_HTTP_TOKEN_FILE`（HTTP 令牌，另一密钥，L714 注释明确两者不等效）。
- L719-724 `_kernel_token()`：读 `TOKEN_FILE`，`OSError` 返回空串。
- L727-740 `bus_call()`：L735-736 `payload["token"] = _kernel_token()`，**每一条**命令在此统一注入；L737 交 `BUS.call`；L738-739 留审计。
- L958-997 `/api/command`：L967 剥掉客户端自带 token；L983-987 `TOKEN_ACTIONS` 注入；L988-994 `DESTRUCTIVE_ACTIONS` 注入；L996 普通 action 由 `bus_call` 兜底注入。
- L1304-1331 `_py_component_dir()`：优先 `KERNEL_DIR`，扫版本目录取最大号，L1331 兜底 `v0.10`。

**总线客户端（`E:\PowerFocus\product\v1.00\app\bus.py`）**

- L19 `_POLL_INTERVAL = 0.2`（服务端回执轮询，**不是**内核轮询）；L33-36 命令名 `ui-<时间戳>-<序号>-<随机>`；L60-61 注释自承：幂等 id 已下发，当前内核忽略；L63-71 原子写 `in/`；L76-95 等回执；L99 超时撤回；L20/38-47 回执 GC 600s。

**内核 v0.13（`E:\PowerFocus\versions\v0.13\电脑算力调度中心_v0.13.ps1`）**

- L132 `$script:LogDir = $PSScriptRoot`；L140 令牌文件落本版本目录；与服务端 `KERNEL_DIR` 指向同一处（`resolve_kernel` L132-149 选最新 stable，MANIFEST 实测 v0.13 为 stable）。
- 分发表：L1639 `Invoke-CommandObject`；L1641 `$action = [string]$Cmd.action`；L1644 `switch ($action)`；L2208-2210 `default → "ERROR: 未知 action: $action"`。
- 全局鉴权闸门：L2255-2257 `$expected = Get-AuthToken; if (-not $expected -or [string]$cmdObj.token -ne $expected) { 认证失败 }`。
- 动作内令牌校验：authorize L1697-1701、revoke L1710-1712、kill L1747-1749、suspend L1764、resume L1776、压制 L1790。
- **"每 2 秒轮询"出处已证实**：L2319-2323 `Start-CommandBus`，L2320 `$script:CmdTimerObj.Interval = 2000`，L2323 日志"命令总线已启动: 每 2 秒轮询"；v3.log L66/L187/L420 同文印证。
- 电源计划：L1151-1170 `Set-PowerPlanHigh`；L1164 `powercfg /setactive $HighPerfGuid`；L1167 失败文案"本机可能不存在高性能电源计划"；L163 高性能 GUID `8c5e7fda-…`；L1870-1883 `set_power_plan` 分支，L1874/1881 有拒绝访问匹配。
- I/O 优先级：L730-738 `Set-IoPriority`（NtSetInformationProcess 0x21），失败返回 `$false`；L1272 降级 WARN。
- 目标解析：L1540-1553 `Resolve-TargetFromCommand`，pid 优先、进程名首个匹配，不中返回 `$null`。

**规则引擎（`E:\PowerFocus\versions\v0.13\rules-engine.ps1`）**

- focus L145-146、demote L153-154 有 `Get-Process` 存活预检；**ecoqos L161-163 没有**；trim L170、affinity L166 同样未预检。`Set-EcoQos` L194 `-ErrorAction Stop`，PID 退出即抛异常，L203 记 WARN。

**MemGuard（`E:\PowerFocus\versions\v0.13\lib\mem-guard.ps1`）**

- 参数 L16-30：`IntervalMs=1000`、`TrimIntervalMs=5000`、`WarnPercent=75`、`CriticalPercent=90`、提交额度 88/93。
- 触发条件：L227 `if ($modelRunning)`；L228-230 物理/提交取更严重一档；L231 `if ($level -ne 'normal')` 才修剪；L215-222 模型/前台提优先级（`raised` 计数）；L295 累计 `freedMB`；L367-368 有修剪或提权才写日志；L306-319 无模型时绝不修剪。

## ③ 故障根因与优先级表

| # | 故障（日志行） | 真根因（证据） | 影响面 | 值不值 | 预估工时 | 优先级 |
|---|---|---|---|---|---|---|
| F4 | 电源计划切换 exit=1（v3.log L177-178、L192-193、L199-204） | 两计划枚举均在（L196-197/L203-204），**"计划缺失"诊断不成立**；`setactive` 返回 1。可证实：L1167 失败文案未带 `LastNativeOutput`，误判为 OEM 精简；未证实：exit=1 是提权不足还是策略锁定（**假设**：当时内核未提权，历史提权状态无记录）。规则引擎 L179/181 不查 exit code | focus 切高性能、restore 切平衡两路失效；CPU/IO 倾斜仍生效 | 中：现状误诊断会把排障带偏 | 2-3h | **P1** |
| F5 | EcoQoS PID 竞态（v3.log L36/56/87/119/150，5 次） | rules-engine L161-163 缺 focus/demote 那样的存活预检；快照取 PID 后、动作执行前进程已退出，L194 抛异常落 WARN | 5 条噪音日志，无破坏后果；释放路径同类可能失败 | 中低：纯防御性 guard，风险极低 | 1h | **P1** |
| F2 | 文件名带空格 → 未知 action（v3.log L328/330） | 实测 done 文件 `prio_37608_s1b set_priority BelowNormal.json`：`action:null, priority:null`，参数被塞进文件名；内核 L1641 取空 action → L2209。**内核无 bug**，是旧写入方序列化缺陷；令牌其实带了 | 2 条；现网 bus.py L64-71 全量序列化、文件名 `ui-*` 无空格，不复现 | 低：只需把空 action 报错写明确 | 0.5-1h | P2 |
| F1 | 总线认证失败（v3.log L422-423） | 实测 `setprio_s3_46316.json`（64B）**无 token 键**；同 PID 成功件 `p_s3_46316.json`（107B）带 `token:"e776…"`。闸门 L2256 拒绝正确。前缀 `setprio_` 在现网 .py/.ps1/.js 中 Grep 0 命中 → 生成方为已下线旧脚本/旧前端或手动探针（**生成方身份未证实**） | 历史 2 条；现网 UI 路径经 L736 注入，不受影响 | 低-中：现网已闭环，补残留扫描与文案即可 | 1-2h | P2 |
| F3 | I/O 优先级权限不足（v3.log L175） | L730-738 调原生接口失败返回 `$false`；同日志后续 set_io_priority 多次成功（L321/L323/L428/L433）→ 非代码恒失败，系当时目标进程受保护/更高完整性级别（**假设**：或当时未提权） | 单条 WARN；降级保留 CPU 倾斜，不崩 | 低：登记为已知限制，不动代码 | 0（登记债务） | P3 |
| F6 | 找不到目标进程（v3.log L411/413） | L1540-1553 解析不中返回 `$null`；命令落盘到 2s 后轮询执行，期间目标退出，与 F5 同类竞态 | 2 条，瞬时，重试即可 | 低：文案细化即可，第一步不做自动重试 | 0.5h | P3 |

## ④ 版本号治理主张

**实测事实**：versions 下 9 份内核目录，体积 0.2/0.2/0.2/0.3/0.4/**394.6**/0.6/0.5/0.5 MB；MANIFEST stage：v0.05-09 stable、v0.10 dev、v0.11/12/13 stable。Python 模块哈希本人复测：v0.11/12/13 三版相同（`875704E65C`/`1370C295BE`/`A968DE0D68`），v0.10 全不同（`B4837D2597`/`12CA6A143E`/`B1DC372002`）——与底账 §2.5 一致，与"四版同构"说法不符（D2）。三套版本号并存：应用 1.00（server.py L75）、内核 v0.13（current.json）、安装包/tag v0.12.0；本地 git tag 实测 6 个：v0.10.0/0.10.1/0.10.2/0.11.0/0.11.1/0.12.0。v0.10 的 394.6MB 构成为 KVRT.exe 116.8 + `.bak` 116.8、node.exe 95.5、node.zip 39.3、Kaspersky 安装包 2×6.7；v0.13 无 `engines/` 目录，bootstrap（dependency_bootstrap.py L20/162）把引擎写到当前内核版本目录。工作区漂移：`git diff --stat` 实测 mem-guard.ps1 41 行、内核 ps1 30 行，59 insertions/12 deletions，**运行内核 ≠ git HEAD**。

**主张**：

1. **保留**：v0.13（运行态）+ v0.12（lineage 上一版，MANIFEST L9）冷留存。
2. **归档**：v0.05–v0.09、v0.11 源码移入 `archive/`（合计约 1.3MB）；v0.10 拆分——源码归档，`engines/` 内 `.bak` KVRT 与 node.zip 先移暂存目录观察 3 天再物理删（可由 bootstrap 重下）。已核 `lib/rollback.ps1` 不引用兄弟版本目录；唯一兜底引用是 server.py L1331，归档前先核对。
3. **模块去重**：v0.11/12/13 相同的三个 Python 模块抽共享 runtime，**第二步做**，第一步只登记债务。
4. **版本号统一**：这周只做映射登记、停止给安装包打与内核不一致的 tag；正式改号（1.00 ↔ v0.13 ↔ semver）下周做，需发布流程配套。

**成本/风险**：归档搬迁 1-2h，引擎清理 1h（含下载链路探针验证）；风险是离线环境备份二进制不可恢复，故先暂存后删除。**这周做归档与备份清理，下周做模块去重与版本号体系。**

## ⑤ 总线架构判断

文件总线现状（bus.py + 内核 tick）：无确认（写完靠轮询 `result.txt`，L79-95）、无事务（崩溃留孤儿，GC 600s）、无背压（L2216 `BusyProcessing` 只防内核重入，多写入方可堆积 `in/`）、参数历史上文件名/JSON 混用（F2 实证）。

**结论：第一步不动总线结构。** 依据：① 现网 health 200、心跳 15s 内（server.py L752-758）、回执闭环在跑；② 内核侧无集成测试，无测试基础上换传输层属于我经历过的"无测试重构崩盘"；③ 一人维护，文件总线可直接看 `in/done` 排障，换管道只会增加排障面。

**不动要付的风险利息**：孤儿命令与重复执行靠幂等 id（L65 已预留，内核当前忽略）；命令堆积时 2s tick 串行处理；排查依赖文件时间线。第二步预留：命令 JSON 加可选字段（不写实现），侧车 `result.json` 方向认可；传输层是否换，等第二步需求与测试就位再议。

## ⑥ 第一步技术动作清单（5 项）

| # | 目标 | 文件（绝对路径） | 工时 | 验收命令/标准 | 回滚方式 | 是否影响运行服务 |
|---|---|---|---|---|---|---|
| 1 | F4 失败可诊断化 + 提权自检：L1167 文案带 `LastNativeOutput` 与 exit code；启动处检测提权并暴露 | `E:\PowerFocus\versions\v0.13\电脑算力调度中心_v0.13.ps1`（L1151-1170 及启动段）；必要时 `E:\PowerFocus\product\v1.00\app\server.py` health 旁证 | 2-3h | 非提权触发 `set_power_plan`，回执含原生输出与"需管理员"提示；WARN 带 exit code | 改前备份 `.bak-cto-20261119`，覆盖还原 | 需重启内核；改服务端需重启 pythonw |
| 2 | F5 规则动作存活预检对齐（ecoqos/trim/affinity） | `E:\PowerFocus\versions\v0.13\rules-engine.ps1`（L161-167 前补 `Get-Process` 守卫，对齐 L145-146） | 1h | 对已退出 PID 触发 ecoqos 记跳过而非异常 WARN；现网规则一轮无新 ERROR | 备份覆盖还原 | 需重启内核加载 |
| 3 | F2/F1 回执文案细化：空 action 与"缺 token 键"/"token 不匹配"可区分 | 内核 ps1 L2208-2210、L2256 | 0.5-1h | 三个探针文件（无 action / 无 token / 错 token）入 `in/`，回执分别可辨 | 备份覆盖还原 | 需重启内核 |
| 4 | 旧写入方残留排查 + `in/` 启动扫描告警（只读扫描，不自动删） | 内核 ps1 启动段；服务端不改 | 1-2h | 启动日志列出 `in/` 残留；排查无活进程持旧前缀写入 | 备份覆盖还原 | 低 |
| 5 | 版本目录归档 + v0.10 备份二进制移暂存（不碰 v0.13 运行态） | 目录搬迁；归档前核对 server.py L1331 兜底 | 2-3h | 归档后 `/api/health` 仍 200、`kernel_alive=true`；bootstrap 下载探针跑通 | 暂存目录搬回原位 | 不影响运行服务（内核已加载内存，路径解析在启动时） |

## ⑦ 我与董事长范围的分歧

**"五类短板全修 + 热感知调度 + 做减法 + 后续扩展"一周内：我判定不现实。**

- **热感知调度这周不能做**：温度口径未裁定（底账 D3：ACPI 热区 73.1/72.1℃ vs 核心 94-95℃，采样点与时点未对齐）。数据源没定就写调度规则，是建在沙地上。
- **五类短板全修不成立**：F1/F2 是历史遗留写入方问题，现网路径已闭环；F3 是权限边界，代码侧无解。这周真正动代码的是 F4、F5 加两项文案细化，其余登记债务。
- **做减法**这周只做归档与备份二进制清理；模块去重、版本号体系重构下周。
- **后续扩展**：这周只预留字段，不写实现。

**一周版范围**即上表 5 项；热感知调度推迟到温度口径裁定与数据源验证之后；总线重构推到第二步。

## ⑧ 对其他岗位的质疑

1. **对架构师沈工**：侧车 `result.json` 第一步"只写不读"——两步之间旧内核读到新字段怎么办？`idempotency_id` 已下发但内核忽略（bus.py L60-61 自承），去重机制第二步在哪一侧实现、由谁保证兼容？请出字段兼容矩阵。
2. **对数据分析师老钱**：D3 温度冲突你负责裁定，但 ACPI 热区与核心 DTS 是两个采样点，光比数值不够；热感知落地前需给出"哪个传感器、采样频率、阈值多少"的可验证基线。另：mem-guard.log L19 的 `357.09999999999997` 是 L295 浮点累计未格式化的显示问题，**不是内存测量偏差**，台账别记成数据错误。
3. **对产品/前端岗**：app.js 仅走 `/api/command`（app.js L388、L935），历史遗留文件名前缀在现网前端找不到来源——请确认是否还有本地辅助脚本或旧版 UI 在直接写 `commands/in/`，否则 F1/F2 无法闭环定性。

## ⑨ 我可能错在哪

1. **F4 根因分层**：我只证实到"计划存在、`setactive` 返回 1"，提权不足是假设。若实机复现是 OEM 电源策略锁定或 GUID 别名问题，我的自检文案方案不够，需要换组策略/别名方向——复现前不把它当定论。
2. **归档安全性**：我假设 v0.10 的 KVRT/node 可由 bootstrap 按需重下；若 `KVRT_URL` 已失效或离线包仅存本机，物理删除备份会导致离线环境无法恢复。删之前必须先跑下载探针验证，未验证前只移暂存。
