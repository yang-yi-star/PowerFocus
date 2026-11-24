import asyncio
import json
import os
import subprocess
import sys

import edge_tts

VOICE = "zh-CN-YunxiaNeural"
RATE = "+16%"
ROOT = r"E:\PowerFocus\marketing\douyin\video_v0120_human"
TTS_DIR = os.path.join(ROOT, "tts")

SEGMENTS = [
    ("s01", "先说个丢人的。"),
    ("s02", "我这软件打包出来的 exe，版本号是新的，里头装的还是上一版的组件。"),
    ("s03", "这个 bug 我自己没发现。"),
    ("s04", "现在打包跟着版本指针走，指到哪装哪。"),
    ("s05", "第二件事，清场。以前这个按钮按下去，就是杀进程。"),
    ("s06", "你正在剪片子，或者跑模型，它一按，东西没了。"),
    ("s07", "现在的做法反过来：降优先级，开 EcoQoS，把工作集换出去。"),
    ("s08", "就像让一个正在干活的人先站边上歇会儿，不是赶他出门。手一松，他回来接着干。"),
    ("s09", "我给自己留了一句话：这个我正在用。它和它下面那一串子进程，整组都不动。"),
    ("s10", "为什么非加这条？我这台机器是 8940HX、5060 8G、32G 内存，跑本地模型经常把内存顶满。"),
    ("s11", "最怕的就是跑到一半，被清掉。"),
    ("s12", "温度也是，按天记日志，峰值留着。"),
    ("s13", "GPU 拿不到，就退 nvidia-smi。CPU 实在拿不到，就空着。"),
    ("s14", "别的机器我不敢保证。"),
    ("s15", "空着难看。编个数更难看。"),
    ("s16", "病毒扫描做成了真接口，扫完能看到进度和结果。"),
    ("s17", "要处置，得你点确认。你不点，它只敢报告。"),
    ("s18", "MCP 的只读工具，11 个了。上一版 10 个。"),
    ("s19", "113 个测试全过，ruff 零错误。"),
    ("s20", "想试试的，GitHub 搜 PowerFocus。不想装也行，看看热闹。"),
]


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", path],
        capture_output=True, text=True,
    )
    try:
        return float(out.stdout.strip())
    except ValueError:
        return 0.0


async def main():
    os.makedirs(TTS_DIR, exist_ok=True)
    meta = []
    for sid, text in SEGMENTS:
        path = os.path.join(TTS_DIR, sid + ".mp3")
        comm = edge_tts.Communicate(text, VOICE, rate=RATE)
        await comm.save(path)
        dur = probe(path)
        meta.append({"id": sid, "text": text, "file": path, "dur": dur})
        print(f"{sid}  {dur:.2f}s  {os.path.getsize(path)} bytes  | {text[:24]}")
    with open(os.path.join(ROOT, "segments.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    total = sum(m["dur"] for m in meta)
    print(f"\nTOTAL = {total:.2f}s")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    asyncio.run(main())
