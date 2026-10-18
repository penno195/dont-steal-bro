--!strict
-- powerups.md #3. Full counter-play/stacking/reskin text lives in that
-- doc; this is only the structured, game-code-facing subset. Effect
-- application (-1 difficulty tier on the current task's rolled
-- challenge) is P2-8's job (Status Effects) - this file only declares
-- the item, per Ground Rule 2.
--
-- durationSeconds is the "next attempt (<=16s)" window the discount
-- applies within.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local TaskInsight: Validate.PowerUpDef = {
	id = "task-insight",
	displayName = "Task Insight",
	description = "Your next task attempt is easier",
	kind = "Buff",
	role = "Utility",
	target = "Self",
	durationSeconds = 16, -- was 15; design-decisions.md §12
	cooldownSeconds = 12,
	rarity = "Uncommon",
	hardControl = false,
	pictureAssetId = 100446077741631,
	acquisition = { fieldPickup = true, loadoutEligible = true, freelyEarnable = true, robuxPrice = nil },
}

return TaskInsight
