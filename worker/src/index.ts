// DJ Cloudflare Worker proxy — dj-proxy
//
// DJ (Flutter, Windows + Android) NEVER holds an AI provider key inside the
// app. The app talks only to this Worker; the Worker holds the keys as
// Cloudflare secrets and forwards requests to the providers.
//
// Providers (PORTING-SPEC.md §3.3): openai, openrouter, anthropic, plus
// the three free OpenAI-compatible ones: gemini, groq, nvidia.
// Voice (PORTING-SPEC.md §4): AssemblyAI (streaming transcription token)
// and ElevenLabs (text-to-speech).
//
// Rules enforced here:
// - No request or response body is ever logged, and no secret is ever logged.
// - A 401/403 from a provider means the key is expired/invalid: return the
//   provider's status with the plain message "cloud key expired" and NEVER
//   retry — DJ falls back to Local/Core on that signal.
// - Every provider call has a 10 s timeout (AbortSignal.timeout).
// - Failures are always { ok: false, message: "<plain message>" }.
//
// Plain TypeScript, no framework. Requires only `wrangler` to deploy.

export interface Env {
  OPENAI_API_KEY: string;
  OPENROUTER_API_KEY: string;
  ANTHROPIC_API_KEY: string;
  // Free providers (all OpenAI-compatible /chat/completions):
  // Gemini — key from Google AI Studio (aistudio.google.com).
  GEMINI_API_KEY: string;
  // Groq — key from console.groq.com → API Keys.
  GROQ_API_KEY: string;
  // NVIDIA NIM — key from build.nvidia.com (free NVIDIA Developer
  // Program account, prototyping only).
  NVIDIA_API_KEY: string;
  ASSEMBLYAI_API_KEY: string;
  ELEVENLABS_API_KEY: string;
  /** Non-secret. Default ElevenLabs voice used when the app sends no voiceId. */
  ELEVENLABS_VOICE_ID: string;
  /**
   * Non-secret, optional. Comma-separated browser origins allowed through
   * CORS, e.g. "https://dj.example.com". The Flutter app (dart:io) sends no
   * Origin header, so it is never blocked by this. A browser request whose
   * Origin is not on this list is rejected. Leave empty and browser-origin
   * requests are rejected; set it only if a web build of DJ ever needs it.
   */
  ALLOWED_ORIGINS?: string;
}

const PROVIDER_TIMEOUT_MS = 10_000;
const ANTHROPIC_VERSION = '2023-06-01';
const ANTHROPIC_MAX_TOKENS = 4096;
// AssemblyAI realtime tokens are short-lived on purpose: 5 minutes.
const ASSEMBLYAI_TOKEN_TTL_SECONDS = 300;
const ELEVENLABS_MODEL_ID = 'eleven_turbo_v2_5';

type Provider = 'openai' | 'openrouter' | 'anthropic' | 'gemini' | 'groq' | 'nvidia';

const PROVIDERS: Provider[] = [
  'openai',
  'openrouter',
  'anthropic',
  'gemini',
  'groq',
  'nvidia',
];

interface ChatTextPart {
  type: 'text';
  text: string;
}

interface ChatImagePart {
  type: 'image_url';
  image_url: { url: string };
}

type ChatPart = ChatTextPart | ChatImagePart;

/** A data: URL image, split into its media type and base64 payload. */
interface DataImage {
  mediaType: string;
  data: string;
}

/**
 * Parse a `data:image/...;base64,...` URL. Returns null for anything
 * else (remote http(s) URLs are rejected on purpose: the Worker only
 * forwards images the app itself captured and base64-encoded).
 */
function parseDataImageUrl(url: string): DataImage | null {
  const match = /^data:(image\/[a-zA-Z0-9.+-]+);base64,([A-Za-z0-9+/=]+)$/.exec(url);
  if (match === null) return null;
  return { mediaType: match[1], data: match[2] };
}

// Vision guardrails: screenshots are PNGs of a few hundred KB. Reject
// anything absurd so one bad request cannot blow up the Worker.
const MAX_IMAGE_BASE64_CHARS = 5_000_000; // ~3.75 MB of image bytes
const MAX_IMAGES_PER_MESSAGE = 4;

interface ChatMessage {
  role: string;
  content: string | ChatPart[];
}

function json(body: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...extraHeaders },
  });
}

function errorJson(message: string, status = 500): Response {
  return json({ ok: false, message }, status);
}

/** CORS headers for this request, or null when the Origin is not allowed. */
function corsHeaders(request: Request, env: Env): Record<string, string> | null {
  const origin = request.headers.get('Origin');
  // Native app requests (Flutter dart:io) carry no Origin header: allow them.
  if (origin === null) return {};
  const allowed = (env.ALLOWED_ORIGINS ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (allowed.includes(origin)) {
    return { 'access-control-allow-origin': origin, vary: 'Origin' };
  }
  return null;
}

function withCors(response: Response, cors: Record<string, string>): Response {
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(cors)) headers.set(k, v);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function isAuthError(status: number): boolean {
  return status === 401 || status === 403;
}

async function readJsonBody(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    return null;
  }
}

function parseChatBody(body: unknown): { provider: Provider; model: string; messages: ChatMessage[] } | null {
  if (typeof body !== 'object' || body === null) return null;
  const b = body as Record<string, unknown>;
  if (typeof b.provider !== 'string' || !(PROVIDERS as string[]).includes(b.provider)) return null;
  if (typeof b.model !== 'string' || b.model.trim() === '') return null;
  if (!Array.isArray(b.messages)) return null;
  const messages: ChatMessage[] = [];
  for (const m of b.messages) {
    if (typeof m !== 'object' || m === null) return null;
    const msg = m as Record<string, unknown>;
    if (typeof msg.role !== 'string') return null;
    const content = parseMessageContent(msg.content);
    if (content === null) return null;
    messages.push({ role: msg.role, content });
  }
  if (messages.length === 0) return null;
  return { provider: b.provider as Provider, model: b.model, messages };
}

/**
 * A message's content is either a plain string (text only) or an
 * OpenAI-style parts array: `{type:'text', text}` and/or
 * `{type:'image_url', image_url:{url}}` where the URL must be a
 * `data:image/...;base64,...` URL. Anything else is rejected.
 */
function parseMessageContent(content: unknown): string | ChatPart[] | null {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content) || content.length === 0) return null;
  const parts: ChatPart[] = [];
  let images = 0;
  for (const p of content) {
    if (typeof p !== 'object' || p === null) return null;
    const part = p as Record<string, unknown>;
    if (part.type === 'text') {
      if (typeof part.text !== 'string') return null;
      parts.push({ type: 'text', text: part.text });
    } else if (part.type === 'image_url') {
      if (typeof part.image_url !== 'object' || part.image_url === null) return null;
      const url = (part.image_url as Record<string, unknown>).url;
      if (typeof url !== 'string') return null;
      const image = parseDataImageUrl(url);
      if (image === null) return null;
      if (image.data.length > MAX_IMAGE_BASE64_CHARS) return null;
      images += 1;
      if (images > MAX_IMAGES_PER_MESSAGE) return null;
      parts.push({ type: 'image_url', image_url: { url } });
    } else {
      return null;
    }
  }
  return parts;
}

/**
 * Build the provider request for a chat call. OpenAI and OpenRouter share the
 * /chat/completions shape; Anthropic uses /v1/messages with a different shape
 * (system is a top-level field, messages are user/assistant only, max_tokens
 * is required).
 */
/**
 * Convert one message's content to Anthropic's shape: a plain string
 * stays a string; a parts array becomes an array of blocks, with
 * image_url parts turned into base64 image blocks.
 */
function toAnthropicContent(
  content: string | ChatPart[],
): string | Array<{ type: string; text?: string; source?: { type: string; media_type: string; data: string } }> {
  if (typeof content === 'string') return content;
  const blocks: Array<{ type: string; text?: string; source?: { type: string; media_type: string; data: string } }> = [];
  for (const part of content) {
    if (part.type === 'text') {
      blocks.push({ type: 'text', text: part.text });
    } else {
      // parseMessageContent already validated this URL.
      const image = parseDataImageUrl(part.image_url.url)!;
      blocks.push({
        type: 'image',
        source: { type: 'base64', media_type: image.mediaType, data: image.data },
      });
    }
  }
  return blocks;
}

/** Plain text of a message, for Anthropic's top-level `system` field. */
function messageText(content: string | ChatPart[]): string {
  if (typeof content === 'string') return content;
  return content
    .filter((p): p is ChatTextPart => p.type === 'text')
    .map((p) => p.text)
    .join('\n');
}

function buildProviderRequest(
  provider: Provider,
  env: Env,
  model: string,
  messages: ChatMessage[],
): { url: string; headers: Record<string, string>; body: string } {
  if (provider === 'anthropic') {
    const systemParts = messages
      .filter((m) => m.role === 'system')
      .map((m) => messageText(m.content));
    const chatMessages = messages
      .filter((m) => m.role !== 'system')
      .map((m) => ({
        role: m.role === 'assistant' ? 'assistant' : 'user',
        content: toAnthropicContent(m.content),
      }));
    return {
      url: 'https://api.anthropic.com/v1/messages',
      headers: {
        'content-type': 'application/json',
        'x-api-key': env.ANTHROPIC_API_KEY,
        'anthropic-version': ANTHROPIC_VERSION,
      },
      body: JSON.stringify({
        model,
        max_tokens: ANTHROPIC_MAX_TOKENS,
        stream: true,
        ...(systemParts.length > 0 ? { system: systemParts.join('\n') } : {}),
        messages: chatMessages,
      }),
    };
  }
  // Every non-Anthropic provider speaks OpenAI-compatible
  // /chat/completions (same request shape, Bearer key, streamed SSE).
  // Gemini's endpoint is Google's OpenAI-compat base; Groq and NVIDIA
  // NIM are OpenAI-compat by design. New providers only need one line
  // here plus a secret in Env.
  const compat: Record<Exclude<Provider, 'anthropic'>, { url: string; key: string }> = {
    openai: {
      url: 'https://api.openai.com/v1/chat/completions',
      key: env.OPENAI_API_KEY,
    },
    openrouter: {
      url: 'https://openrouter.ai/api/v1/chat/completions',
      key: env.OPENROUTER_API_KEY,
    },
    gemini: {
      url: 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
      key: env.GEMINI_API_KEY,
    },
    groq: {
      url: 'https://api.groq.com/openai/v1/chat/completions',
      key: env.GROQ_API_KEY,
    },
    nvidia: {
      url: 'https://integrate.api.nvidia.com/v1/chat/completions',
      key: env.NVIDIA_API_KEY,
    },
  };
  const endpoint = compat[provider];
  return {
    url: endpoint.url,
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${endpoint.key}`,
      ...(provider === 'openrouter'
        ? { 'http-referer': 'https://dj-proxy.workers.dev', 'x-title': 'DJ' }
        : {}),
    },
    body: JSON.stringify({ model, messages, stream: true }),
  };
}

/**
 * Convert Anthropic's SSE stream into OpenAI-style SSE chunks
 * (data: {"choices":[{"delta":{"content":"..."}}]}) so the app only has to
 * parse one shape. OpenAI/OpenRouter/Gemini/Groq/NVIDIA streams pass
 * through untouched (they already speak OpenAI-style SSE).
 */
function anthropicToOpenAiStream(upstream: ReadableStream<Uint8Array>): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  let buffer = '';
  const reader = upstream.getReader();

  async function pump(controller: ReadableStreamDefaultController<Uint8Array>): Promise<void> {
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() ?? '';
        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          const data = trimmed.slice(5).trim();
          if (data === '[DONE]') continue;
          let event: { type?: string; delta?: { type?: string; text?: string } };
          try {
            event = JSON.parse(data);
          } catch {
            continue; // skip a malformed chunk, never crash the stream
          }
          if (event.type === 'content_block_delta' && event.delta?.type === 'text_delta' && event.delta.text) {
            controller.enqueue(
              encoder.encode(
                `data: ${JSON.stringify({ choices: [{ delta: { content: event.delta.text } }] })}\n\n`,
              ),
            );
          } else if (event.type === 'message_stop') {
            controller.enqueue(encoder.encode('data: [DONE]\n\n'));
          }
        }
      }
      controller.enqueue(encoder.encode('data: [DONE]\n\n'));
      controller.close();
    } catch (err) {
      controller.error(err);
    }
  }

  return new ReadableStream<Uint8Array>({ start: (c) => void pump(c) });
}

async function handleChat(request: Request, env: Env): Promise<Response> {
  const parsed = parseChatBody(await readJsonBody(request));
  if (parsed === null) {
    return errorJson('bad chat request: need {provider, model, messages}', 400);
  }
  const { provider, model, messages } = parsed;
  const { url, headers, body } = buildProviderRequest(provider, env, model, messages);

  let upstream: Response;
  try {
    upstream = await fetch(url, {
      method: 'POST',
      headers,
      body,
      signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
    });
  } catch {
    return errorJson('cloud provider unreachable', 502);
  }

  if (!upstream.ok) {
    // 401/403 = key expired/invalid. DJ falls back to Local/Core on this.
    // Never retry, never include the provider body (it may echo details).
    if (isAuthError(upstream.status)) {
      return errorJson('cloud key expired', upstream.status);
    }
    return errorJson(`cloud provider error (${upstream.status})`, 502);
  }
  if (upstream.body === null) {
    return errorJson('cloud provider returned an empty stream', 502);
  }

  const stream =
    provider === 'anthropic' ? anthropicToOpenAiStream(upstream.body) : upstream.body;
  return new Response(stream, {
    status: 200,
    headers: {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
      connection: 'keep-alive',
    },
  });
}

async function handleTts(request: Request, env: Env): Promise<Response> {
  const body = await readJsonBody(request);
  if (typeof body !== 'object' || body === null) {
    return errorJson('bad tts request: need {text}', 400);
  }
  const b = body as Record<string, unknown>;
  if (typeof b.text !== 'string' || b.text.trim() === '') {
    return errorJson('bad tts request: need {text}', 400);
  }
  if (b.text.length > 5000) {
    return errorJson('text too long for tts (max 5000 characters)', 400);
  }
  const voiceId =
    typeof b.voiceId === 'string' && b.voiceId.trim() !== '' ? b.voiceId.trim() : env.ELEVENLABS_VOICE_ID;
  if (voiceId === '') {
    return errorJson('no ElevenLabs voice configured', 500);
  }

  let upstream: Response;
  try {
    upstream = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(voiceId)}?output_format=mp3_44100_128`,
      {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'xi-api-key': env.ELEVENLABS_API_KEY,
        },
        body: JSON.stringify({ text: b.text, model_id: ELEVENLABS_MODEL_ID }),
        signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
      },
    );
  } catch {
    return errorJson('text-to-speech provider unreachable', 502);
  }

  if (!upstream.ok) {
    if (isAuthError(upstream.status)) {
      return errorJson('cloud key expired', upstream.status);
    }
    return errorJson(`text-to-speech provider error (${upstream.status})`, 502);
  }
  return new Response(upstream.body, {
    status: 200,
    headers: { 'content-type': 'audio/mpeg', 'cache-control': 'no-cache' },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  // AssemblyAI realtime token: a short-lived token for the app's streaming
  // transcription. The raw API key is NEVER returned to the app.
  let upstream: Response;
  try {
    upstream = await fetch('https://api.assemblyai.com/v2/realtime/token', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: env.ASSEMBLYAI_API_KEY,
      },
      body: JSON.stringify({ expires_in_seconds: ASSEMBLYAI_TOKEN_TTL_SECONDS }),
      signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
    });
  } catch {
    return errorJson('transcription provider unreachable', 502);
  }

  if (!upstream.ok) {
    if (isAuthError(upstream.status)) {
      return errorJson('cloud key expired', upstream.status);
    }
    return errorJson(`transcription provider error (${upstream.status})`, 502);
  }
  let data: { token?: unknown };
  try {
    data = (await upstream.json()) as { token?: unknown };
  } catch {
    return errorJson('transcription provider returned a bad token', 502);
  }
  if (typeof data.token !== 'string' || data.token === '') {
    return errorJson('transcription provider returned a bad token', 502);
  }
  return json({ ok: true, token: data.token, expiresInSeconds: ASSEMBLYAI_TOKEN_TTL_SECONDS });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const cors = corsHeaders(request, env);
    if (cors === null) {
      return errorJson('origin not allowed', 403);
    }

    // Preflight for any future browser use.
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: {
          ...cors,
          'access-control-allow-methods': 'GET, POST, OPTIONS',
          'access-control-allow-headers': 'content-type',
          'access-control-max-age': '86400',
        },
      });
    }

    let response: Response;
    try {
      if (request.method === 'GET' && url.pathname === '/health') {
        response = json({ ok: true });
      } else if (request.method === 'POST' && url.pathname === '/chat') {
        response = await handleChat(request, env);
      } else if (request.method === 'POST' && url.pathname === '/tts') {
        response = await handleTts(request, env);
      } else if (request.method === 'GET' && url.pathname === '/transcribe-token') {
        response = await handleTranscribeToken(env);
      } else {
        response = errorJson('not found', 404);
      }
    } catch {
      // Never leak internals (or secrets) in an error body.
      response = errorJson('worker error', 500);
    }
    return withCors(response, cors);
  },
};
