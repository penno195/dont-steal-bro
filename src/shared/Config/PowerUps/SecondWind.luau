--!strict
-- powerups.md #2. Full counter-play/stacking/reskin text lives in that
-- doc; this is only the structured, game-code-facing subset. Effect
-- application (cleansing active debuffs) is P2-8's job (Status Effects)
-- - this file only declares the item, per Ground Rule 2.
--
-- durationSeconds is the 2.5s post-cleanse immunity window - the cleanse
-- itself is instant, so the immunity window is the only real "duration"
-- this item has.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SecondWind: Validate.PowerUpDef = {
	id = "second-wind",
	displayName = "Second Wind",
	kind = "Buff",
	target = "Self",
	durationSeconds = 2.5,
	cooldownSeconds = 45,
	rarity = "Rare",
	hardControl = false,
	acquisition = { fieldPickup = true, loadoutEligible = true, freelyEarnable = true, robuxPrice = nil },
}

return SecondWind
