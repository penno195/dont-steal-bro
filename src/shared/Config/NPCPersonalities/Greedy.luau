--!strict
-- architecture.md §4's "Greedy {steal 0.7}". Talks the biggest share
-- game of the three and follows through least often - the lines lean on
-- promises and pressure precisely because the intent behind them is
-- usually a steal. See init.luau for the rule every line obeys.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local Greedy: Validate.NPCPersonalityDef = {
	id = "greedy",
	displayName = "Greedy",
	stealProbability = 0.7, -- architecture.md §4, verbatim
	weight = 1,

	lines = {
		promises = {
			"share share share trust me",
			"im sharing 100% bro",
			"we all share n we all go home happy",
		},
		pressure = {
			"say share now or im switching",
			"why is nobody typing lol",
			"last chance. say it",
		},
		accusations = {
			"hes gonna steal look at him",
			"u went quiet thats so sus",
			"nah u got that stealer energy",
		},
		wobbles = {
			"wait hold on",
			"ok ok im share... probably",
			"hmm",
		},
	},
}

return Greedy
