// One social card per page, generated at build: limestone ground, the
// family strip (mark, wordmark, pronunciation) and the pill, an Aegean bar
// on the leading edge, Fraunces title, Instrument Sans line. Slugs match
// page paths: /og/docs/markers.png, /og/404.png.
//
// The landing page is not here on purpose. Its card is composed by hand
// (public/og/index.png, source in ../../../og.html) so the hero plate can
// sit beside the tagline; a title on limestone would not be the same card.
//
// astro-og-canvas takes one logo and no second text block, so the strip is
// the logo (src/assets/og-strip.png, from ../../../og-strip.html) and the
// pill is a transparent full-size background layer (src/assets/og-pill.png,
// from ../../../og-pill.html) composed under it. Both are rendered by
// art/og.mjs; the sources say how.
import { getCollection } from 'astro:content';
import { OGImageRoute } from 'astro-og-canvas';

const docs = await getCollection('docs');

const pages: Record<string, { title: string; description: string }> = {
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
		logo: { path: './src/assets/og-strip.png', size: [320, 44] },
		bgImage: { path: './src/assets/og-pill.png', fit: 'none', position: 'center' },
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
