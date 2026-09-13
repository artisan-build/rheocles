import { describe, it, expect } from 'vitest'
import {
  initial, reduce, setStreams, setRecent, combineAvailable, combinedLine, canCombineNow, revealError, recentRow,
} from '../../public/js/state.js'

/* Open in Finder and the single file (feature brief §1, §2, addendum), the
 * pure part: when the box shows, what the line under the outcome says,
 * who gets Combine now, and what a refused reveal means. */

const mic = { id: 'microphone:m', kind: 'microphone', name: 'Mic', capabilities: { audio: { sampleRate: 48000, channels: 2 } } }
const mic2 = { id: 'microphone:n', kind: 'microphone', name: 'Mic 2', capabilities: { audio: { sampleRate: 48000, channels: 1 } } }
const cam = { id: 'camera:c', kind: 'camera', name: 'Cam', capabilities: { video: { width: 1920, height: 1080, maxFrameRate: 30 } } }
const win = { id: 'window:1', kind: 'window', name: 'Docs', capabilities: { video: { width: 1200, height: 900, maxFrameRate: 60 } } }
const armed = s => ({ ...s, armed: true })

describe('"Also save a single file"', () => {
  it('is shown only when something is armed and at most one of it is video', () => {
    expect(combineAvailable([])).toBe(false)
    expect(combineAvailable([mic, cam])).toBe(false)                      // nothing armed: nothing to record
    expect(combineAvailable([armed(mic)])).toBe(true)                     // audio only combines to an audio-only .mov
    expect(combineAvailable([armed(mic), armed(mic2)])).toBe(true)        // every mic its own track
    expect(combineAvailable([armed(cam)])).toBe(true)
    expect(combineAvailable([armed(cam), armed(mic), armed(mic2)])).toBe(true)
    expect(combineAvailable([armed(cam), armed(win)])).toBe(false)        // two videos: no single file to be
    expect(combineAvailable([armed(cam), armed(win), armed(mic)])).toBe(false)
    expect(combineAvailable([armed(cam), win, armed(mic)])).toBe(true)    // the second video is not armed
  })

  it('follows the daemon: settings.combine arrives on the settings event', () => {
    let s = reduce(initial(), { event: 'settings', settings: { outputRoot: '/r', codec: 'hevc', combine: true } })
    expect(s.settings.combine).toBe(true)
    s = reduce(s, { event: 'settings', settings: { outputRoot: '/r', codec: 'hevc', combine: false } })
    expect(s.settings.combine).toBe(false)
  })
})

describe('the single file line', () => {
  it('is absent when the take has no combined block', () => {
    expect(combinedLine(undefined)).toBeNull()
    expect(combinedLine(null)).toBeNull()
    expect(combinedLine({})).toBeNull()
  })
  it('pulses while pending, gets a folder when complete, says why when failed', () => {
    expect(combinedLine({ path: 'combined.mov', state: 'pending' }))
      .toEqual({ tone: 'pending', text: 'Single file · combined.mov', note: 'writing…', revealable: false, path: 'combined.mov' })
    expect(combinedLine({ path: 'combined.mov', state: 'complete' }))
      .toEqual({ tone: 'complete', text: 'Single file · combined.mov', note: null, revealable: true, path: 'combined.mov' })
    expect(combinedLine({ path: 'combined.mov', state: 'failed', reason: 'export failed: no video track' }))
      .toEqual({ tone: 'failed', text: 'Single file · combined.mov', note: 'export failed: no video track', revealable: false, path: 'combined.mov' })
    // A failure with no reason still says failed, never nothing.
    expect(combinedLine({ path: 'combined.mov', state: 'failed' }).note).toBe('failed')
  })
  it('moves on the take event, and the take itself stays what it was', () => {
    const done = { id: 't1', state: 'complete', streams: [], combined: { path: 'combined.mov', state: 'pending' } }
    let s = reduce(initial(), { event: 'take', take: done })
    expect(combinedLine(s.take.combined).tone).toBe('pending')
    s = reduce(s, { event: 'take', take: { ...done, combined: { path: 'combined.mov', state: 'failed', reason: 'daemon died' } } })
    expect(combinedLine(s.take.combined)).toMatchObject({ tone: 'failed', note: 'daemon died' })
    expect(s.take.state).toBe('complete')
  })
})

describe('Combine now', () => {
  const take = (state, streams, combined) => ({ id: 't', state, streams: streams.map(s => ({ id: s.id, kind: s.kind, format: s.capabilities })), combined })
  it('is offered on a finished take with no single file and at most one video', () => {
    expect(canCombineNow(take('complete', [cam, mic]))).toBe(true)
    expect(canCombineNow(take('incomplete', [cam, mic]))).toBe(true)       // a take that lost a stream is still worth one file
    expect(canCombineNow(take('complete', [mic, mic2]))).toBe(true)        // audio only
    expect(canCombineNow(take('complete', [cam, win]))).toBe(false)        // two videos
    expect(canCombineNow(take('complete', []))).toBe(false)                // nothing to combine
    expect(canCombineNow(take('recording', [cam, mic]))).toBe(false)
    expect(canCombineNow(take('created', [cam, mic]))).toBe(false)
    expect(canCombineNow(null)).toBe(false)
  })
  it('is hidden once a combined block exists, in any state', () => {
    for (const state of ['pending', 'complete', 'failed']) {
      expect(canCombineNow(take('complete', [cam, mic], { path: 'combined.mov', state }))).toBe(false)
    }
  })
})

describe('recent takes', () => {
  const list = [
    { id: 'b', name: 'Two', state: 'complete', created: '2026-09-12T04:04:33.235Z', destination: 'takes/b', streams: 2, combined: { path: 'combined.mov', state: 'complete' } },
    { id: 'a', name: null, state: 'incomplete', created: '2026-09-11T04:04:33.235Z', destination: 'takes/a', streams: 1 },
  ]
  it('keeps GET /takes verbatim and names a nameless take by its id', () => {
    const s = setRecent(initial(), list)
    expect(s.recent).toHaveLength(2)
    expect(recentRow(s.recent[0])).toMatchObject({ id: 'b', name: 'Two', tone: 'complete', combined: { tone: 'complete', revealable: true } })
    expect(recentRow(s.recent[1])).toMatchObject({ id: 'a', name: 'a', tone: 'other', combined: null })
    expect(recentRow(s.recent[0]).when).not.toBe('')
    expect(setRecent(initial(), 'nonsense').recent).toEqual([])
  })
  it('folds a take event into the matching summary, so the fold agrees with the outcome line', () => {
    let s = setRecent(initial(), list)
    s = reduce(s, { event: 'take', take: { id: 'a', state: 'incomplete', streams: [], combined: { path: 'combined.mov', state: 'pending' } } })
    expect(s.recent[1].combined.state).toBe('pending')
    expect(s.take.id).toBe('a')
  })
  it('does not let another take\'s mux displace the one recording', () => {
    let s = setStreams(setRecent(initial(), list), { streams: [armed(mic)], permissions: null })
    s = reduce(s, { event: 'take', take: { id: 'live', state: 'recording', streams: [{ id: mic.id, started: '2026-09-12T05:00:00.000Z' }] } })
    s = reduce(s, { event: 'take', take: { id: 'a', state: 'incomplete', streams: [], combined: { path: 'combined.mov', state: 'complete' } } })
    expect(s.take.id).toBe('live')
    expect(s.recent[1].combined.state).toBe('complete')
  })
})

describe('a refused reveal', () => {
  it('reads an old daemon\'s "no such route" as an update, not a missing file', () => {
    expect(revealError('POST /takes/t/reveal', 404, { error: 'no such route', code: 'not_found' }))
      .toBe('POST /takes/t/reveal → this rheocles-core has no Open in Finder; update Rheocles')
  })
  it('passes every other refusal through in the daemon\'s words', () => {
    expect(revealError('POST /takes/t/reveal', 404, { error: 'no such path in take t', code: 'not_found' }))
      .toBe('POST /takes/t/reveal → 404 not_found: no such path in take t')
    expect(revealError('POST /reveal', 503, { error: 'connection refused', code: 'unreachable' }))
      .toBe('POST /reveal → 503 unreachable: connection refused')
    expect(revealError('POST /reveal', 500, {})).toBe('POST /reveal → 500 : ')
  })
})
