'use strict';
// Captación de Clientes — interfaz (sin dependencias). Rutas por hash: #/, #/buscar, #/busqueda/:id, #/empresa/:id, #/leads...

const NF = 'No encontrado';
const state = { me: null, meta: null, config: {}, pollTimer: null, lists: {} };
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
const view = () => $('#view');

function esc(v) {
  return String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function val(v) { return v === null || v === undefined || String(v).trim() === '' ? `<span class="nf">${NF}</span>` : esc(v); }
function fmtDate(iso) {
  if (!iso) return '';
  const d = new Date(iso.length === 10 ? iso + 'T00:00:00' : iso);
  return isNaN(d) ? esc(iso) : d.toLocaleDateString('es-ES', { day: '2-digit', month: 'short', year: 'numeric' }) + (iso.length > 10 ? ' ' + d.toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit' }) : '');
}
function tierClass(t) { return 'tier-' + String(t || 'Baja').split(' ')[0]; }
function scoreBadge(c) { return c.score == null ? `<span class="nf">—</span>` : `<span class="score ${tierClass(c.score_tier)}" title="${esc(c.score_tier)}">${c.score}</span>`; }
function link(url, text) {
  if (!url) return `<span class="nf">${NF}</span>`;
  const href = /^https?:\/\//i.test(url) ? url : (url.startsWith('@') || !url.includes('.') ? null : 'https://' + url);
  return href ? `<a href="${esc(href)}" target="_blank" rel="noopener noreferrer"><span class="cut">${esc(text || url.replace(/^https?:\/\/(www\.)?/i, ''))}</span></a>` : esc(url);
}
function igLink(v) {
  if (!v) return `<span class="nf">${NF}</span>`;
  const handle = v.replace(/^https?:\/\/(www\.)?instagram\.com\//i, '').replace(/[/?#].*$/, '').replace(/^@/, '');
  return `<a href="https://www.instagram.com/${esc(handle)}/" target="_blank" rel="noopener noreferrer">@${esc(handle)}</a>`;
}

function toast(msg, isError = false) {
  const t = $('#toast');
  t.textContent = msg;
  t.className = 'toast' + (isError ? ' error' : '');
  clearTimeout(toast._t);
  toast._t = setTimeout(() => t.classList.add('hidden'), isError ? 6000 : 3000);
}

async function api(path, opts = {}) {
  const init = { method: opts.method || 'GET', headers: { 'X-Requested-With': 'fetch' }, credentials: 'same-origin' };
  if (opts.body !== undefined) { init.headers['Content-Type'] = 'application/json'; init.body = JSON.stringify(opts.body); }
  let res;
  try { res = await fetch(path, init); } catch (e) { throw new Error('No se puede conectar con la aplicación. ¿Sigue abierta la ventana de Terminal?'); }
  const data = await res.json().catch(() => ({}));
  if (res.status === 401 && !path.startsWith('/api/login')) { showAuth(false); throw new Error(data.error || 'Sesión caducada'); }
  if (!res.ok) throw new Error(data.error || `Error ${res.status}`);
  return data;
}

// ---------- Tema ----------
function applyTheme(t) { document.documentElement.setAttribute('data-theme', t); try { localStorage.setItem('cc-theme', t); } catch (e) {} }
function initTheme() {
  let t = null;
  try { t = localStorage.getItem('cc-theme'); } catch (e) {}
  if (!t) t = window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  applyTheme(t);
}

// ---------- Autenticación ----------
function showAuth(setup, me = {}) {
  const needCode = setup && me.setup_code_required;
  const minPw = me.min_password || 8;
  $('#shell').classList.add('hidden');
  const a = $('#auth');
  a.classList.remove('hidden');
  a.innerHTML = `
    <form class="card" id="authForm">
      <h1>◎ Captación de clientes</h1>
      <p class="muted">${setup ? (needCode ? 'Primera vez: crea tu cuenta. Necesitas el código de instalación (SETUP_CODE) que aparece en Render → Environment.' : 'Primera vez: crea tu usuario y contraseña. Se guardan cifrados solo en este ordenador.') : 'Inicia sesión para continuar.'}</p>
      ${needCode ? '<div class="field"><label>Código de instalación</label><input name="setup_code" type="password" autocomplete="off" required></div>' : ''}
      <div class="field"><label>Usuario</label><input name="username" autocomplete="username" required minlength="3"></div>
      <div class="field"><label>Contraseña ${setup ? `<span class="hint">(mínimo ${minPw} caracteres)</span>` : ''}</label><input name="password" type="password" autocomplete="${setup ? 'new-password' : 'current-password'}" required minlength="${setup ? minPw : 1}"></div>
      <button class="btn primary" style="width:100%;justify-content:center">${setup ? 'Crear cuenta y entrar' : 'Entrar'}</button>
    </form>`;
  $('#authForm').addEventListener('submit', async e => {
    e.preventDefault();
    const f = new FormData(e.target);
    try {
      await api(setup ? '/api/setup' : '/api/login', { method: 'POST', body: { username: f.get('username'), password: f.get('password'), setup_code: f.get('setup_code') } });
      boot();
    } catch (err) { toast(err.message, true); }
  });
}

async function boot() {
  initTheme();
  const me = await api('/api/me');
  state.config = me.config;
  if (!me.user) return showAuth(me.setup_needed, me);
  state.me = me.user;
  state.meta = await api('/api/meta');
  $('#auth').classList.add('hidden');
  $('#shell').classList.remove('hidden');
  $('#userName').textContent = me.user.username;
  router();
}

// ---------- Router ----------
const routes = [
  [/^#?\/?$/, 'panel', renderPanel],
  [/^#\/buscar$/, 'buscar', renderSearchForm],
  [/^#\/busqueda\/(\d+)$/, 'historial', renderSearchResults],
  [/^#\/empresa\/(\d+)$/, null, renderCompany],
  [/^#\/leads$/, 'leads', renderLeads],
  [/^#\/historial$/, 'historial', renderHistory],
  [/^#\/estadisticas$/, 'estadisticas', renderStats],
  [/^#\/ajustes$/, 'ajustes', renderSettings]
];
function router() {
  if (!state.me) return;
  clearTimeout(state.pollTimer);
  $('#sidebar').classList.remove('open');
  const h = location.hash || '#/';
  for (const [rx, nav, fn] of routes) {
    const m = h.match(rx);
    if (m) {
      $$('.sidebar nav a').forEach(a => a.classList.toggle('active', a.dataset.nav === nav));
      view().innerHTML = '<p class="muted">Cargando…</p>';
      window.scrollTo(0, 0);
      Promise.resolve(fn(m[1])).catch(err => { view().innerHTML = `<div class="notice bad">${esc(err.message)}</div>`; });
      return;
    }
  }
  location.hash = '#/';
}
function setTitle(t) { $('#topTitle').textContent = t; document.title = t + ' · Captación de Clientes'; }

// ---------- Panel ----------
function configNotices() {
  const out = [];
  if (!state.config.google) out.push(`<div class="notice small">ℹ️ Buscando con <b>OpenStreetMap</b> (gratis). Para obtener más negocios y teléfonos, puedes añadir una clave de <b>Google Places</b>: mira <a href="#/ajustes">Ajustes</a>.</div>`);
  if (!state.config.ai) out.push(`<div class="notice small warn">✍️ El asistente de IA no está activado. Añade tu clave de Anthropic en el archivo <code>.env</code> (instrucciones en <a href="#/ajustes">Ajustes</a>).</div>`);
  return out.join('');
}

async function renderPanel() {
  setTitle('Panel');
  const [s, searches] = await Promise.all([api('/api/stats'), api('/api/searches')]);
  view().innerHTML = `
    <div class="card">
      <h1>¿Qué clientes buscas hoy?</h1>
      <p class="muted">Escribe el tipo de negocio y la zona. Ejemplo: <i>clínicas dentales en Barcelona</i>, <i>peluquerías en Gràcia, Barcelona</i>, <i>gimnasios en Valencia</i>.</p>
      <form class="hero-search" id="quickForm">
        <input id="quickInput" placeholder="clínicas dentales en Barcelona" autocomplete="off" required>
        <button class="btn primary">Buscar</button>
      </form>
      <p class="small" style="margin:.6rem 0 0"><a href="#/buscar">Búsqueda avanzada con filtros y cliente ideal →</a></p>
    </div>
    ${configNotices()}
    <div class="grid g4" style="margin-bottom:16px">
      <div class="kpi"><b>${s.saved}</b><span>Leads guardados</span></div>
      <div class="kpi"><b>${s.avg_score ?? '—'}</b><span>Puntuación media</span></div>
      <div class="kpi"><b>${s.meetings}</b><span>Reuniones concertadas</span></div>
      <div class="kpi"><b>${s.won}</b><span>Clientes conseguidos</span></div>
    </div>
    <div class="grid g2">
      <div class="card">
        <h2>Próximas acciones (7 días)</h2>
        ${s.due.length ? `<ul class="timeline">${s.due.map(d => `<li><b>${fmtDate(d.next_action_date)}</b> · <a href="#/empresa/${d.id}">${esc(d.name)}</a><br><span class="muted">${esc(d.next_action || 'Sin descripción')} · ${esc(d.status)}</span></li>`).join('')}</ul>` : '<p class="muted">No hay acciones pendientes. Añádelas desde la ficha de cada empresa.</p>'}
      </div>
      <div class="card">
        <h2>Búsquedas recientes</h2>
        ${searches.length ? `<ul class="timeline">${searches.slice(0, 6).map(x => `<li><a href="#/busqueda/${x.id}">${esc(x.raw_text)}</a> <span class="badge">${x.status === 'completada' ? x.total_found + ' empresas' : esc(x.status)}</span><br><span class="muted small">${fmtDate(x.created_at)}</span></li>`).join('')}</ul>` : '<p class="muted">Aún no has hecho ninguna búsqueda.</p>'}
      </div>
    </div>`;
  $('#quickForm').addEventListener('submit', async e => {
    e.preventDefault();
    const text = $('#quickInput').value.trim();
    if (!/\s(en|de)\s/i.test(text)) { toast('Escribe el negocio y la zona, por ejemplo: «clínicas dentales en Barcelona»', true); return; }
    startSearch({ raw_text: text, limit: 25 });
  });
}

async function startSearch(body, btn) {
  if (btn) btn.disabled = true;
  try {
    const r = await api('/api/search', { method: 'POST', body });
    location.hash = '#/busqueda/' + r.id;
  } catch (err) { toast(err.message, true); if (btn) btn.disabled = false; }
}

// ---------- Búsqueda avanzada ----------
function renderSearchForm() {
  setTitle('Nueva búsqueda');
  let last = {};
  try { last = JSON.parse(localStorage.getItem('cc-last-search') || '{}'); } catch (e) {}
  const v = k => esc(last[k] || '');
  view().innerHTML = `
    <form id="searchForm">
      <div class="card">
        <h2>1. Qué vendes y a quién</h2>
        <div class="grid g2">
          <div class="field"><label>¿Qué vendes? <span class="hint">Se usa para detectar oportunidades y puntuar</span></label><input name="offer" value="${v('offer')}" placeholder="Ej.: diseño web y SEO local para pequeños negocios"></div>
          <div class="field"><label>Tipo de cliente</label><input name="customer_type" value="${v('customer_type')}" placeholder="Ej.: clínicas privadas, negocios con local a pie de calle"></div>
        </div>
        <div class="field"><label>Rasgos del cliente ideal <span class="hint">(palabras clave que suman puntos si aparecen en su web o ficha)</span></label><textarea name="ideal" rows="2" placeholder="Ej.: implantes, estética dental, ortodoncia invisible, varias sedes">${v('ideal')}</textarea></div>
      </div>
      <div class="card">
        <h2>2. Sector y zona</h2>
        <div class="grid g3">
          <div class="field"><label>Sector o tipo de negocio *</label><input name="sector" list="sectorList" required value="${v('sector')}" placeholder="Ej.: clínica dental"><datalist id="sectorList">${state.meta.sectors.map(s => `<option value="${esc(s)}">`).join('')}</datalist></div>
          <div class="field"><label>Ubicación * <span class="hint">ciudad, provincia, comunidad o país</span></label><input name="location" value="${v('location')}" placeholder="Ej.: Barcelona"></div>
          <div class="field"><label>Código postal <span class="hint">(opcional)</span></label><input name="postcode" inputmode="numeric" pattern="\\d{5}" placeholder="08025"></div>
          <div class="field"><label>Filtrar por ciudad <span class="hint">(opcional)</span></label><input name="city" placeholder="Ej.: Sabadell (si buscas en una provincia)"></div>
          <div class="field"><label>¿Cuántas empresas?</label><select name="limit">${[10, 25, 50, 100, 150].map(n => `<option ${n == (last.limit || 25) ? 'selected' : ''}>${n}</option>`).join('')}</select></div>
          <div class="field"><label>Puntuación mínima</label><select name="min_score"><option value="0">Cualquiera</option><option value="40">40+ (secundario)</option><option value="60">60+ (interesante)</option><option value="80">80+ (prioritario)</option></select></div>
        </div>
      </div>
      <div class="card">
        <h2>3. Filtros de presencia digital <span class="hint">(opcional)</span></h2>
        <div class="grid g4">
          ${['website|Web', 'instagram|Instagram', 'email|Email público'].map(x => { const [k, l] = x.split('|'); return `<div class="field"><label>${l}</label><select name="${k}"><option value="">Da igual</option><option value="con">Con ${l.toLowerCase()}</option><option value="sin">Sin ${l.toLowerCase()}</option></select></div>`; }).join('')}
          <div class="field"><label>Duplicados</label><label style="font-weight:400;display:flex;gap:8px;align-items:center;margin-top:8px"><input type="checkbox" name="exclude_saved" style="width:auto" checked> Excluir empresas ya guardadas</label></div>
        </div>
      </div>
      <div class="row"><button class="btn primary" id="goBtn">🔎 Buscar empresas reales</button><span class="muted small">Solo datos públicos reales. Lo que no se encuentre aparecerá como «${NF}».</span></div>
    </form>`;
  $('#searchForm').addEventListener('submit', e => {
    e.preventDefault();
    const f = new FormData(e.target);
    const body = Object.fromEntries(f.entries());
    body.exclude_saved = f.get('exclude_saved') === 'on';
    if (!body.location && !body.postcode) { toast('Indica una ubicación o un código postal', true); return; }
    try { localStorage.setItem('cc-last-search', JSON.stringify({ offer: body.offer, customer_type: body.customer_type, ideal: body.ideal, sector: body.sector, location: body.location, limit: body.limit })); } catch (err) {}
    startSearch(body, $('#goBtn'));
  });
}

// ---------- Tabla de empresas con filtros ----------
const FILTERS = [
  ['q', 'Buscar texto', 'text'], ['country', 'País', 'text'], ['region', 'Comunidad autónoma', 'text'], ['province', 'Provincia', 'text'],
  ['city', 'Ciudad', 'text'], ['postcode', 'Código postal', 'text'], ['sector', 'Sector', 'text'],
  ['website', 'Web', 'tri'], ['instagram', 'Instagram', 'tri'], ['email', 'Email público', 'tri'], ['employees', 'Empleados', 'emp'],
  ['min_score', 'Puntuación mínima', 'score'], ['status', 'Estado comercial', 'status'], ['exclude_saved', 'Ya guardadas', 'saved']
];
function filterControls(f, skip = []) {
  return FILTERS.filter(x => !skip.includes(x[0])).map(([k, l, t]) => {
    let input;
    if (t === 'tri') input = `<select data-f="${k}"><option value="">Da igual</option><option value="con" ${f[k] === 'con' ? 'selected' : ''}>Con</option><option value="sin" ${f[k] === 'sin' ? 'selected' : ''}>Sin</option></select>`;
    else if (t === 'emp') input = `<select data-f="${k}"><option value="">Da igual</option><option value="conocido" ${f[k] === 'conocido' ? 'selected' : ''}>Solo si se conoce</option></select>`;
    else if (t === 'score') input = `<select data-f="${k}">${[[0, 'Cualquiera'], [40, '40+'], [60, '60+'], [80, '80+']].map(([n, lb]) => `<option value="${n}" ${String(f[k] || 0) === String(n) ? 'selected' : ''}>${lb}</option>`).join('')}</select>`;
    else if (t === 'status') input = `<select data-f="${k}"><option value="">Todos</option>${state.meta.statuses.map(s => `<option ${f[k] === s ? 'selected' : ''}>${esc(s)}</option>`).join('')}</select>`;
    else if (t === 'saved') input = `<select data-f="${k}"><option value="">Mostrar</option><option value="1" ${f[k] === '1' ? 'selected' : ''}>Ocultar ya guardadas</option></select>`;
    else input = `<input data-f="${k}" value="${esc(f[k] || '')}">`;
    return `<div><label>${l}</label>${input}</div>`;
  }).join('');
}
function applyFilters(list, f) {
  const has = v => v !== null && v !== undefined && String(v).trim() !== '';
  const like = (v, q) => String(v || '').toLowerCase().includes(String(q).trim().toLowerCase());
  return list.filter(c => {
    for (const k of ['country', 'region', 'province', 'city', 'postcode', 'sector']) if (has(f[k]) && !like(c[k], f[k])) return false;
    for (const k of ['website', 'instagram', 'email']) { if (f[k] === 'con' && !has(c[k])) return false; if (f[k] === 'sin' && has(c[k])) return false; }
    if (f.employees === 'conocido' && !has(c.employees)) return false;
    if (+f.min_score > 0 && (c.score || 0) < +f.min_score) return false;
    if (has(f.status) && c.status !== f.status) return false;
    if (f.exclude_saved === '1' && +c.saved === 1) return false;
    if (has(f.q) && !(like(c.name, f.q) || like(c.city, f.q) || like(c.sector, f.q))) return false;
    return true;
  });
}
const COLS = [
  ['name', 'Empresa'], ['sector', 'Sector'], ['city', 'Ciudad'], ['website', 'Web'], ['instagram', 'Instagram'],
  ['phone', 'Teléfono'], ['email', 'Email'], ['score', 'Puntuación'], ['status', 'Estado comercial']
];
function sortList(list, key, dir) {
  return list.slice().sort((a, b) => {
    let x = a[key], y = b[key];
    if (key === 'score') { x = x || 0; y = y || 0; return dir * (x - y); }
    x = String(x || '￿').toLowerCase(); y = String(y || '￿').toLowerCase();
    return dir * x.localeCompare(y, 'es');
  });
}
function companyTable(list, opts) {
  if (!list.length) return `<div class="card muted">No hay empresas que cumplan estos filtros.</div>`;
  const extra = opts.extraCols || [];
  return `<div class="table-wrap"><table>
    <thead><tr><th style="width:28px"><input type="checkbox" id="checkAll" style="width:auto" aria-label="Seleccionar todas"></th>
      ${COLS.concat(extra).map(([k, l]) => `<th data-sort="${k}">${l}${opts.sort.key === k ? (opts.sort.dir > 0 ? ' ▲' : ' ▼') : ''}</th>`).join('')}<th></th></tr></thead>
    <tbody>${list.map(c => `<tr>
      <td><input type="checkbox" class="rowCheck" value="${c.id}" style="width:auto" aria-label="Seleccionar"></td>
      <td class="name"><a href="#/empresa/${c.id}">${esc(c.name)}</a>${+c.saved ? ' <span title="Guardada">⭐</span>' : ''}</td>
      <td>${val(c.sector)}</td><td>${val(c.city)}</td><td>${link(c.website)}</td><td>${igLink(c.instagram)}</td>
      <td>${c.phone ? `<a href="tel:${esc(c.phone.replace(/[^\d+]/g, ''))}">${esc(c.phone)}</a>` : val(null)}</td>
      <td>${c.email ? `<span class="cut">${esc(c.email)}</span>` : val(null)}</td>
      <td>${scoreBadge(c)}</td><td><span class="badge">${esc(c.status)}</span></td>
      ${extra.map(([k]) => `<td>${k === 'next_action_date' ? (c[k] ? fmtDate(c[k]) : '—') : esc(c[k] || '—')}</td>`).join('')}
      <td><a class="btn small" href="#/empresa/${c.id}">Ver</a></td></tr>`).join('')}</tbody></table></div>`;
}
function exportUrl(format, scope, f, searchId) {
  const p = new URLSearchParams({ format, scope });
  if (searchId) p.set('search_id', searchId);
  Object.entries(f).forEach(([k, v]) => { if (v !== '' && v != null) p.set(k, v); });
  return '/api/export?' + p.toString();
}

// Monta una lista filtrable/ordenable con exportación y guardado masivo.
function mountList(container, list, opts) {
  const key = opts.key;
  const st = state.lists[key] || (state.lists[key] = { f: {}, sort: { key: 'score', dir: -1 } });
  const draw = () => {
    const filtered = sortList(applyFilters(list, st.f), st.sort.key, st.sort.dir);
    container.innerHTML = `
      <details class="card" ${Object.values(st.f).some(v => v && v !== '0') ? 'open' : ''}><summary><b>Filtros</b> <span class="muted small">(${filtered.length} de ${list.length} empresas)</span></summary>
        <div class="filters" style="margin-top:12px">${filterControls(st.f, opts.skipFilters || [])}</div>
        <div class="row" style="margin-top:10px"><button class="btn small" id="clearF" type="button">Quitar filtros</button></div>
      </details>
      <div class="row" style="margin-bottom:10px">
        <button class="btn small" id="saveSel" type="button">⭐ Guardar seleccionadas</button>
        <span class="spacer"></span>
        <a class="btn small" href="${exportUrl('xlsx', opts.scope, st.f, opts.searchId)}">⬇️ Exportar Excel (.xlsx)</a>
        <a class="btn small" href="${exportUrl('csv', opts.scope, st.f, opts.searchId)}">⬇️ Exportar CSV</a>
      </div>
      ${companyTable(filtered, { sort: st.sort, extraCols: opts.extraCols })}`;
    $$('[data-f]', container).forEach(el => el.addEventListener(el.tagName === 'INPUT' ? 'input' : 'change', () => {
      st.f[el.dataset.f] = el.value;
      clearTimeout(draw._t);
      draw._t = setTimeout(() => { const pos = el.dataset.f; draw(); const n = $(`[data-f="${pos}"]`, container); if (n && n.tagName === 'INPUT') { n.focus(); n.setSelectionRange(n.value.length, n.value.length); } }, el.tagName === 'INPUT' ? 250 : 0);
    }));
    $('#clearF', container).onclick = () => { st.f = {}; draw(); };
    $$('th[data-sort]', container).forEach(th => th.onclick = () => {
      const k = th.dataset.sort;
      st.sort = { key: k, dir: st.sort.key === k ? -st.sort.dir : (k === 'score' ? -1 : 1) };
      draw();
    });
    const all = $('#checkAll', container);
    if (all) all.onchange = () => $$('.rowCheck', container).forEach(c => { c.checked = all.checked; });
    $('#saveSel', container).onclick = async () => {
      const ids = $$('.rowCheck:checked', container).map(c => +c.value);
      if (!ids.length) return toast('Marca primero alguna empresa', true);
      await api('/api/companies/bulk-save', { method: 'POST', body: { ids } });
      ids.forEach(id => { const c = list.find(x => x.id === id); if (c) c.saved = 1; });
      toast(`${ids.length} empresas guardadas en «Mis leads»`);
      draw();
    };
  };
  draw();
}

// ---------- Resultados de búsqueda ----------
async function renderSearchResults(id) {
  const s = await api('/api/searches/' + id);
  setTitle('Resultados: ' + s.raw_text);
  const p = s.params || {};
  const head = `<div class="card"><div class="row"><div><h1>${esc(s.raw_text)}</h1>
    <p class="muted small" style="margin:0">${p.offer ? 'Vendes: ' + esc(p.offer) + ' · ' : ''}Zona: ${esc(s.location_label || p.location || p.postcode || '')} · ${fmtDate(s.created_at)}${s.sources_used ? ' · Fuentes: ' + esc(s.sources_used.join(', ')) : ''}</p></div>
    <span class="spacer"></span><a class="btn small" href="#/buscar">Nueva búsqueda</a></div></div>`;
  if (s.status === 'en_curso') {
    view().innerHTML = head + `<div class="card"><h2>Buscando empresas reales…</h2><div class="progress"><div style="width:${s.progress}%"></div></div><p class="muted">${esc(s.message || '')}</p>
      <p class="small muted">Consultamos fuentes públicas reales y visitamos la web de cada negocio para detectar oportunidades. Suele tardar entre 30 segundos y 3 minutos.</p></div>`;
    state.pollTimer = setTimeout(() => { if (location.hash === '#/busqueda/' + id) renderSearchResults(id); }, 2000);
    return;
  }
  if (s.status === 'error') {
    view().innerHTML = head + `<div class="notice bad">${esc(s.message)}</div><p><button class="btn primary" id="retry">Reintentar esta búsqueda</button></p>`;
    $('#retry').onclick = () => startSearch(p, $('#retry'));
    return;
  }
  const list = await api(`/api/searches/${id}/results`);
  view().innerHTML = head + (s.message && /Aviso|Ningún/.test(s.message) ? `<div class="notice warn small">${esc(s.message)}</div>` : `<p class="muted small">${esc(s.message || '')}</p>`) + '<div id="listBox"></div>';
  mountList($('#listBox'), list, { key: 'search' + id, scope: 'search', searchId: id });
}

// ---------- Mis leads ----------
async function renderLeads() {
  setTitle('Mis leads');
  const list = await api('/api/leads');
  view().innerHTML = `<div class="card"><h1>Mis leads</h1><p class="muted" style="margin:0">Empresas que has guardado. Aquí gestionas el seguimiento comercial. Un lead se guarda automáticamente al cambiarle el estado.</p></div><div id="listBox"></div>`;
  if (!list.length) { $('#listBox').innerHTML = '<div class="card muted">Todavía no has guardado ningún lead. Haz una búsqueda y pulsa ⭐ en las empresas que te interesen.</div>'; return; }
  mountList($('#listBox'), list, { key: 'leads', scope: 'leads', skipFilters: ['exclude_saved'], extraCols: [['next_action_date', 'Próx. acción']] });
}

// ---------- Ficha de empresa ----------
const FIELD_LABELS = [
  ['name', 'Nombre comercial'], ['sector', 'Sector'], ['address', 'Dirección'], ['postcode', 'Código postal'], ['city', 'Ciudad'],
  ['province', 'Provincia'], ['region', 'Comunidad autónoma'], ['country', 'País'], ['website', 'Web'], ['instagram', 'Instagram'],
  ['facebook', 'Facebook'], ['linkedin', 'LinkedIn'], ['tiktok', 'TikTok'], ['phone', 'Teléfono público'], ['email', 'Email publicado'],
  ['whatsapp', 'WhatsApp publicado'], ['employees', 'Empleados'], ['opening_hours', 'Horario'], ['rating', 'Valoración Google']
];
function fieldValue(c, k) {
  const v = c[k];
  if (k === 'instagram') return igLink(v);
  if (['website', 'facebook', 'linkedin', 'tiktok'].includes(k)) return link(v);
  if (k === 'phone' && v) return `<a href="tel:${esc(v.replace(/[^\d+]/g, ''))}">${esc(v)}</a>`;
  if (k === 'email' && v) return `<a href="mailto:${esc(v)}">${esc(v)}</a>`;
  if (k === 'rating' && v) return `${esc(v)} ★ (${esc(c.rating_count || 0)} reseñas)`;
  return val(v);
}

async function renderCompany(id) {
  const c = await api('/api/companies/' + id);
  setTitle(c.name);
  const a = c.analysis || {};
  const src = c.field_sources || {};
  const ops = c.opportunities || [];
  const bd = c.score_breakdown || {};
  view().innerHTML = `
    <div class="card">
      <div class="row">
        <div style="min-width:0">
          <h1>${esc(c.name)}</h1>
          <div class="row small"><span>${val(c.sector)}</span>·<span>${val(c.city)}</span>
            <span class="badge conf-${esc(c.confidence)}" title="Fiabilidad de los datos">Confianza ${esc(c.confidence || '—').toLowerCase()}</span>
            <span class="muted">Comprobado: ${fmtDate(c.last_checked_at)}</span></div>
        </div>
        <span class="spacer"></span>
        <div style="text-align:center">${scoreBadge(c)}<div class="small muted">${esc(c.score_tier || '')}</div></div>
      </div>
      <div class="row" style="margin-top:14px">
        <button class="btn ${+c.saved ? '' : 'primary'}" id="saveBtn">${+c.saved ? '⭐ Guardada (quitar)' : '⭐ Guardar en mis leads'}</button>
        <select id="statusSel" style="width:auto">${state.meta.statuses.map(s => `<option ${s === c.status ? 'selected' : ''}>${esc(s)}</option>`).join('')}</select>
        <button class="btn" id="reBtn" title="Vuelve a visitar la web y recalcula la puntuación">🔄 Volver a comprobar</button>
        ${c.maps_url ? `<a class="btn" href="${esc(c.maps_url)}" target="_blank" rel="noopener">Google Maps</a>` : ''}
        ${c.osm_ref ? `<a class="btn" href="${esc(c.osm_ref)}" target="_blank" rel="noopener">Ver en OpenStreetMap</a>` : ''}
      </div>
    </div>
    <div class="grid g2">
      <div>
        <div class="card"><h2>Datos de la empresa</h2>
          <dl class="dl">${FIELD_LABELS.map(([k, l]) => `<dt>${l}</dt><dd>${fieldValue(c, k)}${src[k] ? `<span class="src">· ${src[k].url ? `<a href="${esc(src[k].url)}" target="_blank" rel="noopener">${esc(src[k].source)}</a>` : esc(src[k].source)}</span>` : ''}</dd>`).join('')}
            <dt>Decisor</dt><dd>${c.decision_maker ? `${esc(c.decision_maker)} <span class="src">· ${esc(c.decision_maker_source)}</span>` : `<span class="nf">${NF}</span> <span class="hint">(solo si es público; añádelo abajo con su fuente)</span>`}</dd>
          </dl>
        </div>
        <div class="card"><h2>Oportunidades detectadas</h2>
          ${ops.length ? ops.map(o => `<div class="op"><b>${esc(o.title)}</b><div class="small muted">Evidencia: ${esc(o.evidence)}</div></div>`).join('') : '<p class="muted">No se han detectado carencias claras con la información pública disponible.</p>'}
          ${a.listed_url_error ? `<p class="small muted">ℹ️ ${esc(a.listed_url_error)}</p>` : ''}
          ${a.reachable ? `<p class="small muted">Web analizada: ${link(a.final_url)} · HTTPS: ${a.https ? 'sí' : 'no'} · Móvil: ${a.viewport ? 'sí' : 'no'} · © ${a.copyright_year || 'no indicado'}${a.builder ? ' · Hecha con ' + esc(a.builder) : ''} · Reservas online: ${a.has_booking ? 'sí' : 'no'}</p>` : (a.error ? `<p class="small muted">Web: ${esc(a.error)}</p>` : '')}
          <p class="small muted">La actividad en redes sociales no se puede verificar sin la API oficial de Meta; por eso no se marca «redes abandonadas».</p>
        </div>
        <div class="card"><h2>Puntuación: ${c.score ?? '—'}/100</h2>
          ${Object.entries(bd).map(([k, [v, max]]) => `<div class="bar"><span>${esc(k)}</span><div class="track"><div style="width:${Math.round(v / max * 100)}%"></div></div><span class="small">${v}/${max}</span></div>`).join('')}
          <p class="small">${esc(c.score_explanation || '')}</p>
          ${c.score_context && c.score_context.offer ? `<p class="small muted">Calculada para: «${esc(c.score_context.offer)}»</p>` : ''}
        </div>
      </div>
      <div>
        <div class="card"><h2>Seguimiento comercial</h2>
          <div class="grid g2">
            <div class="field"><label>Próxima acción</label><input id="naText" value="${esc(c.next_action || '')}" placeholder="Ej.: llamar para presentar propuesta"></div>
            <div class="field"><label>Fecha próxima acción</label><input id="naDate" type="date" value="${esc(c.next_action_date || '')}"></div>
            <div class="field"><label>Último contacto</label><input id="lcDate" type="date" value="${esc(c.last_contact_date || '')}"></div>
            <div class="field" style="display:flex;align-items:flex-end"><button class="btn primary" id="saveCrm">Guardar seguimiento</button></div>
          </div>
          <div class="field"><label>Añadir nota o comentario</label><textarea id="noteText" rows="2" placeholder="Ej.: hablé con recepción, el responsable vuelve el lunes"></textarea></div>
          <div class="row"><select id="noteKind" style="width:auto"><option value="nota">Nota</option><option value="comentario">Comentario</option><option value="contacto">Contacto realizado</option></select><input id="noteDate" type="date" style="width:auto" title="Fecha del contacto"><button class="btn" id="addNote">Añadir</button></div>
          <h3 style="margin-top:16px">Historial</h3>
          ${c.events.length ? `<ul class="timeline">${c.events.map(e => `<li><span class="badge">${esc(e.kind)}</span> ${esc(e.text)}${e.event_date ? ` <span class="muted">(${fmtDate(e.event_date)})</span>` : ''}<br><span class="muted small">${fmtDate(e.created_at)}</span></li>`).join('')}</ul>` : '<p class="muted small">Sin actividad todavía.</p>'}
        </div>
        <div class="card"><h2>Asistente comercial con IA</h2>
          <p class="small muted">Genera borradores personalizados solo con los datos reales de esta ficha. Nada se envía: revisa, edita y aprueba cada texto, y envíalo tú manualmente.</p>
          <div class="notice warn small">⚖️ En España, enviar emails comerciales no solicitados puede infringir la LSSI (art. 21) aunque el destinatario sea una empresa. Usa el email cuando haya base legal y ofrece siempre una forma fácil de darse de baja. El WhatsApp solo se propone si el negocio publica ese canal.</div>
          <button class="btn primary" id="aiBtn" ${state.config.ai ? '' : 'disabled title="Configura ANTHROPIC_API_KEY en .env"'}>✨ ${c.drafts.length ? 'Generar nuevos borradores' : 'Generar borradores'}</button>
          ${state.config.ai ? '' : '<p class="small">Para activarlo, añade tu clave de Anthropic (ver <a href="#/ajustes">Ajustes</a>).</p>'}
          <div id="drafts" style="margin-top:14px">${c.drafts.map(d => `
            <div class="draft ${esc(d.status)}" data-id="${d.id}">
              <div class="row"><b>${esc(d.title)}</b><span class="badge">${d.status === 'aprobado' ? '✅ aprobado' : 'borrador'}</span><span class="spacer"></span><span class="muted small">${fmtDate(d.created_at)}</span></div>
              <textarea>${esc(d.content)}</textarea>
              <div class="row" style="margin-top:6px"><button class="btn small" data-act="save">Guardar cambios</button><button class="btn small" data-act="approve">${d.status === 'aprobado' ? 'Volver a borrador' : 'Aprobar'}</button><button class="btn small" data-act="copy">Copiar</button><span class="spacer"></span><button class="btn small danger" data-act="del">Eliminar</button></div>
            </div>`).join('')}</div>
        </div>
        <div class="card"><h2>Privacidad (RGPD / LOPDGDD)</h2>
          <dl class="dl small"><dt>Origen de los datos</dt><dd>${esc(c.source_note || '')}</dd><dt>Primera detección</dt><dd>${fmtDate(c.created_at)}</dd></dl>
          <div class="field" style="margin-top:10px"><label>Base jurídica del tratamiento</label><textarea id="lawful" rows="2">${esc(c.lawful_basis || '')}</textarea></div>
          <div class="grid g2"><div class="field"><label>Decisor (solo si es público)</label><input id="dm" value="${esc(c.decision_maker || '')}" placeholder="Nombre y cargo"></div>
          <div class="field"><label>Fuente pública del decisor</label><input id="dmSrc" value="${esc(c.decision_maker_source || '')}" placeholder="Ej.: web, página «Equipo»"></div></div>
          <div class="row"><button class="btn" id="saveLegal">Guardar</button><span class="spacer"></span><button class="btn danger" id="suppressBtn">Solicitud de supresión</button></div>
          <p class="small muted">«Solicitud de supresión» borra todos los datos de esta empresa (notas, borradores e historial) y la añade a una lista de exclusión para que no vuelva a aparecer en búsquedas.</p>
        </div>
      </div>
    </div>`;

  const patch = async body => {
    try { await api('/api/companies/' + id, { method: 'PATCH', body }); toast('Guardado'); renderCompany(id); } catch (err) { toast(err.message, true); }
  };
  $('#saveBtn').onclick = async () => { await api(`/api/companies/${id}/save`, { method: 'POST', body: { saved: !+c.saved } }); toast(+c.saved ? 'Quitada de mis leads' : 'Guardada en mis leads'); renderCompany(id); };
  $('#statusSel').onchange = e => patch({ status: e.target.value });
  $('#saveCrm').onclick = () => patch({ next_action: $('#naText').value, next_action_date: $('#naDate').value, last_contact_date: $('#lcDate').value });
  $('#saveLegal').onclick = () => patch({ lawful_basis: $('#lawful').value, decision_maker: $('#dm').value, decision_maker_source: $('#dmSrc').value });
  $('#addNote').onclick = async () => {
    try { await api(`/api/companies/${id}/events`, { method: 'POST', body: { kind: $('#noteKind').value, text: $('#noteText').value, date: $('#noteDate').value } }); toast('Añadido al historial'); renderCompany(id); } catch (err) { toast(err.message, true); }
  };
  $('#reBtn').onclick = async e => {
    e.target.disabled = true; e.target.textContent = 'Comprobando…';
    try { await api(`/api/companies/${id}/reanalyze`, { method: 'POST', body: {} }); toast('Datos actualizados'); renderCompany(id); } catch (err) { toast(err.message, true); e.target.disabled = false; }
  };
  $('#aiBtn').onclick = async e => {
    e.target.disabled = true; e.target.textContent = '✨ Generando (puede tardar hasta un minuto)…';
    try { await api(`/api/companies/${id}/ai`, { method: 'POST', body: {} }); toast('Borradores generados'); renderCompany(id); } catch (err) { toast(err.message, true); e.target.disabled = false; e.target.textContent = '✨ Generar borradores'; }
  };
  $$('.draft').forEach(box => box.addEventListener('click', async e => {
    const act = e.target.dataset.act; if (!act) return;
    const did = box.dataset.id; const ta = $('textarea', box);
    try {
      if (act === 'save') { await api('/api/drafts/' + did, { method: 'PATCH', body: { content: ta.value } }); toast('Borrador guardado'); }
      if (act === 'approve') { await api('/api/drafts/' + did, { method: 'PATCH', body: { content: ta.value, status: box.classList.contains('aprobado') ? 'borrador' : 'aprobado' } }); renderCompany(id); }
      if (act === 'copy') { await navigator.clipboard.writeText(ta.value); toast('Copiado al portapapeles'); }
      if (act === 'del' && confirm('¿Eliminar este borrador?')) { await api('/api/drafts/' + did, { method: 'DELETE' }); box.remove(); }
    } catch (err) { toast(err.message, true); }
  }));
  $('#suppressBtn').onclick = async () => {
    const reason = prompt('Supresión de datos de «' + c.name + '».\nEsta acción NO se puede deshacer.\n\nMotivo (p. ej., «solicitud por email del 3/11»):');
    if (reason === null) return;
    try { await api(`/api/companies/${id}/suppress`, { method: 'POST', body: { reason } }); toast('Datos eliminados y empresa excluida de futuras búsquedas'); location.hash = '#/leads'; } catch (err) { toast(err.message, true); }
  };
}

// ---------- Historial ----------
async function renderHistory() {
  setTitle('Historial de búsquedas');
  const list = await api('/api/searches');
  view().innerHTML = `<div class="card"><h1>Historial de búsquedas</h1><p class="muted" style="margin:0">Todas tus búsquedas. Puedes abrir los resultados o repetir la búsqueda para actualizar los datos.</p></div>
    ${list.length ? `<div class="table-wrap"><table><thead><tr><th>Búsqueda</th><th>Fecha</th><th>Estado</th><th>Empresas</th><th>Fuentes</th><th></th></tr></thead><tbody>
    ${list.map(s => `<tr><td class="name"><a href="#/busqueda/${s.id}">${esc(s.raw_text)}</a><div class="muted small">${esc((s.params || {}).offer || '')}</div></td><td>${fmtDate(s.created_at)}</td>
      <td><span class="badge">${esc(s.status)}</span></td><td>${s.total_found || 0}</td><td class="small">${esc((s.sources_used || []).join(', '))}</td>
      <td style="white-space:nowrap"><button class="btn small" data-repeat="${s.id}">Repetir</button> <button class="btn small danger" data-del="${s.id}" title="Quitar del historial">✕</button></td></tr>`).join('')}</tbody></table></div>` : '<div class="card muted">Aún no hay búsquedas.</div>'}`;
  $$('[data-repeat]').forEach(b => b.onclick = () => { const s = list.find(x => x.id === +b.dataset.repeat); startSearch(Object.assign({}, s.params, { exclude_saved: false }), b); });
  $$('[data-del]').forEach(b => b.onclick = async () => { if (!confirm('¿Quitar esta búsqueda del historial? Los leads guardados se conservan.')) return; await api('/api/searches/' + b.dataset.del, { method: 'DELETE' }); renderHistory(); });
}

// ---------- Estadísticas ----------
function bars(rows, labelKey, max) {
  if (!rows.length) return '<p class="muted small">Sin datos todavía.</p>';
  const m = max || Math.max(...rows.map(r => r.n), 1);
  return rows.map(r => `<div class="bar"><span>${esc(r[labelKey] || NF)}</span><div class="track"><div style="width:${Math.round(r.n / m * 100)}%"></div></div><span class="small">${r.n}</span></div>`).join('');
}
async function renderStats() {
  setTitle('Estadísticas');
  const s = await api('/api/stats');
  const order = state.meta.statuses;
  const byStatus = order.map(st => ({ status: st, n: (s.by_status.find(x => x.status === st) || { n: 0 }).n }));
  const byTier = ['Prioritario', 'Interesante', 'Secundario', 'Baja prioridad'].map(t => ({ tier: t, n: (s.by_tier.find(x => x.tier === t) || { n: 0 }).n }));
  view().innerHTML = `
    <div class="grid g4" style="margin-bottom:16px">
      <div class="kpi"><b>${s.saved}</b><span>Leads guardados</span></div>
      <div class="kpi"><b>${s.with_email}</b><span>Con email público</span></div>
      <div class="kpi"><b>${s.without_web}</b><span>Sin web encontrada</span></div>
      <div class="kpi"><b>${s.searches}</b><span>Búsquedas realizadas</span></div>
    </div>
    <div class="grid g2">
      <div class="card"><h2>Embudo comercial</h2>${bars(byStatus, 'status')}</div>
      <div class="card"><h2>Leads por prioridad</h2>${bars(byTier, 'tier')}</div>
      <div class="card"><h2>Sectores</h2>${bars(s.by_sector, 'sector')}</div>
      <div class="card"><h2>Ciudades</h2>${bars(s.by_city, 'city')}</div>
    </div>
    <p class="muted small">Las estadísticas se calculan sobre tus leads guardados. Borradores de IA generados: ${s.drafts}.</p>`;
}

// ---------- Ajustes ----------
async function renderSettings() {
  setTitle('Ajustes y privacidad');
  const [s, priv] = await Promise.all([api('/api/settings'), api('/api/privacy')]);
  const inp = (k, l, hint = '', type = 'text') => `<div class="field"><label>${l} ${hint ? `<span class="hint">${hint}</span>` : ''}</label><input name="${k}" type="${type}" value="${esc(s[k] || '')}"></div>`;
  view().innerHTML = `
    <form id="setForm">
      <div class="card"><h2>Tus datos (para los mensajes de la IA)</h2>
        <div class="grid g3">${inp('sender_name', 'Tu nombre')}${inp('sender_company', 'Tu empresa o marca')}${inp('sender_offer', 'Tu servicio principal', '(si la búsqueda no lo indica)')}</div>
      </div>
      <div class="card"><h2>Privacidad y conservación de datos</h2>
        <div class="grid g3">${inp('retention_days_unsaved', 'Borrar resultados no guardados tras', '(días)', 'number')}${inp('retention_days_saved', 'Borrar leads sin actividad tras', '(días; 0 = nunca)', 'number')}
          <div class="field" style="display:flex;align-items:flex-end"><button class="btn" type="button" id="runRet">Aplicar limpieza ahora</button></div></div>
        <div class="field"><label>Base jurídica por defecto para nuevos leads</label><textarea name="default_lawful_basis" rows="2">${esc(s.default_lawful_basis || '')}</textarea></div>
        <p class="small muted">Los clientes conseguidos no se borran automáticamente. Las solicitudes de supresión se atienden desde la ficha de cada empresa.</p>
      </div>
      <div class="card"><h2>Límites de uso</h2>
        <div class="grid g3">${inp('max_searches_per_hour', 'Búsquedas por hora', '', 'number')}${inp('max_ai_per_hour', 'Generaciones de IA por hora', '', 'number')}</div>
      </div>
      <p><button class="btn primary">Guardar ajustes</button></p>
    </form>
    <div class="card"><h2>Fuentes de datos y claves API</h2>
      <p>${state.config.google ? '✅' : '⚪'} <b>Google Places API</b> — ${state.config.google ? 'activada' : 'no configurada (opcional, de pago con crédito gratuito mensual)'}</p>
      <p>✅ <b>OpenStreetMap</b> (Nominatim + Overpass) — gratis, siempre activo</p>
      <p>${state.config.ai ? '✅' : '⚪'} <b>Asistente IA (Claude, de Anthropic)</b> — ${state.config.ai ? 'activado, modelo ' + esc(state.config.model) : 'no configurado'}</p>
      <p class="small muted">Las claves se guardan en el archivo <code>.env</code> de la carpeta de la aplicación (nunca en el navegador). Tras cambiarlo, cierra y vuelve a abrir la aplicación. El README explica paso a paso cómo conseguir cada clave.</p>
    </div>
    <div class="card"><h2>Lista de exclusión (supresiones atendidas)</h2>
      ${priv.suppression.length ? `<ul class="timeline">${priv.suppression.map(x => `<li><b>${esc(x.label)}</b> · ${fmtDate(x.created_at)}<br><span class="muted small">${esc(x.reason || 'Sin motivo indicado')}</span></li>`).join('')}</ul>` : '<p class="muted small">Ninguna.</p>'}
    </div>
    <div class="card"><h2>Registro de actividad (responsabilidad proactiva)</h2>
      ${priv.audit.length ? `<ul class="timeline">${priv.audit.slice(0, 50).map(x => `<li><span class="badge">${esc(x.action)}</span> ${esc(x.detail)} <span class="muted small">${fmtDate(x.created_at)}</span></li>`).join('')}</ul>` : '<p class="muted small">Sin registros.</p>'}
    </div>`;
  $('#setForm').addEventListener('submit', async e => {
    e.preventDefault();
    try { await api('/api/settings', { method: 'PUT', body: Object.fromEntries(new FormData(e.target).entries()) }); toast('Ajustes guardados'); } catch (err) { toast(err.message, true); }
  });
  $('#runRet').onclick = async () => { const r = await api('/api/retention/run', { method: 'POST', body: {} }); toast(`Limpieza aplicada: ${r.removed} registros eliminados`); };
}

// ---------- Inicio ----------
window.addEventListener('hashchange', router);
$('#themeBtn').onclick = () => applyTheme(document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark');
$('#menuBtn').onclick = () => $('#sidebar').classList.toggle('open');
$('#logoutBtn').onclick = async () => { await api('/api/logout', { method: 'POST', body: {} }); state.me = null; showAuth(false); };
boot().catch(err => { document.body.innerHTML = `<p style="padding:20px">${esc(err.message)}</p>`; });
