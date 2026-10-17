// keyglyph.js — renders a key label as a keycap or a pictorial controller button.
//
// Labels come from spz-core KeyFor: keyboard keys ("E", "F4", "SPACE", "←") or
// controller buttons ("A", "LB", "RT", "LS", "D-PAD ↑", "MENU", "VIEW"). The
// controller ones are drawn as the button itself — coloured face buttons,
// bumper / trigger shapes, a d-pad with the pressed arm lit — so a pad player
// recognises them at a glance. Keyboard keys get an accent-gradient keycap.
//
//   KeyGlyph.html("A")        -> '<span class="kg kg-face kg-a">A</span>'
//   KeyGlyph.html("D-PAD ←")  -> d-pad svg with the left arm lit
//
// Shared by spz-minigames (HUD) and spz-replay (copied there; keep in step).
(function () {
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  const FACE = { A: 'kg-a', B: 'kg-b', X: 'kg-x', Y: 'kg-y' };
  const DPAD = { '↑': 'up', '↓': 'down', '←': 'left', '→': 'right' };

  function dpad(dir) {
    const arm = (d, path) => `<path class="${d === dir ? 'on' : ''}" d="${path}"/>`;
    return `<span class="kg kg-dpad" title="D-pad ${esc(dir)}"><svg viewBox="0 0 24 24">`
      + arm('up', 'M9 2h6v7H9z') + arm('down', 'M9 15h6v7H9z')
      + arm('left', 'M2 9h7v6H2z') + arm('right', 'M15 9h7v6h-7z')
      + '<rect class="mid" x="9" y="9" width="6" height="6"/></svg></span>';
  }

  function html(label) {
    const k = String(label || '?').trim();
    const u = k.toUpperCase();
    if (FACE[u]) return `<span class="kg kg-face ${FACE[u]}">${u}</span>`;
    if (u === 'LB' || u === 'RB') return `<span class="kg kg-bumper">${u}</span>`;
    if (u === 'LT' || u === 'RT') return `<span class="kg kg-trigger">${u}</span>`;
    if (u === 'LS' || u === 'RS') return `<span class="kg kg-stick">${u[0]}</span>`;
    if (u.startsWith('D-PAD')) return dpad(DPAD[k.slice(-1)] || '');
    if (u === 'MENU') return '<span class="kg kg-round" title="Menu">☰</span>';
    if (u === 'VIEW') return '<span class="kg kg-round" title="View">⧉</span>';
    return `<span class="kg kg-key">${esc(k)}</span>`;
  }

  window.KeyGlyph = { html };
})();
