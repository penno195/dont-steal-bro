--!strict
-- architecture.md §4's "Loyal {steal 0.2}". Means it almost every time,
-- which makes it the personality a human can actually build trust with
-- across rounds - and the one whose occasional betrayal lands hardest.
-- See init.luau for the rule every line obeys.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Loyal: Validate.NPCPersonalityDef = {
	id = "loyal",
	displayName = "Loyal",
	stealProbability = 0.2, -- architecture.md §4, verbatim
	weight = 1,

	lines = {
		promises = {
			"sharing. always do",
			"im share, no games",
			"share from me. do what u want",
		},
		pressure = {
			"cmon lets just all share",
			"dont ruin it for everyone",
			"3 shares is free money just take it",
		},
		accusations = {
			"why r u not saying anything",
			"that guy is gonna steal i swear",
			"u said share way too fast",
		},
		wobbles = {
			"idk now",
			"u lot r making me nervous",
			"im still share. i think",
		},
	},
}

return Loyal
