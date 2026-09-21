--!strict
-- powerups.md #10. Full counter-play/stacking/reskin text lives in that
-- doc; this is only the structured, game-code-facing subset. Effect
-- application (knockback + stagger) and the anti-frustration hard-
-- control rules are P2-8's job (Status Effects) - this file only
-- declares the item, per Ground Rule 2. `hardControl = true` - see
-- Freeze.luau's identical note on what that flag means downstream.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local PushTrip: Validate.PowerUpDef = {
	id = "push-trip",
	displayName = "Push/Trip",
	kind = "Debuff",
	target = "Nearest",
	durationSeconds = 1,
	cooldownSeconds = 15,
	rarity = "Common",
	hardControl = true,
	acquisition = { fieldPickup = true, loadoutEligible = true, freelyEarnable = true, robuxPrice = nil },
}

return PushTrip
