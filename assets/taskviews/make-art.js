// Renders the task-view art to transparent PNGs, next to this file.
// Needs @resvg/resvg-js (npm i @resvg/resvg-js in a scratch folder, then
// NODE_PATH=<that folder>/node_modules node make-art.js).
const { Resvg } = require('@resvg/resvg-js');
const fs = require('fs');
const OUT = __dirname + '/';
fs.mkdirSync(OUT, { recursive: true });

const INK = '#0E1015';
const render = (name, w, h, body) => {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">${body}</svg>`;
  
  const png = new Resvg(svg, { font: { loadSystemFonts: true, defaultFontFamily: 'Arial Black' } }).render().asPng();
  fs.writeFileSync(OUT + name + '.png', png);
};

const screw = (x, y, r = 13) => `
  <circle cx="${x}" cy="${y + 2}" r="${r}" fill="#000" opacity=".35"/>
  <circle cx="${x}" cy="${y}" r="${r}" fill="url(#screw)" stroke="${INK}" stroke-width="3"/>
  <path d="M${x - r * 0.6} ${y + r * 0.25} L${x + r * 0.6} ${y - r * 0.25}" stroke="#2B3038" stroke-width="4" stroke-linecap="round"/>`;
const screwDef = `<radialGradient id="screw" cx=".35" cy=".3" r=".8"><stop offset="0" stop-color="#E9EDF2"/><stop offset=".6" stop-color="#9AA3AF"/><stop offset="1" stop-color="#5C6470"/></radialGradient>`;
const steelDef = (id, a = '#6E7889', b = '#3E4552') =>
  `<linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient>`;
const hazardDef = (id, w = 26) =>
  `<pattern id="${id}" width="${w * 2}" height="${w * 2}" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
     <rect width="${w * 2}" height="${w * 2}" fill="#FFC21A"/><rect width="${w}" height="${w * 2}" fill="#16181D"/></pattern>`;
const annulus = (cx, cy, R, r) =>
  `M${cx - R} ${cy} a${R} ${R} 0 1 0 ${2 * R} 0 a${R} ${R} 0 1 0 ${-2 * R} 0 Z M${cx - r} ${cy} a${r} ${r} 0 1 1 ${2 * r} 0 a${r} ${r} 0 1 1 ${-2 * r} 0 Z`;

// ---------- Alarm Killswitch ----------
// Plate 480x560: button well centred at (240,232), label below.
{
  const cx = 240, cy = 232;
  render('ks_plate', 480, 560, `
  <defs>${steelDef('steel')}${screwDef}${hazardDef('haz', 22)}
    <radialGradient id="well" cx=".5" cy=".45" r=".6"><stop offset="0" stop-color="#262A33"/><stop offset="1" stop-color="#0B0D11"/></radialGradient>
    <linearGradient id="label" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFD54A"/><stop offset="1" stop-color="#E9A90C"/></linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient>
  </defs>
  <rect x="10" y="16" width="460" height="536" rx="46" fill="#000" opacity=".35"/>
  <rect x="10" y="8" width="460" height="536" rx="46" fill="url(#steel)" stroke="${INK}" stroke-width="8"/>
  <rect x="22" y="20" width="436" height="512" rx="36" fill="url(#sheen)"/>
  <rect x="24" y="22" width="432" height="508" rx="36" fill="none" stroke="#fff" stroke-opacity=".18" stroke-width="3"/>
  ${screw(52, 50)}${screw(428, 50)}${screw(52, 500)}${screw(428, 500)}
  <circle cx="${cx}" cy="${cy + 6}" r="196" fill="#000" opacity=".3"/>
  <path d="${annulus(cx, cy, 192, 158)}" fill="url(#haz)" fill-rule="evenodd"/>
  <circle cx="${cx}" cy="${cy}" r="192" fill="none" stroke="${INK}" stroke-width="8"/>
  <circle cx="${cx}" cy="${cy}" r="158" fill="#1A1D24" stroke="${INK}" stroke-width="6"/>
  <circle cx="${cx}" cy="${cy}" r="128" fill="url(#well)" stroke="#000" stroke-opacity=".6" stroke-width="4"/>
  <rect x="70" y="440" width="340" height="70" rx="14" fill="${INK}"/>
  <rect x="76" y="444" width="328" height="58" rx="10" fill="url(#label)"/>
  <text x="240" y="485" text-anchor="middle" font-family="Arial Black" font-size="34" fill="${INK}" letter-spacing="1">PRESS &amp; HOLD</text>`);

  render('ks_button', 256, 256, `
  <defs>
    <radialGradient id="cap" cx=".38" cy=".3" r=".75"><stop offset="0" stop-color="#FF7A6B"/><stop offset=".45" stop-color="#E5261F"/><stop offset="1" stop-color="#8A0B0A"/></radialGradient>
    <linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".75"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
  </defs>
  <circle cx="128" cy="134" r="118" fill="#000" opacity=".45"/>
  <circle cx="128" cy="128" r="118" fill="#6A0807" stroke="${INK}" stroke-width="7"/>
  <circle cx="128" cy="122" r="106" fill="url(#cap)"/>
  <ellipse cx="112" cy="72" rx="68" ry="36" fill="url(#gloss)"/>
  <text x="128" y="152" text-anchor="middle" font-family="Arial Black" font-size="60" fill="#5A0606" opacity=".7">KILL</text>
  <text x="128" y="147" text-anchor="middle" font-family="Arial Black" font-size="60" fill="#FFF4F2">KILL</text>`);

  // Beacon: chrome base, red glass dome, cage. Lit/dark is ImageColor3 in code.
  render('siren', 256, 256, `
  <defs>
    <linearGradient id="chrome" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#4C535E"/><stop offset=".3" stop-color="#D9DEE5"/><stop offset=".6" stop-color="#8D96A3"/><stop offset="1" stop-color="#3A4049"/></linearGradient>
    <linearGradient id="dome" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#A3100D"/><stop offset=".35" stop-color="#FF5A47"/><stop offset=".55" stop-color="#FF2A1F"/><stop offset="1" stop-color="#7A0807"/></linearGradient>
    <radialGradient id="core" cx=".5" cy=".55" r=".5"><stop offset="0" stop-color="#FFE9C9"/><stop offset="1" stop-color="#FFE9C9" stop-opacity="0"/></radialGradient>
  </defs>
  <path d="M58 140 Q58 34 128 34 Q198 34 198 140 Z" fill="url(#dome)" stroke="${INK}" stroke-width="7"/>
  <ellipse cx="128" cy="112" rx="40" ry="46" fill="url(#core)" opacity=".8"/>
  <path d="M88 66 Q96 50 112 46" stroke="#fff" stroke-opacity=".7" stroke-width="9" stroke-linecap="round" fill="none"/>
  <g stroke="${INK}" stroke-width="6" fill="none" opacity=".85">
    <path d="M128 36 L128 140"/><path d="M92 46 Q80 90 84 140"/><path d="M164 46 Q176 90 172 140"/>
    <path d="M62 96 Q128 84 194 96"/></g>
  <rect x="40" y="136" width="176" height="34" rx="8" fill="url(#chrome)" stroke="${INK}" stroke-width="7"/>
  <rect x="58" y="168" width="140" height="44" rx="6" fill="url(#chrome)" stroke="${INK}" stroke-width="7"/>
  <rect x="70" y="180" width="116" height="8" rx="4" fill="${INK}" opacity=".35"/>`);
}

// ---------- Shared pieces ----------
render('glow', 256, 256, `<defs><radialGradient id="g"><stop offset="0" stop-color="#fff" stop-opacity="1"/><stop offset=".35" stop-color="#fff" stop-opacity=".55"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient></defs><circle cx="128" cy="128" r="128" fill="url(#g)"/>`);

// Lamp: dark bezel, near-white glass - ImageColor3 tints the glass.
render('lamp', 128, 128, `
  <defs><radialGradient id="glass" cx=".4" cy=".35" r=".7"><stop offset="0" stop-color="#FFFFFF"/><stop offset=".6" stop-color="#D8D8D8"/><stop offset="1" stop-color="#8E8E8E"/></radialGradient>
  <linearGradient id="bez" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5A6270"/><stop offset="1" stop-color="#1C2027"/></linearGradient></defs>
  <circle cx="64" cy="64" r="60" fill="url(#bez)" stroke="${INK}" stroke-width="6"/>
  <circle cx="64" cy="64" r="44" fill="url(#glass)" stroke="${INK}" stroke-width="4"/>
  <ellipse cx="52" cy="46" rx="18" ry="11" fill="#fff" opacity=".85"/>`);

// Chunky button, neutral so ImageColor3 picks the colour; 9-sliced in code
// (SliceCenter 48,40,208,88 on this 256x136 source).
render('button', 256, 136, `
  <defs><linearGradient id="face" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#C9C9C9"/></linearGradient>
  <linearGradient id="gl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".9"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient></defs>
  <rect x="4" y="12" width="248" height="120" rx="36" fill="${INK}"/>
  <rect x="10" y="18" width="236" height="106" rx="30" fill="#6E6E6E"/>
  <rect x="10" y="10" width="236" height="96" rx="30" fill="url(#face)"/>
  <rect x="30" y="16" width="196" height="30" rx="15" fill="url(#gl)" opacity=".8"/>
  <rect x="4" y="4" width="248" height="128" rx="36" fill="none" stroke="${INK}" stroke-width="7"/>`);

// ---------- Reactor Sync ----------
// Gauge 640x440. Pivot (320,330); the arc spans -75..+75 degrees from up,
// radius 230 (ticks are drawn in code, a groove is drawn here).
{
  const px = 320, py = 330, R = 230;
  const pt = (deg, r) => [px + r * Math.sin(deg * Math.PI / 180), py - r * Math.cos(deg * Math.PI / 180)];
  const arc = (r, a0 = -75, a1 = 75) => { const [x0, y0] = pt(a0, r), [x1, y1] = pt(a1, r); return `M${x0} ${y0} A${r} ${r} 0 0 1 ${x1} ${y1}`; };
  let scale = '';
  for (let i = 0; i <= 10; i++) {
    const a = -75 + i * 15, [x0, y0] = pt(a, R - 46), [x1, y1] = pt(a, R - (i % 5 === 0 ? 72 : 60));
    scale += `<line x1="${x0}" y1="${y0}" x2="${x1}" y2="${y1}" stroke="#7FA6C2" stroke-width="${i % 5 === 0 ? 5 : 3}" stroke-linecap="round"/>`;
  }
  const tre = (x, y, s) => { let p = ''; for (let k = 0; k < 3; k++) { const r0 = -90 + k * 120; p += `<path d="M${x} ${y} L${x + s * Math.cos((r0 - 30) * Math.PI / 180)} ${y + s * Math.sin((r0 - 30) * Math.PI / 180)} A${s} ${s} 0 0 1 ${x + s * Math.cos((r0 + 30) * Math.PI / 180)} ${y + s * Math.sin((r0 + 30) * Math.PI / 180)} Z" fill="${INK}"/>`; } return p + `<circle cx="${x}" cy="${y}" r="${s * 0.22}" fill="#FFC21A" stroke="${INK}" stroke-width="4"/>`; };
  render('gauge', 640, 440, `
  <defs>${steelDef('steel', '#717C8E', '#3B424F')}${screwDef}
    <radialGradient id="face" cx=".5" cy=".85" r=".9"><stop offset="0" stop-color="#1D3346"/><stop offset="1" stop-color="#0A121A"/></radialGradient>
    <linearGradient id="glass" x1="0" y1="0" x2=".6" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset=".45" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <linearGradient id="plaque" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFD54A"/><stop offset="1" stop-color="#E9A90C"/></linearGradient>
  </defs>
  <rect x="8" y="16" width="624" height="420" rx="48" fill="#000" opacity=".35"/>
  <rect x="8" y="8" width="624" height="420" rx="48" fill="url(#steel)" stroke="${INK}" stroke-width="8"/>
  <rect x="22" y="22" width="596" height="392" rx="38" fill="none" stroke="#fff" stroke-opacity=".18" stroke-width="3"/>
  ${screw(50, 48)}${screw(590, 48)}${screw(50, 388)}${screw(590, 388)}
  <path d="M${px - 282} ${py + 30} A282 282 0 0 1 ${px + 282} ${py + 30} Z" fill="${INK}"/>
  <path d="M${px - 270} ${py + 22} A270 270 0 0 1 ${px + 270} ${py + 22} Z" fill="url(#face)"/>
  <path d="${arc(R)}" fill="none" stroke="#050A0F" stroke-width="40" stroke-linecap="round"/>
  <path d="${arc(R)}" fill="none" stroke="#16222D" stroke-width="32" stroke-linecap="round"/>
  ${scale}
  <path d="M${px - 270} ${py + 22} A270 270 0 0 1 ${px + 270} ${py + 22} Z" fill="url(#glass)"/>
  <rect x="${px - 150}" y="${py + 34}" width="300" height="52" rx="12" fill="${INK}"/>
  <rect x="${px - 145}" y="${py + 38}" width="290" height="44" rx="9" fill="url(#plaque)"/>
  ${tre(px - 118, py + 60, 17)}${tre(px + 118, py + 60, 17)}
  <text x="${px}" y="${py + 71}" text-anchor="middle" font-family="Arial Black" font-size="26" fill="${INK}">CORE OUTPUT</text>`);

  // Needle: centred on the image so Rotation pivots on the hub.
  render('needle', 64, 480, `
  <defs><linearGradient id="n" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#FF9A3C"/><stop offset=".5" stop-color="#FFE3B0"/><stop offset="1" stop-color="#E8560F"/></linearGradient>
  <radialGradient id="hub" cx=".4" cy=".35" r=".7"><stop offset="0" stop-color="#E9EDF2"/><stop offset="1" stop-color="#4E5663"/></radialGradient></defs>
  <path d="M32 24 L44 240 L20 240 Z" fill="url(#n)" stroke="${INK}" stroke-width="5" stroke-linejoin="round"/>
  <circle cx="32" cy="240" r="26" fill="url(#hub)" stroke="${INK}" stroke-width="6"/>
  <circle cx="32" cy="240" r="8" fill="${INK}"/>`);
}

// ---------- Airlock Cycle ----------
// Corridor 640x300: channel x 46..594, y 50..250; door and lights in code.
render('airlock_track', 640, 300, `
  <defs>${steelDef('steel', '#717C8E', '#3B424F')}${screwDef}${hazardDef('haz', 12)}
    <linearGradient id="chan" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#03060A"/><stop offset=".2" stop-color="#101A24"/><stop offset=".8" stop-color="#101A24"/><stop offset="1" stop-color="#03060A"/></linearGradient>
    <pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse"><path d="M40 0 L0 0 0 40" stroke="#1B2A38" stroke-width="2" fill="none"/></pattern></defs>
  <rect x="8" y="14" width="624" height="280" rx="44" fill="#000" opacity=".35"/>
  <rect x="8" y="6" width="624" height="280" rx="44" fill="url(#steel)" stroke="${INK}" stroke-width="8"/>
  <rect x="22" y="20" width="596" height="252" rx="32" fill="none" stroke="#fff" stroke-opacity=".18" stroke-width="3"/>
  <rect x="40" y="44" width="560" height="212" rx="16" fill="${INK}"/>
  <rect x="46" y="50" width="548" height="200" rx="11" fill="url(#chan)"/>
  <rect x="46" y="50" width="548" height="200" fill="url(#grid)" opacity=".8"/>
  <rect x="46" y="50" width="548" height="14" fill="url(#haz)"/><rect x="46" y="236" width="548" height="14" fill="url(#haz)"/>
  <line x1="46" y1="64" x2="594" y2="64" stroke="${INK}" stroke-width="4"/><line x1="46" y1="236" x2="594" y2="236" stroke="${INK}" stroke-width="4"/>
  ${screw(26, 150, 9)}${screw(614, 150, 9)}`);

// Door leaf: one half of the airlock; code mirrors it for the other half.
render('airlock_door', 96, 220, `
  <defs><linearGradient id="d" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#B9C3D0"/><stop offset="1" stop-color="#7C8798"/></linearGradient>
  ${hazardDef('haz', 10)}
  <radialGradient id="port" cx=".4" cy=".35" r=".7"><stop offset="0" stop-color="#7FD3FF"/><stop offset="1" stop-color="#1E4E78"/></radialGradient></defs>
  <rect x="4" y="4" width="88" height="212" rx="10" fill="url(#d)" stroke="${INK}" stroke-width="7"/>
  <rect x="70" y="8" width="18" height="204" fill="url(#haz)"/>
  <line x1="70" y1="8" x2="70" y2="212" stroke="${INK}" stroke-width="4"/>
  <circle cx="38" cy="78" r="20" fill="url(#port)" stroke="${INK}" stroke-width="6"/>
  <ellipse cx="32" cy="70" rx="7" ry="4" fill="#fff" opacity=".8"/>
  <rect x="18" y="128" width="40" height="10" rx="5" fill="${INK}" opacity=".45"/>
  <rect x="18" y="148" width="40" height="10" rx="5" fill="${INK}" opacity=".45"/>`);
// ---------- Shared backing plate ----------
// 256x256, 9-sliced in code (SliceCenter 72,72,184,184): screws in the corners.
render('plate', 256, 256, `
  <defs>${steelDef('steel')}${screwDef}
    <linearGradient id="sheen" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".2"/><stop offset=".5" stop-color="#fff" stop-opacity="0"/></linearGradient></defs>
  <rect x="6" y="12" width="244" height="238" rx="40" fill="#000" opacity=".35"/>
  <rect x="6" y="6" width="244" height="238" rx="40" fill="url(#steel)" stroke="${INK}" stroke-width="8"/>
  <rect x="18" y="18" width="220" height="214" rx="30" fill="url(#sheen)"/>
  <rect x="18" y="18" width="220" height="214" rx="30" fill="none" stroke="#fff" stroke-opacity=".18" stroke-width="3"/>
  ${screw(42, 42, 11)}${screw(214, 42, 11)}${screw(42, 208, 11)}${screw(214, 208, 11)}`);

// Recessed dark well, 9-sliced (SliceCenter 40,40,88,88): an LCD bezel or a slot.
render('well', 128, 128, `
  <defs><linearGradient id="w" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#05070A"/><stop offset="1" stop-color="#1A1F27"/></linearGradient></defs>
  <rect x="4" y="4" width="120" height="120" rx="22" fill="url(#w)" stroke="${INK}" stroke-width="6"/>
  <rect x="8" y="10" width="112" height="110" rx="18" fill="none" stroke="#fff" stroke-opacity=".1" stroke-width="3"/>`);

// ---------- Breaker Sequence ----------
// Module 176x256 (ref 88x128): lamp socket at (88,40), lever slot centre (88,138), plate y 214..246.
render('breaker', 176, 256, `
  <defs><linearGradient id="body" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#2A2F38"/><stop offset=".5" stop-color="#3E4553"/><stop offset="1" stop-color="#22262E"/></linearGradient>
  <linearGradient id="slot" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#020304"/><stop offset="1" stop-color="#151A21"/></linearGradient>
  <linearGradient id="label" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#E9EDF2"/><stop offset="1" stop-color="#B8C0CB"/></linearGradient>
  ${hazardDef('haz', 8)}</defs>
  <rect x="6" y="10" width="164" height="242" rx="20" fill="#000" opacity=".35"/>
  <rect x="6" y="4" width="164" height="242" rx="20" fill="url(#body)" stroke="${INK}" stroke-width="7"/>
  <rect x="16" y="12" width="144" height="4" rx="2" fill="#fff" opacity=".18"/>
  <circle cx="88" cy="40" r="26" fill="#11141A" stroke="${INK}" stroke-width="5"/>
  <rect x="58" y="78" width="60" height="120" rx="14" fill="${INK}"/>
  <rect x="62" y="82" width="52" height="112" rx="11" fill="url(#slot)"/>
  <rect x="62" y="82" width="52" height="10" fill="url(#haz)" opacity=".9"/>
  <text x="88" y="76" text-anchor="middle" font-family="Arial Black" font-size="13" fill="#9AA6B5">ON</text>
  <text x="88" y="210" text-anchor="middle" font-family="Arial Black" font-size="13" fill="#9AA6B5">OFF</text>
  <rect x="34" y="214" width="108" height="26" rx="6" fill="${INK}"/>
  <rect x="37" y="217" width="102" height="20" rx="4" fill="url(#label)"/>`);

// Lever 72x80: a chunky toggle grip, slid up (ON) or down (OFF) in code.
render('lever', 72, 80, `
  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#AEB6C2"/></linearGradient></defs>
  <rect x="4" y="6" width="64" height="70" rx="14" fill="#000" opacity=".4"/>
  <rect x="4" y="2" width="64" height="70" rx="14" fill="url(#g)" stroke="${INK}" stroke-width="6"/>
  <rect x="16" y="20" width="40" height="6" rx="3" fill="${INK}" opacity=".35"/>
  <rect x="16" y="33" width="40" height="6" rx="3" fill="${INK}" opacity=".35"/>
  <rect x="16" y="46" width="40" height="6" rx="3" fill="${INK}" opacity=".35"/>
  <rect x="12" y="8" width="48" height="6" rx="3" fill="#fff" opacity=".8"/>`);

// ---------- Fuse Rewire ----------
// Tiles 128x128 (ref 64): the socket and the fuse; amp label plate drawn in code at y 92..120.
render('socket', 128, 128, `
  <defs><linearGradient id="t" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6E7889"/><stop offset="1" stop-color="#3E4552"/></linearGradient>
  <linearGradient id="cu" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#8A4B1C"/><stop offset=".45" stop-color="#F2A86A"/><stop offset="1" stop-color="#9C561F"/></linearGradient></defs>
  <rect x="4" y="8" width="120" height="118" rx="20" fill="#000" opacity=".35"/>
  <rect x="4" y="4" width="120" height="118" rx="20" fill="url(#t)" stroke="${INK}" stroke-width="6"/>
  <rect x="22" y="16" width="84" height="70" rx="12" fill="${INK}"/>
  <rect x="26" y="20" width="76" height="62" rx="9" fill="#0C1016"/>
  <rect x="32" y="28" width="16" height="46" rx="5" fill="url(#cu)" stroke="${INK}" stroke-width="3"/>
  <rect x="80" y="28" width="16" height="46" rx="5" fill="url(#cu)" stroke="${INK}" stroke-width="3"/>
  <circle cx="64" cy="51" r="6" fill="#1D242E"/>`);

render('fuse', 128, 128, `
  <defs><linearGradient id="t" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6E7889"/><stop offset="1" stop-color="#3E4552"/></linearGradient>
  <linearGradient id="cap" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F4F6F9"/><stop offset=".5" stop-color="#A9B2BF"/><stop offset="1" stop-color="#5E6774"/></linearGradient>
  <linearGradient id="glass" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#E8F6FF" stop-opacity=".95"/><stop offset=".5" stop-color="#9FC9E6" stop-opacity=".7"/><stop offset="1" stop-color="#5C88A8" stop-opacity=".9"/></linearGradient></defs>
  <rect x="4" y="8" width="120" height="118" rx="20" fill="#000" opacity=".35"/>
  <rect x="4" y="4" width="120" height="118" rx="20" fill="url(#t)" stroke="${INK}" stroke-width="6"/>
  <rect x="34" y="30" width="60" height="40" rx="8" fill="url(#glass)" stroke="${INK}" stroke-width="4"/>
  <path d="M38 50 Q52 38 64 50 T90 50" stroke="#E8590C" stroke-width="3" fill="none"/>
  <rect x="38" y="35" width="52" height="6" rx="3" fill="#fff" opacity=".7"/>
  <rect x="14" y="26" width="24" height="48" rx="7" fill="url(#cap)" stroke="${INK}" stroke-width="4"/>
  <rect x="90" y="26" width="24" height="48" rx="7" fill="url(#cap)" stroke="${INK}" stroke-width="4"/>`);

// ---------- Pressure Valve ----------
// A red mushroom cap with no lettering; the view writes PUMP over it.
render('cap', 256, 256, `
  <defs>
    <radialGradient id="cap" cx=".38" cy=".3" r=".75"><stop offset="0" stop-color="#FF7A6B"/><stop offset=".45" stop-color="#E5261F"/><stop offset="1" stop-color="#8A0B0A"/></radialGradient>
    <linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".75"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
  </defs>
  <circle cx="128" cy="134" r="118" fill="#000" opacity=".45"/>
  <circle cx="128" cy="128" r="118" fill="#6A0807" stroke="${INK}" stroke-width="7"/>
  <circle cx="128" cy="122" r="106" fill="url(#cap)"/>
  <ellipse cx="112" cy="72" rx="68" ry="36" fill="url(#gloss)"/>`);

console.log('ok', fs.readdirSync(OUT).filter(f => f.endsWith('.png')).join(' '));
