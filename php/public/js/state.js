/*
 * The popover's state, as pure functions — what the event stream and the
 * pulse say, reduced to what the page shows. No DOM here, so the parsing
 * and the derivations can be tested without a browser.
 */

/** One decoded event: the whole object, which always names its kind in `event`. */
export function decodeEvent(text) {
  let json
  try { json = JSON.parse(text) } catch { return null }
  return json && typeof json.event === 'string' ? json : null
}

/** Apply one event to the state; returns a new state. */
export function reduce(state, event) {
  switch (event.event) {
    case 'stream': {
      const s = event.stream
      if (!s || !s.id) return state
      const streams = state.streams.some(x => x.id === s.id)
        ? state.streams.map(x => (x.id === s.id ? s : x))
        : [...state.streams, s]
      return { ...state, streams }
    }
    case 'take':
      return event.take && event.take.state ? { ...state, take: event.take } : state
    default:
      return state
  }
}

export const armedCount = state => state.streams.filter(s => s.armed).length
export const isRecording = state => !!state.take && state.take.state === 'recording'

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

/** Decimal units, one decimal: what Finder says. */
export function bytes(count) {
  const gb = count / 1e9
  if (gb >= 1000) return `${(gb / 1000).toFixed(2)} TB`
  if (gb >= 1) return `${gb.toFixed(1)} GB`
  return `${Math.round(gb * 1000)} MB`
}

export const abbreviate = (path, home) =>
  home && path && path.startsWith(home) ? '~' + path.slice(home.length) : path
