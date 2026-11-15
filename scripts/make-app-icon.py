#!/usr/bin/env python3
"""Renders the app icon into StorageCleaner/Assets.xcassets/AppIcon.appiconset.

Requires Pillow (`pip install pillow`). Run from the repository root: `python3 scripts/make-app-icon.py`.
"""
import json
import os

from PIL import Image, ImageDraw, ImageFilter

OUT = "StorageCleaner/Assets.xcassets/AppIcon.appiconset"
S = 2048  # drawing size; downsampled for anti-aliasing

TOP = (36, 52, 71)
BOTTOM = (20, 30, 43)
ACCENT = (79, 166, 214)
WHITE = (246, 248, 250)


def background(size, rounded):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gradient = Image.new("RGBA", (1, size))
    for y in range(size):
        t = y / (size - 1)
        gradient.putpixel((0, y), tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)) + (255,))
    gradient = gradient.resize((size, size))
    if not rounded:
        return gradient
    # macOS icons carry their own rounded square with a margin.
    inset = int(size * 0.098)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (inset, inset, size - inset, size - inset), radius=int(size * 0.18), fill=255
    )
    img.paste(gradient, (0, 0), mask)
    return img


def glyph(img, scale):
    """Two stacked photo cards; the front one carries a check mark."""
    d = ImageDraw.Draw(img)
    c = S / 2 - 0.012 * S * scale
    w, h = 0.46 * S * scale, 0.36 * S * scale
    r = 0.05 * S * scale
    line = int(0.028 * S * scale)

    # back card
    off = 0.06 * S * scale
    d.rounded_rectangle(
        (c - w / 2 + off, c - h / 2 - off * 1.1, c + w / 2 + off, c + h / 2 - off * 1.1),
        radius=r, outline=WHITE + (110,), width=line,
    )
    # front card
    box = (c - w / 2 - off * 0.4, c - h / 2 + off * 0.4, c + w / 2 - off * 0.4, c + h / 2 + off * 0.4)
    d.rounded_rectangle(box, radius=r, fill=WHITE + (255,))
    # horizon inside the front card
    x0, y0, x1, y1 = box
    pad = 0.07 * S * scale
    d.polygon(
        [(x0 + pad, y1 - pad), (x0 + (x1 - x0) * 0.38, y0 + (y1 - y0) * 0.45),
         (x0 + (x1 - x0) * 0.58, y1 - pad - (y1 - y0) * 0.18), (x0 + (x1 - x0) * 0.72, y0 + (y1 - y0) * 0.55),
         (x1 - pad, y1 - pad)],
        fill=TOP + (255,),
    )
    # check badge
    br = 0.105 * S * scale
    bx, by = x1 - br * 0.25, y1 - br * 0.25
    d.ellipse((bx - br - line * 0.6, by - br - line * 0.6, bx + br + line * 0.6, by + br + line * 0.6), fill=BOTTOM + (255,))
    d.ellipse((bx - br, by - br, bx + br, by + br), fill=ACCENT + (255,))
    k = br * 0.5
    d.line([(bx - k, by + k * 0.05), (bx - k * 0.25, by + k * 0.75), (bx + k * 1.0, by - k * 0.65)],
           fill=WHITE + (255,), width=int(line * 1.25), joint="curve")


def render(rounded):
    img = background(S, rounded)
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    glyph(layer, 0.86 if rounded else 1.0)
    alpha = layer.split()[3].filter(ImageFilter.GaussianBlur(S * 0.012)).point(lambda v: v * 90 // 255)
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", (S, S), (0, 0, 0, 255)), (0, int(S * 0.008)), alpha)
    shadow.putalpha(Image.composite(shadow.split()[3], Image.new("L", (S, S), 0), img.split()[3]))
    img.alpha_composite(shadow)
    img.alpha_composite(layer)
    return img


def main():
    ios = render(rounded=False).convert("RGB").resize((1024, 1024), Image.LANCZOS)
    ios.save(os.path.join(OUT, "AppIcon-iOS-1024.png"))
    mac = render(rounded=True)
    images = [{"filename": "AppIcon-iOS-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}]
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = points * scale
            name = f"AppIcon-mac-{px}.png"
            mac.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
