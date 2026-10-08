--!strict
-- One round of Navigation for earned coins: the coin path that keeps Q8
-- true (design-decisions.md, "Navigation"). Every free player can switch
-- it on in any round; Robux only buys never paying again. The first coin
-- offer that isn't power-up stock, which Validate allows by name.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local NavigationRoundCoins: Validate.StoreItemDef = {
	key = "navigation-round-coins",
	kind = "CoinOffer",
	assetId = 0, -- a CoinOffer has no Roblox asset
	enabled = false, -- the toggle has shipped; enable once the art id is in
	displayName = "Navigation",
	description = "A path to your nearest unfinished station, for the rest of this round, bought with coins.",
	robuxPrice = 0,
	coinPrice = 100, -- owner's pick (2026-10-08), a little above Robux parity (~85)
	sortOrder = 201,
	imageAssetId = 0, -- shares navigation-round.png (drawn); paste the same uploaded id
	grants = {
		{ kind = "NavigationRound", amount = 1 },
	},
}

return NavigationRoundCoins
