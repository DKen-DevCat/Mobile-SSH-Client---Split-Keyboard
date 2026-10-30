#!/usr/bin/env python3
"""アプリのアイコン（1024px）を作る。左右の分割キーボードの間にプロンプト。
使い方: python3 scripts/gen_icon.py  （Pillow が要る）"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ios/SplitTerm/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

BG = (7, 9, 13)
KEY = (33, 38, 45)
ACCENT = (47, 129, 247)
GREEN = (63, 224, 138)
S = 1024

img = Image.new("RGB", (S, S), BG)
d = ImageDraw.Draw(img)
# 左右のキーボード（3 段 × 3 列のキー）
for side in (0, 1):
    x0 = 70 if side == 0 else S - 70 - 250
    for r in range(3):
        for c in range(3):
            x = x0 + c * 86
            y = 470 + r * 120
            color = ACCENT if (side == 1 and r == 2 and c == 2) else KEY
            d.rounded_rectangle([x, y, x + 74, y + 104], radius=16, fill=color)
# 中央のプロンプト
font = None
for name in ("DejaVuSansMono-Bold.ttf", "DejaVuSansMono.ttf", "Menlo.ttc"):
    try:
        font = ImageFont.truetype(name, 230)
        break
    except OSError:
        pass
font = font or ImageFont.load_default()
d.text((S / 2, 300), ">_", font=font, fill=GREEN, anchor="mm")
OUT.parent.mkdir(parents=True, exist_ok=True)
img.save(OUT)
print(OUT)
