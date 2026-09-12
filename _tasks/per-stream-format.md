# Per-stream codec / resolution / frame rate

**Deferred (spec §17).** The MVP records every stream at its native
resolution and frame rate, and one codec (`settings.codec` / a take's
`codec`) applies to the whole take. Per-stream overrides — this camera in
ProRes at 1080p while that display stays HEVC at native 4K — are out.

**Why it's clean to add later.** The manifest already records `codec` and
`format` per stream, and the writer is chosen per stream in
`DeviceWriterFactory`. The hooks:

- `arm` could take an optional format (see `arm-format-option.md`) so
  "native" is selectable per stream.
- `POST /takes` `files` is already per-stream; a parallel per-stream `codec`
  / `resolution` / `fps` map would sit beside it, defaulting to the take's.
- `DeviceWriterFactory.makeWriter` would honour those instead of the single
  take codec.

Not started; the single-codec take is deliberate for the MVP.
