// Messages++ on the web: campaigns, people, groups and chats that sync with
// Messages++ on your phone. Your phone sends the texts.
// Signs in with Contacts++ as the "messages-web" connected app (PKCE); talks
// only to the Contacts++ API. No build step, no third-party scripts.

const API = window.messagesApiBase || 'https://s1199.comeriver.com/api/v1';
const CONTACTS_WEB = 'https://contacts.comeriver.com';
const CLIENT_ID = 'messages-web';
const REDIRECT = `${location.origin}/app/callback`;
const SCOPES = ['profile.basic.read', 'session.manage', 'backup.read', 'backup.write', 'relay.queue', 'developer.keys',
  'contacts.lookup', 'messages.read', 'messages.send'];
const BATCH_MAX = 1000;

// ---------- small helpers ----------
const store = {
  get: k => { try { return localStorage.getItem(k); } catch { return null; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch { /* private mode */ } },
  del: k => { try { localStorage.removeItem(k); } catch { /* ignore */ } },
};
const once = {
  get: k => { try { return sessionStorage.getItem(k); } catch { return null; } },
  set: (k, v) => { try { sessionStorage.setItem(k, v); } catch { /* ignore */ } },
  del: k => { try { sessionStorage.removeItem(k); } catch { /* ignore */ } },
};
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
class Raw { constructor(s) { this.s = s; } }
const raw = s => new Raw(s);
/** HTML template that escapes every value unless wrapped in raw(). Arrays are joined. */
const html = (parts, ...values) => raw(parts.reduce((out, part, i) => {
  const v = values[i - 1];
  const s = v instanceof Raw ? v.s : Array.isArray(v) ? v.map(x => (x instanceof Raw ? x.s : esc(x))).join('') : esc(v);
  return out + s + part;
}));
const $ = (sel, root = document) => root.querySelector(sel);
const view = () => $('#view');
const render = content => { view().innerHTML = content instanceof Raw ? content.s : esc(content); };
let toastTimer;
const toast = msg => {
  const t = $('#toast'); t.textContent = msg; t.classList.add('show');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove('show'), 4000);
};
const initials = name => (String(name || '#').trim().split(/\s+/).slice(0, 2).map(p => p[0]).join('') || '#').toUpperCase();
const when = iso => { if (!iso) return ''; const d = new Date(iso.replace(' ', 'T') + (/[zZ+]/.test(iso) ? '' : 'Z')); return isNaN(d) ? '' : d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }); };
const b64url = bytes => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const randomToken = n => b64url(crypto.getRandomValues(new Uint8Array(n)));

// ---------- session and API ----------
export class ApiError extends Error { constructor(m, status, body) { super(m); this.status = status; this.body = body; } }
const session = {
  get token() { return store.get('mpw_access'); },
  get signedIn() { return Boolean(store.get('mpw_access')); },
  save(t) { store.set('mpw_access', t.access_token); if (t.refresh_token) store.set('mpw_refresh', t.refresh_token); },
  clear() { ['mpw_access', 'mpw_refresh', 'mpw_me', 'mpw_records', 'mpw_cursor'].forEach(store.del); },
};
const messageFrom = (body, status) => {
  const e = body?.errors;
  if (e && !Array.isArray(e) && typeof e === 'object') { const f = Object.values(e).flat()[0]; if (f) return String(f); }
  if (Array.isArray(e) && e[0]?.message) return e[0].message;
  if (body?.message) return body.message;
  if (status === 0) return 'You seem to be offline. Check your connection and try again.';
  return 'Something went wrong. Please try again.';
};
let refreshing = null;
const refresh = () => {
  const token = store.get('mpw_refresh');
  if (!token) return Promise.resolve(false);
  refreshing ??= fetch(`${API}/auth/refresh`, { method: 'POST', headers: { Accept: 'application/json', 'Content-Type': 'application/json' }, body: JSON.stringify({ refresh_token: token }) })
    .then(async r => { const b = await r.json().catch(() => ({})); if (!r.ok || !b?.data?.tokens) return false; session.save(b.data.tokens); return true; })
    .catch(() => false).finally(() => { refreshing = null; });
  return refreshing;
};
async function api(path, { method = 'GET', body, retry = true } = {}) {
  const headers = { Accept: 'application/json' };
  if (session.token) headers.Authorization = `Bearer ${session.token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  let r;
  try { r = await fetch(`${API}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }); }
  catch { throw new ApiError(messageFrom(null, 0), 0); }
  if (r.status === 401 && retry && await refresh()) return api(path, { method, body, retry: false });
  const data = await r.json().catch(() => ({}));
  if (r.status === 401) { session.clear(); go('/app/'); throw new ApiError('Your session ended. Sign in again.', 401, data); }
  if (!r.ok) throw new ApiError(messageFrom(data, r.status), r.status, data);
  return data.data;
}

// ---------- sign-in with Contacts++ (PKCE) ----------
async function signIn() {
  const verifier = randomToken(64), state = randomToken(24);
  const challenge = b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))));
  once.set('mpw_verifier', verifier); once.set('mpw_state', state);
  const u = new URL(`${CONTACTS_WEB}/app-authorize`);
  Object.entries({ client_id: CLIENT_ID, redirect_uri: REDIRECT, code_challenge: challenge, state, scopes: SCOPES.join(' ') })
    .forEach(([k, v]) => u.searchParams.set(k, v));
  location.href = u.toString();
}
async function finishSignIn(query) {
  const code = query.get('code'), state = query.get('state');
  const expected = once.get('mpw_state'), verifier = once.get('mpw_verifier');
  once.del('mpw_state'); once.del('mpw_verifier');
  history.replaceState(null, '', '/app/');
  if (query.get('error') === 'access_denied') { toast('Sign-in was cancelled.'); return false; }
  if (!code || !state || !verifier || state !== expected) { toast('That sign-in link expired. Try again.'); return false; }
  try {
    const data = await api('/auth/connected-app/token', { method: 'POST', body: {
      grant_type: 'authorization_code', client_id: CLIENT_ID, redirect_uri: REDIRECT, code, code_verifier: verifier,
      device_name: `Messages++ on the web (${navigator.userAgent.includes('Mac') ? 'Mac' : navigator.userAgent.includes('Windows') ? 'Windows' : 'browser'})`.slice(0, 120),
      platform: 'web',
    } });
    session.save(data.tokens);
    store.set('mpw_me', JSON.stringify(data.user));
    store.del('mpw_signed_out');
    try { sessionStorage.removeItem('mpw_auto'); } catch { /* private mode */ }
    return true;
  } catch (e) { toast(e.message); return false; }
}
/**
 * Signed in to Contacts++ means signed in here: go straight through
 * Contacts++, which returns at once when its session is active. The welcome
 * screen with its button appears only after a sign-out, or when automatic
 * sign-in already ran in this tab (cancelled or failed).
 */
function autoSignIn() {
  let attempted = false;
  try { attempted = sessionStorage.getItem('mpw_auto') === '1'; } catch { /* private mode */ }
  if (store.get('mpw_signed_out') === '1' || attempted) return viewWelcome();
  try { sessionStorage.setItem('mpw_auto', '1'); } catch { /* private mode */ }
  render(html`<section class="hero"><h1>Signing you in…</h1><p class="muted">1/2 · Continuing with your Contacts++ account. Next: Send.</p></section>`);
  signIn();
}
async function signOut() {
  try { await api('/auth/logout', { method: 'POST', body: {} }); } catch { /* signing out here always works */ }
  // Stay signed out here until the person chooses to sign in again.
  store.set('mpw_signed_out', '1');
  session.clear();
  go('/app/');
}
const me = () => { try { return JSON.parse(store.get('mpw_me') || 'null'); } catch { return null; } };

// ---------- synced records (contacts, groups, campaigns, texts) ----------
// Local-first: what was loaded last time shows at once; only changes are fetched.
const records = {
  data: (() => { try { return JSON.parse(store.get('mpw_records') || '{}'); } catch { return {}; } })(),
  cursor: Number(store.get('mpw_cursor') || 0),
  list(kind) { return Object.values(this.data).filter(r => r.kind === kind && !r.deleted); },
  get(kind, key) { return this.data[`${kind}/${key}`]; },
  save() {
    store.set('mpw_cursor', String(this.cursor));
    // Texts are large: keep only contacts, groups and campaigns in the browser.
    const keep = Object.fromEntries(Object.entries(this.data).filter(([, r]) => r.kind !== 'message'));
    store.set('mpw_records', JSON.stringify(keep));
  },
  async refresh(onPage) {
    let more = true, pages = 0;
    while (more && pages < 200) {
      const page = await api(`/messages-plus/sync?since=${this.cursor}&limit=500`);
      for (const r of page.records) {
        const id = `${r.kind}/${r.key}`;
        if (r.deleted) delete this.data[id]; else this.data[id] = r;
      }
      this.cursor = page.cursor; more = page.has_more; pages++;
      onPage?.(pages);
    }
    this.save();
    counts();
  },
  async push(list) {
    const res = await api('/messages-plus/sync', { method: 'POST', body: { records: list, device: 'web' } });
    for (const r of list) {
      const id = `${r.kind}/${r.key}`;
      if (r.deleted) delete this.data[id]; else this.data[id] = { ...r, seq: res.cursor };
    }
    this.save();
    counts();
  },
};
const contactName = key => records.get('contact', key)?.data?.name;
function counts() {
  const set = (k, n) => { const el = document.querySelector(`[data-count="${k}"]`); if (el) el.textContent = n ? String(n) : ''; };
  set('people', records.list('contact').length);
}

// ---------- template ----------
const firstName = name => String(name || '').trim().split(/\s+/)[0] || '';
const renderTemplate = (template, person) => template
  .replace(/\{first_name\}/g, firstName(person.name))
  .replace(/\{name\}/g, person.name || '')
  .replace(/\{company\}/g, person.organization || '')
  .trim();
const segments = text => { const gsm = /^[\x20-\x7E\n\r£¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉÄÖÑÜ§¿äöñüà€]*$/.test(text); const per = gsm ? 160 : 70; const multi = gsm ? 153 : 67; return text.length <= per ? 1 : Math.ceil(text.length / multi); };

// ---------- views ----------
function viewWelcome() {
  render(html`<section class="hero">
    <img src="/assets/messages-plus-plus-icon.png" alt="" width="72" height="72">
    <h1>Messages++ on the web</h1>
    <p class="muted">Write texts on your computer. Your phone sends them from your own number, and Contacts++ members get them as chats.</p>
    <p style="margin:22px 0"><button class="btn" data-signin>→ Continue with Contacts++</button></p>
    <p class="muted small">You need Messages++ on your phone, signed in with the same Contacts++ account. No account yet? Contacts++ is free.</p>
  </section>
  <div class="card">
    <h2>How it works</h2>
    <ol class="steps"><li class="done">Sign in here and in Messages++ on your phone.</li><li class="done">Write a message and pick people or groups.</li><li class="done">Your phone sends it: chats to Contacts++ members, texts to everyone else.</li></ol>
  </div>`);
  $('[data-signin]').addEventListener('click', () => { store.del('mpw_signed_out'); signIn(); });
}

let phonesCache = null;
async function phones() { phonesCache ??= (await api('/messages-plus/phones')).phones; return phonesCache; }

async function viewSend(query) {
  const people = records.list('contact').sort((a, b) => String(a.data.name).localeCompare(String(b.data.name)));
  const groups = records.list('group').sort((a, b) => String(a.data.name).localeCompare(String(b.data.name)));
  render(html`<h1>Send</h1>
    <p class="muted">Your phone sends these from your number. Opt-outs and send limits on the phone still apply.</p>
    <div class="banner" data-phones hidden></div>
    <div class="card">
      <label for="to">To</label>
      <div class="chips" data-groups>${groups.map(g => html`<button type="button" class="chip" aria-pressed="false" data-group="${g.key}">👥 ${g.data.name} · ${(g.data.members || []).length}</button>`)}</div>
      ${groups.length ? '' : html`<p class="muted small">Your groups appear here once your phone backs up (Messages++ › Settings › Backup and sync).</p>`}
      <textarea id="to" rows="3" placeholder="Or numbers, one per line or separated by commas (+2348030000000)" style="min-height:70px;margin-top:10px">${query.get('to') || ''}</textarea>
      <p class="small muted" data-recipients>No one yet.</p>
      <label for="body">Message</label>
      <textarea id="body" placeholder="Hi {first_name}, …">${query.get('body') || ''}</textarea>
      <div class="row small muted"><span data-length>0 characters</span><span>· Placeholders: {first_name} {name} {company}</span></div>
      <label for="name">Name for this send <span class="muted small">(optional)</span></label>
      <input id="name" maxlength="120" placeholder="Choir reminder">
      <div class="row">
        <div class="grow"><label for="phone">Send from</label><select id="phone"><option value="">Any of my phones</option></select></div>
        <div class="grow"><label for="when">When</label><input id="when" type="datetime-local"></div>
      </div>
    </div>
    <div class="card"><h2 style="margin-top:0">Preview</h2><div class="preview" data-preview>Write a message to see what people get.</div></div>
    <div class="row"><button class="btn" data-send>➤ Send from my phone</button><span class="muted small" data-status role="status"></span></div>
    <div data-progress></div>`);

  const picked = new Set();
  const recipients = () => {
    const out = new Map();
    for (const g of picked) for (const key of records.get('group', g)?.data?.members || []) {
      const c = records.get('contact', key)?.data; if (c?.phone && c.consent !== 'opted_out') out.set(c.phone, c);
    }
    for (const n of $('#to').value.split(/[\n,;]+/).map(s => s.trim()).filter(Boolean)) {
      const known = people.find(p => p.data.phone === n)?.data;
      if (!out.has(n)) out.set(n, known || { name: '', phone: n });
    }
    return [...out.values()];
  };
  const update = () => {
    const list = recipients(), body = $('#body').value;
    $('[data-recipients]').textContent = list.length ? `${list.length} ${list.length === 1 ? 'person' : 'people'}` : 'No one yet.';
    $('[data-length]').textContent = `${body.length} characters · ${segments(renderTemplate(body, { name: 'Sample Name' }) || ' ')} SMS part(s)`;
    const sample = list[0] || { name: 'Ada Obi' };
    $('[data-preview]').textContent = body ? renderTemplate(body, sample) : 'Write a message to see what people get.';
  };
  view().addEventListener('input', update);
  view().querySelectorAll('[data-group]').forEach(b => b.addEventListener('click', () => {
    const k = b.dataset.group; picked.has(k) ? picked.delete(k) : picked.add(k);
    b.setAttribute('aria-pressed', String(picked.has(k))); update();
  }));
  if (query.get('group')) view().querySelector(`[data-group="${CSS.escape(query.get('group'))}"]`)?.click();
  update();

  try {
    const list = await phones();
    const select = $('#phone');
    list.forEach(p => select.append(new Option(`${p.name}${p.sends_automatically ? '' : ' (you tap Send on it)'}`, p.id)));
    const b = $('[data-phones]');
    if (!list.length) { b.hidden = false; b.textContent = 'Sign in to Messages++ on your phone with this Contacts++ account first: it sends the texts.'; }
    else if (list.every(p => !p.sends_automatically)) { b.hidden = false; b.textContent = 'Your iPhone asks you to tap Send for each text (chats to Contacts++ members go by themselves).'; }
  } catch (e) { toast(e.message); }

  $('[data-send]').addEventListener('click', async ev => {
    const list = recipients(), body = $('#body').value.trim();
    if (!list.length) return toast('Add at least one person or group.');
    if (!body) return toast('Write a message first.');
    const messages = list.map(p => ({ to: p.phone, body: renderTemplate(body, p), name: p.name || undefined }));
    const chunks = []; for (let i = 0; i < messages.length; i += BATCH_MAX) chunks.push(messages.slice(i, i + BATCH_MAX));
    const sendAt = $('#when').value ? new Date($('#when').value).toISOString() : undefined;
    ev.target.disabled = true;
    const progress = $('[data-progress]');
    const steps = chunks.map((_, i) => `Queuing ${Math.min((i + 1) * BATCH_MAX, messages.length)} of ${messages.length}`);
    const show = (done, now) => { progress.innerHTML = html`<div class="card"><strong>${now + 1}/${steps.length + 1} · ${now < steps.length ? steps[now] : 'Waking your phone'}</strong>
      <div class="bar" style="margin-top:8px"><span style="width:${Math.round((done / (steps.length + 1)) * 100)}%"></span></div>
      <ul class="steps">${[...steps, 'Waking your phone'].map((s, i) => html`<li class="${i < done ? 'done' : i === now ? 'now' : 'todo'}">${s}</li>`)}</ul></div>`.s; };
    let rejected = 0, last;
    try {
      for (let i = 0; i < chunks.length; i++) {
        show(i, i);
        const res = await api('/messages-plus/relay/batches', { method: 'POST', body: {
          name: $('#name').value || undefined, phone_id: $('#phone').value || undefined, send_at: sendAt, messages: chunks[i],
        } });
        rejected += res.rejected.length; last = res.batch;
      }
      show(steps.length + 1, steps.length);
      toast(rejected ? `Queued. ${rejected} number(s) weren't valid and were left out.` : sendAt ? 'Scheduled. Your phone sends it then.' : 'Sent to your phone.');
      go(`/app/sends/${last.id}`);
    } catch (e) {
      progress.innerHTML = '';
      ev.target.disabled = false;
      toast(e.message);
    }
  });
}

const STATUS_LABEL = { queued: 'Waiting for phone', claimed: 'On your phone', sent: 'Sent', delivered: 'Delivered', failed: 'Failed', opted_out: 'Opted out', expired: 'Phone didn’t answer', cancelled: 'Cancelled' };
const statusTag = s => html`<span class="tag ${['failed', 'expired'].includes(s) ? 'bad' : ['queued', 'claimed'].includes(s) ? 'warn' : ''}">${STATUS_LABEL[s] || s}</span>`;
const summary = counts => Object.entries(counts || {}).map(([k, n]) => `${n} ${(STATUS_LABEL[k] || k).toLowerCase()}`).join(' · ');

async function viewSends() {
  render(html`<h1>Sends</h1><p class="muted">Texts you wrote here and on the API, and what your phone did with them.</p><div class="card"><ul class="list" data-list><li class="loading">Loading…</li></ul></div><p><button class="btn secondary" data-more hidden>↓ Show older</button></p>`);
  let page = 1;
  const list = $('[data-list]');
  const load = async () => {
    try {
      const data = await api(`/messages-plus/relay/batches?page=${page}`);
      if (page === 1) list.innerHTML = '';
      if (page === 1 && !data.batches.length) list.innerHTML = html`<li class="muted">Nothing sent yet. <a href="/app/send" data-link>Write your first message</a>.</li>`.s;
      data.batches.forEach(b => list.insertAdjacentHTML('beforeend', html`<li><a class="item" href="/app/sends/${b.id}" data-link>
        <span class="avatar">${b.source === 'api' ? '⌘' : '✎'}</span>
        <span class="grow"><strong class="ellipsis">${b.name || (b.source === 'api' ? 'API' : 'Web send')}</strong><br><span class="small muted">${when(b.created_at)} · ${b.total} · ${summary(b.counts)}</span></span>
        <span aria-hidden="true">›</span></a></li>`.s));
      $('[data-more]').hidden = !data.next_page;
      page = data.next_page || page;
    } catch (e) { toast(e.message); }
  };
  $('[data-more]').addEventListener('click', load);
  await load();
}

async function viewSend1(id) {
  render(html`<p><a href="/app/sends" data-link>‹ Sends</a></p><div data-head class="loading">Loading…</div><div class="card"><ul class="list" data-list></ul></div><p><button class="btn secondary" data-more hidden>↓ More</button></p>`);
  let page = 1, timer;
  const head = async () => {
    const data = await api(`/messages-plus/relay/batches/${id}?page=1`);
    const b = data.batch, open = (b.counts.queued || 0) > 0;
    $('[data-head]').className = '';
    $('[data-head]').innerHTML = html`<h1>${b.name || 'Web send'}</h1>
      <p class="muted">${when(b.created_at)}${b.send_at ? ` · scheduled for ${when(b.send_at)}` : ''}</p>
      <div class="card"><strong>${summary(b.counts) || 'Waiting'}</strong>
      <div class="bar" style="margin-top:8px"><span style="width:${Math.round((((b.counts.sent || 0) + (b.counts.delivered || 0) + (b.counts.failed || 0) + (b.counts.opted_out || 0)) / Math.max(1, b.total)) * 100)}%"></span></div>
      ${open ? html`<p class="small muted">Waiting texts expire ${when(b.expires_at)} if no phone picks them up.</p><button class="btn danger" data-cancel>✕ Cancel waiting texts</button>` : ''}</div>`.s;
    $('[data-cancel]')?.addEventListener('click', async ev => {
      ev.target.disabled = true;
      try { const r = await api(`/messages-plus/relay/batches/${id}`, { method: 'DELETE' }); toast(`${r.cancelled} cancelled.`); head(); }
      catch (e) { ev.target.disabled = false; toast(e.message); }
    });
    return data;
  };
  const rows = jobs => jobs.map(j => html`<li><span class="avatar">${initials(j.name || j.to)}</span>
    <span class="grow"><strong class="ellipsis">${j.name || j.to}</strong><br><span class="small muted">${j.to}${j.channel ? ` · ${j.channel === 'chat' ? 'Contacts++ chat' : 'text'}` : ''}${j.error_code ? ` · ${j.error_code}` : ''}</span></span>
    ${statusTag(j.status)}</li>`.s).join('');
  try {
    const data = await head();
    $('[data-list]').innerHTML = rows(data.jobs);
    $('[data-more]').hidden = !data.next_page;
    page = data.next_page || 1;
    $('[data-more]').addEventListener('click', async () => {
      const more = await api(`/messages-plus/relay/batches/${id}?page=${page}`);
      $('[data-list]').insertAdjacentHTML('beforeend', rows(more.jobs));
      $('[data-more]').hidden = !more.next_page; page = more.next_page || page;
    });
    // Follow progress while open (the phone reports within about a minute).
    timer = setInterval(() => { if (!document.hidden && location.pathname.endsWith(id)) head().catch(() => {}); else clearInterval(timer); }, 15000);
  } catch (e) { $('[data-head]').textContent = e.message; }
}

async function viewBackup() {
  render(html`<h1>Backup</h1><div class="card" data-sum><p class="loading">Loading…</p></div>
    <h2>Recent campaigns</h2><div class="card"><ul class="list" data-campaigns></ul></div>`);
  try {
    const s = await api('/messages-plus/sync/summary');
    const c = s.counts || {};
    $('[data-sum]').innerHTML = html`<p><strong>${c.contact || 0}</strong> contacts · <strong>${c.group || 0}</strong> groups · <strong>${c.campaign || 0}</strong> campaigns · <strong>${c.message || 0}</strong> texts</p>
      <p class="muted small">Last change ${when(s.last_synced_at) || 'never'} · ${Math.round((s.size_bytes || 0) / 1024)} KB · encrypted on Contacts++ servers, visible only to you.</p>
      <p class="muted small">Backup is turned on and off in Messages++ on your phone (Settings › Backup and sync), where you can also delete it.</p>`.s;
  } catch (e) { $('[data-sum]').textContent = e.message; }
  const campaigns = records.list('campaign').sort((a, b) => String(b.data.created_at).localeCompare(String(a.data.created_at))).slice(0, 50);
  $('[data-campaigns]').innerHTML = campaigns.map(k => html`<li><span class="avatar">✉</span><span class="grow"><strong class="ellipsis">${k.data.name}</strong><br>
    <span class="small muted">${when(k.data.created_at)} · ${Object.entries(k.data.recipients || {}).map(([s, n]) => `${n} ${s.replace('_', ' ')}`).join(' · ')}</span></span></li>`.s).join('')
    || html`<li class="muted">No campaigns backed up yet.</li>`.s;
}

async function viewDevelopers() {
  render(html`<h1>Messages++ API</h1>
    <p class="muted">Send texts from your own phone with a simple HTTPS API. <a href="/developers/">Read the guide</a>.</p>
    <div data-body><p class="loading">Loading…</p></div>`);
  const body = $('[data-body]');
  let data;
  try { data = await api('/messages-plus/developer/keys'); } catch (e) { body.textContent = e.message; return; }
  if (!data.premium) {
    body.innerHTML = html`<div class="banner">The API is part of Contacts++ Premium. <a href="${CONTACTS_WEB}/plans" rel="noopener">See plans</a>, then come back here.</div>`.s;
    return;
  }
  const phoneList = await phones().catch(() => []);
  body.innerHTML = html`<p class="muted small">${data.sent_today} sent through the API today.</p>
    <div class="card"><h2 style="margin-top:0">Your keys <span class="muted small">${data.keys.length}</span></h2><ul class="list" data-keys></ul></div>
    <details class="card"><summary><strong>＋ New key</strong></summary>
      <label for="kname">Name</label><input id="kname" maxlength="80" placeholder="My shop">
      <label for="khook">Webhook URL <span class="muted small">(optional, https)</span></label><input id="khook" type="url" placeholder="https://example.com/messages-webhook">
      <div class="row"><div class="grow"><label for="klimit">Daily limit</label><input id="klimit" type="number" min="1" max="5000" value="500"></div>
      <div class="grow"><label for="kphone">Send from</label><select id="kphone"><option value="">Any of my phones</option>${phoneList.map(p => html`<option value="${p.id}">${p.name}</option>`)}</select></div></div>
      <label for="kips">Allowed IP addresses <span class="muted small">(optional, one per line; ranges like 203.0.113.0/24)</span></label><textarea id="kips" style="min-height:60px"></textarea>
      <label class="check"><input type="checkbox" id="kterms"> <span>I only text people who agreed to hear from me, honour opt-outs, and follow my carrier's rules. Texts go from my own SIM and number.</span></label>
      <p><button class="btn" data-create>⚿ Create key</button></p>
    </details>
    <div data-secret></div>`.s;
  const drawKeys = keys => {
    $('[data-keys]').innerHTML = keys.map(k => html`<li><span class="avatar">⚿</span><span class="grow"><strong>${k.name}</strong><br>
      <span class="small muted">${k.hint} · ${k.daily_limit}/day${k.webhook_url ? ` · webhook ${k.webhook_url}` : ''} · last used ${when(k.last_used_at) || 'never'}</span></span>
      <button class="btn secondary" data-rotate="${k.id}" title="New webhook secret">↻ Secret</button>
      <button class="btn danger" data-revoke="${k.id}">✕ Revoke</button></li>`.s).join('') || html`<li class="muted">No keys yet.</li>`.s;
  };
  drawKeys(data.keys);
  const showSecret = (title, items) => {
    $('[data-secret]').innerHTML = html`<div class="card banner ok"><strong>${title}</strong>
      <p class="small">Copy these now: they are shown only once.</p>${items.map(([l, v]) => html`<p class="small"><b>${l}</b></p><div class="secret">${v}</div>`)}</div>`.s;
  };
  $('[data-create]').addEventListener('click', async ev => {
    ev.target.disabled = true;
    try {
      const ips = $('#kips').value.split(/\s+/).filter(Boolean);
      const res = await api('/messages-plus/developer/keys', { method: 'POST', body: {
        name: $('#kname').value, webhook_url: $('#khook').value || null, daily_limit: Number($('#klimit').value) || 500,
        phone_id: $('#kphone').value || null, allowed_ips: ips.length ? ips : null, accept_terms: $('#kterms').checked,
      } });
      data.keys.unshift(res.key); drawKeys(data.keys);
      showSecret('Key created', [['API key', res.api_key], ['Webhook signing secret', res.webhook_secret]]);
      $('details').open = false;
    } catch (e) { toast(e.message); }
    ev.target.disabled = false;
  });
  $('[data-keys]').addEventListener('click', async ev => {
    const revoke = ev.target.closest('[data-revoke]')?.dataset.revoke, rotate = ev.target.closest('[data-rotate]')?.dataset.rotate;
    if (revoke) {
      if (!confirm('Revoke this key? Anything using it stops working at once. This can’t be undone.')) return;
      const before = [...data.keys];
      data.keys = data.keys.filter(k => k.id !== revoke); drawKeys(data.keys);
      try { await api(`/messages-plus/developer/keys/${revoke}`, { method: 'DELETE' }); toast('Key revoked.'); }
      catch (e) { data.keys = before; drawKeys(data.keys); toast(e.message); }
    }
    if (rotate) {
      try { const r = await api(`/messages-plus/developer/keys/${rotate}`, { method: 'PATCH', body: { rotate_webhook_secret: true } }); showSecret('New webhook secret', [['Webhook signing secret', r.webhook_secret]]); }
      catch (e) { toast(e.message); }
    }
  });
}

// ---------- phone numbers ----------
/** The country code used for numbers typed or imported without one (+234…). */
const defaultCountryCode = () => {
  const saved = store.get('mpw_cc');
  if (saved) return saved;
  // The most common code among your contacts.
  const tally = {};
  for (const c of records.list('contact')) { const m = /^\+(\d{1,3})/.exec(c.data.phone || ''); if (m) tally[m[1].slice(0, 3)] = (tally[m[1].slice(0, 3)] || 0) + 1; }
  const best = Object.entries(tally).sort((a, b) => b[1] - a[1])[0]?.[0];
  return best ? `+${best}` : '+234';
};
/** E.164 for a typed number, or '' when it can't be one. */
const toE164 = (raw, cc = defaultCountryCode()) => {
  let v = String(raw || '').trim().replace(/[^\d+]/g, '');
  if (!v) return '';
  if (v.startsWith('00')) v = `+${v.slice(2)}`;
  if (!v.startsWith('+')) v = `${cc}${v.replace(/^0+/, '')}`;
  return /^\+\d{7,15}$/.test(v) ? v : '';
};

// ---------- campaigns (synced with the phone) ----------
const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const STATE_LABEL = {
  waiting: 'Waiting for your phone', scheduled: 'Scheduled', ready: 'Ready', sending: 'Sending', needs_tap: 'Tap Send on your phone',
  paused: 'Paused', sent: 'Sent', partially_completed: 'Partly sent', failed: 'Failed', cancelled: 'Cancelled',
  needs_attention: 'Needs attention', needs_pro: 'Needs Pro', missed: 'Missed', done: 'Done',
};
const stateTone = s => (['failed', 'missed', 'needs_attention', 'needs_pro'].includes(s) ? 'bad' : ['waiting', 'needs_tap', 'paused'].includes(s) ? 'warn' : '');
/** What the phone last said about a plan; "waiting" until it has the latest edit. */
const planState = plan => {
  const status = records.get('campaign_status', plan.key)?.data;
  const applied = status?.applied_updated_at, edited = plan.data.updated_at;
  if (!status || (edited && applied && applied < edited) || (edited && !applied)) return { state: 'waiting', status };
  return { state: status.state || 'waiting', status };
};
/** Once it has started sending, a one-time campaign is history: duplicate it to send again. */
const planLocked = plan => {
  const { state } = planState(plan);
  return plan.data.schedule?.kind !== 'weekly' && ['sending', 'needs_tap', 'sent', 'partially_completed', 'failed', 'cancelled', 'done'].includes(state);
};
const describeSchedule = sch => {
  if (!sch) return 'Send now';
  if (sch.kind === 'once') return `Once · ${when(sch.at)}`;
  const days = WEEKDAYS.filter((_, i) => sch.weekdays & (1 << i));
  const hh = String(Math.floor(sch.minute_of_day / 60)).padStart(2, '0'), mm = String(sch.minute_of_day % 60).padStart(2, '0');
  return `Every ${days.length === 7 ? 'day' : days.join(', ')} at ${hh}:${mm}${sch.ends_on ? ` until ${sch.ends_on}` : ''}`;
};
const audienceSize = data => {
  const people = new Set(data.audience?.contacts || []);
  for (const g of data.audience?.groups || []) for (const k of records.get('group', g)?.data?.members || []) people.add(k);
  return [...people].filter(k => records.get('contact', k)?.data?.phone).length;
};
const countsLine = counts => Object.entries(counts || {}).map(([k, n]) => `${n} ${k.replace(/_/g, ' ')}`).join(' · ');

async function viewCampaigns() {
  const plans = records.list('campaign_plan').sort((a, b) => String(b.data.updated_at).localeCompare(String(a.data.updated_at)));
  const history = records.list('campaign').sort((a, b) => String(b.data.created_at).localeCompare(String(a.data.created_at))).slice(0, 30);
  render(html`<div class="row"><h1 class="grow">Campaigns</h1>
      <a class="btn secondary" href="/app/send" data-link>➤ Quick send</a>
      <a class="btn" href="/app/campaigns/new" data-link>＋ New campaign</a></div>
    <p class="muted">Set them up here; Messages++ on your phone saves them and sends at the time you choose, from your own number.</p>
    <div class="banner" data-phones hidden></div>
    <div class="card"><ul class="list">${plans.map(p => {
      const { state, status } = planState(p);
      const next = status?.next_run_at ? ` · next ${when(status.next_run_at)}` : '';
      const last = status?.last_run?.counts ? ` · last run: ${countsLine(status.last_run.counts)}` : '';
      return html`<li><a class="item" href="/app/campaigns/${p.key}" data-link><span class="avatar">${p.data.schedule?.kind === 'weekly' ? '↻' : '✉'}</span>
        <span class="grow"><strong class="ellipsis">${p.data.name}</strong><br><span class="small muted">${describeSchedule(p.data.schedule)} · ${audienceSize(p.data)} people${next}${last}</span></span>
        <span class="tag ${stateTone(state)}">${STATE_LABEL[state] || state}</span></a></li>`;
    })}${plans.length ? '' : html`<li class="muted">No campaigns yet. <a href="/app/campaigns/new" data-link>Set up your first one</a>; your phone sends it.</li>`}</ul></div>
    <h2>Sent from your phone</h2>
    <div class="card"><ul class="list">${history.map(k => html`<li><span class="avatar">✓</span><span class="grow"><strong class="ellipsis">${k.data.name}</strong><br>
      <span class="small muted">${when(k.data.created_at)} · ${countsLine(k.data.recipients)}</span></span></li>`)}
      ${history.length ? '' : html`<li class="muted small">Campaigns your phone sent appear here when Backup and sync is on in Messages++.</li>`}</ul></div>`);
  phones().then(list => {
    const b = $('[data-phones]'); if (!b) return;
    if (!list.length) { b.hidden = false; b.textContent = 'Sign in to Messages++ on your phone with this Contacts++ account: it saves and sends these campaigns.'; }
  }).catch(() => {});
}

async function viewCampaign(key, query) {
  const existing = key ? records.get('campaign_plan', key) : null;
  if (key && !existing) { render(html`<p><a href="/app/campaigns" data-link>‹ Campaigns</a></p><div class="banner">This campaign was deleted.</div>`); return; }
  const copyOf = query.get('copy') ? records.get('campaign_plan', query.get('copy')) : null;
  const d = existing?.data || (copyOf ? { ...copyOf.data, name: `${copyOf.data.name} (copy)`, schedule: null } : {
    name: '', template: '', channel: 'sms', audience: { groups: query.get('group') ? [query.get('group')] : [], contacts: [] }, fallbacks: {}, schedule: null, enabled: true,
  });
  const locked = existing && planLocked(existing);
  const { state, status } = existing ? planState(existing) : { state: null, status: null };
  const groups = records.list('group').sort((a, b) => String(a.data.name).localeCompare(String(b.data.name)));
  const people = records.list('contact').filter(c => c.data.phone).sort((a, b) => String(a.data.name).localeCompare(String(b.data.name)));
  const sch = d.schedule;
  const at = sch?.kind === 'once' && sch.at ? new Date(sch.at) : null;
  const local = dt => dt ? new Date(dt.getTime() - dt.getTimezoneOffset() * 60000).toISOString().slice(0, 16) : '';
  const minute = sch?.kind === 'weekly' ? sch.minute_of_day : 9 * 60;
  render(html`<p><a href="/app/campaigns" data-link>‹ Campaigns</a></p>
    <div class="row"><h1 class="grow">${existing ? d.name : 'New campaign'}</h1>
      ${state ? html`<span class="tag ${stateTone(state)}">${STATE_LABEL[state] || state}</span>` : ''}</div>
    ${status?.message ? html`<div class="banner">${status.message}</div>` : ''}
    ${state === 'waiting' && existing ? html`<p class="small muted">Your phone picks this up within seconds when it's online, otherwise the next time Messages++ opens.</p>` : ''}
    ${status?.next_run_at ? html`<p class="small muted">Next send ${when(status.next_run_at)} · ${status.recipients || audienceSize(d)} people</p>` : ''}
    ${status?.last_run ? html`<div class="card"><strong>Last run · ${status.last_run.name}</strong><p class="small muted">${countsLine(status.last_run.counts) || 'Waiting'}</p></div>` : ''}
    ${locked ? html`<div class="banner ok">This campaign has been sent, so it can't be changed. <a href="/app/campaigns/new?copy=${encodeURIComponent(key)}" data-link>Duplicate it</a> to send it again.</div>` : ''}
    <fieldset ${locked ? 'disabled' : ''} style="border:0;padding:0;margin:0">
    <div class="card">
      <label for="cname">Name</label><input id="cname" maxlength="120" value="${d.name}" placeholder="Choir practice reminder">
      <label for="body">Message</label>
      <textarea id="body" placeholder="Hi {first_name}, …">${d.template}</textarea>
      <div class="row small muted"><span data-length></span><span>· Placeholders: {first_name} {name} {company} {invite_link}</span></div>
      <div data-fallbacks></div>
    </div>
    <div class="card">
      <h2 style="margin-top:0">Who gets it <span class="muted small" data-count-people></span></h2>
      <div class="chips" data-groups>${groups.map(g => html`<button type="button" class="chip" aria-pressed="${(d.audience?.groups || []).includes(g.key)}" data-group="${g.key}">👥 ${g.data.name} · ${(g.data.members || []).length}</button>`)}</div>
      ${groups.length ? '' : html`<p class="muted small">No groups yet. <a href="/app/people" data-link>Make one in People</a>.</p>`}
      <details style="margin-top:10px"><summary><strong>Pick people</strong> <span class="muted small" data-picked></span></summary>
        <input type="search" placeholder="Search names and numbers" data-pq aria-label="Search people" style="margin-top:8px">
        <ul class="list" data-people style="max-height:320px;overflow:auto"></ul>
      </details>
    </div>
    <div class="card">
      <h2 style="margin-top:0">When</h2>
      <div class="chips" role="radiogroup">
        ${[['now', 'Send now'], ['once', 'Pick a date and time'], ['weekly', 'Repeat every week']].map(([v, l]) => html`<button type="button" class="chip" role="radio" data-when="${v}" aria-pressed="${(sch?.kind || 'now') === v}">${l}</button>`)}
      </div>
      <div data-once ${sch?.kind === 'once' ? '' : 'hidden'}><label for="at">Date and time</label><input id="at" type="datetime-local" value="${local(at)}"></div>
      <div data-weekly ${sch?.kind === 'weekly' ? '' : 'hidden'}>
        <label>Days</label><div class="chips">${WEEKDAYS.map((w, i) => html`<button type="button" class="chip" data-day="${i}" aria-pressed="${Boolean(sch?.kind === 'weekly' && (sch.weekdays & (1 << i)))}">${w}</button>`)}</div>
        <div class="row"><div class="grow"><label for="time">Time</label><input id="time" type="time" value="${String(Math.floor(minute / 60)).padStart(2, '0')}:${String(minute % 60).padStart(2, '0')}"></div>
        <div class="grow"><label for="ends">Until <span class="muted small">(optional)</span></label><input id="ends" type="date" value="${sch?.ends_on || ''}"></div></div>
        <p class="small muted">Times are your phone's local time.</p>
      </div>
      ${existing && sch ? html`<label class="check" style="margin-top:12px"><input type="checkbox" id="enabled" ${d.enabled === false ? '' : 'checked'}> <span>On · uncheck to pause it on your phone</span></label>` : ''}
    </div>
    <div class="card"><h2 style="margin-top:0">Preview</h2><div class="preview" data-preview></div></div>
    </fieldset>
    <div class="row">
      ${locked ? '' : html`<button class="btn" data-save>${existing ? '✓ Save changes' : '✓ Save and send to my phone'}</button>`}
      ${existing ? html`<a class="btn secondary" href="/app/campaigns/new?copy=${encodeURIComponent(key)}" data-link>⧉ Duplicate</a><button class="btn danger" data-delete>✕ Delete</button>` : ''}
      <span class="muted small" data-status role="status"></span>
    </div>`);

  const chosenGroups = new Set(d.audience?.groups || []), chosenPeople = new Set(d.audience?.contacts || []);
  const fallbacks = { ...(d.fallbacks || {}) };
  let mode = sch?.kind || 'now';
  const days = new Set(WEEKDAYS.map((_, i) => i).filter(i => sch?.kind === 'weekly' && (sch.weekdays & (1 << i))));
  const recipients = () => {
    const keys = new Set(chosenPeople);
    for (const g of chosenGroups) for (const k of records.get('group', g)?.data?.members || []) keys.add(k);
    return [...keys].map(k => records.get('contact', k)?.data).filter(c => c?.phone && c.consent !== 'opted_out');
  };
  const drawPeople = () => {
    const q = $('[data-pq]').value.toLowerCase();
    $('[data-people]').innerHTML = people.filter(c => !q || `${c.data.name} ${c.data.phone}`.toLowerCase().includes(q)).slice(0, 300)
      .map(c => html`<li><label class="check" style="margin:0;width:100%"><input type="checkbox" data-person="${c.key}" ${chosenPeople.has(c.key) ? 'checked' : ''}>
        <span class="grow"><strong>${c.data.name}</strong> <span class="small muted">${c.data.phone}</span></span></label></li>`.s).join('')
      || html`<li class="muted small">No one with a number matches.</li>`.s;
  };
  const update = () => {
    const body = $('#body').value, list = recipients();
    $('[data-length]').textContent = `${body.length} characters · ${segments(renderTemplate(body, { name: 'Sample Name' }) || ' ')} SMS part(s)`;
    $('[data-count-people]').textContent = `· ${list.length} ${list.length === 1 ? 'person' : 'people'}`;
    $('[data-picked]').textContent = chosenPeople.size ? `· ${chosenPeople.size} picked` : '';
    const sample = list[0] || { name: 'Ada Obi' };
    $('[data-preview]').textContent = body ? renderTemplate(body, sample).replace(/\{invite_link\}/g, CONTACTS_WEB) : 'Write a message to see what people get.';
    // A fallback for each placeholder someone might not have a value for.
    const vars = [...new Set([...body.matchAll(/\{(\w+)\}/g)].map(m => m[1]))].filter(v => !['invite_link'].includes(v));
    const box = $('[data-fallbacks]');
    const wanted = vars.join(',');
    if (box.dataset.vars !== wanted) {
      box.dataset.vars = wanted;
      box.innerHTML = vars.length ? html`<p class="small muted" style="margin-top:12px">If someone has no value, use:</p><div class="row">${vars.map(v => html`<div class="grow"><label for="fb-${v}">{${v}}</label><input id="fb-${v}" data-fallback="${v}" value="${fallbacks[v] || ''}" placeholder="${v === 'first_name' ? 'friend' : ''}"></div>`)}</div>`.s : '';
    }
  };
  view().addEventListener('input', ev => {
    if (ev.target.dataset.fallback) fallbacks[ev.target.dataset.fallback] = ev.target.value;
    if (ev.target.matches('[data-pq]')) drawPeople();
    update();
  });
  view().addEventListener('change', ev => {
    const k = ev.target.dataset.person; if (!k) return;
    ev.target.checked ? chosenPeople.add(k) : chosenPeople.delete(k); update();
  });
  view().querySelectorAll('[data-group]').forEach(b => b.addEventListener('click', () => {
    const k = b.dataset.group; chosenGroups.has(k) ? chosenGroups.delete(k) : chosenGroups.add(k);
    b.setAttribute('aria-pressed', String(chosenGroups.has(k))); update();
  }));
  view().querySelectorAll('[data-when]').forEach(b => b.addEventListener('click', () => {
    mode = b.dataset.when;
    view().querySelectorAll('[data-when]').forEach(x => x.setAttribute('aria-pressed', String(x === b)));
    $('[data-once]').hidden = mode !== 'once'; $('[data-weekly]').hidden = mode !== 'weekly';
  }));
  view().querySelectorAll('[data-day]').forEach(b => b.addEventListener('click', () => {
    const i = Number(b.dataset.day); days.has(i) ? days.delete(i) : days.add(i); b.setAttribute('aria-pressed', String(days.has(i)));
  }));
  drawPeople(); update();

  $('[data-save]')?.addEventListener('click', async ev => {
    const name = $('#cname').value.trim(), template = $('#body').value.trim();
    if (!name) return toast('Give the campaign a name.');
    if (!template) return toast('Write a message first.');
    if (!recipients().length) return toast('Pick at least one group or person with a number.');
    let schedule = null;
    if (mode === 'once') {
      const v = $('#at').value; if (!v) return toast('Pick a date and time.');
      const t = new Date(v); if (t.getTime() < Date.now() - 60000) return toast('Pick a time in the future, or choose Send now.');
      schedule = { kind: 'once', at: t.toISOString() };
    } else if (mode === 'weekly') {
      if (!days.size) return toast('Pick at least one day.');
      const [hh, mm] = ($('#time').value || '09:00').split(':').map(Number);
      schedule = { kind: 'weekly', weekdays: [...days].reduce((bits, i) => bits | (1 << i), 0), minute_of_day: hh * 60 + mm, ends_on: $('#ends').value || null };
    }
    if (mode === 'now' && !confirm(`Send this to ${recipients().length} people from your phone now?`)) return;
    const vars = ($('[data-fallbacks]').dataset.vars || '').split(',').filter(Boolean);
    const data = {
      name, template, channel: 'sms',
      audience: { groups: [...chosenGroups].sort(), contacts: [...chosenPeople].sort() },
      fallbacks: Object.fromEntries(vars.map(v => [v, (fallbacks[v] || '').trim()]).filter(([, x]) => x)),
      schedule, enabled: $('#enabled') ? $('#enabled').checked : true, updated_at: new Date().toISOString(),
    };
    ev.target.disabled = true;
    const k = key || crypto.randomUUID();
    try {
      await records.push([{ kind: 'campaign_plan', key: k, data }]);
      toast(mode === 'now' ? 'Saved. Your phone sends it as soon as it gets it.' : 'Saved. Your phone has it within seconds.');
      go(`/app/campaigns/${k}`, true);
    } catch (e) { ev.target.disabled = false; toast(e.message); }
  });
  $('[data-delete]')?.addEventListener('click', async () => {
    if (!confirm(locked ? 'Remove this campaign from the list? What was sent stays sent.' : 'Delete this campaign? Your phone won’t send it.')) return;
    try { await records.push([{ kind: 'campaign_plan', key, deleted: true }]); toast('Deleted.'); go('/app/campaigns'); }
    catch (e) { toast(e.message); }
  });
}

// ---------- people and groups ----------
async function viewPeople() {
  const all = () => records.list('contact').sort((a, b) => String(a.data.name).localeCompare(String(b.data.name)));
  const groups = records.list('group').sort((a, b) => String(a.data.name).localeCompare(String(b.data.name)));
  render(html`<div class="row"><h1 class="grow">People <span class="muted small">${all().length}</span></h1>
      <a class="btn secondary" href="/app/people/import" data-link>⇪ Import</a>
      <a class="btn" href="/app/people/new" data-link>＋ Add person</a></div>
    <p class="muted">Synced with Messages++ on your phone. Changes here reach your phone within seconds.</p>
    <h2>Groups <span class="muted small">${groups.length}</span></h2>
    <div class="chips">${groups.map(g => html`<a class="chip" href="/app/groups/${encodeURIComponent(g.key)}" data-link>👥 ${g.data.name} · ${(g.data.members || []).length}</a>`)}
      <a class="chip" aria-pressed="false" href="/app/groups/new" data-link>＋ New group</a></div>
    <h2>Contacts</h2>
    <input type="search" placeholder="Search names, numbers and emails" data-q aria-label="Search">
    <div class="card"><ul class="list" data-list></ul></div><p><button class="btn secondary" data-more hidden>↓ Show more</button></p>`);
  let shown = 100;
  const draw = () => {
    const q = $('[data-q]').value.toLowerCase();
    const list = all().filter(c => !q || `${c.data.name} ${c.data.phone} ${c.data.email || ''}`.toLowerCase().includes(q));
    $('[data-list]').innerHTML = list.slice(0, shown).map(c => html`<li><a class="item" href="/app/people/${encodeURIComponent(c.key)}" data-link><span class="avatar">${initials(c.data.name)}</span>
      <span class="grow"><strong class="ellipsis">${c.data.name}</strong><br><span class="small muted">${c.data.phone || c.data.email || ''}${c.data.consent === 'opted_out' ? ' · opted out' : ''}${c.data.source === 'phone' ? ' · from phone contacts' : ''}</span></span>
      <span aria-hidden="true">›</span></a></li>`.s).join('')
      || html`<li class="muted">${records.list('contact').length ? 'No one matches.' : 'No one yet. Add people, import a CSV or vCard file, or turn on Backup and sync in Messages++ on your phone.'}</li>`.s;
    $('[data-more]').hidden = list.length <= shown;
  };
  $('[data-q]').addEventListener('input', () => { shown = 100; draw(); });
  $('[data-more]').addEventListener('click', () => { shown += 100; draw(); });
  draw();
}

async function viewPerson(key) {
  const isNew = key === 'new';
  const c = isNew ? null : records.get('contact', key);
  if (!isNew && !c) { render(html`<p><a href="/app/people" data-link>‹ People</a></p><div class="banner">This person was deleted.</div>`); return; }
  const d = c?.data || { name: '', phone: '', email: '', organization: '', birthday: '', consent: 'unknown', source: 'app' };
  const fromPhone = d.source === 'phone';
  const groups = records.list('group').sort((a, b) => String(a.data.name).localeCompare(String(b.data.name)));
  const inGroups = new Set(groups.filter(g => (g.data.members || []).includes(key)).map(g => g.key));
  render(html`<p><a href="/app/people" data-link>‹ People</a></p>
    <h1>${isNew ? 'Add person' : d.name}</h1>
    ${fromPhone ? html`<p class="small muted">From your phone's contacts: the name and number are edited there.</p>` : ''}
    <div class="card">
      <label for="pname">Name</label><input id="pname" value="${d.name}" ${fromPhone ? 'readonly' : ''} autocomplete="off">
      <label for="pphone">Mobile number</label><input id="pphone" value="${d.phone || ''}" ${fromPhone ? 'readonly' : ''} placeholder="${defaultCountryCode()} 803 000 0000" inputmode="tel">
      <div class="row"><div class="grow"><label for="pemail">Email</label><input id="pemail" type="email" value="${d.email || ''}"></div>
        <div class="grow"><label for="porg">Company</label><input id="porg" value="${d.organization || ''}"></div></div>
      <div class="row"><div class="grow"><label for="pbday">Birthday</label><input id="pbday" type="date" value="${/^\d{4}-\d{2}-\d{2}$/.test(d.birthday || '') ? d.birthday : ''}"></div>
        <div class="grow"><label for="pconsent">Texts</label><select id="pconsent">
          ${[['unknown', 'Can get texts'], ['opted_in', 'Agreed to get texts'], ['opted_out', 'Opted out: never text']].map(([v, l]) => html`<option value="${v}" ${d.consent === v ? 'selected' : ''}>${l}</option>`)}
        </select></div></div>
      ${groups.length ? html`<label>Groups</label><div class="chips">${groups.map(g => html`<button type="button" class="chip" data-g="${g.key}" aria-pressed="${inGroups.has(g.key)}">👥 ${g.data.name}</button>`)}</div>` : ''}
    </div>
    <div class="row"><button class="btn" data-save>✓ Save</button>
      ${isNew || !d.phone ? '' : html`<a class="btn secondary" href="/app/send?to=${encodeURIComponent(d.phone)}" data-link>✉ Text</a>`}
      ${isNew || fromPhone ? '' : html`<button class="btn danger" data-del>✕ Delete</button>`}</div>`);
  view().querySelectorAll('[data-g]').forEach(b => b.addEventListener('click', () => {
    const g = b.dataset.g; inGroups.has(g) ? inGroups.delete(g) : inGroups.add(g); b.setAttribute('aria-pressed', String(inGroups.has(g)));
  }));
  $('[data-save]').addEventListener('click', async ev => {
    const name = $('#pname').value.trim(), phone = fromPhone ? d.phone : toE164($('#pphone').value);
    const email = $('#pemail').value.trim();
    if (!name) return toast('Add a name.');
    if (!phone && !email) return toast($('#pphone').value.trim() ? 'That number doesn’t look right. Include the country code.' : 'Add a number or an email.');
    const k = isNew ? crypto.randomUUID() : key;
    const data = { ...d, name, phone, email: email || null, organization: $('#porg').value.trim() || null, birthday: $('#pbday').value || null, consent: $('#pconsent').value };
    const changes = [{ kind: 'contact', key: k, data }];
    for (const g of groups) {
      const members = new Set(g.data.members || []), had = members.has(k), wants = inGroups.has(g.key);
      if (had === wants) continue;
      wants ? members.add(k) : members.delete(k);
      changes.push({ kind: 'group', key: g.key, data: { ...g.data, members: [...members].sort() } });
    }
    ev.target.disabled = true;
    try { await records.push(changes); toast('Saved.'); go('/app/people'); }
    catch (e) { ev.target.disabled = false; toast(e.message); }
  });
  $('[data-del]')?.addEventListener('click', async () => {
    if (!confirm(`Delete ${d.name}? They're removed from your groups and from your phone too.`)) return;
    const changes = [{ kind: 'contact', key, deleted: true }];
    for (const g of groups) if ((g.data.members || []).includes(key)) changes.push({ kind: 'group', key: g.key, data: { ...g.data, members: g.data.members.filter(m => m !== key) } });
    try { await records.push(changes); toast('Deleted.'); go('/app/people'); } catch (e) { toast(e.message); }
  });
}

async function viewGroup(key) {
  const isNew = key === 'new';
  const g = isNew ? null : records.get('group', key);
  if (!isNew && !g) { render(html`<p><a href="/app/people" data-link>‹ People</a></p><div class="banner">This group was deleted.</div>`); return; }
  const members = new Set(g?.data?.members || []);
  const people = records.list('contact').sort((a, b) => String(a.data.name).localeCompare(String(b.data.name)));
  render(html`<p><a href="/app/people" data-link>‹ People</a></p>
    <h1>${isNew ? 'New group' : g.data.name}</h1>
    <div class="card"><label for="gname">Name</label><input id="gname" value="${g?.data?.name || ''}" placeholder="Choir">
      <label>Members <span class="muted small" data-n></span></label>
      <input type="search" placeholder="Search people" data-q aria-label="Search people">
      <ul class="list" data-list style="max-height:420px;overflow:auto"></ul></div>
    <div class="row"><button class="btn" data-save>✓ Save</button>
      ${isNew ? '' : html`<a class="btn secondary" href="/app/campaigns/new?group=${encodeURIComponent(key)}" data-link>✉ New campaign to this group</a><button class="btn danger" data-del>✕ Delete group</button>`}</div>`);
  const draw = () => {
    const q = $('[data-q]').value.toLowerCase();
    $('[data-n]').textContent = `· ${members.size}`;
    // Members first, then everyone else.
    const list = people.filter(c => !q || `${c.data.name} ${c.data.phone}`.toLowerCase().includes(q))
      .sort((a, b) => Number(members.has(b.key)) - Number(members.has(a.key))).slice(0, 400);
    $('[data-list]').innerHTML = list.map(c => html`<li><label class="check" style="margin:0;width:100%"><input type="checkbox" data-m="${c.key}" ${members.has(c.key) ? 'checked' : ''}>
      <span class="grow"><strong>${c.data.name}</strong> <span class="small muted">${c.data.phone || c.data.email || ''}</span></span></label></li>`.s).join('')
      || html`<li class="muted small">No one matches.</li>`.s;
  };
  $('[data-q]').addEventListener('input', draw);
  $('[data-list]').addEventListener('change', ev => { const k = ev.target.dataset.m; if (!k) return; ev.target.checked ? members.add(k) : members.delete(k); $('[data-n]').textContent = `· ${members.size}`; });
  $('[data-save]').addEventListener('click', async ev => {
    const name = $('#gname').value.trim(); if (!name) return toast('Give the group a name.');
    ev.target.disabled = true;
    const k = isNew ? crypto.randomUUID() : key;
    try { await records.push([{ kind: 'group', key: k, data: { ...(g?.data || {}), name, members: [...members].sort() } }]); toast('Saved.'); go('/app/people'); }
    catch (e) { ev.target.disabled = false; toast(e.message); }
  });
  $('[data-del]')?.addEventListener('click', async () => {
    if (!confirm(`Delete the group ${g.data.name}? The people in it stay.`)) return;
    try { await records.push([{ kind: 'group', key, deleted: true }]); toast('Deleted.'); go('/app/people'); } catch (e) { toast(e.message); }
  });
  draw();
}

// ---------- import (CSV, vCard) ----------
/** RFC 4180-ish CSV: quotes, escaped quotes, commas/semicolons/tabs, CRLF. */
function parseCSV(text) {
  const firstLine = text.split(/\r?\n/, 1)[0] || '';
  const sep = [',', ';', '\t'].map(c => [c, firstLine.split(c).length]).sort((a, b) => b[1] - a[1])[0][0];
  const rows = []; let row = [], cell = '', quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { cell += '"'; i++; } else if (ch === '"') quoted = false; else cell += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === sep) { row.push(cell); cell = ''; }
    else if (ch === '\n' || ch === '\r') { if (ch === '\r' && text[i + 1] === '\n') i++; row.push(cell); rows.push(row); row = []; cell = ''; }
    else cell += ch;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  return rows.filter(r => r.some(c => c.trim()));
}
/** vCard 2.1–4.0: one row per card with name, first number, email, company, birthday. */
function parseVCF(text) {
  const unfolded = text.replace(/\r?\n[ \t]/g, '');
  const out = [];
  for (const card of unfolded.split(/BEGIN:VCARD/i).slice(1)) {
    const get = re => (card.match(re)?.[1] || '').trim();
    const n = get(/^N(?:;[^:\n]*)?:([^\r\n]*)/im).split(';');
    const name = get(/^FN[^:\n]*:([^\r\n]*)/im) || [n[1], n[0]].filter(Boolean).join(' ');
    const tels = [...card.matchAll(/^TEL[^:\n]*:([^\r\n]*)/gim)];
    const mobile = tels.find(t => /CELL|MOBILE/i.test(t[0])) || tels[0];
    const bday = get(/^BDAY[^:\n]*:([^\r\n]*)/im).replace(/^(\d{4})(\d{2})(\d{2})$/, '$1-$2-$3');
    out.push([name.replace(/\\,/g, ','), mobile?.[1] || '', get(/^EMAIL[^:\n]*:([^\r\n]*)/im), get(/^ORG[^:\n]*:([^\r\n;]*)/im).replace(/\\,/g, ','), bday]);
  }
  return out;
}
const FIELDS = [['name', 'Full name'], ['first', 'First name'], ['last', 'Last name'], ['phone', 'Mobile number'], ['email', 'Email'], ['organization', 'Company'], ['birthday', 'Birthday'], ['', 'Skip']];
const guessField = header => {
  const h = header.toLowerCase();
  if (/first|given/.test(h)) return 'first';
  if (/last|surname|family/.test(h)) return 'last';
  if (/mobile|cell|phone|number|tel|whatsapp/.test(h)) return 'phone';
  if (/mail/.test(h)) return 'email';
  if (/company|org|business|employer/.test(h)) return 'organization';
  if (/birth|bday|dob/.test(h)) return 'birthday';
  if (/name/.test(h)) return 'name';
  return '';
};

async function viewImport() {
  const groups = records.list('group').sort((a, b) => String(a.data.name).localeCompare(String(b.data.name)));
  render(html`<p><a href="/app/people" data-link>‹ People</a></p>
    <h1>Import people</h1>
    <p class="muted">A CSV from a spreadsheet (Excel, Google Sheets, Numbers) or a vCard (.vcf) exported from Google, iCloud or Outlook contacts. Everyone arrives on your phone within seconds.</p>
    <div class="card">
      <label for="file">File</label><input id="file" type="file" accept=".csv,.txt,.tsv,.vcf,text/csv,text/vcard">
      <div class="row"><div class="grow"><label for="cc">Country code for numbers without one</label><input id="cc" value="${defaultCountryCode()}" maxlength="5"></div>
        <div class="grow"><label for="group">Add everyone to a group <span class="muted small">(optional)</span></label>
          <select id="group"><option value="">No group</option><option value="__new">＋ New group…</option>${groups.map(g => html`<option value="${g.key}">${g.data.name}</option>`)}</select></div></div>
    </div>
    <div data-map></div>`);
  let rows = [], headers = [], mapping = [];
  const people = () => {
    const cc = $('#cc').value.trim() || '+234';
    const seen = new Set(), out = [], skipped = { noNumber: 0, duplicate: 0 };
    const existing = new Map(records.list('contact').filter(c => c.data.phone).map(c => [c.data.phone, c]));
    for (const r of rows) {
      const v = f => mapping.map((m, i) => (m === f ? (r[i] || '').trim() : '')).filter(Boolean).join(' ');
      const name = v('name') || [v('first'), v('last')].filter(Boolean).join(' ');
      const phone = toE164(v('phone'), cc), email = v('email');
      if (!phone && !email) { skipped.noNumber++; continue; }
      const id = phone || email.toLowerCase();
      if (seen.has(id)) { skipped.duplicate++; continue; }
      seen.add(id);
      out.push({ name: name || phone || email, phone, email: email || null, organization: v('organization') || null, birthday: /^\d{4}-\d{2}-\d{2}$/.test(v('birthday')) ? v('birthday') : null, match: phone ? existing.get(phone) : null });
    }
    return { out, skipped };
  };
  const drawMap = () => {
    const { out, skipped } = people();
    const fresh = out.filter(p => !p.match).length, updates = out.length - fresh;
    $('[data-map]').innerHTML = html`<div class="card"><h2 style="margin-top:0">Match the columns</h2>
      <div class="row">${headers.map((h, i) => html`<div class="grow" style="flex-basis:160px"><label for="col-${i}" class="ellipsis">${h || `Column ${i + 1}`}</label>
        <select id="col-${i}" data-col="${i}">${FIELDS.map(([v, l]) => html`<option value="${v}" ${mapping[i] === v ? 'selected' : ''}>${l}</option>`)}</select></div>`)}</div>
      <p class="small muted" style="margin-top:12px">${fresh} new · ${updates} already here (their details are updated) · ${skipped.noNumber} without a number or email · ${skipped.duplicate} repeated</p>
      <ul class="list">${out.slice(0, 5).map(p => html`<li><span class="avatar">${initials(p.name)}</span><span class="grow"><strong>${p.name}</strong><br><span class="small muted">${p.phone || p.email}${p.match ? ' · already here' : ''}</span></span></li>`)}</ul>
      ${out.length > 5 ? html`<p class="small muted">and ${out.length - 5} more</p>` : ''}</div>
      <div class="row"><button class="btn" data-go ${out.length ? '' : 'disabled'}>⇪ Import ${out.length}</button><span class="muted small" data-progress role="status"></span></div>`.s;
    $('[data-go]').addEventListener('click', run);
  };
  const run = async ev => {
    const { out } = people();
    let groupKey = $('#group').value, groupData = null;
    if (groupKey === '__new') {
      const name = prompt('Name for the new group'); if (!name) return;
      groupKey = crypto.randomUUID(); groupData = { name, members: [] };
    } else if (groupKey) groupData = { ...records.get('group', groupKey).data };
    ev.target.disabled = true;
    store.set('mpw_cc', $('#cc').value.trim());
    const all = out.map(p => {
      const key = p.match?.key || crypto.randomUUID();
      const before = p.match?.data || { consent: 'unknown', source: 'app' };
      return { kind: 'contact', key, data: { ...before, name: before.source === 'phone' ? before.name : p.name, phone: p.phone || before.phone || '', email: p.email || before.email || null,
        organization: p.organization || before.organization || null, birthday: p.birthday || before.birthday || null } };
    });
    const size = 400, steps = Math.ceil(all.length / size) + (groupData ? 1 : 0);
    try {
      for (let i = 0; i < all.length; i += size) {
        $('[data-progress]').textContent = `${i / size + 1}/${steps} · Saving ${Math.min(i + size, all.length)} of ${all.length}`;
        await records.push(all.slice(i, i + size));
      }
      if (groupData) {
        $('[data-progress]').textContent = `${steps}/${steps} · Adding them to ${groupData.name}`;
        const members = new Set(groupData.members || []); all.forEach(r => members.add(r.key));
        await records.push([{ kind: 'group', key: groupKey, data: { ...groupData, members: [...members].sort() } }]);
      }
      toast(`Imported ${all.length}. They’re on your phone within seconds.`);
      go(groupData ? `/app/groups/${groupKey}` : '/app/people');
    } catch (e) { ev.target.disabled = false; $('[data-progress]').textContent = ''; toast(e.message); }
  };
  $('[data-map]').addEventListener('change', ev => { const i = ev.target.dataset.col; if (i === undefined) return; mapping[Number(i)] = ev.target.value; drawMap(); });
  $('#cc').addEventListener('input', () => { if (rows.length) drawMap(); });
  $('#file').addEventListener('change', async ev => {
    const file = ev.target.files[0]; if (!file) return;
    if (file.size > 10 * 1024 * 1024) return toast('That file is over 10 MB. Split it and import the parts.');
    const text = (await file.text()).replace(/^﻿/, '');
    if (/\.vcf$/i.test(file.name) || /^BEGIN:VCARD/i.test(text.trim())) {
      headers = ['Name', 'Mobile number', 'Email', 'Company', 'Birthday']; rows = parseVCF(text); mapping = ['name', 'phone', 'email', 'organization', 'birthday'];
    } else {
      const all = parseCSV(text);
      const looksLikeHeader = all[0] && all[0].some(c => /name|phone|mobile|email|number/i.test(c));
      headers = looksLikeHeader ? all[0] : all[0].map((_, i) => `Column ${i + 1}`);
      rows = looksLikeHeader ? all.slice(1) : all;
      mapping = headers.map(guessField);
      if (!mapping.includes('phone')) {
        const i = headers.findIndex((_, i) => rows.slice(0, 20).filter(r => /^\+?[\d\s()-]{7,}$/.test((r[i] || '').trim())).length > 10);
        if (i >= 0) mapping[i] = 'phone';
      }
      if (!mapping.some(m => ['name', 'first'].includes(m))) { const i = mapping.findIndex(m => !m); if (i >= 0) mapping[i] = 'name'; }
    }
    if (!rows.length) return toast('No people found in that file.');
    drawMap();
  });
}

// ---------- Contacts++ chats ----------
const chatScopeMissing = e => e instanceof ApiError && (e.status === 403 || e.status === 401);
const chatSignInAgain = () => html`<div class="card" style="text-align:center"><h2 style="margin-top:0">Chat here too</h2>
  <p class="muted">Sign in again to allow chats on the web. It takes a moment and you stay signed in to everything else.</p>
  <p><button class="btn" data-again>→ Continue with Contacts++</button></p></div>`;
const bindAgain = () => $('[data-again]')?.addEventListener('click', () => signIn());

async function viewChats() {
  render(html`<div class="row"><h1 class="grow">Chats</h1><button class="btn" data-new>＋ New chat</button></div>
    <p class="muted">Your Contacts++ chats, the same ones as in Messages++ on your phone and in Contacts++.</p>
    <div data-picker hidden class="card"><input type="search" placeholder="Search your people" data-pq aria-label="Search people"><ul class="list" data-pl style="max-height:360px;overflow:auto"></ul></div>
    <div class="card"><ul class="list" data-list><li class="loading">Loading…</li></ul></div>`);
  try {
    const data = await api('/conversations');
    const list = data.conversations || [];
    const unread = list.reduce((n, c) => n + (c.unread_count || 0), 0);
    const el = document.querySelector('[data-count="chats"]'); if (el) el.textContent = unread ? String(unread) : '';
    $('[data-list]').innerHTML = list.map(c => html`<li><a class="item" href="/app/chats/${c.id}?title=${encodeURIComponent(c.title || '')}" data-link><span class="avatar">${initials(c.title)}</span>
      <span class="grow"><strong class="ellipsis">${c.title || 'Conversation'}</strong><br><span class="small muted ellipsis">${c.last_message_is_mine ? 'You: ' : ''}${c.last_message || ''}</span></span>
      <span class="small muted">${when(c.last_message_at)}</span>${c.unread_count ? html` <span class="tag">${c.unread_count}</span>` : ''}</a></li>`.s).join('')
      || html`<li class="muted">No chats yet. Start one with someone in your People who is on Contacts++.</li>`.s;
  } catch (e) {
    if (chatScopeMissing(e)) { $('[data-list]').closest('.card').outerHTML = chatSignInAgain().s; bindAgain(); return; }
    $('[data-list]').innerHTML = html`<li class="muted">${e.message}</li>`.s;
  }
  // New chat: people with numbers who are on Contacts++.
  let reach = null;
  $('[data-new]').addEventListener('click', async () => {
    const box = $('[data-picker]'); box.hidden = !box.hidden; if (box.hidden) return;
    const people = records.list('contact').filter(c => c.data.phone);
    if (!reach) {
      $('[data-pl]').innerHTML = html`<li class="loading">Checking who’s on Contacts++…</li>`.s;
      reach = {};
      try {
        const numbers = [...new Set(people.map(c => c.data.phone))];
        for (let i = 0; i < numbers.length; i += 200) {
          const res = await api('/messages-plus/reachability', { method: 'POST', body: { numbers: numbers.slice(i, i + 200) } });
          for (const r of res.results || []) if (r.channel === 'chat' && r.user_id) reach[r.number] = r;
        }
      } catch (e) { if (chatScopeMissing(e)) { box.outerHTML = chatSignInAgain().s; bindAgain(); return; } toast(e.message); }
    }
    const draw = () => {
      const q = $('[data-pq]').value.toLowerCase();
      const on = people.filter(c => reach[c.data.phone] && (!q || `${c.data.name} ${c.data.phone}`.toLowerCase().includes(q)));
      $('[data-pl]').innerHTML = on.map(c => html`<li><button class="item" style="all:unset;display:flex;gap:12px;align-items:center;width:100%;cursor:pointer" data-chat="${reach[c.data.phone].user_id}" data-title="${c.data.name}">
        <span class="avatar">${initials(c.data.name)}</span><span class="grow"><strong>${c.data.name}</strong><br><span class="small muted">${c.data.phone}</span></span><span>💬</span></button></li>`.s).join('')
        || html`<li class="muted small">${people.length ? 'None of your people match, or they aren’t on Contacts++ yet.' : 'Add people first.'}</li>`.s;
    };
    $('[data-pq]').oninput = draw; draw();
  });
  $('[data-picker]').addEventListener('click', async ev => {
    const b = ev.target.closest('[data-chat]'); if (!b) return;
    try {
      const c = await api('/conversations', { method: 'POST', body: { type: 'direct', participant_ids: [b.dataset.chat] } });
      go(`/app/chats/${c.id}?title=${encodeURIComponent(b.dataset.title)}`);
    } catch (e) { toast(e.message); }
  });
}

async function viewChat(id) {
  const title = new URLSearchParams(location.search).get('title') || 'Chat';
  const mine = String(me()?.id || '');
  render(html`<p><a href="/app/chats" data-link>‹ Chats</a></p><h1>${title}</h1>
    <div class="card chat"><div class="msgs" data-msgs><p class="loading">Loading…</p></div>
    <form class="row" data-form style="margin-top:12px"><textarea class="grow" id="reply" rows="1" style="min-height:44px" placeholder="Chat message" aria-label="Message"></textarea><button class="btn">➤ Send</button></form></div>`);
  const byId = new Map(); let cursor = null, timer;
  const draw = () => {
    const box = $('[data-msgs]'); if (!box) return;
    const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
    const list = [...byId.values()].filter(m => m.type !== 'system').sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
    box.innerHTML = list.map(m => html`<div class="bubble ${String(m.sender_id) === mine ? 'mine' : ''} ${m.pending ? 'pending' : ''}">
      <div>${m.deleted_at ? 'Message deleted' : (m.body ?? `${m.type} · open in Contacts++`)}</div>
      <div class="small muted">${when(m.created_at)}${m.pending ? ' · Sending…' : m.failed ? ' · Not sent' : m.receipt_state ? ` · ${m.receipt_state}` : ''}</div></div>`.s).join('') || html`<p class="muted">Say hello.</p>`.s;
    if (atBottom || !box.dataset.ready) { box.scrollTop = box.scrollHeight; box.dataset.ready = '1'; }
  };
  const load = async () => {
    const q = cursor ? `?changed_since=${encodeURIComponent(cursor)}` : '';
    const data = await api(`/conversations/${id}/messages${q}`);
    for (const m of data.messages || []) { byId.set(String(m.id), m); if (m.client_id) byId.delete(`pending-${m.client_id}`); }
    cursor = data.sync_cursor || cursor;
    draw();
  };
  try { await load(); api(`/conversations/${id}/read`, { method: 'PUT', body: {} }).catch(() => {}); }
  catch (e) { if (chatScopeMissing(e)) { $('.chat').outerHTML = chatSignInAgain().s; bindAgain(); return; } $('[data-msgs]').textContent = e.message; return; }
  timer = setInterval(() => { if (!location.pathname.endsWith(id)) return clearInterval(timer); if (!document.hidden) load().catch(() => {}); }, 5000);
  const send = async () => {
    const body = $('#reply').value.trim(); if (!body) return;
    const clientId = crypto.randomUUID();
    byId.set(`pending-${clientId}`, { id: `pending-${clientId}`, sender_id: mine, body, created_at: new Date().toISOString(), pending: true, type: 'text' });
    $('#reply').value = ''; draw();
    try {
      const res = await api(`/conversations/${id}/messages`, { method: 'POST', body: { client_id: clientId, type: 'text', body } });
      byId.delete(`pending-${clientId}`); byId.set(String(res.message.id), res.message); draw();
    } catch (e) { const p = byId.get(`pending-${clientId}`); if (p) { p.pending = false; p.failed = true; draw(); } toast(e.message); }
  };
  $('[data-form]').addEventListener('submit', ev => { ev.preventDefault(); send(); });
  $('#reply').addEventListener('keydown', ev => { if (ev.key === 'Enter' && !ev.shiftKey) { ev.preventDefault(); send(); } });
}

// ---------- router ----------
const routes = [
  [/^\/app\/?$/, () => go('/app/campaigns', true)],
  [/^\/app\/campaigns$/, () => viewCampaigns(), 'campaigns'],
  [/^\/app\/campaigns\/new$/, (m, q) => viewCampaign(null, q), 'campaigns'],
  [/^\/app\/campaigns\/([\w-]{1,80})$/, (m, q) => viewCampaign(m[1], q), 'campaigns'],
  [/^\/app\/chats$/, () => viewChats(), 'chats'],
  [/^\/app\/chats\/([\w-]{1,80})$/, m => viewChat(m[1]), 'chats'],
  [/^\/app\/people\/import$/, () => viewImport(), 'people'],
  [/^\/app\/people\/([\w-]{1,80})$/, m => viewPerson(m[1]), 'people'],
  [/^\/app\/groups\/([\w-]{1,80})$/, m => viewGroup(m[1]), 'people'],
  [/^\/app\/send$/, (m, q) => viewSend(q), 'campaigns'],
  [/^\/app\/sends$/, () => viewSends(), 'sends'],
  [/^\/app\/sends\/([0-9a-f-]{36})$/, m => viewSend1(m[1]), 'sends'],
  [/^\/app\/people$/, () => viewPeople(), 'people'],
  [/^\/app\/backup$/, () => viewBackup(), 'backup'],
  [/^\/app\/developers$/, () => viewDevelopers(), 'developers'],
];
function go(path, replace = false) {
  replace ? history.replaceState(null, '', path) : history.pushState(null, '', path);
  route();
}
async function route() {
  const signedIn = session.signedIn;
  document.querySelector('.tabs').hidden = !signedIn;
  document.querySelector('[data-signout]').hidden = !signedIn;
  if (!signedIn) return autoSignIn();
  const path = location.pathname.replace(/\/+$/, '') || '/app';
  for (const [re, fn, tab] of routes) {
    const m = path.match(re);
    if (!m) continue;
    document.querySelectorAll('[data-tab]').forEach(a => { if (a.dataset.tab === tab) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current'); });
    view().focus({ preventScroll: true });
    window.scrollTo(0, 0);
    try { await fn(m, new URLSearchParams(location.search)); } catch (e) { render(html`<div class="banner">${e.message}</div>`); }
    return;
  }
  render(html`<h1>Not found</h1><p><a href="/app/campaigns" data-link>Go to Campaigns</a></p>`);
}

document.addEventListener('click', ev => {
  const a = ev.target.closest('a[data-link]');
  if (!a || ev.metaKey || ev.ctrlKey || ev.shiftKey) return;
  ev.preventDefault();
  go(a.getAttribute('href'));
});
window.addEventListener('popstate', route);
document.querySelector('[data-signout]').addEventListener('click', () => { if (confirm('Sign out of Messages++ on this browser?')) signOut(); });

(async function start() {
  if (location.pathname.startsWith('/app/callback')) {
    await finishSignIn(new URLSearchParams(location.search));
  }
  counts();
  await route();
  if (session.signedIn) {
    // Fetch only what changed since last time, then redraw lists that use it.
    const redraw = () => {
      // Only pages that just show records; never a form someone is typing in.
      const untouched = !$('#body')?.value && !$('#to')?.value;
      if (/\/app\/(people|backup|campaigns)$/.test(location.pathname) || (/\/app\/send$/.test(location.pathname) && untouched)) route();
    };
    records.refresh().then(redraw).catch(e => toast(e.message));
    // Campaign status from the phone, and changes made on the phone, keep arriving.
    setInterval(() => {
      if (document.hidden || !session.signedIn) return;
      const before = records.cursor;
      records.refresh().then(() => { if (records.cursor !== before && /\/app\/campaigns$/.test(location.pathname)) route(); }).catch(() => {});
    }, 20000);
  }
})();
