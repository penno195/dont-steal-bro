# Don't Steal Bro! — Context for AI Sessions

## The game

*Don't Steal Bro!* is a Roblox competitive mini-task race: 6 players race
through *Among Us*/*Crystal Maze*-style stations while sabotaging each other
with power-ups, and the first 3 to finish go to the **Decision Studio** to
blindly choose **Steal** or **Share**, deciding who progresses with what
bounty. The whole metagame is a win streak that only goes up and resets
completely on any loss.

This repo is **pre-production** — no game code exists yet. Design and
architecture are written; nothing here should be treated as "in progress."

## Ground rules (non-negotiable)

1. **Server authority.** Assume the client is fully compromised. Clients only
   ever send intents; the server validates and applies everything. This is a
   competitive game with a public leaderboard — it will be attacked.
2. **Data-driven config.** Adding a map, task, power-up or title means adding
   **one config file** (and at most one handler module). If it requires
   editing a service, the abstraction is leaking — stop and reconsider.
3. **Mobile-first.** Design for one thumb, portrait orientation, on a cheap
   Android phone. A mini-game that needs two thumbs or camera control is cut.
4. **`--!strict` everywhere.** Pure logic (outcome tables, pricing, ranking,
   tie-breaks, streak math) must stay free of any Roblox API calls, so it can
   be unit-tested headlessly in CI (Jest-Lua via Lune).

## Planned Rojo layout

```
src/shared/     -> ReplicatedStorage.Shared   (Config/, Net.luau, Types.luau)
src/server/     -> ServerScriptService        (Services/, TaskHandlers/)
src/client/     -> StarterPlayerScripts       (Controllers/, UI/, TaskViews/)
docs/           design and architecture
tests/          Jest-Lua suites, run headlessly via Lune
```

**Maps are never synced by Rojo.** All 11 maps are built by hand in Studio and
live in `ServerStorage.Maps`, cloned into the round on load. The `.rbxl` is
authoritative for map content; this repo is authoritative for everything
else. Full details: `docs/architecture.md`.

## Open design questions — do not silently answer

`docs/gdd.md` §7 lists eight unresolved design questions (bounty definition,
round timeout, disconnect handling, NPC qualification, streak-reset scope,
Robux power-ups, etc). Task **P0-1** resolves these into
`docs/design-decisions.md`. Until that file exists, these questions are open.

If any task touches one of these questions, **stop and ask the user** —
do not pick an answer and proceed, even a reasonable-sounding one.

## Luau / Roblox API caution

This targets **current Roblox Luau**. APIs and best practices shift over
time and are easy to misremember or hallucinate. Verify API names, signatures
and current recommended patterns rather than recalling them from training
data — especially for `TeleportService`, `MemoryStoreService`, `ProfileStore`,
`TextChatService`, and the Audio API.

Two local sources of truth beat guessing, and both are already in the repo:
`globalTypes.d.luau` (the pinned Roblox type definitions) and
`ServerPackages/_Index/**/profilestore/docs/` (ProfileStore's own guides).

## Keeping sessions cheap

Files here are deliberately comment-dense — `Validate.luau` is 64KB, a
typical service ~30KB — so every read and write costs 2–3x a terser
codebase. Context is re-sent every turn, so cost grows with
(context size × turns). That makes session hygiene a real constraint,
not a nicety:

- **One tracker task per session**, then `/clear`. A P-task is the
  natural boundary. If a task is large, split at its own seams
  (config+validation → service+tests → docs) and clear between.
- **Never `grep` `globalTypes.d.luau` bare.** Line 1 is a single 13KB
  metadata blob naming every Roblox class and service, so nearly any
  service name matches it and dumps 13KB into context. Use
  `awk '/^declare extern type X/,/^end/' globalTypes.d.luau` instead.
- **Don't `sed -i` a file already read or written via the Read/Write
  tools** — the harness re-dumps the whole file into context on an
  out-of-band change. Use `Edit` for those; keep `sed`/`awk` for files
  only ever touched through Bash.
- **Read line ranges**, not whole files, past ~300 lines.
- Don't stage edits through scratchpad files and `cat` them into place;
  that pays for the content twice.
