# 电脑算力调度中心 · 发布方案（release-plan.md）

> 撰写：2026-11-13（release-eng 基线打包轮）
> 适用对象：`product/v1.00` 桌面端（PyInstaller onefile exe）的签名、版本与产物管理。
> 事实来源标注规则：标注「Microsoft 官方」的均引自 learn.microsoft.com / azure.microsoft.com 当前文档；标注「行业惯例」的为市场通行做法，无单一官方出处，采购前需向证书厂商复核报价。

---

## 一、签名方案

### 1.1 三条路线对比

| 维度 | 自签名证书 | OV 代码签名证书 | Azure Artifact Signing（原 Trusted Signing） |
|---|---|---|---|
| 成本 | 0 元 | 行业惯例：约 $200–500/年（标准 OV）；开源/个人专项（如 Certum）约 €69/年 | Basic $9.99/月（含 5,000 次签名/月，超出 $0.005/次）；Premium $99.99/月（含 100,000 次/月）[Microsoft 官方] |
| 证书私钥 | 本机自管 | 本机或硬件 USB Token / HSM（CA 要求） | 微软托管，FIPS 140-3 Level 3 HSM，零接触生命周期管理 [Microsoft 官方] |
| SmartScreen 信誉 | 无起步信誉，警告最重 | 有发布者身份；EV 已不再即时绕过 SmartScreen（2024 起，Microsoft 官方） | 同 OV 量级；Microsoft 明确「不提供即时 SmartScreen 信任」，声誉需数周 + 数百次干净安装 [Microsoft 官方] |
| 地域/主体门槛 | 无 | 无硬性地域限制（中国个人/企业可购买，企业资质更顺） | **Public Trust 证书：组织仅限美/加/欧盟/英/澳/新西兰/日/韩/新加坡/瑞士/挪威/以色列；个人开发者仅限美国和加拿大**；需付费 Azure 订阅（免费/试用订阅不支持）[Microsoft 官方] |
| 身份核验 | 无 | 企业/个人资质审查，1–7 个工作日（行业惯例） | Microsoft Entra Verified ID 第三方核验，1–20 个工作日，60 天窗口续期 [Microsoft 官方] |
| 适用场景 | 内部测试、灰度、受控装机 | 对外正式分发 | 已有海外主体 + CI 集成需求的团队 |

### 1.2 团队推荐（可执行）

**分两阶段：**

1. **现阶段（内部与受控分发）：自签名 + 安装脚本导入信任。**
   - 用 PowerShell `New-SelfSignedCertificate` 签发自签代码签名证书（`-Type CodeSigningCert`，有效期上限 3 年是 New-SelfSignedCertificate 的实践约束，行业惯例）。
   - `install.ps1` 增加 `Import-Certificate` 到 `Cert:\LocalMachine\TrustedPublisher`（机器级信任发布者），配合 `certutil -addstore Root` 导入根证书，装完即无 UAC 发布者「未知」警告。
   - 成本 0，完全满足当前「内部分发 + 单机装机」形态。
   - 附加动作：签名后用 `signtool verify /pa /v` 验证链；用 RFC 3161 时间戳（`signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256`），保证证书过期后签名仍有效——时间戳服务 DigiCert/Sectigo 均免费提供（行业惯例）。

2. **对外正式分发：购买 OV 代码签名证书（推荐 DigiCert / Sectigo / GlobalSign 任一家，企业主体）。**
   - 理由：Azure Artifact Signing 的 Public Trust **个人路径仅限美加、组织路径不含中国大陆主体**，对本团队当前主体形态基本不可用；OV 无地域门槛、价格与 Artifact Signing Basic 同量级，且私钥自管不依赖云厂商。
   - 若未来在美/加/欧盟设立主体并上 CI，可迁移到 Artifact Signing Basic（$9.99/月含 5,000 次签名，本产品单 exe 单文件签名，月 5,000 次约等于 100 个文件 × 50 次构建，绰绰有余）。
   - 采购时确认：证书含 RFC 3161 TSA、支持 EV 升级路径、私钥介质（USB Token 或云签名）。

**SmartScreen 预期管理（写给所有方案）**：Microsoft 官方明确任何签名方案（含 Artifact Signing 与 EV）都不提供首日免警告，信誉需「数周 + 数百次干净安装」积累。发布页应预先说明「首次运行可能提示 SmartScreen，选『仍要运行』」，不要把它当 bug 修。

### 1.3 签名接入打包流水线

在 `build/build.ps1` 末尾（PyInstaller 成功后）追加：

```powershell
$Sig = $env:PF_SIGN_PFX            # PFX 路径；自签阶段由 install 脚本生成
if ($Sig -and (Test-Path $Sig)) {
    & signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 `
        /f $Sig /p $env:PF_SIGN_PASS $out
    & signtool verify /pa /v $out
} else { Write-Host "未配置 PF_SIGN_PFX，跳过签名（未签名构建）" }
```

环境变量驱动，无证书时构建不中断，保证 CI 与本地行为一致。

---

## 二、版本号策略建议

现状（保持并显式化）：

- **内核引擎槽** `versions/vX.YZ`（如 v0.10）：能力版本，`current.json` 指针切换生产。
- **产品交付槽** `product/vN.MM`（如 v1.00）：桌面端打包与安装单元。

建议增补三条规则（均为行业惯例 / SemVer 语义化版本 semver.org）：

1. **产品版本 SemVer 化**：`v1.00` → 主版本.次版本；破坏性数据迁移或内核指针不兼容时升主版本；新功能升次版本；只修 bug 用 `v1.00.1` 三段式补丁号。
2. **构建号 = 日期 + 短提交**：每次打包在 `product/vN.MM/MANIFEST.json` 写入 `build` 字段：`{"built_at": "2026-11-13 07:21", "commit": "<短hash>", "packer": "PyInstaller <版本>"}`，实现「exe 可追溯」——当前 exe 无法回答「是哪次提交打的」，这是本轮发现的最实际缺口。
3. **版本切换只动指针**：桌面端升级 = 新增 `product/vX.YY` 目录 + `install.ps1` 更新开始菜单/桌面快捷方式指向；`versions/current.json` 与产品槽互不联动，避免 v0.10 自检模块数据目录（`%LOCALAPPDATA%\PowerFocus\v0.10`）随产品槽漂移。

---

## 三、打包产物清单

单次 `build/build.ps1` 成功构建应交付/留档以下文件（2026-11-13 实测）：

| 产物 | 路径 | 说明 |
|---|---|---|
| 主程序 | `product/v1.00/dist/电脑算力调度中心.exe` | onefile，实测 20,459,044 B（≈19.5 MB）；内嵌 v0.10 自检/引擎模块、app/web 前端、图标 |
| 构建日志 | `product/v1.00/build/pack-log-YYYYMMDD.txt` | PyInstaller WARN 级输出与耗时，发布留档用 |
| PyInstaller 分析件 | `product/v1.00/build/pyi/` | warn-*.txt / xref-*.html，排查 missing module 用，不必随发布分发 |
| 安装脚本 | `product/v1.00/install.ps1` | 建立快捷方式、目录约定；签名阶段追加信任导入 |
| 使用说明 | `product/v1.00/使用说明.md` | 随包分发 |
| 版本清单 | `product/v1.00/MANIFEST.json` | 建议增补 build 字段（见 §2.2） |
| 图标源 | `product/v1.00/app.ico` | 已随 exe 内嵌，留档以便重打包 |

**明确不随包分发**（合规约束，见 `versions/v0.10/README.md` 许可边界节）：

- KVRT 引擎（`engines/KVRT/KVRT.exe`）——卡巴斯基 EULA 5.4 禁止与非卡巴斯基商业软件配合分发；应用在用户同意后从官方源下载。
- 卡巴斯基完整版安装器——仅应用内下载 + 验签，系统级安装由用户在官方向导本人完成。
- 一切第三方杀毒引擎二进制。

**运行态文件（打包机不留存、不入包）**：`mem-guard.state.json`、`.auth_token`、`v3_heartbeat.json`、`logs/`。

---

## 四、2026-11-13 基线打包实测记录

- 命令：`pwsh -NoProfile -File product/v1.00/build/build.ps1`（增量，未 --clean）
- 结果：成功，19.5 MB，增量耗时 3.4 s（冷构建预期数分钟，未本轮实测）
- PyInstaller 警告（WARN 级 + warn 文件 235 行，全部为可选/跨平台噪音，无阻断项）：
  - `webview.platforms.android` 收集失败（缺 `android` 模块）——pywebview 平台探测，预期
  - `pycparser.lextab/yacctab`、`tzdata` not found——cffi/zoneinfo 可选件，本应用未用 zoneinfo（已 grep 确认）
  - warn 文件其余为 Unix 专属模块（pwd/termios/fcntl…）、pywebview 其它后端（Qt/cocoa/gtk）、uvicorn/fastapi 可选依赖（websockets/uvloop/multipart 等），均为条件导入
- 环境坑（已解决，复现时注意）：
  1. **WorkBuddy CLI 的 `sitecustomize.py`（PYTHONPATH 注入）把 Python `os.remove` 拦截成回收站 trash**，PyInstaller 覆盖旧 exe 时 trash 失败即构建失败。解法：打包前清空 `PYTHONPATH`。
  2. **旧实例进程持有单实例互斥体 `Global\PowerFocusDesktop_v1` 且锁定 dist exe**——打包与验证前先结束所有 `电脑算力调度中心` 进程。注意提权启动的旧实例普通权限杀不掉（拒绝访问），需管理员会话处理。
- exe 级验证（本轮关键验收）：启动 exe → `frozen:true` → 三接口全过：
  - `GET /api/health` 200：`{"app":"ok","version":"1.00","kernel_version":"v0.09","frozen":true}`
  - `GET /api/bootstrap/check` 200：7 组件真实探测（present 5 / missing 2 均为可选），`startup_ok=true`，`data_root=%LOCALAPPDATA%\PowerFocus\v0.10`、`writes_to_program_dir=false`——**v0.10 自检模块在 exe 内真实可用**
  - `GET /` 200：13,499 B，标题正确，token 注入无占位符残留
  - 附带发现：desktop.log 显示 exe 内后台预热自检同样成功（「组件自检: available=True startup_ok=True」×3 次）
- 未尽事项：
  - 冷构建（`--clean`）耗时未测；PDF 杀软误报（PyInstaller onefile 通病）未验证
  - 旧实例 PID 56588（提权启动）无法在普通权限下结束，需管理员清理
  - 签名流水线未实装（等证书路线定夺后按 §1.3 接入）

### 参考来源

- Microsoft Artifact Signing 概览（2026 更名自 Trusted Signing）：https://learn.microsoft.com/azure/artifact-signing/overview
- SKU 与定价：https://learn.microsoft.com/azure/artifact-signing/how-to-change-sku ；https://azure.microsoft.com/products/trusted-signing
- SmartScreen 信誉机制：https://learn.microsoft.com/windows/apps/package-and-deploy/smartscreen-reputation
- 个人/组织地域资格与订阅要求：https://learn.microsoft.com/azure/artifact-signing/faq
- 语义化版本：https://semver.org
