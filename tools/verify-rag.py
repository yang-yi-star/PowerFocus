# -*- coding: utf-8 -*-
"""验证 RAG 前置件：Ollama embedding 接口是否真能用。

只读探测，不建索引、不改任何状态。
"""
import json
import time
import urllib.request

BASE = "http://127.0.0.1:11434"


def post(path: str, body: dict, timeout: float = 30.0) -> dict:
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def main() -> None:
    for model in ("bge-m3:latest", "nomic-embed-text:latest"):
        try:
            t0 = time.time()
            out = post("/api/embed", {"model": model,
                                      "input": "PowerFocus 统一内存架构，调度单位是算力"})
            vec = (out.get("embeddings") or [[]])[0]
            print("%-26s dim=%-5d %.2fs" % (model, len(vec), time.time() - t0))
        except Exception as e:
            print("%-26s 失败: %s: %s" % (model, type(e).__name__, str(e)[:150]))

    # 批量与相似度：确认可用于检索排序
    try:
        out = post("/api/embed", {"model": "bge-m3:latest",
                                  "input": ["本地模型优先运转", "显卡温度和风扇转速", "病毒扫描"]})
        embs = out.get("embeddings") or []
        print("\n批量返回 %d 条向量，dim=%s" % (len(embs), len(embs[0]) if embs else None))
        if len(embs) == 3:
            def cos(a, b):
                return sum(x * y for x, y in zip(a, b)) / (
                    (sum(x * x for x in a) ** 0.5) * (sum(y * y for y in b) ** 0.5))
            print("相似度(本地模型优先, 温度风扇) = %.4f" % cos(embs[0], embs[1]))
            print("相似度(本地模型优先, 病毒扫描) = %.4f" % cos(embs[0], embs[2]))
    except Exception as e:
        print("批量/相似度失败: %s: %s" % (type(e).__name__, str(e)[:150]))


if __name__ == "__main__":
    main()
