// The docs tree, in reading order. Approved with the brand (11 Sep 2026);
// each entry is a collection id under src/content/docs. A page that does not
// exist yet still appears in the sidebar, unlinked, so the shape of the docs
// is visible before every page is.
export interface NavEntry {
	id: string;
	label: string;
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

export const docsHref = (id: string) => (id === 'index' ? '/docs' : `/docs/${id}`);
