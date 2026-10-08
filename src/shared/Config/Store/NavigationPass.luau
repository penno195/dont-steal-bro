--!strict
-- Unlimited Navigation, for Robux only (design-decisions.md Q8,
-- "Navigation"). A perk pass, not a season pass: it grants nothing into
-- the profile, and NavigationService reads ownership live from
-- MarketplaceService each time the toggle is switched on.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local NavigationPass: Validate.StoreItemDef = {
	key = "navigation-pass",
	kind = "GamePass",
	assetId = 2021852267,
	enabled = true,
	displayName = "Unlimited Navigation",
	description = "Switch on Navigation in every round, for good. Shows a path to your nearest unfinished station.",
	robuxPrice = 899, -- display only
	sortOrder = 20,
	imageAssetId = 93138931039665, -- assets/store/navigation-pass.png
	grants = {},
	perk = "UnlimitedNavigation",
}

return NavigationPass
