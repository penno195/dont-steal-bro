--!strict
-- One round of Navigation for Robux (design-decisions.md Q8,
-- "Navigation"). Sold only from the in-match toggle, never in the Hub
-- grid: a player with nothing to spend taps it and picks this or the
-- coin round. The round lands in `navigationRounds` and is spent on the
-- toggle's first switch-on in that race (NavigationService).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local NavigationRound: Validate.StoreItemDef = {
	key = "navigation-round",
	kind = "DeveloperProduct",
	assetId = 0, -- create the developer product (99 R$) in the Creator Dashboard, then enable
	enabled = false,
	displayName = "Navigation",
	description = "A path to your nearest unfinished station, for the rest of this round.",
	robuxPrice = 99, -- display only
	sortOrder = 200,
	imageAssetId = 0, -- assets/store/navigation-round.png: drawn, upload it and paste the id
	grants = {
		{ kind = "NavigationRound", amount = 1 },
	},
}

return NavigationRound
