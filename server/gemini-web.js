'use strict';

/*
 * Gemini Web client (reverse-engineered, unofficial)
 * --------------------------------------------------
 * Drives gemini.google.com the way the browser does, so the app can generate
 * without any API key. Works in "guest" mode (no login) and, if cookies are
 * supplied, in authenticated mode.
 *
 * Optional env:
 *   GEMINI_COOKIES   JSON like {"__Secure-1PSID":"...","__Secure-1PSIDTS":"..."}
 *                    (authenticated mode; guest mode is used when absent)
 *
 * Protocol derived from HanaokaYuzu/Gemini-API (MIT). Unofficial: may break.
 */

const { randomUUID, randomInt } = require('node:crypto');

const BASE = 'https://gemini.google.com';
const INIT = BASE + '/app';
const GENERATE = BASE + '/_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate';
const UA =
  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
const DEFAULT_METADATA = ['', '', '', null, null, null, null, null, null, ''];
const ARTIFACTS_RE = /https?:\/\/googleusercontent\.com\/(?:\w+\/)+\d+\n*/g;

function getNested(data, path, def = null) {
  let cur = data;
  for (const key of path) {
    if (Array.isArray(cur) && typeof key === 'number' && key >= -cur.length && key < cur.length) {
      cur = cur[key];
    } else if (cur && typeof cur === 'object' && key in cur) {
      cur = cur[key];
    } else {
      return def;
    }
  }
  return cur === null || cur === undefined ? def : cur;
}

class Jar {
  constructor(initial) {
    this.map = new Map();
    if (initial && typeof initial === 'object') {
      for (const [k, v] of Object.entries(initial)) if (v) this.map.set(k, String(v));
    }
  }
  add(setCookies) {
    if (!setCookies) return;
    for (const sc of setCookies) {
      const pair = String(sc).split(';')[0];
      const i = pair.indexOf('=');
      if (i > 0) this.map.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
    }
  }
  header() {
    return [...this.map.entries()].map(([k, v]) => `${k}=${v}`).join('; ');
  }
}

class FrameParser {
  constructor() {
    this.reset();
  }
  reset() {
    this.buf = '';
    this.expected = null;
    this.start = 0;
    this.scannedChars = 0;
    this.scannedUnits = 0;
    this.prefixChecked = false;
  }
  stripPrefix() {
    if (this.prefixChecked) return;
    const p = ")]}'";
    if (this.buf.length < p.length && p.startsWith(this.buf)) return;
    if (this.buf.startsWith(p)) this.buf = this.buf.slice(p.length).replace(/^\s+/, '');
    this.prefixChecked = true;
  }
  readLength() {
    let pos = 0;
    while (pos < this.buf.length && /\s/.test(this.buf[pos])) pos++;
    if (pos) this.buf = this.buf.slice(pos);
    if (!this.buf.length) return false;
    const m = this.buf.match(/^(\d+)\n/);
    if (!m) return false;
    this.expected = Number(m[1]);
    this.start = m[1].length;
    this.scannedChars = 0;
    this.scannedUnits = 0;
    return true;
  }
  scan() {
    if (this.expected === null) return;
    let idx = this.start + this.scannedChars;
    const limit = this.buf.length;
    while (this.scannedUnits < this.expected && idx < limit) {
      const u = this.buf.charCodeAt(idx) > 0xffff ? 2 : 1;
      if (this.scannedUnits + u > this.expected) break;
      this.scannedUnits += u;
      this.scannedChars++;
      idx++;
    }
  }
  feed(content) {
    if (content) this.buf += content;
    this.stripPrefix();
    const out = [];
    while ((this.expected !== null || this.readLength()) && this.expected !== null) {
      this.scan();
      if (this.scannedUnits < this.expected) break;
      const end = this.start + this.scannedChars;
      const chunk = this.buf.slice(this.start, end);
      this.buf = this.buf.slice(end);
      this.expected = null;
      this.start = 0;
      this.scannedChars = 0;
      this.scannedUnits = 0;
      if (!chunk.trim()) continue;
      let parsed;
      try {
        parsed = JSON.parse(chunk);
      } catch (_) {
        continue;
      }
      if (Array.isArray(parsed)) out.push(...parsed);
      else out.push(parsed);
    }
    return out;
  }
  flush() {
    return this.feed('');
  }
}

class GeminiWeb {
  constructor(opts = {}) {
    this.jar = new Jar(opts.cookies);
    this.at = '';
    this.bl = null;
    this.fsid = null;
    this.lang = 'en';
    this.metadata = DEFAULT_METADATA;
    this.reqid = randomInt(10000, 99999);
    this.running = false;
  }

  async init() {
    const res = await fetch(INIT, {
      headers: {
        'User-Agent': UA,
        'Accept-Language': 'en-US,en;q=0.9',
        Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
      redirect: 'follow',
    });
    this.jar.add(res.headers.getSetCookie ? res.headers.getSetCookie() : []);
    if (res.status !== 200) throw new Error('Gemini init failed (HTTP ' + res.status + ')');
    const body = await res.text();
    this.bl = (body.match(/"cfb2h":\s*"(.*?)"/) || [])[1] || null;
    this.fsid = (body.match(/"FdrFJe":\s*"(.*?)"/) || [])[1] || null;
    this.lang = (body.match(/"TuX5cc":\s*"(.*?)"/) || [])[1] || 'en';
    this.at = (body.match(/"SNlM0e":\s*"(.*?)"/) || [])[1] || '';
    this.running = true;
    return this;
  }

  async generate(prompt, onDelta) {
    if (!this.running) await this.init();

    const _reqid = this.reqid;
    this.reqid += 100000;

    const inner = new Array(81).fill(null);
    inner[0] = [prompt, 0, null, null, null, null, 0];
    inner[1] = [this.lang];
    inner[2] = this.metadata;
    inner[6] = [1];
    inner[7] = 1;
    inner[10] = 1;
    inner[11] = 0;
    inner[17] = [[0]];
    inner[18] = 0;
    inner[27] = 1;
    inner[30] = [4];
    inner[41] = [1];
    inner[53] = 0;
    inner[61] = [];
    inner[68] = 1;
    inner[79] = 1;
    inner[80] = 1;
    const uuid = randomUUID().toUpperCase();
    inner[59] = uuid;

    const params = new URLSearchParams({ hl: this.lang, _reqid: String(_reqid), rt: 'c' });
    if (this.bl) params.set('bl', this.bl);
    if (this.fsid) params.set('f.sid', this.fsid);

    const headers = {
      'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8',
      Origin: BASE,
      Referer: BASE + '/',
      'X-Same-Domain': '1',
      'User-Agent': UA,
      'x-goog-ext-525005358-jspb': `["${uuid}",1]`,
    };
    if (this.jar.map.size) headers.Cookie = this.jar.header();

    const body = new URLSearchParams({
      at: this.at || '',
      'f.req': JSON.stringify([null, JSON.stringify(inner)]),
    }).toString();

    const res = await fetch(GENERATE + '?' + params.toString(), { method: 'POST', headers, body });
    this.jar.add(res.headers.getSetCookie ? res.headers.getSetCookie() : []);
    if (res.status !== 200) throw new Error('Gemini generate failed (HTTP ' + res.status + ')');

    const parser = new FrameParser();
    const decoder = new TextDecoder('utf-8');
    let lastText = '';

    const handle = (parts) => {
      for (const part of parts) {
        if (!Array.isArray(part) || !part[2] || typeof part[2] !== 'string') continue;
        let obj;
        try {
          obj = JSON.parse(part[2]);
        } catch {
          continue;
        }
        const meta = getNested(obj, [1]);
        if (Array.isArray(meta)) this.metadata = meta;
        const cands = getNested(obj, [4]);
        if (!Array.isArray(cands)) continue;
        for (const cand of cands) {
          let text = getNested(cand, [1, 0], '');
          if (typeof text !== 'string' || !text) continue;
          text = text.replace(ARTIFACTS_RE, '');
          if (text === lastText) continue;
          if (text.startsWith(lastText)) {
            onDelta(text.slice(lastText.length));
            lastText = text;
          } else {
            lastText = text;
          }
        }
      }
    };

    for await (const chunk of res.body) handle(parser.feed(decoder.decode(chunk, { stream: true })));
    handle(parser.feed(decoder.decode()));
    handle(parser.flush());

    return lastText;
  }
}

module.exports = { GeminiWeb };
