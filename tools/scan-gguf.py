import os

OUT = r"E:\PowerFocus\v3\logs\all-gguf.txt"
roots = ["C:\\", "D:\\", "E:\\"]
skip = {"C:\\Windows", "C:\\$Recycle.Bin", "D:\\$Recycle.Bin", "E:\\$Recycle.Bin"}

rows = []
for root in roots:
    for dirpath, dirnames, filenames in os.walk(root, topdown=True, onerror=lambda e: None):
        if any(dirpath.startswith(s) for s in skip):
            dirnames[:] = []
            continue
        for fn in filenames:
            if fn.lower().endswith(".gguf"):
                fp = os.path.join(dirpath, fn)
                try:
                    rows.append((os.path.getsize(fp) / (1024 ** 3), fp))
                except OSError:
                    pass

rows.sort(reverse=True)
with open(OUT, "w", encoding="utf-8") as f:
    for gb, fp in rows:
        f.write("%.2f\t%s\n" % (gb, fp))

print("GGUF_COUNT", len(rows))
for gb, fp in rows:
    print("%.2f\t%s" % (gb, fp))
