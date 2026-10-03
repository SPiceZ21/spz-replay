// spz-replay UI — browser, loading card, playback HUD.
const $ = (id) => document.getElementById(id)
const RES = (window.GetParentResourceName && GetParentResourceName()) || 'spz-replay'

function post(name, data = {}) {
  return fetch(`https://${RES}/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(data),
  }).then((r) => r.json()).catch(() => null)
}

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))

function fmtClock(ms) {
  ms = Math.max(0, ms | 0)
  const m = Math.floor(ms / 60000)
  const s = Math.floor((ms % 60000) / 1000)
  const t = Math.floor((ms % 1000) / 100)
  return `${m}:${String(s).padStart(2, '0')}.${t}`
}
function fmtLen(ms) {
  const s = Math.round(ms / 1000)
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}
function ago(unix) {
  const d = Math.max(0, Date.now() / 1000 - unix)
  if (d < 90) return 'just now'
  if (d < 3600) return `${Math.round(d / 60)} min ago`
  if (d < 86400) return `${Math.round(d / 3600)} h ago`
  return `${Math.round(d / 86400)} d ago`
}
const cap = (s) => (s ? s[0].toUpperCase() + s.slice(1) : '')

// ── Browser ───────────────────────────────────────────────────────────────
let canDelete = false

function renderBrowser(res) {
  const rows = res?.rows || []
  canDelete = !!res?.canDelete
  $('br-rec').classList.toggle('hidden', !res?.recording)
  $('br-error').classList.add('hidden')
  $('br-empty').classList.toggle('hidden', rows.length > 0)
  $('br-list').innerHTML = rows.map((r) => `
    <div class="br-row" data-id="${r.id}">
      <div class="br-track">
        <b>${esc(r.track)}</b>
        <small>${esc(cap(r.race_type))} · ${r.race_type === 'sprint' ? 'A→B' : `${r.laps} LAPS`}${r.car_class ? ' · ' + esc(r.car_class) : ''}</small>
      </div>
      <div class="br-cell">${r.winner ? `<span class="crown">♛</span>${esc(r.winner)}` : '<span class="dim">—</span>'}</div>
      <div class="br-cell mono">${r.racer_count}</div>
      <div class="br-cell mono">${fmtLen(r.duration_ms)}</div>
      <div class="br-cell dim">${ago(r.created)}</div>
      <div class="br-go">
        ${canDelete ? `<button class="btn danger" data-del="${r.id}" title="Delete">✕</button>` : ''}
        <button class="btn" data-watch="${r.id}" data-track="${esc(r.track)}">▶ WATCH</button>
      </div>
    </div>`).join('')
  $('browser').classList.remove('hidden')
}

function closeBrowser() {
  $('browser').classList.add('hidden')
  post('closeBrowser')
}

$('br-close').onclick = closeBrowser
$('br-refresh').onclick = async () => renderBrowser(await post('refresh'))
$('br-list').onclick = async (e) => {
  const w = e.target.closest('[data-watch]')
  const d = e.target.closest('[data-del]')
  if (w) {
    w.disabled = true
    const res = await post('watch', { id: Number(w.dataset.watch), track: w.dataset.track })
    if (res && res.ok) {
      $('browser').classList.add('hidden')
    } else {
      w.disabled = false
      $('br-error').textContent = res?.error || 'Could not open that replay.'
      $('br-error').classList.remove('hidden')
    }
  } else if (d) {
    if (await post('delete', { id: Number(d.dataset.del) })) d.closest('.br-row').remove()
  }
}
window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !$('browser').classList.contains('hidden')) closeBrowser()
})

// ── Player HUD ────────────────────────────────────────────────────────────
let duration = 1
let lastBoardKey = ''

function renderPlayer(d) {
  const root = $('player')
  if (!d.visible) {
    root.classList.add('hidden')
    root.classList.remove('rv')
    $('loading').classList.add('hidden')
    return
  }
  $('loading').classList.add('hidden')
  root.classList.remove('hidden')
  root.classList.toggle('paused', !!d.paused)
  duration = Math.max(1, d.duration)

  const tg = d.target || {}
  $('pl-cam').textContent = d.camera
  $('pl-track').textContent = d.track || '—'
  $('pl-class').textContent = d.carClass || ''
  $('pl-lap').textContent = d.raceType === 'sprint' ? 'SPRINT' : `LAP ${Math.max(1, tg.lap || 1)}/${d.laps || 1}`
  $('pl-pos').textContent = tg.pos > 0 ? `P${tg.pos}` : 'P–'
  $('pl-num').textContent = tg.number ?? ''
  $('pl-num').classList.toggle('hidden', tg.number == null)
  $('pl-name').textContent = tg.name || '—'
  $('pl-crew').textContent = tg.crew || ''
  $('pl-crew').classList.toggle('hidden', !tg.crew)
  const fin = $('pl-final')
  if (tg.dnf) { fin.textContent = 'DNF'; fin.className = 'chip chip-rank' }
  else if (tg.finalPos) {
    fin.textContent = `FINISHED P${tg.finalPos}${tg.time ? ' · ' + fmtClock(tg.time) : ''}`
    fin.className = `chip ${tg.finalPos === 1 ? 'chip-gold' : 'chip-rank'}`
  }
  fin.classList.toggle('hidden', !tg.dnf && !tg.finalPos)
  $('pl-lapv').textContent = d.raceType === 'sprint' ? '—' : `${Math.max(1, tg.lap || 1)}/${d.laps || 1}`
  $('pl-speed').textContent = tg.speed || 0
  $('pl-car').textContent = tg.car || '—'
  $('pl-t').textContent = fmtClock(d.t)
  $('pl-dur').textContent = fmtClock(d.duration)
  $('pl-speedx').textContent = `${d.speed}×`
  const rec = d.rec != null
  $('pl-rec').classList.toggle('on', rec)
  $('pl-rec').querySelector('span').textContent = rec ? 'STOP' : 'REC'
  $('pl-recbadge').classList.toggle('hidden', !rec)
  if (rec) $('pl-rect').textContent = fmtLen(d.rec)

  // While dragging, the knob follows the mouse, not the (gliding) clock.
  if (!dragging) setBar(d.t / duration)

  const board = d.board || []
  const ti = board.findIndex((b) => b.target)
  $('pl-counter').textContent = `${(board[ti]?.id) ?? 1} / ${d.count || board.length}`
  const key = board.map((b) => `${b.id}:${b.pos}:${b.target ? 1 : 0}:${b.finished ? 1 : 0}`).join('|')
  if (key !== lastBoardKey) {
    lastBoardKey = key
    $('pl-list').innerHTML = board.slice(0, 12).map((b, i) => `
      <div class="rrow ${i === 0 ? 'leader' : ''} ${b.target ? 'me' : ''} ${b.finished ? 'done' : ''}" data-id="${b.id}">
        <span class="rpos">${b.pos < 99 ? b.pos : '–'}</span>
        ${b.number != null ? `<span class="rnum">${esc(b.number)}</span>` : ''}
        <span class="rname">${esc(b.name)}</span>
        ${b.finished ? '<span class="rtag">FIN</span>' : ''}
      </div>`).join('')
  }
}

$('pl-list').onclick = (e) => {
  const row = e.target.closest('.rrow')
  if (row) post('control', { op: 'target', id: Number(row.dataset.id) })
}
$('pl-play').onclick = () => post('control', { op: 'toggle' })
$('pl-rec').onclick = () => post('control', { op: 'record' })
$('pl-editor').onclick = () => post('control', { op: 'editor' })

// Timeline scrubbing (mouse mode). The knob moves instantly under the
// mouse; seeks are sent at most every 50 ms, and the game glides its clock to
// each one, so dragging plays the race through smoothly instead of jumping.
const tl = $('pl-track-bar')
let dragging = false
let lastSeek = 0
let pendingK = null
function setBar(k) {
  const pct = Math.min(100, Math.max(0, k * 100))
  $('pl-fill').style.width = pct + '%'
  $('pl-knob').style.left = pct + '%'
}
function seekAt(clientX, force) {
  const r = tl.getBoundingClientRect()
  const k = Math.min(1, Math.max(0, (clientX - r.left) / r.width))
  setBar(k)
  pendingK = k
  const now = performance.now()
  if (force || now - lastSeek > 50) {
    lastSeek = now
    post('seek', { t: Math.round(k * duration) })
    pendingK = null
  }
}
tl.addEventListener('mousedown', (e) => { dragging = true; tl.classList.add('drag'); seekAt(e.clientX, true) })
window.addEventListener('mousemove', (e) => { if (dragging) seekAt(e.clientX) })
window.addEventListener('mouseup', (e) => {
  if (!dragging) return
  dragging = false
  tl.classList.remove('drag')
  seekAt(e.clientX, true)   // land exactly where the mouse was let go
})

function toggleRecordView() {
  const root = $('player')
  const on = !root.classList.contains('rv')
  root.classList.toggle('rv', on)
  const hint = $('pl-rvhint')
  hint.classList.add('hidden')
  if (on) { void hint.offsetWidth; hint.classList.remove('hidden') }
}

// ── Messages ──────────────────────────────────────────────────────────────
window.addEventListener('message', (e) => {
  const { action, data } = e.data || {}
  switch (action) {
    case 'browser': renderBrowser(data); break
    case 'loading':
      $('ld-track').textContent = data?.track || '—'
      $('loading').classList.remove('hidden')
      break
    case 'player': renderPlayer(data || {}); break
    case 'recordView': toggleRecordView(); break
  }
})
