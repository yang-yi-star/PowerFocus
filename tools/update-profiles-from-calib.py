import io
import json
import shutil
import time

PATH = r"E:\PowerFocus\v3\model-profiles.json"
BACKUP = PATH + ".bak-" + time.strftime("%Y%m%d-%H%M%S")

data = json.load(io.open(PATH, encoding="utf-8"))
models = data["models"]

COMMON = {
    "fa": "on",
    "ctx": 8192,
    "cache_type_k": "q8_0",
    "cache_type_v": "f16",
    "threads": 16,
    "threads_batch": 8,
}

TOTAL_MB = 8188

CALIB = {
    "qwen3-14b-q4km": {
        "alias": "Qwen3-14B",
        "speed": (26, 10.37, 7477),
        "safe": (22, 9.02, 6717),
        "note": "ngl=30 实测 2.14 t/s（显存溢出回退内存），禁止使用；8K 档甜点上限 ngl=26",
    },
    "qwen3-4b-instruct-q4km": {
        "alias": "Qwen3-4B",
        "speed": (99, 78.8, 4395),
        "safe": (24, 29.64, 3336),
        "note": "整模型可全量上卡；99 层档显存余量约 3.7GB",
    },
    "heita-q4km": {
        "alias": "Heita",
        "speed": (99, 98.0, 3206),
        "safe": (24, 42.04, 2566),
        "note": "整模型可全量上卡；99 层档显存余量约 4.9GB",
    },
    "qwen2.5-0.5b-instruct-q4km": {
        "alias": "Qwen2.5-0.5B",
        "speed": (99, 344.85, 1546),
        "safe": (16, 209.05, 1432),
        "note": "整模型可全量上卡；99 层档显存余量约 6.6GB",
    },
}


def profile(label, ngl, tps, used_mb, note):
    args = dict(COMMON)
    args["ngl"] = ngl
    return {
        "label": label,
        "args": args,
        "measured": {
            "gen_tokens": 64,
            "tps": tps,
            "vram_used_mb": used_mb,
            "gpu_free_mb": TOTAL_MB - used_mb,
            "engine": "llama.cpp router --models-max 1",
        },
        "notes": note,
    }


stamp = time.strftime("%Y-%m-%d %H:%M")

for key, cfg in CALIB.items():
    m = models[key]
    ngl, tps, used = cfg["speed"]
    sngl, stps, sused = cfg["safe"]
    m["status"] = "calibrated"
    m["measured_at"] = stamp
    m["engine"] = "llama.cpp router mode (port 8080, --models-max 1)"
    m["preset_section"] = cfg["alias"]
    m["profiles"] = {
        "speed_8k": profile("8K 速度优先（实测最优 ngl）", ngl, tps, used, cfg["note"]),
        "safe_8k": profile("8K 安全优先（显存留余量）", sngl, stps, sused, "有浏览器/其他 GPU 负载时使用"),
    }
    m["selection"] = [
        {"when": "gpu_free_mb >= 1200", "use": "speed_8k"},
        {"when": "default", "use": "safe_8k"},
    ]
    m["rules"] = [cfg["note"]]

shutil.copy2(PATH, BACKUP)
with io.open(PATH, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

print("UPDATED", ", ".join(CALIB.keys()))
print("BACKUP", BACKUP)
