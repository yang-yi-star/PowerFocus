# 更新日志（Changelog）

本项目所有重要变更将记录在此文件中。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号语义遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。
版本递增规则（小更新 / 功能版本 / 全面更新）见 [`docs/VERSION_POLICY.md`](docs/VERSION_POLICY.md)。

> **版本真源（2026-11-14 定，工程审计 P0）**
> 唯一对外版本号 = **GitHub Release tag（当前 0.12.0）**，遵循 SemVer 2.0.0。
> 仓库里另有两类数字，只是「代码目录 / 内核迭代槽」，不是发布版本，不得当作 tag 引用：
> - `product/v1.00` — 桌面端代码目录名与数据目录版本槽；
> - `versions/current.json` → `v0.13`（stable）；内核逐版独立目录，指针切换以 `versions/VERSIONING.md` 记录为准。
>
> 修正历史问题：`[1.00.0]` 曾指向不存在的 tag（死链）；`1.00` 含前导零，违反 SemVer §2。
> 逐轮开发细节见根目录 `DEVELOPMENT_LOG.md`（append-only 权威开发日志）。

## [Unreleased]

### 本轮已落地（2026-11-26，应用化补齐，带回归）

- **版本真源统一**：新增 `product/v1.00/app/version.py` 单一真源（环境变量 → 旁侧 VERSION.json → git describe → `dev`）；`/api/health` 与窗口标题改接真源，同时回报 release 版本、内部槽与内核版本，不再三处分裂。
- **关于页 + 更新检查**：`/api/about` 展示版本/槽/内核/Python/许可与外链；`/api/update-check` 只对比 GitHub Release tag、不自动下载，网络失败或无 Release 如实返回，不抛 500。
- **应用偏好**：`app/preferences.py` 落盘 `preferences.json`，覆盖开机自启（HKCU 运行键）、关闭行为、刷新间隔（500–10000ms 钳制）、引导标记；损坏回退默认、未知键忽略、原子写。
- **首次引导**：未完成引导的新用户进入时弹 4 步浮层（认识面板 → 选目标 → 接本地模型 → 安全基线），可跳过；完成/跳过后落 `onboarded`，标记失败不阻断使用。
- **日志与配置导出**：`/api/export/logs` 汇总运行日志为纯文本下载；`/api/export/config` 备份非敏感配置并显式剥离 `api_key`（密钥在 DPAPI 库内，不参与备份）。
- **总览本地模型优先**：总览 verdict 下新增模型卡（已载入数量、模型名、显存、内核在线三态），通用 CPU/内存 KPI 下移为辅助行。
- **系统托盘（本轮降级）**：pywebview 6.2.1 无原生托盘 API，pythonnet 双消息循环长稳未验证；`close_action` 枚举保留 `tray`，前端该项禁用并标注下一版接入，本轮关闭行为只落地 `exit`。详见 `docs/roadmap.md`。

### 已知待办（如实列出，避免误判完成度）

- 应用内每日自动扫描调度器（`run_scheduled_loop()`）已实现，但尚未随主进程常驻启动。
- 模拟进度条只存在于 `versions/*/prototype` 演示页（页面自标「仍是模拟」）；产品版前端无该按钮，安全扫描走 `/api/security/scan` 真实路由。
- 安全态势 API 已实装 `/api/security`、`/api/security/scan`、`/api/security/scan/status`（无 501 占位）；剩余是前端展示细节未打磨。
- KVRT 下载源为 `latest` 直链（未锁定具体版本）；Node.js 已锁定版本 + SHA256。
- `server.py` 剩余模块拆分（`processes.py` / `nlp.py` / `llm_proxy.py`，目标 900 行内）、
  结构化回执 `{ok, ts, payload}`、模型路径改相对解析、端口集中注入、exe 冒烟测试与覆盖率门槛
  （见 `docs/engineering-audit.md` 路线图；第二批只完成总线分层、幂等 id、端口与就绪判定）。

### 双专家审查后明确未修的安全项（本轮不假装完成）

红队视角攻防审计与 Bug 猎手共提交 14 + 30 条发现，本轮只落地与 MCP 发行物直接相关的 P0。
以下保持开放状态，需单独排期或产品授权：

- **F4**：内核命令总线本身无认证，任何能写 `commands/in` 的本地进程都能驱动内核
  （需改约 2000 行 PowerShell 内核，且涉及 stable 指针，不擅自切）。
- **F3**：`/api/health` 在限流豁免集合内；**F7**：KVRT 验签与执行之间存在 TOCTOU，执行前应重验并重算 SHA256。
- **F8**：`dependency_bootstrap.py` 的同意令牌是源码可读的硬编码常量。
- **F10**：部分写操作未进审计日志；**F13**：exe 未做 Authenticode 签名（需证书决策）。
- **B7/B8/B9/B11/B12/B13** 等 P1/P2 级并发与参数校验细节，见审查记录。

## 仓库发布（唯一对外版本真源）

### [0.12.0] - 2026-11-15

按 `docs/VERSION_POLICY.md` 判定为 **MINOR（功能版本）**：新增向后兼容的能力与接口，
老用法全部继续有效。内核线随本版转为 v0.13（stable）。

### 新增（主应用）

- **温度采集落盘**（`product/v1.00/app/temp_log.py`）：优先 LibreHardwareMonitorLib
  （pythonnet，经 `POWERFOCUS_LHM_DIR` 指定库目录），GPU 失败时退回 `nvidia-smi`，
  CPU 无法兜底时如实置空、不填假值；按天落盘 `temp-YYYYMMDD.jsonl`，内存维护本次
  运行峰值并在启动时扫描历史峰值；新增只读接口 `GET /api/temp`（走既有令牌鉴权）。
- **真实病毒扫描 API**（KVRT 链路）：`POST /api/security/scan`（后台执行；
  `process_level>0` 处置必须显式 `disinfect_confirm=yes`）、
  `GET /api/security/scan/status`（进度与结果轮询）。

### 新增（MCP 发行物，版本对齐 0.12.0）

- 新增高危工具 `pf_security_scan`（双重开关：`POWERFOCUS_MCP_ALLOW_WRITE=1`
  + 一次性确认 nonce；默认 `process_level=0` 只报告不处置）。
- 新增只读工具 `pf_security_scan_status`。默认只读工具由 10 个变 11 个。

### 内核（versions/，指针 `current.json` → v0.13）

- **v0.12（stable）**：进程价值判据重写——按可见窗口分级
  （`protect`/`active`/`busy`/`visible`/`idle`），TCP 连接不再算「在用」；
  **清场永不杀进程**，改为优先级 + EcoQoS + 工作集换出，释放时完整还原。
- **v0.13（stable）**：配套应用声明机制（`companion-apps.json`）——用户声明
  「正在使用」的应用按父子链整组 protect 不压不杀。依据：CPU/IO/TCP/窗口四个信号
  在实测中全部判不准「在用」（覆盖 41 个 PID 的实测数据，见 `docs/` 盘点文档）。
  修复 `$pid` 只读自动变量被当循环变量的问题。
- `new-version.ps1` 不再复制 `engines/`（运行时引擎走 `app_paths.data_root()`，
  版本目录内的 `engines\` 是历史遗留）；版本工具支持 `.py` 与 `prototype`。

### 修复（主应用）

- **打包组件错位**（关键）：`build.ps1` 此前写死 `versions\v0.10`，导致每次打包都把
  4 个 Python 组件的**旧副本**塞进 exe——内核指针已指到新版本、exe 里跑的却是旧组件。
  现改为跟随 `versions\current.json` 指针，指针缺失时回退到含组件的最高版本目录。
- **内核拉起启动竞态**：`main.py` 原实现硬等 10 秒，磁盘繁忙/杀软扫描的机器上会误判
  「内核未响应」；改为指数退避 + 内核进程存活检查，总上限 90 秒，内核提前崩溃立即报错。
- **72 个 `.ps1` 文件 BOM 编码统一**（UTF-8 BOM，消除 5.1 下中文注释乱码）。

### 文档

- 新增 12 篇盘点/实测文档（进程判据重写、整机实测、能力台账、版本台账、
  行业共识对照、硬编码盘点、统一内存接线、温度落盘、IO 判据、内核逐版真改、
  复用底账、v0.11 转正式版记录），另附 benchmark 证据 JSON。

### 验证

`pytest` **113 passed**（新增 9 例：安全扫描接口 + 温度模块）；`ruff` 0 错误；
`py_compile` 全部目标通过；关键 JSON 契约（`mcp/VERSION.json`、`current.json`、
`MANIFEST.json`×3）解析通过；改动过的关键 `.ps1` 语法 0 错误。
- exe：Release 附件 `PowerFocus-v0.12.0-x64.exe` 由 CI（windows-latest runner）
  构建并上传，其字节数与 SHA256 由流水线写入该 Release 说明供下载者校验。
- 本机构建副本（同源码、PyInstaller 非可复现构建，与 CI 产物二进制略有差异属正常）：
  **20,475,707 字节**，SHA256
  `bcbf0b40d6227bfc46d993a4fcfa00e30d6090c2cd1e0acb8101cc5cb5cb91d8`
  （打包组件目录 = `versions\v0.13`，2026-11-15）。
- `PowerFocus-MCP-v0.12.0.zip` — 由 CI 从 `mcp/` 打包，作为 Release 独立附件。

### 明确不入库

- `tools/lhm-lib/`（LibreHardwareMonitor v0.9.6 第三方库副本，运行时依赖；
  用户按 `docs/温度落盘-2026-11-15.md` 从官方 Release 自行下载）。
- `marketing/douyin/video_hy4/`（59.7 MB 素材工程，非发行物）。

### [0.11.1] - 2026-11-14

按 `docs/VERSION_POLICY.md` 判定为 **PATCH**：无新功能，纯缺陷修复 + 通用化加固。
定位升级：从「开发机定制品」正式转向**通用应用**——任何电脑 / 服务器加载即可用。

### 修复（红队 F / Bug 猎手 B 编号延续 v0.11.0 审计）

- **F4 命令总线认证**：v0.09（stable）与 v0.10（dev）两代内核消费命令前校验
  `token == Get-AuthToken`，未认证命令回 `ERROR: 命令总线认证失败`；服务端 `BusClient`
  统一注入内核令牌，前端与 MCP 无感知。
- **F7 KVRT 验签 TOCTOU**：`run_scan()` 执行前在同一路径对象上重跑 `WinVerifyTrust`
  并重算 SHA256，与已验签记录比对，不通过即拒绝运行（换文件攻击闭环）。
- **F8 硬编码同意令牌**：删除源码可读常量，改为 `mint_consent(scope)` / `check_consent()`
  一次性令牌（TTL 120s、scope 绑定、用后即焚、错误 scope 尝试直接烧毁令牌）；
  服务端在 POST 内部现场签发并消费，令牌不出服务端、不进浏览器。
- **F3 health 限流**：`/api/health` 免鉴权但不再免限流，限流判定移到鉴权之前。
- **B21 chunked 绕过**：`BodyLimitMiddleware` 对无 `Content-Length` 请求按实际字节累计，
  超限直接 413（回归测试模拟 chunked 全链路）。
- **B22 限流器内存**：`RateLimiter` 每窗口期清扫整桶过期的 key，长期驻留不再无界增长。
- **B11** `/api/chat` `messages` 强制对象数组（≤50 条、每条 ≤32k），非法输入 400 不再 500。
- **B12** `/api/models` 对烂 `profiles`（list / 非 dict）容错，返回空列表不 500。
- **B13 超时契约**：前端 `runCommand` HTTP 预算按 `_timeout` 动态放大
  （`budgetMs = max(90s, _timeout+10s)`），180s 的 `start_router` 不再 90s 断连留孤儿回执。
- **B24** 云端测试失败不再回显上游响应正文。
- **B27** 云端 BASE_URL / 模型地址强制 loopback / https 白名单（`_cloud_url_ok`），
  堵 SSRF 与凭据外送面。
- **B7** 桌面日志 handler 竞态消除（启动时一次性挂 handler）；改 2MB×5 轮转。
- **B8** `wait_ready()` 连接在 finally 中关闭。
- **B9** `_maybe_gc()` 异常不再吞进静默，纳入审计。
- **B19/B20** `OpenProcess` 补 restype/argtypes（64 位句柄截断）；互斥量用
  `use_last_error=True` 正确判定 `ERROR_ALREADY_EXISTS`。
- **B23** 三套日志目录归一：`%LOCALAPPDATA%\PowerFocus\<槽>\logs\`。
- **B26** 配置路径回退统一走 `app_paths` 规则。
- **B28** `/api/health` 的 `kernel_alive` 现在反映内核回执通道真实探活。
- **B29** 删除第二条启动路径：`app/server.py` 开发入口统一走产品版 `serve_only()`。
- **B30 版本槽语义**：`app_paths` 的引擎槽常量与发布版本解耦并写明契约；
  `build.ps1` 的 pyinstaller 路径改为仓库相对解析；spec 文件绝对路径全部相对化。

### 通用化（新目标：任何电脑 / 服务器加载即可用）

- **模型预设三层查找**：`models-preset.local.ini`（本机私有，gitignore）→
  内核目录 local → 内置 `models-preset.ini`（模板）。
- **存在性过滤**：`model-router.ps1` 启动前按本机文件存在性过滤模型条目，
  换机后缺失条目自动跳过并提示，全部缺失时给出配置指引，而不是让 llama-server 启动失败。
- `tools/calibrate-vram.ps1` 去除全部 `E:\` 硬编码，支持 `LLAMA_SERVER_EXE` 环境变量覆盖。
- 全仓盘符扫描：项目代码（py / ps1 / ini / json / js / yml）零本机绝对路径残留。

### 验证

`pytest` **104 passed**（新增 15 例 v0.11.1 回归：F8 令牌 5 例 + B22 2 例 +
B21 2 例 + B11/B12/B13/B29/F3 守卫等）；`ruff` 0 错误；`py_compile` 10 目标；
pwsh 7 全仓 `.ps1` 语法 0 错误（含新增的 model-router 过滤逻辑四场景冒烟：
预设源查找 / 全存在复用 / 模拟换机全缺失报错 / 部分缺失过滤生成）。

**实机验证（新打包 exe）**：`frozen=true / kernel_alive=true / ready=true`；
F4 双向冒烟通过——带令牌命令 `ok=true`，直投无令牌命令回执
`ERROR: 命令总线认证失败：缺少或错误的内核授权令牌`。

### 发行物

- `PowerFocus-v0.11.1-x64.exe` — 20,457,037 字节，
  SHA256 `7dd5e1e7923e22378ff0cb1de7e14b7ec9e87eed35591cdc2f1f2ef8ebdf9c0b`。
  注意：投稿目录中的 `电脑算力调度中心.exe` 与本 Release 资产是**同一构建的不同文件名**
  （SHA256 完全一致，仅按发布渠道分别命名）。
- `PowerFocus-MCP-v0.11.1.zip` — 19,970 字节（版本对齐 0.11.1，包内 6 个文件：
  `VERSION.json` / `config.example.json` / `README.md` / `LICENSE` /
  `powerfocus_mcp/__init__.py` / `powerfocus_mcp/server.py`），
  SHA256 `8da64b985fef87d6cf5dc8858d0f5d95afff5610babeb5263c901400a4daf166`；
  相比首发包补入了随包 LICENSE（Apache-2.0）并修正包内版本字符串残留。

### [0.11.0] - 2026-11-14

按 `docs/VERSION_POLICY.md` 判定为 **MINOR**：新增向后兼容能力（MCP）并附带安全加固，
原有桌面端用法、配置与 API 不变。上一轮 `cfe0ffd`（第二批阶段一 + 开源治理）未单独发版，
其内容并入本版本，保证 tag 与 exe 源码一一对应。**本版本重新打包了 exe**
（20,450,312 字节，SHA256 `72f6bc871d79e1451ba21d170544df4493847b9315a151c7bb7dd02ee0e78a74`，
实机启动 `frozen=true / kernel_alive=true / port=18080`）。

#### 新增 · 可对标最新版本独立加载的 MCP 发行物

- 新增 `mcp/` 独立发行物：`VERSION.json`、`config.example.json`、`README.md`、
  `powerfocus_mcp/__init__.py` 与 `powerfocus_mcp/server.py`。零第三方依赖，
  仅 Python 3.10+ 标准库 + stdio JSON-RPC，任意 MCP 客户端加一段 `mcpServers` 配置即可加载。
- 协议默认 **MCP `2026-07-28`** 无状态核心：不要求握手、支持 `server/discover`、
  `tools/list` 按名排序并带 `ttlMs`/`cacheScope`；同时兼容 `2024-11-05`~`2025-06-18` 的
  `initialize` 握手（官方 12 个月弃用窗口）。
- **默认只读**：只暴露 10 个只读工具；写工具与安装类高危工具默认不出现在 `tools/list`，
  分别需 `POWERFOCUS_MCP_ALLOW_WRITE` / `POWERFOCUS_MCP_ALLOW_INSTALL` 显式开启。
- **一次性确认**：写工具首次调用返回 `resultType: "input_required"` 与短 TTL nonce，
  nonce 绑定工具与参数摘要、用后即失效，支持 `inputResponses` 重试；静态 `true` 不可用。
- **声明即白名单**：只转发 `inputSchema` 显式声明的参数，`token` / `idempotency_id`
  等字段无法从 AI 侧注入后端命令；所有调用写审计日志（只记参数键名，不记值/令牌）。
- 不再转发旧实现的 229 项 REA 逆向引擎能力；根目录旧 `mcp-server.py` 已标记
  `[DEPRECATED since v0.11.0]`，保留仅为历史兼容，不随 Release 分发。
- 每个 Release 附带独立的 `PowerFocus-MCP-v0.11.0.zip`，版本与主应用 tag 严格对齐。

#### 新增 · 版本规则

- `docs/VERSION_POLICY.md` 固化「小版本 = 小更新（PATCH）/ 功能版本（MINOR）/
  大版本 = 全面更新（MAJOR）」判定表、每次开发完成的 8 步发布闭环、
  MCP 发行物与主版本对齐规则、已发布版本索引。

#### P0 安全加固（代码实证，双专家审查交叉确认）

- **F1 · 令牌解耦**：`GET /` 免鉴权却把令牌注入首页 meta，而该令牌原本就是内核授权令牌
  `.auth_token`。现拆为 `_token()`（HTTP/UI 令牌，存 `%LOCALAPPDATA%\PowerFocus\http.token`）
  与 `_kernel_token()`（仅服务端内部注入命令对象，绝不进入 HTTP 响应）；
  `/api/command` 的授权/破坏性动作改注入内核令牌。
- **B2 · 并发首启**：`_token()` 改为进程内加锁 + `.tmp` → `os.replace` 原子写，
  12 线程并发不再产出多个不同令牌。
- **F2/F5 · 参数注入**：`/api/command` 主动丢弃客户端传入的 `token` 与 `idempotency_id`，
  幂等键一律由 `BusClient` 服务端生成。
- **B1 · 回执误判**：`versions/current.json` 指向的 **v0.09 stable** 此前仍是
  「时间戳首行 + `Set-Content` 非原子直写」，第一批只改了 dev 的 v0.10。
  现两代内核统一为「纯正文 + `.tmp` → `Move-Item -Force` 原子替换」；
  `BusClient.call()` 对空回执再等最多 3 轮，避免把稍后写入的 `ERROR` 判成成功。
- **B10 · 假绿测试**：`test_bus_call_timeout_cleans_input` 的 monkeypatch 打在
  `server.BUS_IN` 上，但 `BUS` 实例导入时已绑定真实目录，`tmp_path/in` 从未创建，
  断言恒真且每次跑测试都往 `versions/v0.09/commands/done/` 写孤儿回执。
  已改为隔离的 `BusClient` 实例 + 有效断言，并清理了 5 个历史孤儿回执。
- **B6 · 硬编码**：`resolve_pf_root()` 删除开发机绝对路径 `E:\PowerFocus` 兜底，
  改为环境变量 → 向上探测 → `%LOCALAPPDATA%` 回退。
- **畸形消息免疫**：新 MCP 对 `params` 非对象、空 method、非字典消息一律安全退化，
  主循环包异常且 `emit()` 可序列化兜底，不再出现旧实现「打崩 stdio 进程」的情况。

#### 第二批 · 架构收敛（阶段一）

- 新增 `product/v1.00/app/bus.py` 的 `BusClient`（目录/超时/轮询/幂等 id/回执消费/
  超时撤回/GC），`bus_receipt.py` 保持纯协议层，`server.bus_call()` 收敛为一行兼容包装。
- `main.find_port()` → `bind_port()`：socket 绑定并 listen 后全程持有，交给
  `uvicorn.Server.run(sockets=[sock])`，消除 TOCTOU；`wait_ready()` 改为 HTTP
  `GET /api/health` 等 200，而非 TCP 能连。
- 新增 `tests/py/test_bus.py` 6 例；`ci.yml` 的 `py_compile` 目标补 `bus.py` 与两个 MCP 模块。

#### 开源治理（并入本版本）

- 6 个运行态 `mem-guard.state.json` 从 git 索引移除（本地文件原样保留），`.gitignore` 补规则。
- `THIRD_PARTY_NOTICES.md` 更正与 exe 事实不符的表述，补齐 `requirements.lock.txt` 全部 37 项许可证归因。
- `v0.10.2` Release 补传 `LICENSE` 与 `THIRD_PARTY_NOTICES.md`；开启 GitHub 私密漏洞报告。
- 新增 `README_EN.md`；仓库补齐 12 个中性合规 topics 与 homepage。

#### 验证

- pytest **89 passed**（0.10.2 为 42；本版新增 `test_mcp_server.py` 31 例、
  `test_p0_hardening.py` 10 例、`test_bus.py` 6 例）。
- `ruff check` 0 错误；CI 清单的 10 个 Python 目标 `py_compile` 全部通过；
  pwsh 7 全仓 **150 个 `.ps1`** 语法 0 错误，两代内核分别 13208 / 13206 token、0 错误。
- 源码实机链路：`bind_port` → 预绑定 socket → `serve(port, sock)` → `wait_ready=True`
  → `/api/health` 200（`kernel_alive=true`）。
- MCP 端到端：无握手 `tools/call`、`server/discover`、确定性工具列表、
  nonce 两步确认与重放拒绝、参数白名单、畸形消息免疫均有用例覆盖。

#### 附件

`PowerFocus-v0.11.0-x64.exe`、`LICENSE`、`THIRD_PARTY_NOTICES.md`、
`PowerFocus-MCP-v0.11.0.zip`。

### [0.10.2] - 2026-11-14

四视角工程审计的第一批落地，详见 `docs/engineering-audit.md`。**本版本重新打包了 exe**
（20,446,612 字节，SHA256 `b110e829bc1074649f0239a551ebc1d98cfdb97286c488f913d2ee92cb2d3429`）。

#### 修复

- **P0 · 失败回执被当成功**：新增 `product/v1.00/app/bus_receipt.py` 协议层，`parse_receipt()` 识别 `ERROR:` 前缀并兼容旧版时间戳首行；内核回执改为纯正文，`/api/router` 的 `data` 不再因时间戳而恒为 `None`。
- **P0 · 文件总线可靠性**：命令改为 `.tmp` → `os.replace` 原子发布（内核 `-Filter *.json` 看不到半成品）；回执消费后立即清理，另加 10 分钟节流的过期回收（实测残留 72 个文件）。
- **P1 · 单实例静默退出**：第二个实例被互斥量挡下时弹出系统消息框；`CreateMutexW.restype` 设为 `c_void_p`，避免 64 位句柄被 ctypes 截断。
- **P1 · 版本真源**：本文件重写为单一真源，消除 `v1.00.0` 死链与前导零违规，明确 stable / dev 分期；`SECURITY.md` 私密报告渠道占位注释补实。

#### 工程

- **测试防线**：新增 `tests/py/test_bus_receipt.py`（9 例），pytest 总用例 33 → 42；另有端到端伪内核实证（ERROR → `ok=False`、回执清理、旧格式 JSON 可解析）。
- **CI 门禁**：新增 `ruff check`（此前只有 pyproject 配置没有强制），依赖改由 `requirements-ci.txt` + `requirements.lock.txt` 锁定，`on` 增加 `tags: ['v*']`，`py_compile` 目标补新模块。
- **依赖与治理**：新增 requirements 四件套、CODEOWNERS、dependabot、PR / Issue 模板。
- **验证**：pytest 42/42、ruff 0 错误、96 个 PowerShell 文件语法 0 错误、YAML 合法、新 exe 启动 `frozen=true / kernel_alive=true`。

### [0.10.1] - 2026-11-14

界面 v3「暖木工作台」。附件 20,442,721 字节，SHA256 `543c429ad225e07d6ec434ce41981c7e84d1ef65ec51cfe518a52fd5bc530cb8`。

- **深浅双主题**：token 化 94 个 `--pf-*` 变量，顶栏一键切换并持久化；浅色暖米白 `#FAF6F0`、深色 hue 32° 暖棕灰 `#221E19`、陶土橙单一强调色。
- **无障碍**：全部文字与状态色经 WCAG 2.1 AA 双人独立计算校验；状态色拆「图形轨 3:1 / 文字轨 4.5:1」；焦点环改 2px 实色 accent。
- **清退 v2 违规项**：渐变 logo、紫色第二强调色、10px 小字、无限呼吸动画。
- 新增 `design-tokens.css` / `theme-init.js`；`style.css` 全量改为 token 引用，类名体系不变，前端逻辑零结构改动。
- 设计系统规范与实机截图归档于 `docs/design-v3/`、`marketing/v3_live_*.png`。
- 本 tag 指向包含全部 v3 源码的 `5d98516`，是首个「源码与附件对齐」的发布版本。

### [0.10.0] - 2026-11-13

首个公开发布版本：界面 v2（Linear 风）、7 组件自检、KVRT 合规接入、用户手册与法律合规审查。
Release 附件于 11-14 同步替换为 v3 界面 exe，但该 tag 仍指向首次发布时的源码快照；
**源码与附件对齐的版本是 0.10.1 及其后版本**。

## 桌面端产品（代码目录 `product/v1.00`，非 SemVer 版本）

### v1.00 初始实现 - 2026-11-13

#### 新增

- 七页导航控制台（WebView2 单页应用）：总览 / 进程 / 场景 / 模型与对话 /
  安全态势 / 设置 / 日志。
- 进程调度操作：聚焦三档（温和 / 强制 / 极限）、优先级调整、内存回收（空闲工作集）、
  冻结恢复、终止（破坏性，需确认）。
- 自然语言指令与对话模式：中文指令离线规则解析优先，LLM 兜底；
  云端 API 直连（默认）与本地推理服务双通道，可在设置页切换；
  敏感命令（授权 / 撤销）永远不由 LLM 生成。
- 模型路由与场景预设（游戏 / 工作 / 全力等）一键切换。
- 组件自检接入主进程：启动时后台预热自检，前端新增「组件自检」页，
  下载 / 安装向导类操作需前端传入用户同意令牌，服务端不代填。
- 桌面快捷方式（`install.ps1`）与 PyInstaller 打包脚本，exe 内嵌项目图标。

#### 安全

- 安全基线：服务仅监听 `127.0.0.1`，接口需令牌访问；写操作全部走白名单动作，
  不允许任意命令透传；不操作 PPL 保护的系统进程。
- 模型凭据经 DPAPI 加密存储；破坏性操作二次确认且需本机 token。
- 0.11.0 起 HTTP/UI 令牌与内核授权令牌解耦，详见上文。

#### 修复

- 桌面端版本错位（入口层 / 文档层 / 图标）与历史遗留的重复桌面图标。

## 调度内核（`versions/` 迭代槽，非发布版本）

### 内核 v0.10（stage=dev，未切 current.json） - 2026-11-13

#### 新增

- 应用内安全扫描真实链路（`kvrt_bundle.py`）：经用户同意从卡巴斯基官方源下载 KVRT、
  纯 Python 验签（`WinVerifyTrust` + SHA256，零外部进程）、真实扫描、
  解析官方编码报告并落盘、应用内每日调度配置。已实测扫描 6,943 个对象。
- 多引擎适配层（`engine_adapters.py`）：统一接口识别并调用本机已装安全软件
  （KVRT / Microsoft Defender / 卡巴斯基 KES / ESET 等）；「识别 ≠ 可调用」，
  未经实测的引擎默认拒绝执行；调用遵循「只报告、不处置」边界。
- 启动依赖自检（`dependency_bootstrap.py`）：声明式组件清单（7 项）、
  默认只读自检、`install` 需用户同意令牌、官方源下载 + 哈希校验 + 安全解包
  （防路径穿越）、审计报告落盘；支持离线降级（`--offline`）。
- 卡巴斯基完整版（`vendor_installer` 模式）：只下载并验签官方在线安装器，
  启动官方向导需第二道用户同意令牌且不带任何静默参数，绝不代装。
- Node.js 按需补齐：官方源下载锁定版本（官方清单哈希 + 锁定 SHA256 双重校验），
  解包到应用目录，不修改系统 PATH。

#### 修复

- 运行态数据目录统一至 `%LOCALAPPDATA%\PowerFocus`（`app_paths.py`），
  历史目录只读兼容，不再写入程序目录。
- KVRT 报告解析按官方 stdout 与 XML 字段校准（修复把 `Detected: 0` 误报为 1 条威胁的问题）；
  修正 `-d` 参数连写触发帮助窗口挂起、下载进度污染 stdout、幂等跳过误判失败等问题。
- 2026-11-14：命令回执不再前置时间戳（服务端据此正确解析 JSON 与失败状态）。
- 2026-11-14（0.11.0）：回执改为 `.tmp` → 原子替换，避免服务端读到半截空文件。

### 内核 v0.09（stable，current.json 当前指向）及更早

- 2026-11-14（0.11.0）：同步修复回执格式 —— 去掉时间戳首行、改为原子替换。
  此前第一批只改了 dev 的 v0.10，本版本补齐当前真正生效的 stable 内核。
- 其余见 `versions/` 各版本目录内的 `README.md` / `MANIFEST.json`，以及根目录
  `DEVELOPMENT_LOG.md` 对应日期条目（2026-11-03 起）。

[Unreleased]: #unreleased
[0.10.0]: https://github.com/yang-yi-star/PowerFocus/releases/tag/v0.10.0
[0.10.1]: https://github.com/yang-yi-star/PowerFocus/releases/tag/v0.10.1
[0.10.2]: https://github.com/yang-yi-star/PowerFocus/releases/tag/v0.10.2
[0.11.0]: https://github.com/yang-yi-star/PowerFocus/releases/tag/v0.11.0

<!-- 仓库：yang-yi-star/PowerFocus（2026-11-13 上线） -->
