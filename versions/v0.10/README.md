# v0.10 · 应用内安全扫描能力（最基础原型）

> 由 `versions\new-version.ps1 -From v0.09 -To v0.10` 按《VERSIONING.md》派生，stage = **dev**。
> `versions\current.json` 仍指向 v0.09，本版本**未投入运行、未重打包桌面 exe**，不影响正在使用的应用。

## 本版本新增内容

| 文件 | 说明 |
|---|---|
| `prototype\index.html` | 单文件自包含网页原型，双击即可运行。四页：安全扫描（功能页）/ 扫描报告 / 引擎识别 / 自动扫描设置 |
| `security_scan.py` | 引擎识别、适配器注册表、命令构造、报告数据结构、调度计算、执行安全边界 |
| `MANIFEST.json` | 版本清单，新增 `prototype` 与 `security_scan` 两段元数据 |

## 快速体验

```
双击打开 prototype\index.html

python security_scan.py --discover    # 真实只读识别本机已装安全软件
python security_scan.py --dry-run     # 展示各引擎将执行的命令，不执行
python security_scan.py --settings    # 展示默认配置与下次执行时间
```

`--discover` 是唯一真实访问系统的功能（只读查询 WMI 安全中心，不启停服务、不写注册表）。

## 三条引擎路径

1. **内置引擎**：ClamAV（GPLv2，官方 Windows portable ZIP + `clamscan`）可随安装包分发，客户机无需另装杀毒软件。本原型只有接口占位，**未打包二进制与病毒库**。
2. **卡巴斯基 OEM**：`Kaspersky Scan Engine` / `Anti-Virus SDK v8` 可把品牌引擎嵌入第三方产品，但必须签商业授权取得 SDK 与病毒库分发权。引擎**不能自由再分发**，本版本不伪造内嵌，仅保留接入位。
3. **外部适配器**：检测客户机已装的卡巴斯基 / Defender / 管家类，按官方命令行调用；未查到公开 CLI 的产品只识别、只引导，不臆造命令。

命令依据：Kaspersky 官方支持中心 `avp.com SCAN /RA:<报告> /MEMORY /STARTUP <路径>`；Microsoft Learn `MpCmdRun.exe -Scan -ScanType 1|2|3`；ClamAV 官方 README `clamscan`。

## 硬边界（务必遵守）

- **所有扫描过程与报告都是模拟数据**，报告结构强制带 `simulated: true`，界面每份报告有「模拟」徽章。不得把原型结果当作真实安全结论。
- `run_scan()` 默认返回 dry-run；显式 `allow_execute=True` 也直接抛 `NotImplementedError`。原型阶段禁止拉起整机扫描。
- **不注册系统计划任务、不写系统目录、不修改系统安全设置**。每日自动扫描设计为应用内定时器。
- 9 条 `/api/security/*` 是接口契约占位，`server.py` 尚未实装。
- 不同电脑的系统代码页不同：识别输出已做 UTF-8 强制 + UTF-8/GBK 双解码兜底。

## 完整设计与验证记录

`E:\AI 调度中心\V0.10_应用内安全扫描原型_2026-11-12.md`

内含需求逐条对照、本机实测事实、架构、接口契约、标注体系、验证结果、下一步落地顺序与风险边界。
