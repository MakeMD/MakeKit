"""Slice Nano Banana icon sheets (icon-kit/kit/*.jpg, flat dark background) into PNGs with alpha.

Run: py -3.10 tools/slice_icons.py   (needs Pillow + numpy)
Out: icons/<name>.png (128 master) and icons/<size>/<name>.png for SIZES, plus icon-kit/contact.png.

Alpha = distance from the sheet background colour (soft ramp LO..HI), colour un-mixed from that
background, so icons work on any background. Dark "cut lines" inside icons (same tone as the
background) become transparent on purpose: they read as gaps, like the original design.
ponytail: fixed grid per sheet, no component detection; re-check SHEETS when a sheet is regenerated.
"""
import os
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "icon-kit", "kit")
OUT = os.path.join(ROOT, "icons")
SIZES = (16, 24, 32, 48)
MASTER = 128  # covers 48 px at 250% DPI; embedded into the exes
LO, HI = 14.0, 70.0  # RGB distance from background: <LO transparent, >HI opaque
PAD = 0.06  # empty margin around the icon inside its square, fraction of the side

# sheet -> (cols, rows, names row by row); None = skip that cell
SHEETS = {
    "joint": (4, 3, [
        "delete", "find", "info", "settings",
        "lock", "drive", "favorite", "up",
        "warning", "folder", "document", "ok"]),
    "MakePack": (4, 3, [
        "add", "extract", "test", "view",
        "convert", "report", "refresh", "archive_locked",
        "folder_protected", "history", "pack", "copy"]),
    "MakeCleaner": (4, 4, [
        "cleaner", "registry", "tools", None,
        "options", "uninstall", "startup", None,
        "duplicates", "disk_analyzer", "wipe", None,
        "restore", "cookies", "schedule", None]),
}


def unmix(rgb, bg):
    d = np.sqrt(((rgb - bg) ** 2).sum(-1))
    a = np.clip((d - LO) / (HI - LO), 0.0, 1.0)
    safe = np.maximum(a, 1e-3)[..., None]
    fg = np.clip(bg + (rgb - bg) / safe, 0, 255)
    return np.dstack([fg, a * 255]).astype(np.uint8)


def background(px):
    border = np.concatenate([px[:6].reshape(-1, 3), px[-6:].reshape(-1, 3),
                             px[:, :6].reshape(-1, 3), px[:, -6:].reshape(-1, 3)])
    return np.median(border, 0)


def square(rgba):
    a = rgba[..., 3]
    ys, xs = np.nonzero(a > 8)
    if len(xs) == 0:
        raise ValueError("empty cell")
    crop = rgba[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    h, w = crop.shape[:2]
    side = int(max(h, w) / (1 - 2 * PAD))
    canvas = np.zeros((side, side, 4), np.uint8)
    y0, x0 = (side - h) // 2, (side - w) // 2
    canvas[y0:y0 + h, x0:x0 + w] = crop
    return Image.fromarray(canvas, "RGBA")


def resized(img, n):
    # premultiplied resize, so transparent pixels do not bleed dark fringes into edges
    return img.convert("RGBa").resize((n, n), Image.LANCZOS).convert("RGBA")


def main():
    for d in [OUT] + [os.path.join(OUT, str(s)) for s in SIZES]:
        os.makedirs(d, exist_ok=True)
    made = []
    for sheet, (cols, rows, names) in SHEETS.items():
        assert len(names) == cols * rows, sheet
        px = np.asarray(Image.open(os.path.join(SRC, sheet + ".jpg")).convert("RGB")).astype(float)
        bg = background(px)
        H, W = px.shape[:2]
        for i, name in enumerate(names):
            if name is None:
                continue
            r, c = divmod(i, cols)
            cell = px[r * H // rows:(r + 1) * H // rows, c * W // cols:(c + 1) * W // cols]
            ico = square(unmix(cell, bg))
            resized(ico, MASTER).save(os.path.join(OUT, name + ".png"))
            for s in SIZES:
                resized(ico, s).save(os.path.join(OUT, str(s), name + ".png"))
            made.append(name)
    contact(made)
    print(f"{len(made)} icons -> {OUT}")


def contact(names):
    """One row per icon set size, on the dark UI background and on white; 48/32/16 px at 1:1."""
    bgs = [(45, 52, 54), (255, 255, 255)]
    cell = 56
    img = Image.new("RGB", (len(names) * cell, len(bgs) * 3 * cell), bgs[0])
    for bi, bgc in enumerate(bgs):
        for si, s in enumerate((48, 32, 16)):
            y = (bi * 3 + si) * cell
            img.paste(bgc, (0, y, img.width, y + cell))
            for i, n in enumerate(names):
                ico = Image.open(os.path.join(OUT, str(s), n + ".png"))
                img.paste(ico, (i * cell + (cell - s) // 2, y + (cell - s) // 2), ico)
    img.save(os.path.join(ROOT, "icon-kit", "contact.png"))


if __name__ == "__main__":
    main()
