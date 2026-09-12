# rheocles.com is serving a one-line placeholder

Deployed once from a temp directory by Rheo Infra so the custom domain could
activate (`<p>Rheocles — coming soon.</p>`, deployment `ce177d96`). Nothing
in the repo produces it. Rheo Site replaces it with the first Astro build via
`.github/workflows/deploy-site.yml`; that workflow currently fails on
`site/pnpm-lock.yaml` not existing and starts passing when the Astro project
lands. `www.rheocles.com` serves the same content — no redirect to the apex
is configured; decide whether Site wants one (Pages "Bulk Redirects" or a
`_redirects` file).
