#!/usr/bin/env python3
# 用抠像后的 Clawd 蟹，生成方形 macOS App 图标（深色圆角底 + 居中珊瑚蟹）→ AppIcon.icns
import os, subprocess
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = "/private/tmp/claude-501/-Users-iu-Desktop-KeepAlive/7e30081c-9ac2-483e-89cf-ee9a20da2ac6/scratchpad"
SIZE = 1024
BG = (0x11, 0x13, 0x17, 255)   # 与真图一致的深色
RADIUS = 224                    # macOS 风格圆角

# 主图
canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
ImageDraw.Draw(canvas).rounded_rectangle([0, 0, SIZE-1, SIZE-1], radius=RADIUS, fill=BG)

crab = Image.open(f"{HERE}/clawd.png").convert("RGBA")   # 抠像蟹（透明底）
tw = int(SIZE * 0.66)
th = int(tw * crab.height / crab.width)
crab_big = crab.resize((tw, th), Image.NEAREST)          # 保留像素块感
canvas.alpha_composite(crab_big, ((SIZE - tw)//2, (SIZE - th)//2))

master = f"{SCRATCH}/appicon_1024.png"
canvas.save(master)
print("master:", master)

# 生成 iconset 各尺寸
iconset = f"{SCRATCH}/Clawd.iconset"
os.makedirs(iconset, exist_ok=True)
for s in (16, 32, 128, 256, 512):
    canvas.resize((s, s), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}.png")
    canvas.resize((s*2, s*2), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}@2x.png")

out = f"{HERE}/AppIcon.icns"
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
print("icns:", out)
