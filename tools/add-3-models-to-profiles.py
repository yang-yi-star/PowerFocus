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

NEW = {
    "qwen3-8b-q4km": {
        "alias": "Qwen3-8B",
        "path": r"D:\计算机知识库中心\90-Projects-Code\.assistant\models\qwen3-8b-q4_k_m.gguf",
        "arch": "qwen3",
        "size": 4.68,
        "ngl": 99,
        "tps": 27.73,
        "used": 7556,
        "alt": (30, 27.4, 6685),
        "note": "全量上卡 99 层比 30 层略快（27.73 vs 27.40），显存余量仅 632MB，建议无其他 GPU 负载时使用",
    },
    "qwen2.5-7b-q4km": {
        "alias": "Qwen2.5-7B",
        "path": r"D:\openhua\老D\tianet\models\qwen2.5-7b-q4_k_m.gguf",
        "arch": "qwen2",
        "size": 4.36,
        "ngl": 99,
        "tps": 53.27,
        "used": 6636,
        "alt": (24, 33.68, 6015),
        "note": "全量上卡最快；24 层档显存余 2.1GB，速度损失 37%",
    },
    "heita-fp16": {
        "alias": "Heita-F16",
        "path": r"D:\heita_work\heita-fp16.gguf",
        "arch": "qwen2",
        "size": 5.75,
        "ngl": 24,
        "tps": 16.98,
        "used": 6498,
        "alt": (20, 14.23, 5832),
        "note": "F16 版权重太大，99 层溢出到内存只剩 11.7 t/s；甜点 24 层",
    },
}


def make_profile(label, ngl, tps, used, note):
    args = dict(COMMON)
    args["ngl"] = ngl
    return {
        "label": label,
        "args": args,
        "measured": {
            "gen_tokens": 64,
            "tps": tps,
            "vram_used_mb": used,
            "gpu_free_mb": TOTAL_MB - used,
            "engine": "llama.cpp router --models-max 1",
        },
        "notes": note,
    }


stamp = time.strftime("%Y-%m-%d %H:%M")

for key, cfg in NEW.items():
    ngl, tps, used = cfg["ngl"], cfg["tps"], cfg["used"]
    models[key] = {
        "identity": {
            "architecture": cfg["arch"],
            "size_gb": cfg["size"],
            "path_hint": cfg["path"],
            "note": "全盘扫描 2026-11-04 补录",
        },
        "common": {
            "threads": 16,
            "threads_batch": 8,
            "host": "127.0.0.1",
            "port": 8080,
            "parallel": 1,
            "alias": cfg["alias"],
        },
        "status": "calibrated",
        "measured_at": stamp,
        "engine": "llama.cpp router mode (port 8080, --models-max 1)",
        "preset_section": cfg["alias"],
        "profiles": {
            "speed_8k": make_profile("8K 速度优先（实测最优 ngl）", ngl, tps, used, cfg["note"]),
        },
        "selection": [{"when": "default", "use": "speed_8k"}],
        "rules": [cfg["note"]],
    }

shutil.copy2(PATH, BACKUP)
with io.open(PATH, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)

print("ADDED", ", ".join(NEW.keys()))
print("BACKUP", BACKUP)
