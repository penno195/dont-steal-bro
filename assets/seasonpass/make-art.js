// Renders the season pass tile pictures for items that have no 3D model
// (a trail, an emote, a skin) to 512x512 transparent PNGs next to this
// file. Same setup as assets/taskviews/make-art.js: needs
// @resvg/resvg-js (npm i @resvg/resvg-js in a scratch folder, then
// NODE_PATH=<that folder>/node_modules node make-art.js).
// Thick dark outlines so each reads on both the gold and blue tiles.
const { Resvg } = require('@resvg/resvg-js');
const fs = require('fs');
const OUT = __dirname + '/';

const INK = '#1A1030';
const S = 512;
const render = (name, body) => {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${S}" height="${S}" viewBox="0 0 ${S} ${S}">${body}</svg>`;
  fs.writeFileSync(OUT + name + '.png', new Resvg(svg).render().asPng());
};

const goldDef = (id) =>
  `<linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFF1A8"/><stop offset=".45" stop-color="#F5C842"/><stop offset="1" stop-color="#B9831A"/></linearGradient>`;
const star = (x, y, r, fill = '#FFFFFF') => {
  const p = [];
  for (let i = 0; i < 8; i++) {
    const a = (Math.PI / 4) * i - Math.PI / 2;
    const rr = i % 2 === 0 ? r : r * 0.32;
    p.push(`${x + Math.cos(a) * rr},${y + Math.sin(a) * rr}`);
  }
  return `<polygon points="${p.join(' ')}" fill="${fill}" stroke="${INK}" stroke-width="6" stroke-linejoin="round"/>`;
};
const shadow = (d) => `<path d="${d}" fill="#000" opacity=".3" transform="translate(0 12)"/>`;

// ---------- Founder's Trail: a gold comet streak ----------
{
  const tail = 'M70 420 C150 330 250 250 360 170 C380 200 395 225 405 250 C300 300 200 360 70 420 Z';
  render('trail-founder', `
  <defs>${goldDef('gold')}
    <linearGradient id="fade" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="#F5C842" stop-opacity="0"/><stop offset=".55" stop-color="#F5C842"/><stop offset="1" stop-color="#FFF1A8"/></linearGradient>
  </defs>
  ${shadow(tail)}
  <path d="${tail}" fill="url(#fade)" stroke="${INK}" stroke-width="10" stroke-linejoin="round"/>
  <path d="M120 375 C200 320 270 270 350 215" stroke="#FFFFFF" stroke-width="10" stroke-linecap="round" fill="none" opacity=".7"/>
  <circle cx="392" cy="200" r="78" fill="#000" opacity=".3" transform="translate(0 12)"/>
  <circle cx="392" cy="200" r="78" fill="url(#gold)" stroke="${INK}" stroke-width="12"/>
  <ellipse cx="368" cy="170" rx="30" ry="18" fill="#FFFFFF" opacity=".75" transform="rotate(-30 368 170)"/>
  ${star(160, 210, 34)}${star(250, 420, 26)}${star(460, 380, 30)}`);
}

// ---------- Victory Flex: a flexed arm ----------
{
  // Upper arm along the bottom, bicep bulging up, forearm rising to a
  // fist at the top right.
  const arm =
    'M70 340 C120 230 250 215 300 275 L298 200 C282 160 290 100 340 92 L392 88 C432 90 444 132 430 170 L418 205 C450 270 448 370 405 425 C385 455 345 468 300 468 L70 468 Z';
  render('emote-victory-flex', `
  <defs>
    <linearGradient id="skin" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFE0B8"/><stop offset="1" stop-color="#E7A86F"/></linearGradient>
    ${goldDef('gold')}
  </defs>
  ${shadow(arm)}
  <path d="${arm}" fill="url(#skin)" stroke="${INK}" stroke-width="12" stroke-linejoin="round"/>
  <path d="M300 275 C320 320 315 360 290 390" stroke="${INK}" stroke-width="8" fill="none" stroke-linecap="round" opacity=".45"/>
  <path d="M330 130 L410 128 M325 165 L405 165" stroke="${INK}" stroke-width="8" stroke-linecap="round" opacity=".45"/>
  <ellipse cx="170" cy="285" rx="44" ry="20" fill="#FFFFFF" opacity=".55" transform="rotate(-25 170 285)"/>
  <rect x="40" y="330" width="44" height="150" rx="12" fill="url(#gold)" stroke="${INK}" stroke-width="10"/>
  ${star(140, 130, 46, '#F5C842')}${star(470, 70, 28)}${star(250, 60, 24)}`);
}

// ---------- Founder's Kit: a shirt with a gold F crest ----------
{
  const shirt =
    'M190 90 C215 120 297 120 322 90 L430 140 L470 250 L395 280 L380 245 L380 440 C380 455 368 465 352 465 L160 465 C144 465 132 455 132 440 L132 245 L117 280 L42 250 L82 140 Z';
  render('skin-founder', `
  <defs>
    <linearGradient id="cloth" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6A4CE0"/><stop offset="1" stop-color="#3B2391"/></linearGradient>
    ${goldDef('gold')}
  </defs>
  ${shadow(shirt)}
  <path d="${shirt}" fill="url(#cloth)" stroke="${INK}" stroke-width="12" stroke-linejoin="round"/>
  <path d="M190 90 C215 135 297 135 322 90" fill="none" stroke="url(#gold)" stroke-width="16" stroke-linecap="round"/>
  <path d="M190 90 C215 135 297 135 322 90" fill="none" stroke="${INK}" stroke-width="5" stroke-linecap="round" opacity=".6"/>
  <path d="M256 200 L330 225 L322 320 C315 360 285 385 256 398 C227 385 197 360 190 320 L182 225 Z" fill="url(#gold)" stroke="${INK}" stroke-width="10" stroke-linejoin="round"/>
  <path d="M234 250 L284 250 M234 250 L234 350 M234 296 L274 296" stroke="${INK}" stroke-width="18" stroke-linecap="round" fill="none"/>
  ${star(440, 360, 30)}`);
}
