# Summa annotation proxy (Cloudflare Worker)

A tiny Cloudflare Worker between the Summa app and the Anthropic API. The app
sends only the visible screen text; this Worker holds the Anthropic key, builds
the annotation prompt, calls the model, and returns annotations.

Why:
- **Your API key never ships in the app.** It's a Worker secret.
- **A leaked access code can only annotate literature**, not run arbitrary
  prompts on your bill, because the prompt is built here, not sent by the app.
- **Free and always warm.** Cloudflare Workers have no cold starts and a
  generous free tier (100k requests/day).

## API

- `GET /health` → `{ ok, model, signIn }`
- `POST /session` (Sign in with Apple) — body `{ appleIdentityToken }`, returns
  `{ sessionToken, email }` if the email is on the allowlist.
- `POST /annotate` — `Authorization: Bearer <access code | session token>`,
  body `{ visibleText, bookContext? }`, returns `{ annotations: [...] }`.

## Local dev

```sh
cd server/summa-proxy
npm install
cp .dev.vars.example .dev.vars     # then edit: real ANTHROPIC_API_KEY + an access code
npx wrangler dev --port 8787
```

Smoke test:

```sh
curl -s localhost:8787/annotate \
  -H "Authorization: Bearer test-local-code" \
  -H "Content-Type: application/json" \
  -d '{"visibleText":"Bethink thee of the albatross ... Not Coleridge first threw that spell."}' | jq
```

## Deploy

One-time: a free Cloudflare account, then from `server/summa-proxy`:

```sh
npx wrangler login                              # opens the browser to authorize

# secrets (never committed):
npx wrangler secret put ANTHROPIC_API_KEY       # paste your Anthropic key
npx wrangler secret put SUMMA_ACCESS_TOKENS     # paste an access code (comma-separated for several)

npx wrangler deploy
```

Deploy prints your URL, e.g. `https://summa-proxy.<your-subdomain>.workers.dev`.
Test it: `curl https://…workers.dev/health`.

Non-secret config (model, bundle id, size cap) lives in `wrangler.toml`.

## Adding Sign in with Apple later

Set three more secrets, then redeploy:

```sh
npx wrangler secret put SUMMA_SESSION_SECRET    # node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
npx wrangler secret put SUMMA_ALLOWED_EMAILS    # comma-separated approved emails
# APPLE_BUNDLE_ID is already set in wrangler.toml
npx wrangler deploy
```

`/session` then verifies Apple's identity token and issues a 30-day session
token for allowlisted emails.

## Managing testers

- **Access codes**: `npx wrangler secret put SUMMA_ACCESS_TOKENS` with the new
  comma-separated list, then `npx wrangler deploy`. Remove one to revoke it.
- **Sign-in**: update `SUMMA_ALLOWED_EMAILS` the same way. Revoking an email
  blocks its session token on the next request.
- Usage/cost per request is logged (`npx wrangler tail` to watch live).

## Notes

- No custom rate limiter in code (Workers are stateless per request). If you
  need one, add a Cloudflare **Rate Limiting** rule in the dashboard, or use a
  KV/Durable Object counter.
- `nodejs_compat` is enabled for `jose` (JWT verification).
