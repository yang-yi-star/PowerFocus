"""探针：确认 Ollama embedding 底座可用（RAG 的前置条件）
用法：E:\\PowerFocus\\.venv\\Scripts\\python.exe tools\\probe-ollama-embed.py
"""
import json
import sys
import time

import httpx

BASE = "http://127.0.0.1:11434"


def main() -> int:
    fail = 0

    # 1. 服务是否活着
    try:
        r = httpx.get(f"{BASE}/api/tags", timeout=10)
        print(f"[1] /api/tags  status={r.status_code}")
        if r.status_code != 200:
            print("    FAIL: Ollama 不可达")
            return 1
    except Exception as e:
        print(f"[1] FAIL: 连不上 Ollama: {e}")
        return 1

    models = [m["name"] for m in r.json().get("models", [])]
    print(f"    已装模型: {models}")
    targets = [m for m in models if "bge" in m.lower() or "embed" in m.lower()]
    print(f"    embedding 类模型: {targets}")
    if not targets:
        print("    FAIL: 没有 embedding 模型，需要先 ollama pull bge-m3")
        fail += 1
        print(f"\n结论: {fail} 项失败")
        return fail

    model = targets[0]

    # 2. 单条 embed
    t0 = time.perf_counter()
    try:
        r = httpx.post(
            f"{BASE}/api/embed",
            json={"model": model, "input": "PowerFocus 是整机算力调度中心"},
            timeout=120,
        )
    except Exception as e:
        print(f"[2] FAIL: /api/embed 异常: {e}")
        return 1
    dt = time.perf_counter() - t0
    print(f"[2] /api/embed  status={r.status_code}  耗时={dt:.2f}s")
    if r.status_code != 200:
        print(f"    body: {r.text[:300]}")
        return 1

    body = r.json()
    embs = body.get("embeddings") or []
    if not embs:
        print(f"    FAIL: 响应无 embeddings 字段。keys={list(body.keys())}")
        return 1
    dim = len(embs[0])
    print(f"    dim={dim}  向量前5={[round(x, 4) for x in embs[0][:5]]}")

    # 3. 批量 embed + 归一化检查（余弦相似度前置）
    t0 = time.perf_counter()
    r = httpx.post(
        f"{BASE}/api/embed",
        json={"model": model, "input": ["整机算力池", "显卡显存", "今天天气不错"]},
        timeout=120,
    )
    dt = time.perf_counter() - t0
    print(f"[3] 批量3条  status={r.status_code}  耗时={dt:.2f}s")
    if r.status_code != 200:
        print(f"    FAIL: {r.text[:300]}")
        fail += 1
    else:
        vs = r.json()["embeddings"]
        print(f"    返回 {len(vs)} 条，每条 dim={len(vs[0])}")

        def norm(v):
            return sum(x * x for x in v) ** 0.5

        n0 = norm(vs[0])
        print(f"    模长: {[round(norm(v), 3) for v in vs]}  (接近 1.0 = 已归一化)")
        # 相似度对比：前两条应比第三条更近
        def cos(a, b):
            dot = sum(x * y for x, y in zip(a, b))
            return dot / (norm(a) * norm(b) + 1e-12)

        print(f"    cos(算力池, 显存) = {cos(vs[0], vs[1]):.4f}   (应偏高)")
        print(f"    cos(算力池, 天气) = {cos(vs[0], vs[2]):.4f}   (应偏低)")
        if cos(vs[0], vs[1]) <= cos(vs[0], vs[2]):
            print("    FAIL: 语义相似度关系不符合预期")
            fail += 1

    print(f"\n结论: {'全部通过' if fail == 0 else str(fail) + ' 项失败'}")
    return fail


if __name__ == "__main__":
    sys.exit(main())
