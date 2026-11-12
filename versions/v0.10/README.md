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
