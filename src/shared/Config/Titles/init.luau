--!strict
-- Auto-collects every sibling title definition file. P4-2 filled in the
-- ladder; design-decisions.md Q1's 2026-09-30 revision retuned it to
-- 21 rungs from a first win to a streak nobody should have. Add another
-- the same way as a task - one file, nothing else to touch (Ground
-- Rule 2).
--
--   1   Got One             a first win, and the point is that it's dry
--   2   Back To Back
--   3   Three Deep
--   4   Not A Fluke
--   5   Hot Streak
--   6   Suspicious
--   7   Reported
--   8   Under Review
--   9   Main Character
--  10   Double Digits
--  12   Sweaty
--  14   Tryhard
--  16   Menace
--  18   Lobby Ender
--  20   Twenty Deep
--  25   Certified Problem
--  30   Allegedly Legit
--  35   Untouchable
--  40   Final Boss          Glow
--  45   Actual Villain      Pulse
--  50   Touch Grass         Rainbow
--
-- ON THE VOICE: these are bragging rights worn by a competitive Roblox
-- player, so they're short, flat, and never congratulate you - the
-- ladder gets funnier as it gets more absurd rather than grander. The
-- 6-8 run reads as the lobby growing suspicious of you. The top rung
-- is the community's own insult worn as a trophy, which is exactly how
-- a 50-round streak in a game that resets on any single loss deserves
-- to be marked.
--
-- ON THE THRESHOLDS: one per win to 10, then every 2 to 20, then every
-- 5 to 50 (the user's choice, design-decisions.md Q1 revision). A
-- streak is a run of coin flips and any loss resets it completely
-- (gdd.md), so the odds of reaching a rung fall off a cliff - the
-- early rungs are dense so a short run still earns something, and 50
-- is already far rarer than it looks. The same rungs are the
-- streak-tier axis for win currency and drop odds. Each threshold must be
-- unique - Validate.run rejects two titles claiming the same rung,
-- because "the highest title you've unlocked" has to be a total order.
--
-- ON PERMANENCE: a title unlocks off bestStreak, never currentStreak,
-- and bestStreak is never lowered by anything (ProgressionLogic.
-- applyResult, P4-1) - so a title cannot be revoked by losing. The
-- profile field is append-only too (DataService.unlockTitle). Both
-- halves are structural rather than a rule someone has to remember.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.TitleDef> }
