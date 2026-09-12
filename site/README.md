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
