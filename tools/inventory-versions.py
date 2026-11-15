"""版本台账采集器：扫描 versions\\v0.05 .. v0.11，产出可比对的原始数据。

用法：E:\\PowerFocus\\.venv\\Scripts\\python.exe tools\\inventory-versions.py

设计要点：
- engines 目录单独统计，不进 SHA 计算（v0.10 有 394MB 死资产，会淹没台账）
- __pycache__ / .lock / logs 运行时产物不计入"版本内容"
- 每个文件记 size + sha256，用于跨版本判定"同一份"还是"真改过"
"""
import hashlib
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(r"E:\PowerFocus\versions")
VERS = ["v0.05", "v0.06", "v0.07", "v0.08", "v0.09", "v0.10", "v0.11"]

# 单列统计，不进 SHA
HEAVY_DIRS = {"engines"}
# 运行时产物，不算版本内容
NOISE_DIRS = {"__pycache__", ".pytest_cache", ".ruff_cache"}
NOISE_SUFFIX = {".lock", ".pyc", ".pyo", ".log"}


def is_noise(p: Path, base: Path) -> bool:
    parts = set(p.relative_to(base).parts[:-1])
    if parts & NOISE_DIRS:
        return True
    return p.suffix.lower() in NOISE_SUFFIX


def is_heavy(p: Path, base: Path) -> bool:
    parts = set(p.relative_to(base).parts[:-1])
    return bool(parts & HEAVY_DIRS)


def sha256_of(p: Path, limit_mb: int = 64) -> str:
    """大文件只取前 limit_mb 做指纹，避免扫描过慢；返回带前缀标记。"""
    size = p.stat().st_size
    h = hashlib.sha256()
    if size > limit_mb * 1024 * 1024:
        with open(p, "rb") as f:
            h.update(f.read(limit_mb * 1024 * 1024))
        return "part:" + h.hexdigest()[:32]
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:32]


def scan_version(v: str) -> dict:
    base = ROOT / v
    if not base.exists():
        return {"version": v, "exists": False}

    content = []
    heavy = []
    heavy_total = 0

    for p in base.rglob("*"):
        if not p.is_file():
            continue
        try:
            st = p.stat()
        except OSError:
            continue
        rel = p.relative_to(base).as_posix()

        if is_heavy(p, base):
            heavy_total += st.st_size
            heavy.append({"path": rel, "size": st.st_size})
            continue
        if is_noise(p, base):
            continue

        content.append(
            {
                "path": rel,
                "size": st.st_size,
                "sha": sha256_of(p),
                "mtime": st.st_mtime,
            }
        )

    content.sort(key=lambda x: (-x["size"], x["path"]))

    # 目录分布
    dirs = defaultdict(lambda: {"count": 0, "size": 0})
    for f in content:
        top = f["path"].split("/")[0] if "/" in f["path"] else "(根)"
        if "/" in f["path"]:
            top = top + "/"
        dirs[top]["count"] += 1
        dirs[top]["size"] += f["size"]

    return {
        "version": v,
        "exists": True,
        "content_files": len(content),
        "content_bytes": sum(f["size"] for f in content),
        "heavy_files": len(heavy),
        "heavy_bytes": heavy_total,
        "dirs": {k: v2 for k, v2 in sorted(dirs.items())},
        "files": content,
        "heavy_sample": sorted(heavy, key=lambda x: -x["size"])[:8],
    }


def main() -> int:
    out = {"generated_by": "tools/inventory-versions.py", "versions": []}

    for v in VERS:
        info = scan_version(v)
        out["versions"].append(info)
        if info.get("exists"):
            print(
                f"{v}: {info['content_files']:>5} 文件 / "
                f"{info['content_bytes']/1048576:>8.2f} MB"
                f"    (+heavy {info['heavy_files']} 文件 / {info['heavy_bytes']/1048576:.1f} MB)"
            )
        else:
            print(f"{v}: 不存在")

    # 跨版本存在矩阵：以"最小路径集合"为行
    all_paths = sorted({f["path"] for v in out["versions"] if v.get("exists") for f in v["files"]})
    matrix = []
    for path in all_paths:
        row = {"path": path, "cells": {}}
        for v in out["versions"]:
            if not v.get("exists"):
                continue
            hit = next((f for f in v["files"] if f["path"] == path), None)
            row["cells"][v["version"]] = None if hit is None else hit["sha"]
        matrix.append(row)

    out["matrix"] = matrix
    out["all_paths_count"] = len(all_paths)

    dest = Path(r"E:\PowerFocus\tools\versions-inventory.json")
    dest.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n落盘: {dest}  ({dest.stat().st_size/1024:.1f} KB)")
    print(f"跨版本路径总数: {len(all_paths)}")

    # 控制台摘要：只在一版存在的文件（潜在孤儿）
    orphan = []
    for row in matrix:
        present = [v for v, s in row["cells"].items() if s]
        if len(present) == 1:
            orphan.append((row["path"], present[0]))
    print(f"仅存在于单一版本的文件: {len(orphan)}")
    for p, v in orphan[:20]:
        print(f"   [{v}] {p}")
    if len(orphan) > 20:
        print(f"   ...另有 {len(orphan)-20} 项")

    return 0


if __name__ == "__main__":
    sys.exit(main())
