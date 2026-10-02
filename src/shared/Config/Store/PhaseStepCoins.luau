--!strict
-- A coin offer (rewards-roadmap.md step 6): one Phase Step for earned coins.
-- Coins buy specific power-ups at fixed prices, never anything random
-- (design-decisions.md Q1). This is what makes Q8's "Robux buys time"
-- literal: the same stock a Robux product sells, bought with coins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local PhaseStepCoins: Validate.StoreItemDef = {
	key = "phase-step-coins",
	kind = "CoinOffer",
	assetId = 0, -- a CoinOffer has no Roblox asset
	enabled = true,
	displayName = "Phase Step",
	description = "One Phase Step for your loadout, bought with coins you've earned.",
	robuxPrice = 0,
	coinPrice = 25, -- one rung-0 win of any outcome (design-decisions.md Q1, 2026-10-02 pricing)
	sortOrder = 104,
	grants = {
		{ kind = "PowerUpStock", powerUpId = "phase-step", amount = 1 },
	},
}

return PhaseStepCoins
