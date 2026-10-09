--!strict
-- The victory emote on Season 1's premium track (Seasons/Season1.luau). Played on the
-- results screen and the Decision Studio podium, never worn persistently
-- - see CosmeticService's own note on why "Emote" has nothing to apply
-- on spawn.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local VictoryFlexEmote: Validate.CosmeticDef = {
	id = "emote-victory-flex",
	category = "Emote",
	displayName = "Victory Flex",
	description = "Celebrate your wins with an emote on the results screen and the Studio podium.",
	rarity = "Uncommon",
	sortOrder = 20,
	enabled = true,
	animationAssetId = 86732319077255,
	previewIconAssetId = 100548500057990,
}

return VictoryFlexEmote
