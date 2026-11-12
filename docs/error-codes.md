# PowerFocus 错误码规范（提案，未全面落地）

> 状态：**本文档为 2026-11-13 提出的约定草案**。现有代码中的错误返回是逐处
> 演进出来的，尚未按本约定统一编号；新代码建议遵守，旧代码在触碰时逐步迁移。

---

## 1. 现状盘点（grep 实测，2026-11-13）

### 1.1 HTTP 层（product/v1.00/app/server.py）

| HTTP 状态 | 触发场景（现有代码） |
|---|---|
| 400 | 请求体非 JSON / 非 JSON 对象；action 不在白名单；破坏性操作缺 `confirm=true`；修改授权清单缺本机 token；`mode` 非 dry_run/apply；`base_url` 非 http(s)；缺 `component_id`；未知组件 |
| 401 | `/api/*` 缺本机 token（security 中间件） |
| 403 | Host 头不在白名单（DNS 重绑定防护）；跨源 POST（CSRF 防护） |
| 404 | `/docs` `/openapi.json` 生产隐藏；界面资源缺失 |
| 413 | 请求体 > 1MB（在读入内存前拒绝） |
| 502 | 云端 API 上游返回非 2xx（`JSONResponse` 透传或包装，`server.py:776-777`） |
| 503 | 云端凭据/BASE_URL 未配置；自检模块不可用 |

另有健康检查 `/api/health` 200 免鉴权，属约定豁免而非错误。

### 1.2 PowerShell 脚本 exit code

| 退出码 | 含义（现有代码） | 典型位置 |
|---|---|---|
| 0 | 成功 | `tests/run-tests.ps1:330`、`tools/dev-check.ps1:211` 等 |
| 1 | 通用失败（参数缺失 / 前置检查不过 / 任一 FAIL） | `tests/run-tests.ps1`、内核脚本 `versions\v*\*.ps1:40`、`net-qos.ps1`、`tools\*` |
| 2 | 死链 / 版本目录已归档 | 根目录转发壳 `电脑算力调度中心.ps1:20,26`、`v2.ps1:18` |
| 透传 | 转发壳把内部脚本的 `$LASTEXITCODE` 原样传出 | `电脑算力调度中心.ps1:30` |

问题：**1 是万能失败码**，调用方与日志无法区分「参数错」「环境缺」「测试失败」；
脚本间无统一编号规则，仅靠约定俗成。

---

## 2. 提案：错误码约定

### 2.1 编码格式

```
PF-<模块前缀><三位序号>
```

* 模块前缀（两字母，见 §2.2），序号三位，从 001 递增。
* 出现在：HTTP 400/4xx/5xx 响应体的 `code` 字段、PowerShell 脚本 stderr
  最后一行、日志条目。**HTTP 状态码与 exit code 保持现有语义不变**，
  错误码是补充定位信息，不替代它们。

### 2.2 模块前缀表（初始提案）

| 前缀 | 模块 |
|---|---|
| `SR` | app/server.py（v1.00 控制台服务） |
| `SC` | security.py（鉴权/Host/限流/凭据库） |
| `KN` | 内核脚本（电脑算力调度中心_v*.ps1） |
| `MC` | mcp-server.py |
| `RT` | 模型路由 / router（model-router.ps1、models-preset 解析） |
| `TS` | tests/run-tests.ps1 及测试工具 |

### 2.3 HTTP 状态映射表（提案）

| HTTP 状态 | 错误码段 | 现有场景举例 |
|---|---|---|
| 400 | `PF-SR0xx`（请求/参数类） | 非 JSON、action 越界、缺 confirm |
| 401 | `PF-SC0xx`（凭据类） | 缺本机 token |
| 403 | `PF-SC1xx`（来源校验类） | Host 不合法、跨源 |
| 404 | `PF-SR1xx`（资源不存在类） | 界面资源缺失、docs 隐藏 |
| 413 | `PF-SR2xx`（请求体类） | 超 1MB |
| 500 | `PF-SR9xx`（未分类内部错误） | 兜底段 |
| 502 | `PF-RT9xx`（上游透传类） | 云端 API 上游错误 |
| 503 | `PF-SR3xx`（依赖未就绪类） | 云端未配置、自检模块缺失 |

响应体格式（提案）：

```json
{"code": "PF-SR001", "message": "action 不在白名单: xxx", "status": 400}
```

### 2.4 PowerShell exit code 映射表（提案）

| exit code | 含义 | 错误码段 |
|---|---|---|
| 0 | 成功 | — |
| 1 | 保留：通用失败（兼容既有调用方，不新增使用） | — |
| 2 | 死链 / 目录归档（维持现状） | `PF-KN0xx` |
| 10-19 | 参数/用法错误 | `PF-KN1xx` |
| 20-29 | 环境/前置条件缺失（无 Python、无模型文件、无 token） | `PF-KN2xx` |
| 30-39 | 执行失败（子命令运行报错） | `PF-KN3xx` |

`tests/run-tests.ps1` 保持 0/1 不变（CI 与人工都依赖这一契约）。

### 2.5 落地原则

1. **新代码必须带错误码**；旧代码只在不改逻辑的纯触碰中顺手补，不单独开 PR 批量替换。
2. 错误码一经对外发布不得改义，废弃要保留并指向替代码。
3. 每个模块的完整编号表以注释形式放在模块头部（如 server.py 顶部），本文档只维护映射规则与前缀表。

---

## 3. 未尽事项

* 现有 20 处 `HTTPException`、30+ 处 `exit 1` 尚未按 §2 迁移。
* 前端 `app.js` 目前只按 HTTP 状态分支，未消费 `code` 字段；落地时需同步。
* MCP 层（mcp-server.py）的 JSON-RPC error code 约定待与 §2 对齐。
