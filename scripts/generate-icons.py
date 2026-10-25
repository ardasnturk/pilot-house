#!/usr/bin/env python3
"""Draws the Remote Code icon (a terminal prompt with a signal) and writes every asset-catalog image.

Run from the repository root:  python3 scripts/generate-icons.py
Requires Pillow. Output is deterministic, so the PNGs are committed.
"""
import json
import math
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SS = 4  # supersampling factor

TOP = (34, 40, 74)
BOTTOM = (10, 12, 26)
GLYPH = (240, 244, 255)
GLOW = (96, 140, 255)
SIGNAL = (122, 232, 196)


def gradient(size, top, bottom):
    image = Image.new("RGB", (size, size), top)
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / (size - 1)
        color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        draw.line([(0, y), (size, y)], fill=color)
    return image


def draw_prompt(draw, cx, cy, radius, color, signal=None, width_scale=1.0, arcs=True):
    """Terminal prompt `>_` with two signal arcs at the top right."""
    stroke = radius * 0.19 * width_scale
    # Chevron ">".
    left, mid, top = cx - radius * 0.78, cx - radius * 0.12, cy - radius * 0.36
    points = [(left, top), (mid, cy + radius * 0.06), (left, cy + radius * 0.48)]
    draw.line(points, fill=color, width=int(stroke), joint="curve")
    for x, y in (points[0], points[2]):
        draw.ellipse([x - stroke / 2, y - stroke / 2, x + stroke / 2, y + stroke / 2], fill=color)
    # Cursor "_".
    y = cy + radius * 0.48
    x1, x2 = cx + radius * 0.06, cx + radius * 0.72
    draw.rounded_rectangle([x1, y - stroke / 2, x2, y + stroke / 2], stroke / 2, fill=color)
    if not arcs:
        return
    # Signal: a dot and two arcs radiating from it, "reachable from afar".
    sx, sy = cx + radius * 0.30, cy - radius * 0.30
    arc_color = signal or color
    dot = stroke * 0.62
    draw.ellipse([sx - dot, sy - dot, sx + dot, sy + dot], fill=arc_color)
    arc_width = int(stroke * 0.72)
    for r in (radius * 0.36, radius * 0.66):
        draw.arc([sx - r, sy - r, sx + r, sy + r], start=-80, end=-10, fill=arc_color, width=arc_width)


def master(size, dark=False, tinted=False):
    big = size * SS
    if tinted:
        image = Image.new("RGB", (big, big), (0, 0, 0))
        glyph, glow, signal = (255, 255, 255), (150, 150, 150), (200, 200, 200)
    elif dark:
        image = Image.new("RGB", (big, big), (8, 9, 16))
        glyph, glow, signal = (196, 210, 255), GLOW, SIGNAL
    else:
        image = gradient(big, TOP, BOTTOM)
        glyph, glow, signal = GLYPH, GLOW, SIGNAL
    # Soft screen glow behind the prompt.
    halo = Image.new("L", (big, big), 0)
    ImageDraw.Draw(halo).ellipse([big * 0.2, big * 0.25, big * 0.8, big * 0.85], fill=90 if not tinted else 50)
    halo = halo.filter(ImageFilter.GaussianBlur(big * 0.1))
    image = Image.composite(Image.new("RGB", (big, big), glow), image, halo)
    draw = ImageDraw.Draw(image)
    draw_prompt(draw, big / 2, big / 2, big * 0.40, glyph, signal=signal)
    return image.resize((size, size), Image.LANCZOS)


def mac_icon(size):
    """macOS shape: rounded rectangle with margin and a soft shadow."""
    big = size * SS
    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    inset = big * 0.1
    box = [inset, inset, big - inset, big - inset]
    radius = (big - 2 * inset) * 0.225
    shadow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([box[0], box[1] + big * 0.012, box[2], box[3] + big * 0.012], radius, fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(big * 0.012))
    canvas.alpha_composite(shadow)
    face_size = int(box[2] - box[0])
    face = master(face_size // SS, dark=False).resize((face_size, face_size), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (face_size, face_size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, face_size - 1, face_size - 1], radius, fill=255)
    canvas.paste(face, (int(box[0]), int(box[1])), mask)
    return canvas.resize((size, size), Image.LANCZOS)


def template_glyph(points, badge=False):
    big = points * SS * 2
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    # The badge takes the place of the signal arcs.
    draw_prompt(draw, big / 2, big / 2, big * 0.5, (0, 0, 0, 255), width_scale=1.15, arcs=not badge)
    if badge:
        r = big * 0.17
        draw.ellipse([big - 2 * r, 0, big, 2 * r], fill=(0, 0, 0, 255))
    return image


def write_contents(path, contents):
    with open(os.path.join(path, "Contents.json"), "w") as handle:
        json.dump(contents, handle, indent=2)
        handle.write("\n")


def ios_assets(base):
    icon = os.path.join(base, "AppIcon.appiconset")
    os.makedirs(icon, exist_ok=True)
    master(1024).save(os.path.join(icon, "AppIcon.png"))
    master(1024, dark=True).save(os.path.join(icon, "AppIcon-Dark.png"))
    master(1024, tinted=True).convert("L").save(os.path.join(icon, "AppIcon-Tinted.png"))
    write_contents(icon, {
        "images": [
            {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "AppIcon-Dark.png",
             "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "AppIcon-Tinted.png",
             "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ],
        "info": {"author": "xcode", "version": 1},
    })
    brand = os.path.join(base, "BrandMark.imageset")
    os.makedirs(brand, exist_ok=True)
    mark = Image.new("RGBA", (360, 360), (0, 0, 0, 0))
    draw_prompt(ImageDraw.Draw(mark), 180, 180, 170, (0, 0, 0, 255))
    mark.save(os.path.join(brand, "BrandMark.png"))
    write_contents(brand, {
        "images": [{"filename": "BrandMark.png", "idiom": "universal", "scale": "3x"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"template-rendering-intent": "template"},
    })


def mac_assets(base):
    icon = os.path.join(base, "AppIcon.appiconset")
    os.makedirs(icon, exist_ok=True)
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            mac_icon(pixels).save(os.path.join(icon, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    write_contents(icon, {"images": images, "info": {"author": "xcode", "version": 1}})
    for name, badge in (("MenuBarIcon", False), ("MenuBarIconBadge", True)):
        folder = os.path.join(base, f"{name}.imageset")
        os.makedirs(folder, exist_ok=True)
        entries = []
        for scale in (1, 2):
            glyph = template_glyph(18, badge).resize((18 * scale, 18 * scale), Image.LANCZOS)
            filename = f"{name}{'@2x' if scale == 2 else ''}.png"
            glyph.save(os.path.join(folder, filename))
            entries.append({"filename": filename, "idiom": "mac", "scale": f"{scale}x"})
        write_contents(folder, {
            "images": entries,
            "info": {"author": "xcode", "version": 1},
            "properties": {"template-rendering-intent": "template"},
        })


def accent(base, light, dark):
    folder = os.path.join(base, "AccentColor.colorset")
    os.makedirs(folder, exist_ok=True)

    def component(rgb):
        return {"color-space": "srgb", "components": {
            "alpha": "1.000", "red": f"{rgb[0] / 255:.3f}", "green": f"{rgb[1] / 255:.3f}", "blue": f"{rgb[2] / 255:.3f}"}}

    write_contents(folder, {
        "colors": [
            {"color": component(light), "idiom": "universal"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}], "color": component(dark), "idiom": "universal"},
        ],
        "info": {"author": "xcode", "version": 1},
    })


def catalog(path):
    os.makedirs(path, exist_ok=True)
    write_contents(path, {"info": {"author": "xcode", "version": 1}})
    return path


if __name__ == "__main__":
    mac = catalog(os.path.join(ROOT, "PilothouseMac/Resources/Assets.xcassets"))
    ios = catalog(os.path.join(ROOT, "PilothouseiOS/Resources/Assets.xcassets"))
    mac_assets(mac)
    ios_assets(ios)
    for base in (mac, ios):
        accent(base, (14, 128, 140), (72, 202, 208))
    master(1024).save(os.path.join(ROOT, "docs/icon.png"))
    print("Icons written.")
