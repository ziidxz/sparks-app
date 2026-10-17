'use strict';

/*
 * Big Pickle backend
 * ------------------
 * A tiny dependency-free Node server that the Flutter app talks to and that
 * streams tokens back as SSE.
 *
 * Two providers:
 *   gemini-web (default) – drives gemini.google.com like the browser. No key
 *                          needed (guest mode); set GEMINI_COOKIES to log in.
 *   opencode             – OpenAI-compatible (e.g. OpenCode / OpenAI).
 *
 * Config (env vars):
 *   PROVIDER           optional – "gemini-web" (default) or "opencode"
 *   GEMINI_COOKIES     optional – JSON {"__Secure-1PSID":"...","__Secure-1PSIDTS":"..."}
 *   OPENCODE_API_KEY   required for PROVIDER=opencode
 *   OPENCODE_BASE_URL  optional – default https://opencode.ai/inference/v1
 *   OPENCODE_MODEL     optional – default "big-pickle"
 *   PORT               optional – default 8787
 *   HOST               optional – default 0.0.0.0
 */

const http = require('http');
const https = require('https');
const { URL } = require('url');
const { GeminiWeb } = require('./gemini-web');

const PORT = parseInt(process.env.PORT || '8787', 10);
const HOST = process.env.HOST || '0.0.0.0';
const BASE_URL = (process.env.OPENCODE_BASE_URL || 'https://opencode.ai/inference/v1').replace(/\/+$/, '');
const MODEL = process.env.OPENCODE_MODEL || 'big-pickle';
const API_KEY = process.env.OPENCODE_API_KEY || '';
const PROVIDER = process.env.PROVIDER || (process.env.OPENCODE_API_KEY ? 'opencode' : 'gemini-web');

let GEMINI_COOKIES = null;
if (process.env.GEMINI_COOKIES) {
  try {
    const parsed = JSON.parse(process.env.GEMINI_COOKIES);
    const out = {};
    if (Array.isArray(parsed)) {
      for (const c of parsed) if (c && c.name && c.value) out[c.name] = c.value;
    } else if (parsed && typeof parsed === 'object') {
      for (const [k, v] of Object.entries(parsed)) if (v) out[k] = String(v);
    }
    if (Object.keys(out).length) GEMINI_COOKIES = out;
  } catch (e) {
    console.warn('  gemini cookies: invalid JSON, ignoring (' + e.message + ')');
  }
}

const PERSONA =
  'You are Pickle, a warm, playful and caring companion. ' +
  'You chat casually with the user, keep track of the running conversation, ' +
  'and reply in short, natural messages (1-3 sentences unless asked for more). ' +
  'Never say that you are an AI or a language model.';

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Access-Control-Allow-Origin': '*',
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 1_000_000) {
        reject(new Error('request too large'));
        req.destroy();
        return;
      }
      data += c;
    });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

function buildMessages(history) {
  const msgs = [{ role: 'system', content: PERSONA }];
  for (const m of history) {
    if (!m || typeof m.content !== 'string') continue;
    const role = m.role === 'assistant' ? 'assistant' : 'user';
    msgs.push({ role, content: m.content.slice(0, 8000) });
  }
  return msgs;
}

function callUpstream(payload) {
  return new Promise((resolve, reject) => {
    const url = new URL(BASE_URL + '/chat/completions');
    const body = JSON.stringify(payload);
    const req = https.request(
      {
        hostname: url.hostname,
        port: url.port || 443,
        path: url.pathname + url.search,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${API_KEY}`,
          Accept: 'text/event-stream',
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (up) => resolve(up),
    );
    req.on('error', reject);
    req.setTimeout(120000, () => req.destroy(new Error('upstream timeout')));
    req.write(body);
    req.end();
  });
}

let _gemini = null;
let _geminiChain = Promise.resolve();

function getGemini() {
  if (!_gemini) _gemini = new GeminiWeb({ cookies: GEMINI_COOKIES });
  return _gemini;
}

function withGeminiLock(fn) {
  const run = _geminiChain.then(fn, fn);
  _geminiChain = run.catch(() => {});
  return run;
}

function lastUserText(history) {
  for (let i = history.length - 1; i >= 0; i--) {
    const m = history[i];
    if (m && m.role !== 'assistant' && typeof m.content === 'string' && m.content.trim()) {
      return m.content;
    }
  }
  return '';
}

async function handleGeminiChat(res, history) {
  const prompt = lastUserText(history);
  const stream = {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
    'Access-Control-Allow-Origin': '*',
  };

  if (!prompt) {
    return sendJson(res, 400, { error: 'no user message' });
  }

  res.writeHead(200, stream);
  try {
    await withGeminiLock(() => getGemini().generate(prompt, (delta) => res.write('data: ' + JSON.stringify({ delta }) + '\n\n')));
  } catch (e) {
    res.write('data: ' + JSON.stringify({ error: 'Gemini request failed: ' + e.message }) + '\n\n');
  }
  res.write('data: [DONE]\n\n');
  res.end();
}

async function handleChat(req, res) {
  let parsed;
  try {
    parsed = JSON.parse((await readBody(req)) || '{}');
  } catch (e) {
    return sendJson(res, 400, { error: 'invalid JSON body' });
  }

  const history = Array.isArray(parsed.messages) ? parsed.messages : [];
  if (history.length === 0) {
    return sendJson(res, 400, { error: 'no messages provided' });
  }

  if (PROVIDER === 'gemini-web') {
    return handleGeminiChat(res, history);
  }

  if (!API_KEY) {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
      'Access-Control-Allow-Origin': '*',
    });
    res.write(
      'data: ' +
        JSON.stringify({
          delta:
            'Backend is running, but OPENCODE_API_KEY is not set.\n' +
            'Start it like:  OPENCODE_API_KEY=sk-... node server/server.js',
        }) +
        '\n\n',
    );
    res.write('data: [DONE]\n\n');
    return res.end();
  }

  let up;
  try {
    up = await callUpstream({
      model: MODEL,
      stream: true,
      messages: buildMessages(history),
    });
  } catch (e) {
    return sendJson(res, 502, { error: 'upstream connection failed: ' + e.message });
  }

  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
    'Access-Control-Allow-Origin': '*',
  });

  if (up.statusCode < 200 || up.statusCode >= 300) {
    let errBody = '';
    up.on('data', (c) => (errBody += c));
    up.on('end', () => {
      res.write('data: ' + JSON.stringify({ error: `upstream HTTP ${up.statusCode}: ${errBody.slice(0, 400)}` }) + '\n\n');
      res.write('data: [DONE]\n\n');
      res.end();
    });
    return;
  }

  let buffer = '';
  up.setEncoding('utf8');
  up.on('data', (chunk) => {
    buffer += chunk;
    let idx;
    while ((idx = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, idx).trim();
      buffer = buffer.slice(idx + 1);
      if (!line || !line.startsWith('data:')) continue;
      const data = line.slice(5).trim();
      if (data === '[DONE]') {
        res.write('data: [DONE]\n\n');
        continue;
      }
      try {
        const j = JSON.parse(data);
        const delta = j.choices && j.choices[0] && j.choices[0].delta;
        const text = delta && (delta.content || delta.reasoning_content);
        if (text) res.write('data: ' + JSON.stringify({ delta: text }) + '\n\n');
      } catch (_) {
        /* ignore */
      }
    }
  });
  up.on('end', () => {
    if (!res.writableEnded) {
      res.write('data: [DONE]\n\n');
      res.end();
    }
  });
  up.on('error', (e) => {
    if (!res.writableEnded) {
      res.write('data: ' + JSON.stringify({ error: 'stream error: ' + e.message }) + '\n\n');
      res.write('data: [DONE]\n\n');
      res.end();
    }
  });

  req.on('close', () => up.destroy());
}

const server = http.createServer((req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    });
    return res.end();
  }

  if (req.method === 'GET' && req.url === '/api/health') {
    return sendJson(res, 200, {
      ok: true,
      provider: PROVIDER,
      model: PROVIDER === 'gemini-web' ? 'gemini-web' : MODEL,
      base_url: PROVIDER === 'gemini-web' ? 'https://gemini.google.com' : BASE_URL,
      auth: PROVIDER === 'gemini-web' ? (GEMINI_COOKIES ? 'cookies' : 'guest') : Boolean(API_KEY),
    });
  }

  if (req.method === 'POST' && req.url === '/api/chat') {
    return handleChat(req, res).catch((e) => {
      if (!res.headersSent) sendJson(res, 500, { error: String(e && e.message) });
      else res.end();
    });
  }

  sendJson(res, 404, { error: 'not found' });
});

server.listen(PORT, HOST, () => {
  console.log(`Big Pickle backend listening on http://${HOST}:${PORT}`);
  console.log(`  provider: ${PROVIDER}`);
  if (PROVIDER === 'gemini-web') {
    console.log(`  mode:     ${GEMINI_COOKIES ? 'authenticated (cookies)' : 'guest (no login)'}`);
  } else {
    console.log(`  model:    ${MODEL}`);
    console.log(`  upstream: ${BASE_URL}`);
    console.log(`  api key:  ${API_KEY ? 'set' : 'NOT SET (set OPENCODE_API_KEY)'}`);
  }
});
