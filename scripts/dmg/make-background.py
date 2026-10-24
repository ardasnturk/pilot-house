#!/usr/bin/env python3
"""Draws the DMG window background (660×400 pt, plus @2x) in the icon's colours.

    python3 scripts/dmg/make-background.py

Writes scripts/dmg/background.png and background@2x.png. Finder draws the file
names itself (black in light mode, white in dark mode), so the background is a
mid-tone teal on which both stay readable. Icon centres: app (180, 200),
Applications (480, 200) — keep them in sync with scripts/dmg/settings.py.
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
WIDTH, HEIGHT = 660, 400
TOP, BOTTOM = (64, 138, 148), (40, 104, 116)
GLOW = (178, 240, 232)
FONT = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight):
    face = ImageFont.truetype(FONT, size)
    try:
        # Set only the weight; keep every other axis (width, optical size) at its default.
        axes = face.get_variation_axes()
        values = [weight if str(axis.get("name", b"")).lower().find("weight") >= 0 else axis["default"] for axis in axes]
        face.set_variation_by_axes(values)
    except Exception:
        pass
    return face


def draw(scale):
    w, h = WIDTH * scale, HEIGHT * scale
    image = Image.new("RGB", (w, h))
    pixels = image.load()
    for y in range(h):
        t = y / (h - 1)
        row = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
        for x in range(w):
            pixels[x, y] = row

    # Soft light behind each icon.
    halo = Image.new("L", (w, h), 0)
    hd = ImageDraw.Draw(halo)
    for cx in (180, 480):
        r = 92 * scale
        hd.ellipse([cx * scale - r, 200 * scale - r, cx * scale + r, 200 * scale + r], fill=46)
    halo = halo.filter(ImageFilter.GaussianBlur(40 * scale))
    image = Image.composite(Image.new("RGB", (w, h), (255, 255, 255)), image, halo)

    d = ImageDraw.Draw(image, "RGBA")
    title = "Drag Pilothouse to Applications"
    face = font(26 * scale, 650)
    tw = d.textlength(title, font=face)
    d.text(((w - tw) / 2, 44 * scale), title, font=face, fill=(255, 255, 255, 255))
    sub = "Then open it from Applications — the helm appears in the menu bar."
    small = font(13 * scale, 450)
    sw = d.textlength(sub, font=small)
    d.text(((w - sw) / 2, 84 * scale), sub, font=small, fill=(255, 255, 255, 215))

    # Arrow from the app to Applications.
    y = 196 * scale
    x0, x1 = 262 * scale, 392 * scale
    stroke = 6 * scale
    d.line([(x0, y), (x1 - 14 * scale, y)], fill=GLOW + (255,), width=stroke)
    head = [(x1, y), (x1 - 22 * scale, y - 15 * scale), (x1 - 22 * scale, y + 15 * scale)]
    d.polygon(head, fill=GLOW + (255,))
    for dot in range(3):
        cx = x0 - (18 + dot * 14) * scale
        r = (3 - dot * 0.6) * scale
        d.ellipse([cx - r, y - r, cx + r, y + r], fill=GLOW + (200 - dot * 50,))

    foot = "Needs Claude Code, Codex or Gemini CLI on this Mac  ·  pilot.ardasnturk.com"
    tiny = font(11 * scale, 450)
    fw = d.textlength(foot, font=tiny)
    d.text(((w - fw) / 2, (HEIGHT - 34) * scale), foot, font=tiny, fill=(255, 255, 255, 170))
    return image


draw(1).save(os.path.join(HERE, "background.png"))
draw(2).save(os.path.join(HERE, "background@2x.png"))
print("background written")
