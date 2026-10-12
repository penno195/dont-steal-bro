--!strict
-- Taco Tuesday (owner, 2026-10-12): tacos rain down and disco balls
-- spin over the lobby while "It's Raining Tacos" plays. Started by hand
-- from the staff panel; the day in the name is a theme, not a schedule.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local def: Validate.EventDef = {
	id = "taco-tuesday",
	enabled = true,
	displayName = "Taco Tuesday",
	-- "It's Raining Tacos", uploaded by DistrokidOfficial, the licensed
	-- distributor (staff-tools.md). Avoid fan re-uploads.
	musicAssetId = "rbxassetid://100847230469970",
	view = "TacoTuesday",
}

return def
