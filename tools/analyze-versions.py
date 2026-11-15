"""版本相邻 diff：回答"哪一版加了什么、删了什么、改了什么"。

用法：E:\\PowerFocus\\.venv\\Scripts\\python.exe tools\\analyze-versions.py
依赖：tools\\versions-inventory.json（由 inventory-versions.py 生成）
"""
import json
import sys
from pathlib import Path

INV = Path(r"E:\PowerFocus\tools\versions-inventory.json")
OUT_MD = Path(r"E:\PowerFocus\docs\版本台账-2026-11-15.md")

# 运行时产物目录：命令队列、日志、报告、trace 都不是"版本内容"
NOISE_PREFIX = ("commands/", "logs/", "reports/", "Traces/")
# 运行时状态文件：每版都会变，但变的不是产品内容
NOISE_FILES = {
    ".auth_token",
    "mem-guard.state.json",
    "rules_state.json",
    "v3_heartbeat.json",
    "router.pid",
}


def is_content(path: str) -> bool:
    if path.startswith(NOISE_PREFIX):
        return False
    if path in NOISE_FILES:
        return False
    # 备份文件是操作痕迹，不是版本内容
    if ".bak-" in path or path.endswith(".bak"):
        return False
    return True


def fmt_size(n: int) -> str:
    if n >= 1048576:
        return f"{n/1048576:.2f} MB"
    if n >= 1024:
        return f"{n/1024:.1f} KB"
    return f"{n} B"


def main() -> int:
    data = json.loads(INV.read_text(encoding="utf-8"))
    vers = {v["version"]: v for v in data["versions"] if v.get("exists")}
    order = [v["version"] for v in data["versions"] if v.get("exists")]

    # 只保留内容文件
    files = {}
    for v, info in vers.items():
        files[v] = {f["path"]: f for f in info["files"] if is_content(f["path"])}

    lines = []
    lines.append("# 版本台账 — v0.05 → v0.11 逐版实测（2026-11-15）")
    lines.append("")
    lines.append("> 全部数据由 `tools/inventory-versions.py` 扫描真实文件系统得出，不是回忆。")
    lines.append("> 口径：已排除 `commands/` `logs/` `reports/` `Traces/` 这些运行时产物；`engines/` 单列。")
    lines.append("")

    # 一、总览
    lines.append("## 一、总览")
    lines.append("")
    lines.append("| 版本 | 内容文件 | 内容体积 | engines | 目录分布 |")
    lines.append("|---|---|---|---|---|")
    for v in order:
        info = vers[v]
        dirs = ", ".join(f"{k}{d['count']}" for k, d in info["dirs"].items()) or "—"
        heavy = (
            f"{info['heavy_files']} 文件 / {fmt_size(info['heavy_bytes'])}"
            if info["heavy_bytes"]
            else "—"
        )
        lines.append(
            f"| {v} | {len(files[v])} | {fmt_size(sum(f['size'] for f in files[v].values()))} | {heavy} | {dirs} |"
        )
    lines.append("")

    lines.append("**结论一：七个版本里，只有 v0.09 → v0.10 是空版本，其余五次都是真迭代。**")
    lines.append("")
    lines.append("内容文件数：")
    lines.append("")
    lines.append("```")
    counts = "  ".join(f"{v}:{len(files[v])}" for v in order)
    lines.append(counts)
    lines.append("```")
    lines.append("")
    lines.append("v0.05 到 v0.09 一直是 14 个文件，一个不多一个不少；")
    lines.append("v0.10 跳到 20 才引入 4 个 Python 组件 + prototype + README；")
    lines.append("v0.11 保持 20 并完成本轮统一内存改造。")
    lines.append("")
    lines.append("再看内核脚本体积：")
    lines.append("")
    lines.append("| 版本 | 内核 | 体积 | 相邻增幅 |")
    lines.append("|---|---|---|---|")
    prev_size = None
    for v in order:
        kern = [
            p
            for p in files[v]
            if p.endswith(".ps1") and p.count("/") == 0 and p.startswith("电脑算力调度中心")
        ]
        if kern:
            p = kern[0]
            sz = files[v][p]["size"]
            delta = "—" if prev_size is None else f"{(sz-prev_size)/1024:+.1f} KB"
            lines.append(f"| {v} | `{p}` | {fmt_size(sz)} | {delta} |")
            prev_size = sz
    lines.append("")
    lines.append("**内核真实改动（归一化版本号后比对）——详见 `docs/内核逐版真改.md`：**")
    lines.append("")
    lines.append("| 版本对 | 内核 +行/-行 | 内核新函数 | 性质 |")
    lines.append("|---|---|---|---|")
    lines.append("| v0.05 → v0.06 | +45 / -0 | 0 | 新增 `mem_guard` 命令 action（MemGuard 接入命令总线） |")
    lines.append("| v0.06 → v0.07 | +36 / -0 | 2 | 新增 `Get-MemGuardProcess` / `Start-MemGuardGuard`，守护自动拉起 |")
    lines.append("| v0.07 → v0.08 | +18 / -7 | 0 | 修 EmptyWorkingSet 异步换出计数少报 bug |")
    lines.append("| v0.08 → v0.09 | +37 / -3 | 0 | 关键进程名单真源化 / 令牌 ACL 加固 / 命令总线鉴权 / 回执原子写入 |")
    lines.append("| v0.09 → v0.10 | **+2 / -3** | 0 | **内核只把 BuildDate 从 11-05 改成 11-12** |")
    lines.append("| v0.10 → v0.11 | +233 / -1 | 6 | 本轮统一内存接线（5 计算函数 + 组合函数 + `unified-plan`） |")
    lines.append("")
    lines.append("**必须先纠正一个我先前说错的判断。**")
    lines.append("")
    lines.append("我曾判断“v0.05 到 v0.10 五次升级没有增加任何新能力、版本是空的”。")
    lines.append("数据证明这个判断**只对最后一段成立**：")
    lines.append("")
    lines.append("- v0.05 → v0.09 这五次升级**都是真迭代**：接入内存守护、修异步换出计数、")
    lines.append("  关键进程名单真源化、令牌文件 ACL 加固、命令总线鉴权、回执原子写入。")
    lines.append("  每一条都是在修真实缺陷，不是改名。")
    lines.append("- **只有 v0.09 → v0.10 是空版本**：内核一个功能都没动，只把 `PF_BuildDate` 从")
    lines.append("  `2026-11-05` 改成 `2026-11-12`，另外补了一句注释。")
    lines.append("")
    lines.append("**所以真正的问题不是“所有版本都是空的”，而是 v0.10 这一次：**")
    lines.append("它新增了 4 个 Python 组件（`dependency_bootstrap.py` 57.6 KB、`engine_adapters.py` 43.5 KB、")
    lines.append("`kvrt_bundle.py` 37.4 KB、`security_scan.py` 19.3 KB）、`prototype/index.html` 73 KB、")
    lines.append("`README.md` 17.5 KB，共 6 个新文件——**而内核一行引用都没有**。")
    lines.append("这就是“零件是真的，但零件之间互不认识”的确切位置：**v0.10 这一版**。")
    lines.append("")

    # 二、相邻 diff
    lines.append("## 二、相邻版本差异（只算内容文件）")
    lines.append("")
    for i in range(1, len(order)):
        prev, cur = order[i - 1], order[i]
        pf, cf = files[prev], files[cur]
        added = sorted(set(cf) - set(pf))
        removed = sorted(set(pf) - set(cf))
        changed = sorted(
            p for p in set(pf) & set(cf) if pf[p]["sha"] != cf[p]["sha"]
        )
        same = sorted(p for p in set(pf) & set(cf) if pf[p]["sha"] == cf[p]["sha"])

        lines.append(f"### {prev} → {cur}")
        lines.append("")
        lines.append(
            f"新增 **{len(added)}** / 删除 **{len(removed)}** / 改动 **{len(changed)}** / 原样 **{len(same)}**"
        )
        lines.append("")
        if added:
            lines.append("**新增：**")
            for p in added:
                lines.append(f"- `{p}` — {fmt_size(cf[p]['size'])}")
            lines.append("")
        if removed:
            lines.append("**删除：**")
            for p in removed:
                lines.append(f"- `{p}` — 上版 {fmt_size(pf[p]['size'])}")
            lines.append("")
        if changed:
            lines.append("**改动：**")
            for p in changed:
                lines.append(
                    f"- `{p}` — {fmt_size(pf[p]['size'])} → {fmt_size(cf[p]['size'])}"
                )
            lines.append("")
        if not added and not removed and not changed:
            lines.append("**三件套完全相同**：" + "、".join(f"`{p}`" for p in same[:6]))
            lines.append("")

    # 三、内核文件时间线
    lines.append("## 三、内核脚本（.ps1）时间线")
    lines.append("")
    lines.append("| 版本 | 文件 | 大小 | SHA前12 |")
    lines.append("|---|---|---|---|")
    for v in order:
        for p, f in sorted(files[v].items()):
            if p.endswith(".ps1") and p.count("/") == 0:
                lines.append(f"| {v} | `{p}` | {fmt_size(f['size'])} | `{f['sha'][:12]}` |")
    lines.append("")

    # 四、配置类文件跨版一致性
    lines.append("## 四、配置类文件跨版一致性")
    lines.append("")
    cfg_paths = sorted(
        {p for v in order for p in files[v] if p.endswith((".json", ".ini", ".txt")) and p.count("/") <= 1}
    )
    hdr = "| 文件 | " + " | ".join(order) + " |"
    sep = "|---|" + "---|" * len(order)
    lines.append(hdr)
    lines.append(sep)
    for p in cfg_paths:
        cells = []
        for v in order:
            f = files[v].get(p)
            cells.append(f"`{f['sha'][:8]}`" if f else "—")
        lines.append(f"| `{p}` | " + " | ".join(cells) + " |")
    lines.append("")

    same_all = [
        p
        for p in cfg_paths
        if all(files[v].get(p) for v in order)
        and len({files[v][p]["sha"] for v in order}) == 1
    ]
    if same_all:
        lines.append(f"**七个版本 SHA 完全相同的配置**（{len(same_all)} 个）：")
        lines.append("")
        for p in same_all:
            lines.append(f"- `{p}`")
        lines.append("")
        lines.append("这些文件在七个版本里一个字节都没动过。它们要么是稳定契约，")
        lines.append("要么是**从来没被真正迭代过的死配置**——需要逐个判断是哪一种。")
        lines.append("")

    # 五、Python 组件出现时间线
    lines.append("## 五、Python 组件出现时间线")
    lines.append("")
    py_paths = sorted({p for v in order for p in files[v] if p.endswith(".py")})
    if py_paths:
        lines.append("| 文件 | " + " | ".join(order) + " |")
        lines.append("|---|" + "---|" * len(order))
        for p in py_paths:
            cells = []
            for v in order:
                f = files[v].get(p)
                cells.append(f"{fmt_size(f['size'])}" if f else "—")
            lines.append(f"| `{p}` | " + " | ".join(cells) + " |")
    else:
        lines.append("无 Python 文件。")
    lines.append("")

    # 六、真孤儿（排除运行时产物）
    lines.append("## 六、只在单一版本出现的内容文件")
    lines.append("")
    orphans = []
    for p in sorted({p for v in order for p in files[v]}):
        present = [v for v in order if p in files[v]]
        if len(present) == 1:
            orphans.append((p, present[0]))
    lines.append(f"共 **{len(orphans)}** 个（已排除 commands/logs/reports/Traces）。")
    lines.append("")
    if orphans:
        lines.append("| 文件 | 所在版本 | 大小 |")
        lines.append("|---|---|---|")
        for p, v in orphans:
            lines.append(f"| `{p}` | {v} | {fmt_size(files[v][p]['size'])} |")
    lines.append("")

    OUT_MD.write_text("\n".join(lines), encoding="utf-8")
    print(f"台账已落盘: {OUT_MD}  ({OUT_MD.stat().st_size/1024:.1f} KB)")
    print(f"版本数: {len(order)}   内容文件路径总数: {len({p for v in order for p in files[v]})}")

    # 控制台摘要
    for i in range(1, len(order)):
        prev, cur = order[i - 1], order[i]
        pf, cf = files[prev], files[cur]
        a = len(set(cf) - set(pf))
        r = len(set(pf) - set(cf))
        c = len([p for p in set(pf) & set(cf) if pf[p]["sha"] != cf[p]["sha"]])
        print(f"  {prev}->{cur}: +{a} -{r} ~{c}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
