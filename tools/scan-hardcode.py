"""扫全仓硬编码：绝对路径 / 魔法端口 / 写死版本号 / 魔法数字。

用法：E:\\PowerFocus\\.venv\\Scripts\\python.exe tools\\scan-hardcode.py
产出：tools\\hardcode-report.json + 控制台摘要

口径：
- 只扫"活代码"：versions\\v0.11、product\\v1.00\\app、mcp、根级 .py/.ps1
- 跳过 archive、v2-archive、versions\\v0.05-v0.10、.venv、engines、backup
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(r"E:\PowerFocus")
OUT = ROOT / "tools" / "hardcode-report.json"

SKIP_DIRS = {
    ".venv", "archive", "v2-archive", "engines", "node_modules", "__pycache__",
    "ps1-bom-backup", "dist", "build", "prototype", "docs", "marketing",
    "tests", "tools",
}

# 每种硬编码的识别规则
PATTERNS = [
    ("绝对路径-Windows", re.compile(r"[A-Za-z]:\\\\[^\s\"'\)\]]+|(?<![A-Za-z])[A-Za-z]:\\[^\s\"'\)\]]+")),
    ("绝对盘符简写", re.compile(r"(?<![A-Za-z])[A-Za-z]:\\\\?[A-Za-z]")),
    ("写死版本号", re.compile(r"['\"]0\.(?:0[5-9]|1[01])['\"]|v0\.(?:0[5-9]|1[01])")),
    ("写死端口", re.compile(r"\b(?:18080|11434|8080|18081|18120)\b")),
    ("魔法数字-显存预留", re.compile(r"\b(?:512|1024|2048|4096)\b(?=\s*(?:#|$|;|\)|,)|\s*$)")),
]


def read_text(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8-sig", errors="replace")
    except Exception:
        return ""


def walk() -> list[Path]:
    targets = []
    # 活代码根
    for sub in ("versions/v0.11", "product/v1.00/app", "mcp"):
        d = ROOT / sub
        if d.exists():
            targets.extend(p for p in d.rglob("*") if p.is_file() and p.suffix in {".ps1", ".py", ".json", ".js", ".html"})
    # 根级脚本
    for p in ROOT.glob("*.py"):
        targets.append(p)
    for p in ROOT.glob("*.ps1"):
        targets.append(p)
    # 过滤
    out = []
    for p in targets:
        parts = set(p.parts)
        if any(s in parts for s in ("archive", "v2-archive", "engines", "__pycache__", ".venv", "ps1-bom-backup")):
            continue
        if any(f"v0.0{i}" in p.parts for i in range(5, 10)):
            continue
        out.append(p)
    return out


def main() -> int:
    files = walk()
    report = []

    for p in files:
        text = read_text(p)
        if not text:
            continue
        rel = str(p.relative_to(ROOT)).replace("\\", "/")
        hits = []
        for i, line in enumerate(text.splitlines(), 1):
            s = line.strip()
            if not s or s.startswith("#") and len(s) < 4:
                continue
            for kind, rx in PATTERNS:
                for m in rx.finditer(line):
                    tok = m.group(0)
                    # 数字类误报过滤：太小或明显是别的
                    if kind == "魔法数字-显存预留":
                        if i and tok in ("512", "1024"):
                            # 只保留出现在赋值右侧的
                            if not re.search(rf"{tok}\s*(?:#|;|$)", s):
                                continue
                    hits.append({
                        "line": i,
                        "kind": kind,
                        "token": tok.strip(),
                        "text": s[:180],
                    })
        if hits:
            report.append({"file": rel, "hits": hits})

    total = sum(len(r["hits"]) for r in report)
    kinds = {}
    for r in report:
        for h in r["hits"]:
            kinds[h["kind"]] = kinds.get(h["kind"], 0) + 1

    OUT.write_text(json.dumps({
        "scanned_files": len(files),
        "hit_files": len(report),
        "total_hits": total,
        "by_kind": kinds,
        "detail": report,
    }, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"扫描 {len(files)} 个活代码文件，{len(report)} 个有命中，共 {total} 处")
    print()
    for k, v in sorted(kinds.items(), key=lambda x: -x[1]):
        print(f"  {k:<20} {v}")
    print()
    print("前 12 个命中文件：")
    for r in sorted(report, key=lambda x: -len(x["hits"]))[:12]:
        print(f"  {len(r['hits']):>3} 处  {r['file']}")
    print(f"\n明细: {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
