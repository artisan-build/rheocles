// The docs tree, in reading order. Approved with the brand (11 Sep 2026);
// each entry is a collection id under src/content/docs, except the API
// reference, which is a page of its own generated from docs/openapi.yaml.
// A page that does not exist yet still appears in the sidebar, unlinked, so
// the shape of the docs is visible before every page is.
export interface NavEntry {
	id: string;
	label: string;
	short?: string; // for prev/next links
}

export const docsNav: NavEntry[] = [
	{ id: 'index', label: 'Overview' },
	{ id: 'getting-started', label: 'Getting started' },
	{ id: 'recording-a-take', label: 'Recording a take' },
	{ id: 'streams-and-arming', label: 'Streams and arming' },
	{ id: 'takes-and-the-manifest', label: 'Takes and the manifest' },
	{ id: 'markers', label: 'Markers' },
	{ id: 'timecode-and-sync', label: 'Timecode and sync' },
	{ id: 'api', label: 'The API' },
	{ id: 'api/reference', label: 'API reference' },
	{ id: 'menu-bar-app', label: 'The menu bar app' },
	{ id: 'nativephp-app', label: 'The NativePHP app' },
	{ id: 'troubleshooting', label: 'Troubleshooting' },
];

// Pages that are not collection entries but always exist.
export const staticDocs = new Set(['api/reference']);

export const docsHref = (id: string) => (id === 'index' ? '/docs' : `/docs/${id}`);

export function neighbours(id: string, existing: Set<string>) {
	const i = docsNav.findIndex((e) => e.id === id);
	const prev = docsNav.slice(0, Math.max(i, 0)).reverse().find((e) => existing.has(e.id));
	const next = docsNav.slice(i + 1).find((e) => existing.has(e.id));
	return { prev, next };
}
