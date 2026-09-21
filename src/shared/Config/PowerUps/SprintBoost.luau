--!strict
-- powerups.md #1. Full counter-play/stacking/reskin text lives in that
-- doc; this is only the structured, game-code-facing subset. Effect
-- application (the actual +35% move speed) is P2-8's job (Status
-- Effects) - this file only declares the item, per Ground Rule 2.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SprintBoost: Validate.PowerUpDef = {
	id = "sprint-boost",
	displayName = "Sprint Boost",
	kind = "Buff",
	target = "Self",
	durationSeconds = 6,
	cooldownSeconds = 20,
	rarity = "Common",
	hardControl = false,
	acquisition = { fieldPickup = true, loadoutEligible = true, freelyEarnable = true, robuxPrice = nil },
}

return SprintBoost
