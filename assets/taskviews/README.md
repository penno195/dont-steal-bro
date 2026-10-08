# Task view art

The illustrated pieces of all eight task views. The ids live in
`src/client/UI/TaskArt.luau`, except Vent Purge's tank, which is in
`src/client/TaskViews/VentPurge.luau`, and Pressure Valve's gauge, needle and steam,
which are older owner-supplied art in `PressureValve.luau`.

| File | Used by | Asset id |
|------|---------|----------|
| `vent-tank.png` | Vent Purge (owner-supplied render, cropped) | 104118102672304 |
| `ks_plate.png` | Alarm Killswitch panel, collar, PRESS & HOLD label | 93535533002112 |
| `ks_button.png` | Alarm Killswitch KILL cap | 97048344563976 |
| `siren.png` | Alarm Killswitch beacon | 70675143544611 |
| `gauge.png` | Reactor Sync gauge housing | 112878248184079 |
| `needle.png` | Reactor Sync needle (hub at the image centre, so Rotation pivots on it) | 109908207651781 |
| `airlock_track.png` | Airlock Cycle channel | 134605367931314 |
| `airlock_door.png` | Airlock Cycle shutter | 113955542436103 |
| `breaker.png` | Breaker Sequence module (lamp socket, lever slot, number plate) | 105334560523635 |
| `lever.png` | Breaker Sequence toggle grip | 110475102640409 |
| `socket.png` | Fuse Rewire socket tile | 88858068736134 |
| `fuse.png` | Fuse Rewire glass fuse tile | 108626543957160 |
| `cap.png` | Pressure Valve PUMP cap (unlettered) | 77165658125877 |
| `plate.png` | shared steel backing plate, 9-sliced (SliceCenter 72,72,184,184) | 126503848455724 |
| `well.png` | shared dark recess, 9-sliced (SliceCenter 40,40,88,88) | 127850483743288 |
| `lamp.png` | shared, tinted by ImageColor3 | 74439036798529 |
| `glow.png` | shared, tinted by ImageColor3 | 96266303574461 |
| `button.png` | shared chunky button, 9-sliced (SliceCenter 48,40,208,88), tinted | 139424222917940 |

Everything but `vent-tank.png` is drawn as SVG by `make-art.js` at 2x
the views' reference size. Tintable pieces are near-white so one image
serves every colour. The views place moving parts by coordinates on
this art (button well, gauge pivot, channel rect), so if you change a
layout here, update the constants at the top of that view too.

## Redrawing and uploading

1. `npm i @resvg/resvg-js` in a scratch folder, then
   `NODE_PATH=<scratch>/node_modules node make-art.js`.
2. Serve the folder on localhost (any static server) and upload with
   Studio MCP `upload_image` on `http://localhost:<port>/<file>.png`.
   The tool can't read local paths directly.
3. Put the new id in `TaskArt.luau`.
