// The API reference's source. Reads ../docs/openapi.yaml at build time; when
// it has paths, the reference is generated from it and nothing on the page is
// hand-duplicated. Until Engine lands it, the hand-typed table from spec §11
// (api-spec.ts) has the same shape and feeds the same page.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { parse } from 'yaml';
import { specTable, type ApiSpec, type Endpoint, type Field, type Group, type Method } from './api-spec';

const YAML_PATH = fileURLToPath(new URL('../../../docs/openapi.yaml', import.meta.url));

type Any = Record<string, any>;

function example(schemaOrContent: Any | undefined): string | undefined {
	if (!schemaOrContent) return undefined;
	const json = schemaOrContent['application/json'] ?? schemaOrContent;
	const ex = json.example ?? json.examples?.[Object.keys(json.examples ?? {})[0]]?.value ?? json.schema?.example;
	if (ex === undefined) return undefined;
	return typeof ex === 'string' ? ex : JSON.stringify(ex, null, 2);
}

function fields(body: Any | undefined): Field[] | undefined {
	const schema = body?.content?.['application/json']?.schema;
	if (!schema?.properties) return undefined;
	const required = new Set<string>(schema.required ?? []);
	return Object.entries(schema.properties as Any).map(([name, p]) => ({
		name,
		type: p.enum ? p.enum.map((v: string) => JSON.stringify(v)).join(' | ') : (p.type ?? ''),
		required: required.has(name),
		note: p.description ?? '',
	}));
}

function fromOpenApi(doc: Any): ApiSpec {
	const groups = new Map<string, Group>();
	const tagOrder: string[] = (doc.tags ?? []).map((t: Any) => t.name);
	const group = (tag: string) => {
		const id = tag.toLowerCase().replace(/[^a-z0-9]+/g, '-');
		if (!groups.has(id)) {
			const meta = (doc.tags ?? []).find((t: Any) => t.name === tag);
			groups.set(id, { id, label: tag, blurb: meta?.description, endpoints: [] });
		}
		return groups.get(id)!;
	};

	for (const [path, item] of Object.entries(doc.paths as Any)) {
		for (const [m, op] of Object.entries(item as Any)) {
			if (!['get', 'post', 'put', 'delete', 'patch'].includes(m)) continue;
			const o = op as Any;
			const method = (o['x-transport'] === 'ws' ? 'WS' : m.toUpperCase()) as Method;
			const ok = Object.entries(o.responses ?? {}).find(([code]) => code.startsWith('2'));
			const errors = Object.entries(o.responses ?? {})
				.filter(([code]) => !code.startsWith('2'))
				.map(([code, r]) => ({ code, when: (r as Any).description ?? '' }));
			const e: Endpoint = {
				method,
				path,
				summary: o.summary ?? '',
				description: o.description,
				request: fields(o.requestBody),
				response: example((ok?.[1] as Any)?.content),
				errors: errors.length ? errors : undefined,
				ws: o['x-ws'],
			};
			group(o.tags?.[0] ?? 'Other').endpoints.push(e);
		}
	}

	const ordered = [...groups.values()].sort(
		(a, b) => (tagOrder.indexOf(a.label) + 1 || 99) - (tagOrder.indexOf(b.label) + 1 || 99),
	);
	const events = (doc['x-events'] as Any[] | undefined)?.map((ev) => ({
		type: ev.type,
		when: ev.description ?? '',
		example: typeof ev.example === 'string' ? ev.example : JSON.stringify(ev.example ?? {}),
	}));

	return { source: 'openapi', version: doc.info?.version, groups: ordered, events: events ?? specTable.events };
}

export function loadApi(): ApiSpec {
	try {
		const doc = parse(readFileSync(YAML_PATH, 'utf8'));
		if (doc && typeof doc === 'object' && doc.paths && Object.keys(doc.paths).length > 0) {
			return fromOpenApi(doc);
		}
	} catch {
		// unreadable or malformed: fall through to the spec table
	}
	return specTable;
}
