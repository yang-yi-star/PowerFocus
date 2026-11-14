# 更新日志（Changelog）

本项目所有重要变更将记录在此文件中。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号语义遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

> **版本真源（2026-11-14 定，工程审计 P0）**
> 唯一对外版本号 = **GitHub Release tag（当前 0.10.2）**，遵循 SemVer 2.0.0。
> 仓库里另有两类数字，只是「代码目录 / 内核迭代槽」，不是发布版本，不得当作 tag 引用：
> - `product/v1.00` — 桌面端代码目录名与数据目录版本槽；
> - `versions/current.json` → `v0.09`（stable）；`versions/v0.10` 的 MANIFEST 标 `stage=dev`，
>   是**尚未转正的开发内核，指针未切换是刻意决策，不是配置错误**。
>
> 修正历史问题：`[1.00.0]` 曾指向不存在的 tag（死链）；`1.00` 含前导零，违反 SemVer §2。
> 逐轮开发细节见根目录 `DEVELOPMENT_LOG.md`（append-only 权威开发日志）。

## [Unreleased]

### 第二批 · 架构收敛（阶段一，2026-11-14，**尚未发版**）

> 本段改动只在源码：未重新打包 exe、未创建 tag，`latest` 仍是 0.10.2。
> 路线图见 `docs/engineering-audit.md`；本批只完成其中可独立验证的一段，剩余项如实列在下方待办。

#### 改动

- **总线分层**：新增 `product/v1.00/app/bus.py` 的 `BusClient`（目录、超时、轮询、幂等 id、回执消费、超时撤回、GC 编排），`bus_receipt.py` 保持纯协议层；`server.py` 的 `bus_call()` 收敛为一行兼容包装，路由枢纽不再直接操作命令文件。
- **幂等 id**：命令默认携带 `idempotency_id`；当前内核忽略未知字段、行为不变，后续内核实现去重无需改服务端。
- **端口 TOCTOU 修复**：`main.find_port()` 改为 `bind_port()`，绑定并 `listen` 后全程持有 socket，交给 `uvicorn.Server.run(sockets=[sock])`，不再「先探测、再释放、再重绑」。
- **就绪判定升级**：`wait_ready()` 从「TCP 能连上」改为 HTTP `GET /api/health` 返回 200，避免 socket 已 listen 但 ASGI 未起来就开窗口。
- **测试**：新增 `tests/py/test_bus.py` 6 例，pytest 42 → **48**。
- **CI**：`py_compile` 目标补 `bus.py`，修正过时的依赖注释。

#### 验证

- pytest **48/48**；`ruff check` 0 错误；4 个 Python 模块 `py_compile` 通过；pwsh 7 全仓 **149 个 `.ps1`** 语法 0 错误。
- 源码实机链路：`bind_port` → 预绑定 socket → `serve(port, sock)` → `wait_ready=True` → `/api/health` 200（`kernel_alive=true`）。

#### 开源治理（同批，来自开源合规与冷启动审查）

- 6 个 `mem-guard.state.json` 历史副本从 git 索引移除（工作区文件原样保留），`.gitignore` 补运行态与本机诊断快照规则。
- `THIRD_PARTY_NOTICES.md` 修正与事实不符的「不随打包产物分发第三方程序」表述，补齐 `requirements.lock.txt` 全部 37 个包的许可证归因。
- `v0.10.2` Release 补传 `LICENSE` 与 `THIRD_PARTY_NOTICES.md`；开启 GitHub Private vulnerability reporting。
- 新增 `README_EN.md`；仓库补齐 topics 与 homepage。

### 已知待办（如实列出，避免误判完成度）

- 应用内每日自动扫描调度器（`run_scheduled_loop()`）已实现，但尚未随主进程常驻启动。
- 前端「立即扫描」按钮仍是模拟进度条，真实扫描走 CLI / 后端路由。
- 部分安全态势 API 仍为接口契约占位，未在后端实装。
- KVRT 下载源为 `latest` 直链（未锁定具体版本）；Node.js 已锁定版本 + SHA256。
- `server.py` 剩余模块拆分（`processes.py` / `nlp.py` / `llm_proxy.py`，目标 900 行内）、
  结构化回执 `{ok, ts, payload}`、模型路径改相对解析、端口集中注入、exe 冒烟测试与覆盖率门槛
  （见 `docs/engineering-audit.md` 路线图；第二批只完成总线分层、幂等 id、端口与就绪判定）。
- `/api/health` 仍回报内部版本槽 `version: 1.00 / kernel_version: v0.09`，与发布 tag 0.10.x 语义不同；
  是否对外统一由产品决策，本轮未擅自改动运行行为。

## 仓库发布（唯一对外版本真源）

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

### 内核 v0.09（stable，current.json 当前指向）及更早

见 `versions/` 各版本目录内的 `README.md` / `MANIFEST.json`，以及根目录
`DEVELOPMENT_LOG.md` 对应日期条目（2026-11-03 起）。

[Unreleased]: #unreleased
[0.10.0]: https://github.com/yang-yi-star/PowerFocus/releases/tag/v0.10.0
[0.10.1]: https://github.com/yang-yi-star/PowerFocus/releases/tag/v0.10.1
[0.10.2]: https://github.com/yang-yi-star/PowerFocus/releases/tag/v0.10.2

<!-- 仓库：yang-yi-star/PowerFocus（2026-11-13 上线） -->
