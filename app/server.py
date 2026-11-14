# -*- coding: utf-8 -*-
# ============================================================
# 开发版入口（app\server.py）
#
# 职责：不再维护第二份后端。导入即复用
#       product\v1.00\app\server.py，并把产品版模块注册为自身模块，
#       于是 `import server` 拿到的就是产品版对象——属性、monkeypatch、
#       测试全部指向同一份代码，不会出现「开发版修了产品版没修」的分叉。
#
# 直接运行：.venv\Scripts\python.exe app\server.py  （默认 127.0.0.1:18080）
# ============================================================
import importlib.util
import sys
from pathlib import Path

_PRODUCT_APP = Path(__file__).resolve().parents[1] / "product" / "v1.00" / "app"
_SRC = _PRODUCT_APP / "server.py"

if not _SRC.exists():
    raise SystemExit("产品版后端缺失：%s" % _SRC)

if str(_PRODUCT_APP) not in sys.path:
    sys.path.insert(0, str(_PRODUCT_APP))

_spec = importlib.util.spec_from_file_location("pf_product_server", str(_SRC))
_mod = importlib.util.module_from_spec(_spec)
sys.modules["pf_product_server"] = _mod
_spec.loader.exec_module(_mod)
sys.modules[__name__] = _mod

if __name__ == "__main__":
    # B29：不再维护第二条固定端口启动路径，统一走产品版 serve_only()。
    _mod.serve_only()
