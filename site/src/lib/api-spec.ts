// The API reference's data shape, and the hand-typed table from spec §11
// that feeds it until docs/openapi.yaml is real. src/lib/openapi.ts reads the
// YAML at build time and, when it has paths, produces this same shape — so
// the page never changes and the source swaps in one place.

export type Method = 'GET' | 'POST' | 'WS';

export interface Field {
	name: string;
	type: string;
	required?: boolean;
	note: string;
}

export interface Endpoint {
	method: Method;
	path: string;
	summary: string;
	description?: string;
	request?: Field[];
	response?: string; // example JSON
	responseNote?: string;
	errors?: { code: string; when: string }[];
	ws?: string; // the same command as a WebSocket frame
}

export interface Group {
	id: string;
	label: string;
	blurb?: string;
	endpoints: Endpoint[];
}

export interface EventKind {
	type: string;
	when: string;
	example: string;
}

export interface ApiSpec {
	source: 'openapi' | 'spec';
	version?: string;
	groups: Group[];
	events: EventKind[];
}

const ws = (method: string, path: string, body?: string) =>
	`{ "id": 7, "method": "${method}", "path": "${path}"${body ? `, "body": ${body}` : ''} }`;

export const specTable: ApiSpec = {
	source: 'spec',
	groups: [
		{
			id: 'discovery',
			label: 'Discovery',
			endpoints: [
				{
					method: 'GET',
					path: '/',
					summary: 'Who this is, where files go, how much room there is.',
					description:
						'The one call a client makes first. `outputRoot` is the root every path in every other response is relative to.',
					response: `{ "hostname": "studio.local", "machine": "…", "version": "0.1.0",
  "outputRoot": "/Users/len/Movies/Rheocles", "freeBytes": 812345678912,
  "auth": "bearer" }`,
					ws: ws('GET', '/'),
				},
			],
		},
		{
			id: 'streams',
			label: 'Streams',
			blurb: 'Every input on the machine, with a stable id. Arming makes a device live; it never writes.',
			endpoints: [
				{
					method: 'GET',
					path: '/streams',
					summary: 'Every stream with its armed state.',
					response: `[ { "id": "cam-1a2b", "kind": "camera", "name": "FaceTime HD Camera",
    "model": "…", "armed": false, "can": { "video": true, "audio": false } },
  { "id": "mic-3c4d", "kind": "microphone", "name": "Shure MV7", "model": "…",
    "armed": true, "can": { "video": false, "audio": true } } ]`,
					ws: ws('GET', '/streams'),
				},
				{
					method: 'POST',
					path: '/streams/{id}/arm',
					summary: 'Device live or not. Never stamps anything, never writes.',
					request: [{ name: 'armed', type: 'boolean', required: true, note: 'true arms, false disarms. Disarming a stream that has joined a take implies leave.' }],
					response: `{ "id": "cam-1a2b", "armed": true }`,
					errors: [{ code: '404', when: 'no such stream' }],
					ws: ws('POST', '/streams/cam-1a2b/arm', '{ "armed": true }'),
				},
			],
		},
		{
			id: 'takes',
			label: 'Takes',
			blurb: 'Create reserves the paths and writes the manifest. Start is the cue. Stop finalises.',
			endpoints: [
				{
					method: 'POST',
					path: '/takes',
					summary: 'Snapshot the armed set, reserve every path, write the manifest. Not recording.',
					request: [
						{ name: 'name', type: 'string', note: 'Names the take folder. Defaults to a timestamp.' },
						{ name: 'destination', type: 'string', note: 'A folder, relative to the output root.' },
						{ name: 'files', type: 'object', note: 'Map of stream id → relative path, for clients that want to name files.' },
						{ name: 'codec', type: '"hevc" | "prores422"', note: 'The one global codec setting for this take.' },
						{ name: 'expectedDuration', type: 'number', note: 'Seconds. Used for the disk pre-flight; defaults to 1800.' },
						{ name: 'overwrite', type: 'boolean', note: 'Allow a destination that already exists. Otherwise 409.' },
					],
					response: `{ "id": "tk_7f3a", "state": "created",
  "files": { "cam-1a2b": "ep12/cam-facetime.mov", "mic-3c4d": "ep12/mic-mv7.wav" } }`,
					responseNote: 'Every path relative to the output root.',
					errors: [
						{ code: '409', when: 'the destination already exists and overwrite is not true; or a take is already active' },
						{ code: '507', when: 'the disk pre-flight says there is not room (code to be confirmed by the reference)' },
					],
					ws: ws('POST', '/takes', '{ "name": "ep12" }'),
				},
				{
					method: 'POST',
					path: '/takes/{id}/start',
					summary: 'The cue. Every armed stream joins at once.',
					response: `{ "id": "tk_7f3a", "state": "recording", "started": "2026-09-11T14:02:17.004Z" }`,
					errors: [{ code: '409', when: 'the take is not in state created' }],
					ws: ws('POST', '/takes/tk_7f3a/start'),
				},
				{
					method: 'POST',
					path: '/takes/{id}/stop',
					summary: 'Finalise every writer and the manifest.',
					response: `{ "id": "tk_7f3a", "state": "complete", "stopped": "2026-09-11T14:14:40.501Z" }`,
					ws: ws('POST', '/takes/tk_7f3a/stop'),
				},
				{
					method: 'POST',
					path: '/takes/{id}/join',
					summary: 'Start one stream’s writer now. Arms it first if it is cold.',
					request: [{ name: 'stream', type: 'string', required: true, note: 'The stream id.' }],
					response: `{ "id": "tk_7f3a", "stream": "win-9c0d", "path": "ep12/window-keynote.mov",
  "started": "2026-09-11T14:06:17.021Z", "timecode": "14:06:17:00" }`,
					errors: [{ code: '409', when: 'the take is not recording, or the stream is already joined' }],
					ws: ws('POST', '/takes/tk_7f3a/join', '{ "stream": "win-9c0d" }'),
				},
				{
					method: 'POST',
					path: '/takes/{id}/leave',
					summary: 'Finalise that stream’s file. The stream stays armed; the take continues.',
					request: [{ name: 'stream', type: 'string', required: true, note: 'The stream id.' }],
					response: `{ "id": "tk_7f3a", "stream": "win-9c0d", "stopped": "2026-09-11T14:08:31.115Z", "frames": 8045 }`,
					ws: ws('POST', '/takes/tk_7f3a/leave', '{ "stream": "win-9c0d" }'),
				},
				{
					method: 'POST',
					path: '/takes/{id}/markers',
					summary: 'Append { t, label }. Rheocles stamps t; the label is yours.',
					request: [{ name: 'label', type: 'string', required: true, note: 'Never interpreted by Rheocles.' }],
					response: `{ "t": 38.7, "label": "cold-open out" }`,
					errors: [{ code: '409', when: 'the take is not recording' }],
					ws: ws('POST', '/takes/tk_7f3a/markers', '{ "label": "cold-open out" }'),
				},
				{
					method: 'GET',
					path: '/takes/{id}',
					summary: 'The manifest — live while recording, from disk afterwards.',
					response: `{ "take": { "id": "tk_7f3a", "state": "recording", … },
  "streams": [ … ], "markers": [ … ] }`,
					responseNote: 'The full shape is on Takes and the manifest.',
					errors: [{ code: '404', when: 'no such take' }],
					ws: ws('GET', '/takes/tk_7f3a'),
				},
				{
					method: 'GET',
					path: '/takes',
					summary: 'Recent takes.',
					response: `[ { "id": "tk_7f3a", "name": "ep12", "state": "complete",
    "created": "2026-09-11T14:02:09.412Z", "path": "ep12" }, … ]`,
					ws: ws('GET', '/takes'),
				},
			],
		},
		{
			id: 'record',
			label: 'Record',
			endpoints: [
				{
					method: 'POST',
					path: '/record',
					summary: 'Create and start together. The one-click form; what the popover’s button does.',
					request: [{ name: '…', type: '', note: 'The same body as POST /takes.' }],
					response: `{ "id": "tk_7f3a", "state": "recording", "files": { … } }`,
					ws: ws('POST', '/record', '{ "name": "ep12" }'),
				},
			],
		},
		{
			id: 'events',
			label: 'Events',
			blurb: 'State, levels, drift, joins, errors — pushed as they happen.',
			endpoints: [
				{
					method: 'GET',
					path: '/events',
					summary: 'Server-sent events. One-way; every event type below.',
					description:
						'A browser `EventSource` cannot set an `Authorization` header. How the token travels on this route from a browser — a query parameter, or `fetch` with a readable stream — is the reference’s to pin. Native clients set the header.',
					response: `event: level
data: { "stream": "mic-3c4d", "peakDb": -19.4, "ts": 1789178960251 }`,
				},
			],
		},
		{
			id: 'preview',
			label: 'Preview',
			endpoints: [
				{
					method: 'GET',
					path: '/preview/{stream}',
					summary: 'Low-rate preview frames for one stream, on demand. One at a time.',
					description:
						'For a popover, not a monitor wall. Opening a second preview closes the first. The frame format and rate are the reference’s to pin.',
					errors: [{ code: '404', when: 'no such stream' }],
					ws: ws('GET', '/preview/cam-1a2b'),
				},
			],
		},
		{
			id: 'websocket',
			label: 'WebSocket',
			blurb: 'Everything above, full duplex, on port 7448.',
			endpoints: [
				{
					method: 'WS',
					path: '/',
					summary: 'One socket carries every command and every event.',
					description:
						'One command set, one dispatcher, two transports. A frame names the same method and path as the HTTP call and carries the same body; the reply carries the same JSON with the frame’s `id`. Events arrive unsolicited, as on `/events`. The exact envelope is the reference’s to pin; this is the shape the spec implies.',
					response: `→ { "id": 7, "method": "POST", "path": "/takes/tk_7f3a/start" }
← { "id": 7, "status": 200, "body": { "id": "tk_7f3a", "state": "recording", … } }
← { "event": "state", "data": { "take": "tk_7f3a", "state": "recording" } }`,
				},
			],
		},
	],
	events: [
		{ type: 'state', when: 'a take changes state', example: `{ "take": "tk_7f3a", "state": "recording", "at": "2026-09-11T14:02:17.004Z" }` },
		{ type: 'join', when: 'a stream starts writing', example: `{ "take": "tk_7f3a", "stream": "win-9c0d", "t": 240.017, "timecode": "14:06:17:00" }` },
		{ type: 'leave', when: 'a stream’s file is finalised', example: `{ "take": "tk_7f3a", "stream": "win-9c0d", "t": 374.111, "frames": 8045 }` },
		{ type: 'level', when: 'an armed audio stream’s meter ticks', example: `{ "stream": "mic-3c4d", "peakDb": -19.4 }` },
		{ type: 'drift', when: 'a recording stream’s drift is re-measured', example: `{ "take": "tk_7f3a", "stream": "cam-1a2b", "driftMs": -3, "frames": 21540 }` },
		{ type: 'marker', when: 'a marker lands', example: `{ "take": "tk_7f3a", "t": 38.7, "label": "cold-open out" }` },
		{ type: 'error', when: 'something fails; the take may now be incomplete', example: `{ "take": "tk_7f3a", "stream": "dsp-5e6f", "reason": "disk full", "state": "incomplete" }` },
	],
};
