--!strict
-- architecture.md §4's "Chaotic {0.5}". A coin flip, and the lines are
-- written so that nothing it says narrows that down - it contradicts
-- itself on purpose, which is the only honest way to present a bot
-- whose intent genuinely carries no information. See init.luau for the
-- rule every line obeys.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Chaotic: Validate.NPCPersonalityDef = {
	id = "chaotic",
	displayName = "Chaotic",
	stealProbability = 0.5, -- architecture.md §4, verbatim
	weight = 1,

	lines = {
		promises = {
			"share obviously",
			"yeah im share whatever",
			"share. or not. share",
		},
		pressure = {
			"someones stealing here lets go",
			"speed round pick now",
			"no one talk just lock it",
		},
		accusations = {
			"its u. i can feel it",
			"u typed too much ur lying",
			"he said share twice thats suspicious",
		},
		wobbles = {
			"changed my mind",
			"lol wait",
			"im doing it. or am i",
		},
	},
}

return Chaotic
