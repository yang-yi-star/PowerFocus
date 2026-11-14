# -*- coding: utf-8 -*-
"""v0.11.1 回归：双专家遗留缺陷（F3/F8/F10/B11/B12/B13/B21/B22/B29）修复后的守卫。

风格与 test_p0_hardening.py 一致：不触碰真实内核、不污染生产目录，
所有 I/O 走 tmp_path 或 monkeypatch。
"""
import asyncio
import sys
import time
import types
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "product" / "v1.00" / "app"
sys.path.insert(0, str(ROOT / "app"))
import server  # noqa: E402  （app/server.py shim → 产品版 server.py）
security = server.security  # noqa: E402

# 关键：Host 白名单要求 base_url 是 127.0.0.1（test_console.py 同款约定）。
from fastapi.testclient import TestClient  # noqa: E402

# dependency_bootstrap 依赖 app_paths 与大量 Windows API；只摘 consent 协议层。
DB = ROOT / "versions" / "v0.10" / "dependency_bootstrap.py"


def _load_consent_layer():
    """把 mint_consent / check_consent 以独立模块加载，隔离其模块级状态。"""
    src = DB.read_text(encoding="utf-8")
    start = src.index("_CONSENT_NONCES")
    end = src.index("def check_consent")
    end = src.index("\n\n", end)
    snippet = ("from typing import Dict\n"
               "import secrets as _secrets\nimport time as _time\n"
               + src[start:end])
    mod = types.ModuleType("pf_consent_test")
    exec(compile(snippet, "<consent>", "exec"), mod.__dict__)
    return mod


def _client():
    c = TestClient(server.app, base_url="http://127.0.0.1")
    c.headers.update({"X-PF-Token": server._token()})
    return c


# ---------------------------------------------------------------- F8 同意令牌

def test_f8_consent_single_use():
    m = _load_consent_layer()
    tok = m.mint_consent("install")
    assert tok, "必须签发非空令牌"
    assert m.check_consent(tok, "install") is True
    # 一次性：同一个令牌第二次必须失败
    assert m.check_consent(tok, "install") is False


def test_f8_consent_scope_bound():
    m = _load_consent_layer()
    tok = m.mint_consent("download")
    # scope 不匹配的令牌不能跨用途使用；且 pop 语义下错误尝试直接烧掉令牌
    # （更严格：拿不到的令牌连重放机会都没有）
    assert m.check_consent(tok, "install") is False
    assert m.check_consent(tok, "install") is False, "烧掉后不能重放"
    tok2 = m.mint_consent("download")
    assert m.check_consent(tok2, "download") is True


def test_f8_consent_expired():
    m = _load_consent_layer()
    tok = m.mint_consent("install")
    # 篡改过期时间模拟 TTL 过期
    scope, exp = m._CONSENT_NONCES[tok]
    m._CONSENT_NONCES[tok] = (scope, exp - (m._CONSENT_TTL + 1))
    assert m.check_consent(tok, "install") is False


def test_f8_consent_empty_and_garbage():
    m = _load_consent_layer()
    assert m.check_consent("", "install") is False
    assert m.check_consent("yes", "install") is False
    assert m.check_consent("deadbeef", "install") is False


def test_f8_no_hardcoded_consent_token_in_source():
    """F8 本体：源码里不得再有可读的「同意确认令牌」常量。"""
    src = DB.read_text(encoding="utf-8")
    for needle in ("SECOND_CONSENT_TOKEN =", "INSTALL_CONSENT_TOKEN =",
                   'consent == "yes-confirmed"', "consent_token = 'yes"):
        assert needle not in src, "dependency_bootstrap.py 不应再含硬编码同意令牌: %s" % needle


def test_f8_route_mints_and_consumes_server_side(monkeypatch):
    """前端仍发 consent:'yes'；一次性令牌必须由服务端现场签发并立即消费。"""
    captured = {}

    class _FakeBootstrap:
        COMPONENTS = [type("C", (), {"id": "comp_a"})()]

        def mint_consent(self, scope):
            captured["scope"] = scope
            return "srv-minted-token"

        def check_consent(self, tok, scope):
            captured["token_seen"] = tok
            return tok == "srv-minted-token" and scope == captured.get("scope")

        def install(self, cid, consent, *a, **kw):
            captured["install_consent"] = consent
            return {"executed": True, "component_id": cid}

    fake = _FakeBootstrap()
    monkeypatch.setattr(server, "_bootstrap", lambda: fake, raising=False)
    with _client() as client:
        # 无令牌必须被安全中间件拦截
        anon = TestClient(server.app, base_url="http://127.0.0.1")
        r = anon.post("/api/bootstrap/install",
                      json={"component_id": "comp_a", "consent": "yes"})
        assert r.status_code in (401, 403, 429, 503), "缺令牌必须被拦截"
        # 带令牌：服务端应现场签发令牌并传给 install，而不是把 'yes' 透传
        r = client.post("/api/bootstrap/install",
                        json={"component_id": "comp_a", "consent": "yes"})
        assert r.status_code == 200
        assert captured.get("scope") == "download"
        assert captured.get("install_consent") == "srv-minted-token", \
            "install 收到的必须是服务端现场签发的一次性令牌"
        assert captured.get("install_consent") != "yes", \
            "客户端输入 'yes' 绝不能被当作同意令牌透传"


# ---------------------------------------------------------------- B22 限流器

def test_b22_limiter_sweeps_expired_buckets():
    lim = security.RateLimiter(limit=5, window=0.05)
    for k in ("a", "b", "c", "d", "e"):
        lim.allow(k)
    assert len(lim._hits) == 5
    time.sleep(0.08)   # 过了窗口
    lim.allow("f")     # 触发清扫
    # 过期空桶被删除，只剩 f 自己的桶
    assert set(lim._hits.keys()) == {"f"}, "过期空桶必须被清扫，不能无界增长"


def test_b22_limiter_active_keys_survive_sweep():
    lim = security.RateLimiter(limit=5, window=0.05)
    lim.allow("hot")
    time.sleep(0.08)
    lim.allow("hot")   # hot 又有新时间戳，不应被清扫
    assert "hot" in lim._hits


def test_f3_health_rate_limited_by_config():
    """F3：health 免鉴权但不能免限流——限流必须先于鉴权、覆盖全部 /api。"""
    assert "/api/health" not in (security.SecurityMiddleware.__doc__ or "")
    lim = security.RateLimiter(limit=2, window=60.0)
    assert lim.allow("1.2.3.4") is True
    assert lim.allow("1.2.3.4") is True
    assert lim.allow("1.2.3.4") is False, "限流器必须真的拒绝超额请求"
    # health 不在豁免鉴权的场景下也必须有限流（行为断言走 RateLimiter 本体，
    # 中间件源码级断言：limit 检查出现在鉴权之前）
    src = (APP / "security.py").read_text(encoding="utf-8")
    rate_pos = src.index("rate limit exceeded")
    auth_pos = src.index("return await self._deny(send, 401")
    assert rate_pos < auth_pos, "限流判定必须发生在鉴权之前（否则 health 豁免=无限制）"


# ---------------------------------------------------------------- B21 chunked

def _chunked_scope(body: bytes, limit: int):
    async def receive():
        return {"type": "http.request", "body": body, "more_body": False}

    responded = {}

    async def send(msg):
        responded.setdefault(msg["type"], msg)

    async def downstream(scope, receive, send):
        # 模拟真实 handler：先读请求体（触发 limited_receive 的累计与拦截），
        # 再回 200。不读体的话 chunked 计数永远不会发生。
        while True:
            msg = await receive()
            if not msg.get("more_body"):
                break
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"ok"})

    mw = security.BodyLimitMiddleware(downstream, limit=limit)
    scope = {"type": "http", "method": "POST", "path": "/api/x",
             "headers": [(b"transfer-encoding", b"chunked")]}
    asyncio.run(mw(scope, receive, send))
    return responded


def test_b21_chunked_body_over_limit_rejected():
    responded = _chunked_scope(b"x" * 64, limit=16)
    assert responded["http.response.start"]["status"] == 413, \
        "chunked 无 Content-Length 也必须按实际字节拦截"


def test_b21_chunked_body_under_limit_passes():
    responded = _chunked_scope(b"x" * 8, limit=16)
    assert responded["http.response.start"]["status"] == 200


# ---------------------------------------------------------------- B11 / B12

def test_b11_chat_rejects_non_list_messages():
    with _client() as client:
        for bad in ("hello", 123, {"role": "user"}):
            r = client.post("/api/chat", json={"target": "cloud", "messages": bad})
            assert r.status_code == 400, "messages=%r 必须 400 而不是 500" % (bad,)


def test_b12_models_survives_broken_profiles(tmp_path, monkeypatch):
    """profiles 文件被改成 list 时 /api/models 不能 500。"""
    broken = tmp_path / "models.json"
    broken.write_text('["not", "a", "dict"]', encoding="utf-8")
    monkeypatch.setattr(server, "PROFILES", broken, raising=False)
    with _client() as client:
        r = client.get("/api/models")
        assert r.status_code == 200, "烂 profiles 不能把 /api/models 打成 500"
        assert r.json().get("models") == []


# ---------------------------------------------------------------- B13 / B29

def test_b13_timeout_contract():
    """后端把 _timeout 夹紧到 [1,600]；前端必须有按 _timeout 放大的 HTTP 预算。"""
    src = (APP / "server.py").read_text(encoding="utf-8")
    assert "min(timeout, 600.0)" in src, "后端必须把 _timeout 上限夹到 600 秒"
    js = (APP / "web" / "app.js").read_text(encoding="utf-8")
    assert "budgetMs" in js, "前端必须有按 _timeout 放大的 HTTP 预算（B13）"


def test_b29_dev_entry_uses_product_serve_only():
    shim = (ROOT / "app" / "server.py").read_text(encoding="utf-8")
    assert "serve_only()" in shim, "开发版入口必须统一走产品版 serve_only"
    assert "uvicorn.run" not in shim, "开发版入口不得再自带 uvicorn.run"
