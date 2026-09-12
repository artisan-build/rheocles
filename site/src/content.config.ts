import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

// The docs tree. Order and labels live in src/lib/docs-nav.ts, not in
// frontmatter, so the sidebar is one list that can be read top to bottom.
export const collections = {
	docs: defineCollection({
		loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/docs' }),
		schema: z.object({
			title: z.string(),
			description: z.string(),
			// Written against the spec ahead of the code. Renders with a banner.
			draft: z.boolean().default(false),
		}),
	}),
};
