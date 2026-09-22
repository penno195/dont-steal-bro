--!strict
-- A consumable developer product: stock of one specific power-up, for
-- the pre-game loadout (powerups.md's second acquisition path).
--
-- Q8 IS CHECKED FROM BOTH ENDS. `sprint-boost`'s own config declares
-- `fieldPickup = true, freelyEarnable = true`, so it is earnable
-- without spending; Validate.run re-checks that from this side too, so
-- bundling a power-up that has no free path fails boot even when the
-- power-up's own file names no price of its own.
--
-- What this buys is a quantity of an item, not an advantage: the same
-- item spawns free on every map during every race, and the 3-slot
-- loadout cap (Q8, enforced in GameConfig.store.loadoutSlots) is the
-- same for a player who bought 500 of these and one who earned three.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SprintBoostStock: Validate.StoreItemDef = {
	key = "stock-sprint-boost-10",
	kind = "DeveloperProduct",
	assetId = 0,
	enabled = false,
	displayName = "Sprint Boost x10",
	description = "Ten Sprint Boosts for your loadout. Also earned free from Studio wins and found on every map.",
	robuxPrice = 79, -- PLACEHOLDER: display only
	sortOrder = 40,
	grants = {
		{ kind = "PowerUpStock", powerUpId = "sprint-boost", amount = 10 },
	},
}

return SprintBoostStock
