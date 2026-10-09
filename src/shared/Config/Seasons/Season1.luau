--!strict
-- Season 1, the first monthly season (design-decisions.md Q1; monthly
-- passes, user decision 2026-10-09). Both tracks count every win this
-- month. The free track is the retention tool, so it's the less generous
-- one; the premium track pays once the Season Pass (Store/SeasonPass) is
-- bought, including everything already reached. Every item here is
-- track-only forever, and Validate enforces that.
--
-- Every count and amount is PLACEHOLDER (rewards-roadmap.md step 7), and
-- the tiers are refilled in the season-pass items step. Ships disabled:
-- its cosmetics have no Roblox assets yet, and an enabled season may not
-- grant a disabled cosmetic.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Season1: Validate.SeasonDef = {
	id = "season-1",
	enabled = false,
	displayName = "Season 1",
	startsOn = "2026-11-01",
	endsOn = "2026-12-01",
	passKey = "season-pass",
	free = {
		{ wins = 3, grant = { kind = "Currency", amount = 50 } },
		{ wins = 10, grant = { kind = "PowerUpStock", powerUpId = "sprint-boost", amount = 3 } },
		{ wins = 25, grant = { kind = "Currency", amount = 250 } },
	},
	premium = {
		{ wins = 0, grant = { kind = "Cosmetic", cosmeticId = "trail-founder" } },
		{ wins = 5, grant = { kind = "Currency", amount = 75 } },
		{ wins = 10, grant = { kind = "Cosmetic", cosmeticId = "emote-victory-flex" } },
		{ wins = 20, grant = { kind = "PowerUpStock", powerUpId = "second-wind", amount = 2 } },
		{ wins = 30, grant = { kind = "Cosmetic", cosmeticId = "skin-founder" } },
	},
}

return Season1
