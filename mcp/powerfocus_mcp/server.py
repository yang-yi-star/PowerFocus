# -*- coding: utf-8 -*-
# ============================================================
# PowerFocus MCP Server 0.11.1 · 独立发行物（mcp/powerfocus_mcp/server.py）
#
# 目标：让任意 AI 客户端按 MCP 协议发现并加载 PowerFocus 的能力。
# 形态：stdio 传输 + JSON-RPC 2.0（逐行），零第三方依赖，只用标准库。
# 协议：默认 MCP 2026-07-28 无状态核心；兼容 2025-06-18 / 2025-03-26 /
#       2024-11-05 的 initialize 握手（官方给了 12 个月弃用窗口）。
# 后端：通过本机 127.0.0.1 的 FastAPI 服务调用，复用 X-PF-Token 认证
#       与动作白名单；本文件不直接写命令总线，不重复实现调度逻辑。
#
# 安全红线（对应 MCP 2026-07-28 规范 "Tool Safety / User Consent"）：
#   1. 默认只暴露只读工具；写工具需 POWERFOCUS_MCP_ALLOW_WRITE=1 才出现。
#   2. 写工具每次调用还需 _mcp_confirm=true，防止提示注入静默执行。
#   3. 安装类高危工具另需 POWERFOCUS_MCP_ALLOW_INSTALL=1。
#   4. 不转发 REA 逆向引擎（旧 mcp-server.py 的 229 项能力默认全部关闭）。
#   5. 所有调用写审计日志，只记参数键名，不记参数值与令牌。
#
# 启动：python mcp/powerfocus_mcp/server.py
# 配置：见 mcp/config.example.json 与 mcp/README.md
# ============================================================
from __future__ import annotations

import hashlib
import http.client
import json
import os
import secrets
import sys
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

try:  # 作为包导入（测试）与作为脚本直接运行（AI 客户端拉起）都要能工作
    from . import (APP_VERSION, DEFAULT_PROTOCOL, SERVER_NAME,
                   SUPPORTED_PROTOCOLS, __version__, version_info)
except ImportError:  # pragma: no cover - 脚本直跑时没有包上下文
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from powerfocus_mcp import (APP_VERSION, DEFAULT_PROTOCOL, SERVER_NAME,
                                SUPPORTED_PROTOCOLS, __version__, version_info)

# ---------------------------------------------------------------- 工具注册表

@dataclass(frozen=True)
class Tool:
    """一条能力 = 一个本机 HTTP 路由 + 风险等级 + 参数契约。"""
    name: str
    description: str
    http_method: str
    path: str
    risk: str = "read"                 # read | write | dangerous
    schema: dict = field(default_factory=lambda: {"type": "object", "properties": {}})
    query_keys: tuple[str, ...] = ()  # GET 时从 arguments 里取这些键拼 query


def _obj(properties: dict, required: tuple[str, ...] = ()) -> dict:
    d: dict[str, Any] = {"type": "object", "properties": properties}
    if required:
        d["required"] = list(required)
    return d


_CONFIRM_PROP = {
    "_mcp_confirm": {
        "type": "string",
        "description": "一次性确认 nonce：首次调用写工具会返回 input_required 与 nonce，带上它重试才会真正执行。",
    }
}

NONCE_TTL = 120.0

# 动作白名单与 product/v1.00/app/server.py:209-217 保持一致，供 AI 正确构造参数。
_ACTIONS = (
    "status", "focus", "unfocus", "set_priority", "set_power_plan",
    "trim_memory", "set_io_priority", "set_net_qos", "apply_scene",
    "list_scenes", "list_apps", "request_power", "release_power",
    "list_requests", "mem_guard", "router_status", "list_model_profiles",
    "model_identity", "start_router", "stop_router", "boost_model",
    "suspend_process", "resume_process", "authorize", "revoke",
    "kill_process", "stress_process",
)

TOOLS: tuple[Tool, ...] = (
    # ---------- 只读（默认全部开放） ----------
    Tool("pf_health", "读取本机服务健康状态（版本、内核在线、端口、是否 frozen）。无副作用。",
         "GET", "/api/health"),
    Tool("pf_snapshot", "读取 CPU/内存/模型/内核状态快照。无副作用。",
         "GET", "/api/snapshot"),
    Tool("pf_processes", "列出当前进程（按 CPU/内存排序，最多 120 条），可用 q 按名称或 PID 过滤。无副作用。",
         "GET", "/api/processes",
         schema=_obj({"q": {"type": "string", "description": "名称子串或精确 PID，可省略"}}),
         query_keys=("q",)),
    Tool("pf_models", "列出本地/云端可用模型与当前路由。无副作用。", "GET", "/api/models"),
    Tool("pf_scenes", "列出场景预设（游戏/工作/全力等）。无副作用。", "GET", "/api/scenes"),
    Tool("pf_router_status", "读取调度路由当前状态。无副作用。", "GET", "/api/router"),
    Tool("pf_security_status", "读取安全态势摘要（只读，不触发扫描）。", "GET", "/api/security"),
    Tool("pf_audit_log", "读取应用内审计记录。无副作用。", "GET", "/api/audit"),
    Tool("pf_bootstrap_check", "读取 7 项组件自检结果（只读，不下载不安装）。",
         "GET", "/api/bootstrap/check"),
    Tool("pf_parse_command", "把中文自然语言解析成调度指令但不执行，用于预览。无副作用。",
         "POST", "/api/parse",
         schema=_obj({"text": {"type": "string", "description": "中文指令原文"}}, ("text",))),

    # ---------- 写操作（默认不出现在 tools/list） ----------
    Tool("pf_run_command", "执行一条白名单内的调度动作（聚焦/优先级/内存回收/场景/授权等）。有副作用，必须确认。",
         "POST", "/api/command", risk="write",
         schema=_obj({
             "action": {"type": "string", "enum": list(_ACTIONS),
                        "description": "调度动作，必须在白名单内"},
             "process_name": {"type": "string", "description": "目标进程名（可不带 .exe）"},
             "_timeout": {"type": "number", "description": "超时秒数，1~600，缺省 30"},
             "confirm": {"type": "boolean", "description": "仅 kill_process / stress_process 需要，后端强制要求"},
             **_CONFIRM_PROP,
         }, ("action",))),
    Tool("pf_boost_model", "模型加速：dry_run 只出方案，apply 才真正调参。有副作用，必须确认。",
         "POST", "/api/boost", risk="write",
         schema=_obj({
             "mode": {"type": "string", "enum": ["dry_run", "apply"], "description": "缺省 dry_run"},
             "model": {"type": "string", "description": "可选模型名"},
             **_CONFIRM_PROP,
         })),
    Tool("pf_chat", "通过已配置的云端或本地模型发起一次对话。会消耗模型资源/额度，必须确认。",
         "POST", "/api/chat", risk="write",
         schema=_obj({
             "target": {"type": "string", "enum": ["cloud", "local"]},
             "messages": {"type": "array", "items": {"type": "object"},
                          "description": "OpenAI 兼容 messages 数组"},
             "stream": {"type": "boolean"},
             **_CONFIRM_PROP,
         }, ("messages",))),

    # ---------- 高危（双重开关） ----------
    Tool("pf_install_component", "触发组件下载/安装。会写入本机文件，需独立开关且逐次确认。",
         "POST", "/api/bootstrap/install", risk="dangerous",
         schema=_obj({
             "component": {"type": "string", "description": "组件 id"},
             "consent": {"type": "boolean", "description": "用户同意令牌，由前端流程产生"},
             **_CONFIRM_PROP,
         })),
)

TOOL_BY_NAME = {t.name: t for t in TOOLS}

# ---------------------------------------------------------------- 运行策略

def _flag(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in ("1", "true", "yes", "on")


@dataclass
class Policy:
    """运行策略：决定暴露哪些能力。可用环境变量或构造参数覆盖，便于测试。"""
    allow_write: bool = field(default_factory=lambda: _flag("POWERFOCUS_MCP_ALLOW_WRITE"))
    allow_install: bool = field(default_factory=lambda: _flag("POWERFOCUS_MCP_ALLOW_INSTALL"))
    root: str | None = field(default_factory=lambda: os.environ.get("POWERFOCUS_ROOT"))
    port: int | None = field(default_factory=lambda: (
        int(os.environ["POWERFOCUS_MCP_PORT"])
        if os.environ.get("POWERFOCUS_MCP_PORT", "").isdigit() else None))
    token: str | None = field(default_factory=lambda: os.environ.get("POWERFOCUS_MCP_TOKEN"))

    def permits(self, tool: Tool) -> bool:
        if tool.risk == "read":
            return True
        if tool.risk == "dangerous":
            return self.allow_write and self.allow_install
        return self.allow_write


def visible_tools(policy: Policy) -> list[Tool]:
    """确定性顺序：按工具名排序，保证列表结果可缓存（2026-07-28 要求）。"""
    return sorted((t for t in TOOLS if policy.permits(t)), key=lambda t: t.name)


def tool_descriptor(t: Tool) -> dict:
    return {"name": t.name, "description": t.description, "inputSchema": t.schema}


# ---------------------------------------------------------------- 本机连接

class Runtime:
    """持有端口/令牌发现与 HTTP 调用；不持有协议会话状态。"""

    PORT_RANGE = range(18080, 18120)
    CACHE_TTL = 30.0

    def __init__(self, policy: Policy):
        self.policy = policy
        self._port: int | None = None
        self._port_ts = 0.0
        self._token: str | None = None
        self._token_ts = 0.0
        # 应用层显式句柄（2026-07-28 允许）：nonce -> (工具名, 参数摘要, 过期时间)
        self._nonces: dict[str, tuple[str, str, float]] = {}
        self.call_api: Callable[..., dict] | None = None  # 测试注入点

    # -- 一次性确认：绑定工具与参数摘要，用后即失效 --
    @staticmethod
    def args_digest(tool_name: str, args: dict) -> str:
        raw = json.dumps({"tool": tool_name, "args": args},
                         sort_keys=True, ensure_ascii=False, default=str)
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]

    def _gc_nonces(self) -> None:
        now = time.time()
        for k in [k for k, v in self._nonces.items() if v[2] < now]:
            self._nonces.pop(k, None)

    def mint_nonce(self, tool_name: str, digest: str) -> str:
        self._gc_nonces()
        nonce = secrets.token_urlsafe(18)
        self._nonces[nonce] = (tool_name, digest, time.time() + NONCE_TTL)
        return nonce

    def consume_nonce(self, nonce: str, tool_name: str, digest: str) -> tuple[bool, str]:
        self._gc_nonces()
        ent = self._nonces.pop(nonce, None)
        if ent is None:
            return False, "确认 nonce 无效或已被使用"
        t, d, exp = ent
        if exp < time.time():
            return False, "确认 nonce 已过期"
        if t != tool_name or d != digest:
            return False, "确认 nonce 与本次操作不匹配"
        return True, ""

    # -- 端口：/api/health 豁免认证，用它确认「这就是 PowerFocus」 --
    def port(self) -> int:
        if self.policy.port:
            return self.policy.port
        now = time.time()
        if self._port and now - self._port_ts < self.CACHE_TTL:
            return self._port
        for p in self.PORT_RANGE:
            try:
                c = http.client.HTTPConnection("127.0.0.1", p, timeout=0.2)
                c.request("GET", "/api/health")
                r = c.getresponse()
                body = r.read().decode("utf-8", "replace")
                c.close()
                if r.status == 200 and json.loads(body).get("app") == "ok":
                    self._port, self._port_ts = p, now
                    return p
            except Exception:
                continue
        raise RuntimeError("未发现运行中的 PowerFocus 服务（18080~18119 均无 /api/health）。请先启动桌面应用。")

    # -- 令牌：优先环境变量，其次按与后端一致的规则找 stable 内核目录 --
    def token(self) -> str:
        if self.policy.token:
            return self.policy.token
        now = time.time()
        if self._token and now - self._token_ts < self.CACHE_TTL:
            return self._token
        for cand in self._token_candidates():
            try:
                tok = cand.read_text(encoding="utf-8-sig").strip()
                if tok:
                    self._token, self._token_ts = tok, now
                    return tok
            except OSError:
                continue
        raise RuntimeError("未找到本机令牌。请设置 POWERFOCUS_MCP_TOKEN，或设置 POWERFOCUS_ROOT 指向应用目录。")

    def _token_candidates(self) -> list[Path]:
        roots: list[Path] = []
        if self.policy.root:
            roots.append(Path(self.policy.root))
        else:
            here = Path(__file__).resolve()
            for parent in here.parents:
                if (parent / "versions").is_dir():
                    roots.append(parent)
                    break
            la = os.environ.get("LOCALAPPDATA")
            if la:
                roots.append(Path(la) / "PowerFocus")
        cands: list[Path] = []
        # 0.11.0 起 HTTP 令牌与内核授权令牌解耦：优先只用 HTTP 令牌，
        # 绝不把内核授权令牌交给 AI 客户端；旧版本应用才回退到 .auth_token。
        la = os.environ.get("LOCALAPPDATA")
        if la:
            cands.append(Path(la) / "PowerFocus" / "http.token")
        for root in roots:
            vers = root / "versions"
            if vers.is_dir():
                stable, others = [], []
                for d in sorted(vers.glob("v*"), key=lambda x: x.name, reverse=True):
                    if not d.is_dir():
                        continue
                    try:
                        mf = json.loads((d / "MANIFEST.json").read_text(encoding="utf-8-sig"))
                        stage = mf.get("stage")
                    except Exception:
                        stage = "dev"
                    (stable if stage == "stable" else others).append(d)
                cands.extend(d / ".auth_token" for d in stable + others)
            cands.append(root / ".auth_token")
        return cands

    # -- 统一 HTTP 调用 --
    def api(self, method: str, path: str, payload: dict | None = None,
            query: dict | None = None, timeout: float = 15.0) -> dict:
        if self.call_api is not None:
            return self.call_api(method, path, payload, query, timeout)
        if query:
            from urllib.parse import urlencode
            path = path + "?" + urlencode({k: v for k, v in query.items() if v not in (None, "")})
        headers = {"X-PF-Token": self.token()}
        body = None
        if payload is not None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"
        c = http.client.HTTPConnection("127.0.0.1", self.port(), timeout=timeout)
        try:
            c.request(method, path, body=body, headers=headers)
            r = c.getresponse()
            raw = r.read().decode("utf-8", "replace")
            status = r.status
        finally:
            c.close()
        try:
            data = json.loads(raw) if raw.strip() else {}
        except ValueError:
            data = {"raw": raw[:2000]}
        if status >= 400:
            # 不把后端原始错误全文回给 AI，避免泄露本机路径
            msg = data.get("detail") if isinstance(data, dict) else None
            return {"__http_error__": True, "status": status,
                    "message": str(msg) if msg else "后端请求失败"}
        return data


# ---------------------------------------------------------------- 审计

def _audit_path() -> Path:
    base = Path(os.environ.get("LOCALAPPDATA") or os.environ.get("TEMP") or ".") / "PowerFocus" / "mcp"
    return base / "audit.jsonl"


def _audit(tool: str, risk: str, args: dict, ok: bool, latency_ms: int, note: str = "") -> None:
    """只记录参数键名，绝不记录参数值、令牌或用户输入内容。"""
    try:
        p = _audit_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        rec = {
            "ts": time.strftime("%Y-%m-%d %H:%M:%S"),
            "tool": tool, "risk": risk, "ok": ok,
            "arg_keys": sorted(str(k) for k in (args or {}).keys()),
            "latency_ms": latency_ms, "note": note,
        }
        with p.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception:
        pass  # 审计失败不阻断工具调用


# ---------------------------------------------------------------- 参数校验

def _validate(t: Tool, args: dict) -> str | None:
    if not isinstance(args, dict):
        return "arguments 必须是对象"
    for key in t.schema.get("required", []):
        if key not in args or args[key] in (None, ""):
            return "缺少必填参数: %s" % key
    for key, spec in t.schema.get("properties", {}).items():
        if key not in args:
            continue
        want, got = spec.get("type"), args[key]
        ok = {
            "string": lambda v: isinstance(v, str),
            "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
            "boolean": lambda v: isinstance(v, bool),
            "array": lambda v: isinstance(v, list),
            "object": lambda v: isinstance(v, dict),
        }.get(want, lambda v: True)(got)
        if not ok:
            return "参数 %s 类型应为 %s" % (key, want)
        if "enum" in spec and got not in spec["enum"]:
            return "参数 %s 不在允许范围: %s" % (key, ", ".join(map(str, spec["enum"])))
    return None


# ---------------------------------------------------------------- JSON-RPC

def _ok(msg_id: Any, result: dict) -> dict:
    return {"jsonrpc": "2.0", "id": msg_id, "result": result}


def _err(msg_id: Any, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}}


def _tool_text(data: Any) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2, default=str)


def _tool_result(msg_id: Any, data: Any, is_error: bool = False) -> dict:
    return _ok(msg_id, {"content": [{"type": "text", "text": _tool_text(data)}],
                        "isError": bool(is_error)})


def _extract_confirm(args: dict, params: dict) -> str | None:
    """兼容两种重试方式：简单客户端用 arguments._mcp_confirm，
    2026-07-28 客户端用 MRTR 的 inputResponses。"""
    v = args.get("_mcp_confirm")
    if isinstance(v, str) and v:
        return v
    ir = (params or {}).get("inputResponses")
    if isinstance(ir, dict):
        for k in ("confirm", "_mcp_confirm", "nonce"):
            val = ir.get(k)
            if isinstance(val, str) and val:
                return val
    if isinstance(ir, list):
        for item in ir:
            if isinstance(item, dict):
                val = item.get("value") or item.get("response")
                if isinstance(val, str) and val:
                    return val
    return None


def execute_tool(msg_id: Any, t: Tool, args: dict, policy: Policy, rt: Runtime,
                 params: dict | None = None) -> dict:
    """执行一条工具。写操作在这里做一次性确认，不依赖任何协议会话状态。"""
    started = time.time()
    bad = _validate(t, args)
    if bad:
        return _err(msg_id, -32602, bad)

    # 「声明即白名单」：只转发 inputSchema 显式声明的键，
    # 杜绝 token / idempotency_id / _raw 等字段从 AI 侧注入后端命令。
    allowed = set(t.schema.get("properties", {}).keys())
    clean = {k: v for k, v in args.items() if k in allowed and k != "_mcp_confirm"}

    if t.risk != "read":
        if not policy.permits(t):
            _audit(t.name, t.risk, args, False, 0, "policy_denied")
            return _tool_result(msg_id, {
                "ok": False,
                "error": "该能力未启用。只读是默认策略；如需开放写操作，请在 MCP 客户端配置里设置 "
                         "POWERFOCUS_MCP_ALLOW_WRITE=1（安装类另需 POWERFOCUS_MCP_ALLOW_INSTALL=1）。",
            }, True)

        digest = rt.args_digest(t.name, clean)
        confirm = _extract_confirm(args, params or {})
        if not confirm:
            nonce = rt.mint_nonce(t.name, digest)
            _audit(t.name, t.risk, args, False, 0, "nonce_issued")
            text = (
                "执行 %s 会修改本机状态，需要一次性确认。\n"
                "请在 %d 秒内用相同的 arguments 重试，并附加 "
                "arguments._mcp_confirm = \"%s\"（或按 2026-07-28 规范放进 inputResponses）。\n"
                "该 nonce 绑定本工具与本次参数，用后即失效。"
                % (t.name, int(NONCE_TTL), nonce)
            )
            return _ok(msg_id, {
                "resultType": "input_required",
                "requests": [{"id": "confirm", "type": "boolean",
                              "prompt": "确认执行 %s？" % t.name}],
                "confirm": {"nonce": nonce, "expiresInSec": int(NONCE_TTL),
                            "field": "_mcp_confirm"},
                "content": [{"type": "text", "text": text}],
                "isError": False,
            })
        ok, why = rt.consume_nonce(confirm, t.name, digest)
        if not ok:
            _audit(t.name, t.risk, args, False, 0, "nonce_rejected")
            return _tool_result(msg_id, {"ok": False, "error": why}, True)

    query = {k: clean.pop(k) for k in t.query_keys if k in clean}
    payload = clean if t.http_method == "POST" else None

    try:
        data = rt.api(t.http_method, t.path, payload=payload, query=query or None)
        is_error = bool(data.get("__http_error__")) or (isinstance(data, dict) and data.get("ok") is False)
        _audit(t.name, t.risk, args, not is_error, int((time.time() - started) * 1000),
               "http_error" if is_error else "")
        return _tool_result(msg_id, data, is_error)
    except Exception as e:
        _audit(t.name, t.risk, args, False, int((time.time() - started) * 1000), type(e).__name__)
        return _tool_result(msg_id, {"ok": False, "error": str(e)}, True)


def capabilities(policy: Policy) -> dict:
    return {
        "tools": {"listChanged": False, "available": len(visible_tools(policy))},
        "resources": {"subscribe": False, "listChanged": False},
        "prompts": {"listChanged": False},
    }


def server_instructions(policy: Policy) -> str:
    info = version_info()
    mode = "只读（默认）" if not policy.allow_write else "已开放写操作（需 _mcp_confirm）"
    if policy.allow_install:
        mode += " + 安装类"
    return (
        "PowerFocus 是本机 Windows 算力与进程调度控制台。当前策略：%s。"
        "所有工具只作用于本机已授权的进程，不访问外部系统。"
        "调用前请确认应用已启动（本机 127.0.0.1 服务在线）。"
        "写操作默认不暴露，且每次都需要一次性确认 nonce；REA 逆向引擎能力在本发行物中不提供。"
        "MCP 版本 %s，对标应用版本 %s，协议 %s。"
        % (mode, info.get("mcp_version", __version__),
           info.get("target_app_version", APP_VERSION), DEFAULT_PROTOCOL)
    )


def _params_of(msg: dict) -> dict:
    """畸形消息防护：params 可能是 list / None / 字符串，一律退化为空对象。
    旧 mcp-server.py 在 method 或 params 畸形时会崩掉整个 stdio 进程（B28/F11）。"""
    p = msg.get("params")
    return p if isinstance(p, dict) else {}


def initialize_result(msg: dict, msg_id: Any, policy: Policy) -> dict:
    """兼容 2024-11-05 ~ 2025-06-18 客户端的握手；新规范已退役但仍在弃用窗口内。"""
    req_pv = str(_params_of(msg).get("protocolVersion") or DEFAULT_PROTOCOL)
    pv = req_pv if req_pv in SUPPORTED_PROTOCOLS else DEFAULT_PROTOCOL
    return _ok(msg_id, {
        "protocolVersion": pv,
        "capabilities": capabilities(policy),
        "serverInfo": {"name": SERVER_NAME, "version": __version__},
        "instructions": server_instructions(policy),
    })


def discover_result(msg_id: Any, policy: Policy) -> dict:
    """MCP 2026-07-28 的可选能力发现 RPC（无状态，不建立会话）。"""
    info = version_info()
    return _ok(msg_id, {
        "protocolVersion": DEFAULT_PROTOCOL,
        "protocolVersions": list(SUPPORTED_PROTOCOLS),
        "serverInfo": {"name": SERVER_NAME, "version": __version__,
                       "appVersion": info.get("target_app_version", APP_VERSION)},
        "capabilities": capabilities(policy),
        "instructions": server_instructions(policy),
        "policy": {"allowWrite": policy.allow_write, "allowInstall": policy.allow_install,
                   "defaultReadOnly": True, "reaProxyExposed": False},
        "transport": "stdio",
        "stateless": True,
        # 如实声明：确认流使用 input_required / inputResponses，
        # 但未实现 server-initiated elicitation / sampling 等完整 MRTR 能力
        "mrtr": "confirm-only",
    })


def tools_list_result(msg_id: Any, policy: Policy) -> dict:
    tools = [tool_descriptor(t) for t in visible_tools(policy)]
    return _ok(msg_id, {
        "tools": tools,
        # 2026-07-28 SEP-2549：列表结果给缓存提示，顺序已按 name 排序保证确定性
        "ttlMs": 60000,
        "cacheScope": "server",
    })


def handle(msg: Any, policy: Policy | None = None, rt: Runtime | None = None) -> dict | None:
    """纯分发函数：不读取 stdin、不写 stdout，便于单元测试。

    无状态核心：不要求先 initialize，任何请求都可独立到达。
    """
    policy = policy or Policy()
    rt = rt or Runtime(policy)
    if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0":
        return None
    msg_id = msg.get("id")
    if msg_id is None:  # 通知（含 notifications/initialized）不响应
        return None
    method = str(msg.get("method") or "")

    if method == "initialize":
        return initialize_result(msg, msg_id, policy)
    if method == "server/discover":
        return discover_result(msg_id, policy)
    if method == "ping":
        return _ok(msg_id, {})
    if method == "tools/list":
        return tools_list_result(msg_id, policy)
    if method == "tools/call":
        params = _params_of(msg)
        name = params.get("name")
        args = params.get("arguments") or {}
        t = TOOL_BY_NAME.get(str(name))
        if t is None:
            return _err(msg_id, -32602, "Unknown tool: %s" % name)
        if not policy.permits(t):
            # 未启用的能力等同于不存在，不泄露工具存在性
            return _err(msg_id, -32602, "Unknown tool: %s" % name)
        return execute_tool(msg_id, t, args, policy, rt, params)
    if method.startswith("notifications/"):
        return None
    return _err(msg_id, -32601, "Method not found: %s" % method)


# ---------------------------------------------------------------- stdio 入口

def emit(obj: dict) -> None:
    # default=str：任何意外类型也只退化成文本，绝不因序列化异常污染 stdout 协议流
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, default=str) + "\n")
    sys.stdout.flush()


def main() -> None:
    for stream in (sys.stdin, sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass
    policy = Policy()
    rt = Runtime(policy)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            emit(_err(None, -32700, "Parse error"))
            continue
        try:
            resp = handle(msg, policy, rt)
        except Exception:
            # 协议输出保持干净，异常细节只进 stderr
            sys.stderr.write(traceback.format_exc())
            resp = _err(msg.get("id") if isinstance(msg, dict) else None,
                        -32603, "Internal error")
        if resp is not None:
            emit(resp)


if __name__ == "__main__":
    main()
