# Optional format on the arm body

`POST /streams/{id}/arm` takes only `{ "armed": true|false }`. "Native" for a
camera is deterministic — the largest format, rate capped at 60 — which is
right for a camera and wrong for a capture card fed a 1080p signal (the
Elgato 4K X advertises 3840×2160 and upscales). AVFoundation cannot see the
signal's own resolution or rate.

The clean fix is an optional `{ "video": { "width", "height", "frameRate" } }`
on the arm body, honoured when the device has that format, reported back in
`active`. It is per-stream format selection, which spec §17 keeps out of the
MVP. Decided 12 Sep 2026: not now; `active` in `GET /streams` makes the
chosen format visible, and step 5 will measure the delivered rate.
