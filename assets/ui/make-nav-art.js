// Renders the race HUD's compass and Navigation art: the dial face, its
// tintable rim, the needle and the route badge on the NAV tab. 256x256
// transparent PNGs next to this file. Same setup as
// assets/seasonpass/make-pictures.js: npm i @resvg/resvg-js in a scratch
// folder, then NODE_PATH=<that folder>/node_modules node make-nav-art.js.
//
// The rim is drawn in greys so RaceHUD can tint it (ImageColor3) gold on
// your floor, blue a floor up and orange a floor down; its ink outline
// stays dark under any tint. The needle has no drop shadow, because it
// turns and a shadow would turn with it.
const { Resvg } = require('@resvg/resvg-js');
const fs = require('fs');

const INK = '#1A1030';
const S = 256;
const C = S / 2;

const write = (name, defs, body) => {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${S}" height="${S}" viewBox="0 0 ${S} ${S}">
  <defs>${defs}</defs>${body}</svg>`;
  fs.writeFileSync(__dirname + '/' + name + '.png', new Resvg(svg).render().asPng());
  console.log('wrote', name + '.png');
};

// The dial face: deep stage purple, lit from the top left, with twelve
// ticks (the four quarters long). No letters: the bearing is relative to
// the camera, so an N would lie.
{
  const ticks = [];
  for (let i = 0; i < 12; i++) {
    const long = i % 3 === 0;
    const a = (Math.PI / 6) * i;
    const r1 = 100, r2 = long ? 80 : 89;
    const p = (r) => `${(C + Math.sin(a) * r).toFixed(1)} ${(C - Math.cos(a) * r).toFixed(1)}`;
    ticks.push(`<path d="M${p(r1)} L${p(r2)}" stroke="#FFFFFF" stroke-opacity="${long ? 0.9 : 0.45}" stroke-width="${long ? 9 : 6}" stroke-linecap="round"/>`);
  }
  write('dial-face',
    `<radialGradient id="face" cx=".4" cy=".32" r=".8"><stop offset="0" stop-color="#4A3489"/><stop offset=".6" stop-color="#2A1D57"/><stop offset="1" stop-color="#140C30"/></radialGradient>`,
    `<circle cx="${C}" cy="${C}" r="112" fill="url(#face)"/>
     <circle cx="${C}" cy="${C}" r="108" fill="none" stroke="#000" stroke-opacity=".35" stroke-width="8"/>
     ${ticks.join('')}
     <circle cx="${C}" cy="${C}" r="56" fill="none" stroke="#FFFFFF" stroke-opacity=".08" stroke-width="4"/>`);
}

// The rim: a bevelled ring in greys (bright top, dark bottom, a lit
// inner lip), ink inside and out.
write('dial-rim',
  `<linearGradient id="bevel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset=".55" stop-color="#D8D8D8"/><stop offset="1" stop-color="#8A8A8A"/></linearGradient>
   <linearGradient id="lip" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#9A9A9A"/></linearGradient>`,
  `<circle cx="${C}" cy="${C}" r="117" fill="none" stroke="url(#bevel)" stroke-width="18"/>
   <circle cx="${C}" cy="${C}" r="107" fill="none" stroke="url(#lip)" stroke-width="4"/>
   <path d="M${C - 82} ${C - 82} A116 116 0 0 1 ${C + 40} ${C - 109}" fill="none" stroke="#FFFFFF" stroke-width="5" stroke-linecap="round" opacity=".9"/>
   <circle cx="${C}" cy="${C}" r="126" fill="none" stroke="${INK}" stroke-width="5"/>
   <circle cx="${C}" cy="${C}" r="104.5" fill="none" stroke="${INK}" stroke-width="4"/>`);

// The needle: a gold arrowhead split down its spine, the left half lit
// and the right in shade, so it reads as folded metal. Pointing up, its
// weight centred on the image so it spins in place.
{
  const tip = [C, 10], right = [C + 70, 198], notch = [C, 152], left = [C - 70, 198];
  const pt = (p) => p.join(' ');
  write('compass-needle',
    `<linearGradient id="lit" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFF6C2"/><stop offset=".5" stop-color="#FFD54A"/><stop offset="1" stop-color="#E9A91C"/></linearGradient>
     <linearGradient id="shade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F2B630"/><stop offset=".6" stop-color="#C9860F"/><stop offset="1" stop-color="#9C620A"/></linearGradient>`,
    `<polygon points="${pt(tip)} ${pt(right)} ${pt(notch)} ${pt(left)}" fill="none" stroke="${INK}" stroke-width="22" stroke-linejoin="round"/>
     <polygon points="${pt(tip)} ${pt(notch)} ${pt(left)}" fill="url(#lit)"/>
     <polygon points="${pt(tip)} ${pt(right)} ${pt(notch)}" fill="url(#shade)"/>
     <path d="M${C - 8} 46 L${C - 52} 176" stroke="#FFFFFF" stroke-width="7" stroke-linecap="round" opacity=".75"/>`);
}

// The route badge: a pink map pin at the end of a dotted gold trail,
// with the shared ink ring and soft drop shadow (make-pictures.js).
{
  const finish = `<filter id="finish" x="-10%" y="-10%" width="120%" height="125%">
    <feComponentTransfer in="SourceAlpha" result="solid"><feFuncA type="discrete" tableValues="0 1 1 1 1 1"/></feComponentTransfer>
    <feMorphology in="solid" operator="dilate" radius="9" result="ring"/>
    <feFlood flood-color="${INK}"/><feComposite in2="ring" operator="in" result="inkRing"/>
    <feOffset in="ring" dy="8" result="drop"/>
    <feFlood flood-color="#000" flood-opacity=".3"/><feComposite in2="drop" operator="in" result="shadow"/>
    <feMerge><feMergeNode in="shadow"/><feMergeNode in="inkRing"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>`;
  const dots = [[26, 112], [36, 160], [66, 198], [112, 216]]
    .map(([x, y]) => `<circle cx="${x}" cy="${y}" r="13" fill="url(#gold)"/>`).join('');
  const px = 166, py = 88, r = 62;
  write('nav-route',
    `${finish}
     <linearGradient id="gold" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFF3B0"/><stop offset=".5" stop-color="#F7C843"/><stop offset="1" stop-color="#B57A12"/></linearGradient>
     <radialGradient id="pin" cx=".38" cy=".28" r=".85"><stop offset="0" stop-color="#FF9BD0"/><stop offset=".5" stop-color="#FF3E9A"/><stop offset="1" stop-color="#B0145F"/></radialGradient>`,
    `<g filter="url(#finish)">${dots}
       <path d="M${px} ${py + r + 64} C${px - 22} ${py + r + 20} ${px - r} ${py + 38} ${px - r} ${py} A${r} ${r} 0 1 1 ${px + r} ${py} C${px + r} ${py + 38} ${px + 22} ${py + r + 20} ${px} ${py + r + 64} Z" fill="url(#pin)"/>
     </g>
     <circle cx="${px}" cy="${py}" r="24" fill="#FFFFFF" stroke="${INK}" stroke-width="8"/>
     <ellipse cx="${px - 30}" cy="${py - 32}" rx="16" ry="9" fill="#FFFFFF" opacity=".7" transform="rotate(-40 ${px - 30} ${py - 32})"/>`);
}
