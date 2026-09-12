/*
 * The popover. Holds the daemon's event stream itself (brief, rule 2) and
 * reads GET / from the daemon directly on the pulse; asks PHP only for the
 * daemon's lifecycle — which rheo:watch publishes — and for clicks.
 */
import { decodeEvent, reduce, headline, bytes, abbreviate } from './state.js'

const R = window.RHEO
const $ = id => document.getElementById(id)
const csrf = document.querySelector('meta[name=csrf-token]').content

let daemon = R.daemon || { status: 'launching' }
let discovery = daemon.discovery || null
let state = { streams: [], take: null }
let source = null
let lastError = ''

const PULSE = 3000

function php(method, path, body) {
  return fetch(path, {
    method,
    headers: { 'Content-Type': 'application/json', 'X-CSRF-TOKEN': csrf, Accept: 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }).then(r => r.json())
}

/** The daemon, directly. Loopback; the token is the lock, not the origin. */
function core(path) {
  return fetch(R.base + path, { headers: { Authorization: `Bearer ${R.token}`, Accept: 'application/json' } })
}

// MARK: - render

function render() {
  const h = headline(daemon, state)
  $('mark').dataset.tone = h.tone
  $('state').dataset.tone = h.tone
  $('state-label').textContent = h.label

  $('panel-launching').hidden = daemon.status !== 'launching'
  $('panel-down').hidden = daemon.status !== 'down'
  $('panel-running').hidden = daemon.status !== 'running'

  if (daemon.status === 'down') {
    $('why').textContent = daemon.why || ''
    $('log-path').textContent = abbreviate(daemon.log || '', R.home)
  }
  if (daemon.status === 'running') renderDiscovery()
  $('error').textContent = lastError
}

/** GET / as a list — task 1's centre. Absent values in the colour of absence. */
function renderDiscovery() {
  const d = discovery
  const rows = d
    ? [
        ['name', d.name], ['version', d.version], ['hostname', d.hostname], ['machine id', d.machineId],
        ['output root', abbreviate(d.outputRoot, R.home)],
        ['free', d.freeBytes === undefined ? null : `${bytes(d.freeBytes)} (${d.freeBytes.toLocaleString()} B)`],
        ['auth', d.auth], ['ports', d.ports ? `http ${d.ports.http} · ws ${d.ports.ws}` : null],
      ]
    : []
  const list = $('discovery')
  list.replaceChildren()
  const h = document.createElement('div')
  h.className = 'section'
  h.textContent = 'GET /'
  list.append(h)
  if (!d) {
    const e = document.createElement('div')
    e.className = 'empty'
    e.textContent = 'No answer to GET / yet.'
    list.append(e)
  }
  for (const [k, v] of rows) {
    const row = document.createElement('div')
    row.className = 'field'
    const b = document.createElement('b'); b.textContent = k
    const s = document.createElement('span'); s.textContent = v ?? '··'
    if (v == null) s.className = 'absent'
    row.append(b, s)
    list.append(row)
  }

  $('strip-version').textContent = `rheocles-core ${d ? d.version : '··'}`
  $('strip-owner').textContent = daemon.ours ? 'ours' : 'shared'
  const free = $('strip-free')
  free.textContent = d && d.freeBytes !== undefined ? `${bytes(d.freeBytes)} free` : 'free ··'
  free.classList.toggle('absent', !(d && d.freeBytes !== undefined))
  $('strip-root').textContent = d ? abbreviate(d.outputRoot, R.home) : '··'
}

// MARK: - the pulse

async function pulse() {
  try {
    daemon = await php('GET', '/daemon')
  } catch (e) {
    // PHP itself is not answering; keep what we had.
  }
  if (daemon.status === 'running') {
    // The token file appears when a launched core first answers; a page
    // rendered before that has no events URL. Once, start over with one.
    if (!R.token) { location.reload(); return }
    try {
      const r = await core('/')
      if (r.ok) {
        discovery = await r.json()
        lastError = ''
      } else if (r.status === 401) {
        // The token rotated under us; PHP re-reads the file on render.
        location.reload(); return
      } else {
        const body = await r.json().catch(() => ({}))
        lastError = `GET / → ${r.status} ${body.code || ''}: ${body.error || ''}`
      }
    } catch (e) {
      lastError = `GET / → unreachable`
    }
    listen()
  } else {
    discovery = null
    unlisten()
  }
  render()
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
  state = { streams: [], take: null }
}

// MARK: - clicks

$('quit').addEventListener('click', () => php('POST', '/quit'))
$('relaunch').addEventListener('click', async () => {
  await php('POST', '/daemon/relaunch')
  daemon = { ...daemon, status: 'launching', why: null }
  render()
})
$('gear').addEventListener('click', () => {
  // Settings arrive with task 4.
})

render()
pulse()
setInterval(pulse, PULSE)
