--!strict
-- powerups.md #8. Full counter-play/stacking/reskin text lives in that
-- doc; this is only the structured, game-code-facing subset. Effect
-- application (obscuring the target's screen, never movement) is P2-8's
-- job (Status Effects) - this file only declares the item, per Ground
-- Rule 2.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Blind: Validate.PowerUpDef = {
	id = "blind",
	displayName = "Blind",
	kind = "Debuff",
	target = "Nearest",
	durationSeconds = 4,
	cooldownSeconds = 25,
	rarity = "Uncommon",
	hardControl = false,
	acquisition = { fieldPickup = true, loadoutEligible = true, freelyEarnable = true, robuxPrice = nil },
}

return Blind
