#!/usr/bin/env python3
"""
The sticker cut. A generated plate arrives on its own flat cream, which is
never quite the site's --limestone, so on the page each one reads as a
yellow rectangle. This lifts the drawing off that cream so it sits directly
on the page: flood-fill the background to transparency from all four edges,
soften the one-pixel edge, trim to the drawing plus a constant margin, and
write the result with alpha to src/assets/plates/.

    python3 site/art/sticker.py             # every plate in art/originals
    python3 site/art/sticker.py hero rig    # just those

Post-processing, not regeneration: art/make.py writes to site/art/originals/
and this runs after it. It is idempotent from the originals, so running it
twice is the same as running it once. Needs Pillow, numpy and scipy — in a
throwaway venv, or `python3 -m pip install --user pillow numpy scipy`; they
are not the site's dependencies and do not belong in package.json.

The fill only follows the background inward from the edges, so a cream area
enclosed by an outline (a blanket, a dress band) is left alone. A gap in an
outline lets the fill leak into such an area and leaves a hole; the fix is
a tighter TOLERANCE for that plate, below. A drawing that touches the frame
cannot be helped here — it needs regenerating with everything inside the
frame — so it goes in SKIP and ships on its rectangle rather than as half a
sticker.
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

HERE = Path(__file__).resolve().parent
ORIGINALS = HERE / "originals"
OUT = HERE.parent / "src" / "assets" / "plates"

# How far a pixel may sit from the background colour (max channel difference,
# 0–255) and still be background. The plates' cream is flat, so this is
# small; raise it for a plate whose cream has drifted, lower it for one where
# the fill leaks through a thin outline.
TOLERANCE = 14
TOLERANCES: dict[str, int] = {}

# Full colour at this distance from the background; between TOLERANCE and
# here the alpha ramps, which is what softens the one-pixel edge without a
# blur that would smear cream into the drawing.
OPAQUE_AT = 110

# Clear page around the drawing, in source pixels. Constant across plates so
# they sit the same distance from the copy.
MARGIN = 24

# Plates that touch the frame: the cut would show as a hard straight edge.
# Copied through unchanged until they are regenerated (site/ART.md).
SKIP = {"hero"}


def background(rgb: np.ndarray) -> np.ndarray:
    """The flat background colour: the median of the outermost pixel ring."""
    ring = np.concatenate([rgb[0], rgb[-1], rgb[:, 0], rgb[:, -1]])
    return np.median(ring, axis=0)


def sticker(name: str, tolerance: int) -> tuple[int, int, int, int]:
    image = Image.open(ORIGINALS / f"{name}.png").convert("RGBA")
    rgba = np.asarray(image).astype(np.int16)
    rgb = rgba[..., :3]
    bg = background(rgb)

    distance = np.abs(rgb - bg).max(axis=2)
    near = distance <= tolerance

    # Connected regions of background-coloured pixels; only those that reach
    # an edge are background. Everything else, however pale, is drawing.
    labels, _ = ndimage.label(near)
    edge_labels = np.unique(
        np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]])
    )
    outside = np.isin(labels, edge_labels[edge_labels != 0])

    # The anti-aliased pixels along the cut, two deep, ramp from clear to
    # solid by how far they are from the cream. Inside that ring nothing
    # is touched.
    rim = ndimage.binary_dilation(outside, iterations=2) & ~outside
    alpha = np.full(distance.shape, 255, dtype=np.int16)
    alpha[outside] = 0
    ramp = np.clip((distance - tolerance) / (OPAQUE_AT - tolerance), 0, 1)
    alpha[rim] = np.round(ramp[rim] * 255).astype(np.int16)

    # Un-mix the cream out of the partially transparent rim so the fringe is
    # the drawing's own colour, not cream at half strength.
    out = rgba.astype(np.float32)
    a = alpha.astype(np.float32) / 255
    soft = rim & (alpha > 0) & (alpha < 255)
    out[soft, :3] = np.clip(
        (out[soft, :3] - (1 - a[soft, None]) * bg) / a[soft, None], 0, 255
    )
    out[..., 3] = alpha

    # Trim to the drawing plus the margin, never past the source.
    ys, xs = np.nonzero(alpha)
    top, bottom = max(ys.min() - MARGIN, 0), min(ys.max() + MARGIN + 1, alpha.shape[0])
    left, right = max(xs.min() - MARGIN, 0), min(xs.max() + MARGIN + 1, alpha.shape[1])
    cut = out[top:bottom, left:right].round().astype(np.uint8)

    Image.fromarray(cut, "RGBA").save(OUT / f"{name}.png", optimize=True)
    return left, top, right, bottom


def main(argv: list[str]) -> int:
    names = argv or sorted(p.stem for p in ORIGINALS.glob("*.png"))
    OUT.mkdir(parents=True, exist_ok=True)
    for name in names:
        source = ORIGINALS / f"{name}.png"
        if not source.is_file():
            print(f"{name:8} no original at {source.relative_to(HERE.parent)}", file=sys.stderr)
            return 1
        if name in SKIP:
            (OUT / f"{name}.png").write_bytes(source.read_bytes())
            print(f"{name:8} touches the frame, copied through unchanged")
            continue
        tolerance = TOLERANCES.get(name, TOLERANCE)
        left, top, right, bottom = sticker(name, tolerance)
        print(f"{name:8} tolerance {tolerance:3}  cut to {right - left}×{bottom - top} at ({left}, {top})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
