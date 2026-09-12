import { describe, it, expect } from 'vitest'
import {
  decodeEvent, reduce, initial, setStreams, headline, sections, summary, detail, nudge, writingIds, bytes, abbreviate,
  elapsed, clock, lateJoined, finishedLine, isOver,
} from '../../public/js/state.js'

/* The browser-side state, without a browser: what the events and the pulse
 * say, reduced to what the page shows. */

const mic = { id: 'microphone:m', kind: 'microphone', name: 'Mic', model: 'M', capabilities: { audio: { sampleRate: 48000, channels: 2 } }, armed: false }
const cam = { id: 'camera:c', kind: 'camera', name: 'Cam', model: 'C', capabilities: { video: { width: 3840, height: 2160, maxFrameRate: 30 } }, armed: false }
const win = { id: 'window:1', kind: 'window', name: 'Docs', model: 'com.google.Chrome', capabilities: { video: { width: 1200, height: 900, maxFrameRate: 59.94 } }, armed: false }
const ok = { camera: 'authorized', microphone: 'authorized', screen: 'authorized' }

describe('events', () => {
  it('decodes only objects that name their kind', () => {
    expect(decodeEvent('{"event":"stream","stream":{"id":"x"}}')).toEqual({ event: 'stream', stream: { id: 'x' } })
    expect(decodeEvent('{"stream":{}}')).toBeNull()
    expect(decodeEvent('not json')).toBeNull()
  })

  it('replaces a stream in place on a stream event, appends an unknown one', () => {
    let s = setStreams(initial(), { streams: [mic, cam], permissions: ok })
    s = reduce(s, { event: 'stream', stream: { ...cam, armed: true, framesSeen: 12 } })
    expect(s.streams.map(x => x.id)).toEqual(['microphone:m', 'camera:c'])
    expect(s.streams[1].armed).toBe(true)
    s = reduce(s, { event: 'stream', stream: { ...win } })
    expect(s.streams).toHaveLength(3)
    expect(reduce(s, { event: 'stream' })).toBe(s)
  })

  it('keeps the manifest from a take event, ignores the rest', () => {
    const s = reduce(initial(), { event: 'take', take: { id: 't', state: 'recording', streams: [] } })
    expect(s.take.state).toBe('recording')
    expect(reduce(s, { event: 'levels', levels: {} })).toBe(s)
  })
})

describe('headline', () => {
  const armed = setStreams(initial(), { streams: [{ ...mic, armed: true }, { ...cam, armed: true }], permissions: ok })
  it('speaks for the daemon', () => {
    expect(headline({ status: 'launching' }, armed)).toEqual({ tone: 'launching', label: 'Launching' })
    expect(headline({ status: 'down' }, armed)).toEqual({ tone: 'down', label: 'Down' })
    expect(headline({ status: 'running' }, initial())).toEqual({ tone: 'idle', label: 'Idle' })
    expect(headline({ status: 'running' }, armed)).toEqual({ tone: 'armed', label: 'Armed · 2' })
    expect(headline({ status: 'running' }, reduce(armed, { event: 'take', take: { state: 'recording', streams: [] } })))
      .toEqual({ tone: 'recording', label: 'Recording' })
  })
  it('does not believe a recording manifest with nothing armed', () => {
    const none = setStreams(initial(), { streams: [mic, cam], permissions: ok })
    const s = reduce(none, { event: 'take', take: { state: 'recording', streams: [] } })
    expect(headline({ status: 'running' }, s)).toEqual({ tone: 'idle', label: 'Idle' })
    // Before the first stream read, the take is taken at its word.
    expect(headline({ status: 'running' }, reduce(initial(), { event: 'take', take: { state: 'recording', streams: [] } })).tone).toBe('recording')
  })
})

describe('the list', () => {
  it('groups by kind in the daemon\'s order and hides windows unless asked', () => {
    const streams = [win, cam, mic]
    expect(sections(streams, false, ok, true).map(s => s.heading)).toEqual(['Cameras', 'Microphones'])
    expect(sections(streams, true, ok, true).map(s => s.heading)).toEqual(['Windows', 'Cameras', 'Microphones'])
  })

  it('says what the file will be', () => {
    expect(summary(cam.capabilities)).toBe('3840×2160 · 30')
    expect(summary(win.capabilities)).toBe('1200×900 · 59.94')
    expect(summary(mic.capabilities)).toBe('48 kHz · 2 ch')
    expect(summary({ audio: { sampleRate: 44100, channels: 1 } })).toBe('44.1 kHz · 1 ch')
    expect(summary({})).toBe('··')
    expect(detail(win)).toBe('com.google.Chrome · 1200×900 · 59.94')
    expect(detail(cam)).toBe('3840×2160 · 30')
  })

  it('puts a nudge where the missing streams would be', () => {
    const noScreen = { ...ok, screen: 'notDetermined' }
    const s = sections([mic], false, noScreen, true)
    expect(s.map(x => x.heading)).toEqual(['Displays', 'Microphones'])
    expect(s[0].members).toEqual([])
    expect(s[0].nudge.capability).toBe('Screen Recording')
    expect(s[0].nudge.status).toBe('not asked yet')
    expect(s[0].nudge.relaunch).toBe(true)
    expect(nudge('display', noScreen, false).relaunch).toBe(false)
    expect(nudge('display', noScreen, false).consequence).toContain('then relaunch the daemon')
    expect(nudge('camera', { ...ok, camera: 'denied' }, true)).toMatchObject({ capability: 'Camera', status: 'denied', pane: 'Privacy_Camera' })
    expect(nudge('camera', { ...ok, camera: 'notDetermined' }, true)).toBeNull()  // asked on the first arm
    expect(nudge('microphone', { ...ok, microphone: 'restricted' }, true).status).toBe('restricted')
    expect(nudge('microphone', null, true)).toBeNull()
  })

  it('knows which streams are writing in the active take', () => {
    const s = reduce(initial(), { event: 'take', take: { state: 'recording', streams: [
      { id: 'a', started: '2026-09-12T04:04:33.347Z' },
      { id: 'b', started: '2026-09-12T04:04:33.347Z', stopped: '2026-09-12T04:05:00.000Z' },
      { id: 'c' },
    ] } })
    expect(writingIds(s)).toEqual(['a'])
    expect(writingIds(initial())).toEqual([])
  })
})

describe('formatting', () => {
  it('says bytes the way Finder does', () => {
    expect(bytes(44878079167)).toBe('44.9 GB')
    expect(bytes(1.5e12)).toBe('1.50 TB')
    expect(bytes(512e6)).toBe('512 MB')
  })
  it('abbreviates the home directory', () => {
    expect(abbreviate('/Users/len/Movies/Rheocles', '/Users/len')).toBe('~/Movies/Rheocles')
    expect(abbreviate('/Volumes/Raid/x', '/Users/len')).toBe('/Volumes/Raid/x')
  })
})

describe('takes', () => {
  const take = { id: 't1', name: 'ep12', state: 'recording', started: '2026-09-12T04:00:00.000Z', streams: [
    { id: 'a', started: '2026-09-12T04:00:00.050Z' },
    { id: 'b', started: '2026-09-12T04:04:00.000Z' },
    { id: 'c' },
    { id: 'd', started: '2026-09-12T04:00:00.400Z' },
    { id: 'e', started: '2026-09-12T05:00:00.000Z' },
  ], markers: [] }
  it('appends a marker event to the active take only', () => {
    let s = reduce(initial(), { event: 'take', take })
    s = reduce(s, { event: 'marker', take: 't1', marker: { t: 2.042, label: 'chapter 1' } })
    expect(s.take.markers).toEqual([{ t: 2.042, label: 'chapter 1' }])
    expect(reduce(s, { event: 'marker', take: 'other', marker: { t: 1, label: 'x' } })).toBe(s)
  })
  it('counts from the cue, to now or to the stop', () => {
    const now = Date.parse('2026-09-12T04:04:17.900Z')
    expect(clock(elapsed(take, now))).toBe('04:17')
    expect(clock(elapsed({ ...take, stopped: '2026-09-12T05:01:05.000Z' }, now))).toBe('1:01:05')
    expect(elapsed({ ...take, started: undefined })).toBeNull()
  })
  it('marks late joiners among the first four strokes', () => {
    expect(lateJoined(take)).toEqual([1])
    expect(lateJoined({ ...take, started: undefined })).toEqual([])
  })
  it('says what the take became', () => {
    const now = Date.parse('2026-09-12T04:10:00.000Z')
    const done = { ...take, state: 'complete', stopped: '2026-09-12T04:05:00.000Z' }
    expect(finishedLine(done, now)).toEqual({ text: 'ep12 · complete · 05:00 · 5 files', reason: null, complete: true })
    const bad = { ...take, name: undefined, state: 'incomplete', reason: 'camera:c: no frames arrived', streams: [take.streams[0]] }
    expect(finishedLine(bad, now).text).toBe('t1 · incomplete · 10:00 · 1 file')
    expect(finishedLine(bad, now).reason).toContain('no frames')
    expect(isOver(done)).toBe(true)
    expect(isOver(take)).toBe(false)
  })
})
