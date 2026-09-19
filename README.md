# Don't Steal Bro!

A competitive Roblox mini-task race with power-up griefing and a social-deduction
finale. Six players race to finish their tasks while sabotaging each other. The
first three to finish are teleported to the **Decision Studio**, where they can
talk, negotiate and lie — then blindly pick **Steal** or **Share**.

Your win streak is the whole metagame. It only goes up. One loss takes it all.

## Status

**Pre-production.** No game code exists yet. The design is written, the
technical architecture is decided, and the build plan is broken into 57 tasks
across 10 phases.

Next action: **task P0-1** — resolve the eight open design questions in
`docs/gdd.md` §7. Everything else is blocked behind it.

## Documents

| File | What it is |
|---|---|
| [`docs/gdd.md`](docs/gdd.md) | The game design document. §7 lists what is still undecided. |
| [`docs/architecture.md`](docs/architecture.md) | Locked technical decisions, folder skeleton, and the NPC / mobile-UI / Decision Studio deep dives. |
| [`docs/build-plan.html`](docs/build-plan.html) | The production tracker: 57 tasks in 10 phases, each with a paste-ready prompt and a model recommendation. Open it in a browser. |

Attach the first two to any AI session working on this project. The architecture
doc is what stops each session from re-inventing the folder structure.

### On the tracker's two copies

`docs/build-plan.html` is the offline copy — it ticks, but its tick state is
stored in whichever browser opened it and goes no further.

The **authoritative** tracker is the private artifact at
https://claude.ai/artifact/RSqVYTXtKzUK8v3Zi3hRPX — tick state there syncs and is
visible to anyone the artifact is shared with. Tick progress there, treat the
file in this repo as a read-only backup, and re-export it when the task list
itself changes.

## Planned layout

This folder becomes the Rojo project root at task P1-1:

```
src/shared/     -> ReplicatedStorage.Shared   (config, types, Net)
src/server/     -> ServerScriptService        (services, task handlers)
src/client/     -> StarterPlayerScripts       (controllers, UI, task views)
docs/           design and architecture
tests/          Jest-Lua suites, run headlessly via Lune
```

Maps are built by hand in Studio and live in `ServerStorage`. They are
deliberately **not** synced by Rojo — the `.rbxl` is authoritative for map
content, this repo is authoritative for everything else.

## Ground rules

- **The server decides everything.** Clients send intents; the server validates.
  Assume the client is fully compromised, because it will be.
- **Data-driven.** Adding a map, task, power-up or title means adding one config
  file. If it needs a service edit, the abstraction is leaking.
- **Mobile-first.** One thumb, portrait, on a cheap Android phone. If a mini-game
  needs two thumbs plus camera control, it is cut.
- **`--!strict` everywhere**, and pure logic stays free of Roblox API calls so it
  can be tested in CI.
