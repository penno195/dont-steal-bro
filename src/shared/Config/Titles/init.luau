--!strict
-- Auto-collects every sibling title definition file. P4-2 filled in the
-- ladder: ten rungs from a first win to a streak nobody should have.
-- Add an eleventh the same way as a task - one file, nothing else to
-- touch (Ground Rule 2).
--
--   1   Got One             a first win, and the point is that it's dry
--   3   Three Deep
--   5   Hot Streak
--  10   Double Digits
--  15   Menace
--  25   Certified Problem
--  40   Untouchable
--  60   Final Boss          Glow
--  85   Actual Villain      Pulse
-- 120   Touch Grass         Rainbow
--
-- ON THE VOICE: these are bragging rights worn by a competitive Roblox
-- player, so they're short, flat, and never congratulate you - the
-- ladder gets funnier as it gets more absurd rather than grander. The
-- top rung is the community's own insult worn as a trophy, which is
-- exactly how a 120-round streak in a game that resets on any single
-- loss deserves to be marked.
--
-- ON THE THRESHOLDS: they widen deliberately (1, 3, 5, 10, 15, 25, 40,
-- 60, 85, 120). Any loss resets the streak completely (gdd.md), so the
-- probability of reaching a rung falls off a cliff rather than
-- linearly, and evenly-spaced thresholds would make the top half
-- unreachable-looking rather than aspirational. Each threshold must be
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
