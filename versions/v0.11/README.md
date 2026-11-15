# v0.11 —— 统一对接基线

> 派生自 `v0.10`，`stage=dev`。本目录为 v0.10 的完整代码快照 + 版本规范补齐，**未切 `current.json`**，生产内核仍为 `v0.09`。

## 一、本版做了什么

| 项 | 说明 |
|---|---|
| 版本元数据 | `$script:PF_Version='0.11'`、`PF_VersionLabel='v0.11'`、`PF_BuildDate='2026-11-15'` |
| 入口脚本 | `电脑算力调度中心_v0.11.ps1`（103.8 KB，与 v0.10 逻辑一致，仅改版本标识） |
| Python 组件 | `kvrt_bundle.py` / `security_scan.py` / `engine_adapters.py` / `dependency_bootstrap.py` 全部带入 |
| prototype | `prototype/index.html` 带入 |
| 编码 | 全部 `.ps1` 为 **UTF-8 with BOM**，`Parser::ParseFile` 校验 **0 错误** |
| MANIFEST | 重新生成，`lineage=v0.10`，`stage=dev` |

## 二、本版没有带什么，为什么

**没有 `engines\`。**

运行时引擎路径由 `app_paths.data_root()/engines` 决定，即
`%LOCALAPPDATA%\PowerFocus\<DATA_SLOT>\engines`，
**不读版本目录下的 `engines\`**。

v0.10 目录内的 `engines\` 有 393.9 MB（旧 KVRT ×2 + Node + node zip），属历史遗留、不参与运行。
复制它只会让每个新版本凭空膨胀 394 MB，因此 `new-version.ps1` 自 2026-11-15 起不再复制。

> 若确实需要在版本目录内保留引擎副本（例如做离线分发），**手工复制**，不要改回工具默认行为。

**没有 `reports\`**：运行时数据，应留在产生它的那个版本目录里作为历史证据（v0.10 保留着
`reports\scan-20261112-131235.json` 这份唯一一次真实全盘扫描成功的报告）。

## 三、运行

```powershell
pwsh -File "E:\PowerFocus\versions\v0.11\电脑算力调度中心_v0.11.ps1"
```

单实例锁为 `$PSScriptRoot\.v3.lock`，每个版本各一把，因此 v0.10 与 v0.11 可并行存在（建议只跑一个）。

## 四、已知的架构不一致（待决，未擅自修改）

`app_paths.py` 中 `DATA_SLOT = "v0.10"` 为**硬编码**，意味着：

- v0.11 的配置、日志、引擎仍写入 `%LOCALAPPDATA%\PowerFocus\v0.10\`
- 即 **v0.11 与 v0.10 共用同一数据槽**

这与"每个版本独立"的策略在**数据层**不一致（代码层已独立）。
改 `DATA_SLOT` 会影响正在运行的 v1.00 产品，故本版未改动，留待明确决策。

## 五、与 v0.10 的关系

| 维度 | v0.10 | v0.11 |
|---|---|---|
| 代码 | 相同 | 相同（仅版本串） |
| 数据槽 | `%LOCALAPPDATA%\PowerFocus\v0.10` | 同上（共用） |
| 引擎 | 运行时读数据槽 | 同上 |
| stage | dev | dev |
| 体积 | 394.6 MB | **0.43 MB** |

v0.11 的"新增"不在代码，而在**规范层面**：
`new-version.ps1` 现在会带走 Python 组件与 prototype、不再复制 engines、并以 UTF-8 BOM 写文件；
`VERSIONING.md` 补齐了 v0.09–v0.11 的版本谱系与数据槽说明。

---

*创建：2026-11-15 | 工具：`versions\new-version.ps1`（本日增强）*
