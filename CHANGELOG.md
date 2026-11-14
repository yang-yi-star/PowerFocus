# 更新日志（Changelog）

本项目所有重要变更将记录在此文件中。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号语义遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

> 本项目存在两条版本线：**调度内核**（`versions/`，0.x 线）与**桌面端产品**
> （`product/`，1.x 线），两者独立演进，各自记录。
> 逐轮开发细节见根目录 `DEVELOPMENT_LOG.md`（append-only 权威开发日志）。

## [Unreleased]

### 变更（2026-11-14 · 界面 v3）

- **「暖木工作台」视觉系统**：深浅双主题 token 化（94 个 `--pf-*` 变量），顶栏一键切换并持久化；浅色暖米白 `#FAF6F0`、深色 hue 32° 暖棕灰 `#221E19`、陶土橙单一强调色。
- **无障碍**：全部文字与状态色经 WCAG 2.1 AA 双人独立计算校验；状态色拆「图形轨 3:1 / 文字轨 4.5:1」，焦点环改 2px 实色 accent。
- **清退 v2 违规项**：渐变 logo、紫色第二强调色、10px 小字、无限呼吸动画。
- 新增 `design-tokens.css` / `theme-init.js`；`style.css` 全量改为 token 引用，类名体系不变，前端逻辑零结构改动。
- 重新打包 `dist/电脑算力调度中心.exe`（20,442,721 字节，SHA256 `543c429ad225e07d6ec434ce41981c7e84d1ef65ec51cfe518a52fd5bc530cb8`）；v0.10.0 Release 附件已同步替换，旧版 exe 仅留本地备份（`dist-v3/`，不入库）。
- 设计系统规范与实机截图归档于 `docs/design-v3/`、`marketing/v3_live_*.png`。

### 已知待办（如实列出，避免误判完成度）

- 应用内每日自动扫描调度器（`run_scheduled_loop()`）已实现，但尚未随主进程常驻启动。
- 前端「立即扫描」按钮仍是模拟进度条，真实扫描走 CLI / 后端路由。
- 部分安全态势 API 仍为接口契约占位，未在后端实装。
- KVRT 下载源为 `latest` 直链（未锁定具体版本）；Node.js 已锁定版本 + SHA256。

## 桌面端产品（product/v1.00）

### [1.00.0] - 2026-11-13

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

## 调度内核（versions/）

### [0.10.0] - 2026-11-13

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

### [0.09.0] 及更早

见 `versions/` 各版本目录内的 `README.md` / `MANIFEST.json`，以及根目录
`DEVELOPMENT_LOG.md` 对应日期条目（2026-11-03 起）。

[Unreleased]: #unreleased
[1.00.0]: https://github.com/yang-yi-star/PowerFocus/releases/tag/v1.00.0
[0.10.0]: https://github.com/yang-yi-star/PowerFocus/releases/tag/v0.10.0

<!-- 仓库：yang-yi-star/PowerFocus（2026-11-13 上线） -->
