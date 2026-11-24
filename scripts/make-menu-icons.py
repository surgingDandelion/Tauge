from pathlib import Path

from PIL import Image, ImageChops, ImageOps


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Sources" / "TaugeApp" / "Assets"


def load_tau_mask():
    with Image.open(ROOT / "tauge.png") as artwork:
        # Ignore the tile boundary before isolating the coral and raspberry τ.
        inset_x = round(artwork.width * 0.12)
        inset_y = round(artwork.height * 0.12)
        interior = artwork.crop(
            (inset_x, inset_y, artwork.width - inset_x, artwork.height - inset_y)
        )
        red, green, blue = interior.convert("RGB").split()

    # High red contrast excludes the peach tile. The green/blue contrast
    # separates the red τ from the orange terminal chevron.
    red_mark = ImageChops.subtract(red, green).point(
        lambda value: 255 if value >= 125 else 0
    )
    exclude_chevron = ImageChops.subtract(green, blue).point(
        lambda value: 255 if value <= 45 else 0
    )
    mask = ImageChops.multiply(red_mark, exclude_chevron)
    bounds = mask.getbbox()
    if bounds is None:
        raise ValueError("Could not isolate the D-style τ in tauge.png")
    return mask.crop(bounds)


def main():
    tau = load_tau_mask()
    ASSETS.mkdir(parents=True, exist_ok=True)
    for scale in (1, 2, 3):
        size = 18 * scale
        ink_limit = 16 * scale
        ink = ImageOps.contain(tau, (ink_limit, ink_limit), Image.Resampling.LANCZOS)
        alpha = Image.new("L", (size, size))
        alpha.paste(ink, ((size - ink.width) // 2, (size - ink.height) // 2))

        template = Image.new("RGBA", (size, size))
        template.putalpha(alpha)
        suffix = "" if scale == 1 else f"@{scale}x"
        output = ASSETS / f"MenuIcon{suffix}.png"
        template.save(output)
        print(f"{output.name}: {size}×{size}")


if __name__ == "__main__":
    main()
