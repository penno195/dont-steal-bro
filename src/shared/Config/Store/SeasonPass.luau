--!strict
-- The season pass: one developer product, bought again each month (user
-- decision, 2026-10-09). Buying it unlocks the live season's premium
-- track and pays every premium item that season's wins already reached
-- (SeasonLogic.buyPass). A game pass can't do this: it's owned forever.
-- Every Config/Seasons file names this as its passKey.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SeasonPass: Validate.StoreItemDef = {
	key = "season-pass",
	kind = "DeveloperProduct",
	assetId = 0, -- create the developer product in Creator Hub, then paste its id here
	enabled = false,
	displayName = "Season Pass",
	description = "Unlock this month's paid tiers. Every win this season counts, including the ones you've already won.",
	robuxPrice = 199, -- PLACEHOLDER: display only, never read for a grant
	sortOrder = 10,
	imageAssetId = 130933629115331, -- assets/store/season-pass.png
	grants = { { kind = "SeasonPass" } },
}

return SeasonPass
