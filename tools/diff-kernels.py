"""内核逐版真 diff：归一化版本号后比对，回答"哪一版加了什么能力"。

用法：E:\\PowerFocus\\.venv\\Scripts\\python.exe tools\\diff-kernels.py
产出：docs\\内核逐版真改.md
"""
import difflib
import re
import sys
from pathlib import Path

VER_ROOT = Path(r"E:\PowerFocus\versions")
OUT = Path(r"E:\PowerFocus\docs\内核逐版真改.md")
VERS = ["v0.05", "v0.06", "v0.07", "v0.08", "v0.09", "v0.10", "v0.11"]

# 版本号归一化：v0.05 / V0.05 / 0.05 统一成一个占位符，避免"改个版本号"被算成改动
VER_RE = re.compile(r"v?0\.(?:0[5-9]|1[01])", re.IGNORECASE)


def kernel_path(v: str) -> Path:
    return VER_ROOT / v / f"电脑算力调度中心_{v}.ps1"


def read_lines(p: Path) -> list[str]:
    # 内核带 BOM，用 utf-8-sig 读
    return p.read_text(encoding="utf-8-sig").splitlines()


def norm(line: str) -> str:
    return VER_RE.sub("v<X>", line.strip())


def funcs(lines: list[str]) -> set[str]:
    """提取所有 function 名"""
    return {
        m.group(1)
        for line in lines
        if (m := re.match(r"\s*function\s+([A-Za-z0-9_\-]+)", line))
    }


def actions(lines: list[str]) -> set[str]:
    """提取命令总线 action 名（8 空格缩进的 'xxx' { ）"""
    return {
        m.group(1)
        for line in lines
        if (m := re.match(r"\s{8}'([a-z0-9\-]+)'\s*\{", line))
    }


def main() -> int:
    existing = [v for v in VERS if kernel_path(v).exists()]
    if len(existing) < 2:
        print("内核文件不足两个，无法比对")
        return 1

    cache = {}
    for v in existing:
        raw = read_lines(kernel_path(v))
        cache[v] = {
            "raw": raw,
            "norm": [norm(l) for l in raw],
            "funcs": funcs(raw),
            "actions": actions(raw),
        }

    lines_out = []
    lines_out.append("# 内核逐版真改 — 归一化版本号后的实际代码差异")
    lines_out.append("")
    lines_out.append("> 口径：把 `v0.05`…`v0.11` 这类字符串归一化成 `v<X>` 再比对，")
    lines_out.append("> 所以下面每一条都是**真的代码改动**，不是改版本号。")
    lines_out.append("")

    summary = []

    for i in range(1, len(existing)):
        prev, cur = existing[i - 1], existing[i]
        a, b = cache[prev], cache[cur]

        diff = list(difflib.unified_diff(a["norm"], b["norm"], lineterm="", n=0))
        added = [l[1:] for l in diff if l.startswith("+") and not l.startswith("+++")]
        removed = [l[1:] for l in diff if l.startswith("-") and not l.startswith("---")]

        f_new = sorted(b["funcs"] - a["funcs"])
        f_del = sorted(a["funcs"] - b["funcs"])
        a_new = sorted(b["actions"] - a["actions"])
        a_del = sorted(a["actions"] - b["actions"])

        lines_out.append(f"## {prev} → {cur}")
        lines_out.append("")
        lines_out.append(
            f"内核行数 **{len(a['raw'])} → {len(b['raw'])}**（{len(b['raw'])-len(a['raw']):+d}）  |  "
            f"真实改动 **+{len(added)} / -{len(removed)} 行**"
        )
        lines_out.append("")

        if f_new or f_del or a_new or a_del:
            lines_out.append("**能力增减：**")
            lines_out.append("")
            if f_new:
                lines_out.append(f"- 新增函数 {len(f_new)} 个：" + "、".join(f"`{x}`" for x in f_new))
            if f_del:
                lines_out.append(f"- 删除函数 {len(f_del)} 个：" + "、".join(f"`{x}`" for x in f_del))
            if a_new:
                lines_out.append(f"- 新增命令 action：" + "、".join(f"`{x}`" for x in a_new))
            if a_del:
                lines_out.append(f"- 删除命令 action：" + "、".join(f"`{x}`" for x in a_del))
            lines_out.append("")

        if added:
            lines_out.append("**新增内容（前 40 行）：**")
            lines_out.append("")
            lines_out.append("```powershell")
            for l in added[:40]:
                lines_out.append(l.rstrip())
            if len(added) > 40:
                lines_out.append(f"... 另有 {len(added)-40} 行")
            lines_out.append("```")
            lines_out.append("")

        if removed:
            lines_out.append("**删除内容（前 25 行）：**")
            lines_out.append("")
            lines_out.append("```powershell")
            for l in removed[:25]:
                lines_out.append(l.rstrip())
            if len(removed) > 25:
                lines_out.append(f"... 另有 {len(removed)-25} 行")
            lines_out.append("```")
            lines_out.append("")

        if not added and not removed:
            lines_out.append("**真实改动为零**：除了版本号字符串，内核一个字节都没变。")
            lines_out.append("")

        summary.append((prev, cur, len(added), len(removed), len(f_new), len(a_new)))

    lines_out.append("## 汇总")
    lines_out.append("")
    lines_out.append("| 版本对 | 新增行 | 删除行 | 新函数 | 新 action |")
    lines_out.append("|---|---|---|---|---|")
    for prev, cur, na, nr, nf, nac in summary:
        lines_out.append(f"| {prev} → {cur} | {na} | {nr} | {nf} | {nac} |")
    lines_out.append("")

    OUT.write_text("\n".join(lines_out), encoding="utf-8")
    print(f"落盘: {OUT} ({OUT.stat().st_size/1024:.1f} KB)")
    print("")
    print(f"{'版本对':<16} {'+行':>6} {'-行':>6} {'函数':>5} {'action':>7}")
    for prev, cur, na, nr, nf, nac in summary:
        print(f"{prev+'→'+cur:<16} {na:>6} {nr:>6} {nf:>5} {nac:>7}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
