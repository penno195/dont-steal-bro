--!strict
-- A Streak Save (design-decisions.md, "Applied case: staff tools"): a
-- held item that does what a buy-back does. When a player loses with a
-- buy-back offer open and holds one, the offer card lets them spend it
-- instead of Robux (StoreService's UseStreakSaveIntent). A flat 100 R$,
-- whatever the streak: the buy-back tiers' "ends in 9" rule doesn't
-- apply here. Saves stack with no cap and never drop for free - the
-- only other way to get one is a staff gift. Validate keeps it off coin
-- offers and season tracks.
--
-- Ships disabled with no id until the owner creates the developer
-- product in Creator Hub and pastes its id in (Store/init.luau), with
-- its icon (assets/store/streak-save.png, not made yet).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local StreakSave: Validate.StoreItemDef = {
	key = "streak-save",
	kind = "DeveloperProduct",
	assetId = 0,
	enabled = false,
	displayName = "Streak Save",
	description = "Keep it for a bad day. Lose a streak and use this to carry on from where you were.",
	robuxPrice = 100, -- display only
	sortOrder = 50,
	imageAssetId = 0,
	grants = {
		{ kind = "StreakSave", amount = 1 },
	},
}

return StreakSave
