--!strict
-- The victory emote on Season 1's premium track (Seasons/Season1.luau).
-- Played on demand (EmoteController) and on the Decision Studio podium
-- when its wearer wins, never worn persistently - see CosmeticService's
-- own note on why "Emote" has nothing to apply on spawn.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local VictoryFlexEmote: Validate.CosmeticDef = {
	id = "emote-victory-flex",
	category = "Emote",
	displayName = "Victory Flex",
	description = "Flex anytime with G or the emote button. Plays by itself on the Studio podium when you win.",
	rarity = "Uncommon",
	sortOrder = 20,
	enabled = true,
	animationAssetId = 86732319077255,
	previewIconAssetId = 95305500617277,
}

return VictoryFlexEmote
