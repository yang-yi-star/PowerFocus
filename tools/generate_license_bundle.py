#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成可分发的第三方许可证包与 CycloneDX SBOM。

设计约束：
1. 只读取本机 `.venv` 的已安装元数据与随包许可证文件，不联网、不猜许可证。
2. 每个包生成一个独立文本，包含声明、来源文件、SHA256 与许可证全文。
3. 上游 wheel 缺许可证文件时，明确标记缺口；有已核实的上游 LICENSE 时单独覆盖。
4. 不把 pip 纳入运行时清单（pip 不随 exe 分发）。
5. 输出可复现：同一环境重复执行，除时间戳与 SBOM serialNumber 外内容一致。

用法：
    .venv\\Scripts\\python.exe tools\\generate_license_bundle.py
    .venv\\Scripts\\python.exe tools\\generate_license_bundle.py --check
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
import uuid
from importlib import metadata
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
LICENSE_DIR = ROOT / "LICENSES"
SBOM_PATH = ROOT / "SBOM.cdx.json"
INDEX_PATH = LICENSE_DIR / "index.json"

SKIP = {"pip"}
LICENSE_SUFFIXES = ("LICENSE", "LICENCE", "COPYING", "NOTICE")

# 由本机实际打包环境核定的 SPDX 标识。不要在生成时自动猜。
SPDX = {
    "altgraph": "MIT",
    "annotated-doc": "MIT",
    "annotated-types": "MIT",
    "anyio": "MIT",
    "bottle": "MIT",
    "certifi": "MPL-2.0",
    "cffi": "MIT-0",
    "click": "BSD-3-Clause",
    "clr-loader": "MIT",
    "colorama": "BSD-3-Clause",
    "fastapi": "MIT",
    "h11": "MIT",
    "httpcore": "BSD-3-Clause",
    "httpx": "BSD-3-Clause",
    "idna": "BSD-3-Clause",
    "iniconfig": "MIT",
    "opentelemetry-api": "Apache-2.0",
    "packaging": "Apache-2.0 OR BSD-2-Clause",
    "pefile": "MIT",
    "pluggy": "MIT",
    "proxy-tools": "BSD-2-Clause",
    "psutil": "BSD-3-Clause",
    "pycparser": "BSD-3-Clause",
    "pydantic": "MIT",
    "pydantic-core": "MIT",
    "pygments": "BSD-2-Clause",
    "pyinstaller": "GPL-2.0-or-later WITH Bootloader-exception",
    "pyinstaller-hooks-contrib": "Apache-2.0",
    "pytest": "MIT",
    "pythonnet": "MIT",
    "pywebview": "BSD-3-Clause",
    "pywin32-ctypes": "BSD-3-Clause",
    "ruff": "MIT",
    "setuptools": "MIT",
    "starlette": "BSD-3-Clause",
    "typing-inspection": "MIT",
    "typing-extensions": "PSF-2.0",
    "uvicorn": "BSD-3-Clause",
}

# wheel 未附带许可证文件，已从上游仓库核实并原样收录。
UPSTREAM_FALLBACKS = {
    "proxy-tools": {
        "spdx": "BSD-2-Clause",
        "source": "https://raw.githubusercontent.com/jtushman/proxy_tools/master/LICENSE.txt",
        "url": "https://github.com/jtushman/proxy_tools",
        "note": (
            "PyPI 元数据写的是 MIT，但上游仓库 LICENSE.txt 正文是 BSD 二条款，"
            "版权行为 Armin Ronacher (2013) / Jonathan Tushman (2014)。"
            "以许可证正文为准，按 BSD-2-Clause 分发。"
        ),
        "text": """The BSD License (BSD)

Copyright (c) 2013 Armin Ronacher
Copyright (c) 2014 Jonathan Tushman

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.""",
    }
}


def norm(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_text(path: Path) -> str:
    raw = path.read_bytes()
    for enc in ("utf-8", "utf-8-sig", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def license_files(dist_info: Path) -> List[Path]:
    found: List[Path] = []
    for p in dist_info.rglob("*"):
        if not p.is_file():
            continue
        if p.name.upper().startswith(LICENSE_SUFFIXES):
            found.append(p)
    return sorted(set(found), key=lambda p: str(p).lower())


def declared_license(meta: metadata.PackageMetadata) -> str:
    expr = (meta.get("License-Expression") or "").strip()
    if expr:
        return expr
    lic = (meta.get("License") or "").strip()
    if lic:
        first = " ".join(lic.splitlines()).strip()
        return first[:160] + ("…" if len(first) > 160 else "")
    classifiers = [c for c in (meta.get_all("Classifier") or []) if c.startswith("License ::")]
    return "; ".join(classifiers)


def read_lock() -> Dict[str, str]:
    lock = ROOT / "requirements.lock.txt"
    out: Dict[str, str] = {}
    if not lock.exists():
        return out
    for line in lock.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "==" not in line:
            continue
        name, version = line.split("==", 1)
        out[norm(name)] = version.strip()
    return out


def distributions() -> List[metadata.Distribution]:
    keep = []
    for dist in metadata.distributions():
        name = dist.metadata.get("Name")
        if not name or name.lower() in SKIP:
            continue
        keep.append(dist)
    return sorted(keep, key=lambda d: norm(d.metadata["Name"]))


def build_index(check_only: bool = False) -> dict:
    lock = read_lock()
    lock_drift = []
    packages = []
    for dist in distributions():
        name = dist.metadata["Name"]
        version = dist.version
        key = norm(name)
        di = Path(dist._path)  # importlib.metadata 的 Distribution 私有但稳定的落盘路径
        files = license_files(di)
        spdx = SPDX.get(key)
        if not spdx:
            raise SystemExit(f"未登记 SPDX 许可证：{name} {version}（先在 SPDX 表中核实）")

        texts = []
        sources = []
        for f in files:
            rel = str(f.relative_to(ROOT)) if f.is_relative_to(ROOT) else str(f)
            texts.append((f, read_text(f)))
            sources.append({
                "path": rel,
                "sha256": sha256(f),
                "bytes": f.stat().st_size,
            })

        fallback = None
        if not files:
            fallback = UPSTREAM_FALLBACKS.get(key)
            if fallback:
                spdx = fallback["spdx"]
                texts.append((None, fallback["text"]))
                sources.append({
                    "path": fallback["source"],
                    "sha256": hashlib.sha256(fallback["text"].encode("utf-8")).hexdigest(),
                    "bytes": len(fallback["text"].encode("utf-8")),
                    "upstream": True,
                })

        if not texts:
            raise SystemExit(f"缺少许可证全文且无已核实上游来源：{name} {version}")

        packages.append({
            "name": name,
            "normalized": key,
            "version": version,
            "spdx": spdx,
            "declared": declared_license(dist.metadata),
            "license_files": sources,
            "fallback_note": fallback["note"] if fallback else "",
            "texts": texts,
        })

        if key in lock and lock[key] != version:
            lock_drift.append({"name": name, "locked": lock[key], "installed": version})

    missing_in_lock = sorted(set(SPDX) - set(lock) - {"pywebview"})
    extra_in_lock = sorted(set(lock) - {norm(p["name"]) for p in packages})

    index = {
        "generated_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "root": ".",
        "generator": "tools/generate_license_bundle.py",
        "package_count": len(packages),
        "packages": [{k: v for k, v in p.items() if k != "texts"} for p in packages],
        "lock_drift": lock_drift,
        "missing_in_lock": missing_in_lock,
        "extra_in_lock": extra_in_lock,
        "notes": [
            "清单按本机 .venv 实际打包环境生成，不是 requirements.lock.txt 的理想版本。",
            "lock_drift 列出的版本差异在重新安装依赖前会继续存在；重新打包前应先对齐。",
            "proxy_tools 的 PyPI 元数据写 MIT，上游 LICENSE.txt 正文为 BSD-2-Clause，本包以正文为准。",
        ],
    }
    return index, packages


def render_package(p: dict) -> str:
    lines = [
        "PowerFocus 第三方许可证全文",
        "=" * 78,
        f"Package: {p['name']}",
        f"Version: {p['version']}",
        f"SPDX-License-Identifier: {p['spdx']}",
        f"Declared metadata: {p['declared'] or '（未声明）'}",
        "",
        "License source(s):",
    ]
    for s in p["license_files"]:
        lines.append(f"  - {s['path']}  sha256={s['sha256']}  bytes={s['bytes']}")
    if p["fallback_note"]:
        lines += ["", "核实说明:", p["fallback_note"]]
    lines += ["", "License text:", ""]
    for source, text in p["texts"]:
        if source is None:
            title = "upstream LICENSE (已核实)"
        else:
            try:
                title = str(source.relative_to(ROOT))
            except ValueError:
                title = str(source)
        lines += [f"----- {title} -----", text.rstrip(), ""]
    return "\n".join(lines)


def render_readme(index: dict) -> str:
    lines = [
        "# 第三方许可证包（LICENSES）",
        "",
        f"生成时间：`{index['generated_at']}`",
        f"包数量：**{index['package_count']}**（不含 pip；pip 不随 exe 分发）",
        "",
        "本目录由 `tools/generate_license_bundle.py` 从本机 `.venv` 生成。",
        "每份 `<包名>-<版本>.txt` 含：SPDX 标识、元数据声明、许可证来源与 SHA256、许可证全文。",
        "`index.json` 为机器可读索引，根目录 `SBOM.cdx.json` 为 CycloneDX 1.5 SBOM。",
        "",
        "## 重要口径",
        "",
        "- **源码仓库**只含项目原创代码与 Apache-2.0 许可证。",
        "- **Release 单文件 exe** 内含 CPython 与本目录所列 Python 包；分发 exe 时须同时附带 `LICENSE`、`THIRD_PARTY_NOTICES.md`、`LICENSES/` 与 `SBOM.cdx.json`。",
        "- KVRT、Node.js、卡巴斯基完整版安装器**不随包分发**，不进入本目录。",
        "",
        "## 本机环境与 lock 的漂移",
        "",
    ]
    if index["lock_drift"]:
        lines += ["| 包 | lock 目标 | 本机实际 |", "|---|---|---|"]
        for row in index["lock_drift"]:
            lines.append(f"| {row['name']} | {row['locked']} | {row['installed']} |")
        lines += ["", "这些差异说明当前 `.venv` 不是按 `requirements.lock.txt` 精确重建的；生成包按实际 exe 环境为准，重新打包前应先对齐。"]
    else:
        lines += ["无版本漂移。"]
    lines += [
        "",
        "## 已核实的上游元数据冲突",
        "",
        "- `proxy_tools 0.1.0`：PyPI 元数据写 MIT，上游仓库 `LICENSE.txt` 正文为 BSD-2-Clause；本包按正文收录并保留冲突说明。",
        "",
    ]
    return "\n".join(lines)


def build_sbom(index: dict) -> dict:
    comps = []
    for p in index["packages"]:
        lic = p["spdx"]
        if " " in lic or "WITH" in lic:
            license_entry = {"expression": lic}
        else:
            license_entry = {"license": {"id": lic}}
        comps.append({
            "type": "library",
            "bom-ref": f"pkg:pypi/{quote(p['normalized'])}@{p['version']}",
            "name": p["name"],
            "version": p["version"],
            "purl": f"pkg:pypi/{quote(p['normalized'])}@{p['version']}",
            "licenses": [license_entry],
            "properties": [
                {"name": "pf:license-source", "value": "; ".join(s["path"] for s in p["license_files"])},
                {"name": "pf:declared-metadata", "value": p["declared"] or ""},
            ],
        })
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, 'powerfocus:' + ','.join(p['name'] + '@' + p['version'] for p in index['packages']))}",
        "version": 1,
        "metadata": {
            "timestamp": index["generated_at"],
            "tools": {"components": [{"type": "application", "name": "PowerFocus license-bundle-generator", "version": "1.0"}]},
            "component": {
                "type": "application",
                "bom-ref": "pkg:generic/powerfocus@1.00",
                "name": "PowerFocus",
                "version": "1.00",
                "licenses": [{"license": {"id": "Apache-2.0"}}],
            },
        },
        "components": comps,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验现有许可证包是否完整，不写入")
    args = ap.parse_args()

    index, packages = build_index(check_only=args.check)
    if args.check:
        problems = []
        if not LICENSE_DIR.exists():
            problems.append("LICENSES 目录不存在")
        if not SBOM_PATH.exists():
            problems.append("SBOM.cdx.json 不存在")
        for p in index["packages"]:
            target = LICENSE_DIR / f"{p['normalized']}-{p['version']}.txt"
            if not target.exists():
                problems.append(f"缺少 {target.name}")
        if problems:
            print("LICENSE_CHECK=FAIL")
            for x in problems:
                print(" -", x)
            return 1
        print(f"LICENSE_CHECK=PASS packages={index['package_count']} drift={len(index['lock_drift'])}")
        return 0

    LICENSE_DIR.mkdir(parents=True, exist_ok=True)
    for p in packages:
        (LICENSE_DIR / f"{p['normalized']}-{p['version']}.txt").write_text(
            render_package(p), encoding="utf-8", newline="\n")
    (LICENSE_DIR / "README.md").write_text(render_readme(index), encoding="utf-8", newline="\n")
    INDEX_PATH.write_text(json.dumps(index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    SBOM_PATH.write_text(json.dumps(build_sbom(index), ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"LICENSES packages={index['package_count']} drift={len(index['lock_drift'])}")
    for row in index["lock_drift"]:
        print(f"DRIFT {row['name']}: lock={row['locked']} installed={row['installed']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())


