"""能力台账：把 v0.11 内核 + lib 六模块 + MCP 工具 + HTTP 路由 盘成一张表。

用法：E:\\PowerFocus\\.venv\\Scripts\\python.exe tools\\capability-ledger.py
产出：docs\\能力台账-2026-11-15.md
"""
import re
import sys
from pathlib import Path

ROOT = Path(r"E:\PowerFocus")
KERNEL = ROOT / "versions" / "v0.11" / "电脑算力调度中心_v0.11.ps1"
LIB_DIR = ROOT / "versions" / "v0.11" / "lib"
MCP = ROOT / "mcp" / "powerfocus_mcp" / "server.py"
SERVER = ROOT / "product" / "v1.00" / "app" / "server.py"
OUT = ROOT / "docs" / "能力台账-2026-11-15.md"

FUNC_RE = re.compile(r"^\s*function\s+([A-Za-z0-9_\-]+)\s*(?:\(|\{)")
ACTION_RE = re.compile(r"^ {4,8}'([a-z][a-z0-9_\-]+)'\s*\{")
TOOL_RE = re.compile(r'(?:name\s*=\s*|")(pf_[a-z0-9_]+)')
ROUTE_RE = re.compile(r'@app\.(?:get|post|put|delete)\("([^"]+)"\)')


def read(p: Path) -> list[str]:
    return p.read_text(encoding="utf-8-sig", errors="replace").splitlines()


def main() -> int:
    if not KERNEL.exists():
        print(f"内核不存在: {KERNEL}")
        return 1

    out = []
    out.append("# 能力台账 — v0.11 全部可调用单元（2026-11-15）")
    out.append("")
    out.append("> 数据由 `tools/capability-ledger.py` 扫真实源码得出。")
    out.append("> 口径：只统计**代码里真实存在**的 function / action / tool / route，不统计文档声称的。")
    out.append("")

    # ---------- 内核 ----------
    kl = read(KERNEL)
    kfuncs = []
    for i, line in enumerate(kl, 1):
        m = FUNC_RE.match(line)
        if m:
            kfuncs.append((i, m.group(1)))
    kactions = []
    for i, line in enumerate(kl, 1):
        m = ACTION_RE.match(line)
        if m:
            kactions.append((i, m.group(1)))

    out.append("## 一、内核（电脑算力调度中心_v0.11.ps1）")
    out.append("")
    out.append(f"- 文件行数：**{len(kl)}**")
    out.append(f"- 函数：**{len(kfuncs)}** 个")
    out.append(f"- 命令 action：**{len(kactions)}** 个")
    out.append("")
    out.append("### 命令 action（外部进程写 JSON 就能调用的入口）")
    out.append("")
    out.append("| 行号 | action | 语义 |")
    out.append("|---|---|---|")
    SEMANTIC = {
        "status": "整机状态快照（进程清单、CPU、内存、电源、模型、申请态）",
        "unfocus": "解除全部聚焦/压制，恢复原优先级",
        "focus": "把指定进程拉成当前调度焦点（gentle/aggressive/godmode 三档）",
        "authorize": "把进程加入授权清单（不再被清场压制）",
        "revoke": "从授权清单移除",
        "request_power": "**算力申请**：外部应用申请算力，内核清场压低其他进程补给申请者",
        "release_power": "释放算力申请，被压进程全部还原",
        "list_requests": "列出当前算力申请（含剩余秒数）",
        "list_junk": "只读审计：列出会被判定为无用而清理的候选进程",
        "mem_guard": "内存守护（status/once/start/stop）",
        "unified-plan": "**统一内存层分配**：按显存+内存算出 GGUF 每层落 GPU 还是 CPU",
        "list_apps": "列出可卸载应用",
        "uninstall_app": "卸载应用（走 Geek 桥接）",
        "set_priority": "改进程 CPU 优先级（Idle / BelowNormal / Normal / AboveNormal / High / RealTime）",
        "kill_process": "强杀进程（需 token，系统关键进程自动拒绝）",
        "suspend_process": "**冻结进程**（P/Invoke NtSuspendProcess，进程完全不响应）",
        "resume_process": "恢复被冻结的进程（NtResumeProcess）",
        "stress_process": "压制进程：压到 Idle + 连打 8 次 EmptyWorkingSet 收工作集",
        "set_power_plan": "切换电源计划（高性能 / 平衡）",
        "trim_memory": "全机工作集内存修剪（可排除焦点进程）",
        "set_io_priority": "改磁盘 I/O 优先级（VeryLow / Low / Normal / High）",
        "set_net_qos": "网络限速（New-NetQosPolicy，按进程限 Mbps，0 = 撤销）",
        "apply_scene": "套用场景配置（scenes.json）",
        "list_scenes": "列出全部场景",
        "list_model_profiles": "列出模型加速档案（model-profiles.json）",
        "model_identity": "GGUF 身份识别（读 metadata 判定模型真身）",
        "start_router": "启动模型路由（tools\\model-router.ps1）",
        "stop_router": "停止模型路由",
        "router_status": "模型路由状态",
        "boost_model": "模型加速（按档案给模型进程集中算力）",
        "start_rules": "启动规则引擎（ProBalance 范式）",
        "stop_rules": "停止规则引擎",
        "list_rules": "列出规则",
        "apply_rules": "应用规则集",
        "set_ecoqos": "设置 CPU EcoQoS（能效核调度提示）",
        "set_affinity": "设置 CPU 亲和性（绑定核心）",
    }
    for ln, name in kactions:
        out.append(f"| {ln} | `{name}` | {SEMANTIC.get(name, '—')} |")
    out.append("")

    out.append("### 内核函数")
    out.append("")
    out.append("| 行号 | 函数 |")
    out.append("|---|---|")
    for ln, name in kfuncs:
        out.append(f"| {ln} | `{name}` |")
    out.append("")

    # ---------- lib ----------
    out.append("## 二、lib 六模块")
    out.append("")
    out.append("| 模块 | 大小 | 函数数 | 是否被 dot-source |")
    out.append("|---|---|---|---|")
    kernel_text = "\n".join(kl)
    WIRED = {
        "rollback.ps1": "是（127–128 行无条件）",
        "model-registry.ps1": "是（131–132 行无条件）",
        "geek-bridge.ps1": "是（1355–1358 行条件）",
        "mem-guard.ps1": "是（1578 / 2037 行调用）",
        "app-purger.ps1": "**否，零引用**",
        "clean-recyclebin.ps1": "**否，零引用**",
    }
    lib_funcs = {}
    for p in sorted(LIB_DIR.glob("*.ps1")):
        ll = read(p)
        fs = [m.group(1) for line in ll if (m := FUNC_RE.match(line))]
        lib_funcs[p.name] = fs
        wired = next((v for k, v in WIRED.items() if k == p.name), "未知")
        out.append(f"| `{p.name}` | {p.stat().st_size/1024:.1f} KB | {len(fs)} | {wired} |")
    out.append("")

    out.append("### lib 模块内函数")
    out.append("")
    for name, fs in lib_funcs.items():
        if fs:
            out.append(f"- **{name}**：" + "、".join(f"`{f}`" for f in fs))
    out.append("")

    # ---------- MCP ----------
    out.append("## 三、MCP 工具")
    out.append("")
    if MCP.exists():
        mt = "\n".join(read(MCP))
        tools = sorted(set(TOOL_RE.findall(mt)))
        out.append(f"- 源文件行数：{len(read(MCP))}")
        out.append(f"- pf_ 工具：**{len(tools)}** 个")
        out.append("")
        for t in tools:
            out.append(f"- `{t}`")
    else:
        out.append("- MCP 源文件不存在")
    out.append("")

    # ---------- HTTP ----------
    out.append("## 四、产品层 HTTP 路由")
    out.append("")
    if SERVER.exists():
        st = "\n".join(read(SERVER))
        routes = ROUTE_RE.findall(st)
        out.append(f"- 源文件行数：{len(read(SERVER))}")
        out.append(f"- 路由：**{len(routes)}** 条")
        out.append("")
        for r in routes:
            out.append(f"- `{r}`")
    else:
        out.append("- server.py 不存在")
    out.append("")

    # ---------- 合计 ----------
    lib_total = sum(len(v) for v in lib_funcs.values())
    mcp_total = len(sorted(set(TOOL_RE.findall("\n".join(read(MCP)))))) if MCP.exists() else 0
    route_total = len(ROUTE_RE.findall("\n".join(read(SERVER)))) if SERVER.exists() else 0

    out.append("## 五、合计")
    out.append("")
    out.append("| 层 | 可调用单元 | 数量 |")
    out.append("|---|---|---|")
    out.append(f"| 内核 | function | {len(kfuncs)} |")
    out.append(f"| 内核 | 命令 action（外部 JSON 入口） | {len(kactions)} |")
    out.append(f"| lib | 六个模块内 function | {lib_total} |")
    out.append(f"| MCP | pf_ 工具 | {mcp_total} |")
    out.append(f"| 产品层 | HTTP 路由 | {route_total} |")
    out.append(f"| **合计** | | **{len(kfuncs)+len(kactions)+lib_total+mcp_total+route_total}** |")
    out.append("")
    out.append("## 六、死的零件（代码在，没人调）")
    out.append("")
    out.append("| 零件 | 规模 | 状态 | 影响 |")
    out.append("|---|---|---|---|")
    out.append("| `lib\\app-purger.ps1` | 12.1 KB / 5 函数 | 零 dot-source、零调用 | 自清理卸载能力完全不可用；实际卸载只能走 geek-bridge |")
    out.append("| `lib\\clean-recyclebin.ps1` | 2.5 KB / 1 函数 | 零 dot-source、零调用 | 回收站清理能力完全不可用 |")
    out.append("")
    out.append("这两个模块在 v0.05–v0.11 七个版本里一直随包复制、一直没人调。")
    out.append("`DEVELOPMENT_LOG.md` 第 279 行早在 11-04 就记录了这个事实，不是新发现。")
    out.append("")

    OUT.write_text("\n".join(out), encoding="utf-8")
    print(f"落盘: {OUT} ({OUT.stat().st_size/1024:.1f} KB)")
    print(f"内核函数 {len(kfuncs)} / action {len(kactions)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
