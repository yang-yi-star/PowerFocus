## v0.11.1 — 双专家遗留缺陷清零 + 通用化

按 `docs/VERSION_POLICY.md` 判定为 **PATCH**：无新功能，纯缺陷修复与安全加固。
本版本起项目定位升级为**通用应用**——任何电脑 / 服务器加载即可用，不再是开发机定制品。

### 安全边界（红队 F 编号）

- **F4 命令总线认证**：v0.09 / v0.10 两代内核消费命令前校验内核授权令牌，
  未认证命令回 `ERROR: 命令总线认证失败`；已实测双向（带令牌放行 / 直投无令牌被拒）
- **F7 KVRT 验签 TOCTOU**：执行前同路径重跑 `WinVerifyTrust` + 重算 SHA256，不符即拒跑
- **F8 同意令牌**：删除源码可读常量，改一次性令牌（TTL 120s、scope 绑定、
  用后即焚、错误 scope 直接烧毁）；服务端现场签发并消费，令牌不出服务端
- **F3** `/api/health` 免鉴权但不再免限流；**F10** 写操作由总线层审计总闸统一记录
- **B27** 云端 BASE_URL 强制 loopback / https 白名单，堵 SSRF 与凭据外送

### 质量修复（Bug 猎手 B 编号）

B7 日志轮转与竞态 · B8 连接关闭 · B9 GC 异常 · B11/B12 参数校验 ·
B13 前端按 `_timeout` 放大 HTTP 预算 · B19/B20 句柄与 LastError ·
B21 chunked 按字节 413 · B22 限流器清扫过期桶 · B23 日志目录归一 ·
B26/B28/B29/B30 启动入口、就绪语义与版本槽统一

### 通用化（任何电脑 / 服务器可用）

- 模型预设**三层查找**：`models-preset.local.ini`（本机私有，gitignore）→ 内核目录 local → 内置模板
- **存在性过滤**：启动前按本机文件存在性过滤模型条目，换机后缺失条目自动跳过并提示，
  全部缺失时给出配置指引，而不是让 llama-server 启动失败
- `calibrate-vram.ps1` / spec / build.ps1 全部去绝对路径；全仓扫描零本机盘符残留
- CI：GitHub Actions 改 commit SHA pin

### 验证

`pytest` **104 passed**（新增 15 例回归）；`ruff` 0 错误；`py_compile` 10 目标；
pwsh 7 全仓 `.ps1` 语法 0 错误；新 exe 实机 `frozen=true / kernel_alive=true / ready=true`。

### 附件

- `PowerFocus-v0.11.1-x64.exe` — 20457037 字节，SHA256 `7dd5e1e7923e22378ff0cb1de7e14b7ec9e87eed35591cdc2f1f2ef8ebdf9c0b`（与投稿分发的 `电脑算力调度中心.exe` 为同一构建）
- `PowerFocus-MCP-v0.11.1.zip` — 19970 字节，SHA256 `8da64b985fef87d6cf5dc8858d0f5d95afff5610babeb5263c901400a4daf166`；MCP 独立发行物（含随包 LICENSE，版本对齐 0.11.1），接入见 `mcp/README.md`
- `LICENSE` / `THIRD_PARTY_NOTICES.md` — 发行合规随附

### 仍开放（需产品决策，不假装完成）

F9（系统进程硬闸统一）、F13/F14（CI 供应链与路径 ACL，需先决定签名与构建策略）；
详见 `docs/engineering-audit.md` 5.3 节与第五批排期。
