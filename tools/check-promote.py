# -*- coding: utf-8 -*-
from pathlib import Path
import json

FILES = [
    Path(r"E:\PowerFocus\versions\v0.12\MANIFEST.json"),
    Path(r"E:\PowerFocus\versions\current.json"),
    Path(r"E:\PowerFocus\product\v1.00\MANIFEST.json"),
]
BOM = b"\xef\xbb\xbf"
for f in FILES:
    raw = f.read_bytes()
    has_bom = raw.startswith(BOM)
    d = json.loads(raw.decode("utf-8-sig"))
    print(f"{f.name:16} BOM={str(has_bom):5} stage={d.get('stage','-'):8} "
          f"version={d.get('version','-'):8} kernel={d.get('kernel_version','-')}")
