import os

from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = r"E:\PowerFocus\marketing\douyin\video_v0120"
OUT = os.path.join(ROOT, "cover.jpg")
LIVE = r"E:\PowerFocus\marketing\v3_live_dark.png"

W, H = 1080, 1440
TXT = (255, 255, 255)
ACCENT = (255, 196, 0)
RED = (255, 62, 62)
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
    gd.ellipse([540 - r, 520 - r, 540 + r, 520 + r], fill=c)
glow = glow.filter(ImageFilter.GaussianBlur(26))
img = glow
d = ImageDraw.Draw(img)

d.rectangle([0, 0, W, 14], fill=ACCENT)

shot = Image.open(LIVE).convert("RGB")
sw, sh = shot.size
card = shot.crop((int(0.05 * sw), int(0.07 * sh), int(0.94 * sw), int(0.42 * sh)))
cw = 800
ch = int(card.height * cw / card.width)
card = card.resize((cw, ch), Image.LANCZOS)
card = card.rotate(-3.5, expand=True, resample=Image.BICUBIC)

shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle([150, 150, 150 + card.width, 150 + card.height], radius=14, fill=(0, 0, 0, 170))
shadow = shadow.filter(ImageFilter.GaussianBlur(22))
img = Image.alpha_composite(img.convert("RGBA"), shadow).convert("RGB")
d = ImageDraw.Draw(img)

d.rounded_rectangle([166, 176, 166 + card.width, 176 + card.height], radius=12, fill=(24, 26, 34))
img.paste(card, (150, 150), card if card.mode == "RGBA" else None)
d = ImageDraw.Draw(img)
d.rounded_rectangle([150, 150, 150 + card.width, 150 + card.height], radius=10, outline=(70, 78, 96), width=3)

d.rounded_rectangle([120, 108, 386, 176], radius=8, fill=ACCENT)
d.text((136, 120), "真实项目记录", font=f(30, True), fill=(20, 14, 0))

y = 560
f1 = f(104, True)
d.text((70, y), "清场不再", font=f1, fill=TXT)

y += 142
f2 = f(150, True)
t = "杀进程"
bbox = d.textbbox((70, y), t, font=f2)
d.rectangle([bbox[0] - 10, bbox[1] + 12, bbox[2] + 12, bbox[3] + 6], fill=ACCENT)
d.text((70, y), t, font=f2, fill=(16, 12, 0))

y += 236
d.text((70, y), "温度落盘 · 真病毒扫描", font=f(64, True), fill=TXT)

d.rectangle([0, H - 208, W, H - 96], fill=(18, 21, 28))
d.text((64, H - 190), "PowerFocus v0.12.0 · 电脑算力调度中心", font=f(34, True), fill=TXT)
d.text((64, H - 140), "开源免费 · GitHub 搜 PowerFocus", font=f(30, False), fill=MUTED)

d.rectangle([0, H - 96, W, H], fill=(11, 13, 18))
d.text((64, H - 74), "2026-11-15 新版发布", font=f(34, True), fill=ACCENT)

d.rounded_rectangle([W - 250, 108, W - 60, 178], radius=34, fill=RED)
d.text((W - 232, 120), "113 测试全过", font=f(30, True), fill=(255, 255, 255))

img.save(OUT, quality=93)
print(OUT, img.size, os.path.getsize(OUT))
