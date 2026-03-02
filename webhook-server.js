#!/usr/bin/env node
// WeChatBridge webhook server v2 - Mac side

const http  = require('http');
const https = require('https');
const fs    = require('fs');
const { exec } = require('child_process');

const PHONE_IP   = 'PHONE_IP';
const TUNNEL_PORT = 58082;   // localhost:58082 via SSH tunnel → phone:58080
const MY_PORT    = 58081;
const MY_IP      = 'MAC_IP';

// API config
const BASE_URL = 'https://api.gptclubapi.xyz/api';
const MODEL    = 'claude-haiku-4-5-20251001';

function getApiKey() {
  try {
    const raw = fs.readFileSync('/path/to/your/api_key', 'utf8');
    const m = raw.match(/sk-[a-zA-Z0-9_-]{30,}/);
    return m ? m[0] : null;
  } catch(e) { return null; }
}
const API_KEY = getApiKey();
console.log(`[WCB] API_KEY: ${API_KEY ? API_KEY.slice(0,10)+'...' : 'NOT FOUND'}`);
console.log(`[WCB] Server: ${MY_IP}:${MY_PORT}`);

// ─── AI (OpenAI chat format) ──────────────────────────────────
function callAI(fromUser, content, history) {
  return new Promise((resolve, reject) => {
    const messages = [
      { role: 'system', content: `你是霹雳的微信分身。霹雳是加密货币交易员，说话简短随意，像真人发微信。1-2句话回复，不暴露是AI。对话对象: ${fromUser}` },
      ...history,
      { role: 'user', content }
    ];
    const payload = JSON.stringify({ model: MODEL, max_tokens: 100, messages });
    const url = new URL(`${BASE_URL}/v1/chat/completions`);
    const options = {
      hostname: url.hostname, path: url.pathname, method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${API_KEY}`, 'Content-Length': Buffer.byteLength(payload) }
    };
    const req = https.request(options, res => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => {
        try {
          const j = JSON.parse(data);
          if (j.error) { console.error('[AI ERROR]', j.error); reject(new Error(JSON.stringify(j.error))); return; }
          resolve(j.choices?.[0]?.message?.content?.trim() || '');
        } catch(e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.write(payload); req.end();
  });
}

// ─── Send via SSH tunnel ──────────────────────────────────────
function sendReply(toUser, text) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify({ user_id: toUser, message: text });
    const tmp = `/tmp/wcb_${Date.now()}.json`;
    fs.writeFileSync(tmp, payload);
    exec(`curl -s --max-time 8 -X POST http://127.0.0.1:${TUNNEL_PORT}/send_private_msg -H "Content-Type: application/json" -d @${tmp}`, (err, out) => {
      fs.unlink(tmp, () => {});
      if (err) { console.error('[SEND ERR]', err.message); reject(err); return; }
      console.log(`[SEND→${toUser}] ${text} | ${out.trim()}`);
      resolve();
    });
  });
}

// ─── Conversation memory ──────────────────────────────────────
const histories = new Map();
function getHistory(u) { if (!histories.has(u)) histories.set(u, []); return histories.get(u); }
function addHistory(u, role, content) {
  const h = getHistory(u);
  h.push({ role, content });
  if (h.length > 20) h.splice(0, 2);
}

// ─── Filters ──────────────────────────────────────────────────
const WHITELIST = new Set(['filehelper'  // add wxids here]);
const IGNORE    = new Set(['weixin', 'medianoti', 'floatbottle', 'qqmail']);

// ─── HTTP server ──────────────────────────────────────────────
http.createServer(async (req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end('{"status":"ok"}');

  if (req.method !== 'POST') return;
  let body = '';
  req.on('data', d => body += d);
  req.on('end', async () => {
    let msg;
    try { msg = JSON.parse(body); } catch(e) { return; }

    const { from, content, type } = msg;
    console.log(`\n[RECV] from=${from} type=${type} | ${content}`);

    if (!from || !content)           return;
    if (IGNORE.has(from))            return;
    if (from.startsWith('gh_'))      return;
    if (type !== 1)                  return; // text only
    if (WHITELIST.size > 0 && !WHITELIST.has(from)) { console.log(`[SKIP] ${from}`); return; }

    try {
      const history = getHistory(from);
      addHistory(from, 'user', content);
      console.log(`[AI→] calling...`);
      const reply = await callAI(from, content, history.slice(0, -1));
      if (!reply) { console.log('[AI] empty reply'); return; }
      console.log(`[AI→${from}] ${reply}`);
      addHistory(from, 'assistant', reply);
      await sendReply(from, reply);
    } catch(e) {
      console.error('[ERR]', e.message);
    }
  });
}).listen(MY_PORT, '0.0.0.0', () => {
  console.log(`[WCB] Listening on ${MY_PORT}`);
});
