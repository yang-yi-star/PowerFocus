# 11 · DevOps 运维评审（PowerFocus 第一步推演）

> 岗位：DevOps 工程师（黑塔智能集团软件公司）｜ 日期：2026-11-19 ｜ 性质：**P0 集团级推演，只出方案不改代码**
> 取证基准：共享底稿 `_evidence\现场事实底账.md`（下称"底账 §"）；标注"本轮实测"的条目为本人用只读命令复核，命令见各节。
> 本轮纪律：未修改/删除任何 `.ps1/.py/.exe/.json`，未 kill 进程，未写 versions 与 product。

---

## ① 一句话结论

**当前不具备"一键回到今天这个状态"的能力：工作区有 59 行未提交改动且无任何文件级快照，git 只能退回 HEAD（会丢掉这 59 行）；第一步若要落地，必须先补快照、补一次回滚演练，内核级改动短停 5–15 秒、后端/打包级改动中断 30–60 秒。**

运维立场：**🔄 有条件支持**。条件见 ⑤ SOP 前置项；快照与回滚演练未完成前，不允许动 versions/product 下任何文件。

---

## ② 回滚能力评估：**不能**一键回到今日状态

### 2.1 逐项核查（本轮只读实测）

| 核查项 | 实测结果 | 证据/命令 | 判定 |
|---|---|---|---|
| git 可否回滚 | HEAD = `bdfc68b`；`git status` 显示 2 个已跟踪文件 modified：`versions/v0.13/lib/mem-guard.ps1`（41 行）、`versions/v0.13/电脑算力调度中心_v0.13.ps1`（30 行），合计 59 insertions / 12 deletions（与底账 §0 一致）；`git stash list` **为空**；reflog 仅历史提交，当前工作态**无 commit、无 tag、无 stash** | `git status --short` / `git diff --stat` / `git stash list` / `git reflog -5` | **部分可回滚**：`git checkout HEAD -- <file>` 能退回 HEAD，但会**丢弃这 59 行未提交改动**，不是回到今天状态 |
| 运行内核文件与 HEAD 是否一致 | **不一致**。运行中内核 pwsh（PID 25560）命令行指向 `versions\v0.13\电脑算力调度中心_v0.13.ps1`；进程启动 19:58:31，晚于两个文件 mtime（内核 11-16 04:10:42、mem-guard 11-16 11:47:21），即进程加载的是当前工作区（已改动）副本；而该副本 ≠ HEAD | `Get-CimInstance Win32_Process` + `Get-Item` 时间戳 + `git diff` | **运行态 = 工作区改动态，≠ HEAD，且改动态无快照** |
| exe 备份是否可用 | dist 下 5 个 `.bak` exe 哈希两两不同（本轮 SHA256 前 12 位实测），均为 11-14/11-15 旧构建；exe 壳与内核 `.ps1` 是解耦两层，**exe 备份保护不了内核脚本改动** | 见 ③ 哈希表 | 只能回滚壳层，覆盖不了本轮风险面 |
| commands\in 是否有残留 | **in 目录为空**，无在途命令；`done` 200 个历史回执共 16.3 KB（陈旧归档，不阻塞）；`out\status.json` 1,282 B，停在 11-16 21:11 | 列目录实测 | 总线无在途残留，回滚时无需排空 |
| MemGuard/规则状态文件是否一致 | `mem-guard.state.json` 427 B（21:50:43 实时刷新）、`rules_state.json` 110 B（21:50:42 实时）、`.v3.lock` 0 B 被运行进程独占（读取被拒）。三者均被 `.gitignore` 忽略，属运行态再生文件 | 列目录 + `Get-Content` 实测 | 状态文件**不需要也不应当手工回滚**；重启后由内核/MemGuard 再生，但回滚 SOP 中须禁止手改 |
| 现有回滚脚本 | `lib\rollback.ps1` 只保存/还原 **llama-server 的优先级与电源计划**；Restore 默认 dry-run，`-Apply` 才生效；脚本自述"永不重启进程" | 通读 rollback.ps1 L36–123 | **这不是代码/文件回滚工具**，不能承担第一步回滚 |
| 密钥 | `.auth_token` 34 B（11-15 06:29:06）；`http.token` 32 B 在 `%LOCALAPPDATA%\PowerFocus\`（11-14 10:23:45）；两个不同密钥（底账 §2.2 L173/L177-178） | 实测存在性 | 快照只记录"存在 + 路径 + 长度"，**不复制密钥内容** |

### 2.2 结论：不能一键回滚，缺四样东西

1. **文件级快照**：两个改动中的 `.ps1`、`current.json`、`MANIFEST.json`、本轮将触碰的 `app\*.py`，在变更前没有带哈希留档的副本；现存 `mem-guard.ps1.bak-commitwatch-20261116`（16,512 B）早于当前文件（18,824 B），是 11-15 旧备份，**不是今日状态**。
2. **VCS 锚点**：当前 59 行改动未提交、未打标签，无法用分支/tag 指回。
3. **回滚演练记录**：按 DevOps 纪律，回滚步骤必须在非生产实跑并计时；当前没有任何演练记录。
4. **现场台账**：运行进程命令行、PID、端口、探针基线 JSON 未在变更前固化，回滚重启时无对照基准。

> 二级退路（代价明确）：文件快照全失时，可 `git checkout HEAD -- <file>` 退回提交态，**代价是永久丢失 59 行未提交改动**；壳层可用保留的上一版 `.bak` exe 替换重启。

---

## ③ 备份保留与清理策略（含释放 MB）

### 3.1 dist 实测台账（本轮哈希 + 体积，目录共 **136.65 MB / 8 文件**）

| 文件 | MB | SHA256 前 12 | 处置建议 |
|---|---|---|---|
| `电脑算力调度中心.exe` | 19.53 | BCBF0B40D622 | **必留**：install.ps1 快捷方式与运行态都指向它（PID 3272 在跑） |
| `PowerFocus-v0.12.0-x64.exe` | 19.53 | BCBF0B40D622 | **与主程序字节相同**（同哈希同时间戳）：发布命名副本。建议移入 `archive\release\` 归档，dist 内不保留重复副本；核实前不删 |
| `.bak-v012-20261115` | 19.52 | F7E28E06734C | **留 1 个**：带版本标注的上一已知良好壳层回滚目标 |
| `.bak-20261114` | 19.51 | 7DD5E1E7923E | 清理：无版本标注的过渡备份 |
| `.bak-20261115` | 19.51 | FF20C6B581AC | 清理：无版本标注的过渡备份 |
| `.bak-20261115-0649` | 19.52 | 3F888D178C7C | 清理：时间戳中间态 |
| `.bak-run-203331` | 19.53 | C525CFEECAE9 | 清理：运行态临时转存 |
| `PowerFocus-MCP-v0.11.1.zip` | 0.02 | 8DA64B985FEF | 保留：MCP 分发物，体积极小；若 MCP 已不随包再议 |

### 3.2 释放量算账

- **第一步可安全清理**：4 个无标注 `.bak` = 19.51 + 19.51 + 19.52 + 19.53 = **78.07 MB**（5 个 bak 合计 97.58 MB，保留 1 个 19.52 MB）。
- **第二步去重**：命名副本 exe 移入归档后，dist 目录再减 **19.53 MB**（磁盘不释放，仅目录减负）。
- **待稳定后再议**（不在本轮执行）：`dist-v3\电脑算力调度中心-v0.10.0-旧皮肤备份.exe` 19.49 MB、`out\rebuild-20261112\dist\电脑算力调度中心.exe` 19.41 MB，合计 **38.90 MB**；当前 release 连续观察无回滚后再归档或清除。
- 命名规则（今后）：`PowerFocus-<app版本>-x64.exe` 为发布物；本地过渡备份一律 `*.bak-<yyyyMMdd>-<构建标识>`，只保留最近 1 个已知良好版本；禁止在 dist 堆积无名时间戳副本。
- 另：`app\main.py.bak-20261114`（9,984 B）与 3 个 `MANIFEST.json.bak-*` 体量可忽略，随源码备份策略统一收口，不单独处理。

---

## ④ 运行面治理最小方案（不做过度设计）

### 4.1 现场基线（本轮采样；底账 §1 口径并列）

| 进程 | PID | WS（本轮） | 归属判定（命令行实测） |
|---|---|---|---|
| 电脑算力调度中心.exe（主壳，18080 监听） | 3272 | 75.3 MB | PowerFocus |
| 同名残壳 | 6972 | 1.9 MB | PowerFocus |
| pythonw.exe | 3580 | 2.7 MB | **命令行为 `D:\DSH共享\speech-to-text\sensevoice\server.py`，不属 PowerFocus**（与底账 §1 归属不一致，列入 §⑧ 质疑） |
| pwsh 内核 | 25560 | 67.1 MB | PowerFocus 内核，命令行指向 v0.13 主脚本 |
| pwsh MemGuard | 27596 | 179.2 MB | 命令行 `mem-guard.ps1 -IntervalMs 1000 -CacheMs 5000` |
| pwsh | 38812 | 106.3 MB | 本轮 CIM 快照未复现，归属存疑，见 §⑨ |

MemGuard 证据（底账 §3 + 本轮复核日志首行）：`mem-guard.log` L1 `interval=1000ms warn=75% critical=90% trimEvery=5000ms`（1 秒轮询、5 秒修剪）；L18 实测回收 852.6 MB；L19 出现浮点未格式化 `357.09999999999997MB`；L21–29 低水位段 `trimmed=0 freed=0 raised=1` 空转。日志体积：v3.log 40.9 KB、mem-guard.log 17.5 KB、v3-lifecycle.log 1.0 KB（本轮实测）。

### 4.2 最小方案（三件事，不上监控平台/不引中间件）

1. **日志轮转**：v3.log / mem-guard.log / lifecycle.log 按"单文件超 500 KB 或跨天"切割为 `<名>.yyyyMMdd-N.log`，只留最近 7 份；router 类日志同规则。当前总量不足 60 KB，**本轮只定规则不写框架**；落地优先复用内核既有写日志函数加截断，不新增后台服务。
2. **状态文件**：`mem-guard.state.json`、`rules_state.json`、`.v3.lock` 维持运行态再生、gitignore 忽略现状；约定**只读取不手改**，重启即再生。`commands\done` 200 个回执仅 16.3 KB，暂不清；超 500 个或 1 MB 时按月归档。
3. **进程守护**：exe 主壳拉起内核 pwsh 与 MemGuard pwsh。最小守护 = 探针巡检：`kernel_alive=false` 或超时连续 3 次 → 先记现场日志，再按 ⑤ 重启对应 pwsh；**不自动重启 exe 壳**，壳层异常人工介入。MemGuard 空转与浮点打印属代码质量问题，交开发排期。

---

## ⑤ 第一步部署 / 回滚 SOP（步骤级，可照此执行）

> 适用范围：第一步对 `versions\v0.13` 内核脚本或 `product\v1.00\app` 后端的变更。本轮只出 SOP，所有写动作在下一轮授权后执行。
> 基线探针（本轮实测）：`Invoke-WebRequest http://127.0.0.1:18080/api/health -UseBasicParsing` → HTTP 200，body：
> `{"app":"ok","name":"电脑算力调度中心","version":"1.00","kernel_version":"v0.13","kernel_alive":true,"ready":true,"frozen":true,"port":18080}`

### 阶段 A · 变更前快照（预计 10 分钟，不改 versions/product 内容）

1. **采基线**
   - 命令：`git -C 'E:\PowerFocus' status --short`；`git -C 'E:\PowerFocus' diff --stat`；`Get-Process` 进程清单；健康探针连打 3 次；`Get-PSDrive E` 记磁盘余量。
   - 校验点：探针 3 次均 200，`kernel_alive=true / ready=true`；基线 JSON、PID、命令行、哈希写入快照台账。
   - 失败分支：探针已异常 → **停止第一步**，先排障，不在故障基线上叠加变更。

2. **建快照目录并复制待改文件**
   - 命令：
     ```powershell
     $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
     $snap = "E:\PowerFocus\docs\plan-2026-11-19\snapshot-$ts"
     New-Item -ItemType Directory -Path $snap -Force
     Copy-Item 'E:\PowerFocus\versions\v0.13\电脑算力调度中心_v0.13.ps1' $snap\
     Copy-Item 'E:\PowerFocus\versions\v0.13\lib\mem-guard.ps1' $snap\
     Copy-Item 'E:\PowerFocus\versions\current.json' $snap\
     Copy-Item 'E:\PowerFocus\product\v1.00\MANIFEST.json' $snap\
     # 若本轮改 app 层，再复制对应 server.py / main.py / security.py 等
     ```
   - 校验点：`Get-FileHash` 逐文件比对快照副本与源文件一致；台账记录 `.auth_token`、`http.token` 的存在性/路径/长度，**不复制密钥**。
   - 失败分支：哈希不一致 → 重新复制；目录不可写 → 换 `archive\pre-step1-$ts\`，仍不可写则停止变更。

3. **VCS 锚点（需授权）**：将当前 59 行改动提交为 WIP 提交或打轻量标签 `pre-step1-<日期>`，使今日状态在 git 中可指回。
   - 校验点：`git status` 中两文件不再处于未提交改动，标签可 `git show` 命中。
   - 失败分支：暂不具备提交条件 → 至少把 ② 中快照目录路径与哈希登记到发布记录，二级退路见 2.2。

### 阶段 B · 变更执行（停服窗口内）

4. **冻结操作**：确认前端无人正在操作；记录变更前最后一次探针结果。
5. **按粒度停进程**（覆盖占用文件前必须停；`.v3.lock` 实测被独占即证据）：
   - 仅内核 `.ps1` 变更：停内核 pwsh（PID 25560）与 MemGuard pwsh（PID 27596），由主壳重新拉起；
   - `app\*.py` 或壳变更：退出 exe 主壳（3272）与残壳（6972）。
   - 校验点：目标进程已退出；对应文件句柄释放。
   - 失败分支：进程退不掉 → 不强行覆盖文件，转人工排查占用，禁止改文件后强杀。
6. **落改动文件**，先做静态校验：PowerShell 脚本用 `pwsh -NoProfile -File <脚本>` 做解析加载检查；Python 文件用 `python -m py_compile <file>`。
   - 校验点：无解析错误、无语法报错。
   - 失败分支：编译/解析失败 → 直接进入阶段 D 回滚，不在现场调试。

### 阶段 C · 变更后校验（观察 10–30 分钟）

7. **重启对应进程**，内核命令行基准（取自本轮 CIM 台账）：
   - 内核：`C:\Tools\PowerShell7\pwsh.EXE -NoProfile -ExecutionPolicy Bypass -File E:\PowerFocus\versions\v0.13\电脑算力调度中心_v0.13.ps1`
   - MemGuard：`pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ...\lib\mem-guard.ps1 -IntervalMs 1000 -CacheMs 5000`
8. **探针校验**：等待 5–10 秒后打 `/api/health`。
   - 合格判据：HTTP 200；`app=ok`、`kernel_alive=true`、`ready=true`、`frozen=true`、`port=18080`、`version=1.00`、`kernel_version=v0.13`；连续 3 次探针稳定。
9. **业务冒烟**：`/api/processes` 返回非空进程表；MemGuard 日志出现新启动行；观察期内 v3.log / mem-guard.log 无新增 ERROR。
   - 失败分支：任一条不满足 → 阶段 D。

### 阶段 D · 失败回滚（目标 5 分钟内）

10. **触发条件**：探针非 200 / 超时 / `kernel_alive=false` / `ready=false` / 核心接口 5xx / 冒烟无数据。
11. **留现场**：先复制故障时点的 v3.log、mem-guard.log、state.json 到快照目录 `incident-$ts\`，再动手回滚。
12. **文件级回滚**：用阶段 A 快照覆盖被改文件（先停对应进程，同步骤 5 粒度）；命令示例：
    ```powershell
    Copy-Item "$snap\电脑算力调度中心_v0.13.ps1" 'E:\PowerFocus\versions\v0.13\' -Force
    Copy-Item "$snap\mem-guard.ps1" 'E:\PowerFocus\versions\v0.13\lib\' -Force
    ```
13. **重启并确认恢复**：按步骤 7 拉起进程；探针须回到步骤 8 全部判据；`/api/processes` 非空；进程命令行与台账一致；mem-guard.log 出现新启动行。
14. **二级回滚**：文件快照失效时，`git -C 'E:\PowerFocus' checkout HEAD -- <被改文件>` 退回提交态（**代价：丢失 59 行未提交改动**）；壳层故障用 ③ 保留的 `.bak-v012-20261115` 替换 `dist\电脑算力调度中心.exe` 后重启 exe。
15. **回滚后动作**：冻结后续变更，保留现场与日志，复盘记录故障时点、触发条件、回滚耗时。

---

## ⑥ 版本号治理的运维视角

### 6.1 三套版本号并存（本轮 + 底账 §2.3 实测）

| 来源 | 取值 |
|---|---|
| `/api/health` | `version=1.00`、`kernel_version=v0.13` |
| `versions\current.json` | `version=v0.13`，updated 2026-11-15 06:28:24 |
| dist 安装包文件名 | `PowerFocus-v0.12.0-x64.exe` |
| git tag | 末位 v0.12.0（v0.10.0 → v0.12.0） |
| `MANIFEST.json` | `version=1.00`、`kernel_version=v0.13`，但 `kernel_dir` 仍写 `v0.09`、`kernel_required>=v0.13`（内部自相矛盾） |

### 6.2 对运维意味着什么

- **装的是哪一版说不清**：快捷方式拉起 dist exe（文件名 v0.12.0，哈希 BCBF…），后端报 1.00、内核跑 v0.13，无法凭单一字段判断现场版本。
- **升级判断无依据**：没有字段同时携带 app 版本 + 内核版本 + 构建哈希，排障只能靠探针 + 文件哈希人工比对。
- **回滚目标难选**：壳看 dist 哈希、内核看 versions 目录与 current.json 指针，两条线无统一清单；MANIFEST `kernel_dir=v0.09` 还可能误导定位。

### 6.3 建议与代价

- **单一真相源**：以发布 MANIFEST 为准，一份清单同时记 `app_version / kernel_version / build_hash / build_date`；exe 文件名跟随 app 版本；`current.json` 由安装/切换流程写入，不再手工维护。
- **git tag 与发布物对齐**：每次发版打对应 tag，dist 保留物哈希记入发布记录。
- **代价**：一次版本号统一清理（build 脚本、install.ps1、MANIFEST、health 输出、文档）约 1–2 人日；存量已装机器在重新打包前，版本号不一致仍会存在，只能靠探针 + 哈希核对。

---

## ⑦ 成本、停机时间与风险

| 事项 | 工作量 | 停机/中断 | 是否必须停机 |
|---|---|---|---|
| 快照脚本 + 回滚 SOP + 一次实跑演练计时 | 1–1.5 人日 | 演练在非生产态，不影响常驻服务 | 否（演练除外） |
| dist 清理与归档复核（78.07 MB  immediate） | 0.5 人日 | 替换/删除 exe 文件时需退出对应 exe 壳 | 删 exe 备份本身不停服务；替换运行 exe 需停壳 |
| 日志轮转最小落地 | 0.5–1 人日 | 无中断（随下次进程重启生效） | 否 |
| 版本号统一 | 1–2 人日 | 重打包发布时短停 | 重新打包出 exe 需停壳 |

**停机口径（实测架构：18080 由 exe 主壳 PID 3272 持有）**：
- 仅内核 `.ps1` 变更：HTTP 面不中断；内核 pwsh / MemGuard 重启窗口约 **5–15 秒**，期间探针可能 `kernel_alive=false`，内核类命令不可用。
- 后端 `app\*.py` 变更或壳重打包：WebView2 窗口与 18080 **同时中断**，预计 **30–60 秒**（含进程退出、拉起、探针恢复）；具体时长取决于 server.py 是否内嵌，见 §⑧ 待确认项。

**主要风险**：
1. 59 行未提交改动无快照，误覆盖即永久丢失 —— 缓解：阶段 A 快照 + VCS 锚点先行。
2. 文件占用致覆盖失败或被迫强杀 —— 缓解：按步骤 5 粒度停进程，句柄释放后再写。
3. 状态文件/总线残留干扰判断 —— 缓解：状态文件只读不改，done 回执不阻塞。
4. 温度/内存口径冲突（底账 §1 D3、§5）不在运维结论内，登记待复核。

---

## ⑧ 对其他岗位的质疑

1. **致 CTO / 后端**：`app\server.py` 到底是被 PyInstaller 内嵌进 exe，还是运行时从 `product\v1.00\app\` 外部加载？这直接决定改一个 `.py` 是替换目录文件即生效（内核级短停）还是必须重新打包 exe（壳级 30–60 秒中断）。运维侧未读 `build\build.ps1`，请明确加载方式。
2. **致开发 / 内核负责人**：当前 59 行未提交改动（mem-guard.ps1 41 行 + 主脚本 30 行）的业务意图是什么、是否在别处留有说明？仅靠文件复制快照，无法支撑后续评审与回溯；请确认这些改动是否应当先提交 WIP 锚点再进入第一步。
3. **致数据分析师**：底账 §1 将 PID 3580 pythonw 计入 PowerFocus 常驻，本轮命令行实测为 `D:\DSH共享\speech-to-text\sensevoice\server.py`，归属需复核；另底账 §3 记载的 `logs\router.log`（5,567 B）与 `router.err.log`（717 B）本轮在 `versions\v0.13` 递归检索未命中，请确认去向。
4. **致 PM / 产品**：对外承诺与用户可见的版本号以哪个为准——安装包名 v0.12.0、界面/后端 1.00、内核 v0.13？升级提示与排障口径需要单一答案。

---

## ⑨ 我可能错在哪

1. **后端内嵌判断未实证**：我据"18080 由 exe 主壳监听"推断 FastAPI 被内嵌进 exe，但未通读 `build\build.ps1` 与 PyInstaller 配置确认 `app\server.py` 是内嵌副本还是外部加载。若实为外部加载，app 层改动无需重打包，回滚粒度更轻、停机更短，§⑤ 阶段 B 与 §⑦ 停机口径需相应下调。
2. **进程归属基于单次快照**：PID 38812（106.3 MB pwsh）本轮 CIM 未复现；MemGuard 进程 WS 179.2 MB 是否正常、低水位空转（L21–29 `trimmed=0`）是否推高常驻内存，未读修剪算法实现（底账 §7.4 未覆盖），本报告不对 MemGuard 内存健康下结论，仅登记现象待复核。

---

## ⑩ 追加核实（应 QA 质询，2026-11-19）

> 质询来源：`posts\10-QA.md` §2.1/§3/§⑧-1。指控要点："内存守护对模型/前台的真实保护当前不可用（脚本路径错位到不存在的 `E:\PowerFocus\lib\mem-guard.ps1`）"。本轮仍只读：未改代码、未 kill 进程。取证时点 2026-11-19 22:06（CST）。

### 10.1 核实项与实测命令、原始输出

**核实项 1：`E:\PowerFocus\lib\mem-guard.ps1` 是否不存在**

命令：`Test-Path -LiteralPath 'E:\PowerFocus\lib\mem-guard.ps1'`；并列目录 `E:\PowerFocus\lib`。

原始输出：
- `Test-Path` → **False**。
- `E:\PowerFocus\lib\` 目录存在，仅含 `app-purger.ps1`（12,383 B）、`clean-recyclebin.ps1`（2,542 B）、`geek-bridge.ps1`（4,514 B），**无 mem-guard.ps1**。

**核实项 2：当前真正在跑的 MemGuard 是哪个文件**

命令：`Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'"` 取全文命令行；`Get-FileHash` 比对磁盘脚本。

原始输出（运行中 MemGuard 进程）：
- **PID 27596**，启动时间 2026-11-19 19:58:36。
- CommandLine 全文：`"C:\Tools\PowerShell7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "E:\PowerFocus\versions\v0.13\lib\mem-guard.ps1" -IntervalMs 1000 -CacheMs 5000`
- 加载脚本绝对路径：**`E:\PowerFocus\versions\v0.13\lib\mem-guard.ps1`**，18,824 B，SHA256 前 12 位 `DA573D199AA8`（与底账 §2.6 记录的 v0.13 副本 18,824 B 一致）。
- 进程启动 19:58:36 晚于文件 mtime（11-16 11:47:21），即进程加载的就是当前磁盘上这份 v0.13 副本。

全仓 + LOCALAPPDATA 副本检索（`Get-ChildItem -Recurse -Filter 'mem-guard*'`）：
- `mem-guard.ps1` 共 13 份：`versions\v0.05`～`v0.13` 各一份 + `archive\legacy-lib-20261105-032012` + `tools\ps1-bom-backup\v0.09/v0.10`；**`%LOCALAPPDATA%\PowerFocus\` 下 0 份 mem-guard 脚本**（v0.10/v1.00 目录只有 engines、reports、desktop/security/temp 日志）。
- 其余 pwsh：PID 25560 为内核主脚本；PID 29848/51996/52380 为本 agent 沙箱运行时；**无第二套 MemGuard 进程**。

**核实项 3：证据对齐——日志位置与新鲜度**

命令：检索全部 `mem-guard*.log`；读 v0.13 日志首尾行；读脚本路径常量。

原始输出：
- 唯一活动日志：**`E:\PowerFocus\versions\v0.13\logs\mem-guard.log`**，18,163 B，最新一条 `2026-11-19 22:05:06 [INFO] model=False mem=53.5% commit=47.5%(33.8GB/71.2GB) level=idle trimmed=0 freed=0MB raised=1`；`mem-guard.state.json` 22:06:29 刷新（取证时点 22:06:34），探针 `/api/health` 200、`kernel_alive=true`。
- 脚本自身路径常量（`mem-guard.ps1` L35–38）：`Root = Split-Path $PSScriptRoot -Parent`、`LogDir = Root\logs`、`LogFile = LogDir\mem-guard.log`、`StateFile = Root\mem-guard.state.json`——日志由脚本所在位置推导，落在 `versions\v0.13\logs\`，与实测一致。
- `%LOCALAPPDATA%\PowerFocus\v0.10\logs\` 下仅 `desktop.log`、`security.log`、`temp-20261115～19.jsonl`，**无 mem-guard.log**；`v1.00\logs` 仅 `desktop.log`。
- 历史日志：v0.05/v0.06/v0.07/v0.08/v0.09/v0.12 各一份，末次写入 11-16 03:31:44 及更早，属旧版本残留，**不是当前实例**。

**核实项 4：错位路径的引用范围**

命令：全仓 Grep `PowerFocus\lib\mem-guard`（`*.ps1`）。

原始输出：仅命中一处——`tests\test-mem-guard.ps1:9`：`$guard = 'E:\PowerFocus\lib\mem-guard.ps1'`，并在 L16 作为 `-File $guard` 启动参数使用。生产内核主脚本的两处拉起点（L1821、L2290）均为 `Join-Path $PSScriptRoot 'lib\mem-guard.ps1'` 相对定位，**不引用该绝对路径**。

### 10.2 裁定：**部分成立**

| 指控环节 | 裁定 | 依据 |
|---|---|---|
| 测试脚本路径错位、真跑用例不可执行 | **成立** | `tests\test-mem-guard.ps1:9` 写死的 `E:\PowerFocus\lib\mem-guard.ps1` 实测不存在；场景 A/B/C 启动守护即失败，这条测试通路当前不可跑。QA §3"证据确凿"的判断与本实测一致 |
| "生产内存守护对模型/前台的真实保护当前不可用" | **不成立** | 生产守护 PID 27596 正在运行 v0.13 脚本，命令行、磁盘哈希、日志与状态文件新鲜度四项对齐；内核用相对路径拉起，生产路径没有错位。错位的是**测试 harness 的路径常量**，不是运行时守护 |

QA 推断错在的一步：把"测试脚本里写死的默认/历史路径"当成了"生产运行路径"。QA 报告 §3 本身已写明"真实内核实现在 `versions\v0.13\lib\mem-guard.ps1`（18,824 B）"，与本裁定一致；需要纠正的是指控标题把"测试不可执行"升格表述为"守护不可用"。

### 10.3 影响

1. **断的是验证通路，不是守护进程**：守护对模型/前台的真实保护目前没有可执行的自动化真跑用例背书；pytest 全绿不覆盖这条生产通路（与 QA §2.2 一致）。
2. **不存在第二套常驻 MemGuard**：全仓与 LOCALAPPDATA 各只有一套活动实例；旧版本日志为历史残留，不推翻常驻进程口径。（另：PID 3580 pythonw 属 DSH sensevoice 的归属疑点仍按 §⑧-3 登记，与本项无关。）
3. **生产侧现象另案**：近 5 条日志均 idle、`trimmed=0 freed=0`（低水位空转），属水位/算法问题，与路径错位无关，交开发复核；脚本 L77–79 自带 2 MB / 1500 行截断，当前无需另建轮转。

### 10.4 建议（补法）

1. `test-mem-guard.ps1` 第 9 行路径参数化：读 `versions\current.json` 取 `version`，拼 `versions\<ver>\lib\mem-guard.ps1`（或相对脚本位置 `..\versions\<current>\lib\mem-guard.ps1`），禁止写死绝对路径；同脚本 L10 `$router='E:\PowerFocus\tools\model-router.ps1'` 建议一并核查是否错位（本轮不在四件事范围内，未深查）。
2. 修复前在测试台账标记该 ps1"不可跑/路径错位"，不计入已覆盖用例；第一步上线验收仍按 QA §④ V3 现场命令核对真实修剪。
3. 运维侧：v0.05–v0.12 历史 `mem-guard.log` 随日志归档策略清理；活动日志保留 v0.13 一份。

### 10.5 本节盲区

进程加载的脚本块在内存中的哈希无法直接读取；"运行的就是 v0.13 这份"的证据链为：命令行路径 + 磁盘文件哈希/大小 + 进程启动晚于文件 mtime，三项对齐。若进程启动后磁盘脚本被替换过（本轮未见替换痕迹，文件 mtime 停在 11-16），内存中仍可能是旧解析结果，需重启后复核。
