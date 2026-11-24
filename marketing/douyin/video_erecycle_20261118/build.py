import json
import os
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = r"E:\PowerFocus\marketing\douyin\video_erecycle_20261118"
FRAMES = os.path.join(ROOT, "frames")
TTS = os.path.join(ROOT, "tts")
BGM = r"E:\PowerFocus\marketing\douyin\video_hy4\bgm.wav"
CLIPS = os.path.join(ROOT, "clips")
ASS_PATH = os.path.join(ROOT, "subs.ass")
FINAL_NAME = "电脑错误收集中心_E盘回收站_成片.mp4"

FPS = 25
GAP = 0.25


def ts(x):
    h = int(x // 3600)
    m = int((x % 3600) // 60)
    s = x % 60
    return f"{h}:{m:02d}:{s:05.2f}"


def split_line(t, maxlen=15):
    parts = re.split(r"(?<=[，。：；、！？])", t)
    parts = [p for p in parts if p.strip()]
    out, cur = [], ""
    for p in parts:
        if len(cur) + len(p) <= maxlen:
            cur += p
        else:
            if cur:
                out.append(cur)
            cur = p
    if cur:
        out.append(cur)
    final = []
    for l in out:
        while len(l) > maxlen * 1.8:
            final.append(l[:maxlen])
            l = l[maxlen:]
        final.append(l)
    return [x for x in final if x.strip()]


def build_ass(segs):
    head = """[Script Info]
ScriptType: v4.00+
PlayResX: 1080
PlayResY: 1920
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Def,Microsoft YaHei,54,&H00FFFFFF,&H00FFFFFF,&H00000000,&H78000000,-1,0,0,0,100,100,1,0,1,5,3,2,70,70,378,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
    lines = []
    t = 0.0
    for seg in segs:
        dur = seg["dur"]
        chunks = split_line(seg["text"])
        total = sum(len(c) for c in chunks) or 1
        t0 = t
        for c in chunks:
            d = dur * len(c) / total
            txt = c.replace("{", "｛").replace("}", "｝")
            lines.append(f"Dialogue: 0,{ts(t0)},{ts(t0 + d)},Def,,0,0,0,,{txt}")
            t0 += d
        t += dur + GAP
    with open(ASS_PATH, "w", encoding="utf-8") as f:
        f.write(head + "\n".join(lines) + "\n")
    return t


def run(cmd, tag):
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        print("FAIL", tag)
        print((r.stderr or "")[-1200:])
        sys.exit(1)


def main():
    os.makedirs(CLIPS, exist_ok=True)
    segs = json.load(open(os.path.join(ROOT, "segments.json"), encoding="utf-8"))
    total = build_ass(segs)
    print(f"ASS 完成，总长 {total:.2f}s")

    listing = []
    for seg in segs:
        sid = seg["id"]
        dur = seg["dur"] + GAP
        n = max(1, int(round(dur * FPS)))
        frame = os.path.join(FRAMES, sid + ".png")
        audio = os.path.join(TTS, sid + ".mp3")
        out = os.path.join(CLIPS, sid + ".mp4")
        vf = (
            f"zoompan=z='min(1+0.095*on/{n},1.10)':"
            f"x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=1:s=1080x1920:fps={FPS}"
        )
        cmd = [
            "ffmpeg", "-y", "-loop", "1", "-framerate", str(FPS), "-i", frame,
            "-i", audio,
            "-t", f"{dur:.3f}",
            "-vf", vf,
            "-af", f"apad=pad_dur={GAP},aresample=44100",
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "19", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-ac", "2",
            "-shortest", "-movflags", "+faststart",
            out,
        ]
        run(cmd, sid)
        print("clip", sid, f"{dur:.2f}s", os.path.getsize(out))
        listing.append(f"file '{out.replace(os.sep, '/')}'")

    listfile = os.path.join(CLIPS, "list.txt")
    with open(listfile, "w", encoding="utf-8") as f:
        f.write("\n".join(listing) + "\n")

    raw = os.path.join(ROOT, "raw.mp4")
    run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", listfile,
         "-c", "copy", raw], "concat")
    print("concat ok", os.path.getsize(raw))

    fade_out = max(10, int(total) - 6)
    final = os.path.join(ROOT, FINAL_NAME)
    cmd = [
        "ffmpeg", "-y", "-i", raw, "-i", BGM,
        "-filter_complex",
        "[0:a]volume=1.0[a0];"
        "[1:a]aresample=44100,volume=0.16,afade=t=in:st=0:d=2,afade=t=out:st=" + str(fade_out) + ":d=5[a1];"
        "[a0][a1]amix=inputs=2:duration=first:dropout_transition=2,"
        "loudnorm=I=-14:TP=-1.5:LRA=11[aout]",
        "-map", "0:v", "-map", "[aout]",
        "-vf", "ass=subs.ass",
        "-c:v", "libx264", "-preset", "medium", "-crf", "19", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "192k",
        "-movflags", "+faststart",
        final,
    ]
    run(cmd, "final")
    print("FINAL", final, os.path.getsize(final))


if __name__ == "__main__":
    main()
