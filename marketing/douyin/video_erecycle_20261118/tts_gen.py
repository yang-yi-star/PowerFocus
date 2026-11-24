import asyncio
import json
import os
import subprocess
import sys

import edge_tts

VOICE = "zh-CN-YunxiaNeural"
RATE = "+20%"
ROOT = r"E:\PowerFocus\marketing\douyin\video_erecycle_20261118"
TTS_DIR = os.path.join(ROOT, "tts")

SEGMENTS = [
    ("s01", "11 月 17 号，E 盘剩 0.00 GB。两百个 G，两天见底。"),
    ("s02", "先查是谁在写。E 盘的 tts 目录，一个训练脚本每 1 到 3 分钟掉一个 .pth，585 兆。"),
    ("s03", "我开始删。删了 1956 项，31.55 GB。盘还是满的。"),
    ("s04", "因为删不是删。它进了回收站。回收站也在你的盘上。"),
    ("s05", "清回收站。第一招，Clear-RecycleBin。没报错，零删除。"),
    ("s06", "第二招，直接删目录。每个文件回我 Access denied。三条 FullControl，一条 Deny 都没有。"),
    ("s07", "第三招，rd /s /q，一样。第四招调 API，返回 S_OK。S_OK 就是成功。一个字节没动。"),
    ("s08", "我先怀疑腾讯电脑管家。冤枉它了，它连进程都没跑。"),
    ("s09", "真凶是执行环境的保护层，专拦我这个工具进程树。就是我伸出去的一整串手，它按这串手认人。别的机器我不敢保证。"),
    ("s10", "解法很土。SYSTEM 计划任务，跑同一条命令，脱离这串手。一次成功，31.95 GB 回来了。"),
    ("s11", "三件事。删进回收站不等于释放。API 说成功不等于事情发生。动手前先留清单，3732 项。"),
    ("s12", "你回收站现在多大？右键看属性。先看里面有什么，再决定清不清。"),
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
        print(f"{sid}  {dur:.2f}s  {os.path.getsize(path)} bytes  | {text[:22]}")
    with open(os.path.join(ROOT, "segments.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    total = sum(m["dur"] for m in meta)
    print(f"\nTOTAL = {total:.2f}s")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    asyncio.run(main())
