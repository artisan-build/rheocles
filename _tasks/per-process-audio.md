# Per-process system audio

**Deferred (spec §5, §17).** System audio is captured as one stream — the
whole mix — via a Core Audio process tap in a private aggregate device
(`SystemAudioSession`). Capturing a *single* application's audio (just the
browser, just the call) is out of the MVP.

**Why it's close.** `CATapDescription` already supports process selection:
`SystemAudioSession` uses `stereoGlobalTapButExcludeProcesses([])` (everything).
The per-process version is `CATapDescription(processes:...)` or the
mono/stereo-mixdown-of-processes initializers, keyed by `audit_token` /
`pid`. It would surface as additional `systemAudio:` streams — one per
capturable process — in `GET /streams`, each its own tap and aggregate.

**What's missing:** enumerating capturable audio processes for the stream
list (they are volatile, like windows, so likely behind a setting), and one
tap+aggregate per selected process. The writer path (BWF) is unchanged.

Not started.
