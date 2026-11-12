# 电脑算力调度中心 · 版本管理规范

## 一、版本基准

- **v0.05 是首个可正式投入实际使用的标志性版本**，作为正式版本体系的起点。
- 自 v0.05 起，**每一次迭代都按正式版本管理**：必须建目录、必须有清单、必须能独立部署与回滚。
- v0.05 之前的版本（`v1`、`v2`、`v3` 早期目录）视为**历史遗产**，冻结归档，不再修改。

## 二、目录约定

```
E:\PowerFocus\
├── versions\                      ← 正式版本唯一存放位置
│   ├── VERSIONING.md              ← 本规范
│   ├── new-version.ps1            ← 版本创建工具
│   ├── v0.05\                     ← 一个版本 = 一个文件夹
│   │   ├── MANIFEST.json          ← 版本清单（必填）
│   │   ├── 电脑算力调度中心_v0.05.ps1
│   │   ├── lib\
│   │   ├── rules.json / scenes.json / models-preset.ini / model-profiles.json
│   │   ├── logs\                  ← 本版本专属
│   │   └── commands\{in,out,done}\
│   └── v0.06\                     ← 下一个版本，与 v0.05 完全并列
├── v3\                            ← 已归档（2026-11-05 移至 archive\v3-legacy-20261105-032012）
├── lib\ / tools\ / tests\         ← 跨版本共享的通用工具（非版本资产）
└── archive\                       ← 已退役版本（v3-legacy-*、legacy-lib-* 等）
```

### 已完成隔离实例

| 版本 | 目录 | stage | 说明 |
|---|---|---|---|
| v0.05 | `versions\v0.05\` | stable | 首个正式版基线，保留可回滚 |
| v0.06 | `versions\v0.06\` | stable | v0.05 派生，新增 `mem_guard` 命令总线动作 |
| v0.07 | `versions\v0.07\` | stable | v0.06 派生，主程序启动时自动拉起 MemGuard 守护 |
| v0.08 | `versions\v0.08\` | stable | v0.07 派生，修正内存修剪释放量统计（异步回读）、补全优先级别英文识别 |

### 产品线（桌面端）

内核（`versions\`）负责特权执行；产品（`product\`）负责界面与交互，两条线各自独立编号。

| 产品版本 | 目录 | 依赖内核 | 说明 |
|---|---|---|---|
| v1.00 | `product\v1.00\` | ≥ v0.08 | 首个产品版：桌面窗口 + 对话 + 核心调度闭环，单文件 exe |

内核版本指针：`versions\current.json`（当前指向 `v0.08`）。产品启动时按该指针定位内核，指针不存在时自动取 `stage=stable` 的最高版本。

### 硬性规则

1. **文件夹名必须包含完整版本号**：`v0.05`、`v0.06`、`v1.0`，禁止 `latest`、`new`、`temp`。
2. **一个版本一个目录**，版本内所有脚本、配置、日志、状态、命令总线**全部落在该目录内**。
3. **禁止跨版本读写**：新版本不得指向旧版本的日志/状态/配置；脚本内所有路径必须基于 `$PSScriptRoot`。
4. **禁止原地修改已发布版本**：`stage` 为 `stable` 后只允许修数据文件，代码变更必须开新版本目录。
5. **共享能力走 `E:\PowerFocus\lib\`**（如通用工具），但**被版本使用的副本必须复制进该版本目录**，保证该版本目录可单独拷走运行。
6. **回滚 = 切目录**：任何时刻只需停掉当前版本进程、启动目标版本目录的入口脚本。

## 三、MANIFEST.json 必填字段

| 字段 | 说明 |
|---|---|
| `version` / `version_label` | 版本号（`0.05` / `v0.05`） |
| `build_date` | 构建日期 |
| `stage` | `dev` / `beta` / `stable` |
| `entry` | 入口脚本文件名 |
| `lineage` | 来源版本 |
| `components` / `configs` | 组件与配置清单 |
| `runtime_isolated` | 该版本独占的运行时文件/目录 |

## 四、版本号规则

- 格式 `0.XX`，两位小数递增：`0.05 → 0.06 → 0.07 …`，到 `1.00` 转正式主版本。
- 每次创建新版本必须同时更新：目录名、入口脚本文件名、脚本内 `$script:PF_Version`、`MANIFEST.json`。

## 五、创建新版本的标准动作

```powershell
pwsh -File "E:\PowerFocus\versions\new-version.ps1" -From v0.05 -To v0.06 -Title "内存管理模块集成"
```

工具会自动：
1. 复制上一版本的组件与配置（**不带日志、状态、命令历史**）
2. 重命名入口脚本为新版本号
3. 改写脚本内版本标识
4. 生成新的 `MANIFEST.json`
5. 清空运行时目录，保证新版本从干净状态启动

## 六、运行与切换

```powershell
# 启动某版本
pwsh -File "E:\PowerFocus\versions\v0.05\电脑算力调度中心_v0.05.ps1"

# 查看当前运行的版本
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
  Where-Object { $_.CommandLine -match 'versions\\v' } |
  Select-Object ProcessId, CommandLine
```

单实例锁为 `$PSScriptRoot\.v3.lock`，**每个版本各一把锁**，因此不同版本可以并行存在（但同一时刻建议只运行一个，避免优先级争夺）。
