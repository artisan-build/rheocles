# Rheocles

**REE-oh-kleez** — rhymes with Sophocles, same as its sibling.

Sibling of [Sonocles](https://sonocles.com). Sonocles listens; Rheocles
watches. Same maker, same type, same illustrated register, same temperature —
a different mark, a different myth, a different island. Someone seeing both
sites should know they share a maker; someone seeing one should not feel it
is a reskin. Agreed with Len, 11 Sep 2026.

## The name is not decoration

*Rheō* (ῥέω) is "to flow". It descends from the Proto-Indo-European root
`*srew-`, which came down through Germanic as the English word **stream**. So
*rheo-* does not resemble "stream"; it *is* "stream", two thousand years
upstream. For a tool whose whole job is recording streams, that is an
inheritance rather than a pun — the same kind of luck Sonocles had with
*kleos* and "loud".

*-cles* is `-κλῆς`, from *kleos*: renown, **known for**. Known for the flow.

Rhea (Ῥέα), Titaness, mother of the Olympians, is attached to *rheō* by Plato,
in the *Cratylus*, and Plato was making a pun. We are borrowing it, not
asserting it. One honest note in the family spirit: both halves are Greek this
time. Sonocles could not say that, and will hear about it.

## The myth — spent once

Kronos swallowed each of his children as they were born, so that there was
only ever one of him. Rhea hid the sixth and handed him a stone in swaddling
clothes.

That is the product, and it is roughly our position on compositing. OBS is
Kronos: everything goes in, one thing comes out. Rheocles is Rhea: every child
stays its own child. The stone is the landing-page joke and the mark's origin
story. It appears once on the landing page and on one plate, and then the copy
gets on with saying numbers.

## Why it exists

OBS records one composited stream. Pteroprompter wanted the camera, the
prompter screen, the microphone and the system audio as four separate files,
started together, with no compositor in the way — because the layout is a
decision for the edit, not for the moment the light goes red.

That story leads. It is specific, it is checkable, and it explains the
architecture without an adjective.

## Licence and posture

Free, open source, MIT. Not a trial, not a tier, not a loss leader. Say so
plainly and once.

## What it is

A macOS menu bar app that records any number of input streams at once — every
camera, microphone, display and window — **each to its own file, on one cue**,
every file stamped with time-of-day timecode so an editor syncs them in one
click.

## What it is not

Not a compositor. That distinction is the entire positioning:

|  | a compositor | Rheocles |
|---|---|---|
| gives you | one file | one file per stream |
| the layout is decided | before you record | in the edit |
| files sync | by eye | by timecode |
| a crash leaves | a corrupt file | playable files and a truthful manifest |

Vocabulary is fixed. Say **stream** for an input, **take** for a recording,
**file** for what lands on disk, **cue** for the start, **arm** for
live-but-not-writing. Never "clip", never "track", never "source" — that is
OBS's word, and borrowing it borrows the model.

## Voice

Sonocles' rules, unchanged:

- **Say the number.** "Stamped from the host clock at the first written frame"
  beats "frame-accurate", because one of them is checkable.
- **Admit what it does not do.** Armed streams cost CPU and hold their
  devices. A stream that joins after midnight into a take that started before
  it will sort wrong in an NLE. The WAV ceiling is 4 GB. Say so.
- **Never dress up an absence.** An unmeasured drift is not zero. A feature
  that is planned is not a feature; "coming soon" is the only allowed
  softening, and only for the cask before the first release.
- **Dry, not zany.** The name is already the joke. Spending it once is
  sufficient.
- **No exclamation marks.**

Things we do not say: blazing, seamless, effortless, magical, revolutionary,
game-changing, powered by AI, unlock, supercharge, "just works", frame-perfect.

Things we do say: one cue, its own file, time-of-day, armed, 7447, loopback
only, measured, open the manifest and check.

One sentence from the spec must appear in the docs in these words: **Late
joining is for saving CPU on a heavy stream you already know will not need
edit flexibility. It is not a way to script a take.**

## Palette

**Limestone and Aegean.** Derived from Sonocles' with one deliberate shift.

Sonocles is the Attic mainland: fired clay, red-figure, terracotta on
limestone. Rheocles is **Crete** — Rhea's island, where Zeus was hidden — and
Crete's painting is the **Minoan fresco**: Knossos blue on lime plaster. The
ground is literally the same limestone; the pigment on it changes.

So: same ground, same ink, same absence colour, same record red, same app
darks, same type. The **signature** swaps from terracotta to Aegean blue, and
terracotta demotes to a warm supporting role as ochre — the colour of a stream
that is armed, live, and costing you.

The app stays dark; the site is light. Same palette, opposite grounds, for the
same reason as Sonocles: a tool sits over a running take, a poster does not.

| role | token | value | note |
|---|---|---|---|
| site ground | `limestone` | `#FAF2E4` | shared verbatim — the plaster |
| site inset | `limestone-deep` | `#EFE5D2` | shared |
| site rule | `limestone-line` | `#DED0B8` | shared |
| ink | `ink` | `#2A211A` | shared |
| ink, soft / faint | `ink-soft` `ink-faint` | `#4E4034` `#6B5C4C` | shared |
| **the signature** | `aegean` | `#2E5C86` | 6.3:1 on limestone |
| signature, soft / deep | `aegean-soft` `aegean-deep` | `#5F8FB8` `#244A6B` | |
| armed — live, costing you | `ochre` | `#C9903A` | fills and marks only |
| armed, as text | `ochre-ink` | `#8A5E1A` | |
| recording, stop | `oxide` | `#B4453A` | shared — record red is family DNA |
| complete, healthy | `olive` | `#6E7A52` | shared |
| **absent values** | `script` | `#7A6A59` | shared — a value we do not have |
| deepest ground (app) | `slip` | `#100C0A` | shared |
| popover | `panel` | `#1C1611` | shared |
| inset / meter cell | `field` | `#2B211A` | shared |
| brightest text (app) | `bone` | `#EFE3D0` | shared |
| body text (app) | `body` | `#CDBBA3` | shared |
| signature (app) | `aegean-bright` | `#6FA3D6` | aegean on dark |
| healthy (app) | `verdigris` | `#7FA88C` | shared |

Views name the *role*, not the pigment, so a palette change stays in one file.

`script` is load-bearing beyond its name, exactly as it is for Sonocles: a
missing drift, an unmeasured level, a stream with no frames yet. Absence gets
its own colour so it is never mistaken for a number.

State colours are a small language and the menu bar app speaks it: `script`
idle, `ochre` armed, `oxide` recording, `olive`/`verdigris` complete.

## Type

Carried over from Sonocles exactly, same Google Fonts request. Type is the
family constant; nothing here moves.

| use | face | why |
|---|---|---|
| wordmark, headings, pull quotes | **Fraunces**, variable, `SOFT 30` `WONK 1` | Old-style warmth with the soft and wonk axes up far enough to read as drawn rather than defaulted. One display face does the whole display voice. |
| kickers | **IBM Plex Mono**, uppercase, letterspaced | Furniture, never competing with the heading beneath. |
| body, card headings | **Instrument Sans** | A workhorse. The page is about a technical tool and has to be read. |
| data, code, timecode | **IBM Plex Mono** | Numbers should look like numbers. Timecode especially. |

No marble, no laurels, no columns. The classical reference lives in the
letterforms, the palette and the plates.

## Mark

Sonocles' mark is arcs struck from one dot. Rheocles' mark is **strokes
struck from one bar**: a single vertical stroke — the cue — with four
horizontal strokes flowing right from it, staggered in length, drawn with a
slight hand-made waver rather than ruled, the same "drawn, not defaulted" that
Fraunces' wonk axis gives the type. It is a river braid, a multitrack timeline,
and "one cue, many files" in one drawing. The strokes never merge. That is the
point.

At menu bar size the mark gives way to legibility, as Sonocles' does: idle
dims the whole mark to 40 %; armed draws the strokes in outline; recording
fills them. A late-joined stream is a shorter stroke that starts to the right
of the bar, so the icon can tell the truth about the take without opening the
popover. Template `NSImage`, drawn from shapes — see spec §12.

Section rules on the site are a thin **meander** band — the Greek key, named
after a river — where Sonocles' are a colonnade.

## The plates

Same register as Sonocles' `STYLE_FLAT` in `sonocles/art/make.py`: flat comic
illustration with thick even outlines, completely flat fills, warm characters
with real faces, limestone ground, as though screen printed. The source it has
clearly *looked at* shifts from Attic vase painting to Minoan fresco —
processions, dolphins, the Knossos blues, a lion or two for Rhea. Palette
strictly: limestone cream, Aegean blue, ochre, oxide red, olive, and a dark
warm charcoal for outlines. Nothing else.

Both of Sonocles' expensive lessons carry over. **No lettering, ever.**
**Specify clothing explicitly.** And a third that is ours: **no vases** — the
reference is wall painting, and a pot on a Rheocles plate is a Sonocles plate.

Every run costs money. Prompts are written down in `site/ART.md` and Len
approves each run before anything is generated.

## Copy

### One-liner

> Every stream, its own file, on one cue.

### Standfirst

> Rheocles records every camera, microphone, display and window on your Mac at
> once — each to its own file, started on one cue and stamped with time-of-day
> timecode, so an editor syncs them in one click. No compositor. Loopback only.

### The paragraph that does the work

> A compositor decides the layout before you record and hands you one file
> afterwards. That is fine for a live stream, where the layout is the show. It
> is the wrong shape for a take you are going to cut: the camera, the prompter
> screen, the microphone and the system audio each want to be their own file,
> started on the same cue, so the edit can decide what goes where.
>
> Rheocles is built for that second case. Arm what you want, cue once, and
> every armed stream lands as its own file with its own time-of-day timecode —
> so an editor lines them up without a manifest, and the manifest agrees with
> the files.

### Feature lines

**Every stream, its own file.**
Cameras, microphones, displays, windows and system audio, each written by its
own writer at native resolution and rate. Video to fragmented MOV, audio to
Broadcast Wave. No compositor, no mixdown, nothing to undo in the edit.

**Armed means live.**
An armed stream has frames flowing and discarded, so the cue starts a writer on
frames that already exist instead of waiting for a device to spin up. That is
the whole reason there is an arm button. Armed streams cost CPU and hold their
devices; the icon makes that obvious.

**Late arming.**
A stream that joins four minutes in is stamped four minutes in, and an editor
places it at four minutes. Late joining is for saving CPU on a heavy stream you
already know will not need edit flexibility. It is not a way to script a take.

**Every file carries its own time.**
A time-of-day timecode track in every video file, a Broadcast Wave time
reference in every audio file, both stamped from the host clock at the first
written frame. Files sync in an editor without the manifest. Drift against the
host clock is measured per stream and reported, whether or not you use it.

**The manifest is the take.**
`manifest.json`, rewritten atomically on every state change, so at any instant
it is either the previous complete version or the next. A dead process leaves
playable files and a truthful manifest.

**Anything can drive it.**
HTTP with server-sent events, and WebSocket, as equals: one command set, two
transports. A bearer token, always, provisioned to a file so same-machine apps
pair with zero clicks. Loopback only in the MVP — not as a policy, but because
the LAN path is designed and not yet built.

### Footer line

> Made for Pteroprompter. Useful on its own.

## Siblings, not a find-and-replace

Same page grid and header (mark · wordmark · pronunciation in mono · GitHub),
same free/open-source pill, same Fraunces hero with the second line in the
signature colour, same kicker-and-rule section rhythm, same dark code blocks,
same warm card grid, same plate-with-caption, same footer sentence shape.

Different signature colour, different mark, different myth, different rule
motif, different island. Sonocles is a red-figure pot from Athens; Rheocles is
a fresco from Knossos. They were made by the same hands and they are not the
same object.
