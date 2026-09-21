--!strict
-- powerups.md #7. Full counter-play/stacking/reskin text lives in that
-- doc; this is only the structured, game-code-facing subset. Effect
-- application (the -40% zone, and the -70% combined-stack floor across
-- overlapping zones) is P2-8's job (Status Effects) - this file only
-- declares the item, per Ground Rule 2. `hardControl = false`: Slow
-- Field is explicitly soft control (powerups.md's anti-frustration
-- layer), which is exactly why it needs its OWN separate stacking floor
-- rather than the hard-control rules Freeze/Push-Trip get.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SlowField: Validate.PowerUpDef = {
	id = "slow-field",
	displayName = "Slow Field",
	kind = "Debuff",
	target = "Area",
	durationSeconds = 5,
	cooldownSeconds = 30,
	rarity = "Common",
	hardControl = false,
	acquisition = { fieldPickup = true, loadoutEligible = true, freelyEarnable = true, robuxPrice = nil },
}

return SlowField
