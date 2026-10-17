// Renders the reward pictures for the season pass tiles and the claim
// pop-up: coin piles (by amount), a badge per power-up, and the items
// with no 3D model (Founder's skin, trail and emote). 512x512
// transparent PNGs into pictures/ next to this file.
//
// Every picture gets the same finish as make-wear-pictures.py gives the
// Meshy renders, a thick ink outline and a soft drop shadow, so 3D and
// drawn items sit together on the gold and blue tiles. The art itself
// is shaded (top light, gloss, crease shadows) to match those renders
// rather than flat clip-art. Same setup as assets/taskviews/make-art.js: needs
// @resvg/resvg-js (npm i @resvg/resvg-js in a scratch folder, then
// NODE_PATH=<that folder>/node_modules node make-pictures.js).
const { Resvg } = require('@resvg/resvg-js');
const fs = require('fs');
const OUT = __dirname + '/pictures/';
fs.mkdirSync(OUT, { recursive: true });

const INK = '#1A1030';
const S = 512;

// The outer finish: ink ring (alpha over ~40/255, dilated by `ring`) and
// a shadow 12 below; 10 is make-wear-pictures.py's. A small UI icon
// takes a thicker ring so it survives being drawn at ~20px.
const finish = (ring) => `<filter id="finish" x="-10%" y="-10%" width="120%" height="125%">
  <feComponentTransfer in="SourceAlpha" result="solid"><feFuncA type="discrete" tableValues="0 1 1 1 1 1"/></feComponentTransfer>
  <feMorphology in="solid" operator="dilate" radius="${ring}" result="ring"/>
  <feFlood flood-color="${INK}"/><feComposite in2="ring" operator="in" result="inkRing"/>
  <feOffset in="ring" dy="12" result="drop"/>
  <feFlood flood-color="#000" flood-opacity=".3"/><feComposite in2="drop" operator="in" result="shadow"/>
  <feMerge><feMergeNode in="shadow"/><feMergeNode in="inkRing"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>`;

// `loose` (the sparkles) sits on top without the finish, which would
// swell such small shapes into blobs.
const render = (name, defs, body, loose = '', ring = 10) => {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${S}" height="${S}" viewBox="0 0 ${S} ${S}">
  <defs>${finish(ring)}${defs}</defs><g filter="url(#finish)">${body}</g>${loose}</svg>`;
  fs.writeFileSync(OUT + name + '.png', new Resvg(svg).render().asPng());
  console.log('wrote', name + '.png');
};

// A top-lit vertical gradient from `light` through `mid` to `dark`.
const grad = (id, light, mid, dark) =>
  `<linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${light}"/><stop offset=".5" stop-color="${mid}"/><stop offset="1" stop-color="${dark}"/></linearGradient>`;
// A ball-lit radial gradient, lit from the top left.
const ball = (id, light, mid, dark) =>
  `<radialGradient id="${id}" cx=".38" cy=".3" r=".75"><stop offset="0" stop-color="${light}"/><stop offset=".55" stop-color="${mid}"/><stop offset="1" stop-color="${dark}"/></radialGradient>`;
const GOLD = ['#FFF3B0', '#F7C843', '#B57A12'];
const gloss = (cx, cy, rx, ry, rot = -30, op = 0.7) =>
  `<ellipse cx="${cx}" cy="${cy}" rx="${rx}" ry="${ry}" fill="#FFFFFF" opacity="${op}" transform="rotate(${rot} ${cx} ${cy})"/>`;
const sparkle = (x, y, r, fill = '#FFFFFF') => {
  const p = [];
  for (let i = 0; i < 8; i++) {
    const a = (Math.PI / 4) * i - Math.PI / 2;
    const rr = i % 2 === 0 ? r : r * 0.3;
    p.push(`${(x + Math.cos(a) * rr).toFixed(1)},${(y + Math.sin(a) * rr).toFixed(1)}`);
  }
  const pts = p.join(' ');
  return `<polygon points="${pts}" fill="#000" opacity=".3" transform="translate(0 6)"/><polygon points="${pts}" fill="${fill}" stroke="${INK}" stroke-width="6" stroke-linejoin="round"/>`;
};
const starPts = (x, y, r, inner = 0.45) => {
  const p = [];
  for (let i = 0; i < 10; i++) {
    const a = (Math.PI / 5) * i - Math.PI / 2;
    const rr = i % 2 === 0 ? r : r * inner;
    p.push(`${(x + Math.cos(a) * rr).toFixed(1)},${(y + Math.sin(a) * rr).toFixed(1)}`);
  }
  return p.join(' ');
};

// ===== coins ================================================================
// A coin face-on: rim, inset face, embossed star, gloss.
const coinDefs = `${ball('coinFace', ...GOLD)}${grad('coinRim', '#FFE27A', '#E0A526', '#9A6208')}
  ${grad('coinEdge', '#D99A1E', '#B9790F', '#7E4D05')}`;
const coin = (x, y, r) => `
  <circle cx="${x}" cy="${y}" r="${r}" fill="url(#coinRim)" stroke="${INK}" stroke-width="6"/>
  <circle cx="${x}" cy="${y}" r="${r * 0.76}" fill="url(#coinFace)" stroke="#9A6208" stroke-width="4"/>
  <polygon points="${starPts(x, y + r * 0.03, r * 0.46)}" fill="#C98A14" stroke="#8A5606" stroke-width="3" stroke-linejoin="round"/>
  <polygon points="${starPts(x - r * 0.03, y - r * 0.01, r * 0.42)}" fill="#FFE27A"/>
  ${gloss(x - r * 0.38, y - r * 0.42, r * 0.28, r * 0.13, -35, 0.8)}`;
// A coin lying flat, seen from above at an angle: an ellipse on a thin edge.
const flat = (x, y, r) => `
  <ellipse cx="${x}" cy="${y + r * 0.13}" rx="${r}" ry="${r * 0.42}" fill="url(#coinEdge)" stroke="${INK}" stroke-width="5"/>
  <ellipse cx="${x}" cy="${y}" rx="${r}" ry="${r * 0.42}" fill="url(#coinRim)" stroke="${INK}" stroke-width="5"/>
  <ellipse cx="${x}" cy="${y}" rx="${r * 0.72}" ry="${r * 0.29}" fill="url(#coinFace)" stroke="#9A6208" stroke-width="3"/>
  <ellipse cx="${x - r * 0.3}" cy="${y - r * 0.12}" rx="${r * 0.25}" ry="${r * 0.07}" fill="#FFFFFF" opacity=".7"/>`;
const stack = (x, base, r, n) => {
  let s = '';
  for (let i = 0; i < n; i++) s += flat(x, base - i * r * 0.26, r);
  return s;
};

// 75 and under: a few coins.
render('coins-small', coinDefs, `
  ${stack(200, 400, 92, 3)}
  ${coin(320, 300, 120)}`,
  `${sparkle(110, 190, 30)}${sparkle(440, 140, 24)}`);

// Up to 150: two stacks and a coin in front.
render('coins-stack', coinDefs, `
  ${stack(160, 410, 86, 7)}
  ${stack(330, 360, 86, 5)}
  ${coin(330, 360, 105)}`,
  `${sparkle(90, 120, 28)}${sparkle(455, 160, 26)}${sparkle(250, 70, 20)}`);

// More: a chest spilling over with coins.
{
  const defs = `${coinDefs}${grad('wood', '#C27A3E', '#8E4F22', '#5C2E10')}${grad('lid', '#D08848', '#9B5828', '#6A3514')}
    ${grad('band', '#FFE27A', '#E0A526', '#9A6208')}`;
  render('coins-chest', defs, `
  <path d="M86 238 L426 238 L410 452 C408 466 398 474 384 474 L128 474 C114 474 104 466 102 452 Z" fill="url(#wood)" stroke="${INK}" stroke-width="8" stroke-linejoin="round"/>
  <path d="M100 300 L412 300 M104 390 L408 390" stroke="#4A230A" stroke-width="6" opacity=".55"/>
  <path d="M150 238 L156 474 M356 238 L350 474" stroke="url(#band)" stroke-width="30"/>
  <path d="M150 238 L156 474 M356 238 L350 474" stroke="${INK}" stroke-width="4" opacity=".5"/>
  ${flat(160, 230, 70)}${flat(350, 228, 70)}${flat(255, 205, 78)}${flat(200, 176, 62)}${flat(318, 172, 60)}
  ${coin(256, 132, 70)}${coin(150, 158, 52)}${coin(372, 150, 54)}
  <path d="M60 255 L452 255 L446 290 L66 290 Z" fill="url(#lid)" stroke="${INK}" stroke-width="8" stroke-linejoin="round"/>
  <rect x="222" y="262" width="68" height="84" rx="12" fill="url(#band)" stroke="${INK}" stroke-width="7"/>
  <circle cx="256" cy="295" r="11" fill="${INK}"/><path d="M256 300 L256 324" stroke="${INK}" stroke-width="10" stroke-linecap="round"/>
  ${gloss(120, 262, 30, 7, 0, 0.45)}`,
  `${sparkle(70, 120, 30)}${sparkle(452, 96, 26)}${sparkle(452, 380, 22)}`);
}

// The UI's coin icon (Icons "coin-gold": the balance pill, prize strips,
// payouts): two coins, drawn bold for ~20px.
render('icon-coin', coinDefs, `
  ${coin(200, 210, 150)}
  ${coin(312, 300, 168)}`, '', 26);

// ===== power-ups ============================================================
// A glossy disc in the power-up's store colour with a white symbol, the
// same colour and symbol as its store icon so the two read as one item.
const disc = (id, colour, symbol) => {
  const [light, mid, dark] = colour;
  render(`powerup-${id}`, `${ball('d', light, mid, dark)}${grad('rim', '#FFFFFF', '#E6E1F5', '#9B92B8')}`, `
  <circle cx="256" cy="256" r="206" fill="url(#rim)" stroke="${INK}" stroke-width="8"/>
  <circle cx="256" cy="256" r="174" fill="url(#d)" stroke="${INK}" stroke-width="8"/>
  <path d="M120 180 A150 150 0 0 1 330 100" stroke="#FFFFFF" stroke-width="22" stroke-linecap="round" fill="none" opacity=".45"/>
  <g transform="translate(0 6)" opacity=".35">${symbol.replaceAll('#FFFFFF', '#000000')}</g>
  ${symbol}`);
};
const W = '#FFFFFF';
const sym = (d, extra = '') =>
  `<path d="${d}" fill="${W}" stroke="${INK}" stroke-width="10" stroke-linejoin="round" stroke-linecap="round"/>${extra}`;

disc('sprint-boost', ['#7FC6FF', '#2F7DF0', '#1446A8'],
  sym('M290 120 L170 285 L248 285 L218 400 L346 222 L266 222 Z'));
disc('freeze', ['#C8F4FF', '#3FC3EE', '#1478A8'], `<g stroke-linecap="round">
  <g stroke="${INK}" stroke-width="40">${[0, 60, 120].map((a) => `<path d="M256 140 L256 372" transform="rotate(${a} 256 256)"/>`).join('')}
  ${[0, 60, 120, 180, 240, 300].map((a) => `<path d="M256 170 L226 145 M256 170 L286 145" transform="rotate(${a} 256 256)"/>`).join('')}</g>
  <g stroke="${W}" stroke-width="22">${[0, 60, 120].map((a) => `<path d="M256 140 L256 372" transform="rotate(${a} 256 256)"/>`).join('')}
  ${[0, 60, 120, 180, 240, 300].map((a) => `<path d="M256 170 L226 145 M256 170 L286 145" transform="rotate(${a} 256 256)"/>`).join('')}</g></g>`);
disc('overclock', ['#FFD27A', '#F58A1F', '#B04E08'], `
  <rect x="236" y="106" width="40" height="34" rx="8" fill="${W}" stroke="${INK}" stroke-width="9"/>
  <circle cx="256" cy="268" r="118" fill="${W}" stroke="${INK}" stroke-width="10"/>
  <circle cx="256" cy="268" r="92" fill="none" stroke="#F0E8FF" stroke-width="6"/>
  ${[0, 90, 180, 270].map((a) => `<path d="M256 168 L256 186" stroke="${INK}" stroke-width="9" stroke-linecap="round" transform="rotate(${a} 256 268)"/>`).join('')}
  <path d="M256 268 L256 196 M256 268 L310 296" stroke="${INK}" stroke-width="13" stroke-linecap="round"/>
  <path d="M256 268 L310 296" stroke="#F0412F" stroke-width="7" stroke-linecap="round"/>
  <circle cx="256" cy="268" r="12" fill="${INK}"/>`);
disc('phase-step', ['#9BF2DF', '#22B39A', '#0D6E60'],
  sym('M160 380 L160 245 C160 180 202 132 256 132 C310 132 352 180 352 245 L352 380 L320 352 L288 380 L256 352 L224 380 L192 352 Z',
    `<ellipse cx="220" cy="240" rx="16" ry="24" fill="${INK}"/><ellipse cx="292" cy="240" rx="16" ry="24" fill="${INK}"/>`));
disc('push-trip', ['#FF9AA6', '#EE3B52', '#A3142A'],
  sym('M130 220 L270 220 L270 150 L392 256 L270 362 L270 292 L130 292 Z'));
disc('second-wind', ['#9CF09A', '#2FB84A', '#167026'],
  sym('M216 128 L296 128 L296 216 L384 216 L384 296 L296 296 L296 384 L216 384 L216 296 L128 296 L128 216 L216 216 Z'));
disc('slow-field', ['#D7B2FF', '#9256F0', '#5520A8'], `
  <circle cx="256" cy="256" r="120" fill="${W}" stroke="${INK}" stroke-width="10"/>
  <circle cx="256" cy="256" r="84" fill="#9256F0" stroke="${INK}" stroke-width="8"/>
  <circle cx="256" cy="256" r="52" fill="${W}" stroke="${INK}" stroke-width="8"/>
  <circle cx="256" cy="256" r="20" fill="#9256F0" stroke="${INK}" stroke-width="7"/>`);
disc('task-insight', ['#FFF08A', '#F5C21B', '#B07E06'], `
  <path d="M300 300 L384 384" stroke="${INK}" stroke-width="52" stroke-linecap="round"/>
  <path d="M300 300 L380 380" stroke="#7A4A20" stroke-width="32" stroke-linecap="round"/>
  <circle cx="232" cy="232" r="96" fill="#BFEFFF" stroke="${INK}" stroke-width="12"/>
  <circle cx="232" cy="232" r="96" fill="none" stroke="${W}" stroke-width="16" opacity=".9" transform="scale(.86) translate(38 38)"/>
  ${gloss(200, 196, 32, 16, -40, 0.85)}`);
disc('task-scramble', ['#FF9BE8', '#D63BC0', '#8A167A'], `
  <path d="M196 200 C196 150 226 124 262 124 C304 124 330 152 330 190 C330 236 278 246 278 296 L278 312"
    fill="none" stroke="${INK}" stroke-width="58" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M196 200 C196 150 226 124 262 124 C304 124 330 152 330 190 C330 236 278 246 278 296 L278 312"
    fill="none" stroke="${W}" stroke-width="38" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="278" cy="378" r="30" fill="${W}" stroke="${INK}" stroke-width="10"/>`);
disc('blind', ['#B9B4CC', '#5D5878', '#2C2840'], `
  <path d="M110 256 C160 180 210 156 256 156 C302 156 352 180 402 256 C352 332 302 356 256 356 C210 356 160 332 110 256 Z" fill="${W}" stroke="${INK}" stroke-width="10" stroke-linejoin="round"/>
  <circle cx="256" cy="256" r="58" fill="${INK}"/><circle cx="234" cy="234" r="16" fill="${W}"/>
  <path d="M146 146 L366 366" stroke="${INK}" stroke-width="44" stroke-linecap="round"/>
  <path d="M146 146 L366 366" stroke="#F0412F" stroke-width="24" stroke-linecap="round"/>`);

// ===== cosmetics with no model ==============================================

// Founder's Kit: the purple shirt with a gold F crest, cloth-shaded.
{
  const shirt =
    'M188 82 C212 116 300 116 324 82 L432 132 L476 248 L398 282 L382 246 L382 438 C382 456 368 468 350 468 L162 468 C144 468 130 456 130 438 L130 246 L114 282 L36 248 L80 132 Z';
  render('skin-founder', `
    <linearGradient id="cloth" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#8A6CF5"/><stop offset=".5" stop-color="#5A3BD4"/><stop offset="1" stop-color="#2E1A85"/></linearGradient>
    ${grad('gold', ...GOLD)}`, `
  <path d="${shirt}" fill="url(#cloth)" stroke="${INK}" stroke-width="8" stroke-linejoin="round"/>
  <path d="M130 246 L130 300 M382 246 L382 300" stroke="#1F1160" stroke-width="8" opacity=".5" stroke-linecap="round"/>
  <path d="M160 420 C200 400 230 440 270 418 M300 440 C330 420 350 430 372 420" stroke="#1F1160" stroke-width="7" fill="none" opacity=".45" stroke-linecap="round"/>
  <path d="M96 150 C110 200 120 230 118 262" stroke="#B9A6FF" stroke-width="14" fill="none" opacity=".55" stroke-linecap="round"/>
  <path d="M188 82 C212 130 300 130 324 82" fill="none" stroke="${INK}" stroke-width="26" stroke-linecap="round"/>
  <path d="M188 82 C212 130 300 130 324 82" fill="none" stroke="url(#gold)" stroke-width="15" stroke-linecap="round"/>
  <path d="M256 190 L336 216 L328 318 C320 362 288 388 256 402 C224 388 192 362 184 318 L176 216 Z" fill="url(#gold)" stroke="${INK}" stroke-width="9" stroke-linejoin="round"/>
  <path d="M256 208 L320 228 L314 314 C308 348 284 370 256 382" fill="none" stroke="#9A6208" stroke-width="5" opacity=".6"/>
  <path d="M236 250 L282 250 M236 250 L236 346 M236 294 L272 294" stroke="${INK}" stroke-width="20" stroke-linecap="round" fill="none"/>
  ${gloss(206, 236, 18, 9, -30, 0.8)}`,
  `${sparkle(446, 372, 28)}${sparkle(70, 340, 22)}`);
}

// Founder's Trail: a glowing gold comet with a sparkling tail.
{
  render('trail-founder', `
    ${ball('head', '#FFFBE0', '#F7C843', '#B57A12')}
    <linearGradient id="tail" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="#F7C843" stop-opacity="0"/><stop offset=".4" stop-color="#F7C843" stop-opacity=".85"/><stop offset="1" stop-color="#FFF3B0"/></linearGradient>
    <linearGradient id="core" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0"/><stop offset="1" stop-color="#FFFFFF"/></linearGradient>
`, `
  <path d="M44 462 C140 360 230 270 318 132 L428 236 C300 330 190 400 44 462 Z" fill="url(#tail)" stroke="${INK}" stroke-width="7" stroke-linejoin="round"/>
  <path d="M100 418 C190 344 270 274 356 196" stroke="url(#core)" stroke-width="22" stroke-linecap="round" fill="none"/>
  <circle cx="378" cy="186" r="92" fill="url(#head)" stroke="${INK}" stroke-width="8"/>
  <polygon points="${starPts(378, 192, 50)}" fill="#E0A526" stroke="#9A6208" stroke-width="4" stroke-linejoin="round"/>
  ${gloss(344, 146, 32, 17, -35, 0.85)}`,
  `${sparkle(150, 300, 30)}${sparkle(250, 410, 24)}${sparkle(470, 352, 26)}${sparkle(214, 196, 18)}`);
}

// Victory Flex: a flexed arm in a purple sleeve, bicep up, fist high.
{
  render('emote-victory-flex', `
    ${grad('skin', '#FFE3C2', '#F2B98A', '#C9845A')}
    ${ball('bicep', '#FFF0DC', '#F4BE90', '#CF8A5E')}
    ${grad('sleeve', '#8A6CF5', '#5A3BD4', '#2E1A85')}${grad('gold', ...GOLD)}`, `
  <path d="M100 334 C126 226 288 170 342 296 L338 214 L438 214 L444 404 C444 444 414 466 372 466 L100 466 Z" fill="url(#skin)" stroke="${INK}" stroke-width="8" stroke-linejoin="round"/>
  <path d="M118 326 C150 236 268 206 330 300 C300 344 200 354 118 344 Z" fill="url(#bicep)"/>
  <path d="M342 296 C346 340 334 380 300 404" stroke="#A8643C" stroke-width="7" fill="none" opacity=".6" stroke-linecap="round"/>
  <path d="M424 230 C432 300 432 360 420 420" stroke="#A8643C" stroke-width="7" fill="none" opacity=".45" stroke-linecap="round"/>
  ${gloss(200, 282, 50, 20, -22, 0.6)}
  <path d="M322 224 C306 178 310 122 334 104 C344 86 368 86 378 100 C388 84 412 84 422 100 C434 88 456 94 460 116 C468 146 464 186 452 224 Z" fill="url(#skin)" stroke="${INK}" stroke-width="8" stroke-linejoin="round"/>
  <path d="M378 102 L376 142 M422 102 L420 142" stroke="#A8643C" stroke-width="7" stroke-linecap="round" opacity=".7"/>
  <path d="M330 196 C352 170 404 166 434 180 C446 192 436 208 420 208 L338 214 Z" fill="url(#skin)" stroke="${INK}" stroke-width="7" stroke-linejoin="round"/>
  ${gloss(350, 118, 14, 8, -30, 0.6)}${gloss(398, 108, 12, 6, -10, 0.5)}
  <path d="M40 290 L142 276 C156 334 156 406 142 472 L40 472 Z" fill="url(#sleeve)" stroke="${INK}" stroke-width="8" stroke-linejoin="round"/>
  <path d="M136 282 C150 336 150 404 136 466" stroke="url(#gold)" stroke-width="14" fill="none" stroke-linecap="round"/>
  <path d="M210 196 C230 170 262 164 288 172 M184 170 C214 130 260 124 300 136" stroke="${W}" stroke-width="10" stroke-linecap="round" fill="none"/>`,
  `${sparkle(110, 150, 34, '#F7C843')}${sparkle(470, 300, 24)}${sparkle(250, 90, 22)}`);
}
