# -*- coding: utf-8 -*-
"""pytest 全局环境隔离（31 号：测试不得写生产 security.log）。

背景
----
`tests/py` 下的用例直接用 `TestClient(server.app)` 构造真实 FastAPI 应用；
`app/security.py` 的 `audit()` 默认按生产口径落盘：

    PF_SECURITY_LOG（若设置，按「文件路径」语义使用）
      → app_paths.log_dir()/security.log
      → %LOCALAPPDATA%/PowerFocus/logs/security.log

未隔离时，每跑一轮 `tests/run-tests.ps1`（内含 pytest）就往真实审计日志灌十几条
假事件（`client=testclient`、伪造 `http_token_bootstrapped` 指向 pytest tmp_path、
4 条假 `security_scan_start`），真安全事件与测试数据混档，事后取证要人工剔除。

做法
----
在 pytest 收集、导入任何 app 模块之前（conftest 是收集阶段最先导入的文件），把
`PF_SECURITY_LOG` 指向系统临时目录下的专用文件。`setdefault` 语义：外部已显式
指定时尊重外部值（例如 CI 想单独收一份）。

边界
----
只改本测试进程的环境变量：不动 `LOCALAPPDATA`、不动 `http.token`、不动生产日志
目录，也不改任何产品代码。回滚 = 删除本文件。
"""

import os
import tempfile

_TEST_SECURITY_LOG = os.path.join(tempfile.gettempdir(), "pf-test-security.log")

os.environ.setdefault("PF_SECURITY_LOG", _TEST_SECURITY_LOG)
