
import os
from PIL import Image, ImageChops, ImageFilter

SRC = "tauge.png"
OUT = "Resources"
os.makedirs(OUT, exist_ok=True)

im = Image.open(SRC).convert("RGB")
W, H = im.size
r, g, b = im.split()
minc = ImageChops.darker(ImageChops.darker(r, g), b)
# 1 = artwork (anything clearly darker than the white backdrop)
white = minc.point(lambda v: 1 if v < 240 else 0).convert("L")
data = white.tobytes()
rows = []
for y in range(H):
    row = data[y * W:(y + 1) * W].translate(bytes([0, 1] + [0] * 254))
    left = row.find(b"\x01")
    right = row.rfind(b"\x01")
    if left < 0:
        rows.append(b"\x00" * W)
    else:
        rows.append(b"\x00" * left + b"\xff" * (right - left + 1) + b"\x00" * (W - right - 1))
alpha = Image.frombytes("L", (W, H), b"".join(rows))
# feather the hard edge slightly so downscaling stays clean
alpha = alpha.filter(ImageFilter.GaussianBlur(1.2))
alpha = alpha.point(lambda v: 0 if v < 40 else (255 if v > 215 else v))

art = im.copy()
art.putalpha(alpha)
bbox = alpha.getbbox()
art = art.crop(bbox)
print("bbox", bbox, "art", art.size)

# macOS icon grid: art occupies 824 of 1024 with 100pt margins
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
body = art.resize((824, 824), Image.LANCZOS)
canvas.paste(body, (100, 100), body)
canvas.save(os.path.join(OUT, "AppIcon-1024.png"))

sizes = [16, 32, 64, 128, 256, 512, 1024]
iconset = ".build/AppIcon.iconset"
os.makedirs(iconset, exist_ok=True)
for s in sizes:
    img = canvas.resize((s, s), Image.LANCZOS)
    img.save(os.path.join(iconset, "icon_%dx%d.png" % (s, s)))
    if s <= 512:
        img2 = canvas.resize((s * 2, s * 2), Image.LANCZOS)
        img2.save(os.path.join(iconset, "icon_%dx%d@2x.png" % (s, s)))
print("iconset ready")

# menu bar glyph: white T + blue prompt -> black template
lum = minc.point(lambda v: 255 if v >= 150 else 0)
blue = ImageChops.subtract(b, r).point(lambda v: 255 if v >= 45 else 0)
glyph = ImageChops.multiply(ImageChops.lighter(lum, blue), alpha)
glyph = glyph.filter(ImageFilter.GaussianBlur(3))
glyph = glyph.point(lambda v: 0 if v < 45 else (255 if v > 170 else v))
gbox = glyph.getbbox()
print("glyph bbox", gbox)
glyph = glyph.crop(gbox)
gw, gh = glyph.size
scale = 34.0 / max(gw, gh)
gw2, gh2 = max(1, round(gw * scale)), max(1, round(gh * scale))
glyph_s = glyph.resize((gw2, gh2), Image.LANCZOS)
for name, size in (("MenuIcon.png", 18), ("MenuIcon@2x.png", 36), ("MenuIcon@3x.png", 54)):
    canvas2 = Image.new("L", (size, size), 0)
    gw3, gh3 = max(1, round(gw * (size - 2) / max(gw, gh))), max(1, round(gh * (size - 2) / max(gw, gh)))
    canvas2.paste(glyph.resize((gw3, gh3), Image.LANCZOS), ((size - gw3) // 2, (size - gh3) // 2))
    rgba = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rgba.putalpha(canvas2)
    rgba.save(os.path.join(OUT, name))
    print(name, size, (gw3, gh3))


# review sheets
prev = Image.new("RGBA", (1024 + 60, 1024), (238, 238, 242, 255))
prev.paste(canvas, (30, 0), canvas)
prev.resize((760, 566), Image.LANCZOS).save(".build/icon-app-preview.png")
mi = Image.open(os.path.join(OUT, "MenuIcon@2x.png"))
sheet = Image.new("RGBA", (420, 300), (20, 22, 28, 255))
sheet.alpha_composite(mi, (24, 28))
sheet.alpha_composite(mi.resize((120, 120), Image.LANCZOS), (90, 24))
light = Image.new("RGBA", (420, 150), (242, 242, 246, 255))
black = Image.new("RGBA", (36, 36), (0, 0, 0, 255))
black.putalpha(mi.getchannel("A"))
light.alpha_composite(black, (24, 24))
black2 = Image.new("RGBA", (120, 120), (0, 0, 0, 255))
black2.putalpha(mi.resize((120, 120), Image.LANCZOS).getchannel("A"))
light.alpha_composite(black2, (90, 20))
sheet.alpha_composite(light, (0, 150))
sheet.resize((840, 600), Image.LANCZOS).save(".build/icon-menu-preview.png")
print("previews ready")
