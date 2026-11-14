# PowerFocus MCP Server 0.11.0

让任意支持 MCP 的 AI 客户端（Claude、Cursor、VS Code、ChatGPT、各类 Agent）把
PowerFocus 识别为一个 MCP Server 并加载使用。

- **产品版本**：`0.11.0`，与主应用 Release `v0.11.0` 一致（规则见 `docs/VERSION_POLICY.md`）
- **协议版本**：默认 `2026-07-28`（无状态核心），兼容 `2025-06-18` / `2025-03-26` / `2024-11-05`
- **传输**：`stdio`，逐行 JSON-RPC 2.0
- **依赖**：**零第三方依赖**，仅 Python 3.10+ 标准库
- **前置**：本机桌面应用已启动（`127.0.0.1` 上的 FastAPI 服务在线）

## 1. 加载方式

把 `config.example.json` 里的 `mcpServers.powerfocus` 片段复制进你的客户端配置文件
（Claude Desktop 的 `claude_desktop_config.json`、Cursor 的 `mcp.json`、VS Code settings 等），
把 `<目录>` 换成实际路径：

```json
{
  "mcpServers": {
    "powerfocus": {
      "command": "python",
      "args": ["E:/PowerFocus/mcp/powerfocus_mcp/server.py"],
      "env": { "POWERFOCUS_ROOT": "E:/PowerFocus" }
    }
  }
}
```

客户端会以子进程方式拉起本文件。可先手工验证：

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | python mcp/powerfocus_mcp/server.py
```

## 2. 与根目录旧 `mcp-server.py` 的区别

旧文件（2026-11-05，协议 `2024-11-05`）**保留但已标记弃用**，不再建议对外使用。

| 维度 | 旧 `mcp-server.py` | 本发行物 `mcp/` |
|---|---|---|
| 后端通道 | 直写 `commands/in` 命令总线，绕过全部 HTTP 鉴权 | 通过 `127.0.0.1` 的 HTTP API，复用 `X-PF-Token`、动作白名单与限流 |
| 默认能力 | 全部 16 个工具（含写操作）+ 229 项 REA 逆向工具 | **默认只读 10 个工具**；REA 完全不提供 |
| 写操作 | 无二次确认、无审计 | 默认不暴露；需显式开关 + 一次性确认 nonce |
| 审计 | 无 | 每次调用写 `%LOCALAPPDATA%\PowerFocus\mcp\audit.jsonl`（只记参数键名，不记值/令牌） |
| 协议 | 强制先 `initialize`，否则 `-32000` | 无状态：任何请求可独立到达；同时兼容旧握手 |
| 路径 | 硬编码 `E:\PowerFocus` | 环境变量 / 自动探测，可整目录拷走 |
| 版本 | 内部编号 `1.1.0`，与发布版本无关 | 与 Release tag 严格对齐 |

**旧实现的安全结论（红队审计）**：它是一条完全不设防的旁路——任何能加载该 MCP 的 AI
都能压低/结束本机进程、启停服务、apply 调参，并调用 REA 对本机文件做静态逆向。
因此本发行物不再复用它的工具集与转发逻辑。

## 3. 默认工具（只读）

`pf_health`、`pf_snapshot`、`pf_processes`、`pf_models`、`pf_scenes`、
`pf_router_status`、`pf_security_status`、`pf_audit_log`、
`pf_bootstrap_check`、`pf_parse_command`。

写工具（`pf_run_command`、`pf_boost_model`、`pf_chat`）与高危工具
（`pf_install_component`）只有设置 `POWERFOCUS_MCP_ALLOW_WRITE=1`
（安装类另需 `POWERFOCUS_MCP_ALLOW_INSTALL=1`）后才会出现在 `tools/list`。

## 4. 写操作的一次性确认（两步）

开启写权限后，调用写工具**第一次不会执行**，而是返回 `resultType: "input_required"`
并附一个短 TTL 的一次性 nonce（绑定具体工具与参数摘要）。客户端带
`_mcp_confirm: "<nonce>"`（或 2026-07-28 的 `inputResponses`）重试才会真正执行。
nonce 用后即失效、不可复用、不可跨工具/跨参数使用。

这对应 MCP 2026-07-28「显式句柄传递状态」的做法，也避免了用静态常量当确认令牌
（旧 `dependency_bootstrap.py` 的硬编码 consent token 已被红队列为缺陷）。

## 5. 协议实现说明

| 方法 | 行为 |
|---|---|
| `tools/call` | **无需先握手**（2026-07-28 无状态核心） |
| `server/discover` | 返回能力、协议版本列表、当前安全策略（可选发现 RPC） |
| `initialize` | 兼容 2024-11-05 ~ 2025-06-18 客户端，返回协商后的 `protocolVersion` |
| `notifications/*` | 忽略，不响应 |
| `tools/list` | 按工具名排序（确定性顺序），带 `ttlMs` / `cacheScope` 缓存提示 |
| `ping` | 返回空 result |

`server/discover` 里 `mrtr: "confirm-only"` 是如实声明：确认流使用了
`input_required` / `inputResponses`，但没有实现 server-initiated 的
elicitation / sampling 等完整 MRTR 能力。列表缓存提示按 SEP-2549 落地。

## 6. 安全边界（请务必阅读）

- stdio 没有协议级客户端认证，**能力边界 = 能配置/启动这个 server 的人或进程**。
  不要把它放进不可信的 MCP 配置，不要对公网暴露。
- 本发行物**不新增 HTTP 监听端口**，因此不会引入 DNS rebinding / CORS / CSRF 面。
  若将来要加 HTTP 传输，必须先完成「HTTP 令牌与内核授权令牌解耦」，并复用
  `SecurityMiddleware` 全套，禁止宽松 CORS。
- 审计日志不记录参数值、令牌或用户输入内容，避免日志本身成为泄露面。
- 所有工具只作用于本机已授权进程；不操作外部系统。

## 7. 排错

| 现象 | 原因与处理 |
|---|---|
| `未发现运行中的 PowerFocus 服务` | 桌面应用没开，或端口不在 18080~18119；用 `POWERFOCUS_MCP_PORT` 指定 |
| `未找到本机令牌` | 设置 `POWERFOCUS_ROOT` 指向应用根目录，或直接给 `POWERFOCUS_MCP_TOKEN` |
| `该能力未启用` | 只读是默认策略；按第 3 节设置开关 |
| `写操作需要逐次确认` | 按第 4 节取 nonce 后重试 |
| `后端请求失败 4xx` | 令牌与应用当前 token 不一致；重启应用或重新读取 token |

## 8. 发行物内容

```
mcp/
├── VERSION.json                 # 版本与协议兼容声明
├── config.example.json          # 各客户端配置样例
├── README.md                    # 本文件
└── powerfocus_mcp/
    ├── __init__.py              # 版本常量
    └── server.py                # MCP Server 主体
```

发版时整个 `mcp/` 打成 `PowerFocus-MCP-v0.11.0.zip`，作为该 tag Release 的独立附件。
