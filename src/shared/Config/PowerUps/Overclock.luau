--!strict
-- powerups.md #5. Full counter-play/stacking/reskin text lives in that
-- doc; this is only the structured, game-code-facing subset. Effect
-- application (-50% cooldown on the player's other power-ups) is P2-8's
-- job (Status Effects) - this file only declares the item, per Ground
-- Rule 2.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Overclock: Validate.PowerUpDef = {
	id = "overclock",
	displayName = "Overclock",
	kind = "Buff",
	target = "Self",
	durationSeconds = 10,
	cooldownSeconds = 40,
	rarity = "Rare",
	hardControl = false,
	acquisition = { fieldPickup = true, loadoutEligible = true, freelyEarnable = true, robuxPrice = nil },
}

return Overclock
