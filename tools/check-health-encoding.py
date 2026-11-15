# -*- coding: utf-8 -*-
"""确认 /api/health 的中文到底是真乱码，还是 PowerShell 侧按 latin-1 解码造成的假象。"""
import urllib.request, json

url = "http://127.0.0.1:18080/api/health"
with urllib.request.urlopen(url, timeout=15) as r:
    raw = r.read()
    ctype = r.headers.get("Content-Type")

print("Content-Type =", ctype)
print("原始字节前 40 =", raw[:40])
print("按 UTF-8 解码 =", json.loads(raw.decode("utf-8")))

# 对照：按 latin-1 解码，看是否复现 PowerShell 里看到的乱码
try:
    print("按 latin-1 解码 =", json.loads(raw.decode("latin-1")))
except Exception as e:
    print("latin-1 解码失败（说明确实是 UTF-8 字节）:", type(e).__name__)
