# dj-proxy — DJ's Cloudflare Worker API-key proxy

DJ's Cloud layer (Layer 2, PORTING-SPEC.md §3.3) talks to OpenAI, OpenRouter
and Anthropic for chat, AssemblyAI for streaming transcription, and
ElevenLabs for text-to-speech. **The API keys must never ship inside the app.**
This Worker sits in between: the app talks to the Worker, the Worker talks to
the providers, and the keys live only as Worker secrets.

## Routes

| Route | Method | Body / result |
|---|---|---|
| `/health` | GET | `{ ok: true }` — the app checks the Worker is up. |
| `/chat` | POST | `{ provider: "openai" \| "openrouter" \| "anthropic", model, messages: [{ role, content }] }` → streamed reply as OpenAI-style SSE (`data: {"choices":[{"delta":{"content":"..."}}]}`, ends with `data: [DONE]`). Anthropic's different request/response shape is handled inside the Worker and its stream is converted to the same OpenAI-style SSE, so the app parses one shape. |
| `/tts` | POST | `{ text, voiceId? }` → audio bytes (`audio/mpeg`). Uses `ELEVENLABS_API_KEY`; `voiceId` defaults to the `ELEVENLABS_VOICE_ID` var. Text max 5000 characters. |
| `/transcribe-token` | GET | `{ ok: true, token, expiresInSeconds: 300 }` — a short-lived AssemblyAI realtime token for the app's streaming transcription. **The raw AssemblyAI key is never returned.** |

Every route: 10 s timeout per provider call. No message contents and no keys
are ever logged. Failures are `{ ok: false, message }`.

**Key-expired signal (matches PORTING-SPEC.md §3.3):** if a provider answers
401/403, the Worker returns that same status with
`{ ok: false, message: "cloud key expired" }` and never retries. DJ's
capability layer treats that as "fall back to Local/Core" and says so in the
UI. Any other provider failure returns 502 with a plain message.

**CORS:** the Flutter app (dart:io) sends no `Origin` header, so it is never
blocked. A browser request is only allowed if its Origin is listed in the
`ALLOWED_ORIGINS` var (unset = browser origins rejected). In production, set
`ALLOWED_ORIGINS` only if a web build of DJ ever needs it.

## Setup (do once, on your own Cloudflare account)

Prerequisites: a free Cloudflare account, Node.js 18+.

```bash
# 1. Install dependencies
cd worker
npm install

# 2. Set the 5 secrets (wrangler prompts for each value; nothing is written to a file)
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put OPENROUTER_API_KEY
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# 3. (Optional) set your default ElevenLabs voice id in wrangler.toml
#    (ELEVENLABS_VOICE_ID) — it is not a secret, so it can live in the file.

# 4. Deploy
npx wrangler deploy
```

Wrangler prints the Worker URL, normally
`https://dj-proxy.<your-subdomain>.workers.dev`.

## Connect DJ to it

In DJ: **Settings → Cloud → Worker URL**, paste the Worker URL above. That is
the only cloud setting the app holds. DJ's `dj_config.json` must **not**
contain a `cloud.apiKey` any more — the key lives in the Worker now.

## Test each route (replace the URL with yours)

```bash
URL=https://dj-proxy.<your-subdomain>.workers.dev

# health
curl $URL/health
# → {"ok":true}

# chat (OpenAI) — streams SSE chunks
curl -N -X POST $URL/chat \
  -H 'content-type: application/json' \
  -d '{"provider":"openai","model":"gpt-4o-mini","messages":[{"role":"user","content":"Say hi in five words."}]}'

# chat (Anthropic) — same SSE shape back
curl -N -X POST $URL/chat \
  -H 'content-type: application/json' \
  -d '{"provider":"anthropic","model":"claude-sonnet-4-5","messages":[{"role":"user","content":"Say hi in five words."}]}'

# tts — saves an mp3
curl -X POST $URL/tts \
  -H 'content-type: application/json' \
  -d '{"text":"Hi, I am DJ."}' --output dj-test.mp3

# transcribe token — returns a temporary token, never the raw key
curl $URL/transcribe-token
# → {"ok":true,"token":"...","expiresInSeconds":300}
```

If a chat call returns `{"ok":false,"message":"cloud key expired"}` with a
401/403 status, that provider's key is wrong or expired: set a fresh key with
`npx wrangler secret put <NAME>` and redeploy is **not** needed — secrets take
effect immediately.

## The rule, in one line

**The app NEVER holds a provider key.** If a key is ever pasted into the app
(or into `dj_config.json`) by mistake, revoke that key at the provider, delete
it from the app/config, and put the fresh key in the Worker with
`npx wrangler secret put <NAME>`.

## Local checks (no deploy needed)

```bash
npm run typecheck   # tsc --noEmit
npx wrangler dev    # run the Worker locally for testing
```
