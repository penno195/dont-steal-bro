# Decision Studio proximity chat — notes (P3-3)

Companion to `src/server/Services/StudioChat.luau` (text + voice access
control) and `src/client/Controllers/StudioChatController.luau` (typing/
speaking status). This is the answer the task itself asked for: what has
to be configured outside code, and what a player without voice actually
experiences.

## What must be configured outside code

1. **Voice chat must be enabled for the experience**, in Creator Hub
   under the experience's own Settings → Discovery (or the dedicated
   Voice settings page, depending on current Creator Hub layout) — this
   is the single switch that makes Roblox start auto-provisioning
   `AudioDeviceInput`/`AudioEmitter`/`AudioListener` for eligible players
   at all. Without it, `player:FindFirstChild("AudioDeviceInput")` never
   finds anything for anyone, and the whole experience runs in
   text-only mode regardless of any individual player's own settings.

2. **Age and verification requirements are entirely Roblox's own, not
   configurable per-experience.** Voice chat requires a player to be at
   least 13 and to have verified their account via phone number or
   government ID (country-dependent) — this is a platform-wide policy,
   not something this experience's settings can loosen or tighten. A
   player under 13, or 13+ but unverified, simply never gets an
   `AudioDeviceInput` — no code path in this repo can distinguish "too
   young" from "unverified" from "voice disabled experience-wide" from
   "declined the mic permission prompt"; all four look identical from
   the server (`FindFirstChild` returns nil) and are handled identically
   (text-only, gracefully).

3. **Text chat filtering needs nothing configured** — `TextChatService`
   filters every message automatically based on the sender's own account
   settings (age bracket, etc). Nothing in `StudioChat.luau` calls
   `TextService:FilterStringAsync` itself, and it shouldn't.

4. **Bubble chat needs `TextChatService.BubbleChatConfiguration.Enabled`
   to be true** for the Negotiate channel's messages to show as bubbles
   above the podiums at all — this is a global, experience-wide toggle,
   not something set per-channel. If it's already the project default,
   nothing further is needed; if bubble chat has been turned off
   experience-wide for some other reason, it needs to come back on for
   this phase to look right (there's no way to enable it for one channel
   only).

## What a player without voice actually experiences

**Nothing is lost.** This was the task's own absolute requirement -
"nothing in the finale may depend on being heard" - and it holds
structurally, not just as a design intention:

- They see and can type in the same restricted, proximity-gated text
  channel the other two finalists use, with bubble chat above their own
  and the other two podiums exactly as anyone else would.
- They see the same typing indicator (`StudioChatController.
  isPlayerTyping`) for the other two finalists that a voice-enabled
  player sees.
- `StudioChatController.isPlayerSpeaking` simply always returns `false`
  for them (they have no `AudioDeviceInput` to ever go `Active`) - a
  future HUD reading this should render that as "not currently speaking"
  rather than an error or a missing icon, since it's a completely normal
  and expected state, not a fallback for a broken feature.
- The Decision Studio's actual mechanics - locking in a choice, the
  reveal, the outcome - never reference voice or text state anywhere.
  `DecisionService.luau`'s own submission validation has no notion of
  "did this player participate in Negotiate" at all.

The one thing genuinely different for them: they can't be *heard*, so
they're reading and typing their negotiation rather than speaking it.
That's a real difference in how the round feels, not a difference in
what's possible to do or win.
