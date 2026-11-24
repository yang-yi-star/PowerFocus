import json
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = r"E:\PowerFocus\marketing\douyin\video_erecycle_20261118"
FRAMES = os.path.join(ROOT, "frames")

W, H = 1080, 1920
BG = (10, 13, 18)
DARK = (6, 8, 11)
BORDER = (40, 47, 60)
TXT = (240, 243, 248)
MUTED = (136, 148, 166)
ACCENT = (255, 201, 84)
RED = (255, 84, 84)

FONTS = [r"C:\Windows\Fonts\msyhbd.ttc", r"C:\Windows\Fonts\msyh.ttc"]
FONTS_R = [r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\msyhbd.ttc"]

FOOTER = "电脑错误收集中心 · 每条都留证据"


def ff(size, bold=True):
    for p in (FONTS if bold else FONTS_R):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return ImageFont.load_default()


def wrap(d, text, f, maxw):
    lines, cur = [], ""
    for ch in text:
        if d.textlength(cur + ch, font=f) <= maxw:
            cur += ch
        else:
            lines.append(cur)
            cur = ch
    if cur:
        lines.append(cur)
    return lines


def header(d, kicker, title, title_color=TXT):
    d.text((70, 104), kicker, font=ff(28, False), fill=MUTED)
    d.text((70, 152), title, font=ff(46, True), fill=title_color)
    d.line([(70, 236), (W - 70, 236)], fill=(32, 38, 50), width=2)


def quote_card(img, d, lines, center_y=800, label=None, accent_last=True, size=46):
    f = ff(size, True)
    lh = size + 24
    pad_x, pad_y = 52, 46
    max_w = 940
    wrapped = []
    for ln in lines:
        wrapped.extend(wrap(d, ln, f, max_w - pad_x * 2 - 34))
    n = len(wrapped)
    ch = n * lh + pad_y * 2 + (28 if label else 0)
    x0 = (W - max_w) // 2
    y0 = center_y - ch // 2
    d.rectangle([x0, y0, x0 + max_w, y0 + ch], fill=(16, 20, 27))
    d.rectangle([x0, y0, x0 + max_w, y0 + ch], outline=BORDER, width=2)
    d.rectangle([x0, y0, x0 + 9, y0 + ch], fill=ACCENT)
    ty = y0 + pad_y
    if label:
        d.text((x0 + pad_x + 32, ty - 8), label, font=ff(24, False), fill=MUTED)
        ty += 36
    for i, ln in enumerate(wrapped):
        color = ACCENT if (accent_last and i >= n - 1) else TXT
        d.text((x0 + pad_x + 32, ty), ln, font=f, fill=color)
        ty += lh


def takeaway(d, lines, top=1230):
    f = ff(40, True)
    x = 70
    d.rectangle([x, top - 8, x + 8, top + 56 * len(lines) + 6], fill=ACCENT)
    ty = top
    for ln in lines:
        d.text((x + 34, ty), ln, font=f, fill=TXT)
        ty += 56


def big_text(kicker, lines, foot=None, size=88, top=640, hi_last=True, colors=None):
    img = Image.new("RGB", (W, H), DARK)
    d = ImageDraw.Draw(img)
    d.text((70, 300), kicker, font=ff(30, False), fill=MUTED)
    d.line([(70, 360), (W - 70, 360)], fill=(30, 36, 46), width=2)
    ty = top
    for i, ln in enumerate(lines):
        if colors:
            color = colors[i]
        else:
            color = ACCENT if (hi_last and i == len(lines) - 1) else TXT
        d.text((70, ty), ln, font=ff(size, True), fill=color)
        ty += int(size * 1.32)
    if foot:
        d.text((74, ty + 70), foot, font=ff(32, False), fill=MUTED)
    return img


LAYOUT = {
    "s01": dict(style="big", kicker="2026-11-17 晚",
                lines=["E 盘剩", "0.00 GB"],
                foot="两百个 G 的盘 · 两天见底"),
    "s02": dict(kind="quote", kicker="先查是谁在写", title="每 1–3 分钟掉一个权重",
                lines=["E 盘的 tts 目录，", "一个训练脚本在批量产出。", "一个 .pth，585 兆。"],
                label="近三天净写入约 24 GB",
                takeaway=["不是病毒。是我自己跑的。"]),
    "s03": dict(style="big", kicker="第一反应：删",
                lines=["删了 1956 项", "31.55 GB"],
                foot="盘，还是满的"),
    "s04": dict(kind="quote", kicker="删了为什么没用", title="删不是删",
                lines=["文件进了回收站。", "回收站，也在你的盘上。"],
                label="E:\\$RECYCLE.BIN",
                takeaway=["换个文件夹而已，没走。"]),
    "s05": dict(kind="quote", kicker="清空回收站 · 第一招", title="Clear-RecycleBin",
                lines=["没报错。", "零删除。"],
                label="pwsh 7 官方 cmdlet",
                takeaway=["安静地什么都没干。"]),
    "s06": dict(kind="quote", kicker="第二招", title="直接删目录",
                lines=["每个文件回我一行", "Access denied。",
                       "权限表三条 FullControl，", "一条 Deny 都没有。"],
                label="High 完整性 + 完整权限",
                takeaway=["权限没问题。就是不让删。"]),
    "s07": dict(kind="quote", kicker="第三招、第四招", title="cmd 也拒，API 假成功",
                lines=["cmd 的 rd /s /q，一样。",
                       "第四招调 API，返回 S_OK。", "S_OK 就是成功。",
                       "回收站一个字节都没动。"],
                label="SHEmptyRecycleBinW",
                takeaway=["返回成功 ≠ 事情发生了。"]),
    "s08": dict(kind="quote", kicker="我冤枉了谁", title="腾讯电脑管家",
                lines=["我先怀疑它。", "它连进程都没在跑。"],
                label="查过：不是它的锅",
                takeaway=["冤枉了一整轮。"]),
    "s09": dict(kind="quote", kicker="真凶", title="执行环境的保护层",
                lines=["专拦我这个工具进程树。",
                       "就是我干活时伸出去的", "一整串手。", "它按这串手认人。"],
                label="ACL 和提权都拦不住它",
                takeaway=["别的机器我不敢保证也是它。"]),
    "s10": dict(kind="quote", kicker="解法", title="脱离这串手",
                lines=["建一个 SYSTEM 计划任务，", "跑同一条 rd /s /q。", "一次成功。"],
                label="schtasks /ru SYSTEM",
                takeaway=["31.95 GB 回来了。"]),
    "s11": dict(kind="quote", kicker="换来的三件事", title="三条，抄走",
                lines=["删进回收站 ≠ 释放空间。",
                       "API 说成功 ≠ 事情发生。",
                       "动手前先留清单。"],
                label="3732 项，逐项 CSV 留档",
                takeaway=["下一台机器别再踩。"]),
    "s12": dict(style="big", kicker="你也去看一眼",
                lines=["你回收站", "现在多大？"],
                foot="右键 → 属性 · 先看里面有什么，再决定清不清"),
}


def main():
    os.makedirs(FRAMES, exist_ok=True)
    segs = json.load(open(os.path.join(ROOT, "segments.json"), encoding="utf-8"))
    for s in segs:
        sid = s["id"]
        spec = LAYOUT[sid]
        style = spec.get("style")
        if style == "big":
            img = big_text(spec["kicker"], spec["lines"], spec.get("foot"))
        else:
            img = Image.new("RGB", (W, H), BG)
            d = ImageDraw.Draw(img)
            header(d, spec["kicker"], spec["title"])
            quote_card(img, d, spec["lines"], center_y=800,
                       label=spec.get("label"),
                       accent_last=spec.get("accent_last", True), size=46)
            takeaway(d, spec["takeaway"], top=1230)
            d.text((70, 1700), FOOTER, font=ff(22, False), fill=(88, 98, 114))
        out = os.path.join(FRAMES, sid + ".png")
        img.save(out)
        print("frame", sid, img.size, os.path.getsize(out))


if __name__ == "__main__":
    main()
