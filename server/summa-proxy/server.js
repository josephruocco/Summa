// Summa annotation proxy.
//
// Sits between the Summa app and the Anthropic API. The app sends only the
// visible screen text; this server holds the Anthropic key, builds the
// annotation prompt, calls the model, and returns the annotations. That means
// the key never ships in the app, and a leaked access code can only be used to
// annotate literature -- not to run arbitrary prompts on your bill.
//
// Zero dependencies: Node 18+ built-in http + global fetch. Run: `node server.js`.
//
// Required env:
//   ANTHROPIC_API_KEY    your Anthropic API key (the only place it lives)
//   SUMMA_ACCESS_TOKENS  comma-separated list of valid beta access codes
// Optional env:
//   ANNOTATION_MODEL     default "claude-sonnet-4-6"
//   PORT                 default 8787
//   RATE_LIMIT_PER_MIN   max requests per access code per minute, default 40
//   MAX_TEXT_CHARS       reject bodies whose visibleText exceeds this, default 12000

import http from "node:http";
import { createRemoteJWKSet, jwtVerify, SignJWT } from "jose";

const MODEL = process.env.ANNOTATION_MODEL || "claude-sonnet-4-6";
const PORT = parseInt(process.env.PORT || "8787", 10);
const RATE_LIMIT_PER_MIN = parseInt(process.env.RATE_LIMIT_PER_MIN || "40", 10);
const MAX_TEXT_CHARS = parseInt(process.env.MAX_TEXT_CHARS || "12000", 10);

const API_KEY = process.env.ANTHROPIC_API_KEY;

// Auth path 1: shared per-tester access codes (simplest).
const ACCESS_TOKENS = new Set(
  (process.env.SUMMA_ACCESS_TOKENS || "").split(",").map((t) => t.trim()).filter(Boolean)
);

// Auth path 2: Sign in with Apple + an email allowlist. The app sends Apple's
// identity token to /session; if the email is on the allowlist, we issue our
// own 30-day session token (HS256, signed with SUMMA_SESSION_SECRET) that the
// app then uses on /annotate. That way Apple is only touched once at sign-in.
const APPLE_BUNDLE_ID = (process.env.APPLE_BUNDLE_ID || "").trim();
const SESSION_SECRET = (process.env.SUMMA_SESSION_SECRET || "").trim();
const ALLOWED_EMAILS = new Set(
  (process.env.SUMMA_ALLOWED_EMAILS || "").split(",").map((e) => e.trim().toLowerCase()).filter(Boolean)
);
const APPLE_ISSUER = "https://appleid.apple.com";
const appleJWKS = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));
const SESSION_ISSUER = "summa-proxy";
const signInEnabled = !!(APPLE_BUNDLE_ID && SESSION_SECRET && ALLOWED_EMAILS.size > 0);

if (!API_KEY) {
  console.error("FATAL: ANTHROPIC_API_KEY is not set.");
  process.exit(1);
}
if (ACCESS_TOKENS.size === 0 && !signInEnabled) {
  console.error(
    "FATAL: no auth configured. Set SUMMA_ACCESS_TOKENS, or all of APPLE_BUNDLE_ID + SUMMA_SESSION_SECRET + SUMMA_ALLOWED_EMAILS."
  );
  process.exit(1);
}

const sessionKey = SESSION_SECRET ? new TextEncoder().encode(SESSION_SECRET) : null;

function emailAllowed(email) {
  return !!email && ALLOWED_EMAILS.has(String(email).toLowerCase());
}

// Verify Apple's identity token: signature against Apple's JWKS, correct
// issuer, and audience == your app's bundle id. Throws if anything is off.
async function verifyAppleIdentityToken(token) {
  const { payload } = await jwtVerify(token, appleJWKS, {
    issuer: APPLE_ISSUER,
    audience: APPLE_BUNDLE_ID,
  });
  return payload; // includes email, sub, exp
}

async function issueSessionToken(email) {
  return await new SignJWT({ email: String(email).toLowerCase() })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setIssuer(SESSION_ISSUER)
    .setExpirationTime("30d")
    .sign(sessionKey);
}

// Returns the email if the token is one of our valid, unexpired session tokens.
async function emailFromSessionToken(token) {
  if (!sessionKey) return null;
  try {
    const { payload } = await jwtVerify(token, sessionKey, { issuer: SESSION_ISSUER });
    return typeof payload.email === "string" ? payload.email : null;
  } catch {
    return null;
  }
}

// ponytail: in-memory fixed-window rate limiter, per access code. Resets on
// restart and is per-instance, so it won't hold across a multi-instance
// deployment -- fine for a single-instance beta. Swap for a shared store
// (Redis/Upstash) if you scale horizontally.
const windowHits = new Map(); // token -> { windowStart, count }
function rateLimited(token) {
  const now = Date.now();
  const slot = windowHits.get(token);
  if (!slot || now - slot.windowStart >= 60_000) {
    windowHits.set(token, { windowStart: now, count: 1 });
    return false;
  }
  slot.count += 1;
  return slot.count > RATE_LIMIT_PER_MIN;
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

// Pull the JSON array out of the model's reply and keep only well-formed,
// correctly-typed entries. The app also re-validates, but sanitizing here keeps
// junk off the wire.
const VALID_TYPES = new Set(["allusion", "context", "callback", "philology", "interpretation"]);
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
    .filter(
      (a) =>
        a && typeof a.anchor === "string" && a.anchor &&
        typeof a.note === "string" && a.note &&
        typeof a.type === "string" && VALID_TYPES.has(a.type)
    )
    .map((a) => ({ anchor: a.anchor, type: a.type, note: a.note }));
}

function send(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(body);
}

async function callAnthropic(prompt) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 30_000);
  try {
    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 1500,
        temperature: 0,
        messages: [{ role: "user", content: prompt }],
      }),
      signal: controller.signal,
    });
    if (!resp.ok) return { error: `anthropic ${resp.status}` };
    const json = await resp.json();
    const text = json?.content?.[0]?.text ?? "";
    return { text, usage: json?.usage };
  } catch (e) {
    return { error: String(e?.name === "AbortError" ? "timeout" : e) };
  } finally {
    clearTimeout(timeout);
  }
}

function readBody(req, limitBytes) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > limitBytes) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    return send(res, 200, { ok: true, model: MODEL, signIn: signInEnabled });
  }

  // Exchange an Apple identity token for a Summa session token (Sign in with Apple).
  if (req.method === "POST" && req.url === "/session") {
    if (!signInEnabled) return send(res, 501, { error: "sign-in not configured" });
    let payload;
    try {
      payload = JSON.parse(await readBody(req, 16 * 1024));
    } catch {
      return send(res, 400, { error: "bad request body" });
    }
    const idToken = typeof payload.appleIdentityToken === "string" ? payload.appleIdentityToken : "";
    if (!idToken) return send(res, 400, { error: "appleIdentityToken required" });

    let claims;
    try {
      claims = await verifyAppleIdentityToken(idToken);
    } catch (e) {
      console.error(`[session] Apple token rejected: ${e}`);
      return send(res, 401, { error: "invalid Apple token" });
    }
    const email = (claims.email || "").toLowerCase();
    if (!emailAllowed(email)) {
      console.log(`[session] denied (not on allowlist): ${email || "no-email"}`);
      return send(res, 403, { error: "this account is not on the beta allowlist" });
    }
    const sessionToken = await issueSessionToken(email);
    console.log(`[session] issued for ${email}`);
    return send(res, 200, { sessionToken, email });
  }

  if (req.method !== "POST" || req.url !== "/annotate") {
    return send(res, 404, { error: "not found" });
  }

  // Auth on /annotate: Bearer is either a shared access code, or a Summa
  // session token issued at sign-in. Session tokens are re-checked against the
  // current allowlist so revoking an email takes effect immediately.
  const auth = req.headers["authorization"] || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  let identity = null;
  if (token && ACCESS_TOKENS.has(token)) {
    identity = `code:${token.slice(0, 6)}`;
  } else if (token) {
    const email = await emailFromSessionToken(token);
    if (email && emailAllowed(email)) identity = `user:${email}`;
  }
  if (!identity) {
    return send(res, 401, { error: "invalid or missing credentials" });
  }
  if (rateLimited(identity)) {
    return send(res, 429, { error: "rate limit exceeded, slow down" });
  }

  let payload;
  try {
    const raw = await readBody(req, 64 * 1024);
    payload = JSON.parse(raw);
  } catch {
    return send(res, 400, { error: "bad request body" });
  }

  const visibleText = typeof payload.visibleText === "string" ? payload.visibleText : "";
  const bookContext = typeof payload.bookContext === "string" ? payload.bookContext : "";
  if (!visibleText.trim()) return send(res, 400, { error: "visibleText required" });
  if (visibleText.length > MAX_TEXT_CHARS) {
    return send(res, 413, { error: `visibleText exceeds ${MAX_TEXT_CHARS} chars` });
  }

  const result = await callAnthropic(buildPrompt(visibleText, bookContext));
  if (result.error) {
    console.error(`[annotate] upstream error: ${result.error}`);
    return send(res, 502, { error: "upstream failure" });
  }

  const annotations = parseAnnotations(result.text);
  if (result.usage) {
    const { input_tokens: i = 0, output_tokens: o = 0 } = result.usage;
    // Rough Sonnet pricing ($3/M in, $15/M out) for at-a-glance cost tracking.
    const cost = (i / 1e6) * 3 + (o / 1e6) * 15;
    console.log(`[annotate] ${identity} in=${i} out=${o} $${cost.toFixed(4)} annotations=${annotations.length}`);
  }
  return send(res, 200, { annotations });
});

server.listen(PORT, () => {
  console.log(
    `Summa proxy listening on :${PORT} (model ${MODEL}, ${ACCESS_TOKENS.size} access code(s), sign-in ${signInEnabled ? "on" : "off"})`
  );
});
