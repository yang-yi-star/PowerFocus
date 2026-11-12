# 第三方声明（THIRD_PARTY NOTICES）

本仓库的源代码（Python / PowerShell / HTML / Markdown）为 PowerFocus 项目原创，
以 Apache License 2.0 发布（见 [LICENSE](LICENSE)）。

**本仓库不包含任何第三方二进制文件。**下文所列的第三方软件要么是本项目的运行/构建依赖
（由用户按各组件自己的许可获取），要么由应用在用户明确同意后从官方源下载到用户本机——
任何第三方程序都不随本仓库、也不随本项目打包产物分发。

---

## 一、由应用按需下载的第三方组件（不随仓库 / 安装包分发）

### 卡巴斯基病毒移除工具（Kaspersky Virus Removal Tool，KVRT）

- **性质**：卡巴斯基实验室（AO Kaspersky Lab）的专有免费软件，非开源。
- **许可**：Kaspersky End User License Agreement（EULA，support.kaspersky.com/8530）。
- **本项目使用方式**：仅当用户在界面明确同意后，应用从卡巴斯基官方分发点下载 KVRT
  至应用自身数据目录，进行官方签名链（Authenticode / WinVerifyTrust）与 SHA256 校验，
  然后调用其扫描功能并解析其官方报告。
- **合规边界（依据 EULA 条款）**：
  - EULA **5.4**：不得为配合非卡巴斯基合法财产的商业软件产品而分发本软件
    → 本项目**不预置、不随安装包、不随仓库**分发 KVRT，只提供「用户同意后从官方源下载」的能力；
  - EULA **5.3**：不得用本软件创建用于检测、拦截或处理威胁的其他软件
    → 本项目只做「下载 + 校验 + 调用 + 收报告」，不拆解引擎、不做二次封装、不重打包；
  - EULA **6.4**：本软件不用于长期持续防护 → 本项目如实呈现其为一次性扫描清除工具，
    无实时防护能力，扫描结果仅供参考。
- **免责**：本项目与卡巴斯基无任何隶属、合作或背书关系。KVRT 本身的 EULA 由用户
  在使用该工具时自行接受；本项目不代替用户接受卡巴斯基的任何协议。

### 卡巴斯基完整版安装器（Kaspersky Free / Kaspersky for Windows 在线安装器）

- **性质**：卡巴斯基专有软件的官方在线安装器（约数 MB，运行后由其自行下载完整包）。
- **许可**：卡巴斯基 EULA 与隐私政策，由用户本人在官方安装向导中接受。
- **本项目使用方式**：应用**只下载并验签**（HTTPS + 官方域名 + 官方签名链 + SHA256），
  之后启动官方安装向导**需用户第二次明确同意**，且只传可执行路径、不带任何静默参数。
  应用绝不代替用户接受 EULA、绝不静默安装、不写任何系统驱动或服务。
  EULA / 隐私政策 / KSN / 账号激活全部由用户本人在向导中完成。

### Node.js

- **性质**：OpenJS Foundation 的 JavaScript 运行时。
- **许可**：MIT License（nodejs.org 随附 LICENSE 文件）。
- **本项目使用方式**：目前仅作为开发 / 构建工具（非客户机运行时依赖）。当用户主动点击
  「补齐组件」后，应用从 nodejs.org 官方源下载锁定版本（版本号 + 官方 SHASUMS256 清单
  哈希 + 锁定 SHA256 双重校验）的官方 zip 包，解包到应用自身目录，**不修改系统 PATH**、
  不写注册表、不需要管理员权限。

---

## 二、运行时依赖（从源码运行时由用户自行安装，不随仓库分发）

| 组件 | 许可 | 来源 | 本项目使用方式 |
|---|---|---|---|
| Python 3.13+ | Python Software Foundation License 2.0（PSF-2.0） | python.org | 后端运行时 |
| FastAPI | MIT License | pypi.org/project/fastapi | HTTP API 框架 |
| uvicorn | BSD 3-Clause License | pypi.org/project/uvicorn | ASGI 服务器 |
| httpx | BSD 3-Clause License | pypi.org/project/httpx | HTTP 客户端（模型通道 / 下载） |
| psutil | BSD 3-Clause License | pypi.org/project/psutil | 进程 / 系统信息读取 |
| pywebview | BSD 3-Clause License | pypi.org/project/pywebview | 桌面窗口容器（承载 WebView2） |
| PowerShell 7（pwsh） | MIT License | github.com/PowerShell/PowerShell | 调度内核运行时 |
| Microsoft Edge WebView2 Runtime | 专有（Microsoft 免费分发系统组件） | Microsoft 官方 | 前端渲染内核；系统级组件，本项目不重分发 |

## 三、构建工具（仅开发时使用，不进入运行产物）

| 组件 | 许可 | 本项目使用方式 |
|---|---|---|
| PyInstaller | GPL-2.0-or-later **WITH Bootloader-exception** | 仅用于把源码打包成 exe。依其官方许可条款，bootloader 例外允许打包产物以任意许可分发；本项目不对 PyInstaller 本体做任何修改或再分发 |
| pytest | MIT License | 本地测试 |
| ruff | MIT License | 本地代码检查 |

## 四、仅做接口适配、不分发、不修改的第三方安全软件

应用的多引擎适配层可识别本机已安装的安全软件（Microsoft Defender、卡巴斯基 KES、
ESET 等）并按各厂商公开文档构造命令行。这些软件：

- 均为本机用户自行安装的第三方软件，本项目不下载、不分发、不修改其任何文件；
- 「识别 ≠ 可调用」，未经实测的引擎默认拒绝执行；
- 调用时遵循各厂商公开命令行文档，且默认只报告、不处置（不删除用户文件）。

---

**商标声明**：Kaspersky、Node.js、Python、Microsoft、Windows、Edge 等名称为各自
所有者的商标，此处引用仅用于描述性说明，不构成任何权利主张。

若您认为本声明有遗漏或错误，欢迎按 [CONTRIBUTING.md](CONTRIBUTING.md) 提交 Issue 更正。
