"""验证产品层 resolve_kernel() 是否真的指向 v0.11，以及 Python 组件目录是否跟着走。"""
import sys
import importlib.util
from pathlib import Path

SERVER = Path(r"E:\PowerFocus\product\v1.00\app\server.py")
if not SERVER.exists():
    print(f"ERROR: 找不到 {SERVER}")
    sys.exit(1)

# 不执行 main()，只取模块级函数
sys.path.insert(0, str(SERVER.parent))
src = SERVER.read_text(encoding="utf-8", errors="replace")

# 只导入不启动：--check 之类的启动会开 HTTP 服务，所以用 exec 局部化
ns = {"__name__": "pf_server_probe", "__file__": str(SERVER)}
try:
    exec(compile(src, str(SERVER), "exec"), ns)
except SystemExit as e:
    print(f"server.py 触发 SystemExit({e.code})，通常在 main() 守卫里，属正常")
except Exception as e:
    print(f"执行失败: {type(e).__name__}: {e}")
    sys.exit(1)

print("=== 1. resolve_kernel() ===")
if "resolve_kernel" in ns:
    k = ns["resolve_kernel"]()
    print(f"  返回: {k}")
    print(f"  存在: {Path(k).is_dir() if k else False}")
    if k and Path(k).is_dir():
        mf = Path(k) / "MANIFEST.json"
        if mf.exists():
            import json
            j = json.loads(mf.read_text(encoding="utf-8"))
            print(f"  MANIFEST: version={j.get('version')} stage={j.get('stage')}")
else:
    print("  未找到 resolve_kernel")

print("\n=== 2. _py_component_dir() ===")
if "_py_component_dir" in ns:
    for name in ("dependency_bootstrap", "security_scan", "engine_adapters", "kvrt_bundle"):
        try:
            d = ns["_py_component_dir"](name)
            exists = (Path(d) / f"{name}.py").exists() if d else False
            print(f"  {name:24} -> {d}  (文件存在={exists})")
        except Exception as e:
            print(f"  {name:24} -> 异常: {e}")
else:
    print("  未找到 _py_component_dir")

print("\n=== 3. KERNEL_DIR / PF_ROOT ===")
for v in ("KERNEL_DIR", "PF_ROOT", "VERS"):
    if v in ns:
        print(f"  {v} = {ns[v]}")
