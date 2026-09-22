--!strict
-- A consumable developer product bundling stock of three power-ups -
-- the "skip the grind" purchase, and the one worth reading
-- docs/store-receipts.md §"Pay-to-win review" about before enabling.
--
-- Everything in it is a Common, every item in it spawns free on every
-- map, and it grants quantity only. It does not raise the loadout cap,
-- because nothing can: GameConfig.store.loadoutSlots is validated to be
-- exactly 3 (design-decisions.md Q8).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local StarterLoadoutBundle: Validate.StoreItemDef = {
	key = "bundle-starter-loadout",
	kind = "DeveloperProduct",
	assetId = 0,
	enabled = false,
	displayName = "Starter Loadout Bundle",
	description = "Five each of Sprint Boost, Slow Field and Push-Trip. Every one of them is also earned free by playing.",
	robuxPrice = 149, -- PLACEHOLDER: display only
	sortOrder = 41,
	grants = {
		{ kind = "PowerUpStock", powerUpId = "sprint-boost", amount = 5 },
		{ kind = "PowerUpStock", powerUpId = "slow-field", amount = 5 },
		{ kind = "PowerUpStock", powerUpId = "push-trip", amount = 5 },
	},
}

return StarterLoadoutBundle
