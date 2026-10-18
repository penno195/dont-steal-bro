# Staff tools: plan

Decided by the owner on 2026-10-10 to 2026-10-12. The rules are in
`design-decisions.md` ("Applied case: staff tools"). **One step per
session, then `/clear`.** Tick a step off here in the same commit that
finishes it.

## Steps

- [x] **1. Streak Save item.** A `streakSaves` count in the profile and
  a `Store/StreakSave.luau` developer product (100 R$). The buy-back
  offer card gets a "Use Streak Save" button when the player holds one,
  next to the Robux button. Using one is server-validated against the
  live offer, exactly like a buy-back receipt, and spends one save.
  Owner job: create the developer product in Creator Hub and paste its
  id into the config file.
  *Built 2026-10-12: profile v10 `streakSaves`, `StreakSave` grant kind
  (DeveloperProduct only), `UseStreakSaveIntent`. Product 3718198254
  created and enabled the same day.*
- [x] **2. Staff grants (server).** One staff-only remote, gated on
  `liveOps.adminUserIds`, that gives a chosen player coins, a cosmetic,
  Unlimited Navigation (held in the profile) or Streak Saves. Every
  grant goes into an audit log (who, to whom, what, when), the same way
  LiveConfig does it. There are no caps. Pure validation lives in a
  `*Logic.luau` module with specs.
  *Built 2026-10-12: `StaffGrantIntent` / `StaffGrantResult`,
  `StaffService` + `StaffGrantLogic`, also Navigation rounds. Profile
  v11 `unlimitedNavigation`, read by `StoreService.ownsPerk`; the store
  then shows the pass as owned. Audit at `liveOps.staffAuditKey`
  (`docs/live-ops.md`). `StaffService.onGifted` is step 3's hook. Not
  yet tested in Studio: there's no panel until step 4.*
- [x] **3. Gift pop-up.** The receiving player sees "Gift received from
  <staff name>" with the item, and the item lands in their inventory.
  If they're mid-race, the pop-up waits until the race ends.
  *Built 2026-10-12. Owner: the pop-up shows **only in the lobby**,
  so a gift given in a match, or before the game is closed, shows on
  the next lobby visit. Each gift joins the profile's `unseenGifts`
  (v12, capped at 20, ids from GenerateGUID). The Hub sends them as
  `GiftReceived` when the profile loads and after each gift; the
  client shows them through `ClaimPopup` (now takes a title and body)
  once the loading cover is gone and no practice round is on, then
  `GiftsSeenIntent { upToId }` clears them. Rules in `GiftLogic` and
  `StaffGrantLogic.noteUnseen / markSeen`, with specs.*
- [x] **4. Staff panel (client).** A screen only staff can open, for
  picking a player in the server, then an item, then Give. It shows
  names only, never streaks or titles (Q7 condition 1).
  *Built 2026-10-12: a fifth launcher button (gift icon) for
  `liveOps.adminUserIds` only, so it opens between rounds, not mid-
  race. `Screens/StaffPanel` is a small centred window, not a full-
  screen menu (owner, after the Squishie merge game's panel): chip
  grids for who and what, an amount box with quick picks, and a
  searchable cosmetic grid. `UI/StaffPanelLogic` with specs, data in
  MenuController.
  Give takes two taps (no caps, so the second tap is the guard). A
  reply that never comes clears after 10 s. Tested in Studio solo:
  100 coins to everyone -> server grant -> pop-up, which also covers
  steps 2 and 3.*
- [x] **5. Events.** A themed event (e.g. "Taco Tuesday") with a name,
  a music track and a schedule or a manual start. It runs in **every
  server at once**. During it, staff hand out gifts the step 2 way, to
  one chosen player or to everyone in their own server.
  *Built 2026-10-12. Owner: **manual start only** (no schedule), for
  a set number of minutes (1 to 1440) or until stopped; **lobby only**
  (its music replaces the hub bed; races and the Studio are
  untouched); each event has **its own look**. An event is one file in
  `Config/Events/` (name, music, view) plus one client module in
  `src/client/EventViews/`. The staff panel's new Events tab starts and
  stops it (two taps each). `EventService` + `EventLogic` (specs) keep
  one versioned record at `liveOps.eventKey`, tell every Hub at once
  through MessagingService (`eventTopic`), and every Hub re-reads it
  each refresh as a backstop. Audit at `liveOps.eventAuditKey`. Hubs
  show it through the ReplicatedStorage attributes `LiveEventId` /
  `LiveEventEndsAt`; `EventController` runs the view and
  `AudioController` the music. Taco Tuesday: tacos rain round each
  player (Creator Store mesh "roblox-taco-v2") and three disco balls
  spin over the spawn plaza, or under any part tagged
  `EventDiscoAnchor`. Tested in Studio solo: start, stop, a bad id, a
  restart picking up a running event. Cross-server delivery needs a
  live test with two Hub servers.*
- [x] **6. Announcements.** Staff type a line in the staff panel and it
  shows as a big banner for every player in every live server (Hub,
  match and practice), not just their own.
  *Built 2026-10-18. Owner: it shows **at once everywhere, mid-race
  included**, and keeping streaks out of it is **staff's job** (Q7
  condition 1): the Announce tab warns "It shows mid-race too. Never
  mention anyone's streak." and nothing scans the text for it. The
  panel's third tab has a message box (120 characters, counted by
  `AnnounceLogic`, shared with the server) and Send (two taps).
  `AnnounceService` checks staff, tidies and caps the text, holds each
  staff member to one per `announceCooldownSeconds`, filters it with
  `TextService` (`FilterStringAsync` then
  `GetNonChatStringForBroadcastAsync`, in the sender's name), refuses
  one the filter wiped out or one over MessagingService's 1KB, shows it
  in its own server and publishes on `liveOps.announceTopic`. Every
  server subscribes and drops repeats and anything over 2 min old.
  A failed publish tells staff only their server got it. Audit at
  `liveOps.announceAuditKey`. `AnnouncementController` draws the
  banner in the upper third ("ANNOUNCEMENT FROM <NAME>", the message
  in the display face, stroked, on a dark band with a gold rim): it
  drops in, holds for its reading time, fades, and up to 3 more wait
  their turn. The look is in constants at the top of the controller,
  to swap for the Squishie merge game's style. Not yet tested: a
  Studio solo run (filter, banner, cooldown), then a live test with
  two servers (a Hub and a match) for cross-server delivery.*

## Settled (owner, 2026-10-12)

- **Who a gift goes to:** staff pick either **one player in their own
  server** or **every player currently in their own server**. Staff
  can't reach players in other servers.
- **Event reach:** an event (its theme and music) runs in every server.
- **Taco Tuesday music:** "It's Raining Tacos", Creator Store audio
  `100847230469970`, uploaded by DistrokidOfficial (the licensed
  distributor). Avoid fan re-uploads.
