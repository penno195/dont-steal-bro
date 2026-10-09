--!strict
-- powerups.md #6. Full counter-play/stacking/reskin text lives in that
-- doc; this is only the structured, game-code-facing subset. Effect
-- application (full immobilize) and the anti-frustration hard-control
-- rules (post-effect immunity, diminishing returns, the 15s rolling
-- disable-time cap) are P2-8's job (Status Effects) - this file only
-- declares the item, per Ground Rule 2. `hardControl = true` is what
-- tells P2-8's resolver this item is subject to those rules at all.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Freeze: Validate.PowerUpDef = {
	id = "freeze",
	displayName = "Freeze",
	description = "Freezes a rival in place",
	kind = "Debuff",
	role = "Attack",
	target = "Aimed",
	durationSeconds = 4.5, -- was 2.5, then 3.5; design-decisions.md §12
	cooldownSeconds = 12,
	rarity = "Uncommon",
	hardControl = true,
	impact = { style = "Frost", rgb = { 150, 215, 255 } }, -- icy shards and frost mist
	victimLook = "Frozen", -- encased in an ice block
	acquisition = { fieldPickup = true, loadoutEligible = true, freelyEarnable = true, robuxPrice = nil },
}

return Freeze
