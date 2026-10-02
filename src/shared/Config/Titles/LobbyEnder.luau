--!strict
-- P4-2's title ladder, rung 14 of 21. See init.luau for the ladder as a
-- whole and the voice these are written in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local LobbyEnder: Validate.TitleDef = {
	id = "lobby-ender",
	displayName = "Lobby Ender",
	colorHex = "#e04ab8",
	minStreak = 18,
}

return LobbyEnder
