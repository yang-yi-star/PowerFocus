"""列出关键代码文件里的硬编码明细（供人工判断哪些是真问题）。"""
import json
import sys
from pathlib import Path

REPORT = Path(r"E:\PowerFocus\tools\hardcode-report.json")
TARGETS = [
    "versions/v0.11/电脑算力调度中心_v0.11.ps1",
    "versions/v0.11/engine_adapters.py",
    "versions/v0.11/dependency_bootstrap.py",
    "versions/v0.11/lib/app-purger.ps1",
    "versions/v0.11/security_scan.py",
    "mcp/powerfocus_mcp/server.py",
    "product/v1.00/app/server.py",
]


def main() -> int:
    data = json.loads(REPORT.read_text(encoding="utf-8"))
    idx = {r["file"]: r["hits"] for r in data["detail"]}
    for t in TARGETS:
        hits = idx.get(t, [])
        print("")
        print("=" * 70)
        print(f"{t}  ({len(hits)} hits)")
        print("=" * 70)
        for h in hits:
            print(f"  L{h['line']:<5} [{h['kind']}] {h['token']}")
            print(f"         {h['text'][:150]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
