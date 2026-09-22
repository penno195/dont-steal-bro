--!strict
-- A permanent cosmetic game pass: the victory emote played on the
-- results screen and the Decision Studio podium. Cosmetic only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local VictoryEmotePass: Validate.StoreItemDef = {
	key = "victory-emote-pass",
	kind = "GamePass",
	assetId = 0,
	enabled = false,
	displayName = "Victory Emote",
	description = "Celebrate your wins with an emote on the results screen and the Studio podium.",
	robuxPrice = 99, -- PLACEHOLDER: display only
	sortOrder = 20,
	grants = {
		{ kind = "Cosmetic", cosmeticId = "emote-victory-flex" },
	},
}

return VictoryEmotePass
