# -*- coding: utf-8 -*-
"""KVRT EULA 边界的离线回归。

不启动扫描、不碰真实 KVRT：
  - ScanRequest 默认拒绝
  - 未显式同意时 build_scan_args 不得出现 -accepteula
  - run_scan 在未同意时于任何副作用之前拒绝
  - CLI --scan 未带 --accept-eula 时返回 2
  - status() 如实暴露 EULA 与 devbuild 下载通道
"""
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "versions" / "v0.13"))

import kvrt_bundle as k  # noqa: E402


def test_default_is_refusal():
    req = k.ScanRequest()
    assert req.accept_eula is False
    assert "-accepteula" not in k.build_scan_args(req)


def test_explicit_true_adds_flag():
    req = k.ScanRequest(accept_eula=True)
    assert "-accepteula" in k.build_scan_args(req)


def test_run_scan_refuses_before_side_effects():
    with pytest.raises(RuntimeError, match="EULA"):
        k.run_scan(k.ScanRequest(scope="core"))


def test_cli_scan_requires_flag(capsys):
    code = k.main(["--scan"])
    assert code == 2
    err = capsys.readouterr().err
    assert "accept-eula" in err
    assert k.EULA_URL in err


def test_status_reports_eula_and_channel():
    st = k.status()
    assert st["eula_url"] == "https://support.kaspersky.com/8530"
    assert "devbuild" in st["download_channel"]
    assert "非消费级" in st["download_channel"]
