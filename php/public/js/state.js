/*
 * The popover's state, as pure functions — what the event stream and the
 * pulse say, reduced to what the page shows. No DOM here, so the parsing
 * and the derivations can be tested without a browser (tests/js).
 */

/** One decoded event: the whole object, which always names its kind in `event`. */
export function decodeEvent(text) {
  let json
  try { json = JSON.parse(text) } catch { return null }
  return json && typeof json.event === 'string' ? json : null
}

export const initial = () => ({ streams: [], permissions: null, take: null, levels: {}, settings: null })

/** `GET /streams`, verbatim: the list and what macOS lets the daemon see. */
export const setStreams = (state, list) => ({
  ...state,
  streams: Array.isArray(list.streams) ? list.streams : [],
  permissions: list.permissions || null,
})

/** Apply one event to the state; returns a new state. */
export function reduce(state, event) {
  switch (event.event) {
    case 'stream': {
      // The StreamInfo as it now is; replace it in place so the switch
      // moves without a full re-read. A stream we have not listed yet is
      // appended; the next pulse puts it in the daemon's order.
      const s = event.stream
      if (!s || !s.id) return state
      const streams = state.streams.some(x => x.id === s.id)
        ? state.streams.map(x => (x.id === s.id ? s : x))
        : [...state.streams, s]
      return { ...state, streams }
    }
    case 'take':
      return event.take && event.take.state ? { ...state, take: event.take } : state
    case 'levels': {
      // Per-stream peak dBFS ~4×/s while recording (audio only). Kept by
      // id; an unmeasured level is absent, never zero.
      const next = { ...state.levels }
      for (const s of event.streams || []) if (s && s.id && typeof s.levelDb === 'number') next[s.id] = s.levelDb
      return { ...state, levels: next }
    }
    case 'settings':
      return event.settings ? { ...state, settings: event.settings } : state
    case 'marker': {
      // `{ t, label }` just added to the active take (PROTOCOL § Events);
      // appended here so the count moves before the next manifest arrives.
      const m = event.marker
      if (!m || !state.take || state.take.id !== event.take) return state
      return { ...state, take: { ...state.take, markers: [...(state.take.markers || []), m] } }
    }
    default:
      return state
  }
}

export const armedCount = state => state.streams.filter(s => s.armed).length

/**
 * Recording is a take the daemon says is recording — with one check the
 * daemon's own list cannot make: every recording stream is armed (join arms),
 * so a `recording` manifest with nothing armed is one a dead daemon left on
 * disk, not a take in progress. Before the first stream read, the take is
 * taken at its word.
 */
export const isRecording = state =>
  !!state.take && state.take.state === 'recording' && (state.streams.length === 0 || armedCount(state) > 0)

/**
 * The header's tone and word, from the daemon's condition. The state pill
 * speaks for the daemon, not the app: recording is a take it says is
 * recording, armed is any stream it says is armed.
 */
export function headline(daemon, state) {
  if (daemon.status === 'launching') return { tone: 'launching', label: 'Launching' }
  if (daemon.status === 'down') return { tone: 'down', label: 'Down' }
  if (isRecording(state)) return { tone: 'recording', label: 'Recording' }
  const n = armedCount(state)
  return n > 0 ? { tone: 'armed', label: `Armed · ${n}` } : { tone: 'idle', label: 'Idle' }
}

// MARK: - streams

/** The daemon's fixed order (PROTOCOL § GET /streams), and the headings. */
export const KINDS = ['display', 'window', 'camera', 'microphone', 'systemAudio']
export const HEADINGS = {
  display: 'Displays', window: 'Windows', camera: 'Cameras', microphone: 'Microphones', systemAudio: 'System audio',
}

/** The streams the popover lists: everything, or everything but windows. */
export const visibleStreams = (streams, showWindows) =>
  showWindows ? streams : streams.filter(s => s.kind !== 'window')

/**
 * Sections by kind, in the daemon's order. A kind with no members is left
 * out — unless a permission nudge belongs there, so the nudge has a place
 * to sit where the missing streams would be.
 */
export function sections(streams, showWindows, permissions, ours) {
  const visible = visibleStreams(streams, showWindows)
  return KINDS.map(kind => ({
    kind,
    heading: HEADINGS[kind],
    members: visible.filter(s => s.kind === kind),
    nudge: nudge(kind, permissions, ours),
  })).filter(s => s.members.length > 0 || s.nudge)
}

/** A rate or a kHz figure, whole when it is whole. */
const whole = (n, digits) => (Math.abs(n - Math.round(n)) < 0.01 ? String(Math.round(n)) : n.toFixed(digits))

/** "3840×2160 · 60" or "48 kHz · 2 ch": what the file will be. */
export function summary(capabilities) {
  const c = capabilities || {}
  if (c.video) return `${c.video.width}×${c.video.height} · ${whole(c.video.maxFrameRate, 2)}`
  if (c.audio) return `${whole(c.audio.sampleRate / 1000, 1)} kHz · ${c.audio.channels} ch`
  return '··'
}

/**
 * The row's second line. For a window, the owning app comes first — the
 * name alone ("Docs") says nothing about which of forty windows it is.
 */
export const detail = stream =>
  stream.kind === 'window' ? `${stream.model} · ${summary(stream.capabilities)}` : summary(stream.capabilities)

const statusWord = { authorized: 'granted', denied: 'denied', restricted: 'restricted', notDetermined: 'not asked yet' }

/**
 * What macOS has not let the daemon do, said where the missing streams
 * would be. `GET /streams` reports it for exactly this (PROTOCOL). Screen
 * Recording takes effect on the daemon's next launch, so the nudge under
 * Displays offers a relaunch when the daemon is ours, and says to relaunch
 * it when it is not.
 */
export function nudge(kind, permissions, ours) {
  if (!permissions) return null
  const p = permissions
  if (kind === 'display' && p.screen !== 'authorized') {
    return {
      capability: 'Screen Recording', status: statusWord[p.screen] || p.screen, pane: 'Privacy_ScreenCapture',
      consequence: ours
        ? 'displays and windows are not listed; relaunch the daemon once granted'
        : 'displays and windows are not listed; grant it, then relaunch the daemon',
      relaunch: ours,
    }
  }
  if (kind === 'camera' && (p.camera === 'denied' || p.camera === 'restricted')) {
    return { capability: 'Camera', status: statusWord[p.camera], pane: 'Privacy_Camera', consequence: 'arming a camera will fail' }
  }
  if (kind === 'microphone' && (p.microphone === 'denied' || p.microphone === 'restricted')) {
    return { capability: 'Microphone', status: statusWord[p.microphone], pane: 'Privacy_Microphone', consequence: 'arming a microphone will fail' }
  }
  return null
}

/**
 * Twelve cells over the useful range: below −60 dBFS is silence for our
 * purposes and clipping pins at the top, the way a console meter reads.
 * No reading is no cells, never an empty bar pretending to be silence.
 */
export const meterCells = db => (db == null ? 0 : Math.max(0, Math.min(12, Math.floor(((db + 60) / 60) * 12))))

/** `3f9a1c…a2b3c4`: enough to compare, not enough to use. */
export const maskToken = t => (!t || t.length <= 12 ? t : `${t.slice(0, 6)}…${t.slice(-6)}`)

/** Streams in the active take and still writing: joined and not left. */
export const writingIds = state =>
  isRecording(state) ? state.take.streams.filter(s => s.started && !s.stopped).map(s => s.id) : []

export const isOver = take => !!take && (take.state === 'complete' || take.state === 'incomplete')

/** Seconds since the cue, to now or to the stop; null before the cue. */
export function elapsed(take, now = Date.now()) {
  if (!take || !take.started) return null
  const end = take.stopped ? Date.parse(take.stopped) : now
  return Math.max(0, (end - Date.parse(take.started)) / 1000)
}

/** `h:mm:ss` from the cue — what a tape counter says. */
export function clock(seconds) {
  const total = Math.floor(seconds)
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60
  const two = n => String(n).padStart(2, '0')
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${two(m)}:${two(s)}`
}

/**
 * Streams that joined more than a second after the cue, by position among
 * the take's first four — what the mark draws as a shorter stroke (BRAND §
 * Mark). The same rule as IconState::lateJoined, so header and menu bar agree.
 */
export function lateJoined(take) {
  if (!take || !take.started) return []
  const cue = Date.parse(take.started)
  return (take.streams || []).slice(0, 4)
    .map((s, i) => (s.started && Date.parse(s.started) - cue > 1000 ? i : -1))
    .filter(i => i >= 0)
}

/** The finished line: name · state · elapsed · n files — reason. */
export function finishedLine(take, now = Date.now()) {
  const parts = [take.name || take.id, take.state]
  const e = elapsed(take, now)
  if (e != null) parts.push(clock(e))
  parts.push(`${(take.streams || []).length} file${(take.streams || []).length === 1 ? '' : 's'}`)
  return { text: parts.join(' · '), reason: take.reason || null, complete: take.state === 'complete' }
}

// MARK: - formatting

/** Decimal units, one decimal: what Finder says. */
export function bytes(count) {
  const gb = count / 1e9
  if (gb >= 1000) return `${(gb / 1000).toFixed(2)} TB`
  if (gb >= 1) return `${gb.toFixed(1)} GB`
  return `${Math.round(gb * 1000)} MB`
}

export const abbreviate = (path, home) =>
  home && path && path.startsWith(home) ? '~' + path.slice(home.length) : path
