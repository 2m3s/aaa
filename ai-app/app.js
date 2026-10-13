'use strict';

// ---- Providers ------------------------------------------------------------
// Each one has a free tier and allows calls straight from a browser (CORS).

const PROVIDERS = {
  gemini: {
    name: 'Google Gemini',
    model: 'gemini-2.5-flash',
    note: 'Free key, no card: <a href="https://aistudio.google.com/apikey" target="_blank" rel="noopener">aistudio.google.com/apikey</a>',
    stream: streamGemini,
  },
  groq: {
    name: 'Groq',
    model: 'llama-3.3-70b-versatile',
    note: 'Free key, very fast: <a href="https://console.groq.com/keys" target="_blank" rel="noopener">console.groq.com/keys</a>',
    stream: (opts) => streamOpenAI({ ...opts, url: 'https://api.groq.com/openai/v1/chat/completions' }),
  },
  openrouter: {
    name: 'OpenRouter',
    model: 'meta-llama/llama-3.3-70b-instruct:free',
    note: 'Free models end in <code>:free</code>: <a href="https://openrouter.ai/keys" target="_blank" rel="noopener">openrouter.ai/keys</a>',
    stream: (opts) => streamOpenAI({
      ...opts,
      url: 'https://openrouter.ai/api/v1/chat/completions',
      headers: { 'X-Title': 'Pocket AI' },
    }),
  },
};

// ---- Modes ----------------------------------------------------------------

const BASE = 'You are a helpful assistant inside a small iPhone app. Keep answers clear and reasonably short; use Markdown lists or code blocks only when they help.';

const MODES = [
  { id: 'chat', label: 'Chat', placeholder: 'Message', system: BASE },
  { id: 'summarize', label: 'Summarize', placeholder: 'Paste text to summarize',
    system: BASE + ' Summarize whatever the user sends in a few bullet points, then one sentence with the main takeaway.' },
  { id: 'rewrite', label: 'Rewrite', placeholder: 'Paste text to improve',
    system: BASE + ' Rewrite the user\'s text so it is clearer and more natural, keeping their meaning and tone. Reply with only the rewritten text.' },
  { id: 'grammar', label: 'Fix grammar', placeholder: 'Paste text to correct',
    system: BASE + ' Correct spelling, grammar and punctuation in the user\'s text with minimal changes. Reply with only the corrected text.' },
  { id: 'translate', label: 'Translate', placeholder: 'Text, e.g. "to Spanish: …"',
    system: BASE + ' Translate the user\'s text. If they name a target language use it; otherwise translate into English, or from English into Spanish. Reply with only the translation.' },
  { id: 'explain', label: 'Explain simply', placeholder: 'What should I explain?',
    system: BASE + ' Explain the topic as if to a curious 12-year-old, using a short everyday example.' },
  { id: 'code', label: 'Code', placeholder: 'Describe the code you need',
    system: BASE + ' You are a programming helper. Give working code in a fenced code block, then a brief explanation.' },
];

// ---- Storage (all wrapped: private mode can make it throw) -----------------

const store = {
  get(key, fallback) {
    try { const v = localStorage.getItem('pocketai.' + key); return v == null ? fallback : JSON.parse(v); }
    catch { return fallback; }
  },
  set(key, value) {
    try { localStorage.setItem('pocketai.' + key, JSON.stringify(value)); } catch { /* ignore */ }
  },
};

const state = {
  provider: store.get('provider', 'gemini'),
  keys: store.get('keys', {}),
  models: store.get('models', {}),
  mode: store.get('mode', 'chat'),
  messages: store.get('messages', []), // [{role: 'user'|'assistant', content}]
  controller: null,
};
if (!PROVIDERS[state.provider]) state.provider = 'gemini';
if (!MODES.some((m) => m.id === state.mode)) state.mode = 'chat';

// ---- Elements -------------------------------------------------------------

const $ = (id) => document.getElementById(id);
const chat = $('chat'), empty = $('empty'), input = $('input'), sendBtn = $('sendBtn');
const dialog = $('settings'), providerSel = $('provider'), keyInput = $('apiKey'), modelInput = $('model');

// ---- Rendering ------------------------------------------------------------

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function inline(s) {
  return s
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>');
}

// Small Markdown subset: code fences, headings, lists, bold/italic/code, paragraphs.
// Everything is HTML-escaped first, so model output can't inject markup.
function markdown(src) {
  const parts = escapeHtml(src).split(/```/);
  let html = '';
  parts.forEach((part, i) => {
    if (i % 2 === 1) {
      const body = part.replace(/^[\w+-]*\n/, '');
      html += `<pre><code>${body.replace(/\n$/, '')}</code></pre>`;
      return;
    }
    let list = null;
    let para = [];
    const flushPara = () => { if (para.length) { html += `<p>${inline(para.join('<br>'))}</p>`; para = []; } };
    const closeList = () => { if (list) { html += `</${list}>`; list = null; } };
    for (const line of part.split('\n')) {
      let m;
      if (!line.trim()) { flushPara(); closeList(); }
      else if ((m = line.match(/^#{1,6}\s+(.*)/))) { flushPara(); closeList(); html += `<h4>${inline(m[1])}</h4>`; }
      else if ((m = line.match(/^\s*[-*•]\s+(.*)/)) || (m = line.match(/^\s*\d+[.)]\s+(.*)/))) {
        flushPara();
        const type = /^\s*\d/.test(line) ? 'ol' : 'ul';
        if (list !== type) { closeList(); html += `<${type}>`; list = type; }
        html += `<li>${inline(m[1])}</li>`;
      } else { closeList(); para.push(line); }
    }
    flushPara(); closeList();
  });
  return html;
}

function addMessageEl(role, content) {
  const el = document.createElement('div');
  el.className = 'msg ' + (role === 'user' ? 'user' : 'ai');
  const body = document.createElement('div');
  el.appendChild(body);
  if (role === 'user') body.textContent = content;
  else body.innerHTML = markdown(content);
  chat.appendChild(el);
  return { el, body };
}

function addCopyButton(el, getText) {
  const bar = document.createElement('div');
  bar.className = 'actions';
  const btn = document.createElement('button');
  btn.className = 'copy';
  btn.type = 'button';
  btn.textContent = 'Copy';
  btn.onclick = async () => {
    try { await navigator.clipboard.writeText(getText()); btn.textContent = 'Copied'; }
    catch { btn.textContent = 'Copy failed'; }
    setTimeout(() => (btn.textContent = 'Copy'), 1500);
  };
  bar.appendChild(btn);
  el.appendChild(bar);
}

function scrollToBottom() { chat.scrollTop = chat.scrollHeight; }

function renderAll() {
  chat.querySelectorAll('.msg').forEach((n) => n.remove());
  empty.hidden = state.messages.length > 0;
  for (const m of state.messages) {
    const { el } = addMessageEl(m.role, m.content);
    if (m.role === 'assistant') addCopyButton(el, () => m.content);
  }
  scrollToBottom();
}

function renderModes() {
  const nav = $('modes');
  nav.innerHTML = '';
  for (const mode of MODES) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'chip';
    b.textContent = mode.label;
    b.setAttribute('aria-pressed', String(mode.id === state.mode));
    b.onclick = () => {
      state.mode = mode.id;
      store.set('mode', mode.id);
      renderModes();
      input.focus();
    };
    nav.appendChild(b);
  }
  input.placeholder = currentMode().placeholder;
}

const currentMode = () => MODES.find((m) => m.id === state.mode);
const currentModel = () => state.models[state.provider] || PROVIDERS[state.provider].model;

function showError(text) {
  const el = document.createElement('div');
  el.className = 'msg error';
  el.textContent = text;
  chat.appendChild(el);
  scrollToBottom();
}

// ---- Streaming clients ----------------------------------------------------

// Yields the JSON payload of each `data:` line in a Server-Sent Events stream.
async function* sse(response) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let nl;
    while ((nl = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (!line.startsWith('data:')) continue;
      const data = line.slice(5).trim();
      if (data === '[DONE]') return;
      try { yield JSON.parse(data); } catch { /* keep-alive or partial junk */ }
    }
  }
}

async function failIfBad(res) {
  if (res.ok) return;
  let detail = '';
  try {
    const text = await res.text();
    try {
      const j = JSON.parse(text);
      const e = Array.isArray(j) ? j[0]?.error : j.error;
      detail = e?.message || text;
    } catch { detail = text; }
  } catch { /* ignore */ }
  const hint = res.status === 401 || res.status === 403 ? ' Check your API key in Settings.'
    : res.status === 429 ? ' You hit the free rate limit; wait a minute and try again.'
    : res.status === 404 ? ' The model name may have changed; check it in Settings.'
    : '';
  throw new Error(`${res.status}: ${detail.slice(0, 300)}${hint}`);
}

async function* streamOpenAI({ url, headers = {}, key, model, system, messages, signal }) {
  const res = await fetch(url, {
    method: 'POST',
    signal,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}`, ...headers },
    body: JSON.stringify({ model, stream: true, messages: [{ role: 'system', content: system }, ...messages] }),
  });
  await failIfBad(res);
  for await (const chunk of sse(res)) {
    if (chunk.error) throw new Error(chunk.error.message || 'Provider error');
    const text = chunk.choices?.[0]?.delta?.content;
    if (text) yield text;
  }
}

async function* streamGemini({ key, model, system, messages, signal }) {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:streamGenerateContent?alt=sse`;
  const res = await fetch(url, {
    method: 'POST',
    signal,
    headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: system }] },
      contents: messages.map((m) => ({ role: m.role === 'assistant' ? 'model' : 'user', parts: [{ text: m.content }] })),
    }),
  });
  await failIfBad(res);
  for await (const chunk of sse(res)) {
    if (chunk.error) throw new Error(chunk.error.message || 'Provider error');
    for (const part of chunk.candidates?.[0]?.content?.parts || []) {
      if (part.text && !part.thought) yield part.text;
    }
  }
}

// ---- Sending --------------------------------------------------------------

const MAX_HISTORY = 20; // messages sent back to the model, to stay light on free quotas

function setBusy(busy) {
  sendBtn.classList.toggle('busy', busy);
  sendBtn.setAttribute('aria-label', busy ? 'Stop' : 'Send');
  updateSendEnabled();
}

function updateSendEnabled() {
  sendBtn.disabled = !state.controller && !input.value.trim();
}

async function send(text) {
  const key = state.keys[state.provider];
  state.messages.push({ role: 'user', content: text });
  store.set('messages', state.messages);
  empty.hidden = true;
  addMessageEl('user', text);

  const reply = { role: 'assistant', content: '' };
  const { el, body } = addMessageEl('assistant', '');
  body.classList.add('cursor');
  scrollToBottom();

  state.controller = new AbortController();
  setBusy(true);
  try {
    const stream = PROVIDERS[state.provider].stream({
      key,
      model: currentModel(),
      system: currentMode().system,
      messages: state.messages.slice(-MAX_HISTORY),
      signal: state.controller.signal,
    });
    const nearBottom = () => chat.scrollHeight - chat.scrollTop - chat.clientHeight < 80;
    for await (const piece of stream) {
      const stick = nearBottom();
      reply.content += piece;
      body.innerHTML = markdown(reply.content);
      if (stick) scrollToBottom();
    }
  } catch (err) {
    if (err.name !== 'AbortError') showError(err.message || String(err));
  } finally {
    body.classList.remove('cursor');
    state.controller = null;
    setBusy(false);
  }

  if (reply.content) {
    state.messages.push(reply);
    addCopyButton(el, () => reply.content);
  } else {
    el.remove();
    state.messages.pop(); // drop the unanswered question so history stays paired
  }
  store.set('messages', state.messages);
}

$('composer').addEventListener('submit', (e) => {
  e.preventDefault();
  if (state.controller) { state.controller.abort(); return; }
  const text = input.value.trim();
  if (!text) return;
  if (!state.keys[state.provider]) { openSettings(); return; }
  input.value = '';
  autosize();
  send(text);
});

function autosize() {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, 160) + 'px';
  updateSendEnabled();
}
input.addEventListener('input', autosize);
// Enter sends on a hardware keyboard; on the iPhone keyboard Return adds a new line.
input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && matchMedia('(pointer: fine)').matches) {
    e.preventDefault();
    $('composer').requestSubmit();
  }
});

$('clearBtn').addEventListener('click', () => {
  if (state.controller) state.controller.abort();
  if (state.messages.length && !confirm('Start a new chat? This one will be cleared.')) return;
  state.messages = [];
  store.set('messages', state.messages);
  chat.querySelectorAll('.msg').forEach((n) => n.remove());
  empty.hidden = false;
});

// ---- Settings -------------------------------------------------------------

for (const [id, p] of Object.entries(PROVIDERS)) providerSel.add(new Option(p.name, id));

function fillSettings(providerId) {
  providerSel.value = providerId;
  keyInput.value = state.keys[providerId] || '';
  modelInput.value = state.models[providerId] || PROVIDERS[providerId].model;
  $('providerNote').innerHTML = PROVIDERS[providerId].note;
}

function openSettings() {
  fillSettings(state.provider);
  dialog.returnValue = '';
  dialog.showModal();
}

providerSel.addEventListener('change', () => fillSettings(providerSel.value));
$('settingsBtn').addEventListener('click', openSettings);
dialog.addEventListener('close', () => {
  if (dialog.returnValue !== 'save') return;
  const id = providerSel.value;
  state.provider = id;
  state.keys[id] = keyInput.value.trim();
  const model = modelInput.value.trim();
  if (model && model !== PROVIDERS[id].model) state.models[id] = model;
  else delete state.models[id];
  store.set('provider', state.provider);
  store.set('keys', state.keys);
  store.set('models', state.models);
});

// ---- Start ----------------------------------------------------------------

renderModes();
renderAll();
updateSendEnabled();
if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
