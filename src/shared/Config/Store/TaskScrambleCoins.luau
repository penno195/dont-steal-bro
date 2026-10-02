--!strict
-- A coin offer (rewards-roadmap.md step 6): one Task Scramble for earned coins.
-- Coins buy specific power-ups at fixed prices, never anything random
-- (design-decisions.md Q1). This is what makes Q8's "Robux buys time"
-- literal: the same stock a Robux product sells, bought with coins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local TaskScrambleCoins: Validate.StoreItemDef = {
	key = "task-scramble-coins",
	kind = "CoinOffer",
	assetId = 0, -- a CoinOffer has no Roblox asset
	enabled = true,
	displayName = "Task Scramble",
	description = "One Task Scramble for your loadout, bought with coins you've earned.",
	robuxPrice = 0,
	coinPrice = 150, -- PLACEHOLDER: about two to six wins (rewards-roadmap.md step 7)
	sortOrder = 110,
	grants = {
		{ kind = "PowerUpStock", powerUpId = "task-scramble", amount = 1 },
	},
}

return TaskScrambleCoins
