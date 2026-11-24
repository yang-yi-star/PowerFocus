# -*- coding: utf-8 -*-
"""08 号回归：发布 MANIFEST 的内核三元组必须与 current.json / 磁盘一致。

为什么要有这份测试：
    `product\\v1.00\\MANIFEST.json` 是人工维护的发布元数据。2026-11-19 实测发现
    `kernel_version=v0.13`、`kernel_required>=v0.13`，但 `kernel_dir` 仍指向
    `versions\\v0.09`，同一份清单自相矛盾。它会误导排障和回滚定位到旧内核。

判据：
    1. `kernel_version` 必须等于 `versions\\current.json` 的 `version`；
    2. `kernel_dir` 的目录名必须等于该版本（防止再写回旧目录）；
    3. `kernel_required` 必须包含该版本；
    4. `kernel_dir` 必须真实存在且带内核 MANIFEST。

边界：
    只读元数据，不启动/不重启任何进程；不改 build/install/health 的架构。
    全量版本号收敛（PF-004）是另一个问题，不在本测试的断言范围内。
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRODUCT_MANIFEST = ROOT / "product" / "v1.00" / "MANIFEST.json"
CURRENT_JSON = ROOT / "versions" / "current.json"


def _load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def test_manifest_kernel_triplet_is_consistent() -> None:
    manifest = _load_json(PRODUCT_MANIFEST)
    current = _load_json(CURRENT_JSON)
    version = current["version"]

    assert manifest["kernel_version"] == version, (
        f"MANIFEST kernel_version={manifest['kernel_version']!r} "
        f"与 current.json version={version!r} 不一致"
    )

    kernel_dir = Path(manifest["kernel_dir"])
    assert kernel_dir.name == version, (
        f"MANIFEST kernel_dir={kernel_dir} 指向 {kernel_dir.name!r}，"
        f"与 version={version!r} 不一致"
    )
    assert version in manifest["kernel_required"], (
        f"MANIFEST kernel_required={manifest['kernel_required']!r} "
        f"未包含 {version!r}"
    )
    assert kernel_dir.is_dir(), f"MANIFEST kernel_dir 不存在：{kernel_dir}"
    assert (kernel_dir / "MANIFEST.json").is_file(), (
        f"MANIFEST kernel_dir 缺少内核 MANIFEST.json：{kernel_dir}"
    )
