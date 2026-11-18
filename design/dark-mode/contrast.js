// WCAG contrast checks for every theme in themes.js. Usage: node contrast.js
const THEMES = require('./themes.js');
function parse(c) {
  if (c.startsWith('#')) { const n = parseInt(c.slice(1), 16); return [n >> 16 & 255, n >> 8 & 255, n & 255, 1]; }
  const m = c.match(/rgba?\(([^)]+)\)/)[1].split(',').map(Number); return [m[0], m[1], m[2], m[3] ?? 1];
}
function over(fg, bg) { const [r, g, b, a] = parse(fg), [R, G, B] = typeof bg === 'string' ? parse(bg) : bg;
  return [r * a + R * (1 - a), g * a + G * (1 - a), b * a + B * (1 - a)]; }
function lum([r, g, b]) { return [r, g, b].map(v => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; })
  .reduce((s, v, i) => s + v * [0.2126, 0.7152, 0.0722][i], 0); }
function ratio(a, b) { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); }
function lab([r, g, b]) { // sRGB -> CIELAB (D65)
  const l = [r, g, b].map(v => { v /= 255; return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  const X = (l[0] * .4124 + l[1] * .3576 + l[2] * .1805) / .95047, Y = l[0] * .2126 + l[1] * .7152 + l[2] * .0722,
    Z = (l[0] * .0193 + l[1] * .1192 + l[2] * .9505) / 1.08883;
  const f = t => t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116;
  return [116 * f(Y) - 16, 500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z))]; }
const dE = (a, b) => { const p = lab(a), q = lab(b); return Math.hypot(p[0] - q[0], p[1] - q[1], p[2] - q[2]); };
const rows = [];
const only = process.argv.slice(2);
for (const [key, t] of Object.entries(THEMES)) {
  if (only.length && !only.includes(key)) continue;
  const bg = parse(t.bg).slice(0, 3), surf = over(t.surface, bg), tint = over(t.tint, bg), chip = over(t.chip, bg);
  const c = (fg, base) => ratio(over(fg, base), base).toFixed(1);
  const r = {
    theme: key,
    'text/bg': c(t.text, bg), 'heading/bg': c(t.heading || t.text, bg), 'text/card': c(t.text, surf), 'text2/bg': c(t.text2, bg), 'text2/card': c(t.text2, surf),
    'text2/chip': c(t.text2, chip), 'btn label/tint': c(t.tintText, tint),
    'onAccent/accent': ratio(parse(t.onAccent), parse(t.accent)).toFixed(1),
    'accent/bg': c(t.accent, bg),
    'red/white chk ΔE': dE(parse(t.rFill), parse(t.wFill)).toFixed(0),
    'red/white chk L-ratio': ratio(parse(t.rFill), parse(t.wFill)).toFixed(1),
    'red/surface': ratio(parse(t.rFill), parse(t.playBot)).toFixed(1),
    'white/surface': ratio(parse(t.wFill), parse(t.playBot)).toFixed(1),
    'red/point ΔE': dE(parse(t.rFill), parse(t.tri)).toFixed(0),
    'hl/surface': ratio(parse(t.hl), parse(t.playBot)).toFixed(1),
  };
  rows.push(r);
}
const cols = Object.keys(rows[0]);
console.log('| ' + cols.join(' | ') + ' |\n|' + cols.map(() => '---').join('|') + '|');
for (const r of rows) console.log('| ' + cols.map(k => r[k]).join(' | ') + ' |');
