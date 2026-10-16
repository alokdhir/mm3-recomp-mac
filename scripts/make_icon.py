#!/usr/bin/env python3
"""Draw the app icon: a city skyline at dusk over a road running to the
horizon, in the macOS icon shape, with "MM3" in blocky outlined letters
leaning forward. Original art: no game or publisher artwork.

    .venv-upscale/bin/python scripts/make_icon.py      # needs Pillow
    -> mac/bundle/AppIcon.icns (via iconutil)
"""
import math
import os
import random
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'mac', 'bundle', 'AppIcon.icns')
S = 2048                    # drawn at 2x, then reduced
BOX = int(S * 824 / 1024)   # the icon grid's rounded square
M = (S - BOX) // 2


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def squircle_mask():
    """The macOS icon outline: a rounded square, corners 22.5% of its side."""
    m = Image.new('L', (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle([M, M, M + BOX, M + BOX], radius=int(BOX * 0.225), fill=255)
    return m


FONT = '/System/Library/Fonts/Supplemental/Impact.ttf'


def title(top):
    """MM3: a yellow-to-orange fill in a thick dark outline, a thin light
    rim outside that, sheared forward like italics, with a soft shadow."""
    font = ImageFont.truetype(FONT, int(BOX * 0.31))
    text, stroke = 'MM3', int(BOX * 0.028)
    probe = ImageDraw.Draw(Image.new('L', (1, 1)))
    l, t, r, b = probe.textbbox((0, 0), text, font=font, stroke_width=stroke)
    tw, th = r - l, b - t
    ox, oy = (S - tw) / 2 - l, top + BOX * 0.075 - t
    def mask(width):
        m = Image.new('L', (S, S), 0)
        ImageDraw.Draw(m).text((ox, oy), text, font=font, fill=255, stroke_width=width, stroke_fill=255)
        return m
    def closed(m):          # fills the slivers where neighbouring outlines meet
        return m.filter(ImageFilter.MaxFilter(31)).filter(ImageFilter.MinFilter(31))
    fill_m, outline_m, rim_m = mask(0), closed(mask(stroke)), closed(mask(stroke + int(BOX * 0.010)))
    grad = Image.new('RGBA', (S, S))
    gd = ImageDraw.Draw(grad)
    y0, y1 = int(oy + t), int(oy + b)
    for y in range(y0, y1 + 1):
        gd.line([(0, y), (S, y)], fill=lerp((255, 236, 120), (255, 132, 36), (y - y0) / max(1, y1 - y0)))
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    layer.paste((255, 244, 220, 255), (0, 0), rim_m)
    layer.paste((18, 12, 40, 255), (0, 0), outline_m)
    layer.paste(grad, (0, 0), fill_m)
    shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 150), (int(BOX * 0.012), int(BOX * 0.02)), rim_m)
    shadow = shadow.filter(ImageFilter.GaussianBlur(BOX * 0.012))
    shadow.alpha_composite(layer)
    k, yc = 0.21, oy + t + th / 2                     # lean: about 12 degrees
    return shadow.transform((S, S), Image.AFFINE, (1, k, -k * yc, 0, 1, 0), resample=Image.BICUBIC)


def draw():
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    art = Image.new('RGBA', (S, S))
    d = ImageDraw.Draw(art)
    top, horizon_y, bottom = M, M + int(BOX * 0.60), M + BOX
    # sky: deep indigo to violet to a sunset orange at the horizon
    stops = [(0.0, (20, 16, 58)), (0.55, (98, 38, 110)), (0.85, (214, 84, 86)), (1.0, (250, 160, 70))]
    for y in range(top, horizon_y + 1):
        t = (y - top) / (horizon_y - top)
        for k in range(len(stops) - 1):
            if stops[k][0] <= t <= stops[k + 1][0]:
                u = (t - stops[k][0]) / (stops[k + 1][0] - stops[k][0])
                d.line([(0, y), (S, y)], fill=lerp(stops[k][1], stops[k + 1][1], u))
                break
    # the sun, low and soft
    glow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx, cy, sr = S * 0.5, horizon_y - BOX * 0.06, BOX * 0.17
    gd.ellipse([cx - sr * 1.9, cy - sr * 1.9, cx + sr * 1.9, cy + sr * 1.9], fill=(255, 190, 110, 90))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.03))
    art.alpha_composite(glow)
    d = ImageDraw.Draw(art)
    d.ellipse([cx - sr, cy - sr, cx + sr, cy + sr], fill=(255, 214, 120))
    # skyline: towers of varied height, lit windows
    rng = random.Random(3)
    x = M - 10
    sil = (16, 12, 36)
    while x < M + BOX + 10:
        w = rng.randint(int(BOX * 0.045), int(BOX * 0.11))
        near_mid = 1.0 - abs((x + w / 2) - S / 2) / (BOX / 2)
        h = int(BOX * (0.07 + 0.30 * rng.random() * (0.45 + 0.55 * near_mid)))
        y0 = horizon_y - h
        d.rectangle([x, y0, x + w, horizon_y + 2], fill=sil)
        if rng.random() < 0.35:                       # a spire or step
            sw = max(6, w // 4)
            d.rectangle([x + w // 2 - sw // 2, y0 - h // 6, x + w // 2 + sw // 2, y0], fill=sil)
        wx, wy = max(10, w // 6), max(10, h // 14)
        for yy in range(y0 + wy, horizon_y - wy, int(wy * 2.1)):
            for xx in range(x + wx // 2, x + w - wx, int(wx * 1.9)):
                if rng.random() < 0.38:
                    d.rectangle([xx, yy, xx + wx * 0.7, yy + wy * 0.8], fill=(255, 200, 110))
        x += w + rng.randint(0, int(BOX * 0.012))
    # road: asphalt to the vanishing point, edge lines, centre dashes
    vp = (S / 2, horizon_y)
    bl, br = (M - BOX * 0.25, bottom), (M + BOX * 1.25, bottom)
    d.rectangle([0, horizon_y, S, S], fill=(34, 30, 52))
    d.polygon([vp, br, bl], fill=(52, 50, 66))
    for side in (bl, br):
        for k in range(14):
            t0, t1 = k / 14, (k + 1) / 14
            p0 = lerp(vp, side, t0 ** 1.0)
            p1 = lerp(vp, side, t1 ** 1.0)
            d.line([p0, p1], fill=(235, 235, 245), width=max(2, int(4 + 22 * t1)))
    for k in range(10):                               # perspective dashes
        t0 = (k / 10) ** 2.2
        t1 = ((k + 0.55) / 10) ** 2.2
        y0, y1 = horizon_y + (bottom - horizon_y) * t0, horizon_y + (bottom - horizon_y) * t1
        w0, w1 = 3 + 40 * t0, 3 + 40 * t1
        d.polygon([(S / 2 - w0, y0), (S / 2 + w0, y0), (S / 2 + w1, y1), (S / 2 - w1, y1)],
                  fill=(255, 205, 60))
    art.alpha_composite(title(top))
    mask = squircle_mask()
    img.paste(art, (0, 0), mask)
    # a soft drop shadow under the shape, as macOS icons have
    shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    sh = Image.new('L', (S, S), 0)
    sh.paste(mask.point(lambda v: v * 0.45), (0, int(S * 0.012)))
    shadow.putalpha(sh.filter(ImageFilter.GaussianBlur(S * 0.012)))
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    out.alpha_composite(shadow)
    out.alpha_composite(img)
    return out.resize((1024, 1024), Image.LANCZOS)


def main():
    icon = draw()
    tmp = tempfile.mkdtemp()
    iconset = os.path.join(tmp, 'AppIcon.iconset')
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f'icon_{size}x{size}.png'))
        icon.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f'icon_{size}x{size}@2x.png'))
    subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', OUT], check=True)
    icon.save(os.path.join(tmp, 'preview.png'))
    print(OUT, '(preview', os.path.join(tmp, 'preview.png') + ')')
    shutil.rmtree(iconset)


if __name__ == '__main__':
    main()
