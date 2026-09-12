// The API reference's data shape, and the hand-typed table from spec §11.
// src/lib/openapi.ts reads docs/openapi.yaml at build time and renders every
// route it pins from the YAML; routes only this table knows are rendered as
// planned. When the YAML has every route, this table contributes nothing but
// the group order and blurbs.

export type Method = 'GET' | 'POST' | 'PATCH' | 'WS';

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
	responseFields?: Field[]; // from the YAML schema
	responseNote?: string;
	errors?: { code: string; when: string }[];
	ws?: string; // the same command as a WebSocket frame
	pinned?: boolean; // rendered from docs/openapi.yaml
	planned?: boolean; // only the spec names it so far
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
	pinned?: boolean;
	planned?: boolean;
}

export interface ApiSpec {
	source: 'openapi' | 'merged' | 'spec';
	version?: string;
	groups: Group[];
	events: EventKind[];
	pinned?: number;
	planned?: number;
}

// The frame encoding from docs/PROTOCOL.md: the HTTP request, as an object.
const ws = (method: string, path: string, body?: string) =>
	`{ "id": 7, "method": "${method}", "path": "${path}", "body": ${body ?? 'null'} }`;

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
					response: `{ "name": "Rheocles", "version": "0.1.0", "hostname": "studio.local",
  "machineId": "…", "outputRoot": "/Users/len/Movies/Rheocles",
  "freeBytes": 812345678912, "auth": "bearer", "ports": { "http": 7447, "ws": 7448 } }`,
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
					response: `{ "streams": [
    { "id": "camera:0x2300000fd9009c", "kind": "camera", "name": "Elgato 4K X",
      "model": "UVC Camera VendorID_4057 ProductID_156",
      "capabilities": { "video": { "width": 3840, "height": 2160, "maxFrameRate": 30 } },
      "armed": false },
    { "id": "microphone:Scarlett_2i2", "kind": "microphone", "name": "Scarlett 2i2 USB",
      "model": "Scarlett 2i2 USB:1235:8210",
      "capabilities": { "audio": { "sampleRate": 48000, "channels": 2 } },
      "armed": true } ],
  "permissions": { "camera": "notDetermined", "microphone": "authorized", "screen": "authorized" } }`,
					ws: ws('GET', '/streams'),
				},
				{
					method: 'POST',
					path: '/streams/{id}/arm',
					summary: 'Device live or not. Never stamps anything, never writes.',
					request: [{ name: 'armed', type: 'boolean', required: true, note: 'true arms, false disarms. Disarming a stream that has joined a take implies leave.' }],
					response: `{ "id": "camera:0x2300000fd9009c", "armed": true }`,
					errors: [{ code: '404', when: 'no such stream' }],
					ws: ws('POST', '/streams/camera:0x2300000fd9009c/arm', '{ "armed": true }'),
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
						{ name: 'codec', type: '"hevc" | "prores"', note: 'The one global codec setting for this take.' },
						{ name: 'expectedDuration', type: 'number', note: 'Seconds. Used for the disk pre-flight; defaults to 1800.' },
						{ name: 'overwrite', type: 'boolean', note: 'Allow a destination that already exists. Otherwise 409.' },
					],
					response: `{ "id": "20260912T040433-fd9q", "state": "created",
  "files": { "camera:0x2300000fd9009c": "elgato-4k-x.mov", "microphone:Scarlett_2i2": "scarlett-2i2-usb.wav" } }`,
					responseNote: 'Every path relative to the output root.',
					errors: [
						{ code: '409', when: 'the destination already exists and overwrite is not true; or a take is already active' },
						{ code: '507', when: 'the disk pre-flight refused the take' },
					],
					ws: ws('POST', '/takes', '{ "name": "Episode 12" }'),
				},
				{
					method: 'POST',
					path: '/takes/{id}/start',
					summary: 'The cue. Every armed stream joins at once.',
					response: `{ "id": "20260912T040433-fd9q", "state": "recording", "started": "2026-09-11T14:02:17.004Z" }`,
					errors: [{ code: '409', when: 'the take is not in state created' }],
					ws: ws('POST', '/takes/20260912T040433-fd9q/start'),
				},
				{
					method: 'POST',
					path: '/takes/{id}/stop',
					summary: 'Finalise every writer and the manifest.',
					response: `{ "id": "20260912T040433-fd9q", "state": "complete", "stopped": "2026-09-11T14:14:40.501Z" }`,
					ws: ws('POST', '/takes/20260912T040433-fd9q/stop'),
				},
				{
					method: 'POST',
					path: '/takes/{id}/join',
					summary: 'Start one stream’s writer now. Arms it first if it is cold.',
					request: [{ name: 'stream', type: 'string', required: true, note: 'The stream id.' }],
					response: `{ "id": "20260912T040433-fd9q", "stream": "window:11597", "path": "window-com.apple.iWork.Keynote.mov",
  "started": "2026-09-11T14:06:17.021Z", "timecode": "14:06:17:00" }`,
					errors: [{ code: '409', when: 'the take is not recording, or the stream is already joined' }],
					ws: ws('POST', '/takes/20260912T040433-fd9q/join', '{ "stream": "window:11597" }'),
				},
				{
					method: 'POST',
					path: '/takes/{id}/leave',
					summary: 'Finalise that stream’s file. The stream stays armed; the take continues.',
					request: [{ name: 'stream', type: 'string', required: true, note: 'The stream id.' }],
					response: `{ "id": "20260912T040433-fd9q", "stream": "window:11597", "stopped": "2026-09-11T14:08:31.115Z", "framesWritten": 8045 }`,
					ws: ws('POST', '/takes/20260912T040433-fd9q/leave', '{ "stream": "window:11597" }'),
				},
				{
					method: 'POST',
					path: '/takes/{id}/markers',
					summary: 'Append { t, label }. Rheocles stamps t; the label is yours.',
					request: [{ name: 'label', type: 'string', required: true, note: 'Never interpreted by Rheocles.' }],
					response: `{ "t": 38.7, "label": "cold-open out" }`,
					errors: [{ code: '409', when: 'the take is not recording' }],
					ws: ws('POST', '/takes/20260912T040433-fd9q/markers', '{ "label": "cold-open out" }'),
				},
				{
					method: 'GET',
					path: '/takes/{id}',
					summary: 'The manifest — live while recording, from disk afterwards.',
					response: `{ "take": { "id": "20260912T040433-fd9q", "state": "recording", … },
  "streams": [ … ], "markers": [ … ] }`,
					responseNote: 'The full shape is on Takes and the manifest.',
					errors: [{ code: '404', when: 'no such take' }],
					ws: ws('GET', '/takes/20260912T040433-fd9q'),
				},
				{
					method: 'GET',
					path: '/takes',
					summary: 'Recent takes.',
					response: `[ { "id": "20260912T040433-fd9q", "name": "Episode 12", "state": "complete",
    "created": "2026-09-11T14:02:09.412Z", "destination": "takes/2026-09-11/210433-episode-12", "streams": 5 }, … ]`,
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
					response: `{ "id": "20260912T040433-fd9q", "state": "recording", "files": { … } }`,
					ws: ws('POST', '/record', '{ "name": "Episode 12" }'),
				},
			],
		},
		{
			id: 'settings',
			label: 'Settings',
			blurb: 'Daemon-owned defaults, persisted to ~/Library/Application Support/Rheocles/settings.json.',
			endpoints: [
				{ method: 'GET', path: '/settings', summary: 'The output root and the codec.', response: `{ "outputRoot": "/Users/len/Movies/Rheocles", "codec": "hevc" }`, ws: ws('GET', '/settings') },
				{
					method: 'PATCH',
					path: '/settings',
					summary: 'Change either. The output root cannot move while a take is active.',
					request: [
						{ name: 'outputRoot', type: 'string', note: 'Absolute. 409 while a take is created or recording — its files are already reserved beneath the old root.' },
						{ name: 'codec', type: '"hevc" | "prores"', note: 'One setting for every take that follows.' },
					],
					response: `{ "outputRoot": "/Volumes/SSD/Takes", "codec": "hevc" }`,
					errors: [{ code: '409', when: 'outputRoot while a take is active' }],
					ws: ws('PATCH', '/settings', '{ "codec": "prores" }'),
				},
			],
		},
		{
			id: 'token',
			label: 'Token',
			endpoints: [
				{
					method: 'POST',
					path: '/token/rotate',
					summary: 'A new token. The old one is refused from the next request on, both transports.',
					response: `{ "token": "9f3c…" }`,
					ws: ws('POST', '/token/rotate', '{}'),
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
data: { "stream": "microphone:Scarlett_2i2", "peakDb": -19.4, "ts": 1789178960251 }`,
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
					ws: ws('GET', '/preview/camera:0x2300000fd9009c'),
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
						'Text frames, one JSON object each. The first frame must be `{ "auth": "<token>" }`; until then every command answers 401 and no event is delivered. A command frame is the HTTP request as an object — `id` is anything you like and is echoed back, `method`, `path`, and the optional `query` and `body` are exactly the HTTP request’s — and the reply carries the HTTP `status` and `body`. Events arrive as objects with an `event` key and no `id`. After `POST /token/rotate` a socket that authenticated with the old token stays up but must `auth` again before its next command.',
					response: `→ { "auth": "<token>" }
← { "id": null, "status": 200, "body": { "authenticated": true } }
→ { "id": 7, "method": "POST", "path": "/takes/20260912T040433-fd9q/start", "query": {}, "body": null }
← { "id": 7, "status": 200, "body": { "id": "20260912T040433-fd9q", "state": "recording", … } }
← { "event": "state", "take": "20260912T040433-fd9q", "state": "recording" }`,
				},
			],
		},
	],
	// Every event the daemon emits is pinned in the YAML's x-events; nothing is
	// planned here. Kept as the fallback shape only.
	events: [],
};
