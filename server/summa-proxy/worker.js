// Summa annotation proxy — Cloudflare Worker.
//
// Sits between the Summa app and the Anthropic API. The app sends only the
// visible screen text; this Worker holds the Anthropic key, builds the
// annotation prompt, calls the model, and returns the annotations. The key
// never ships in the app, and a leaked access code can only annotate
// literature (the prompt is built here, not sent by the client).
//
// Auth, two ways:
//   1. Shared per-tester access codes (SUMMA_ACCESS_TOKENS).
//   2. Sign in with Apple + email allowlist: the app posts Apple's identity
//      token to /session; if the email is allowed we mint a 30-day HS256
//      session token the app then uses on /annotate.
//
// Config (Worker vars/secrets):
//   ANTHROPIC_API_KEY   (secret)   the only place the key lives
//   SUMMA_ACCESS_TOKENS (secret)   comma-separated access codes        [optional]
//   APPLE_BUNDLE_ID     (var)      audience to verify on Apple tokens  [sign-in]
//   SUMMA_SESSION_SECRET(secret)   HMAC key for session tokens         [sign-in]
//   SUMMA_ALLOWED_EMAILS(secret)   comma-separated allowlist           [sign-in]
//   ANNOTATION_MODEL    (var)      default "claude-sonnet-4-6"
//   MAX_TEXT_CHARS      (var)      default "12000"

import { createRemoteJWKSet, jwtVerify, SignJWT } from "jose";

const VALID_TYPES = new Set(["allusion", "context", "callback", "philology", "interpretation"]);
const APPLE_ISSUER = "https://appleid.apple.com";
const SESSION_ISSUER = "summa-proxy";

// JWKS set is created once per isolate and cached across requests.
let appleJWKS = null;
function getAppleJWKS() {
  if (!appleJWKS) appleJWKS = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
  return appleJWKS;
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
}

function config(env) {
  return {
    apiKey: env.ANTHROPIC_API_KEY,
    model: env.ANNOTATION_MODEL || "claude-sonnet-4-6",
    maxChars: parseInt(env.MAX_TEXT_CHARS || "12000", 10),
    accessTokens: new Set((env.SUMMA_ACCESS_TOKENS || "").split(",").map((t) => t.trim()).filter(Boolean)),
    bundleId: (env.APPLE_BUNDLE_ID || "").trim(),
    sessionSecret: (env.SUMMA_SESSION_SECRET || "").trim(),
    allowed: new Set((env.SUMMA_ALLOWED_EMAILS || "").split(",").map((e) => e.trim().toLowerCase()).filter(Boolean)),
  };
}

function buildPrompt(visibleText, bookContext) {
  const sourceLine = bookContext ? `Source (for your reference only): ${bookContext}\n\n` : "";
  return `You are an editor annotating literature for an intelligent, well-read general reader, in the manner of a Norton Critical Edition.

${sourceLine}The text below is what is currently visible on the reader's screen: a partial view of a longer work, captured by OCR. It may begin or end mid-sentence and contain minor OCR errors. Annotate only what is fully visible here. Do not reference earlier or later parts of the work you cannot see.

<screen>
${visibleText}
</screen>

Return a JSON array. Each element:
{"anchor": "<a short exact substring copied from the text above>", "type": "<allusion|context|philology|interpretation>", "note": "<= 45 words"}

Types:
- allusion: a biblical, classical, literary, or mythological source.
- context: a historical, period, nautical, or ethnographic fact needed to parse the passage.
- philology: an archaic or shifted word meaning, or an etymology, where it carries the sentence.
- interpretation: a critical reading, framed as a reading and not a fact. At most one.

Rules:
- Annotate only what a smart, well-read non-specialist would genuinely miss. Never define common words. Never restate the text. Never summarize plot.
- Be selective: at most roughly one annotation per two sentences. Zero annotations is a correct, valid answer for plain text. Do not pad.
- The anchor must be copied verbatim from the text so it can be located on screen, and must be SHORT: a single word or a short phrase, never a whole sentence.
- One annotation per distinct reference, each anchored to the specific named thing itself -- the exact title, name, place, or term -- NOT the clause around it. Never bundle several references into a single long anchor. When the text quotes a title, anchor exactly that quoted title.
- Terse, factual, confident register. No hedging, no throat-clearing.

For example, in a sentence like: the grand old kings of Pegu placing the title "Lord of the White Elephants" above all their other ascriptions of dominion; and the modern kings of Siam unfurling the same snow-white quadruped
annotate "Pegu", "Lord of the White Elephants", and "Siam" as three separate entries, each with its own short anchor -- never as one long anchor spanning the whole clause.

Return only the JSON array, no other text.`;
}

function parseAnnotations(text) {
  const start = text.indexOf("[");
  const end = text.lastIndexOf("]");
  if (start === -1 || end === -1 || end < start) return [];
  let arr;
  try {
    arr = JSON.parse(text.slice(start, end + 1));
  } catch {
    return [];
  }
  if (!Array.isArray(arr)) return [];
  return arr
    .filter((a) => a && typeof a.anchor === "string" && a.anchor && typeof a.note === "string" && a.note && typeof a.type === "string" && VALID_TYPES.has(a.type))
    .map((a) => ({ anchor: a.anchor, type: a.type, note: a.note }));
}

async function callAnthropic(apiKey, model, prompt) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 30_000);
  try {
    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model, max_tokens: 1500, temperature: 0, messages: [{ role: "user", content: prompt }] }),
      signal: controller.signal,
    });
    if (!resp.ok) return { error: `anthropic ${resp.status}` };
    const j = await resp.json();
    return { text: j?.content?.[0]?.text ?? "", usage: j?.usage };
  } catch (e) {
    return { error: e?.name === "AbortError" ? "timeout" : String(e) };
  } finally {
    clearTimeout(timer);
  }
}

async function emailFromSessionToken(secret, token) {
  try {
    const { payload } = await jwtVerify(token, new TextEncoder().encode(secret), { issuer: SESSION_ISSUER });
    return typeof payload.email === "string" ? payload.email : null;
  } catch {
    return null;
  }
}

export default {
  async fetch(request, env) {
    const cfg = config(env);
    if (!cfg.apiKey) return json({ error: "server misconfigured" }, 500);

    const url = new URL(request.url);
    const signInEnabled = !!(cfg.bundleId && cfg.sessionSecret && cfg.allowed.size > 0);

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, model: cfg.model, signIn: signInEnabled });
    }

    // Sign in with Apple: exchange Apple's identity token for a Summa session token.
    if (request.method === "POST" && url.pathname === "/session") {
      if (!signInEnabled) return json({ error: "sign-in not configured" }, 501);
      let body;
      try {
        body = await request.json();
      } catch {
        return json({ error: "bad request body" }, 400);
      }
      const idToken = typeof body.appleIdentityToken === "string" ? body.appleIdentityToken : "";
      if (!idToken) return json({ error: "appleIdentityToken required" }, 400);

      let claims;
      try {
        const { payload } = await jwtVerify(idToken, getAppleJWKS(), { issuer: APPLE_ISSUER, audience: cfg.bundleId });
        claims = payload;
      } catch (e) {
        console.error(`[session] Apple token rejected: ${e}`);
        return json({ error: "invalid Apple token" }, 401);
      }
      const email = (claims.email || "").toLowerCase();
      if (!cfg.allowed.has(email)) {
        console.log(`[session] denied (not on allowlist): ${email || "no-email"}`);
        return json({ error: "this account is not on the beta allowlist" }, 403);
      }
      const sessionToken = await new SignJWT({ email })
        .setProtectedHeader({ alg: "HS256" })
        .setIssuedAt()
        .setIssuer(SESSION_ISSUER)
        .setExpirationTime("30d")
        .sign(new TextEncoder().encode(cfg.sessionSecret));
      console.log(`[session] issued for ${email}`);
      return json({ sessionToken, email });
    }

    if (request.method !== "POST" || url.pathname !== "/annotate") {
      return json({ error: "not found" }, 404);
    }

    // Auth: a shared access code, or a Summa session token (re-checked against
    // the current allowlist so revoking an email takes effect immediately).
    const authz = request.headers.get("authorization") || "";
    const token = authz.startsWith("Bearer ") ? authz.slice(7).trim() : "";
    let identity = null;
    if (token && cfg.accessTokens.has(token)) {
      identity = `code:${token.slice(0, 6)}`;
    } else if (token && cfg.sessionSecret) {
      const email = await emailFromSessionToken(cfg.sessionSecret, token);
      if (email && cfg.allowed.has(email)) identity = `user:${email}`;
    }
    if (!identity) return json({ error: "invalid or missing credentials" }, 401);

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: "bad request body" }, 400);
    }
    const visibleText = typeof body.visibleText === "string" ? body.visibleText : "";
    const bookContext = typeof body.bookContext === "string" ? body.bookContext : "";
    if (!visibleText.trim()) return json({ error: "visibleText required" }, 400);
    if (visibleText.length > cfg.maxChars) return json({ error: `visibleText exceeds ${cfg.maxChars} chars` }, 413);

    const result = await callAnthropic(cfg.apiKey, cfg.model, buildPrompt(visibleText, bookContext));
    if (result.error) {
      console.error(`[annotate] upstream error: ${result.error}`);
      return json({ error: "upstream failure" }, 502);
    }
    const annotations = parseAnnotations(result.text);
    if (result.usage) {
      const i = result.usage.input_tokens || 0;
      const o = result.usage.output_tokens || 0;
      const cost = (i / 1e6) * 3 + (o / 1e6) * 15;
      console.log(`[annotate] ${identity} in=${i} out=${o} $${cost.toFixed(4)} annotations=${annotations.length}`);
    }
    return json({ annotations });
  },
};
