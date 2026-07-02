#!/usr/bin/env python3
# 直接用真图：把深色圆角背景抠成透明，保留珊瑚蟹身 + 黑眼。菜单栏友好版。
from PIL import Image

SRC = "/Users/iu/.claude/image-cache/7e30081c-9ac2-483e-89cf-ee9a20da2ac6/3.png"
OUT = "/private/tmp/claude-501/-Users-iu-Desktop-KeepAlive/7e30081c-9ac2-483e-89cf-ee9a20da2ac6/scratchpad"
DEST = "/Users/iu/Desktop/KeepAlive/assets"

im = Image.open(SRC).convert("RGBA")
W, H = im.size
px = im.load()

CORAL = (0xdd, 0x5b, 0x3e)
BG    = (0x11, 0x13, 0x17)
BLACK = (0, 0, 0)
def dist(a, b): return sum((a[i]-b[i])**2 for i in range(3))

keyed = Image.new("RGBA", (W, H), (0, 0, 0, 0))
kp = keyed.load()
for y in range(H):
    for x in range(W):
        r, g, b, a = px[x, y]
        if a < 128:
            continue  # 原本透明
        dc, db, dk = dist((r,g,b),CORAL), dist((r,g,b),BG), dist((r,g,b),BLACK)
        m = min(dc, db, dk)
        if m == db:
            continue                       # 背景 → 透明
        elif m == dk:
            kp[x, y] = (0, 0, 0, 255)       # 眼 → 黑
        else:
            kp[x, y] = (0xdd, 0x5b, 0x3e, 255)  # 蟹身 → 珊瑚

# 裁掉透明边（让图标更饱满）
bbox = keyed.getbbox()
keyed = keyed.crop(bbox)
print("cropped to", keyed.size)

# 存资源（原生高分，菜单栏会缩放）
keyed.save(f"{DEST}/clawd.png")
print("saved", f"{DEST}/clawd.png")

# 也存一份带深色背景的“徽章版”备用
im.save(f"{DEST}/clawd_badge.png")

# 预览：把抠像结果分别叠在浅色和深色底上，方便肉眼看
def composite(bg):
    base = Image.new("RGBA", keyed.size, bg)
    base.alpha_composite(keyed)
    return base.resize((keyed.width*4, keyed.height*4), Image.NEAREST)
light = composite((235,235,235,255))
dark  = composite((30,30,30,255))
combo = Image.new("RGBA", (light.width, light.height*2+8), (255,255,255,255))
combo.paste(light, (0,0)); combo.paste(dark, (0, light.height+8))
combo.save(f"{OUT}/clawd_keyed_preview.png")
print("preview", f"{OUT}/clawd_keyed_preview.png")
