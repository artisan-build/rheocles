// @ts-check
import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';
import expressiveCode from 'astro-expressive-code';
import pagefind from 'astro-pagefind';

// Plain Astro, deliberately not Starlight. The docs are a designed product
// surface with the same header as the landing page, a sidebar we control, and
// an API reference generated from docs/openapi.yaml; Starlight's chrome would
// be something to fight rather than use. What Starlight would have supplied
// is assembled from parts: content collections (Astro core), code blocks
// (expressive-code, the same engine Starlight ships), search (pagefind).
export default defineConfig({
	site: 'https://rheocles.com',
	trailingSlash: 'never',
	build: { format: 'file' },
	integrations: [
		expressiveCode({
			// Dark blocks on a light page, as on sonocles.com. Fonts and colours
			// are overridden in src/styles/code.css so the theme stays in one place.
			themes: ['github-dark-dimmed'],
			// Long lines wrap rather than scroll; a reference is read, not copied wholesale.
			defaultProps: { wrap: true, preserveIndent: true },
			styleOverrides: {
				borderRadius: '10px',
				codeFontFamily: "'IBM Plex Mono', ui-monospace, SFMono-Regular, Menlo, monospace",
				codeFontSize: '0.86rem',
				frames: { shadowColor: 'transparent' },
			},
		}),
		mdx(),
		pagefind(),
	],
});
