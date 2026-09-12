# www.rheocles.com → rheocles.com, 301

Decided (orchestrator, 12 Sep 2026): www redirects to the apex. Not yet done.

Both hostnames are attached to the Pages project and both serve the site.
A Pages `_redirects` file matches paths only, not hosts, so the redirect
cannot live in `site/`. A Pages Function middleware could do it, but that
puts a Worker in front of every request of a static site to handle one
hostname; the right tool is a zone **Redirect Rule**, which runs at the edge
and costs nothing.

The repo's `CLOUDFLARE_API_TOKEN` is scoped to Pages and cannot read or
write zone rulesets (`Authentication error` on
`/zones/{zone}/rulesets/phases/http_request_dynamic_redirect/entrypoint`).
So this is either one click in the dashboard or one call with a token that
has *Zone → Dynamic Redirect → Edit* for `rheocles.com`
(zone `39553960ee6b4a10a17e60b2b23b9c89`).

**Dashboard:** rheocles.com → Rules → Redirect Rules → Create → template
*Redirect from WWW to Root* → deploy. It writes exactly the rule below.

**API:**

```sh
curl -X PUT "https://api.cloudflare.com/client/v4/zones/39553960ee6b4a10a17e60b2b23b9c89/rulesets/phases/http_request_dynamic_redirect/entrypoint" \
  -H "Authorization: Bearer $ZONE_TOKEN" -H "Content-Type: application/json" \
  --data '{ "rules": [ {
    "description": "www to apex",
    "expression": "(http.host eq \"www.rheocles.com\")",
    "action": "redirect",
    "action_parameters": { "from_value": {
      "status_code": 301, "preserve_query_string": true,
      "target_url": { "expression": "concat(\"https://rheocles.com\", http.request.uri.path)" } } }
  } ] }'
```

**Verify:** `curl -sI https://www.rheocles.com/docs | head -3` → `301` with
`location: https://rheocles.com/docs`. Then delete this note.
