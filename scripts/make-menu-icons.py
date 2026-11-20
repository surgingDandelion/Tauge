
import os
from PIL import Image, ImageChops, ImageFilter, ImageDraw

os.makedirs("Sources/TaugeApp/Assets", exist_ok=True)
letters = Image.open(".build/letters.png").convert("L")
t_only = letters.crop((0, 0, 840, letters.size[1]))
t_only = t_only.crop(t_only.getbbox())

MASTER = 864
sq = Image.new("L", (MASTER, MASTER), 0)
ImageDraw.Draw(sq).rounded_rectangle((0, 0, MASTER - 1, MASTER - 1), radius=int(MASTER * 0.228), fill=255)

def place(img, size, pad):
    w, h = img.size
    scale = (size - 2 * pad) / max(w, h)
    w2, h2 = max(1, round(w * scale)), max(1, round(h * scale))
    out = Image.new("L", (size, size), 0)
    out.paste(img.resize((w2, h2), Image.LANCZOS), ((size - w2) // 2, (size - h2) // 2))
    return out

ink = ImageChops.subtract(sq, place(t_only, MASTER, pad=int(MASTER * 0.115)))
for name, size in (("MenuIcon", 18), ("MenuIcon@2x", 36), ("MenuIcon@3x", 54)):
    small = ink.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.putalpha(small)
    out.save("Sources/TaugeApp/Assets/%s.png" % name)
    print(name, size)

preview = Image.new("RGBA", (420, 120), (26, 28, 34, 255))
for i, s in enumerate((18, 36, 54)):
    icon = Image.open("Sources/TaugeApp/Assets/%s.png" % ("MenuIcon" if s == 18 else "MenuIcon@%dx" % (s // 18)))
    preview.alpha_composite(icon.convert("RGBA"), (20 + i * 70, 33))
preview.resize((840, 240), Image.LANCZOS).save(".build/menu-final.png")
print("ok")
