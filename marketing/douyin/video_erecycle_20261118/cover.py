import os

from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = r"E:\PowerFocus\marketing\douyin\video_erecycle_20261118"
OUT = os.path.join(ROOT, "cover.jpg")

W, H = 1080, 1440
TXT = (255, 255, 255)
ACCENT = (255, 201, 84)
RED = (240, 68, 68)
MUTED = (168, 178, 194)

FB = r"C:\Windows\Fonts\msyhbd.ttc"
FR = r"C:\Windows\Fonts\msyh.ttc"


def f(size, bold=True):
    try:
        return ImageFont.truetype(FB if bold else FR, size)
    except Exception:
        return ImageFont.load_default()


img = Image.new("RGB", (W, H), (6, 7, 12))

glow = Image.new("RGB", (W, H), (6, 7, 12))
gd = ImageDraw.Draw(glow)
for r in range(760, 0, -24):
    k = 1 - r / 760
    c = (int(6 + 34 * k), int(7 + 30 * k), int(12 + 46 * k))
    gd.ellipse([540 - r, 620 - r, 540 + r, 620 + r], fill=c)
glow = glow.filter(ImageFilter.GaussianBlur(26))
img = glow
d = ImageDraw.Draw(img)

d.rectangle([0, 0, W, 14], fill=ACCENT)

d.rounded_rectangle([70, 92, 366, 160], radius=8, fill=ACCENT)
d.text((88, 105), "真实排错记录", font=f(30, True), fill=(20, 14, 0))

d.rounded_rectangle([W - 300, 92, W - 60, 160], radius=34, fill=RED)
d.text((W - 282, 105), "0.00 GB", font=f(32, True), fill=(255, 255, 255))

y = 560
f1 = f(96, True)
d.text((70, y), "删了 31G", font=f1, fill=TXT)

y += 140
f2 = f(132, True)
t = "盘还是满的"
bbox = d.textbbox((70, y), t, font=f2)
d.rectangle([bbox[0] - 8, bbox[1] + 12, bbox[2] + 10, bbox[3] + 4], fill=ACCENT)
d.text((70, y), t, font=f2, fill=(16, 12, 0))

y += 216
d.text((70, y), "四条清空路全失败", font=f(62, True), fill=TXT)
y += 92
d.text((70, y), "SYSTEM 计划任务，一次清掉 31.95 GB", font=f(36, False), fill=MUTED)

d.rectangle([0, H - 208, W, H - 96], fill=(18, 21, 28))
d.text((64, H - 190), "电脑错误收集中心 · 2026-11-18", font=f(34, True), fill=TXT)
d.text((64, H - 140), "每条都留证据 · GitHub 搜 ai-failure-fix-notes", font=f(30, False), fill=MUTED)

d.rectangle([0, H - 96, W, H], fill=(11, 13, 18))
d.text((64, H - 74), "删不是删，删是搬家", font=f(34, True), fill=ACCENT)

img.save(OUT, quality=93)
print(OUT, img.size, os.path.getsize(OUT))
