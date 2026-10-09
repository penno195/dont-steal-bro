--!strict
-- Season 1, the first monthly season (design-decisions.md Q1; monthly
-- passes, user decision 2026-10-09). Both tracks count every win this
-- month. The free track is the retention tool, so it's the less generous
-- one; the premium track pays once the Season Pass (Store/SeasonPass) is
-- bought, including everything already reached. Every item here is
-- track-only forever, and Validate enforces that.
--
-- The lineup is the owner's (2026-10-09): eleven columns from 0 to 30
-- wins, a paid item at every column and a free one at every other, with
-- five new wearables. Amounts are still PLACEHOLDER (rewards-roadmap.md
-- step 7b). Runs long, from launch to the end of November (owner,
-- 2026-10-09), since the first weeks will be quiet; monthly after that.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Season1: Validate.SeasonDef = {
	id = "season-1",
	enabled = true,
	displayName = "Season 1",
	startsOn = "2026-10-09",
	endsOn = "2026-12-01",
	passKey = "season-pass",
	free = {
		{ wins = 2, grant = { kind = "Currency", amount = 50 } },
		{ wins = 6, grant = { kind = "PowerUpStock", powerUpId = "sprint-boost", amount = 3 } },
		{ wins = 10, grant = { kind = "Cosmetic", cosmeticId = "hat-traffic-cone" } },
		{ wins = 16, grant = { kind = "Currency", amount = 100 } },
		{ wins = 20, grant = { kind = "PowerUpStock", powerUpId = "task-insight", amount = 2 } },
		{ wins = 30, grant = { kind = "Currency", amount = 250 } },
	},
	premium = {
		{ wins = 0, grant = { kind = "Cosmetic", cosmeticId = "back-loot-sack" } },
		{ wins = 2, grant = { kind = "Currency", amount = 75 } },
		{ wins = 4, grant = { kind = "Cosmetic", cosmeticId = "hat-burglar-beanie" } },
		{ wins = 6, grant = { kind = "Cosmetic", cosmeticId = "trail-founder" } },
		{ wins = 8, grant = { kind = "PowerUpStock", powerUpId = "second-wind", amount = 2 } },
		{ wins = 10, grant = { kind = "Cosmetic", cosmeticId = "emote-victory-flex" } },
		{ wins = 13, grant = { kind = "Currency", amount = 150 } },
		{ wins = 16, grant = { kind = "Cosmetic", cosmeticId = "hat-game-show-top-hat" } },
		{ wins = 20, grant = { kind = "PowerUpStock", powerUpId = "overclock", amount = 2 } },
		{ wins = 25, grant = { kind = "Cosmetic", cosmeticId = "skin-founder" } },
		{ wins = 30, grant = { kind = "Cosmetic", cosmeticId = "back-gold-bar-jetpack" } },
	},
}

return Season1
