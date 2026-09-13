#!/usr/bin/env python3
"""
Plates for rheocles.com, via OpenAI's gpt-image-2. Sonocles' art/make.py
pattern, with Rheocles' subjects.

    python3 art/make.py --list
    python3 art/make.py --dry-run                # print prompts, spend nothing
    python3 art/make.py --env path/to/.env       # generate what is missing
    python3 art/make.py --only hero --force      # redo one, deliberately

Every call costs money, so nothing regenerates unless asked: a plate that
already exists in site/art/originals is skipped unless --force, and the
outputs are committed, not scratch. Len approves every run by name and count
before it happens; the prompts here are the ones written down in site/ART.md,
and ART.md is the copy people read — keep the two in step.

THE DIRECTION
Sonocles' flat comic register with the source moved from Attic vase painting
to Minoan fresco: Knossos blue on lime plaster, Rhea and her six children, the
one joke (Kronos, the stone) played straight. docs/BRAND.md § The plates.

Three lessons, two of them paid for by Sonocles. No lettering, ever — the
model cannot spell Greek and gibberish reads as carelessness. Specify clothing
explicitly, or moderation refuses the run and teaches nothing. And no vases:
the reference is wall painting, and a pot on a Rheocles plate is a Sonocles
plate.
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# The originals land here; site/art/sticker.py cuts them to stickers (the
# cream lifted off, the drawing sat straight on the page) and writes those
# to site/src/assets/plates, where Astro's <Image> serves sized variants.
# Run sticker.py after every generation.
OUT = ROOT / "site" / "art" / "originals"

# The shared grammar. Every prompt inherits it so the set reads as one hand.
STYLE = """
Flat modern vector illustration in a bold, playful, comic style. A contemporary
editorial illustrator riffing on Minoan wall painting — the frescoes of Knossos —
clearly inspired by it, absolutely not pretending to be an artifact.

Clean confident shapes with thick even outlines. Completely flat colour fills:
no gradients, no shading, no texture, no photographic realism. Characters are
warm and funny with expressive cartoon faces — big eyes, real emotions, visible
personality — with slightly rounded, friendly proportions and comedic timing in
the poses.

Palette strictly: deep Aegean blue, warm ochre yellow, pale limestone cream, a
muted brick red used sparingly, soft olive green, and a dark warm charcoal for
outlines. Nothing else. Blue is the dominant colour.

Set on a plain flat pale limestone-cream background with generous empty space
around the subject. Everything fully inside the frame, nothing touching the
edges. No vase, no pottery, no plaster cracks, no museum lighting, no plinth,
no frame, no photographic background. Pure flat graphic illustration, as
though screen printed.

Absolutely no lettering, no text, no Greek characters, no numerals, no
watermarks anywhere. All figures fully clothed in simple draped tunics or
Minoan flounced dresses.
"""

PLATES = {
    "hero": (
        "1536x1024",
        """
        Wide composition, lots of breathing room.

        A tall, calm, amused woman in a blue Minoan flounced dress — Rhea — stands
        behind a long low bench on which six small cradles sit in a neat row. In
        each cradle a different cheerful infant: one with a tiny lightning bolt as
        a toy, one holding a seashell, one with a small sheaf of wheat, one wearing
        a little crown of leaves, one asleep, one waving. Rhea has one hand raised,
        palm out, index finger up, in the exact gesture of someone about to count
        in a band. Every baby is looking at her hand.

        At the left, standing whole in a doorway that sits well inside the
        frame, a large scowling bearded figure in an ochre robe — Kronos — looks
        put out, arms folded. Nobody is paying him any attention.

        The joke is that each child has its own cradle and they are all about to
        start on the same word.
        """,
    ),
    "stone": (
        "1024x1024",
        """
        A single square composition, two characters, centred.

        Rhea, in a blue Minoan flounced dress, holds out a rock the size of a
        watermelon, carefully wrapped in a cream blanket like a swaddled baby,
        with a completely straight face. Kronos, a large bearded figure in an
        ochre robe, reaches for it with both hands, delighted, clearly about to
        eat it, eyes shut in anticipation.

        Tucked behind Rhea's skirt, a small real baby peeks out, grinning.

        Played perfectly straight. The comedy is in Rhea's expression: patient,
        polite, absolutely not going to explain.
        """,
    ),
    "rig": (
        "1536x1024",
        """
        Wide composition. A cosy Minoan interior with a low bench.

        Rhea, blue flounced dress, sits at ease with a cup of something, one arm
        along the back of the bench, looking pleased with herself. In front of
        her, six small cradles in a row, and in each a happy infant — every one
        of them holding a little rectangular tablet the way a child holds a
        picture book.

        The sixth cradle, at the end of the row, is slightly apart from the
        others and a small olive-green footstool has clearly just been pushed in
        to make room for it. That baby is waving.

        Everyone is relaxed. Nothing about this is unusual to anyone in the
        picture.
        """,
    ),
}

# Written down but not approved for a run. Reachable only by name:
#   python3 art/make.py --only late-join
LATER = {
    "late-join": (
        "1024x1024",
        """
        A square composition. A row of five small cradles, every infant in them
        fast asleep. Through a doorway on the right, Rhea — blue Minoan flounced
        dress — carries in a sixth cradle with a wide-awake, delighted baby in
        it. On the wall, a simple water clock, drawn as a small ochre vessel
        with a spout, dripping into a bowl.

        Nobody is disturbed. The late one is simply being set down at the end
        of the row, in the place it belongs.
        """,
    ),
    "two-boxes": (
        "1536x1024",
        """
        Wide composition split by a wall down the middle into two identical
        rooms. In each room, a low bench with three cradles and a cheerful
        infant in each. Above the wall, exactly centred, one large round clock
        face drawn in flat blue and ochre with a single hand — no numerals, no
        markings — visible from both rooms. Every baby in both rooms is looking
        up at the same clock.
        """,
    ),
}
PLATES.update(LATER)
RETIRED = frozenset(LATER)


def load_env(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip("'\""))


def generate(size: str, body: str, quality: str, key: str) -> bytes:
    prompt = (STYLE + "\n" + body).strip()
    payload = json.dumps(
        {
            "model": "gpt-image-2",
            "prompt": prompt,
            "size": size,
            "quality": quality,
            "n": 1,
        }
    ).encode()

    request = urllib.request.Request(
        "https://api.openai.com/v1/images/generations",
        data=payload,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
    )

    with urllib.request.urlopen(request, timeout=600) as response:
        data = json.load(response)

    return base64.b64decode(data["data"][0]["b64_json"])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--quality", default="high", choices=["low", "medium", "high"])
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--env",
        default=str(ROOT / ".env"),
        help="where OPENAI_API_KEY lives, if not already in the environment",
    )
    args = parser.parse_args()

    if args.list:
        for name, (size, body) in PLATES.items():
            first = " ".join(body.split())[:88]
            mark = "later   " if name in RETIRED else "        "
            print(f"{name:12} {mark}{size:10} {first}…")
        return 0

    wanted = args.only or [n for n in PLATES if n not in RETIRED]
    OUT.mkdir(parents=True, exist_ok=True)

    if not args.dry_run:
        load_env(Path(args.env))
        key = os.environ.get("OPENAI_API_KEY")
        if not key:
            print("no OPENAI_API_KEY", file=sys.stderr)
            return 1
    else:
        key = ""

    for name in wanted:
        if name not in PLATES:
            print(f"unknown plate '{name}'", file=sys.stderr)
            continue

        size, body = PLATES[name]
        target = OUT / f"{name}.png"

        if target.exists() and not args.force:
            print(f"{name:12} exists, skipping (--force to redo)")
            continue

        if args.dry_run:
            print(f"--- {name} ({size}) ---")
            print((STYLE + "\n" + body).strip())
            print()
            continue

        print(f"{name:12} generating {size} {args.quality}…", flush=True)
        try:
            target.write_bytes(generate(size, body, args.quality, key))
            print(f"{name:12} -> {target.relative_to(ROOT)}")
        except urllib.error.HTTPError as error:
            print(f"{name:12} FAILED {error.code}: {error.read()[:400]!r}", file=sys.stderr)
        except Exception as error:  # noqa: BLE001
            print(f"{name:12} FAILED {error}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
