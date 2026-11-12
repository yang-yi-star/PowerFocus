# v0.10 · 应用内安全扫描能力（真实链路已跑通）

> 由 `versions\new-version.ps1 -From v0.09 -To v0.10` 按《VERSIONING.md》派生，stage = **dev**。
> `versions\current.json` 仍指向 v0.09，本版本**未切换生产指针、未重打包桌面 exe**，不影响正在使用的应用。

## 一句话现状

**卡巴斯基 KVRT 引擎由应用自己下载、纯 Python 验签、真实调用，跑完一次真实扫描并产出官方报告。**
不是模拟：2026-11-12 13:12 真实扫描 **6,943 个对象**，`Processed=6943 / Detected=0 / Found=0`，退出码 0。

## 本版本文件

| 文件 | 说明 |
|---|---|
| `kvrt_bundle.py` | **应用内真实链路**：官方源下载 / WinVerifyTrust 验签 / 真实扫描 / 官方报告解析 / 报告落盘 / 应用内每日调度 |
| `prototype\index.html` | 单文件自包含网页原型，四页：安全扫描 / 扫描报告 / 引擎识别 / 自动扫描设置。**内嵌真实报告与真实引擎状态的只读快照**，首份报告标「实测」，其余标「模拟」 |
| `security_scan.py` | 引擎识别（WMI SecurityCenter2）、适配器注册表、命令构造、报告数据结构；原型阶段不执行 |
| `engines\KVRT\KVRT.exe` | 用户主动从官方源下载到**应用自己的目录**的引擎（122,445,696 B / 20.0.14.0）。**不入库、不随安装包分发** |
| `engines\KVRT\engine.json` | 验签记录（签名链、厂商、版本、SHA256） |
| `reports\scan-20261112-131235.json` | 真实扫描报告（校准版）；原版留档为 `.json.bak` |
| `reports\KVRT_Data\Reports\*.klr.enc1` | KVRT 官方报告，XOR 0xEF 编码的 XML |
| `scan_settings.json` | 应用内自动扫描配置（开关 / 频率 / 引擎 / 范围 / 处置级别） |
| `MANIFEST.json` | 版本清单，含 `prototype` / `security_scan` / `kvrt_real` 元数据 |

## 快速使用

```
双击打开 prototype\index.html            # 看真实报告与设置页（自包含、不联网）

python kvrt_bundle.py --status            # 引擎真实状态 + 验签记录
python kvrt_bundle.py --verify            # 纯 Python 验签（零外部进程）
python kvrt_bundle.py --scan --path <目录>   # 应用内真实扫描并出报告
python kvrt_bundle.py --scan --allvolumes   # 整机全盘真实扫描
python kvrt_bundle.py --reports           # 列出真实报告
python kvrt_bundle.py --settings          # 查看自动扫描配置与下次执行时间
python kvrt_bundle.py --download --verify # 首次：从官方源下载并验签
python security_scan.py --discover       # 真实只读识别本机已装安全软件
```

`--download` 只从卡巴斯基官方分发点 `devbuilds.s.kaspersky-labs.com/devbuilds/KVRT/latest/full/KVRT.exe` 取文件，
落到应用自身目录，不写系统目录、不注册服务、不预置进安装包。

## 关键实测结论（不要重复踩）

1. **官方文档版本要对齐内核**：`support.kaspersky.com/.../269475` 是 KVRT **2026** 文档；下载到的 `latest/full/KVRT.exe` 实际是 **20.0.14.0 / KVRT2020 内核**。
2. **`-customonly` 在 KVRT2020 不被识别**，一旦传入就弹 `KVRT2020 - Command line arguments help` 窗口挂起（首次真跑因此 24 分钟零产出、退出码 -1）。实测可用组合只有：
   `KVRT.exe -accepteula -silent -d <数据目录> -custom <反斜杠路径>`；`-allvolumes` 也已单独复核可用。
3. **`-d <folder_path>` 是空格分隔的两个参数**，连写成 `-dE:\...` 也会触发帮助窗口。
4. **报告是 XOR 0xEF 编码的 XML**：`.klr.enc1` 解出 `<Block0 Type="Scan" Processed="6943" Found="0" Neutralized="0">`。
5. **威胁数必须取官方字段**，不能用「日志里出现 detected 字样」来数——旧解析器把 `Detected: 0` 误报成 1 条威胁，已按官方 stdout 与 XML 校准为 0。
6. KVRT 有单实例锁，并发启动会直接退出；应用调度器一次只跑一个作业。
7. 验签不依赖任何外部解释器：`ctypes` 直调 `WinVerifyTrust` + Version API + SHA256，避免命令行工具在受限环境被拦截。

## 许可边界（KVRT EULA，support.kaspersky.com/8530）

- **5.4** 不得为配合非卡巴斯基合法财产的商业软件产品而分发本软件 → 应用**不预置、不随包**，只在用户主动触发时下载到自身目录。
- **5.3** 不得用本软件创建用于检测/拦截/处理威胁的其他软件 → 只做「下载 + 校验 + 调用 + 收报告」，不拆引擎、不做二次封装。
- **6.4** 本软件不用于长期持续防护 → 它是一次性扫描清除工具，**没有实时防护**；需联网更新病毒库、需管理员权限。
- 默认 `-processlevel` 不传，即**只报告、不删文件**。
- 若要「品牌就是卡巴斯基且随包内嵌」，须走 `Kaspersky Scan Engine` / `Anti-Virus SDK v8` 的 OEM 商业授权，本版本不伪造。

## 多引擎适配层（2026-11-12 新增 · `engine_adapters.py`）

**本轮路线**：识别并调用不同电脑上已安装的各类杀毒/安全软件，设置页可选「内置能力 / 已识别引擎」并真实执行，全部作为应用内部功能。

### 本机真实探测结论（`python engine_adapters.py --list`）

| 引擎 | 来源 | 官方文档 | 本机实测 | 判定 |
| --- | --- | --- | --- | --- |
| KVRT | 应用内下载 | KVRT 269475 | 真扫 6,943 对象 / 检出 0 | **ready（唯一可调用）** |
| Microsoft Defender | Windows 组件 | Microsoft Learn | `-?` rc=0；真跑 `-Scan` 返回 `hr=0x800106ba` | service_disabled |
| Kaspersky KES | 外部已装 | 181236 | 未安装、未实测 | not_installed（拒绝执行） |
| ESET ecls.exe | 外部已装 | ESET 官方参数文档 | 未安装、未实测 | not_installed（拒绝执行） |
| 腾讯电脑管家 | 外部已装 | 无公开 CLI | WMI 已注册但安装目录不存在 | stale_registration |
| 360 / 火绒 / 其他 | 外部已装 | 无 Windows 公开 CLI | 未识别 | guide |

WMI `root\SecurityCenter2\AntiVirusProduct` 本机只返回 2 条：腾讯管家（登记路径是卸载残留）、Defender（`signed_exe` 是 `windowsdefender://`，不是可执行路径）。
**结论：识别 ≠ 可调用**，`available` 一律以「真实路径 + 服务状态 + 验签结果」判定，不按产品名猜。

### 由实证反推出的三条硬约束

1. **WMI 路径必须校验存在性**：腾讯管家登记 `...\QQPCMgr\18.2.30648.204\QQPCMgr.exe`，但 `C:\Program Files (x86)\Tencent\QQPCMgr` 整个目录不存在，属卸载后残留注册项。
2. **只报告不处置**：卡巴 KES 的 `avp.com SCAN` 默认是 `/i2`（清除失败即删除文件），必须显式 `/i0`（仅通知）；Defender 的 `-DisableRemediation` 官方注明**仅自定义扫描(-ScanType 3)有效**，因此不开放全盘/快速扫描；ESET 用 `/clean-mode=none`；KVRT 不传 `-processlevel`。
3. **未实测不许真跑**：KES / ESET 只有官方文档核对、本机未安装，`run_engine()` 默认拒绝执行，需显式 `--allow-unverified`；引导型引擎（管家/360/火绒）不产生扫描作业、不谎报结果。

### 统一接口与调用边界

`registry()` 返回 8 个适配器，均实现 `probe() / build_command() / parse() / run()`；上层业务只构造 `ScanRequest`，切换引擎不改业务代码。`run_engine(engine_id, req)` 是应用内统一入口，可由 `server.py` 路由或应用主进程直接 import。真实报告写入 `reports/scan-<时间戳>-<引擎>.json`，字段与 `kvrt_bundle.py` 报告兼容，`list_reports()` 可一起读。

安全边界：不改系统服务状态、不注册系统计划任务、不写系统目录；`scope=custom` 未提供 `--path` 时拒绝执行（防止悄悄退化成整机扫描）；原型 CLI 默认 dry-run，真实执行必须显式 `--execute`。

CLI：`--list` 引擎清单 / `--discover` WMI 原始识别+路径校验 / `--dry-run` 命令预览 / `--scan --execute` 真跑 / `--reports` 报告列表。

### 前端接入

`prototype/index.html` 内嵌 `ENGINE_MATRIX` 与 `PROBE_FACTS` 只读实测快照：引擎页新增「多引擎可调用性矩阵」与「真实探测证据与处置边界」两块面板；设置页按 `available` 禁用不可选引擎并显示 `reason_code`，`activeEngine()` 改为以矩阵为准。同时修正了旧版界面上会删文件的 `avp.com SCAN /RA:` 与已不开放的 `-ScanType 2` 展示。

## 仍是原型/未完成的部分

- 网页上的「立即扫描」按钮仍是**模拟进度条**，不会执行真实引擎；真实调用走 `kvrt_bundle.py`（或后续 `server.py` 路由）。
- 9 条 `/api/security/*` 仍是接口契约占位，`server.py` 未实装。
- 应用内调度器 `run_scheduled_loop()` 已实现但**未随应用主进程常驻启动**；需接入 v1.00 服务后才能真正「每天 03:00 自动扫」。
- 整机全盘扫描耗时远大于本次小范围扫描（本次 366 秒 / 6,943 对象），调度需考虑超时与 CPU 时段。
- ClamAV 随包与 GPLv2 合规、卡巴斯基 OEM、多机适配器逐台验证均未完成。
- `current.json` 仍为 v0.09；stage 转 stable 后才切指针、重打包 exe、接入七页导航。

## 完整设计与验证记录

- `E:\AI 调度中心\V0.10_应用内安全扫描原型_2026-11-12.md`（基础原型设计契约）
- `E:\AI 调度中心\V0.10_真实KVRT链路_2026-11-12.md`（本轮真实链路实证与校准记录）
- `E:\AI 调度中心\.screenshots\v010-real.png` / `v010-real-reports.png`（无头浏览器实渲染证据）
