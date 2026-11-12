import os
import struct
import sys

def read_str(f):
    n = struct.unpack("<Q", f.read(8))[0]
    return f.read(n).decode("utf-8", "ignore")

def read_val(f, t):
    if t == 8:
        return read_str(f)
    if t == 9:
        sub = struct.unpack("<I", f.read(4))[0]
        cnt = struct.unpack("<Q", f.read(8))[0]
        return [read_val(f, sub) for _ in range(min(cnt, 4))]
    fmt = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}
    return struct.unpack("<" + fmt[t], f.read(struct.calcsize(fmt[t])))[0]

def gguf_info(path):
    with open(path, "rb") as f:
        if f.read(4) != b"GGUF":
            return None
        ver = struct.unpack("<I", f.read(4))[0]
        tensor_count = struct.unpack("<Q", f.read(8))[0]
        kv_count = struct.unpack("<Q", f.read(8))[0]
        info = {"version": ver, "tensors": tensor_count}
        for _ in range(kv_count):
            key = read_str(f)
            t = struct.unpack("<I", f.read(4))[0]
            val = read_val(f, t)
            if key.startswith("general.") or key.endswith(".block_count") or key.endswith(".context_length"):
                info[key] = val
        return info

paths = [l.split("\t")[1].strip() for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
for p in paths:
    try:
        info = gguf_info(p)
        if info is None:
            print("NOT_GGUF", p)
            continue
        arch = info.get("general.architecture", "?")
        blocks = info.get("%s.block_count" % arch, info.get("%s.block_count".replace("%s", arch), "?"))
        print("%-12s blocks=%-4s tensors=%-5s %s" % (arch, blocks, info.get("tensors"), p))
    except Exception as exc:
        print("ERR %s: %s" % (p, exc))
