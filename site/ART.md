# Plates

Illustrations for rheocles.com. Every run costs money; Len approves each one
explicitly, by name and count, through the orchestrator. The prompts live in
`art/make.py` (the source of truth — a bare run generates only what is
approved and missing); this file is the copy people read. A plate without an
image renders as a flat placeholder in its proportions
(`src/components/Plate.astro`).

**Generated 11 Sep 2026, one run, gpt-image-2 at `high`:** hero, stone, rig →
`art/originals/`. One first-pass note: the rig plate has a planter pot at
the right edge, which the "no vases" rule did not anticipate. It reads as a
plant, not a Sonocles pot; left as is.

**Queued for one regeneration, on Len's word:** hero. Kronos and the doorway
are clipped by the left edge of the frame, which no post-processing can fix.
The style block now says "everything fully inside the frame, nothing touching
the edges", and every future prompt carries that line. Until the rerun the
hero plate ships on its cream rectangle (`boxed` in `index.astro`) rather
than as a half-sticker.

## The sticker cut

A generated plate arrives on its own flat cream, never quite the site's
`--limestone`, so on the page it reads as a yellow rectangle. `art/sticker.py`
lifts the drawing off it — flood-fills the cream to transparency from the four
edges, softens the one-pixel edge, trims to the drawing plus a constant
margin — and writes `src/assets/plates/*.png` with alpha, so the drawing sits
straight on the page. The originals stay in `art/originals/` and are the
source; the script is idempotent from them.

```sh
# Pillow, numpy, scipy — a throwaway venv, not the site's package.json
python3 art/sticker.py            # every plate
python3 art/sticker.py rig stone  # just those
```

Check each result at 1× against the page: no cream halo, no holes where the
fill leaked through a thin outline into a pale interior (tighten
`TOLERANCES[name]` in the script if it does). A plate whose drawing touches
the frame goes in `SKIP` and ships boxed until it is regenerated.

The register is Sonocles' `STYLE_FLAT` with the source shifted from Attic vase
painting to Minoan fresco — see `docs/BRAND.md` § The plates. The style block
below is shared by every prompt; each plate is the subject paragraph plus the
style block. Both of Sonocles' expensive lessons apply, plus one of ours:
**no lettering, ever; everyone clothed; no vases.**

The first run was **3 plates, 1 image each** (hero, stone, rig). The two under
*Later* are written but not approved; `make.py` reaches them only by `--only`.

## Style — appended to every prompt

```
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
```

## hero — "Rhea and the cradles" · 1536×1024 · landing, below the fold

```
Wide composition, lots of breathing room.

A tall, calm, amused woman in a blue Minoan flounced dress — Rhea — stands
behind a long low bench on which six small cradles sit in a neat row. In each
cradle a different cheerful infant: one with a tiny lightning bolt as a toy,
one holding a seashell, one with a small sheaf of wheat, one wearing a little
crown of leaves, one asleep, one waving. Rhea has one hand raised, palm out,
index finger up, in the exact gesture of someone about to count in a band.
Every baby is looking at her hand.

At the far left edge, half through a doorway, a large scowling bearded figure
in an ochre robe — Kronos — looks put out, arms folded. Nobody is paying him
any attention.

The joke is that each child has its own cradle and they are all about to start
on the same word.
```

## stone — "Rhea and the stone" · 1024×1024 · landing, "The name"

```
A single square composition, two characters, centred.

Rhea, in a blue Minoan flounced dress, holds out a rock the size of a
watermelon, carefully wrapped in a cream blanket like a swaddled baby, with a
completely straight face. Kronos, a large bearded figure in an ochre robe,
reaches for it with both hands, delighted, clearly about to eat it, eyes shut
in anticipation.

Tucked behind Rhea's skirt, a small real baby peeks out, grinning.

Played perfectly straight. The comedy is in Rhea's expression: patient,
polite, absolutely not going to explain.
```

## rig — "the rig" · 1536×1024 · landing, closing plate

```
Wide composition. A cosy Minoan interior with a low bench.

Rhea, blue flounced dress, sits at ease with a cup of something, one arm along
the back of the bench, looking pleased with herself. In front of her, six
small cradles in a row, and in each a happy infant — every one of them
holding a little rectangular tablet the way a child holds a picture book.

The sixth cradle, at the end of the row, is slightly apart from the others and
a small olive-green footstool has clearly just been pushed in to make room for
it. That baby is waving.

Everyone is relaxed. Nothing about this is unusual to anyone in the picture.
```

## Later, if wanted

- **late join** · 1024×1024 · docs, Streams and arming — a seventh cradle
  being carried in through the door while the others are already asleep; a
  small water clock on the wall.
- **the two boxes** · 1536×1024 · docs, Timecode and sync — two identical
  benches in two rooms, one clock on the wall between them, the cradles in
  both rooms started on the same tick.

# Screenshots

The hero's popover (`src/assets/popover.png`) is not a plate and not a desktop
capture: the app renders it from a frozen model with fake devices, at 2×, so
it can be regenerated after any UI change without a display, a daemon or a
camera. The state is `chosen` in `app/Sources/Rheocles/Preview.swift` — the
Elgato 4K X camera and the Scarlett 2i2 microphone armed, the BenQ display
and two windows listed but not, the take bar idle with "Also save a single
file" unticked — so "you choose" is visible rather than stated.

```sh
cd app && swift build -c release --product Rheocles
.build/release/Rheocles --render-preview /tmp/rheocles-previews
cp /tmp/rheocles-previews/chosen.png ../site/src/assets/popover.png
```

The PNG is the popover alone, 688×1332 (344×666 at 1×), no window chrome;
`index.astro` gives it the shadow.
