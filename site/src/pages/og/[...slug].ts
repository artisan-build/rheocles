// One social card per page, generated at build: limestone ground, the mark,
// an Aegean bar on the leading edge, Fraunces title, Instrument Sans line.
// Slugs match page paths: /og/index.png, /og/docs/markers.png, /og/404.png.
import { getCollection } from 'astro:content';
import { OGImageRoute } from 'astro-og-canvas';

const docs = await getCollection('docs');

const pages: Record<string, { title: string; description: string }> = {
	index: {
		title: 'Every stream, its own file, on one cue.',
		description: 'Cameras, microphones, displays, windows — each to its own file, time-of-day timecode in every one. Free, open source, MIT.',
	},
	'404': { title: 'Not found.', description: 'Nothing at this path. The manifest would have said.' },
	'docs/api/reference': {
		title: 'API reference',
		description: 'Every route, on both transports — generated from docs/openapi.yaml.',
	},
	...Object.fromEntries(
		docs.map((e) => [
			e.id === 'index' ? 'docs/index' : `docs/${e.id}`,
			{ title: e.data.title, description: e.data.description },
		]),
	),
};

export const { getStaticPaths, GET } = await OGImageRoute({
	param: 'slug',
	pages,
	getImageOptions: (_id, page) => ({
		title: page.title,
		description: page.description,
		logo: { path: './src/assets/og-mark.png', size: [84] },
		bgGradient: [[250, 242, 228]],
		border: { color: [46, 92, 134], width: 18, side: 'inline-start' },
		padding: 72,
		font: {
			title: {
				color: [42, 33, 26],
				size: 62,
				weight: 'Bold',
				lineHeight: 1.12,
				families: ['Fraunces'],
			},
			description: {
				color: [78, 64, 52],
				size: 28,
				lineHeight: 1.4,
				families: ['Instrument Sans'],
			},
		},
		fonts: ['./src/assets/og-fonts/Fraunces.ttf', './src/assets/og-fonts/InstrumentSans.ttf'],
	}),
});
