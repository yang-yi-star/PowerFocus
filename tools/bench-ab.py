"""A/B 实测：有调度 vs 无调度，同一个模型、同一个 prompt，比 tok/s。

用法：
  python tools\\bench-ab.py baseline    # 基线：不动任何进程
  python tools\\bench-ab.py dispatched  # 调度后：先压其他进程再测

Ollama /api/generate 返回 eval_count / eval_duration(ns)，tok/s = eval_count / (eval_duration/1e9)。
"""
import json
import sys
import time
import urllib.request

OLLAMA = "http://127.0.0.1:11434"
MODEL = "qwen3:8b"
PROMPT = "用三句话解释什么是算力调度。"
NUM_PREDICT = 96
ROUNDS = 3


def stats() -> dict:
    """采一次系统快照：CPU 占用、可用内存、显存。"""
    import subprocess
    out = {}
    try:
        r = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.total,memory.used,memory.free,utilization.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            p = [x.strip() for x in r.stdout.split(",")]
            out["gpu_total_mb"] = int(p[0]); out["gpu_used_mb"] = int(p[1])
            out["gpu_free_mb"] = int(p[2]); out["gpu_util_pct"] = int(p[3])
    except Exception as e:
        out["gpu_err"] = str(e)
    try:
        import ctypes

        class MEMORYSTATUS(ctypes.Structure):
            _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong),
                        ("ullTotalPhys", ctypes.c_ulonglong), ("ullAvailPhys", ctypes.c_ulonglong),
                        ("ullTotalPageFile", ctypes.c_ulonglong), ("ullAvailPageFile", ctypes.c_ulonglong),
                        ("ullTotalVirtual", ctypes.c_ulonglong), ("ullAvailVirtual", ctypes.c_ulonglong),
                        ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]
        m = MEMORYSTATUS(); m.dwLength = ctypes.sizeof(MEMORYSTATUS)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m))
        out["mem_total_mb"] = round(m.ullTotalPhys / 1048576, 1)
        out["mem_avail_mb"] = round(m.ullAvailPhys / 1048576, 1)
        out["mem_load_pct"] = m.dwMemoryLoad
    except Exception as e:
        out["mem_err"] = str(e)
    return out


def generate() -> dict:
    body = json.dumps({
        "model": MODEL, "prompt": PROMPT, "stream": False,
        "options": {"num_predict": NUM_PREDICT, "temperature": 0.2},
    }).encode("utf-8")
    req = urllib.request.Request(f"{OLLAMA}/api/generate", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=600) as r:
        d = json.loads(r.read().decode("utf-8"))
    wall = time.time() - t0
    ec = d.get("eval_count", 0)
    ed = d.get("eval_duration", 0)  # ns
    pc = d.get("prompt_eval_count", 0)
    pd = d.get("prompt_eval_duration", 0)
    tg = ec / (ed / 1e9) if ed else 0
    pp = pc / (pd / 1e9) if pd else 0
    return {
        "eval_count": ec, "eval_duration_ns": ed, "tok_per_s": round(tg, 2),
        "prompt_count": pc, "prompt_per_s": round(pp, 2), "wall_s": round(wall, 2),
        "load_ms": d.get("load_duration", 0) // 1_000_000,
    }


def main() -> int:
    label = sys.argv[1] if len(sys.argv) > 1 else "baseline"
    print(f"=== {label} ===")
    s = stats()
    print("系统状态:", json.dumps(s, ensure_ascii=False))
    rows = []
    for i in range(ROUNDS):
        print(f"\n[第 {i+1}/{ROUNDS} 轮] ", end="", flush=True)
        try:
            r = generate()
            print(f"tg={r['tok_per_s']} tok/s  pp={r['prompt_per_s']} tok/s  "
                  f"tokens={r['eval_count']}  wall={r['wall_s']}s  load={r['load_ms']}ms")
            rows.append(r)
        except Exception as e:
            print(f"失败: {type(e).__name__}: {e}")
    if rows:
        avg = sum(r["tok_per_s"] for r in rows) / len(rows)
        print(f"\n--- {label} 平均: {avg:.2f} tok/s（{len(rows)} 轮）---")
        out = {"label": label, "avg_tok_per_s": round(avg, 2),
               "snapshot": s, "rows": rows}
        fn = f"bench-ab-{label}.json"
        open(os.path.join(os.path.dirname(os.path.abspath(__file__)), fn),
             "w", encoding="utf-8").write(json.dumps(out, ensure_ascii=False, indent=2))
        print(f"已写 {fn}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
