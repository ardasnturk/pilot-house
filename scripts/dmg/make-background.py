#!/usr/bin/env python3
"""Draws the DMG window background (660×400 pt, plus @2x) in the 1.1 brand look:
a teal → indigo → violet gradient with soft light, glass tiles behind the
icons, a curved arrow and the three steps after installing.

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
TEAL, INDIGO, VIOLET = (13, 168, 173), (77, 92, 237), (158, 82, 235)
GLOW = (214, 250, 246)
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


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(w, h):
    """Diagonal teal → indigo → violet."""
    image = Image.new("RGB", (w, h))
    pixels = image.load()
    for y in range(h):
        for x in range(w):
            t = (x / w) * 0.7 + (y / h) * 0.3
            pixels[x, y] = lerp(TEAL, INDIGO, t / 0.55) if t < 0.55 else lerp(INDIGO, VIOLET, (t - 0.55) / 0.45)
    return image


def draw(scale):
    w, h = WIDTH * scale, HEIGHT * scale
    image = gradient(w, h)

    # Soft light: a bright blob top left, a pink one bottom right.
    for (cx, cy, r, colour, alpha) in ((90, 40, 220, (255, 255, 255), 70), (600, 380, 240, (238, 92, 158), 90)):
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).ellipse([(cx - r) * scale, (cy - r) * scale, (cx + r) * scale, (cy + r) * scale], fill=alpha)
        mask = mask.filter(ImageFilter.GaussianBlur(70 * scale))
        image = Image.composite(Image.new("RGB", (w, h), colour), image, mask)

    d = ImageDraw.Draw(image, "RGBA")
    # Glass tiles behind the two icons and their labels.
    for cx in (180, 480):
        box = [(cx - 92) * scale, 118 * scale, (cx + 92) * scale, 296 * scale]
        d.rounded_rectangle(box, radius=26 * scale, fill=(255, 255, 255, 52), outline=(255, 255, 255, 90), width=max(1, scale))

    title = "Drag Pilothouse to Applications"
    face = font(26 * scale, 700)
    tw = d.textlength(title, font=face)
    d.text(((w - tw) / 2, 40 * scale), title, font=face, fill=(255, 255, 255, 255))
    sub = "Then open it from Applications: a helm icon appears in the menu bar."
    small = font(13 * scale, 500)
    sw = d.textlength(sub, font=small)
    d.text(((w - sw) / 2, 78 * scale), sub, font=small, fill=(255, 255, 255, 225))

    # Curved, dashed arrow from the app to Applications.
    points = []
    for i in range(41):
        t = i / 40
        x = 284 + (376 - 284) * t
        y = 200 - 34 * 4 * t * (1 - t)
        points.append((x * scale, y * scale))
    for i in range(0, 38, 4):
        d.line(points[i:i + 3], fill=GLOW + (255,), width=5 * scale, joint="curve")
    # Head along the curve's direction at its end.
    import math
    tip = points[-1]
    angle = math.atan2(136, 92)
    length, spread = 18 * scale, 0.5
    left = (tip[0] - length * math.cos(angle - spread), tip[1] - length * math.sin(angle - spread))
    right = (tip[0] - length * math.cos(angle + spread), tip[1] - length * math.sin(angle + spread))
    d.polygon([tip, left, right], fill=GLOW + (255,))

    # The steps after installing, as pills.
    steps = ["1  Drag to Applications", "2  Open Pilothouse", "3  Pair your iPhone"]
    pill = font(12 * scale, 600)
    widths = [d.textlength(text, font=pill) + 28 * scale for text in steps]
    gap = 10 * scale
    x = (w - sum(widths) - gap * (len(steps) - 1)) / 2
    y = (HEIGHT - 66) * scale
    for text, width in zip(steps, widths):
        d.rounded_rectangle([x, y, x + width, y + 28 * scale], radius=14 * scale, fill=(255, 255, 255, 46))
        d.text((x + 14 * scale, y + 7 * scale), text, font=pill, fill=(255, 255, 255, 240))
        x += width + gap

    foot = "Needs Claude Code, Codex or Gemini CLI on this Mac  ·  pilot.ardasnturk.com"
    tiny = font(11 * scale, 450)
    fw = d.textlength(foot, font=tiny)
    d.text(((w - fw) / 2, (HEIGHT - 26) * scale), foot, font=tiny, fill=(255, 255, 255, 180))
    return image


draw(1).save(os.path.join(HERE, "background.png"))
draw(2).save(os.path.join(HERE, "background@2x.png"))
print("background written")
