# -*- coding: utf-8 -*-
"""第三方许可证包与 SBOM 的回归测试。

这些测试不联网、不启动应用，只校验仓库内可交付的许可证附件：
  - 38 个运行时包（不含 pip）都有全文
  - 已核实的关键许可证不被改回错值
  - SBOM 与 index 的包集合一致
  - 打包脚本会把附件复制进 dist
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LICENSES = ROOT / "LICENSES"
INDEX = LICENSES / "index.json"
SBOM = ROOT / "SBOM.cdx.json"
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
BUILD = ROOT / "product" / "v1.00" / "build" / "build.ps1"


def load_index():
    return json.loads(INDEX.read_text(encoding="utf-8"))


def test_generator_check_passes():
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "generate_license_bundle.py"), "--check"],
                       cwd=str(ROOT), capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "LICENSE_CHECK=PASS" in r.stdout
    assert "packages=38" in r.stdout


def test_index_has_all_runtime_packages():
    idx = load_index()
    assert idx["package_count"] == 38
    names = {p["name"] for p in idx["packages"]}
    assert {"pywebview", "clr_loader", "proxy_tools", "fastapi", "psutil"} <= names
    for p in idx["packages"]:
        target = LICENSES / f"{p['normalized']}-{p['version']}.txt"
        assert target.is_file(), target
        assert target.stat().st_size > 500, target
        text = target.read_text(encoding="utf-8")
        assert f"Package: {p['name']}" in text
        assert f"SPDX-License-Identifier: {p['spdx']}" in text
        assert "License text:" in text


def test_verified_license_corrections_stick():
    idx = load_index()
    by_name = {p["name"]: p for p in idx["packages"]}
    assert by_name["clr_loader"]["spdx"] == "MIT"
    assert by_name["pywebview"]["spdx"] == "BSD-3-Clause"
    # PyPI 元数据写 MIT，但上游 LICENSE.txt 正文是 BSD-2-Clause；以正文为准。
    assert by_name["proxy_tools"]["spdx"] == "BSD-2-Clause"
    assert by_name["proxy_tools"]["declared"].startswith("MIT")
    assert "上游" in by_name["proxy_tools"]["fallback_note"]


def test_sbom_matches_index():
    idx = load_index()
    sbom = json.loads(SBOM.read_text(encoding="utf-8"))
    assert sbom["bomFormat"] == "CycloneDX"
    assert sbom["specVersion"] == "1.5"
    assert sbom["metadata"]["component"]["name"] == "PowerFocus"
    assert len(sbom["components"]) == idx["package_count"] == 38
    purls = {c["purl"] for c in sbom["components"]}
    assert "pkg:pypi/pywebview@6.2.1" in purls
    assert "pkg:pypi/clr-loader@0.3.1" in purls
    assert "pkg:pypi/proxy-tools@0.1.0" in purls


def test_notices_and_build_are_consistent():
    notices = NOTICES.read_text(encoding="utf-8")
    assert "| clr_loader | 0.3.1 | MIT |" in notices
    assert "| pywebview | 6.2.1 | BSD-3-Clause |" in notices
    assert "| proxy_tools | 0.1.0 | BSD-2-Clause" in notices
    assert "38 项" in notices
    assert "元数据未声明" not in notices

    build = BUILD.read_text(encoding="utf-8")
    assert "generate_license_bundle.py" in build
    assert "LICENSES" in build
    assert "SBOM.cdx.json" in build
    assert "THIRD_PARTY_NOTICES.md" in build
