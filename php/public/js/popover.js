/*
 * The popover. Holds the daemon's event stream itself (brief, rule 2) and
 * reads GET / and GET /streams from the daemon directly on the pulse; asks
 * PHP only for the daemon's lifecycle — which rheo:watch publishes — and
 * for clicks.
 */
import {
  decodeEvent, reduce, initial, setStreams, headline, sections, detail, writingIds, bytes, abbreviate,
} from './state.js'

const R = window.RHEO
const $ = id => document.getElementById(id)
const csrf = document.querySelector('meta[name=csrf-token]').content

let daemon = R.daemon || { status: 'launching' }
let discovery = daemon.discovery || null
let state = initial()
let preferences = R.preferences || { showWindows: false, codec: 'hevc' }
let source = null
/** What the pulse could not read — cleared by the next pulse that can. */
let pulseError = ''
/** A call the daemon refused, in the daemon's words — cleared by the next call. */
let clickError = ''
/** One POST /streams/{id}/arm in flight: the switch shows what was asked for. */
let pending = null
let showSettings = false

const PULSE = 3000

function php(method, path, body) {
  return fetch(path, {
    method,
    headers: { 'Content-Type': 'application/json', 'X-CSRF-TOKEN': csrf, Accept: 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }).then(async r => ({ ok: r.ok, status: r.status, body: await r.json().catch(() => ({})) }))
}

/** The daemon, directly. Loopback; the token is the lock, not the origin. */
function core(path) {
  return fetch(R.base + path, { headers: { Authorization: `Bearer ${R.token}`, Accept: 'application/json' } })
}

// MARK: - render

const el = (tag, cls, text) => {
  const n = document.createElement(tag)
  if (cls) n.className = cls
  if (text !== undefined) n.textContent = text
  return n
}

function render() {
  const h = headline(daemon, state)
  $('mark').dataset.tone = h.tone
  $('state').dataset.tone = h.tone
  $('state-label').textContent = h.label
  $('gear').setAttribute('aria-pressed', String(showSettings))

  $('panel-launching').hidden = daemon.status !== 'launching'
  $('panel-down').hidden = daemon.status !== 'down'
  $('panel-running').hidden = daemon.status !== 'running'

  if (daemon.status === 'down') {
    $('why').textContent = daemon.why || ''
    $('log-path').textContent = abbreviate(daemon.log || '', R.home)
  }
  if (daemon.status === 'running') {
    $('streams').hidden = showSettings
    $('settings').hidden = !showSettings
    if (showSettings) renderSettings()
    else renderStreams()
    renderTakeBar()
    renderStrip()
  }
  $('error').textContent = clickError || pulseError
  fit()
}

/** Every stream, grouped by kind in the daemon's order, each with its arm switch. */
function renderStreams() {
  const list = $('streams')
  list.replaceChildren()
  const writing = writingIds(state)
  const groups = sections(state.streams, preferences.showWindows, state.permissions, daemon.ours)
  for (const g of groups) {
    list.append(el('div', 'section', g.heading))
    for (const s of g.members) list.append(row(s, writing.includes(s.id)))
    if (g.nudge) list.append(nudgeView(g.nudge))
  }
  if (state.streams.length === 0 && !state.permissions) {
    list.append(el('div', 'empty', 'No answer to GET /streams yet.'))
  }
}

/**
 * One stream. Armed is unmistakable: the row's name, its switch and a bar
 * down its left edge all go ochre — the colour of a device that is live,
 * held, and costing CPU. Writing in the active take goes oxide.
 */
function row(s, writing) {
  const shownArmed = pending && pending.id === s.id ? pending.armed : !!s.armed
  const r = el('div', 'stream')
  r.dataset.armed = String(shownArmed)
  if (writing) r.dataset.writing = 'true'

  r.append(el('i', 'bar'))
  r.append(glyph(s.kind))

  const text = el('div', 'text')
  text.append(el('div', 'name', s.name))
  const sub = el('div', 'sub')
  sub.append(el('span', 'detail', detail(s)))
  if (s.armed && s.capabilities && s.capabilities.audio) sub.append(meter(null))
  text.append(sub)
  r.append(text)

  if (s.capabilities && s.capabilities.video) {
    const eye = el('button', 'eye')
    eye.setAttribute('aria-label', 'Preview')
    eye.title = 'Preview'
    eye.innerHTML = EYE
    r.append(eye)  // Preview on demand arrives with task 4; the eye keeps its place.
  }

  const sw = el('button', 'switch')
  sw.setAttribute('role', 'switch')
  sw.setAttribute('aria-checked', String(shownArmed))
  sw.setAttribute('aria-label', shownArmed ? 'Disarm' : 'Arm')
  sw.disabled = !!pending && pending.id === s.id
  sw.append(el('i', 'knob'))
  sw.addEventListener('click', () => arm(s.id, !shownArmed))
  r.append(sw)
  return r
}

/**
 * Twelve cells over the useful range. No reading yet is no cells and `··`,
 * never an empty bar pretending to be silence. Levels arrive with task 4.
 */
function meter(db) {
  const m = el('span', 'meter')
  const cells = el('span', 'cells')
  const filled = db == null ? 0 : Math.max(0, Math.min(12, Math.floor(((db + 60) / 60) * 12)))
  for (let i = 0; i < 12; i++) {
    const c = el('i')
    if (i < filled) c.dataset.on = i >= 11 ? 'clip' : 'on'
    cells.append(c)
  }
  m.append(cells)
  const n = el('span', 'db', db == null ? '··' : String(Math.round(db)))
  if (db == null) n.classList.add('absent')
  m.append(n)
  return m
}

/** A grant that is missing, and the one click that fixes it. */
function nudgeView(n) {
  const v = el('div', 'nudge')
  v.append(el('p', 'prose soft', `${n.capability}: ${n.status} — ${n.consequence}.`))
  const actions = el('div', 'actions')
  const open = el('button', 'btn', 'Open Privacy settings')
  open.addEventListener('click', () => php('POST', '/api/privacy', { pane: n.pane }))
  actions.append(open)
  if (n.relaunch) {
    const relaunch = el('button', 'btn', 'Relaunch daemon')
    relaunch.addEventListener('click', () => php('POST', '/daemon/relaunch'))
    actions.append(relaunch)
  }
  v.append(actions)
  return v
}

/** Settings, in place of the list. Show windows now; the rest with task 4. */
function renderSettings() {
  const box = $('settings')
  box.replaceChildren()

  const windows = el('div', 'row')
  windows.append(el('div', 'section', 'Windows'))
  const label = el('label', 'check')
  const cb = el('input')
  cb.type = 'checkbox'
  cb.checked = !!preferences.showWindows
  cb.addEventListener('change', () => setPreference({ showWindows: cb.checked }))
  label.append(cb, el('span', 'box'), el('span', 'text', 'Show windows in the stream list'))
  windows.append(label)
  windows.append(el('p', 'prose', 'Long and volatile, so hidden unless asked for.'))
  box.append(windows)

  box.append(el('div', 'rule inset'))
  box.append(el('p', 'prose script pad', 'Output root, codec and the pairing code arrive with task 4.'))
}

/** Record or Stop, the take's name, and the time since the cue (task 3). The disabled pill keeps its place. */
function renderTakeBar() {
  const n = state.streams.filter(s => s.armed).length
  $('takebar-note').textContent = n === 0 ? 'Arm a stream to record.' : `${n} armed · Record arrives with task 3.`
}

/** GET / under the streams: the daemon is answering, its version, whose it is, how much room there is. */
function renderStrip() {
  const d = discovery
  $('strip-version').textContent = `rheocles-core ${d ? d.version : '··'}`
  $('strip-owner').textContent = daemon.ours ? 'ours' : 'shared'
  const free = $('strip-free')
  free.textContent = d && d.freeBytes !== undefined ? `${bytes(d.freeBytes)} free` : 'free ··'
  free.classList.toggle('absent', !(d && d.freeBytes !== undefined))
  $('strip-root').textContent = d ? abbreviate(d.outputRoot, R.home) : '··'
}

/**
 * The popover is content-sized, as the Swift one is. The list has a cap
 * (392, the Swift list's) and scrolls beyond it; everything else is as tall
 * as it is, and the window is asked to fit — once per change.
 */
let fitted = 0
function fit() {
  const want = Math.min(720, Math.max(160, Math.ceil(document.body.scrollHeight)))
  if (Math.abs(want - fitted) < 2) return
  fitted = want
  php('POST', '/api/resize', { height: want })
}

// MARK: - the pulse

async function pulse() {
  try {
    const r = await php('GET', '/daemon')
    if (r.ok) daemon = r.body
  } catch {
    // PHP itself is not answering; keep what we had.
  }
  if (daemon.status === 'running') {
    // The token file appears when a launched core first answers; a page
    // rendered before that has no events URL. Once, start over with one.
    if (!R.token) { location.reload(); return }
    pulseError = ''
    await Promise.all([readDiscovery(), readStreams()])
    listen()
  } else {
    discovery = null
    unlisten()
  }
  render()
}

async function readDiscovery() {
  try {
    const r = await core('/')
    if (r.ok) { discovery = await r.json(); return }
    if (r.status === 401) { location.reload(); return }  // rotated under us; PHP re-reads the file
    const body = await r.json().catch(() => ({}))
    pulseError = `GET / → ${r.status} ${body.code || ''}: ${body.error || ''}`
  } catch (e) {
    pulseError = `GET / → unreachable (${e.message})`
  }
}

/** Re-read the list. A failure here is not a daemon failure — GET / just succeeded — so it is shown, not acted on. */
async function readStreams() {
  try {
    const r = await core('/streams')
    if (r.ok) { state = setStreams(state, await r.json()); return }
    const body = await r.json().catch(() => ({}))
    pulseError = `GET /streams → ${r.status} ${body.code || ''}: ${body.error || ''}`
  } catch (e) {
    pulseError = `GET /streams → unreachable (${e.message})`
  }
}

// MARK: - events

/** One EventSource for as long as the daemon is up; the browser reconnects. */
function listen() {
  if (source || !R.events) return
  source = new EventSource(R.events)
  source.onmessage = e => {
    const event = decodeEvent(e.data)
    if (!event) return
    state = reduce(state, event)
    render()
  }
  source.onerror = () => {
    // EventSource retries on its own; the pulse decides whether the daemon
    // is gone. Nothing to do here but keep the last state.
  }
}

function unlisten() {
  if (source) { source.close(); source = null }
  state = initial()
}

// MARK: - clicks

/**
 * Arm or disarm one stream (spec §6): device live or not, never a write.
 * Optimistic in the switch only; the list is the daemon's, re-read after
 * the answer. A refusal is shown in the daemon's words.
 */
async function arm(id, armed) {
  if (pending) return
  pending = { id, armed }
  clickError = ''
  render()
  const r = await php('POST', `/api/streams/${encodeURIComponent(id)}/arm`, { armed })
  if (!r.ok) clickError = `POST /streams/${id}/arm → ${r.status} ${r.body.code || ''}: ${r.body.error || ''}`
  await readStreams()
  pending = null
  render()
}

async function setPreference(values) {
  const r = await php('POST', '/api/preferences', values)
  if (r.ok) preferences = r.body
  render()
}

$('quit').addEventListener('click', () => php('POST', '/quit'))
$('relaunch').addEventListener('click', async () => {
  await php('POST', '/daemon/relaunch')
  daemon = { ...daemon, status: 'launching', why: null }
  render()
})
$('gear').addEventListener('click', () => { showSettings = !showSettings; render() })
// ⌘R reloads the page — the menu bar window is not in NativePHP's window
// table, so nothing else can, and a stale page otherwise needs an app restart.
document.addEventListener('keydown', e => { if (e.metaKey && e.key === 'r') location.reload() })

// MARK: - glyphs, drawn from lines so they are the ink's colour and no other

const ICONS = {
  display: '<rect x="2" y="3.5" width="20" height="13" rx="1.5"/><path d="M8 20.5h8M12 16.5v4"/>',
  window: '<rect x="2" y="4" width="20" height="16" rx="1.5"/><path d="M2 9h20"/>',
  camera: '<rect x="2" y="6" width="14" height="12" rx="1.5"/><path d="M16 10l6-3v10l-6-3z"/>',
  microphone: '<rect x="9" y="2.5" width="6" height="11" rx="3"/><path d="M5 10.5a7 7 0 0 0 14 0M12 17.5v4M8.5 21.5h7"/>',
  systemAudio: '<path d="M3 9.5v5h4l5 4v-13l-5 4z"/><path d="M15.5 9a4 4 0 0 1 0 6M18.5 6.5a8 8 0 0 1 0 11"/>',
}
const EYE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1.5 12s4-7 10.5-7 10.5 7 10.5 7-4 7-10.5 7S1.5 12 1.5 12z"/><circle cx="12" cy="12" r="3"/></svg>'

function glyph(kind) {
  const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
  s.setAttribute('viewBox', '0 0 24 24')
  s.setAttribute('class', 'glyph')
  s.innerHTML = ICONS[kind] || ICONS.display
  return s
}

render()
pulse()
setInterval(pulse, PULSE)
