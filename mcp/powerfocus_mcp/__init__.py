# -*- coding: utf-8 -*-
"""PowerFocus MCP Server 发行物版本信息。

版本号与所对齐的主应用 Release tag 一致，规则见 docs/VERSION_POLICY.md。
"""
import json
from pathlib import Path

__version__ = "0.11.1"
APP_VERSION = "0.11.1"
SERVER_NAME = "powerfocus-mcp"

# 协议版本是兼容声明，不是产品版本号。
DEFAULT_PROTOCOL = "2026-07-28"
SUPPORTED_PROTOCOLS = ("2026-07-28", "2025-06-18", "2025-03-26", "2024-11-05")


def version_info() -> dict:
    """读取随发行物一同分发的 VERSION.json，供 server/discover 使用。"""
    p = Path(__file__).resolve().parent.parent / "VERSION.json"
    try:
        return json.loads(p.read_text(encoding="utf-8-sig"))
    except Exception:
        return {
            "mcp_version": __version__,
            "target_app_version": APP_VERSION,
            "protocol_versions": list(SUPPORTED_PROTOCOLS),
            "default_protocol_version": DEFAULT_PROTOCOL,
            "transport": "stdio",
            "stateless_core": True,
        }
