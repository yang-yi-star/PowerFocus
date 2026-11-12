# 贡献指南（CONTRIBUTING）

感谢关注 PowerFocus · 电脑算力调度中心！欢迎以 Issue、文档修正、代码修复等形式参与。
开始之前，请先花几分钟读完本文件。

## 行为准则

参与本项目（包括 Issue、PR、评论区）即表示同意遵守
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。违反者将被限制参与。

## 我可以贡献什么

- **Bug 报告**：调度行为与预期不符、进程恢复不正确、扫描链路报错等。
- **文档**：README / 使用说明的错漏、第三方声明补充、翻译。
- **代码**：修复缺陷、内核与桌面端的小型改进、多引擎适配层的引擎验证。
- **测试证据**：在您的机器上实测某个引擎或场景并附上输出，非常有价值。

暂不接受的功能方向：超频、驱动 / 内核级改动、绕过 Windows 安全机制的能力、
实时杀毒防护（本项目扫描能力定位是一次性检测参考，详见 README 免责声明）。

## 提交 Issue

请包含：

1. 系统版本（Windows 10 / 11）、运行方式（源码 / exe）；
2. 复现步骤与预期 / 实际行为；
3. 日志：`%LOCALAPPDATA%\PowerFocus\logs\` 下相关日志片段（**先自行脱敏**，删去令牌、路径中的用户名等隐私信息）；
4. 若涉及安全扫描：KVRT 的官方 stdout 或报告摘要，不要粘贴完整报告。

## 开发环境

- Windows 10 / 11，Python 3.13+，PowerShell 7（pwsh）。
- 后端依赖：`pip install fastapi uvicorn httpx psutil pywebview`。
- 本地工具链：`pip install pytest ruff`（配置见根目录 `pyproject.toml`）。

```powershell
# 运行测试（仓库根目录）
pytest

# 代码检查（仅查未定义名 / 未使用导入 / 语法错误，不强制重排风格）
ruff check
```

## 代码约定

- **不覆盖历史**：内核按 `versions/` 目录分版本派生（见 `versions/VERSIONING.md` 与
  `versions/new-version.ps1`），不要直接修改历史版本目录里的文件；
  修复请在最新版本目录（或 product/v1.00）中进行。
- **安全边界不可回退**：仅回环监听、令牌鉴权、白名单动作、破坏性操作二次确认、
  用户同意令牌（`USER_APPROVED_DOWNLOAD` / `USER_APPROVED_SYSTEM_INSTALL`）机制
  是项目的安全基线，PR 不得移除或弱化；若您认为某处设计不当，请先开 Issue 讨论。
- **第三方组件纪律**：不得把任何第三方二进制提交进仓库；下载 / 验签逻辑只从官方源获取，
  不得引入镜像站或捆绑重分发（详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)）。
- PowerShell 侧遵循既有命名风格；Python 侧遵循 `ruff check` 现行规则。
- 每次实质变更请同步更新根目录 `DEVELOPMENT_LOG.md`（追加式日志）。

## 提交 Pull Request

1. Fork / 建分支（命名建议 `fix/xxx` 或 `docs/xxx`）。
2. 一个 PR 聚焦一件事；大改动请先开 Issue 对齐方向。
3. 确保本地 `pytest` 与 `ruff check` 通过。
4. PR 描述写清：动机、改动点、验证方式（附实测输出截图 / 文本更佳）。
5. 若改动触及安全模型（监听、鉴权、令牌、白名单、下载验签），请在描述中显式说明。

## 许可

提交到本项目的贡献，除非显式声明，均按 [LICENSE](LICENSE)（Apache License 2.0）授权。
