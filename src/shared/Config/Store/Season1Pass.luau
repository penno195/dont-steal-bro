--!strict
-- Season 1's pass. It grants nothing itself: owning it unlocks the
-- premium track in Seasons/Season1.luau, which counts wins from when
-- ownership is first seen until the season ends. A pass is owned
-- forever, so every season sells a new one (rewards-roadmap.md step 5).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Season1Pass: Validate.StoreItemDef = {
	key = "season-1-pass",
	kind = "GamePass",
	assetId = 0, -- not created in the Creator Dashboard yet - see init.luau
	enabled = false,
	displayName = "Season 1 Pass",
	description = "Unlock Season 1's premium track: founder cosmetics, coins and power-ups as you win. Only wins until the season ends count.",
	robuxPrice = 199, -- PLACEHOLDER: display only, never read for a grant
	sortOrder = 10,
	grants = {},
}

return Season1Pass
