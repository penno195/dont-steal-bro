--!strict
-- The Season Pass launch offer: 99 R$ instead of 199 (user decision,
-- 2026-10-09, design-decisions.md Q1 "the featured plinths"). A second
-- developer product granting the same pass. While it's on sale it
-- `replaces` the full-price SeasonPass, so a request for the pass is
-- sold through this one; after onSaleUntil the 199 R$ product is back
-- on its own, with no Creator Dashboard change on the day.
--
-- TO SWITCH ON: create a 99 R$ developer product on the Creator
-- Dashboard (same icon as the Season Pass), paste its id into assetId,
-- set onSaleUntil to the offer's real end, and set enabled = true.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local SeasonPassLaunch: Validate.StoreItemDef = {
	key = "season-pass-launch",
	kind = "DeveloperProduct",
	assetId = 3717654890,
	enabled = true,
	displayName = "Season Pass",
	description = "Launch offer! Unlock this season's paid tiers. Every win this season counts, including the ones you've already won.",
	robuxPrice = 99, -- display only; Roblox charges the product's dashboard price
	wasPrice = 199,
	onSaleUntil = "2026-12-01 00:00", -- the owner: until December's pass (Season 1's endsOn)
	replaces = "season-pass",
	featuredSlot = 2, -- the centre plinth (StorePodium2, x 182)
	-- assets/seasonpass/models/GoldenTicket (Meshy), ~4 studs across
	plinthModel = { meshAssetId = 136634816390121, textureAssetId = 135638183265178, scale = 0.022 },
	sortOrder = 10,
	imageAssetId = 125004472230907, -- assets/store/season-pass.png (crown ticket, 2026-10-10)
	grants = { { kind = "SeasonPass" } },
}

return SeasonPassLaunch
