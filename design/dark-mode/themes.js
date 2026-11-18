// Dark-mode sketch tokens for Tavlo (#191). One object per direction; `light` is
// today's app (CaramelPalette / ChromeTheme / ChromeKit) as the reference.
// Shared by mock.html (rendering) and contrast.js (WCAG checks).
(function (root) {
  // Board + checker tokens shared by every theme unless overridden.
  const caramelBoard = {
    frameTop: '#e8c089', frameMid: '#d4a466', frameBot: '#a87a3e', frameHi: '#f4d6a3',
    playTop: '#8a4a22', playBot: '#6a361a',
    tri: '#fbeed1', triStroke: '#2a1408', pip: '#fff5d8', barLine: '#2a1408',
    diamondBorder: '#2a1408', diamondFill: '#fbeed1', tileDark: '#8a4a22', tileLight: '#f0dab0',
    diamondDot: '#1a0a04', trayFill: '#2a1408', trayOpacity: 0.22,
    wFill: '#f1e6c8', wHi: '#fbf3d8', wRing: '#a8915f', wEdge: '#5a4828',
    rFill: '#c0392b', rHi: '#dc5040', rRing: '#5e160b', rEdge: '#2a0a04',
    dieFace: '#f5ead0', diePip: '#2a1408',
    hl: '#f4b400', hlFill: '#f6c623', hlEdge: '#7a5400', hlBest: '#2f7fd1', hlBoth: '#3fa64a',
    lastMove: '#2f7fd1',
    boardShadow: 'none',
  };

  const THEMES = {
    light: {
      name: 'Today (light)', short: 'Light reference',
      blurb: 'The shipping light theme: caramel chrome on a warm paper page.',
      dark: false,
      bg: '#ece6dc', surface: '#f6f0e3', elevated: '#fdf9f1', separator: 'rgba(58,37,16,0.12)',
      text: '#3a2510', text2: 'rgba(58,37,16,0.72)', icon: 'rgba(58,37,16,0.75)',
      accent: '#a87a3e', onAccent: '#ffffff', tint: 'rgba(168,122,62,0.16)', tintText: '#3a2510',
      chip: 'rgba(58,37,16,0.06)', cardShadow: '0 3px 10px rgba(0,0,0,0.10)',
      destructive: '#b05a44', statusInk: '#000000', wordmark: '#3a2510', progress: '#6a8a4a',
      chromeWhite: '#fbeed1', chromeRed: '#a83a2a', chromeDiscStroke: 'rgba(58,37,16,0.35)',
      ...caramelBoard,
    },

    // A — warm, but deep and saturated instead of mid-grey-brown.
    espresso: {
      name: 'A · Espresso', short: 'Espresso',
      blurb: 'Near-black roasted brown chrome, crema-cream type, caramel board slightly toned down.',
      dark: true,
      bg: '#100804', surface: '#1e110a', elevated: '#2a1910', separator: 'rgba(255,214,160,0.10)',
      text: '#f8ecd6', text2: 'rgba(248,236,214,0.70)', icon: 'rgba(248,236,214,0.80)',
      accent: '#e8a24a', onAccent: '#1c0f05', tint: 'rgba(232,162,74,0.15)', tintText: '#f8ecd6',
      chip: 'rgba(255,226,180,0.07)', cardShadow: '0 0 0 1px rgba(255,214,160,0.06)',
      destructive: '#f08b6d', statusInk: '#ffffff', wordmark: '#f3c27a', progress: '#8fbf63',
      chromeWhite: '#f1e6c8', chromeRed: '#d84a36', chromeDiscStroke: 'rgba(0,0,0,0.5)',
      ...caramelBoard,
      frameTop: '#d7a868', frameMid: '#bd8a4b', frameBot: '#8c5f2a', frameHi: '#ecc78c',
      playTop: '#7e3f1b', playBot: '#5c2a12',
      tri: '#f4e3c0', pip: '#fff1cf', diamondFill: '#f4e3c0', triStroke: '#1c0d05',
      rFill: '#cc3a2a', rHi: '#e85844',
      dieFace: '#f6ead0',
    },

    // B — cool blue-black chrome, warm caramel board as the focal point.
    night: {
      name: 'B · Night table', short: 'Night table',
      blurb: 'Cool ink-blue chrome with crisp white type; the caramel board stays warm and becomes the glowing centre.',
      dark: true,
      bg: '#0a0e15', surface: '#141a24', elevated: '#1d2531', separator: 'rgba(170,190,220,0.12)',
      text: '#eef2f7', text2: '#a3afc0', icon: '#c9d2de',
      accent: '#eaa74d', onAccent: '#1a1006', tint: 'rgba(170,190,220,0.12)', tintText: '#eef2f7',
      chip: 'rgba(170,190,220,0.08)', cardShadow: '0 0 0 1px rgba(170,190,220,0.07)',
      destructive: '#ff8a70', statusInk: '#ffffff', wordmark: '#f0b860', progress: '#7cc88a',
      chromeWhite: '#f1e6c8', chromeRed: '#e0503c', chromeDiscStroke: 'rgba(0,0,0,0.5)',
      ...caramelBoard,
      frameTop: '#e0b476', frameMid: '#c99858', frameBot: '#996a32', frameHi: '#f2d29e',
      tri: '#f7e8c8', diamondFill: '#f7e8c8',
      boardShadow: '0 -18px 40px rgba(234,167,77,0.10)',
    },

    // C — OLED black; the board itself goes dark walnut with luminous cream points.
    walnut: {
      name: 'C · Walnut (OLED)', short: 'Walnut',
      blurb: 'True-black screen; the board darkens to walnut with cream points that glow, so nothing glares at night.',
      dark: true,
      bg: '#000000', surface: '#141210', elevated: '#1f1c19', separator: 'rgba(255,240,220,0.12)',
      text: '#f5efe6', text2: 'rgba(245,239,230,0.66)', icon: 'rgba(245,239,230,0.80)',
      accent: '#e09a42', onAccent: '#140a02', tint: 'rgba(255,240,220,0.10)', tintText: '#f5efe6',
      chip: 'rgba(255,240,220,0.08)', cardShadow: '0 0 0 1px rgba(255,240,220,0.07)',
      destructive: '#ff8d72', statusInk: '#ffffff', wordmark: '#f5efe6', progress: '#86c46c',
      chromeWhite: '#f3e8cc', chromeRed: '#e04a35', chromeDiscStroke: 'rgba(255,255,255,0.25)',
      ...caramelBoard,
      frameTop: '#6e4526', frameMid: '#553219', frameBot: '#341c0c', frameHi: '#c8904e',
      playTop: '#1f110a', playBot: '#140a05',
      tri: '#ead09a', triStroke: '#0a0503', pip: '#fff0c8', barLine: '#a8743e',
      diamondBorder: '#0a0503', diamondFill: '#ead09a', tileDark: '#6e4526', tileLight: '#d9b77c',
      diamondDot: '#0a0503', trayFill: '#000000', trayOpacity: 0.45,
      wFill: '#f4e9cd', wHi: '#fffaea', wRing: '#a8915f', wEdge: '#3a2d18',
      rFill: '#d7412f', rHi: '#f0604c', rRing: '#6a1a0d', rEdge: '#1a0603',
      dieFace: '#efe2c2',
      hlBest: '#4a9bf0', hlBoth: '#4cc25a', lastMove: '#4a9bf0',
    },

    // D — Kafeneio felt: deep bottle-green chrome and a green felt play surface
    // inside the caramel frame.
    felt: {
      name: 'D · Kafeneio felt', short: 'Felt',
      blurb: 'Deep bottle-green chrome and a green felt play surface inside the caramel frame: café-table backgammon.',
      dark: true,
      bg: '#06120d', surface: '#0d231a', elevated: '#143024', separator: 'rgba(170,230,200,0.12)',
      text: '#eef6f1', text2: '#9fbcad', icon: '#c6dcd0',
      accent: '#eaa64c', onAccent: '#1a1006', tint: 'rgba(110,210,160,0.11)', tintText: '#eef6f1',
      chip: 'rgba(170,230,200,0.08)', cardShadow: '0 0 0 1px rgba(170,230,200,0.07)',
      destructive: '#ff8a70', statusInk: '#ffffff', wordmark: '#f0b860', progress: '#eaa64c',
      chromeWhite: '#f1e6c8', chromeRed: '#e0503c', chromeDiscStroke: 'rgba(0,0,0,0.5)',
      ...caramelBoard,
      frameTop: '#d9ab6c', frameMid: '#c08e50', frameBot: '#8e612b', frameHi: '#efcd96',
      playTop: '#1e5a40', playBot: '#143f2c',
      tri: '#f4e6c6', diamondFill: '#f4e6c6', tileDark: '#1e5a40', triStroke: '#0b1f16',
      barLine: '#0b1f16', diamondBorder: '#0b1f16', trayFill: '#0b1f16',
    },
  };

  // ── C refinements (user feedback: keep C's black + walnut board, warm text) ──
  const walnutBoard = {};
  for (const k of Object.keys(THEMES.walnut))
    if (!['name', 'short', 'blurb'].includes(k)) walnutBoard[k] = THEMES.walnut[k];
  const warmText = {
    text: '#f4d7a4', heading: '#f4d7a4', text2: '#cf9f62', icon: '#d9ad72',
    tint: 'rgba(255,190,110,0.10)', tintText: '#f4d7a4', chip: 'rgba(255,190,110,0.08)',
    separator: 'rgba(255,190,110,0.14)', cardShadow: '0 0 0 1px rgba(255,190,110,0.08)',
    wordmark: '#f4d7a4', chromeDiscStroke: 'rgba(255,220,170,0.25)',
  };
  Object.assign(THEMES, {
    c1: { ...walnutBoard, name: 'C1 · Walnut (today’s C)', short: 'C1',
      blurb: 'Reference: true black, neutral near-black surfaces, near-white text.' },
    c2: { ...walnutBoard, ...warmText, name: 'C2 · Black + warm text', short: 'C2',
      blurb: 'True black (#000); cream-caramel text, muted caramel secondary; warm-tinted surfaces.',
      surface: '#16100a', elevated: '#22180f' },
    c3: { ...walnutBoard, ...warmText, name: 'C3 · Espresso + warm text', short: 'C3',
      blurb: 'Same warm text on espresso-black (#0e0805) with clear surface steps: the LCD-friendly one.',
      bg: '#0e0805', surface: '#1d130b', elevated: '#2b1c10',
      tint: 'rgba(255,190,110,0.11)', chip: 'rgba(255,190,110,0.09)' },
    c4: { ...walnutBoard, ...warmText, name: 'C4 · Balanced', short: 'C4',
      blurb: 'Near-black espresso (#080402); caramel headings + wordmark, warm-cream body, tan captions.',
      bg: '#080402', surface: '#18100a', elevated: '#25190f',
      heading: '#f2b866', wordmark: '#f2b866', text: '#f7e6c8', tintText: '#f7e6c8',
      text2: '#c99c64', icon: '#e0b47a' },
  });

  if (typeof module !== 'undefined') module.exports = THEMES;
  else root.THEMES = THEMES;
})(this);
