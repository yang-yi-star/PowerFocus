# PowerFocus 工程审计与优化路线图

- 审计日期：2026-11-14
- 基线：`main = 5d98516`（v0.10.1 发布后）
- 方法：四角色独立审计（架构 / 系统可靠性 / 安全 / 发布工程）+ 主理人逐条复核
- 证据口径：**每条结论必须带 `路径:行号` 或实测命令输出**，无证据不写
- 说明：会话中断导致「系统可靠性」「安全」两路成员未能恢复，其审计由主理人亲自补做并复核；
  架构与发布工程两路由独立审计员完成，主理人对关键结论做了二次实算/实读确认。

---

## 1. 重新审视：这个应用实际在做什么

名义定位是「电脑算力调度中心 / 把闲置家用电脑变成 AI 算力节点」。按代码还原的真实形态是：

```
web/app.js (1022 行)
   ↓ HTTP + X-PF-Token
server.py (1148 行 / 22 条路由 / 61 个函数)  ← 唯一枢纽
   ├─→ 文件总线 commands/in|done → 内核.ps1 (2057 行) + lib/*.ps1 (1515 行)
   │                                  ↓ 进程优先级 / 内存回收 / 场景 / 安全扫描
   ├─→ llama-server:8080 或云端 API（server.py:748-791，OpenAI 兼容）
   └─→ ctypes 原生进程枚举（server.py:251-327）
```

**定位落差（本次审视最重要的结论）**：真正的核心资产是 **PowerShell 内核的 3572 行本机进程与资源治理逻辑**；
Python 侧主要承担采集、协议适配与 Web 呈现。「AI 算力调度」在当前实现里表现为
「用本地/云端 LLM 解析自然语言指令 + 模型路由 + 可选本地推理」，**不是分布式算力调度，也没有节点发现/任务分发**。

建议：对外表述收敛为「本机算力与进程调度控制台（含本地大模型推理）」。
这不削弱产品价值，反而让 README / Release / 用户预期一致，也为将来真做节点化留出清晰边界。

---

## 2. 做对了什么（避免只挑毛病）

| 项 | 证据 |
|---|---|
| 全局认证 + Host 校验 | `server.py:240-242` 三层中间件，仅 `/api/health` 豁免；`server.py:920` 有用错误 token 的自检用例 |
| 写操作白名单 + 破坏性双确认 | `server.py:714-745`：`ALLOWED_ACTIONS` / `DESTRUCTIVE_ACTIONS`、`confirm=true`、后端注入本机 token、超时封顶 600s |
| CSP 与请求体限制 | CSP 由 `security.py:319` 以响应头注入（非 meta）；`BodyLimitMiddleware` 1 MiB |
| KVRT 供应链合规 | `kvrt_bundle.py:212` WinVerifyTrust、`:294` SHA256、`:36` 硬编码期望哈希、`:420` 未验签拒绝运行；引擎不入库（EULA 5.3/5.4） |
| 凭据保护 | `security.py:200-256` ctypes 直调 Windows DPAPI，不依赖第三方加密库 |
| 日志与数据目录 | `main.py:29-31` RotatingFileHandler 2 MiB × 5；`app_paths.py` 统一 `%LOCALAPPDATA%\PowerFocus` |
| 界面工程 | 94 个 token 双主题、WCAG 2.1 AA 双人独立复算、类名体系不变使前端逻辑零结构改动 |

---

## 3. 与专业软件公司工程基线的差距（审计前）

| 维度 | 审计前实测 | 公司基线 | 优先级 |
|---|---|---|---|
| 依赖锁定 | 无 requirements / lock；`ci.yml:46` 五个包全浮动 | pin + constraints + 可重建 | P0 |
| 可复现构建 | `build.ps1:14` 硬编码 `E:\PowerFocus\.venv`；PYTHONPATH shim、pwsh 7 依赖未固化 | 与机器无关 + 构建元数据 | P0 |
| CI 门禁 | 7 步全静态；无 lint / 构建 / 产物校验；tag push 不触发（`ci.yml:16-20`） | lint+type+test+build+audit | P0 |
| 测试防线 | 33 用例，仅覆盖 app_paths 与安全契约；无覆盖率、无集成、无 exe 冒烟 | 覆盖率门槛 + 分层测试 | P1 |
| 版本语义 | tag 0.10.x / 产品 1.00 / 内核 0.09 三线混用；`CHANGELOG.md:91` 死链 | 单一 SemVer 真源 | P0 |
| 治理件 | `.github/` 仅 ci.yml；`SECURITY.md:17` 私密渠道为占位注释 | CODEOWNERS / 模板 / 检查单 | P1 |
| 文档同步 | `MANIFEST.json:93` 记 16 passed（实测 33）、`:5` build_date 不符；`release-plan.md:77` 字节数属另一次构建 | 单一真源 + CI 校验 | P1 |
| 发布完整性 | 无签名 / SBOM / provenance（SLSA 0）、无 Go-No-Go 单 | 签名 + SBOM + 回滚演练 | P2 |
| 可观测性 | README 明示数据不上传，无崩溃上报 / SLI / SLO | 本地指标 + 可选上报 | P2 |

---

## 4. 问题清单（P0 / P1 / P2）

### P0

1. **失败回执被当成成功** — `server.py:504` 只判断 done 文件存在即 `return True`；内核 `电脑算力调度中心_v0.10.ps1:1755` 异常时正文写 `ERROR:`。结果：失败操作被前端提示为成功。
2. **回执首行时间戳污染 JSON** — 内核 `:1760` 写 `"$stamp`n$resultText"`，`server.py:828` 直接 `json.loads(text)`，导致 `/api/router` 的 `data` 恒为 `None`。
3. **文件总线无原子写 / 无幂等 / 无清理** — `server.py:494,499,511` 直接 `write_text`、超时只删 in；内核 `:1762` Move 进 done 后永不删。实测 `commands/done` 残留 **72 个**文件；半写 JSON 会被内核读成 ERROR；`kill/stress` 超时重试可能重复执行。
4. **发布链路不可复现 / 版本真源缺失**（见第 3 节）。

### P1

5. `server.py` 上帝对象：1148 行混 7 类职责；`main.py:119` 越层 Popen 内核，`server.py:1036` 反向 import `versions/v0.10`。
6. **单实例静默退出**：`main.py:160-162` 仅写日志后 return，`--windowed` 无控制台 → 用户双击「没反应」；且 `CreateMutexW` 未设 `restype`，64 位句柄被 ctypes 截成 `c_int`。
7. `find_port` TOCTOU：`main.py:70-78` 先 bind 再由 `with` 释放，uvicorn 之后重新 bind 同一端口。
8. 硬编码开发机路径：`models-preset.ini:16-79` 八个模型全为 `E:\`/`D:\` 绝对路径；`server.py:81` 兜底 `E:\PowerFocus`；端口 8080/18080 分散定义。
9. 版本指针语义未声明：`versions/current.json:4` = v0.09、`server.py:1038` 硬编码加载 v0.10 自检、`app_paths.py:42` = v0.10、`main.py:28` = v1.00；CI 的 JSON 契约（`ci.yml:86-119`）守的是 v0.09 配置，与实际打包的 v0.10 自检模块错配。
10. 文档漂移与治理件缺失（见第 3 节）。

### P2

11. `server.py:123` `BUS_OUT` 定义后零引用；内核 `:97,1176` 写 `out/status.json` 无消费者；根 `commands/` 与 `versions/v0.10/commands/` 并存，内核 `:15` 注释仍写 `E:\PowerFocus\v3\commands`。
12. 新增一个视图要改 `index.html` 两处 + `app.js` 四处（`VIEW_ORDER` / `switchView` / 绑定 / 渲染），`app.js` 已 1022 行且持续膨胀。
13. 27 处 `except Exception`（`server.py`），部分静默吞异常。
14. `pyproject.toml` 配了 ruff 但 CI 从不执行；`tests/` 下 4 个 `.ps1` 被 `ci.yml:8-11` 明示不跑。

---

## 5. 第一批已落地（本轮实际改动）

| 类别 | 改动 |
|---|---|
| P0 协议层 | 新增 `product/v1.00/app/bus_receipt.py`：`parse_receipt()` / `atomic_write()` / `dumps_command()` / `gc_done()`；`server.py` 的 `bus_call` 改用它；内核回执改为纯正文 |
| P0 清理 | 回执消费后立即删除，10 分钟节流的过期回收 |
| P1 体验 | `main.py` 增加 `notify_already_running()` 系统消息框；互斥量句柄 64 位修正并全局持有 |
| 测试 | 新增 `tests/py/test_bus_receipt.py` 9 例（时间戳剥离 / ERROR 双格式 / 全角冒号 / 原子写 / GC），pytest 33 → **42** |
| CI | 新增 `ruff check` 门禁；依赖改 `-r requirements-ci.txt`；`on` 增 `tags: ['v*']`；`py_compile` 目标补 `bus_receipt.py` |
| 依赖 | `requirements.txt` / `.lock.txt` / `-dev.txt` / `-ci.txt` 四件套，全部精确锁定 2026-11-14 实测版本 |
| 治理 | `CODEOWNERS`、`dependabot.yml`、PR 模板、Bug/Feature Issue 模板；`SECURITY.md` 占位补实 |
| 版本 | `CHANGELOG.md` 重写为单一真源，消除 `v1.00.0` 死链与前导零违规，明确 stable/dev 分期 |
| 文档 | 本报告 |

**验证记录**：`pytest` 42/42 通过；`ruff check` 0 错误（清理了 2 处未使用导入）；
`py_compile` 3 文件通过；PowerShell 内核 `Parser::ParseFile` **13191 token / 0 错误**。

---

## 5.1 第二批（阶段一）已落地与验证

| 类别 | 改动 | 证据 |
|---|---|---|
| 分层 | 新增 `product/v1.00/app/bus.py` 的 `BusClient`，承接目录 / 超时 / 轮询 / 幂等 id / 消费 / 撤回 / GC；`bus_receipt.py` 保持零依赖纯协议层 | `server.py` 的 `bus_call()` 由约 40 行降为 `return await BUS.call(cmd, timeout)` |
| 幂等 | 命令默认写入 `idempotency_id`；内核忽略未知字段，行为不变 | `tests/py/test_bus.py::test_command_has_idempotency_id_and_no_tmp_left` |
| 端口 | `find_port()`（bind 后释放 → uvicorn 重绑，存在 TOCTOU）改为 `bind_port()`，socket 全程持有并 `listen(128)` | `main.py:93-107`；`server.serve(port, sock)` 走 `uv_server.run(sockets=[sock])` |
| 就绪 | `wait_ready()` 由 TCP `connect_ex()` 改为 HTTP `GET /api/health` 等 200 | `main.py:110-130`；避免已 listen 但 ASGI 未启动就开窗口 |
| 测试 | 新增 `tests/py/test_bus.py` 6 例；pytest 42 → **48** | 覆盖成功 / ERROR / 幂等 / 原子写 / 消费即清理 / 超时撤回 / 200 id 不碰撞 |
| 门禁 | `ci.yml` 的 `py_compile` 目标补 `bus.py` | 新模块此前不进编译清单，已修正 |

**验证记录（全部实测）**：`pytest tests/py -q` → 48 passed；`ruff check product/v1.00/app tests/py app_paths.py` → All checks passed；
4 个模块 `py_compile` 通过；pwsh 7 全仓 **149 个 `.ps1`** `Parser::ParseFile` → 0 错误；
源码实机起服务：`bind_port=18091` → `wait_ready=True` → `GET /api/health` 200
（`{"app":"ok","frozen":false,"kernel_alive":true,...}`）。

**本阶段明确未做**（不虚报完成）：`processes.py` / `nlp.py` / `llm_proxy.py` 三个模块尚未拆出，
`server.py` 仍在 1100 行上下未达 900 行目标；结构化回执、模型路径相对化、端口集中注入未动。

---

## 5.2 第三批（v0.11.0）MCP 发行物与双专家 P0 加固

本轮由两个只读专职角色并行审查：网络攻防 / 红队视角（`general-purpose-1`）与
缺陷挖掘 / 质量审计（`general-purpose-2`）。红队给出 F1–F14 攻击面清单与《MCP 对外暴露前
必须满足的安全红线》，Bug 猎手给出 27 项缺陷（P0×5 / P1×5 / P2×17）与复现路径。
主理人对每条结论都做了代码实证复核后才决定是否落地，未把报告结论直接当事实使用。

| 类别 | 改动 | 证据 |
|---|---|---|
| 版本治理 | 新增 `docs/VERSION_POLICY.md`：唯一对外版本号 = GitHub Release tag；PATCH 小更新 / MINOR 功能版本 / MAJOR 全面更新；每次开发完固定 8 步发布闭环 | `CHANGELOG.md` 的 `[0.11.0]` 按 MINOR 判定 |
| MCP 发行物 | 新建独立 `mcp/`，协议 `2026-07-28` 无状态核心、stdio JSON-RPC、零第三方依赖；不直写命令总线，改走本机 HTTP API 复用 `X-PF-Token` 与动作白名单 | `mcp/powerfocus_mcp/server.py`；`mcp/VERSION.json` 对齐 `0.11.0` |
| MCP 安全 | 默认只读 10 工具；写工具需 `POWERFOCUS_MCP_ALLOW_WRITE` + 一次性 nonce（`input_required` → `inputResponses`）；参数声明即白名单；审计只记键名；不暴露 REA 229 项代理 | `tests/py/test_mcp_server.py` 31 例 |
| 旧入口 | `mcp-server.py` 标记 `[DEPRECATED since v0.11.0]`，不随 Release 分发 | 原因：绕过鉴权 / 无审计 / 强制握手 / 硬编码 `E:\PowerFocus` |
| F1 令牌解耦 | HTTP/UI token 移至 `%LOCALAPPDATA%\PowerFocus\http.token`；内核授权 token 仅服务端内部注入，绝不进入 HTTP 响应 | `server.py::_token()` / `_kernel_token()`；`test_p0_hardening.py` |
| F2 / B5 参数注入 | `/api/command` 丢弃 `_` 前缀字段与客户端 `token` / `idempotency_id` | `server.py` 命令构造段 |
| B1 / B2 原子性 | token 并发原子写（`_TOKEN_LOCK` + `.tmp` → `os.replace`）；`BusClient` 空回执再等最多 3 轮，避免把后续 `ERROR:` 误判成功 | 12 线程并发用例 |
| B1 内核回执 | 当前 stable 内核 v0.09 与 dev 内核 v0.10 回执一律纯正文 + `.tmp` → `Move-Item -Force` 原子替换 | 两处 `电脑算力调度中心_v0.0*.ps1` |
| B6 / B10 | `resolve_pf_root()` 去除 `E:\PowerFocus` 硬编码；修复「断言恒真且污染生产目录」的假绿测试并加守卫 | 5 个历史孤儿回执已清理 |

**验证记录（全部实测）**：`pytest tests/py -q` → **89 passed**；`ruff check`（含 `mcp/powerfocus_mcp`）→ 0 错误；
6 模块 `py_compile` 通过；pwsh 7 全仓 **150 个 `.ps1`** → 0 错误；
v0.09 / v0.10 内核分别 13208 / 13206 token、0 errors；
重新打包 exe **20,450,312 B**，SHA256 `72f6bc871d79e1451ba21d170544df4493847b9315a151c7bb7dd02ee0e78a74`；
实机 `frozen=true / kernel_alive=true / port=18080`。

**本轮明确未修**（不虚报完成，留待排期）：F3 `/api/health` 限流豁免、F4 命令总线无认证、
F7 KVRT 验签 TOCTOU、F8 硬编码同意令牌、F10 无统一写审计、F13 CI 供应链加固、F14 路径 ACL；
以及 B7–B13、B19–B30（含版本槽 `v0.10` / `current.json=v0.09` 不一致与 `build.ps1` 硬编码 pyinstaller 路径）。
这些项要么涉及产品 Go/No-Go 决策，要么需要独立构建链改造，本轮未擅自改行为。

---

## 5.3 第四批（v0.11.1）双专家遗留缺陷清零 + 通用化

发布定位升级：**通用应用**——任何电脑 / 服务器加载即可用，不再是开发机定制品。
本轮以「换一台机器还能不能跑」为验收标准，把双专家报告中可修项全部落地：

| 编号 | 缺陷 | 修复证据 |
|---|---|---|
| F4 | 命令总线无认证 | v0.09 / v0.10 两代内核消费前校验 `Get-AuthToken`；`BusClient` 统一注入；ps1 语法 0 错误 |
| F7 | KVRT 验签 TOCTOU | `run_scan()` 执行前同路径重跑 `WinVerifyTrust` + 重算 SHA256，不符即拒跑 |
| F8 | 硬编码同意令牌 | `mint_consent/check_consent` 一次性令牌（TTL/scope/用后即焚），服务端现场签发消费；5 例回归 |
| F3 | health 免限流 DoS | 限流先于鉴权、覆盖全部 `/api`；回归断言源码顺序 |
| B7/B8/B9 | 日志竞态 / 连接泄漏 / GC 吞错 | handler 启动期一次性挂载 + 2MB×5 轮转；`wait_ready` finally 关闭；GC 异常入审计 |
| B11/B12 | chat/models 参数 500 | messages 强校验 400；烂 profiles 返回空列表；各 1 例回归 |
| B13 | 前后端超时契约 | 前端 `budgetMs = max(90s, _timeout+10s)`；后端夹紧 [1,600]；1 例契约回归 |
| B19/B20 | 句柄截断 / LastError | restype/argtypes 补全；`use_last_error=True` 判 183 |
| B21/B22 | chunked 绕过 / limiter 无界 | 按字节累计 413；每窗口清扫整桶过期 key；各 2 例回归 |
| B23/B26 | 日志三套 / 配置路径 | 统一 `%LOCALAPPDATA%\PowerFocus\<槽>\logs`；回退走 `app_paths` |
| B27 | 云端 SSRF/凭据外送 | `_cloud_url_ok()` loopback/https 白名单 |
| B28/B29/B30 | 就绪语义 / 第二启动路径 / 版本槽 | health 探活真实化；`serve_only()` 统一入口；引擎槽与发布版本解耦、build.ps1/spec 相对化 |

**通用化（新验收标准）**：

- 模型预设三层查找：`models-preset.local.ini`（本机私有，gitignore）→ 内核目录 local → 内置模板；
- `model-router.ps1` 存在性过滤：换机后缺失条目自动跳过并提示，全部缺失给出配置指引
  （四场景冒烟实证：源查找 / 全存在复用 / 模拟换机全缺失报错 / 部分缺失过滤生成）；
- `calibrate-vram.ps1` 去 `E:\` 硬编码，支持 `LLAMA_SERVER_EXE` 覆盖；
- 全仓扫描：项目代码零本机绝对路径残留。

**验证**：pytest **104 passed**（新增 15 例）、ruff 0 错误、py_compile 10 目标、
pwsh 7 全仓 `.ps1` 0 错误。冒烟中发现并修正 `New-EffectivePreset` 返回流被
`Write-Output` 污染的真实 bug（`$usePreset` 会变成数组，`--models-preset` 传坏）。

---

## 6. 明确未擅自改动的高风险项（需产品决策）

1. **`versions/current.json` 保持 v0.09**：`versions/v0.10/MANIFEST.json:6` 标 `stage: "dev"`，
   `:7` note 明写「未切 current.json」。把它改成 v0.10 等于把未转正内核切为生产，
   属于产品 Go/No-Go 决策，不是配置纠错。审计结论应表述为「缺治理声明」而非「配错了」。
2. **`server.py:1038` 自检硬编码 v0.10**：建议补一条「dev 模块仅供自检、不参与运行时路由」的契约文档，
   而不是直接改指针。
3. **未加 CI 构建 job**：`windows-latest` 无 WebView2 / .NET 本机工具链，PyInstaller 在托管 runner 上
   产出的 exe 与本机不一致，强加只会制造假绿灯。建议改用自托管 runner 后再上构建与产物校验。
4. **未做 exe 签名 / SBOM / SLSA provenance**：需要代码签名证书与构建链改造，是独立项目，不在本轮范围。

---

## 7. 路线图（每批独立可验证）

- **第二批 · 架构收敛（阶段一已完成，见 5.1）**：已落地 `bus.py` 分层、命令幂等 id、`bind_port` 消除 TOCTOU、
  `wait_ready` 升级为 HTTP 就绪判定、6 例新单测与 CI 目标补全。
  **剩余**：`server.py` 再抽 `processes.py` / `nlp.py` / `llm_proxy.py` 并降到 900 行内；
  回执升级为结构化 `{ok, ts, payload}`（保留旧格式兼容）；模型路径改 `${DATA_DIR}/models` 相对解析；端口集中注入。
- **第二批 · 发行与供应链（本轮新增，来自开源合规审查）**：Release 补 `LICENSE` + 全量 `THIRD_PARTY_NOTICES`、
  开启 Private vulnerability reporting、CI action 改 commit SHA pin、`pip-audit` 门禁、
  tag 触发的 build job 与 `actions/attest-build-provenance`（SLSA L0 → L2）。
  本轮已落地前两项与 PVR；SHA pin / provenance / 自托管 runner 需先决定构建策略再动，未擅自改 CI 行为。
- **第三批 · 质量门禁**：覆盖率门槛（≥60% 起步）、`server.py` 路由集成测试、exe 冒烟（启动 → `/api/health` → 关闭）、
  发布 Go/No-Go 检查单与回滚演练、构建元数据（commit / built_at / sha256）写入 MANIFEST 并由 CI 校验。
- **第四批 · 公司化收尾**：自托管构建 runner、exe 签名与 SBOM、依赖 CVE SLA、
  本地 SLI 指标（启动耗时 / 总线超时率 / 自检通过率）、SLO 与发布冻结阈值。
- **第五批 · 双专家遗留缺陷排期（v0.11.1 已完成主体）**：F3 / F4 / F7 / F8 与
  B7 / B8 / B9 / B11 / B12 / B13 / B19 / B20 / B21 / B22 / B23 / B26 / B27 / B28 / B29 / B30
  已全部落地并带回归（见 5.3）；F10 由总线层 `bus_command` 审计总闸覆盖。
  剩余：F9（系统进程硬闸统一）、F13 / F14（CI 供应链 + 路径 ACL）归入
  「CI 供应链 + 路径 ACL」专项，需先决定构建与签名策略。

---

## 8. 一句话结论

这个项目的**功能密度与安全边界意识超出典型个人项目**，但工程可重复性（依赖、版本、门禁、构建）
还停在「一个人能跑通」的阶段。第一批把它推进到「换一台机器也能复现、改错了会被门禁挡下」的起点；
第二批阶段一已把命令总线的职责边界、端口竞态与就绪判定这三处真实缺陷收掉并留下可独立运行的单测；
第三批（v0.11.0）在两个专职审查角色的证据清单上收掉 7 项 P0，并把 MCP 从「无鉴权直写总线的旧脚本」
换成「默认只读、显式授权、一次性确认、版本对标 Release 的独立发行物」；
第四批（v0.11.1）把双专家遗留缺陷清零至只剩需产品决策的 F9 / F13 / F14，
并以「通用应用」为新验收标准清掉了最后一批机器绑定（模型预设三层查找 + 存在性过滤，
换机后缺失条目自动跳过而不是启动失败）。
真正决定它能否像公司产品一样长期演进的，仍是 `server.py` 剩余拆分与发行链路的构建溯源
（签名 / SBOM / provenance）。
