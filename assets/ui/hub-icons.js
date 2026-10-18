// The Hub launcher's full-colour icons (Hub menu art pass, 2026-10-18).
// One SVG source for both the HTML mockup (docs/ui-art-pass/hub-menu.html
// loads this file with a <script> tag) and the 256x256 PNGs uploaded to
// Roblox (`node hub-icons.js` with NODE_PATH pointing at a scratch
// @resvg/resvg-js install, like make-nav-art.js).
//
// House style: Game Show palette (Tokens.luau), a thick ink outline, lit
// from the top left, a soft gloss, and a drop shadow baked in so they read
// on the purple buttons and on the bright Hub alike.
(function () {
  const INK = '#1B0B33';
  const W = 7; // outline width, in the 128 box

  const grad = (id, top, bottom, x2 = 0, y2 = 1) =>
    `<linearGradient id="${id}" x1="0" y1="0" x2="${x2}" y2="${y2}"><stop offset="0" stop-color="${top}"/><stop offset="1" stop-color="${bottom}"/></linearGradient>`;
  const GOLD = (id) => grad(id, '#FFF09A', '#F5A300');
  const line = `stroke="${INK}" stroke-width="${W}" stroke-linejoin="round" stroke-linecap="round"`;
  const gloss = (cx, cy, rx, ry, rot = -20) =>
    `<ellipse cx="${cx}" cy="${cy}" rx="${rx}" ry="${ry}" transform="rotate(${rot} ${cx} ${cy})" fill="#fff" fill-opacity=".5"/>`;

  const star = (cx, cy, r, ri = r * 0.45) => {
    const pts = [];
    for (let i = 0; i < 10; i++) {
      const a = (Math.PI / 5) * i - Math.PI / 2;
      const rr = i % 2 ? ri : r;
      pts.push(`${(cx + Math.cos(a) * rr).toFixed(1)},${(cy + Math.sin(a) * rr).toFixed(1)}`);
    }
    return pts.join(' ');
  };

  const gear = (cx, cy, rOut, rIn, teeth) => {
    const pts = [];
    const step = (Math.PI * 2) / teeth;
    for (let i = 0; i < teeth; i++) {
      const a = step * i;
      for (const [da, r] of [[-0.3, rIn], [-0.2, rOut], [0.2, rOut], [0.3, rIn]]) {
        const t = a + da * step * 1.1;
        pts.push(`${(cx + Math.cos(t) * r).toFixed(1)},${(cy + Math.sin(t) * r).toFixed(1)}`);
      }
    }
    return pts.join(' ');
  };

  // Each entry: [defs, body] in a 128x128 box.
  const ICONS = {
    // The Locker: a backpack, "everything that's yours".
    locker: [
      grad('lk-body', '#FF8CC6', '#E0307E') + grad('lk-flap', '#FFB3DA', '#FF5FA8') + GOLD('lk-gold'),
      `<path d="M46 30 Q64 6 82 30" fill="none" stroke="${INK}" stroke-width="16" stroke-linecap="round"/>
       <path d="M46 30 Q64 6 82 30" fill="none" stroke="#7C4DFF" stroke-width="6" stroke-linecap="round"/>
       <rect x="24" y="28" width="80" height="88" rx="24" fill="url(#lk-body)" ${line}/>
       <rect x="38" y="76" width="52" height="30" rx="10" fill="#C2185B" ${line}/>
       <path d="M50 88 H78" stroke="#FF8CC6" stroke-width="5" stroke-linecap="round"/>
       <path d="M24 60 V52 Q24 28 48 28 H80 Q104 28 104 52 V60 Q64 74 24 60Z" fill="url(#lk-flap)" ${line}/>
       <rect x="55" y="56" width="18" height="18" rx="5" fill="url(#lk-gold)" ${line}/>
       ${gloss(44, 42, 13, 6)}`,
    ],

    // The Store: a market stall with a candy awning and a coin.
    shop: [
      grad('sh-counter', '#8F6BFF', '#4F2BD6') + GOLD('sh-gold'),
      `<rect x="30" y="44" width="10" height="34" fill="#B9A6FF" ${line}/>
       <rect x="88" y="44" width="10" height="34" fill="#B9A6FF" ${line}/>
       <rect x="20" y="70" width="88" height="44" rx="9" fill="url(#sh-counter)" ${line}/>
       ${[0, 1, 2, 3].map((i) => `<rect x="${14 + 25 * i}" y="20" width="25" height="22" fill="${i % 2 ? '#FFFFFF' : '#FF4FA3'}"/>`).join('')}
       ${[0, 1, 2, 3].map((i) => `<path d="M${14 + 25 * i} 42 a12.5 12.5 0 0 0 25 0Z" fill="${i % 2 ? '#FFFFFF' : '#FF4FA3'}" ${line}/>`).join('')}
       <rect x="14" y="16" width="100" height="26" rx="6" fill="none" ${line}/>
       <circle cx="64" cy="92" r="15" fill="url(#sh-gold)" ${line}/>
       <circle cx="64" cy="92" r="7" fill="none" stroke="#C77700" stroke-width="4"/>
       ${gloss(40, 82, 10, 4, 0)}`,
    ],

    // Ranks: the gold cup with a star.
    trophy: [
      GOLD('tr-gold') + grad('tr-base', '#8F6BFF', '#4F2BD6'),
      `<path d="M38 36 H22 Q20 66 46 70" fill="none" stroke="${INK}" stroke-width="15" stroke-linecap="round"/>
       <path d="M90 36 H106 Q108 66 82 70" fill="none" stroke="${INK}" stroke-width="15" stroke-linecap="round"/>
       <path d="M38 36 H22 Q20 66 46 70" fill="none" stroke="#FFC94A" stroke-width="6" stroke-linecap="round"/>
       <path d="M90 36 H106 Q108 66 82 70" fill="none" stroke="#FFC94A" stroke-width="6" stroke-linecap="round"/>
       <rect x="55" y="78" width="18" height="18" fill="#F5A300" ${line}/>
       <path d="M34 20 H94 V46 Q94 82 64 84 Q34 82 34 46Z" fill="url(#tr-gold)" ${line}/>
       <rect x="36" y="94" width="56" height="20" rx="6" fill="url(#tr-base)" ${line}/>
       <polygon points="${star(64, 50, 15)}" fill="#FFFFFF" stroke="#C77700" stroke-width="3" stroke-linejoin="round"/>
       ${gloss(44, 36, 5, 11, 10)}`,
    ],

    // Settings: a steel cog with a purple hub.
    settings: [
      grad('st-steel', '#F4F2FF', '#9A93BE') + grad('st-hub', '#8F6BFF', '#4F2BD6'),
      `<polygon points="${gear(64, 64, 52, 40, 8)}" fill="url(#st-steel)" ${line}/>
       <circle cx="64" cy="64" r="20" fill="url(#st-hub)" ${line}/>
       <circle cx="64" cy="64" r="6" fill="${INK}"/>
       ${gloss(46, 40, 12, 5, -35)}`,
    ],

    // Daily challenges: a clipboard, two ticked and one to go.
    tasks: [
      grad('tk-board', '#FFC94A', '#F08A1C'),
      `<rect x="24" y="20" width="80" height="98" rx="12" fill="url(#tk-board)" ${line}/>
       <rect x="34" y="34" width="60" height="74" rx="5" fill="#FFFFFF" stroke="${INK}" stroke-width="4"/>
       <rect x="46" y="10" width="36" height="20" rx="6" fill="#B9A6FF" ${line}/>
       ${[0, 1, 2].map((i) => {
         const y = 52 + i * 20;
         const done = i < 2;
         return `<circle cx="47" cy="${y}" r="7" fill="${done ? '#3CCB7F' : '#FFFFFF'}" stroke="${INK}" stroke-width="3.5"/>
           ${done ? `<path d="M43.5 ${y} l2.5 3 l5 -6" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>` : ''}
           <rect x="59" y="${y - 3}" width="26" height="6" rx="3" fill="${done ? '#C9BDF0' : '#5A3FA0'}"/>`;
       }).join('')}`,
    ],

    // Playtime: a gold stopwatch.
    playtime: [
      GOLD('pt-gold'),
      `<rect x="56" y="8" width="16" height="14" rx="4" fill="#B9A6FF" ${line}/>
       <path d="M94 26 l9 -9" ${line}/>
       <circle cx="64" cy="70" r="46" fill="url(#pt-gold)" ${line}/>
       <circle cx="64" cy="70" r="34" fill="#FFFFFF" stroke="#C77700" stroke-width="4"/>
       <path d="M64 70 V46" stroke="${INK}" stroke-width="7" stroke-linecap="round"/>
       <path d="M64 70 L80 80" stroke="#FF4FA3" stroke-width="6" stroke-linecap="round"/>
       <circle cx="64" cy="70" r="5" fill="${INK}"/>
       ${gloss(40, 44, 9, 4, -40)}`,
    ],

    // Your record: a scorecard of shares, steals and times robbed.
    record: [
      grad('rc-card', '#8F6BFF', '#4F2BD6'),
      `<rect x="18" y="20" width="92" height="92" rx="16" fill="url(#rc-card)" ${line}/>
       <rect x="32" y="62" width="16" height="36" rx="3" fill="#4ADE80" stroke="${INK}" stroke-width="4"/>
       <rect x="56" y="40" width="16" height="58" rx="3" fill="#FF6B6B" stroke="${INK}" stroke-width="4"/>
       <rect x="80" y="74" width="16" height="24" rx="3" fill="#FFC94A" stroke="${INK}" stroke-width="4"/>
       <path d="M30 100 H98" stroke="#fff" stroke-width="4" stroke-linecap="round"/>
       ${gloss(40, 32, 14, 5, 0)}`,
    ],

    // Bank the streak: a piggy bank swallowing a coin.
    bank: [
      grad('bk-pig', '#FFB3DA', '#FF5FA8') + GOLD('bk-gold'),
      `<rect x="34" y="88" width="14" height="22" rx="5" fill="#E0307E" ${line}/>
       <rect x="76" y="88" width="14" height="22" rx="5" fill="#E0307E" ${line}/>
       <path d="M40 46 L36 30 L54 40Z" fill="#E0307E" ${line}/>
       <ellipse cx="62" cy="72" rx="44" ry="32" fill="url(#bk-pig)" ${line}/>
       <rect x="98" y="62" width="16" height="20" rx="7" fill="#FF8CC6" ${line}/>
       <circle cx="80" cy="62" r="4" fill="${INK}"/>
       <rect x="50" y="44" width="24" height="6" rx="3" fill="${INK}"/>
       <circle cx="62" cy="26" r="14" fill="url(#bk-gold)" ${line}/>
       ${gloss(40, 60, 11, 5, -25)}`,
    ],

    // The practice party: two players, its own art (it used to borrow `rival`).
    party: [
      grad('pa-back', '#8F6BFF', '#4F2BD6') + grad('pa-front', '#FFB3DA', '#FF4FA3'),
      `<circle cx="84" cy="40" r="17" fill="url(#pa-back)" ${line}/>
       <path d="M56 98 Q58 64 84 64 Q110 64 112 98Z" fill="url(#pa-back)" ${line}/>
       <circle cx="50" cy="50" r="19" fill="url(#pa-front)" ${line}/>
       <path d="M18 114 Q20 76 50 76 Q80 76 82 114Z" fill="url(#pa-front)" ${line}/>
       ${gloss(43, 42, 6, 3, -30)}`,
    ],
  };

  // The whole icon as an SVG string. `shadow` bakes in the drop shadow.
  const svg = (key, size = 128, shadow = true) => {
    const [defs, body] = ICONS[key];
    const sh = shadow
      ? `<filter id="ds" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="4" stdDeviation="0" flood-color="${INK}" flood-opacity=".45"/></filter>`
      : '';
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="-6 -6 140 140"><defs>${defs}${sh}</defs><g ${shadow ? 'filter="url(#ds)"' : ''}>${body}</g></svg>`;
  };

  const HubIcons = { keys: Object.keys(ICONS), svg };
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = HubIcons;
    if (require.main === module) {
      const { Resvg } = require('@resvg/resvg-js');
      const fs = require('fs');
      for (const key of HubIcons.keys) {
        fs.writeFileSync(__dirname + '/hub-' + key + '.png', new Resvg(svg(key, 256)).render().asPng());
        console.log('wrote hub-' + key + '.png');
      }
    }
  } else {
    window.HubIcons = HubIcons;
  }
})();
