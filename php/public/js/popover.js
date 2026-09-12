/*
 * The popover. Holds the daemon's event stream itself (brief, rule 2) and
 * reads GET / and GET /streams from the daemon directly on the pulse; asks
 * PHP only for the daemon's lifecycle — which rheo:watch publishes — and
 * for clicks.
 */
import {
  decodeEvent, reduce, initial, setStreams, headline, sections, detail, writingIds, bytes, abbreviate,
  isRecording, isOver, elapsed, clock, lateJoined, finishedLine, meterCells, maskToken,
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
/** A take call in flight: Record, Stop and Mark are one at a time. */
let takeBusy = false
/** Ticks once a second while a take is recording, so the elapsed time moves. */
let ticker = null
/** The one stream being previewed, if any (spec §12: one at a time). */
let previewing = null
let previewTimer = null
let previewFrame = null   // an object URL for the last JPEG
let previewError = null
/** The pairing code shown in full, or masked; Rotate armed for a second click. */
let tokenShown = false
let rotateArmed = false
let rotateTimer = null
let settingsError = ''

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
  renderMark()
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

/**
 * The header's mark: solid strokes; recording stops the bar short and lights
 * the dot at its foot; a late-joined stream is a shorter stroke that starts
 * to the right of the bar — the same drawing as the menu bar icon.
 */
function renderMark() {
  const recording = daemon.status === 'running' && isRecording(state)
  $('mark-bar').setAttribute('d', recording ? 'M5 4 V25' : 'M5 4 V28')
  $('mark-dot').hidden = !recording
  const late = recording ? lateJoined(state.take) : []
  document.querySelectorAll('#mark .stroke').forEach((p, i) => {
    p.setAttribute('d', late.includes(i) ? p.dataset.late : p.dataset.cue)
  })
}

/** Every stream, grouped by kind in the daemon's order, each with its arm switch. */
function renderStreams() {
  const list = $('streams')
  list.replaceChildren()
  const writing = writingIds(state)
  const groups = sections(state.streams, preferences.showWindows, state.permissions, daemon.ours)
  for (const g of groups) {
    list.append(el('div', 'section', g.heading))
    for (const s of g.members) {
      list.append(row(s, writing.includes(s.id)))
      if (previewing === s.id && s.capabilities && s.capabilities.video) list.append(previewPane())
    }
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
  const audio = !!(s.capabilities && s.capabilities.audio)
  // Levels flow only while armed (or sampled while previewing); before the
  // first reading the meter is empty and the number is absent.
  if (audio && (s.armed || previewing === s.id)) sub.append(meter(s.id, state.levels[s.id]))
  text.append(sub)
  r.append(text)

  // The eye (video) or the ear (audio): preview this stream, one at a time.
  const on = previewing === s.id
  const btn = el('button', 'eye')
  btn.setAttribute('aria-label', on ? 'Stop preview' : 'Preview')
  btn.setAttribute('aria-pressed', String(on))
  btn.innerHTML = audio ? EAR : EYE
  btn.addEventListener('click', () => togglePreview(s.id))
  r.append(btn)

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
function meter(id, db) {
  const m = el('span', 'meter')
  m.dataset.id = id
  const cells = el('span', 'cells')
  for (let i = 0; i < 12; i++) cells.append(el('i'))
  m.append(cells, el('span', 'db'))
  setMeter(m, db)
  return m
}

function setMeter(m, db) {
  const filled = meterCells(db)
  m.querySelectorAll('.cells i').forEach((c, i) => {
    if (i < filled) c.dataset.on = i >= 11 ? 'clip' : 'on'
    else delete c.dataset.on
  })
  const n = m.querySelector('.db')
  n.textContent = db == null ? '··' : String(Math.round(db))
  n.classList.toggle('absent', db == null)
}

/** `levels` arrive ~4×/s while recording: move the meters, not the list. */
function updateMeters() {
  document.querySelectorAll('.meter[data-id]').forEach(m => setMeter(m, state.levels[m.dataset.id]))
}

/**
 * The preview frame, under the row it belongs to. 16:9 at the popover's
 * width; a frame of another shape letterboxes on the code-block ground.
 */
function previewPane() {
  const pane = el('div', 'preview')
  if (previewFrame) {
    const img = el('img')
    img.src = previewFrame
    img.alt = ''
    pane.append(img)
  } else if (previewError) {
    pane.append(el('span', 'preview-error', previewError))
  } else {
    pane.append(el('span', 'preview-wait', 'waiting for a frame'))
  }
  return pane
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

/**
 * Settings, in place of the list (spec §12): output root, codec, show
 * windows, the bearer token as a pairing code. Every row says whose setting
 * it is: the output root, the codec and the token are the daemon's,
 * changed over PATCH /settings and POST /token/rotate and shown as the
 * daemon last answered; show windows is the app's. A refusal — the root
 * cannot move under an active take — is shown in the daemon's words.
 */
function renderSettings() {
  const box = $('settings')
  box.replaceChildren()
  const st = state.settings

  const root = section('Output root')
  const rootRow = el('div', 'setting-row')
  const rootText = el('span', 'mono-value', st ? abbreviate(st.outputRoot, R.home) : '··')
  if (!st) rootText.classList.add('absent')
  rootRow.append(rootText, el('span', 'spacer'))
  const change = el('button', 'btn', 'Change…')
  change.disabled = !st
  change.addEventListener('click', chooseRoot)
  const reveal = el('button', 'btn', 'Reveal')
  reveal.disabled = !st
  reveal.addEventListener('click', () => php('POST', '/api/settings/reveal'))
  rootRow.append(change, reveal)
  root.append(rootRow, note('Where new takes land. Cannot move while a take is active.'))
  box.append(root, rule())

  const codec = section('Codec')
  codec.append(segmented([['hevc', 'HEVC'], ['prores', 'ProRes 422']], st ? st.codec : null, v => updateSettings({ codec: v })))
  codec.append(note("The daemon's default for every take. Video only; audio is always Broadcast Wave."))
  box.append(codec, rule())

  const windows = section('Windows')
  const label = el('label', 'check')
  const cb = el('input')
  cb.type = 'checkbox'
  cb.checked = !!preferences.showWindows
  cb.addEventListener('change', () => setPreference({ showWindows: cb.checked }))
  label.append(cb, el('span', 'box'), el('span', 'text', 'Show windows in the stream list'))
  windows.append(label, note('Long and volatile, so hidden unless asked for.'))
  box.append(windows, rule())

  const pairing = section('Pairing code')
  const tokRow = el('div', 'setting-row')
  const tok = el('span', 'mono-value token', R.token ? (tokenShown ? R.token : maskToken(R.token)) : '··')
  if (tokenShown) tok.classList.add('full')
  if (!R.token) tok.classList.add('absent')
  tokRow.append(tok, el('span', 'spacer'))
  const show = el('button', 'btn', tokenShown ? 'Hide' : 'Show')
  show.addEventListener('click', () => { tokenShown = !tokenShown; render() })
  const copy = el('button', 'btn', 'Copy')
  copy.addEventListener('click', () => php('POST', '/api/token/copy'))
  const rotate = el('button', rotateArmed ? 'btn oxide filled' : 'btn oxide', rotateArmed ? 'Rotate now' : 'Rotate')
  rotate.addEventListener('click', rotateToken)
  tokRow.append(show, copy, rotate)
  pairing.append(tokRow, note(rotateArmed
    ? 'Click again to rotate. Every other paired client loses access until it reads the new token from the file.'
    : `The bearer token, from ${abbreviate(R.tokenFile, R.home)}. Rotating invalidates the old one at once.`))
  box.append(pairing)

  if (settingsError) box.append(el('p', 'settings-error', settingsError))
}

const section = title => { const d = el('div', 'row'); d.append(el('div', 'section', title)); return d }
const note = text => el('p', 'prose', text)
const rule = () => el('div', 'rule inset')

/** A two-way choice drawn from shapes: the site's pill, split. */
function segmented(options, selected, onPick) {
  const g = el('div', 'segmented')
  for (const [value, label] of options) {
    const b = el('button', 'seg', label)
    b.setAttribute('aria-pressed', String(value === selected))
    b.disabled = selected == null
    b.addEventListener('click', () => { if (value !== selected) onPick(value) })
    g.append(b)
  }
  return g
}

/**
 * Record or Stop, the take's name, and the time since the cue (spec §12).
 *
 * One button (spec §7). Record is POST /record — create and start in one —
 * and is only offered when something is armed, because a take with no
 * streams is a folder with a manifest in it. While recording the bar turns
 * oxide and counts; afterwards it says what the take became, in olive if
 * complete and oxide with the reason if not.
 */
function renderTakeBar() {
  const take = state.take
  const recording = isRecording(state)
  const armed = state.streams.filter(s => s.armed).length
  const canRecord = armed > 0 && !takeBusy
  $('takebar').dataset.recording = String(recording)

  $('record').hidden = recording
  $('record').disabled = !canRecord
  $('stop').hidden = !recording
  $('stop').disabled = takeBusy
  $('takebar-note').hidden = recording || armed > 0
  $('take-name').hidden = recording || armed === 0 || isOver(take)
  $('live').hidden = !recording
  $('finished').hidden = recording || !isOver(take)
  $('markers').hidden = !recording

  if (recording) {
    $('live-name').textContent = take.name || '··'
    const e = elapsed(take)
    $('live-elapsed').textContent = e == null ? '··:··' : clock(e)
    $('live-writing').textContent = `${writingIds(state).length} writing`
    const n = (take.markers || []).length
    $('marker-count').textContent = n === 0 ? 'no markers' : `${n} marker${n === 1 ? '' : 's'}`
    $('marker-count').classList.toggle('absent', n === 0)
  } else if (isOver(take)) {
    const f = finishedLine(take)
    const box = $('finished')
    box.dataset.complete = String(f.complete)
    const text = $('finished-text')
    text.replaceChildren()
    // Two lines at most, breaking only between parts: "2 files" and the
    // name hold together (non-breaking spaces), the separators do not.
    const nb = t => t.replace(/ /g, '\u00a0')
    const [name, word, ...rest] = f.text.split(' · ')
    text.append(el('span', 'name', nb(name)), ' · ', el('span', 'state-word', word))
    for (const part of rest) text.append(' · ', nb(part))
    if (f.reason) text.append(' — ', el('span', 'reason', f.reason))
  }
  tick(recording)
}

/** The one-second tick while recording; idle otherwise. */
function tick(recording) {
  if (recording && !ticker) {
    ticker = setInterval(() => {
      if (!isRecording(state)) return
      const e = elapsed(state.take)
      $('live-elapsed').textContent = e == null ? '··:··' : clock(e)
    }, 1000)
  } else if (!recording && ticker) {
    clearInterval(ticker)
    ticker = null
  }
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
    await Promise.all([readDiscovery(), readStreams(), discoverTake(), readSettings()])
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

/** `GET /settings`, the daemon's; `settings` events keep it current between pulses. */
async function readSettings() {
  try {
    const r = await core('/settings')
    if (r.ok) state = { ...state, settings: await r.json() }
  } catch {
    // Reported by the other reads.
  }
}

/**
 * Find a take that is recording — one started by another client, or one
 * that was running when the popover opened — and keep the active one
 * current. Events carry the rest; this is the fallback.
 */
async function discoverTake() {
  try {
    if (isRecording(state)) {
      const r = await core(`/takes/${state.take.id}`)
      if (r.ok) state = { ...state, take: await r.json() }
      return
    }
    const r = await core('/takes')
    if (!r.ok) return
    const active = (await r.json()).find(t => t.state === 'recording')
    if (active && (!state.take || state.take.id !== active.id)) {
      const m = await core(`/takes/${active.id}`)
      if (m.ok) state = { ...state, take: await m.json() }
    }
  } catch {
    // The pulse's other reads report; this one is best effort.
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
    // Only a state that moved is worth a render; `levels` (~4×/s while
    // recording) move the meters in place and nothing else.
    const next = reduce(state, event)
    if (next === state) return
    state = next
    if (event.event === 'levels') { updateMeters(); return }
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

/** Record: create and start in one — the popover's one button (spec §7). */
async function record() {
  if (takeBusy) return
  takeBusy = true
  clickError = ''
  render()
  const r = await php('POST', '/api/record', { name: $('take-name').value })
  if (r.ok) {
    state = { ...state, take: r.body.take }
    $('take-name').value = ''
  } else {
    clickError = `POST /record → ${r.status} ${r.body.code || ''}: ${r.body.error || ''}`
  }
  takeBusy = false
  await readStreams()
  render()
}

/** Stop the active take; the manifest comes back final. */
async function stop() {
  if (takeBusy || !state.take) return
  takeBusy = true
  clickError = ''
  render()
  const id = state.take.id
  const r = await php('POST', `/api/takes/${encodeURIComponent(id)}/stop`)
  if (r.ok) state = { ...state, take: r.body }
  else clickError = `POST /takes/${id}/stop → ${r.status} ${r.body.code || ''}: ${r.body.error || ''}`
  takeBusy = false
  await readStreams()
  render()
}

/**
 * POST /takes/{id}/markers while recording (spec §10): Rheocles stamps `t`
 * from its own clock; the label is ours and it never reads it. The manifest
 * comes back with the marker on it.
 */
async function mark() {
  if (takeBusy || !isRecording(state)) return
  takeBusy = true
  clickError = ''
  const id = state.take.id
  const r = await php('POST', `/api/takes/${encodeURIComponent(id)}/markers`, {
    label: $('marker-label').value, count: (state.take.markers || []).length,
  })
  if (r.ok) { state = { ...state, take: r.body }; $('marker-label').value = '' }
  else clickError = `POST /takes/${id}/markers → ${r.status} ${r.body.code || ''}: ${r.body.error || ''}`
  takeBusy = false
  render()
}

// MARK: - preview

/**
 * Preview on demand, one stream at a time (spec §12): GET /preview/{id}
 * polled while the pane is open, and nothing at all when it is not — a
 * wall of thumbnails would be a wall of capture sessions. Video answers a
 * JPEG (longest side 640); audio answers `{ levelDb }`, a short sample's
 * peak, which feeds the row's meter so a microphone can be checked before
 * anything is armed. A refusal is shown in the daemon's words.
 */
const PREVIEW_INTERVAL = 250

function togglePreview(id) {
  if (previewing === id) stopPreview()
  else startPreview(id)
  render()
}

function startPreview(id) {
  stopPreview()
  previewing = id
  previewError = null
  const poll = async () => {
    if (previewing !== id) return
    let delay = PREVIEW_INTERVAL
    try {
      const r = await core(`/preview/${id}`)
      if (previewing !== id) return
      if (!r.ok) {
        const body = await r.json().catch(() => ({}))
        previewError = `GET /preview/${id} → ${r.status} ${body.code || ''}: ${body.error || ''}`
        delay = 2000  // a refusal will not change in 250 ms
        render()
      } else if ((r.headers.get('content-type') || '').startsWith('application/json')) {
        const sample = await r.json()
        state = { ...state, levels: { ...state.levels, [id]: sample.levelDb } }
        previewError = null
        updateMeters()
      } else {
        const blob = await r.blob()
        const url = URL.createObjectURL(blob)
        const first = !previewFrame
        if (previewFrame) URL.revokeObjectURL(previewFrame)
        previewFrame = url
        previewError = null
        if (first) render()
        else { const img = document.querySelector('.preview img'); if (img) img.src = url }
      }
    } catch (e) {
      previewError = `GET /preview/${id} → unreachable`
      delay = 2000
      render()
    }
    previewTimer = setTimeout(poll, delay)
  }
  poll()
}

function stopPreview() {
  if (previewTimer) { clearTimeout(previewTimer); previewTimer = null }
  if (previewing && !isRecording(state)) {
    // The sampled level is stale the moment sampling stops.
    const levels = { ...state.levels }
    delete levels[previewing]
    state = { ...state, levels }
  }
  previewing = null
  if (previewFrame) { URL.revokeObjectURL(previewFrame); previewFrame = null }
  previewError = null
}

// MARK: - settings

async function updateSettings(changes) {
  settingsError = ''
  const r = await php('PATCH', '/api/settings', changes)
  if (r.ok) state = { ...state, settings: r.body }
  else settingsError = `PATCH /settings → ${r.status} ${r.body.code || ''}: ${r.body.error || ''}`
  render()
}

/** Change…: a native folder chooser, then PATCH. Cancel changes nothing. */
async function chooseRoot() {
  settingsError = ''
  const r = await php('POST', '/api/settings/choose-root')
  if (r.ok && r.body && r.body.outputRoot) state = { ...state, settings: r.body }
  else if (!r.ok) settingsError = `PATCH /settings → ${r.status} ${r.body.code || ''}: ${r.body.error || ''}`
  render()
}

/**
 * POST /token/rotate: the daemon rewrites its file and the old token is
 * dead for every request after the answer — including this page's, which
 * reloads to read the file again; the watcher does the same on its next
 * 401. Every other paired client has to read the file again; that is what
 * rotation is for, and why it takes two clicks.
 */
async function rotateToken() {
  if (!rotateArmed) {
    rotateArmed = true
    clearTimeout(rotateTimer)
    rotateTimer = setTimeout(() => { rotateArmed = false; render() }, 6000)
    render()
    return
  }
  rotateArmed = false
  clearTimeout(rotateTimer)
  settingsError = ''
  const r = await php('POST', '/api/token/rotate')
  if (r.ok && r.body.token) { unlisten(); location.reload(); return }
  settingsError = `POST /token/rotate → ${r.status} ${r.body.code || ''}: ${r.body.error || ''}`
  render()
}

async function setPreference(values) {
  const r = await php('POST', '/api/preferences', values)
  if (r.ok) preferences = r.body
  render()
}

$('record').addEventListener('click', record)
$('stop').addEventListener('click', stop)
$('mark-button').addEventListener('click', mark)
$('take-name').addEventListener('keydown', e => { if (e.key === 'Enter' && !$('record').disabled) record() })
$('marker-label').addEventListener('keydown', e => { if (e.key === 'Enter') mark() })
$('quit').addEventListener('click', () => php('POST', '/quit'))
$('relaunch').addEventListener('click', async () => {
  await php('POST', '/daemon/relaunch')
  daemon = { ...daemon, status: 'launching', why: null }
  render()
})
$('gear').addEventListener('click', () => { showSettings = !showSettings; if (showSettings) stopPreview(); render() })
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
const EAR = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9.5a6 6 0 0 1 12 0c0 3-2 4-2.5 6-.4 1.6-1 3-3 3s-2.5-1.5-2.5-2.5"/><path d="M9.5 9.5a2.5 2.5 0 0 1 5 0c0 1.5-1.5 2-1.5 3.5"/></svg>'

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
