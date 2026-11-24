import json
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = r"E:\PowerFocus\marketing\douyin\video_v0120"
FRAMES = os.path.join(ROOT, "frames")
LIVE = r"E:\PowerFocus\marketing\v3_live_dark.png"

W, H = 1080, 1920
BG = (10, 13, 18)
DARK = (6, 8, 11)
BORDER = (40, 47, 60)
TXT = (240, 243, 248)
MUTED = (136, 148, 166)
ACCENT = (255, 201, 84)

FONTS = [r"C:\Windows\Fonts\msyhbd.ttc", r"C:\Windows\Fonts\msyh.ttc"]
FONTS_R = [r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\msyhbd.ttc"]


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


def header(d, kicker, title):
    d.text((70, 104), kicker, font=ff(28, False), fill=MUTED)
    d.text((70, 152), title, font=ff(46, True), fill=TXT)
    d.line([(70, 236), (W - 70, 236)], fill=(32, 38, 50), width=2)


def shot_card(img, d, src, crop, center_y=740, label=None, max_h=560):
    im = Image.open(src).convert("RGB")
    ow, oh = im.size
    x0, y0, x1, y1 = crop
    im = im.crop((int(x0 * ow), int(y0 * oh), int(x1 * ow), int(y1 * oh)))
    scale = min(940 / im.width, max_h / im.height)
    nw, nh = max(1, int(im.width * scale)), max(1, int(im.height * scale))
    disp = im.resize((nw, nh), Image.LANCZOS)
    x = (W - nw) // 2
    y = center_y - nh // 2
    d.rectangle([x - 16, y - 16, x + nw + 15, y + nh + 15], fill=(15, 19, 26))
    img.paste(disp, (x, y))
    d.rectangle([x - 1, y - 1, x + nw, y + nh], outline=BORDER, width=2)
    if label:
        f = ff(26, False)
        tw = d.textlength(label, font=f)
        d.rounded_rectangle([x - 16, y - 62, x - 16 + tw + 34, y - 16], radius=10, fill=(24, 30, 40))
        d.text((x + 1, y - 54), label, font=f, fill=MUTED)


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


def big_text(kicker, lines, foot=None, size=88, top=700, hi_last=True):
    img = Image.new("RGB", (W, H), DARK)
    d = ImageDraw.Draw(img)
    d.text((70, 300), kicker, font=ff(30, False), fill=MUTED)
    d.line([(70, 360), (W - 70, 360)], fill=(30, 36, 46), width=2)
    ty = top
    for i, ln in enumerate(lines):
        color = ACCENT if (hi_last and i == len(lines) - 1) else TXT
        d.text((70, ty), ln, font=ff(size, True), fill=color)
        ty += int(size * 1.32)
    if foot:
        d.text((74, ty + 70), foot, font=ff(32, False), fill=MUTED)
    return img


LAYOUT = {
    "s01": dict(style="big", kicker="一个真实的项目记录",
                lines=["我的开源软件", "发新版了"],
                foot="PowerFocus v0.12.0 · 2026-11-15"),
    "s02": dict(kind="shot", src=LIVE, crop=(0.05, 0.04, 0.95, 0.50),
                kicker="不是演示", title="exe 和 MCP 都已挂上 Release",
                label="PowerFocus 总览",
                takeaway=["GitHub Release 直接下载，", "桌面 exe + MCP 插件都有。"]),
    "s03": dict(kind="quote", kicker="这次最实用的", title="温度真的落盘了",
                lines=["CPU、GPU 温度", "按天记成日志，", "历史峰值也留着。"],
                label="新增 /api/temp", accent_last=True,
                takeaway=["不是看一眼就完，是留下来。"]),
    "s04": dict(kind="quote", kicker="一条底线", title="测不到就说测不到",
                lines=["GPU 拿不到，退回 nvidia-smi；", "CPU 实在拿不到，就留空。",
                       "不给你编一个数。"],
                label="不填假值", accent_last=True,
                takeaway=["工具可以笨，但不能骗你。"]),
    "s05": dict(kind="quote", kicker="第二条", title="病毒扫描做成真接口",
                lines=["点一下，后台真扫。", "进度和结果，都能查到。"],
                label="/api/security/scan", accent_last=True,
                takeaway=["真扫，不是动画。"]),
    "s06": dict(kind="quote", kicker="但有一条线", title="处置必须你点头",
                lines=["要处置威胁，", "必须你显式确认。", "不确认，只报告。"],
                label="disinfect_confirm=yes", accent_last=True,
                takeaway=["绝不替你动文件。"]),
    "s07": dict(kind="quote", kicker="第三条，最重要", title="清场再也不杀进程",
                lines=["只降优先级、开 EcoQoS、", "把工作集换出去。",
                       "松开手，完整还原。"],
                label="内核 v0.12 / v0.13", accent_last=True,
                takeaway=["释放内存，不再靠杀。"]),
    "s08": dict(kind="quote", kicker="你来告诉它", title="「这个我正在用」",
                lines=["你声明一句在用，", "它和它的子进程，", "整组都不动。"],
                label="companion-apps.json", accent_last=True,
                takeaway=["判断交给最清楚的人：你。"]),
    "s09": dict(kind="quote", kicker="顺手修了个 bug", title="exe 里曾塞的是旧组件",
                lines=["以前打包写死版本目录，", "新内核配旧组件。",
                       "现在跟着版本指针走。"],
                label="打包组件错位", accent_last=True,
                takeaway=["指到哪，就装哪。"]),
    "s10": dict(style="big", kicker="在哪下",
                lines=["GitHub 搜", "PowerFocus"],
                foot="113 测试全过 · ruff 0 错误 · Apache-2.0"),
    "s11": dict(style="end"),
}


def build_end():
    img = Image.new("RGB", (W, H), DARK)
    d = ImageDraw.Draw(img)
    d.text((70, 700), "PowerFocus", font=ff(112, True), fill=TXT)
    d.text((70, 858), "电脑算力调度中心", font=ff(84, True), fill=ACCENT)
    d.line([(74, 1044), (520, 1044)], fill=(40, 46, 58), width=2)
    d.text((74, 1088), "v0.12.0 · 2026-11-15 发布", font=ff(34, False), fill=MUTED)
    d.text((74, 1140), "开源免费 · GitHub 可下载", font=ff(34, False), fill=MUTED)
    d.text((74, 1256), "#PowerFocus  #开源  #Windows", font=ff(32, False), fill=MUTED)
    return img


def main():
    os.makedirs(FRAMES, exist_ok=True)
    segs = json.load(open(os.path.join(ROOT, "segments.json"), encoding="utf-8"))
    for s in segs:
        sid = s["id"]
        spec = LAYOUT[sid]
        style = spec.get("style")
        if style == "big":
            img = big_text(spec["kicker"], spec["lines"], spec.get("foot"))
        elif style == "end":
            img = build_end()
        else:
            img = Image.new("RGB", (W, H), BG)
            d = ImageDraw.Draw(img)
            header(d, spec["kicker"], spec["title"])
            if spec["kind"] == "shot":
                shot_card(img, d, spec["src"], spec["crop"], center_y=740,
                          label=spec.get("label"), max_h=spec.get("max_h", 560))
            else:
                quote_card(img, d, spec["lines"], center_y=800,
                           label=spec.get("label"),
                           accent_last=spec.get("accent_last", True), size=46)
            takeaway(d, spec["takeaway"], top=1230)
            d.text((70, 1700), "PowerFocus 为开源项目，GitHub 可下载", font=ff(22, False), fill=(88, 98, 114))
        out = os.path.join(FRAMES, sid + ".png")
        img.save(out)
        print("frame", sid, img.size, os.path.getsize(out))


if __name__ == "__main__":
    main()
