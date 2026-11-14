# -*- coding: utf-8 -*-
"""控制台服务契约 + 安全基线测试。

覆盖：鉴权 / Host 校验（DNS 重绑定）/ 跨源拒绝 / 请求体上限 /
      接口地图隐藏 / 安全响应头 / 主动自检 / DPAPI 凭据库 / 总线超时。
"""
import asyncio
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "app"))

import server  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

# 关键：Host 必须落在白名单，否则中间件会先拒（403），测不到鉴权。
BASE = "http://127.0.0.1"
client = TestClient(server.app, base_url=BASE)
client.headers.update({"X-PF-Token": server._token()})
security = server.security


def _anon():
    return TestClient(server.app, base_url=BASE)


def test_api_requires_token():
    """/api/* 无本机 token 必须 401；health 豁免。"""
    anon = _anon()
    assert anon.get("/api/models").status_code == 401
    assert anon.get("/api/health").status_code == 200
    assert client.get("/api/models").status_code == 200


def test_host_header_rejected():
    """伪造 Host = DNS 重绑定的入口，必须 403。"""
    anon = _anon()
    r = anon.get("/api/health", headers={"Host": "evil.example.com"})
    assert r.status_code == 403
    assert "invalid host" in r.text


def test_cross_origin_post_rejected():
    """浏览器跨源 POST（CSRF / 恶意网页）必须 403。"""
    r = client.post("/api/command", json={"action": "status"},
                    headers={"Origin": "https://evil.example.com"})
    assert r.status_code == 403


def test_docs_hidden():
    """生产不暴露接口地图。"""
    assert client.get("/openapi.json").status_code == 404
    assert client.get("/docs").status_code == 404
    assert client.get("/redoc").status_code == 404


def test_security_headers_present():
    r = client.get("/api/health")
    keys = {k.lower() for k in r.headers.keys()}
    for want in ("x-content-type-options", "x-frame-options",
                 "content-security-policy", "referrer-policy"):
        assert want in keys, "缺少安全响应头: %s" % want


def test_body_limit():
    """1MB 以上的请求体直接 413，不读进内存。"""
    r = client.post("/api/parse", content=b"x" * 1_200_000,
                    headers={"Content-Type": "application/json"})
    assert r.status_code == 413


def test_bad_json_is_400_not_500():
    r = client.post("/api/command", content=b"{not json",
                    headers={"Content-Type": "application/json"})
    assert r.status_code == 400


def test_allowed_actions_exist_in_v3():
    """白名单里的每个 action 都必须在当前内核版本的 switch 中真实存在。"""
    scripts = sorted(server.KERNEL_DIR.glob("电脑算力调度中心_v*.ps1"))
    assert scripts, "内核脚本不存在: %s" % server.KERNEL_DIR
    text = scripts[-1].read_text(encoding="utf-8")
    cases = set(re.findall(r"^\s+'([a-z_]+)'\s*\{", text, re.M))
    missing = sorted(server.ALLOWED_ACTIONS - cases)
    assert not missing, "白名单存在内核未实现的动作: %s" % missing


def test_health():
    r = client.get("/api/health")
    assert r.status_code == 200
    body = r.json()
    assert body["app"] == "ok"
    assert body["port"] == server.PORT


def test_health_hides_paths():
    """免费接口不得泄露安装路径等侦察信息。"""
    body = client.get("/api/health").json()
    assert "kernel_dir" not in body
    assert "llama_base" not in body


def test_command_rejects_unknown_action():
    r = client.post("/api/command", json={"action": "delete_everything"})
    assert r.status_code == 400


def test_selfcheck_all_pass():
    """主动攻击自检：真实发请求验证每一道防线。"""
    r = client.post("/api/selfcheck")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True, body
    assert len(body["checks"]) >= 7


def test_security_status_contract():
    r = client.get("/api/security")
    assert r.status_code == 200
    body = r.json()
    assert body["bind"]["loopback_only"] is True
    assert body["docs"]["disabled"] is True
    assert "127.0.0.1" in body["host_guard"]["allowed"]
    assert body["token"]["fingerprint"].startswith("sha256:")


def test_model_router_hardened():
    """本地模型服务必须带 API Key 且 CORS 收敛，不能裸奔在 8080。"""
    txt = (ROOT / "tools" / "model-router.ps1").read_text(encoding="utf-8")
    assert "--api-key-file" in txt, "llama-server 未绑定密钥"
    assert "--cors-origins" in txt, "llama-server 未收敛 CORS"
    assert ".model_key" in txt, "缺少本机模型密钥文件"


def test_vault_roundtrip(monkeypatch, tmp_path):
    """DPAPI 凭据库：写入后可解出，缺失文件返回空。"""
    target = tmp_path / "cloud.vault"
    monkeypatch.setenv("PF_VAULT_PATH", str(target))
    security.vault_set({"api_key": "sk-test", "base_url": "https://example.com"})
    data = security.vault_get()
    assert data["api_key"] == "sk-test"
    assert data["base_url"] == "https://example.com"
    raw = target.read_bytes()
    assert b"sk-test" not in raw, "密钥不能以明文落盘"
    monkeypatch.setenv("PF_VAULT_PATH", str(tmp_path / "missing.vault"))
    assert security.vault_get() == {}


def test_bus_client_timeout_cleans_input(tmp_path):
    """直接测 BusClient，并断言它真的写进了隔离的临时目录。

    旧测试 monkeypatch 的是 server.BUS_IN / BUS_DONE，但 BUS 实例在模块导入时
    就已绑定真实目录，命令仍写进 versions/*/commands/in；而 tmp_path/in 从未
    被创建，glob 恒为空 —— 断言是假阳性且污染生产目录。
    """
    in_dir, done_dir = tmp_path / "in", tmp_path / "done"
    done_dir.mkdir()
    cli = server.bus.BusClient(in_dir, done_dir, "test-kernel")
    ok, text = asyncio.run(cli.call({"action": "status"}, timeout=0.6))
    assert ok is False
    assert "超时" in text
    assert in_dir.is_dir(), "BusClient 必须在目标目录创建 in/"
    assert not list(in_dir.glob("*.json")), "超时后必须撤回 in 里的命令"
