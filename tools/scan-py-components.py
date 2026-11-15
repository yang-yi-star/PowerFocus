"""扫 v0.11 的四个 Python 组件：行数、体积、顶层符号。"""
import re
import sys
from pathlib import Path

ROOT = Path(r"E:\PowerFocus\versions\v0.11")
NAMES = ["dependency_bootstrap.py", "engine_adapters.py", "kvrt_bundle.py", "security_scan.py"]

SYM = re.compile(r"^(?:def|class)\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)


def main() -> int:
    for name in NAMES:
        p = ROOT / name
        if not p.exists():
            print(f"{name}: 不存在")
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        syms = SYM.findall(text)
        print(f"{name:<26} {len(lines):>5} 行  {p.stat().st_size/1024:>6.1f} KB  符号 {len(syms)}")
        print("    " + "、".join(syms[:16]))
        if len(syms) > 16:
            print(f"    ... 另有 {len(syms)-16} 个")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
