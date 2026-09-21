--!strict
-- powerups.md #9. Full counter-play/stacking/reskin text lives in that
-- doc; this is only the structured, game-code-facing subset. Effect
-- application (forcing the victim's current task challenge to re-roll)
-- and the 15s cumulative-exposure cap are P2-8's job (Status Effects) -
-- this file only declares the item, per Ground Rule 2.
--
-- durationSeconds is a minimal positive placeholder, not a real
-- countdown - the effect itself is instant (~4s is added task time, not
-- a lingering debuff state); Validate.checkPowerUp requires a positive
-- duration for every item, so this can't be literally 0.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local TaskScramble: Validate.PowerUpDef = {
	id = "task-scramble",
	displayName = "Task Scramble",
	kind = "Debuff",
	target = "Aimed",
	durationSeconds = 0.1,
	cooldownSeconds = 20,
	rarity = "Common",
	hardControl = false,
	acquisition = { fieldPickup = true, loadoutEligible = true, freelyEarnable = true, robuxPrice = nil },
}

return TaskScramble
