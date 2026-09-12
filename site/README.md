# rheocles.com

Astro, plain — not Starlight. The docs are a designed surface with the same
header as the landing page and an API reference generated from
`docs/openapi.yaml`; assembling sidebar, search (pagefind) and code blocks
(expressive-code) from parts costs less than fighting a theme's chrome.

    pnpm install
    pnpm dev        # http://localhost:4321
    pnpm build      # → dist/, what Cloudflare Pages serves

Deploys on every push to `main` touching `site/` via
`.github/workflows/deploy-site.yml`. For a preview URL from a branch:

    export CLOUDFLARE_API_TOKEN="$(grep '^CLOUDFLARE_API_TOKEN=' ../.env | cut -d= -f2-)"
    pnpm deploy:preview

Brand: `../docs/BRAND.md`. Docs tree: `src/lib/docs-nav.ts`. Pages written
ahead of the code carry `draft: true` and render with a banner.

## What the build produces

- Pages under `src/pages/` and `src/content/docs/`; the docs tree order is
  `src/lib/docs-nav.ts`.
- The API reference at `/docs/api/reference` from `../docs/openapi.yaml`
  (every route the YAML pins) merged with `src/lib/api-spec.ts` (routes the
  spec names that the YAML does not have yet, marked *planned*). The YAML is
  read at build time, so a change to it needs a site deploy to show.
- A social card per page under `/og/…png` (`src/pages/og/[...slug].ts`,
  astro-og-canvas, fonts in `src/assets/og-fonts/` under the OFL).
- `sitemap-index.xml`, `robots.txt`, `404.html`, the favicon set
  (`public/`, rasterised once from the mark).

Plates: `../art/make.py`; prompts and the approval log in `ART.md`.
