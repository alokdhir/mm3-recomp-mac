#!/usr/bin/env python3
"""Upscale dumped game textures into a replacement pack with Real-ESRGAN.

    RECOMP_TEX_DUMP_DIR=texdump ./build/third_party/mm3-recomp/mm3_recomp   # play
    .venv-upscale/bin/python scripts/upscale_textures.py texdump texpack
    ./build/third_party/mm3-recomp/mm3_recomp                               # uses texpack/

Each PNG keeps its name (the texture's content key). Only photographic
surfaces go through Real-ESRGAN (RealESRGAN_x4plus). Anything with
transparency or few colours -- fonts, signs, HUD, maps, masks -- is left to
the original by default: glyphs a few texels tall come out of a model as
different letters ("WARNING" read "VIARNING"), and even the runtime's
edge-steepening resampler (tools/texpack/upscale.py, --graphics) read worse
than the original smoothly filtered. Colour is bled into fully
transparent texels first, so edges do not pick up whatever colour lay under
them, and alpha is upscaled on its own. Textures that are data rather than
pictures (thin ramps and lookup strips, normal maps) are left out: the
original stays in use. 512 px and larger get 2x, the rest 4x.

Needs torch, spandrel, pillow, numpy (Python 3.12 venv: .venv-upscale) and
the two .pth files in --models (default .venv-upscale/models).
"""
import argparse
import os
import sys
import time

import numpy as np
from PIL import Image
import torch
import spandrel

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'third_party', 'mm3-recomp', 'tools', 'xboxrecomp', 'tools', 'texpack'))
import upscale as edge_upscale  # noqa: E402  (the runtime's font/mask resampler)


def load_model(path, device):
    m = spandrel.ModelLoader().load_from_file(path)
    m.model.eval().to(device)
    if device.type == 'mps':
        m.model.half()
    return m


def run(model, rgb, device, tile=384, pad=16):
    """rgb: HxWx3 float32 0..1 -> (4H)x(4W)x3, tiled with overlap."""
    h, w, _ = rgb.shape
    s = model.scale
    out = np.zeros((h * s, w * s, 3), np.float32)
    half = device.type == 'mps'
    for y0 in range(0, h, tile):
        for x0 in range(0, w, tile):
            y1, x1 = min(y0 + tile, h), min(x0 + tile, w)
            ya, xa = max(y0 - pad, 0), max(x0 - pad, 0)
            yb, xb = min(y1 + pad, h), min(x1 + pad, w)
            t = torch.from_numpy(np.ascontiguousarray(rgb[ya:yb, xa:xb].transpose(2, 0, 1)))[None]
            t = t.to(device)
            if half:
                t = t.half()
            with torch.no_grad():
                r = model.model(t)
            r = r[0].float().clamp(0, 1).cpu().numpy().transpose(1, 2, 0)
            out[y0 * s:y1 * s, x0 * s:x1 * s] = r[(y0 - ya) * s:(y0 - ya + y1 - y0) * s,
                                                   (x0 - xa) * s:(x0 - xa + x1 - x0) * s]
    return out


def bleed(rgb, alpha, passes=24):
    """Fill fully transparent texels with the colour of their opaque
    neighbours, spreading outward a texel per pass."""
    known = alpha > 0.5 / 255
    if known.all() or not known.any():
        return rgb
    rgb = rgb.copy()
    k = known.astype(np.float32)
    for _ in range(passes):
        if k.min() > 0:
            break
        acc = np.zeros_like(rgb)
        wsum = np.zeros(k.shape, np.float32)
        p = np.pad(rgb * k[..., None], ((1, 1), (1, 1), (0, 0)), mode='edge')
        q = np.pad(k, 1, mode='edge')
        for dy in (0, 1, 2):
            for dx in (0, 1, 2):
                acc += p[dy:dy + rgb.shape[0], dx:dx + rgb.shape[1]]
                wsum += q[dy:dy + k.shape[0], dx:dx + k.shape[1]]
        fill = (k == 0) & (wsum > 0)
        rgb[fill] = acc[fill] / wsum[fill][:, None]
        k = np.where(fill, 1.0, k)
    return rgb


def is_data(img, rgb):
    w, h = img.size
    if min(w, h) <= 4 or max(w, h) >= 16 * min(w, h):
        return 'strip'
    m = rgb.reshape(-1, 3).mean(axis=0)
    if m[2] > 0.7 and abs(m[0] - 0.5) < 0.12 and abs(m[1] - 0.5) < 0.12:
        return 'normal map'
    return None


def is_mask(rgb, alpha):
    """One flat colour where it is visible: the shape is all in alpha."""
    seen = alpha > 0.5
    if alpha.min() >= 250 / 255 or seen.sum() < 16:
        return False
    return float(rgb[seen].std(axis=0).max()) < 0.03


def is_graphic(img, alpha):
    if alpha.min() < 250 / 255:
        return True
    small = img.convert('RGB').resize((64, 64), Image.NEAREST)
    return len(small.getcolors(64 * 64) or ()) <= 200


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--models', default=os.path.join(ROOT, '.venv-upscale', 'models'))
    ap.add_argument('--force', action='store_true', help='redo textures already in dst')
    ap.add_argument('--only', help='comma-separated keys (file stems) to process')
    ap.add_argument('--graphics', action='store_true',
                    help='also resample fonts/HUD/signs/masks (edge method); off by default: '
                         'small text read better as the original, smoothly filtered')
    args = ap.parse_args()
    device = torch.device('mps' if torch.backends.mps.is_available() else 'cpu')
    general = load_model(os.path.join(args.models, 'RealESRGAN_x4plus.pth'), device)
    art = load_model(os.path.join(args.models, 'RealESRGAN_x4plus_anime_6B.pth'), device)
    os.makedirs(args.dst, exist_ok=True)
    names = sorted(n for n in os.listdir(args.src) if n.lower().endswith('.png'))
    if args.only:
        keep = set(args.only.split(','))
        names = [n for n in names if os.path.splitext(n)[0] in keep]
    done = skipped = 0
    t0 = time.time()
    for n in names:
        out_path = os.path.join(args.dst, n)
        if os.path.exists(out_path) and not args.force:
            continue
        img = Image.open(os.path.join(args.src, n)).convert('RGBA')
        a8 = np.asarray(img, np.float32) / 255.0
        rgb, alpha = a8[..., :3], a8[..., 3]
        why = is_data(img, rgb)
        if why:
            skipped += 1
            print(f'  skip {n} ({img.size[0]}x{img.size[1]}, {why})')
            continue
        if is_mask(rgb, alpha) or is_graphic(img, alpha):
            if not args.graphics:
                skipped += 1
                continue
            result = edge_upscale.upscale(img, 4 if max(img.size) < 512 else 2, 1.5)
            result.save(out_path)
            done += 1
            continue
        model = art if is_graphic(img, alpha) else general
        has_alpha = alpha.min() < 1.0
        up = run(model, bleed(rgb, alpha), device)
        if has_alpha:
            a3 = np.repeat(alpha[..., None], 3, axis=2)
            ua = run(art, a3, device).mean(axis=2)
        else:
            ua = np.ones(up.shape[:2], np.float32)
        out = np.dstack([up, ua])
        result = Image.fromarray((out * 255.0 + 0.5).clip(0, 255).astype(np.uint8), 'RGBA')
        if max(img.size) >= 512:
            result = result.resize((img.size[0] * 2, img.size[1] * 2), Image.LANCZOS)
        result.save(out_path)
        done += 1
        if done % 25 == 0:
            print(f'  {done} upscaled ({time.time() - t0:.0f} s)', flush=True)
    print(f'{done} upscaled, {skipped} left as they are, {time.time() - t0:.0f} s -> {args.dst}')


if __name__ == '__main__':
    sys.exit(main())
