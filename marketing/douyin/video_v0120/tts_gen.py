import asyncio
import json
import os
import subprocess
import sys

import edge_tts

VOICE = "zh-CN-YunxiaNeural"
RATE = "+16%"
ROOT = r"E:\PowerFocus\marketing\douyin\video_v0120"
TTS_DIR = os.path.join(ROOT, "tts")

SEGMENTS = [
    ("s01", "我的开源软件 PowerFocus，今天发新版了，v0.12.0。这条视频讲清楚，这次到底改了什么。"),
    ("s02", "先说一句，它不是演示。桌面 exe 和 MCP 插件，都已经挂在 GitHub Release 上，直接就能下。"),
    ("s03", "最实用的一条：温度真的落盘了。CPU、GPU 温度按天记成日志，峰值也留着。"),
    ("s04", "测不到，就老实说测不到。GPU 拿不到就退回 nvidia-smi，CPU 实在拿不到，就留空，不给你编一个数。"),
    ("s05", "第二条，病毒扫描做成了真接口。点一下，后台真扫，进度和结果都能查。"),
    ("s06", "但要处置威胁，必须你显式确认。不确认，它只报告，绝不动你的文件。"),
    ("s07", "第三条，清场再也不杀进程了。只降优先级、开 EcoQoS、把工作集换出去，松开手就完整还原。"),
    ("s08", "你声明一句，这个软件我正在用，它和它的子进程，整组都不动。"),
    ("s09", "还修了一个我自己都没察觉的 bug。以前打包，exe 里塞的是旧组件。现在跟着版本指针走，指到哪就装哪。"),
    ("s10", "113 个测试全过，ruff 零错误。GitHub 搜 PowerFocus，开源免费，直接下。"),
    ("s11", "PowerFocus，电脑算力调度中心。"),
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
