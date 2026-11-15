# -*- coding: utf-8 -*-
"""把 v0.12 转正式版：MANIFEST stage=stable、current.json 指向 v0.12、产品层 kernel 依赖改 v0.12。
所有 JSON 写出去 BOM（json.loads 读到 BOM 会炸）。"""
from pathlib import Path
import json, shutil, datetime, sys

REPO = Path(r"E:\PowerFocus")
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")

def load_bom_safe(p):
    return json.loads(p.read_bytes().decode("utf-8-sig"))

def save_no_bom(p, obj):
    txt = json.dumps(obj, ensure_ascii=False, indent=2) + "\n"
    p.write_bytes(txt.encode("utf-8"))

def backup(p, tag):
    b = p.with_name(p.name + f".bak-{tag}")
    if not b.exists():
        shutil.copy2(p, b)
    return b

# 1) v0.12 MANIFEST -> stable
m12 = REPO / "versions" / "v0.12" / "MANIFEST.json"
d = load_bom_safe(m12)
old_stage = d.get("stage")
backup(m12, f"{stamp}-stable")
d["stage"] = "stable"
d["note"] = ("v0.12 转正式版：进程价值判据重写（按可见窗口分级，TCP 连接不再算\"在用\"）、"
             "清场永不杀进程（改为优先级 + EcoQoS + 工作集换出）、EcoQoS 与工作集修剪随释放完整还原")
save_no_bom(m12, d)
print(f"1) v0.12 MANIFEST: stage {old_stage} -> stable")

# 2) current.json -> v0.12
cur = REPO / "versions" / "current.json"
c = load_bom_safe(cur)
old_ver = c.get("version")
backup(cur, f"{stamp}-stable")
c["version"] = "v0.12"
c["updated"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
save_no_bom(cur, c)
print(f"2) current.json: {old_ver} -> v0.12")

# 3) 产品层 MANIFEST kernel 依赖
pm = REPO / "product" / "v1.00" / "MANIFEST.json"
p = load_bom_safe(pm)
old_k = p.get("kernel_version"), p.get("kernel_required")
backup(pm, f"{stamp}-kernel12")
p["kernel_version"] = "v0.12"
p["kernel_required"] = ">= v0.12"
save_no_bom(pm, p)
print(f"3) product MANIFEST: {old_k} -> ('v0.12', '>= v0.12')")

print("\n回滚：把 .bak-* 覆盖回去即可")
