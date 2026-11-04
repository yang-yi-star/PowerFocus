# PowerFocus 开发规范

> 本文件是 `E:\PowerFocus` 的开发环境契约。任何 AI 或人接手开发前，先读本文件与 `DEVELOPMENT_LOG.md`。
> 变更规范本身也要在 `DEVELOPMENT_LOG.md` 追加一条记录。

## 1. 定位与三条硬约束

PowerFocus 是**通用算力调度加速器**：给任意本地模型榨干整机性能，不绑定任何具体模型。

1. **单模型优先**：不做多模型并存调度。
2. **参数不跨模型复用**：未命中档案（`v3\model-profiles.json`）的模型禁止套用任何档位参数。
3. **v2 / v3 物理隔离**：日志、状态、命令总线各自独立，禁止混写。

## 2. 目录规范

**现有文件一律不搬家**（脚本内是绝对路径，桌面快捷方式与计划任务 `PowerFocusAutoV2` 指向根目录转发壳）。只允许增量补齐：

| 路径 | 角色 | 是否入库 |
|---|---|---|
| `电脑算力调度中心.ps1` | 主入口转发壳（快捷方式/计划任务指向此文件） | 是 |
| `v2\` | v2 真身 + 独立 `logs`/`commands`/`rules_state` | 源码入库，运行时状态忽略 |
| `v3\` | v3 引擎（未上线）；`lib\` 注册表与回滚模块 | 源码入库，`commands\`/`.v3.lock`/`rollback\*.json` 忽略 |
| `lib\` | 根级共享模块（app-purger / clean-recyclebin / geek-bridge） | 是 |
| `tools\` | 开发者工具：`dev-check.ps1` 环境自检 | 是 |
| `tests\` | 测试入口：`run-tests.ps1` | 是 |
| `docs\` | 规范与设计文档（本文件所在） | 是 |
| `logs\` | 运行日志 | 否 |
| `commands\` | 命令总线 `in\` `done\` `out\`（只保留 README 与示例） | 部分 |
| `archive\` | 历史备份与一次性证据；截图/日志不入库 | 部分 |
| `out\` | 临时产物（运行时自动创建） | 否 |
| `DEVELOPMENT_LOG.md` | **append-only 开发日志**，最新在底部 | 是 |
| `__pycache__\` | Python 字节码 | 否 |

新增文件先问一句：它是**长期源码**还是**一次性产物**？产物放 `out\`，不进根目录。

## 3. 工具链与固定解释器

| 工具 | 固定路径 / 版本 | 备注 |
|---|---|---|
| pwsh | 7.6.9 | **唯一 Shell**，禁用 `powershell.exe` 5.1 |
| Python | `D:\Python313\python.exe`（3.13.0） | 备选 3.11 / 3.12，按此顺序回退 |
| Node | `C:\Program Files\nodejs\node.exe`（v26.13.0） | REA / MCP 生态 |
| rea-agents | `%APPDATA%\npm\rea.cmd`（6.8.0，229 工具） | 全局安装，MCP 逆向能力来源 |
| Git | 2.54.0 | 本地仓库，不推远程 |
| llama.cpp | `E:\Program Files\llama.cpp\bin\llama-server.exe`（b12032） | 推理引擎 |
| CUDA / CMake / Ninja / aria2 / ffmpeg | 已在 PATH | 见索引 |

**沙箱 PATH 污染（实测发现）**：在豆包/WorkBuddy 的 agent 沙箱里执行命令时，PATH 上的 `python` / `node` / `rea` 会被替换为沙箱自带版本（3.13.16 / 22.23.2 / rea 6.7.0），与系统真实版本不同。表现为「工具版本忽高忽低」「REA 工具数从 229 掉到 207」。因此：

- 脚本内一律写**绝对路径**，不依赖 PATH 上的 `python` / `node`。
- `dev-check.ps1` 会把这种差异报成 `WARN node 别名` / `WARN rea 别名`，看到 WARN 不是环境坏了，是执行器在沙箱里。
- `mcp-server.py` 的 `_find_rea()` 现在按 `POWERFOCUS_REA` → `%APPDATA%\npm` → PATH 的顺序定位，优先命中全局 6.8.0（229 工具）；只在全局安装缺失时才回退到 PATH（可能命中沙箱版）。

**编码**：源文件统一 UTF-8（`.editorconfig` 锁定），中文文件显式 `-Encoding utf8` 读写。`.ps1` 用 CRLF，`.py`/`.json`/`.md` 用 LF（`.gitattributes` 锁定）。

## 4. 运行与调试入口

```powershell
# 环境自检（工具链/关键文件/端口/显存/git）
pwsh -File E:\PowerFocus\tools\dev-check.ps1
pwsh -File E:\PowerFocus\tools\dev-check.ps1 -Json      # 机器可读

# 测试（语法/JSON/Python/MCP 冒烟/仓库卫生）
pwsh -File E:\PowerFocus\tests\run-tests.ps1
pwsh -File E:\PowerFocus\tests\run-tests.ps1 -SkipMcp   # 不想拉起 MCP 时

# v2（生产）：双击转发壳或计划任务；调试时直接 dot-source
# v3（未上线）：调试用 $env:PF_V3_NO_LOCK=1 绕过单实例锁
# MCP 服务：客户端以子进程方式拉起，手工冒烟见 tests\run-tests.ps1 第 4 项
```

**MCP 手工冒烟**：向 stdin 写两行 JSON-RPC（`initialize` → `tools/list`），首行 `id=1`，次行 `id=2`，读 stdout。服务端错误只写 stderr，不会污染协议流。

## 5. 测试规范

`tests\run-tests.ps1` 是唯一测试入口，五类检查：

| 检查 | 内容 | 失败含义 |
|---|---|---|
| PS 语法 | 全仓 `.ps1` 走 `Parser::ParseFile` | 语法错误，加载即崩 |
| JSON 契约 | `model-profiles.json` schema、rules/scenes/authorized_apps 合法性 | 运行时解析失败 |
| Python 编译 | `py_compile mcp-server.py` | MCP 服务无法启动 |
| MCP 冒烟 | stdio `initialize` + `tools/list`，校验 5 个原生工具与协议回显 | 协议层断裂或工具丢失 |
| 仓库卫生 | 确认 `auth_token` / `*.log` / 心跳 / 锁未被 git 跟踪 | 密钥或运行态泄漏 |

**规矩**：改完任何 `.ps1` / `mcp-server.py` / 配置 JSON，必须先跑 `run-tests.ps1` 全绿，再写 `DEVELOPMENT_LOG.md`。

## 6. 日志与产物分离

| 类型 | 位置 | 说明 |
|---|---|---|
| 运行日志 | `v2\*.log`、`v3\*.log`、`logs\` | 不入库；按日期追加，不覆盖 |
| 生命周期/心跳 | `v3\v3-lifecycle.log`、`v2\v2_heartbeat.json`、`v3\v3.lock` | 运行时状态，不入库 |
| 命令总线 | `commands\{in,out,done}`、`v2\commands\`、`v3\commands\` | 运行态，不入库；只留 README 与示例 |
| 实测证据 | `archive\<主题>-<时间戳>\` | 一次性证据，截图/日志不入库 |
| 开发记录 | `DEVELOPMENT_LOG.md` | **入库**，append-only |

禁止把运行日志、截图、模型文件写进根目录。

## 7. 配置与密钥

- `v3\.auth_token`（开后门授权令牌）、`*.token`、`*.secret`、`*.key`：**永不入库**，已在 `.gitignore`。
- `authorized_apps.json`（授权清单）、`scenes.json`（场景预设）、`rules.json`（规则）：属于配置，入库；修改必须先备份为 `.bak`。
- MCP 客户端配置分散在各 AI 客户端目录，统一通过 `E:\PowerFocus\mcp-server.py` 转发，不逐份散改。
- 令牌只落本地文件，不进命令行参数、不进日志、不进提交信息。

## 8. 版本与归档

- 版本演进 = **新目录 + 根目录转发壳切换**（v1 → `archive\`，v2 → `v2\`，v3 → `v3\`）。禁止在旧目录上就地重写主脚本，除非先备份进 `archive\`。
- 大版本切换前：`git commit` 一次基线，再动刀；切换失败用 `git checkout` 回退。
- 归档命名：`archive\<主题>-<yyyyMMdd-HHmmss>\`，与现有目录保持一致。

## 9. 提交规范

- 只提交源码、配置、文档；运行态与密钥由 `.gitignore` 兜底。
- 提交信息前缀：`feat:` / `fix:` / `docs:` / `chore:` / `refactor:`，一句话说清**为什么**改。
- 同一提交内附带 `DEVELOPMENT_LOG.md` 条目，保证「代码变更 ↔ 日志记录」可追溯。
- 仓库未配置全局 git 身份时，用行内参数提交，避免污染全局配置：
  `git -c user.name="PowerFocus Dev" -c user.email="dev@local" commit -m "..."`

## 10. 排障顺序（不得跳步）

1. 查 `DEVELOPMENT_LOG.md`：同类问题是否修过、当时怎么修、当时运行态如何。
2. 查官方文档（llama.cpp / MCP 规范 / Python 官方）。
3. 无官方文档才自己动手，且全程记录到 `DEVELOPMENT_LOG.md`。
4. 网络问题先分类：网速 / 未联网 / 代理 / 配置，再对症查案例。
