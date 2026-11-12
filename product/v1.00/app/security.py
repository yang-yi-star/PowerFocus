# -*- coding: utf-8 -*-
# ============================================================
# 本地服务安全层（PowerFocus Console · security.py）
#
# 设计依据（均为公开资料，不是臆测）：
#   1. DNS 重绑定是本地 HTTP 服务的头号外部攻击面：攻击者用公网域名把
#      浏览器解析到自己机器 127.0.0.1，从而同源读取接口。唯一有效防线是
#      校验 Host 头（OWASP / CVE-2026-42559 同类缺陷的官方修复方式）。
#   2. OWASP FastAPI Security Cheat Sheet：生产必须关闭 /docs 与 /openapi.json；
#      鉴权用恒定时间比较；写接口限流（OWASP API2:2023 认证失效）。
#   3. 本地服务审计：认证失败、Host 伪造、跨源请求、体积超限全部落盘，
#      便于事后取证。
#
# 边界说明（诚实）：Windows 单用户模型下，同一用户身份运行的进程天然可以
# 读取本机文件。本层能挡住的是「外部程序 / 外部网站 / 局域网 / 浏览器跨源」，
# 挡不住「同用户恶意进程」。后者只能靠系统级隔离（不同账户/PPL），不在本层。
# ============================================================
import ctypes
import hashlib
import hmac
import json
import os
import threading
import time
from collections import defaultdict, deque
from pathlib import Path

# ---------------- 主机白名单（DNS 重绑定防线） ----------------
BASE_HOSTS = {"127.0.0.1", "localhost", "::1"}


def trusted_hostnames() -> set:
    """基础回环名 + 环境变量 PF_TRUSTED_HOSTS（逗号分隔，仅测试/自定义部署用）。"""
    extra = os.environ.get("PF_TRUSTED_HOSTS", "")
    names = set(BASE_HOSTS)
    for item in extra.split(","):
        item = item.strip().lower()
        if item:
            names.add(item)
    return names


def _hostname_of(value: str) -> str:
    """从 Host / Origin 头里取出主机名，忽略端口与协议。"""
    v = (value or "").strip().lower()
    if not v:
        return ""
    if "://" in v:
        v = v.split("://", 1)[1]
    v = v.split("/", 1)[0]
    if v.startswith("["):  # IPv6 字面量 [::1]:18080
        return v[1:].split("]", 1)[0]
    if ":" in v:
        return v.rsplit(":", 1)[0]
    return v


def host_ok(value: str) -> bool:
    """Host 头必须落在白名单；空值、多值、伪造域名一律拒绝。"""
    if not value or "," in value:
        return False
    return _hostname_of(value) in trusted_hostnames()


def origin_ok(value: str) -> bool:
    """浏览器跨源来源校验：只允许本机回环来源，'null' 一律拒绝。"""
    if not value:
        return True  # 非浏览器客户端（MCP / curl）不带 Origin
    if value.strip().lower() == "null":
        return False
    return _hostname_of(value) in trusted_hostnames()


# ---------------- 恒定时间鉴权 ----------------
def token_matches(given: str, expected: str) -> bool:
    """防止按字节比较带来的时序侧信道。"""
    if not expected or not given:
        return False
    return hmac.compare_digest(given.encode("utf-8", "ignore"),
                               expected.encode("utf-8", "ignore"))


def token_fingerprint(token: str) -> str:
    """对外只暴露指纹，不暴露令牌本体。"""
    if not token:
        return ""
    return "sha256:" + hashlib.sha256(token.encode("utf-8")).hexdigest()[:12]


# ---------------- 限流 ----------------
class RateLimiter:
    """滑动窗口限流：按客户端地址分桶，超限直接 429。"""

    def __init__(self, limit: int = 240, window: float = 60.0):
        self.limit = int(limit)
        self.window = float(window)
        self._hits = defaultdict(deque)
        self._lock = threading.Lock()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            q = self._hits[key]
            while q and now - q[0] > self.window:
                q.popleft()
            if len(q) >= self.limit:
                return False
            q.append(now)
            return True

    def reset(self, key: str) -> None:
        with self._lock:
            self._hits.pop(key, None)


class FailureGuard:
    """认证失败熔断：短时间内连续失败到阈值后，直接拒绝该来源。"""

    def __init__(self, threshold: int = 20, window: float = 300.0, block: float = 120.0):
        self.threshold = int(threshold)
        self.window = float(window)
        self.block_sec = float(block)
        self._fails = defaultdict(deque)
        self._blocked = {}
        self._lock = threading.Lock()

    def blocked(self, key: str) -> bool:
        now = time.monotonic()
        with self._lock:
            until = self._blocked.get(key)
            if until and until > now:
                return True
            if until:
                self._blocked.pop(key, None)
            return False

    def bump(self, key: str) -> None:
        now = time.monotonic()
        with self._lock:
            q = self._fails[key]
            q.append(now)
            while q and now - q[0] > self.window:
                q.popleft()
            if len(q) >= self.threshold:
                self._blocked[key] = now + self.block_sec
                q.clear()

    def reset(self, key: str) -> None:
        with self._lock:
            self._fails.pop(key, None)


# ---------------- 审计日志 ----------------
_LOG_LOCK = threading.Lock()


def audit_path() -> Path:
    env = os.environ.get("PF_SECURITY_LOG")
    if env:
        return Path(env)
    base = Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "PowerFocus" / "logs"
    return base / "security.log"


def audit(event: str, **fields) -> None:
    """追加一行 JSONL，超过 2MB 轮转；写入失败不影响主流程。"""
    try:
        p = audit_path()
        p.parent.mkdir(parents=True, exist_ok=True)
        line = {"ts": time.strftime("%Y-%m-%d %H:%M:%S"), "event": event}
        line.update({k: v for k, v in fields.items() if v is not None})
        text = json.dumps(line, ensure_ascii=False)
        with _LOG_LOCK:
            try:
                if p.exists() and p.stat().st_size > 2 * 1024 * 1024:
                    p.replace(p.with_suffix(".log.1"))
            except Exception:
                pass
            with p.open("a", encoding="utf-8") as f:
                f.write(text + "\n")
    except Exception:
        pass


def audit_tail(limit: int = 50) -> list:
    """读取最近 N 条审计事件（新→旧）。"""
    try:
        lines = audit_path().read_text(encoding="utf-8").splitlines()
    except Exception:
        return []
    out = []
    for raw in reversed(lines[-max(1, min(limit, 500)):]):
        try:
            out.append(json.loads(raw))
        except Exception:
            continue
    return out


# ---------------- Windows DPAPI 凭据库 ----------------
class _BLOB(ctypes.Structure):
    _fields_ = [("cbData", ctypes.c_ulong), ("pbData", ctypes.POINTER(ctypes.c_char))]


def _blob(data: bytes):
    buf = ctypes.create_string_buffer(data, len(data))
    return _BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))), buf


def _crypt32():
    lib = ctypes.windll.crypt32
    lib.CryptProtectData.argtypes = [
        ctypes.POINTER(_BLOB), ctypes.c_wchar_p, ctypes.POINTER(_BLOB),
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(_BLOB)]
    lib.CryptProtectData.restype = ctypes.c_int
    lib.CryptUnprotectData.argtypes = [
        ctypes.POINTER(_BLOB), ctypes.POINTER(ctypes.c_wchar_p), ctypes.POINTER(_BLOB),
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(_BLOB)]
    lib.CryptUnprotectData.restype = ctypes.c_int
    return lib


def _local_free(ptr) -> None:
    k32 = ctypes.windll.kernel32
    k32.LocalFree.argtypes = [ctypes.c_void_p]
    k32.LocalFree.restype = ctypes.c_void_p
    try:
        k32.LocalFree(ptr)
    except Exception:
        pass


ENTROPY = b"PowerFocus.v1"


def dpapi_protect(data: bytes) -> bytes:
    """用当前用户 DPAPI 密钥加密；密文只能被同一用户在同一台机器解开。"""
    inb, _in_keep = _blob(data)
    ent, _ent_keep = _blob(ENTROPY)
    outb = _BLOB()
    if not _crypt32().CryptProtectData(ctypes.byref(inb), "PowerFocus", ctypes.byref(ent),
                                       None, None, 0x1, ctypes.byref(outb)):
        raise OSError("DPAPI 加密失败")
    try:
        return ctypes.string_at(outb.pbData, outb.cbData)
    finally:
        _local_free(outb.pbData)


def dpapi_unprotect(blob: bytes) -> bytes:
    inb, _in_keep = _blob(blob)
    ent, _ent_keep = _blob(ENTROPY)
    outb = _BLOB()
    if not _crypt32().CryptUnprotectData(ctypes.byref(inb), None, ctypes.byref(ent),
                                         None, None, 0x1, ctypes.byref(outb)):
        raise OSError("DPAPI 解密失败（可能换了用户或换了机器）")
    try:
        return ctypes.string_at(outb.pbData, outb.cbData)
    finally:
        _local_free(outb.pbData)


def vault_path() -> Path:
    env = os.environ.get("PF_VAULT_PATH")
    if env:
        return Path(env)
    base = Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "PowerFocus" / "secrets"
    return base / "cloud.vault"


def vault_get() -> dict:
    """读取加密的云端凭据；不存在或解不开都返回空字典，绝不回落到明文文件。"""
    p = vault_path()
    if not p.exists():
        return {}
    try:
        raw = dpapi_unprotect(p.read_bytes())
        data = json.loads(raw.decode("utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def vault_set(data: dict) -> Path:
    p = vault_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(dpapi_protect(json.dumps(data, ensure_ascii=False).encode("utf-8")))
    try:  # 目录已有用户级 ACL；文件再显式收回继承，避免被复制到共享目录
        import subprocess
        user = os.environ.get("USERNAME") or ""
        if user:
            subprocess.run(["icacls", str(p), "/inheritance:r", "/grant:r", "%s:(R,W)" % user],
                           capture_output=True, timeout=10)
    except Exception:
        pass
    return p


def vault_clear() -> None:
    try:
        vault_path().unlink(missing_ok=True)
    except Exception:
        pass


# ---------------- ASGI 中间件 ----------------
def _json_bytes(obj) -> tuple:
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    return body, [(b"content-type", b"application/json; charset=utf-8"),
                  (b"content-length", str(len(body)).encode())]


SECURITY_HEADERS = [
    (b"x-content-type-options", b"nosniff"),
    (b"x-frame-options", b"DENY"),
    (b"referrer-policy", b"no-referrer"),
    (b"cross-origin-opener-policy", b"same-origin"),
    (b"cross-origin-resource-policy", b"same-origin"),
    (b"content-security-policy",
     b"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
     b"connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; "
     b"frame-ancestors 'none'; form-action 'none'"),
]


class SecurityMiddleware:
    """纯 ASGI 中间件：Host 白名单 → 跨源校验 → 限流 → 鉴权 → 安全响应头。

    顺序很关键：Host 校验必须在最前面。否则攻击者只要能让请求抵达，
    后面的鉴权就是唯一屏障，而浏览器会把同一源下的令牌读走。
    """

    def __init__(self, app, token_provider, api_prefix="/api", exempt=None,
                 limit_per_min=600, failure_threshold=20):
        self.app = app
        self.token_provider = token_provider
        self.api_prefix = api_prefix
        self.exempt = set(exempt or ())
        self.limiter = RateLimiter(limit=limit_per_min, window=60.0)
        self.failures = FailureGuard(threshold=failure_threshold)

    def reset(self, addr: str) -> None:
        """自检专用：清掉该来源的限流与失败计数，避免自检把自己锁在门外。"""
        self.limiter.reset(addr)
        self.failures.reset(addr)

    async def _deny(self, send, status: int, detail: str, extra=None):
        body, headers = _json_bytes({"detail": detail})
        headers = headers + SECURITY_HEADERS + list(extra or [])
        await send({"type": "http.response.start", "status": status, "headers": headers})
        await send({"type": "http.response.body", "body": body})

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        headers = {}
        for k, v in scope.get("headers") or []:
            headers[k.decode("latin1").lower()] = v.decode("latin1")

        client = scope.get("client") or ("unknown", 0)
        addr = str(client[0])
        path = scope.get("path") or ""
        method = scope.get("method") or "GET"

        async def send_with_headers(message):
            if message["type"] == "http.response.start":
                existing = {k.lower() for k, _ in message.get("headers") or []}
                message.setdefault("headers", [])
                message["headers"] = list(message["headers"]) + [
                    (k, v) for k, v in SECURITY_HEADERS if k.lower() not in existing]
            await send(message)

        # 1) Host 头（DNS 重绑定）
        if not host_ok(headers.get("host", "")):
            audit("host_rejected", host=headers.get("host"), path=path, client=addr)
            return await self._deny(send, 403, "invalid host")

        # 2) 浏览器跨源（CSRF）
        if method in ("POST", "PUT", "PATCH", "DELETE"):
            origin = headers.get("origin", "")
            if not origin_ok(origin):
                audit("origin_rejected", origin=origin, path=path, client=addr)
                return await self._deny(send, 403, "cross-origin rejected")
            if headers.get("sec-fetch-site", "").lower() == "cross-site":
                audit("cross_site_rejected", path=path, client=addr)
                return await self._deny(send, 403, "cross-site rejected")

        # 3) 熔断 + 限流
        if self.failures.blocked(addr):
            audit("fail_guard", path=path, client=addr)
            return await self._deny(send, 429, "too many auth failures")
        if path.startswith(self.api_prefix) and path not in self.exempt:
            if not self.limiter.allow(addr):
                audit("rate_limited", path=path, client=addr)
                return await self._deny(send, 429, "rate limit exceeded")

        # 4) 鉴权
        if path.startswith(self.api_prefix) and path not in self.exempt:
            expect = self.token_provider() or ""
            if not expect:
                return await self._deny(send, 503, "token unavailable")
            given = headers.get("x-pf-token", "")
            if not token_matches(given, expect):
                self.failures.bump(addr)
                audit("auth_failed", path=path, client=addr,
                      ua=(headers.get("user-agent") or "")[:160])
                return await self._deny(send, 401, "unauthorized")

        return await self.app(scope, receive, send_with_headers)


class BodyLimitMiddleware:
    """请求体上限：Content-Length 先挡，chunked 传输按实际字节累计再挡。"""

    def __init__(self, app, limit: int = 1_048_576):
        self.app = app
        self.limit = int(limit)

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        for k, v in scope.get("headers") or []:
            if k.decode("latin1").lower() == "content-length":
                try:
                    if int(v.decode("latin1")) > self.limit:
                        body, headers = _json_bytes({"detail": "request body too large"})
                        headers = headers + SECURITY_HEADERS
                        await send({"type": "http.response.start", "status": 413, "headers": headers})
                        await send({"type": "http.response.body", "body": body})
                        audit("body_rejected", path=scope.get("path"), client=str((scope.get("client") or ["?"])[0]))
                        return
                except ValueError:
                    body, headers = _json_bytes({"detail": "bad content-length"})
                    await send({"type": "http.response.start", "status": 400, "headers": headers + SECURITY_HEADERS})
                    await send({"type": "http.response.body", "body": body})
                    return

        received = 0
        started = False

        async def tracked_send(message):
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
            await send(message)

        async def limited_receive():
            nonlocal received
            msg = await receive()
            if msg.get("type") == "http.request":
                received += len(msg.get("body") or b"")
                if received > self.limit:
                    # 抛给本中间件：handler 还没吐响应时直接换 413，避免把超大
                    # chunked 请求整体读进内存。
                    audit("body_rejected", path=scope.get("path"),
                          client=str((scope.get("client") or ["?"])[0]), mode="chunked")
                    raise _BodyTooLarge()
            return msg

        try:
            await self.app(scope, limited_receive, tracked_send)
        except _BodyTooLarge:
            if not started:
                body, headers = _json_bytes({"detail": "request body too large"})
                await send({"type": "http.response.start", "status": 413,
                            "headers": headers + SECURITY_HEADERS})
                await send({"type": "http.response.body", "body": body})


class _BodyTooLarge(Exception):
    pass
