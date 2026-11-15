# -*- coding: utf-8 -*-
from pathlib import Path
K = Path(r"E:\PowerFocus\versions\v0.12\电脑算力调度中心_v0.12.ps1")
raw = K.read_bytes()
bom = raw.startswith(b"\xef\xbb\xbf")
t = raw.decode("utf-8-sig")
old = "                    $script:PowerEcoQos += $p.Id"
new = "                    $script:PowerEcoQos[[int]$p.Id] = $true"
if old not in t:
    raise SystemExit("锚点未找到")
t = t.replace(old, new, 1)
K.write_bytes((b"\xef\xbb\xbf" if bom else b"") + t.encode("utf-8"))
print("OK 已改为索引赋值（哈希表不能用 +=）")
