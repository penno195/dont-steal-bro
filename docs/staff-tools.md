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
  *Built 2026-10-12: `GiftReceived` (staff display name + the gift),
  fired from `StaffService.onGifted`; drawn by MenuController through
  `ClaimPopup` (now takes a title and body) with `GiftLogic` specs.
  Held while the round is in play and through the Studio's reveal,
  then everything held shows in one pop-up. On a match server that
  leaves about 7 s of Results before everyone goes home. Not yet
  tested in Studio: there's no panel until step 4.*
- [ ] **4. Staff panel (client).** A screen only staff can open, for
  picking a player in the server, then an item, then Give. It shows
  names only, never streaks or titles (Q7 condition 1).
- [ ] **5. Events.** A themed event (e.g. "Taco Tuesday") with a name,
  a music track and a schedule or a manual start. It runs in **every
  server at once**. During it, staff hand out gifts the step 2 way, to
  one chosen player or to everyone in their own server.

## Settled (owner, 2026-10-12)

- **Who a gift goes to:** staff pick either **one player in their own
  server** or **every player currently in their own server**. Staff
  can't reach players in other servers.
- **Event reach:** an event (its theme and music) runs in every server.
- **Taco Tuesday music:** "It's Raining Tacos", Creator Store audio
  `100847230469970`, uploaded by DistrokidOfficial (the licensed
  distributor). Avoid fan re-uploads.
