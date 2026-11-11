"""Build app icons (.ico + PNGs) from Nano Banana renders on a flat white background.

Run: py -3.10 tools/app_icons.py <src.jpg> <out_dir> <name>   (Pillow + numpy)
Out: <out_dir>/<name>.ico (16..256) and <out_dir>/<name>-<size>.png for the sizes in PNGS.

Alpha = distance from the white background, colour un-mixed from white; only the largest blob
(the tile) survives, so stray generation artefacts beside it are dropped. The tile is cropped
and centred so every app icon of the family fills the canvas the same way.
"""
import os
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ICO = (16, 20, 24, 32, 40, 48, 64, 128, 256)
PNGS = (44, 50, 150, 256)  # MSIX logos + a master
LO, HI = 10.0, 60.0
FILL = 0.94  # tile side / canvas side (Windows icons keep a small margin)


def alpha_from_white(rgb):
    bg = np.array([255.0, 255.0, 255.0])
    d = np.sqrt(((rgb - bg) ** 2).sum(-1))
    a = np.clip((d - LO) / (HI - LO), 0.0, 1.0)
    fg = np.clip(bg + (rgb - bg) / np.maximum(a, 1e-3)[..., None], 0, 255)
    return fg, a


def largest_blob(mask):
    """Label 4-connected components (scan + union-find, no scipy) and keep the biggest."""
    h, w = mask.shape
    lab = np.zeros((h, w), np.int32)
    parent = [0]

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for y in range(h):
        row, up = mask[y], lab[y - 1] if y else None
        for x in np.nonzero(row)[0]:
            l = lab[y, x - 1] if x and row[x - 1] else 0
            u = up[x] if y and mask[y - 1, x] else 0
            if l and u:
                rl, ru = find(l), find(u)
                lab[y, x] = min(rl, ru)
                parent[max(rl, ru)] = min(rl, ru)
            elif l or u:
                lab[y, x] = l or u
            else:
                parent.append(len(parent))
                lab[y, x] = len(parent) - 1
    roots = np.array([find(i) for i in range(len(parent))])
    lab = roots[lab]
    counts = np.bincount(lab.ravel())
    counts[0] = 0
    return lab == counts.argmax()


def build(src, out_dir, name):
    rgb = np.asarray(Image.open(src).convert("RGB")).astype(float)
    small = Image.fromarray(rgb.astype(np.uint8)).resize((rgb.shape[1] // 4, rgb.shape[0] // 4))
    _, a_small = alpha_from_white(np.asarray(small).astype(float))
    keep_small = largest_blob(a_small > 0.5)
    keep = np.asarray(Image.fromarray(keep_small.astype(np.uint8) * 255).resize(
        (rgb.shape[1], rgb.shape[0]), Image.NEAREST)).astype(bool)
    # grow the kept area a little so the soft anti-aliased rim stays
    keep = np.asarray(Image.fromarray(keep.astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(9))) > 0
    # everything enclosed by the tile is opaque (near-white symbol parts must not turn see-through):
    # flood the outside from a corner, whatever stays unflooded is the solid tile
    m = Image.fromarray(keep.astype(np.uint8) * 255).copy()  # copy: fromarray shares a read-only buffer, floodfill would silently do nothing
    ImageDraw.floodfill(m, (0, 0), 128)
    solid = np.asarray(m) != 128
    inner = np.asarray(Image.fromarray(solid.astype(np.uint8) * 255).filter(ImageFilter.MinFilter(9))) > 0
    fg, a = alpha_from_white(rgb)
    a = np.where(inner, 1.0, a * solid)
    fg = np.where(inner[..., None], rgb, fg)
    ys, xs = np.nonzero(a > 0.5)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    rgba = np.dstack([fg, a * 255]).astype(np.uint8)[y0:y1, x0:x1]
    h, w = rgba.shape[:2]
    side = int(round(max(h, w) / FILL))
    canvas = np.zeros((side, side, 4), np.uint8)
    canvas[(side - h) // 2:(side - h) // 2 + h, (side - w) // 2:(side - w) // 2 + w] = rgba
    master = Image.fromarray(canvas, "RGBA")

    def sized(n):
        return master.convert("RGBa").resize((n, n), Image.LANCZOS).convert("RGBA")

    os.makedirs(out_dir, exist_ok=True)
    big = sized(256)
    big.save(os.path.join(out_dir, name + ".ico"), sizes=[(s, s) for s in ICO],
             append_images=[sized(s) for s in ICO if s != 256])
    for s in PNGS:
        sized(s).save(os.path.join(out_dir, f"{name}-{s}.png"))
    print(f"{name}: tile {w}x{h} px -> {out_dir}")


if __name__ == "__main__":
    build(*sys.argv[1:4])
