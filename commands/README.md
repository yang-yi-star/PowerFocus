# 命令总线使用说明

调度中心 v2 每 2 秒轮询 `in\` 目录下的 *.json 命令文件：
执行 → 结果写入 `done\<原文件名>.result.txt` → 原文件移入 `done\`。

## 可用动作

| action | 必填字段 | 可选字段 | 说明 |
|---|---|---|---|
| status | - | - | 整机状态快照写入 out\status.json |
| focus | process_name 或 pid | mode: gentle/aggressive/godmode | 目标必须在授权清单内 |
| unfocus | - | - | 解除聚焦并按原值还原 |
| authorize | process_name, token | level: high/realtime | 修改授权清单，需 .auth_token 中的密钥 |
| revoke | process_name, token | - | 撤销授权，需 token |
| set_priority | process_name 或 pid, priority | - | 直接设优先级 |
| set_power_plan | plan: high/balanced | - | 切换电源计划 |

## 命令示例（完整示例见示例命令_focus.json）

```json
{
  "action": "focus",
  "process_name": "llama-server",
  "mode": "godmode"
}
```

## 安全机制

- focus/godmode 只对 authorized_apps.json 中的进程生效。
- authorize/revoke 必须携带 E:\PowerFocus\.auth_token 里的 token（本机首次运行调度中心时自动生成）。
- 所有命令执行结果均记录在 电脑算力调度中心_v2.log。

## 自然语言层（阶段二，已实现）

入口：`E:\PowerFocus\nl-gateway.ps1`

- 交互模式：`pwsh -File nl-gateway.ps1`，直接说人话（"给 llama-server 开后门"、"看看现在什么情况"）
- 单次模式（供外部 AI / 脚本调用）：`pwsh -File nl-gateway.ps1 -Command "给 llama-server 开后门"`
- 纯规则模式（不依赖模型）：加 `-NoModel`

翻译两级：规则解析（nl-parser.ps1，快、离线）→ LLM 兜底（localhost:8080 主推理服务，OpenAI 兼容接口，系统提示词内约束 schema + 输出经 action 白名单校验）。

安全铁律：
- authorize / revoke 属敏感命令，LLM 永远无权生成；人工指令也必须在交互模式下二次确认（单次模式一律拒绝）
- LLM 输出的 action/mode/priority/plan 均经白名单校验，防幻觉
