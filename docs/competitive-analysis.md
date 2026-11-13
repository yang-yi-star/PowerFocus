# 竞品分析——为什么做这个项目（2026-11-13）

> 依据：GitHub / 公开网页调研（调研日期 2026-11-13）。借鉴 Zanrei 项目的做法：立项先写清
> 「市面上有什么、它们同意什么、只有我们做什么」，让项目定位经得起检验。

## 一、四个赛道的同类项目

### 赛道 1：进程 / 内存调度（正面重叠区）

| 项目 | 状态 | 重叠度 | 说明 |
|---|---|---|---|
| **ThreadPilot**（PrimeBuild-pc，开源） | 活跃（2026-10 仍在迭代，v1.7.8） | **~70%** | 自称「开源 Process Lasso 替代」：CPU 亲和性 / CPU Sets、优先级、内存优先级、电源计划、持久规则、Game Boost（默认关闭）、Win11 Fluent 界面、WinGet / Chocolatey 分发、CI 发布流水线 |
| Process Lasso（Bitsum，闭源收费） | 品类标杆 v18.x | ~50% | 定义了「进程自动化规则」品类；SmartTrim / 响应性控制；本项目的开源参照系 |
| Mem Reduct（henrypp，GPL-3.0） | 8.8k stars | ~30% | 内存清理单项冠军：382KB、Native API 清 8 个内存区域、阈值/定时自动清理、托盘、GPG 签名发布 |
| Windows Memory Cleaner（开源） | 活跃 | ~25% | 便携、CLI 开关齐全、服务模式 |

### 赛道 2：Windows 优化工具箱（周边，非直接竞品）

WinUtil（ChrisTitusTech，65.2k ⭐，MIT）、Win11Debloat（61.2k）、Atlas OS（21.9k）、
hellzerg/optimizer（18.2k）、Sophia Script（9.8k）、BleachBit（7.3k）。
共同点：debloat / 遥测关闭 / 服务调整 / 隐私。**本项目不做这些**——定位不同，不构成竞争，
但它们的工程实践（配置文件化 tweaks、可回退、恢复点）值得借鉴。

### 赛道 3：本地 LLM 桌面控制（模型路由 + 自然语言方向）

| 项目 | 说明 |
|---|---|
| Windows-Use（Jeomon，MIT） | GUI 层 agent：UI Automation API 读屏，任意 LLM 决定点击/输入 |
| OpenJarvis（Stanford Hazy Research） | 本地优先 AI 框架，Ollama 集成；把能耗/成本/延迟与精度并轨追踪 |
| LocalAI-Desktop | Ollama 桌面助手：对话+视觉+系统控制，**命令白名单**、日志按天轮转 |
| Ollama-Agent-PC / Clippy | 小型实验项目：自然语言控 PC |

### 赛道 4：杀毒引擎集成

**未找到任何开源桌面工具做「经用户同意、从官方源下载并验签 KVRT，再集成其扫描报告」**。
桌面工具与杀毒引擎的集成存在真实空白（受限于厂商 EULA，多数项目选择不碰）。

## 二、定位判断

1. **单项不构成发布理由**：进程调度+内存清理单项，ThreadPilot 更成熟（版本迭代、包管理器分发、原生 UI）。
2. **组合定位目前无同类**：把 **CPU、内存、本地大模型、安全扫描视为同一个「算力资源池」调度**，
   配自然语言指令与注意力审计界面——调研范围内没有发现第二家。
   尤其模型路由：传统优化器不理解「载入 7B 模型 = 6GB 显存被长期占用」这类资源语义。
3. **诚实声明**：本项目的进程操作能力低于 ThreadPilot（无 CPU Sets / 亲和性拓扑），
   内存清理深度低于 Mem Reduct（Native API 级别）；差异化在组合、模型路由与安全链路集成。

## 三、从竞品身上学什么（转化为待办）

| 来源 | 实践 | 本项目行动 |
|---|---|---|
| ThreadPilot | guardrails 显式声明（High 警告 / Realtime 阻止） | 进程操作界面可加同等显式安全边界提示 |
| ThreadPilot | WinGet / Chocolatey 包管理器分发 | 发布路径后续选项 |
| Mem Reduct | GPG 签名 release 二进制 | 签名路线文档已列，执行时参考 |
| WinUtil | tweaks 配置文件化 + 可回退 + 恢复点 | 调度规则的未来形态参考 |
| Zanrei | docs/ 内竞品对比研究文档 | 本文档 |
| LocalAI-Desktop | 命令白名单 + 危险命令拒绝 | 自然语言指令链路的安全模型对齐 |
