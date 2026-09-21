--!strict
-- powerups.md #4. Full counter-play/stacking/reskin text lives in that
-- doc; this is only the structured, game-code-facing subset. Effect
-- application (untargetable by aimed/nearest effects) is P2-8's job
-- (Status Effects) - this file only declares the item, per Ground Rule 2.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local PhaseStep: Validate.PowerUpDef = {
	id = "phase-step",
	displayName = "Phase Step",
	kind = "Buff",
	target = "Self",
	durationSeconds = 3,
	cooldownSeconds = 30,
	rarity = "Rare",
	hardControl = false,
	acquisition = { fieldPickup = true, loadoutEligible = true, freelyEarnable = true, robuxPrice = nil },
}

return PhaseStep
