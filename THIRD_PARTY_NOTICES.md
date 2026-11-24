# 第三方声明（THIRD_PARTY NOTICES）

本仓库的源代码（Python / PowerShell / HTML / Markdown）为 PowerFocus 项目原创，
以 Apache License 2.0 发布（见 [LICENSE](LICENSE)）。

**源码仓库不包含任何第三方二进制文件。**但「源码仓库」与「单文件 exe」是两种不同的分发形态，
必须分开说明：

- **源码仓库**：只含本项目原创代码与其许可证，不含任何第三方二进制。
- **Release 的单文件 exe**：由 PyInstaller 打包，内部**确实包含** CPython 运行时与
  `requirements.lock.txt` 所列、以及打包脚本实际收集的第三方 Python 包（含 `pywebview`）。
  它们各自保留原许可与版权声明，完整清单见下文第二节；`LICENSE`、本文件、`LICENSES/`
  逐包全文与 `SBOM.cdx.json` 作为独立附件随每个 Release 一同提供。
- 下文第一节的组件（KVRT / 卡巴斯基在线安装器 / Node.js）**既不入仓库、也不进 exe**，
  由应用在用户明确同意后从官方源下载到用户本机。

> 更正记录（2026-11-14，开源合规审查）：本文件此前称「任何第三方程序都不随本项目打包产物分发」，
> 与打包 spec 中 `collect_all('uvicorn' / 'webview' / 'pythonnet' / 'clr_loader')` 的事实不符，
> 也导致原第二节只列 7 个组件、遗漏 lock 中的 37 个包。2026-11-24 又补入 lock 未列、
> 但打包实际收集的 `pywebview`，总数为 38。现按 Apache-2.0 §4(a)(c)
> 及各依赖许可「分发时保留版权与许可声明」的要求如实更正。

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

## 二、单文件 exe 内含的第三方依赖（随 Release 分发）

### 2.1 平台级组件

| 组件 | 许可 | 本项目使用方式 |
|---|---|---|
| CPython 3.13 | Python Software Foundation License 2.0（PSF-2.0） | PyInstaller 内嵌的 Python 运行时 |
| Microsoft Edge WebView2 Runtime | 专有（Microsoft 免费分发的系统组件） | 前端渲染内核；系统级组件，本项目不重分发 |
| PowerShell 7（pwsh） | MIT License | 调度内核运行时；需用户本机已安装，不随 exe 分发 |
| FastAPI | MIT License | HTTP API 框架 |
| uvicorn | BSD 3-Clause License | ASGI 服务器 |
| httpx | BSD 3-Clause License | HTTP 客户端（模型通道 / 下载） |
| psutil | BSD 3-Clause License | 进程 / 系统信息读取 |
| pywebview | BSD 3-Clause License | 桌面窗口容器（承载 WebView2） |

### 2.2 Python 包全量清单（38 项）

下表为本机 `.venv` 中 `importlib.metadata` 的实测结果，覆盖 `requirements.lock.txt` 的 37 项，
并补入 lock 未列、但打包脚本实际收集的 `pywebview`。逐包许可证全文、来源与 SHA256
见 [`LICENSES/`](LICENSES/README.md)，机器可读清单见 [`SBOM.cdx.json`](SBOM.cdx.json)。

> 版本口径：本表按**本机实际打包环境**记录。当前 `.venv` 与 `requirements.lock.txt` 有 5 处
> 版本漂移（annotated-doc / click / fastapi / pyinstaller-hooks-contrib / ruff），
> 已在 `LICENSES/README.md` 如实列出；重新打包前应先对齐环境，不能用 lock 的理想版本冒充产物版本。

| 包 | 版本 | 许可证 |
|---|---|---|
| altgraph | 0.17.5 | MIT |
| annotated-doc | 0.0.5 | MIT |
| annotated-types | 0.8.0 | MIT |
| anyio | 4.16.0 | MIT |
| bottle | 0.13.4 | MIT |
| certifi | 2026.10.23 | MPL-2.0 |
| cffi | 2.1.1 | MIT-0 |
| click | 8.5.0 | BSD-3-Clause |
| clr_loader | 0.3.1 | MIT |
| colorama | 0.4.6 | BSD-3-Clause |
| fastapi | 0.162.0 | MIT |
| h11 | 0.16.0 | MIT |
| httpcore | 1.0.9 | BSD-3-Clause |
| httpx | 0.28.1 | BSD-3-Clause |
| idna | 3.20 | BSD-3-Clause |
| iniconfig | 2.3.1 | MIT |
| opentelemetry-api | 1.45.2 | Apache-2.0 |
| packaging | 26.3 | Apache-2.0 OR BSD-2-Clause |
| pefile | 2024.8.26 | MIT |
| pluggy | 1.7.0 | MIT |
| proxy_tools | 0.1.0 | BSD-2-Clause（PyPI 元数据误写 MIT，以上游 LICENSE 正文为准） |
| psutil | 7.2.2 | BSD-3-Clause |
| pycparser | 3.12 | BSD-3-Clause |
| pydantic | 2.14.2 | MIT |
| pydantic_core | 2.50.2 | MIT |
| Pygments | 2.21.0 | BSD-2-Clause |
| pyinstaller | 6.22.3 | GPL-2.0-or-later WITH Bootloader-exception（见第三节） |
| pyinstaller-hooks-contrib | 2026.9 | Apache-2.0 |
| pytest | 9.2.0 | MIT |
| pythonnet | 3.2.1 | MIT |
| pywebview | 6.2.1 | BSD-3-Clause |
| pywin32-ctypes | 0.2.3 | BSD-3-Clause |
| ruff | 0.17.3 | MIT |
| setuptools | 84.2.1 | MIT |
| starlette | 1.10.0 | BSD-3-Clause |
| typing-inspection | 0.4.5 | MIT |
| typing_extensions | 4.16.0 | PSF-2.0 |
| uvicorn | 0.54.0 | BSD-3-Clause |

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
