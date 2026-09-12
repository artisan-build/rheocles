// The API reference's source. Reads ../docs/openapi.yaml at build time. Every
// route the YAML pins is rendered from the YAML — summary, request fields,
// response fields, errors — and nothing about it is hand-duplicated. Routes
// the spec names that the YAML does not yet have come from the hand-typed
// §11 table (api-spec.ts) and are marked planned, so the page is complete
// and current at once. When the YAML has every route, nothing is planned.
import { parse } from 'yaml';
// Inlined by Vite at build time, resolved relative to this file — so it
// works from the bundle, where import.meta.url no longer points at src/.
import yamlText from '../../../docs/openapi.yaml?raw';
import { specTable, type ApiSpec, type Endpoint, type Field, type Group } from './api-spec';

type Any = Record<string, any>;

function resolver(doc: Any) {
	const deref = (node: Any | undefined, depth = 0): Any | undefined => {
		if (!node || typeof node !== 'object' || depth > 12) return node;
		if (typeof node.$ref === 'string') {
			const target = node.$ref
				.replace(/^#\//, '')
				.split('/')
				.reduce((acc: Any, key: string) => acc?.[key], doc);
			return deref(target, depth + 1);
		}
		return node;
	};
	return deref;
}

function typeOf(p: Any, deref: (n: Any) => Any | undefined): string {
	const s = deref(p) ?? {};
	if (s.const !== undefined) return JSON.stringify(s.const);
	if (s.enum) return s.enum.map((v: unknown) => JSON.stringify(v)).join(' | ');
	if (s.type === 'array') return `${typeOf(s.items ?? {}, deref)}[]`;
	if (s.type === 'integer') return s.format === 'int64' ? 'integer' : 'integer';
	return s.type ?? 'object';
}

// Flatten a schema's properties to one table, nesting as dotted names and
// arrays as name[]. Two levels is enough for this API and keeps the table
// readable; deeper shapes get a one-line summary.
function fields(schema: Any | undefined, deref: (n: Any) => Any | undefined, prefix = '', depth = 0): Field[] {
	const s = deref(schema);
	if (!s?.properties) return [];
	const required = new Set<string>(s.required ?? []);
	const out: Field[] = [];
	for (const [name, raw] of Object.entries(s.properties as Any)) {
		const p = deref(raw) ?? {};
		const full = prefix + name;
		out.push({
			name: full,
			type: typeOf(p, deref),
			required: required.has(name),
			note: String(p.description ?? '').replace(/\s+/g, ' ').trim(),
		});
		const inner = p.type === 'array' ? deref(p.items) : p;
		if (depth < 2 && inner?.properties) {
			out.push(...fields(inner, deref, full + (p.type === 'array' ? '[].' : '.'), depth + 1));
		}
	}
	return out;
}

function example(content: Any | undefined, deref: (n: Any) => Any | undefined): string | undefined {
	const json = content?.['application/json'];
	if (!json) return undefined;
	const ex = json.example ?? json.examples?.[Object.keys(json.examples ?? {})[0]]?.value ?? deref(json.schema)?.example;
	if (ex === undefined) return undefined;
	return typeof ex === 'string' ? ex : JSON.stringify(ex, null, 2);
}

// Engine writes x-ws as { request, response } objects; render as two frames.
function wsFrames(x: unknown): string | undefined {
	if (!x) return undefined;
	if (typeof x === 'string') return x;
	const o = x as Any;
	const lines: string[] = [];
	if (o.request) lines.push(`→ ${JSON.stringify(o.request)}`);
	if (o.response) lines.push(`← ${JSON.stringify(o.response)}`);
	return lines.join('\n') || undefined;
}

function fromOpenApi(doc: Any): Map<string, Endpoint> {
	const deref = resolver(doc);
	const out = new Map<string, Endpoint>();
	for (const [path, item] of Object.entries((doc.paths ?? {}) as Any)) {
		for (const [m, op] of Object.entries(item as Any)) {
			if (!['get', 'post', 'put', 'delete', 'patch'].includes(m)) continue;
			const o = op as Any;
			const method = m.toUpperCase() as Endpoint['method'];
			const responses = Object.entries(o.responses ?? {}).map(([code, r]) => [code, deref(r as Any)] as const);
			const ok = responses.find(([code]) => code.startsWith('2'));
			const errors = responses
				.filter(([code]) => !code.startsWith('2'))
				.map(([code, r]) => ({ code, when: String(r?.description ?? '').trim() }));
			const body = deref(o.requestBody)?.content?.['application/json']?.schema;
			const okContent = ok?.[1]?.content ?? {};
			const okSchema = okContent['application/json']?.schema;
			// Query parameters render in the request table, prefixed with ?.
			const query: Field[] = ((o.parameters ?? []) as Any[])
				.map((p) => deref(p) ?? p)
				.filter((p) => p.in === 'query')
				.map((p) => ({ name: `?${p.name}`, type: p.schema?.type ?? '', required: !!p.required, note: String(p.description ?? '') }));
			const request = [...(body ? fields(body, deref) : []), ...query];
			out.set(`${method} ${path}`, {
				method,
				path,
				summary: o.summary ?? '',
				description: o.description,
				request: request.length ? request : undefined,
				response: example(okContent, deref),
				responseTypes: Object.keys(okContent).length ? Object.keys(okContent) : undefined,
				responseFields: okSchema ? fields(okSchema, deref) : undefined,
				responseNote: ok?.[1]?.description,
				errors: errors.length ? errors : undefined,
				ws: wsFrames(o['x-ws']),
				pinned: true,
			});
		}
	}
	return out;
}

export function loadApi(): ApiSpec {
	let doc: Any | undefined;
	try {
		const parsed = parse(yamlText);
		if (parsed && typeof parsed === 'object' && parsed.paths && Object.keys(parsed.paths).length > 0) doc = parsed;
	} catch {
		doc = undefined; // unreadable or malformed: everything is planned
	}
	if (!doc) return { ...specTable, source: 'spec', pinned: 0, planned: specTable.groups.flatMap((g) => g.endpoints).length };

	const fromYaml = fromOpenApi(doc);
	// The WebSocket transport is not a path; the YAML describes it in a
	// top-level x-websocket block, rendered as the WS / entry.
	const xws = doc['x-websocket'] as Any | undefined;
	if (xws) {
		const j = (v: unknown) => JSON.stringify(v);
		const frames: string[] = [];
		if (xws.auth?.request) frames.push(`→ ${j(xws.auth.request)}`);
		if (xws.auth?.response) frames.push(`← ${j(xws.auth.response)}`);
		if (xws.request?.example) frames.push(`→ ${j(xws.request.example)}`);
		if (xws.response?.example) frames.push(`← ${j(xws.response.example)}`);
		if (xws.response?.binaryExample) frames.push(`← ${j(xws.response.binaryExample)}`);
		const description = [xws.auth?.description, xws.request?.description, xws.response?.description, xws.events?.description]
			.filter(Boolean)
			.map((t: string) => t.replace(/\s+/g, ' ').trim())
			.join(' ');
		fromYaml.set('WS /', {
			method: 'WS',
			path: xws.url ?? '/',
			summary: 'One socket carries every command and every event.',
			description,
			response: frames.join('\n'),
			pinned: true,
		});
	}
	const seen = new Set<string>();
	let pinned = 0;
	let planned = 0;
	const groups: Group[] = specTable.groups.map((g) => ({
		...g,
		endpoints: g.endpoints.map((e) => {
			const key = `${e.method} ${e.path}`;
			const y = fromYaml.get(key);
			seen.add(key);
			if (y) {
				pinned++;
				// The YAML owns everything it states; the spec table only lends the
				// WebSocket frame when the YAML has no x-ws for the route.
				return { ...y, ws: y.ws ?? e.ws };
			}
			planned++;
			return { ...e, planned: true };
		}),
	}));
	// Routes the YAML has that the spec table does not: append under Other.
	const extra = [...fromYaml.entries()].filter(([k]) => !seen.has(k)).map(([, e]) => e);
	if (extra.length) {
		pinned += extra.length;
		groups.push({ id: 'other', label: 'Other', endpoints: extra });
	}
	// Events the YAML pins, then the spec's planned ones it does not name yet.
	const fromYamlEvents = (doc['x-events'] as Any[] | undefined)?.map((ev) => ({
		type: ev.event ?? ev.type,
		when: ev.description ?? '',
		example: typeof ev.example === 'string' ? ev.example : JSON.stringify(ev.example ?? {}),
		pinned: true,
	}));
	const named = new Set((fromYamlEvents ?? []).map((e) => e.type));
	const events = fromYamlEvents
		? [...fromYamlEvents, ...specTable.events.filter((e) => !named.has(e.type)).map((e) => ({ ...e, planned: true }))]
		: undefined;
	return {
		source: planned ? 'merged' : 'openapi',
		version: doc.info?.version,
		groups,
		events: events ?? specTable.events,
		pinned,
		planned,
	};
}
