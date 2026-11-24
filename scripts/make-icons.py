
import os
import subprocess
from PIL import Image, ImageChops, ImageFilter, ImageOps

SRC = "tauge.png"
OUT = "Resources"
os.makedirs(OUT, exist_ok=True)

source = Image.open(SRC)
has_alpha = "A" in source.getbands() or "transparency" in source.info
art = source.convert("RGBA")
if has_alpha:
    # Remove faint background pixels and make the tile interior opaque.
    # Keep intermediate values for the antialiased outline.
    alpha = art.getchannel("A").point(lambda value: 0 if value <= 15 else (255 if value >= 247 else value))
else:
    width, height = source.size
    r, g, b = source.convert("RGB").split()
    minc = ImageChops.darker(ImageChops.darker(r, g), b)
    # Legacy source artwork is flattened against a white backdrop.
    data = minc.point(lambda value: 1 if value < 240 else 0).tobytes()
    rows = []
    for y in range(height):
        row = data[y * width:(y + 1) * width]
        left = row.find(b"\x01")
        right = row.rfind(b"\x01")
        if left < 0:
            rows.append(b"\x00" * width)
        else:
            rows.append(b"\x00" * left + b"\xff" * (right - left + 1) + b"\x00" * (width - right - 1))
    alpha = Image.frombytes("L", (width, height), b"".join(rows))
    alpha = alpha.filter(ImageFilter.GaussianBlur(1.2))
    alpha = alpha.point(lambda value: 0 if value < 40 else (255 if value > 215 else value))

bbox = alpha.getbbox()
if bbox is None:
    raise SystemExit(f"{SRC} has no visible artwork")
art.putalpha(alpha)

# Keep the artwork centered on the 824-pixel macOS icon grid.
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
body = ImageOps.contain(art.crop(bbox), (824, 824), Image.LANCZOS)
canvas.alpha_composite(body, ((canvas.width - body.width) // 2, (canvas.height - body.height) // 2))
canvas.save(os.path.join(OUT, "AppIcon-1024.png"))

iconset = ".build/AppIcon.iconset"
os.makedirs(iconset, exist_ok=True)
for size in (16, 32, 128, 256, 512):
    canvas.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
    canvas.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
subprocess.run(["iconutil", "-c", "icns", "-o", os.path.join(OUT, "AppIcon.icns"), iconset], check=True)

preview = Image.new("RGBA", (1024, 1024), (238, 238, 242, 255))
preview.alpha_composite(canvas)
preview.resize((760, 760), Image.LANCZOS).save(".build/icon-app-preview.png")
print("app icons ready")

if has_alpha:
    raise SystemExit(0)

# Preview the menu glyph for the legacy dark artwork only.
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
