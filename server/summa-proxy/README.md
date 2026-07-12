# Summa annotation proxy

A tiny server that sits between the Summa app and the Anthropic API. The app
sends only the visible screen text; this server holds the Anthropic key, builds
the annotation prompt, calls the model, and returns annotations.

Why it exists:
- **Your API key never ships in the app.** It lives only as a server secret.
- **A leaked access code can only annotate literature**, not run arbitrary
  prompts on your bill, because the prompt is built here, not sent by the app.
- **You control cost**: per-code rate limiting and one place to see usage.

## API

`POST /annotate`
- Header: `Authorization: Bearer <access code>`
- Body: `{"visibleText": "...", "bookContext": "optional source label"}`
- Returns: `{"annotations": [{"anchor": "...", "type": "allusion|context|philology|interpretation", "note": "..."}]}`

`GET /health` → `{"ok": true, "model": "..."}`

## Run locally

```sh
cd server/summa-proxy
cp .env.example .env          # then edit: real ANTHROPIC_API_KEY + at least one access code
node --env-file=.env server.js
```

Smoke test:

```sh
curl -s localhost:8787/annotate \
  -H "Authorization: Bearer <one of your codes>" \
  -H "Content-Type: application/json" \
  -d '{"visibleText":"Bethink thee of the albatross, whence come those clouds of spiritual wonderment and pale dread, in which that white phantom sails in all imaginations? Not Coleridge first threw that spell."}' | jq
```

## Deploy

Zero dependencies, one file, reads config from env. Any Node 18+ host works.
Easiest options (all have a free/cheap tier and manage secrets for you):

- **Render** (web service): connect the repo, root dir `server/summa-proxy`,
  build command empty, start command `node server.js`, add env vars in the
  dashboard. Gives you an HTTPS URL.
- **Railway / Fly.io**: same idea; `node server.js` as the start command.
- **Your own VPS**: `node --env-file=.env server.js` behind nginx/caddy for TLS.

Set these as secrets/env on the host (NOT in the repo):
- `ANTHROPIC_API_KEY`
- `SUMMA_ACCESS_TOKENS` — comma-separated, one code per tester

After deploy you get a base URL like `https://summa-proxy.onrender.com`. In the
Summa app settings, set the proxy URL to that and give each tester their access
code. That's it.

## Managing testers

Generate a code:

```sh
node -e "console.log(require('crypto').randomBytes(16).toString('hex'))"
```

Add it to `SUMMA_ACCESS_TOKENS` (comma-separated) and redeploy. Remove a code to
revoke that tester. Each request logs `token=<first 6 chars>… in=… out=… $cost`
so you can see per-tester usage in the host's logs.

## Notes / ceilings

- Rate limiting is in-memory and per-instance (resets on restart). Fine for a
  single-instance beta; use a shared store (Redis/Upstash) if you run multiple
  instances.
- HTTPS is provided by the host (Render/Railway/Fly) or your reverse proxy. The
  app should always talk to the proxy over `https://` in production so access
  codes aren't sent in the clear.
