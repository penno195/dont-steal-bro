--!strict
-- Covers TelemetryLogic.luau: the event -> AnalyticsService call mapping,
-- and the guards that keep custom fields inside the platform's limits
-- (3 string fields, 8,000 combinations).

local TestRunner = require("./TestRunner")
local TelemetryLogic = require("../src/server/TelemetryLogic")

local round: TelemetryLogic.RoundContext = { roundId = "job:1", mapId = "School", humans = 4 }

TestRunner.describe("TelemetryLogic.field", function()
	TestRunner.it("prefixes the dimension name", function()
		TestRunner.expect(TelemetryLogic.field("Map", "School")):toBe("Map: School")
		TestRunner.expect(TelemetryLogic.field("Humans", 4)):toBe("Humans: 4")
	end)

	TestRunner.it("strips odd characters and caps the length", function()
		TestRunner.expect(TelemetryLogic.field("Map", "a<b>\n{c}")):toBe("Map: abc")
		local long = TelemetryLogic.field("X", string.rep("z", 500))
		TestRunner.expect(#long):toBe(#"X: " + 40)
	end)

	TestRunner.it("never sends an empty value", function()
		TestRunner.expect(TelemetryLogic.field("Map", "")):toBe("Map: none")
		TestRunner.expect(TelemetryLogic.field("Map", "!!!")):toBe("Map: none")
	end)
end)

TestRunner.describe("TelemetryLogic.streakBand", function()
	TestRunner.it("bands at the edges", function()
		TestRunner.expect(TelemetryLogic.streakBand(0)):toBe("0")
		TestRunner.expect(TelemetryLogic.streakBand(1)):toBe("1-2")
		TestRunner.expect(TelemetryLogic.streakBand(2)):toBe("1-2")
		TestRunner.expect(TelemetryLogic.streakBand(3)):toBe("3-4")
		TestRunner.expect(TelemetryLogic.streakBand(5)):toBe("5-9")
		TestRunner.expect(TelemetryLogic.streakBand(19)):toBe("10-19")
		TestRunner.expect(TelemetryLogic.streakBand(20)):toBe("20+")
		TestRunner.expect(TelemetryLogic.streakBand(5000)):toBe("20+")
		TestRunner.expect(TelemetryLogic.streakBand(-1)):toBe("0")
	end)
end)

TestRunner.describe("TelemetryLogic.returnReason", function()
	TestRunner.it("keeps only reasons the match server sends", function()
		TestRunner.expect(TelemetryLogic.returnReason("RoundOver")):toBe("RoundOver")
		TestRunner.expect(TelemetryLogic.returnReason("Late")):toBe("Late")
		TestRunner.expect(TelemetryLogic.returnReason("Hacked lol")):toBe("Unknown")
		TestRunner.expect(TelemetryLogic.returnReason(nil)):toBe("Unknown")
		TestRunner.expect(TelemetryLogic.returnReason({})):toBe("Unknown")
	end)
end)

TestRunner.describe("TelemetryLogic funnels", function()
	TestRunner.it("keys the Round funnel on the round id, with named steps", function()
		local record = TelemetryLogic.roundStep(round, TelemetryLogic.RoundStep.ChoiceLocked)
		TestRunner.expect(record.kind):toBe("Funnel")
		TestRunner.expect(record.name):toBe("Round")
		TestRunner.expect(record.sessionId):toBe("job:1")
		TestRunner.expect(record.step):toBe(5)
		TestRunner.expect(record.stepName):toBe("ChoiceLocked")
	end)

	TestRunner.it("gives every Round step the same fields, so the funnel can be split", function()
		local first = TelemetryLogic.roundStep(round, TelemetryLogic.RoundStep.Started)
		local last = TelemetryLogic.roundStep(round, TelemetryLogic.RoundStep.ResultReceived)
		for slot = 1, 3 do
			TestRunner.expect(first.fields[slot]):toBe(last.fields[slot])
		end
		TestRunner.expect(first.fields[1]):toBe("Map: School")
		TestRunner.expect(first.fields[2]):toBe("Humans: 4")
		TestRunner.expect(first.fields[3]):toBe(nil)
	end)

	TestRunner.it("adds the config version once there is one", function()
		local versioned = table.clone(round)
		versioned.configVersion = "v12"
		local record = TelemetryLogic.roundStep(versioned, TelemetryLogic.RoundStep.Started)
		TestRunner.expect(record.fields[3]):toBe("Config: v12")
	end)

	TestRunner.it("numbers steps 1..n with no gaps", function()
		local seen = {}
		local count = 0
		for _, step in TelemetryLogic.RoundStep do
			seen[step] = true
			count += 1
		end
		for step = 1, count do
			TestRunner.expect(seen[step]):toBe(true)
		end
	end)

	TestRunner.it("runs the Matchmaking funnel on its own session id", function()
		local record = TelemetryLogic.matchmakingStep("guid", TelemetryLogic.MatchmakingStep.Matched)
		TestRunner.expect(record.name):toBe("Matchmaking")
		TestRunner.expect(record.sessionId):toBe("guid")
		TestRunner.expect(record.stepName):toBe("Matched")
	end)
end)

TestRunner.describe("TelemetryLogic custom events", function()
	TestRunner.it("puts unbounded numbers in value, never in a field", function()
		local choice = TelemetryLogic.stealShareChoice("Steal", 37, 0, 4)
		TestRunner.expect(choice.kind):toBe("Custom")
		TestRunner.expect(choice.value):toBe(37)
		TestRunner.expect(choice.fields[1]):toBe("Choice: Steal")
		TestRunner.expect(choice.fields[2]):toBe("Bots: 0")
		TestRunner.expect(choice.fields[3]):toBe("Rung: 4")

		local loss = TelemetryLogic.streakLoss(12, "StudioLoss", "Museum")
		TestRunner.expect(loss.value):toBe(12)
		TestRunner.expect(loss.fields[2]):toBe("Streak: 10-19")
	end)

	TestRunner.it("leaves the rung slot out when the caller has none", function()
		TestRunner.expect(TelemetryLogic.stealShareChoice("Share", 0, 2, nil).fields[3]):toBe(nil)
	end)

	TestRunner.it("labels the config resolution so a rollout splits", function()
		TestRunner.expect(TelemetryLogic.configLabel("Staged", 7)):toBe("Staged v7")
		local staged = table.clone(round)
		staged.configVersion = TelemetryLogic.configLabel("Staged", 7)
		TestRunner.expect(TelemetryLogic.roundStep(staged, 1).fields[3]):toBe("Config: Staged v7")
	end)

	TestRunner.it("times an abandoned task and says how they left", function()
		local record = TelemetryLogic.taskAbandoned("fuse-rewire", 9.9, "Switched", "Factory")
		TestRunner.expect(record.name):toBe("TaskAbandoned")
		TestRunner.expect(record.value):toBe(9)
		TestRunner.expect(record.fields[3]):toBe("Exit: Switched")
	end)

	TestRunner.it("ends a round with race length in value", function()
		local record = TelemetryLogic.roundEnded("School", 181.6, 2, 4)
		TestRunner.expect(record.value):toBe(181)
		TestRunner.expect(record.fields[2]):toBe("Finishers: 2")
		TestRunner.expect(record.fields[3]):toBe("Humans: 4")
	end)

	TestRunner.it("puts bot seats on a win, and says when they're unknown", function()
		local win = TelemetryLogic.streakWin(6, 3, "Museum")
		TestRunner.expect(win.value):toBe(6)
		TestRunner.expect(win.fields[1]):toBe("Streak: 5-9")
		TestRunner.expect(win.fields[2]):toBe("Bots: 3")
		TestRunner.expect(TelemetryLogic.streakWin(1, nil, "m").fields[2]):toBe("Bots: unknown")
	end)

	TestRunner.it("floors task seconds and splits by task, map and order", function()
		local record = TelemetryLogic.taskCompleted("reactor-sync", 14.8, 2, "Laboratory")
		TestRunner.expect(record.name):toBe("TaskCompleted")
		TestRunner.expect(record.value):toBe(14)
		TestRunner.expect(record.fields[1]):toBe("Task: reactor-sync")
		TestRunner.expect(record.fields[2]):toBe("Map: Laboratory")
		TestRunner.expect(record.fields[3]):toBe("Order: 2")
	end)

	TestRunner.it("reports power-up results without the target", function()
		local record = TelemetryLogic.powerUpUsed("Freeze", false, "Factory")
		TestRunner.expect(record.fields[2]):toBe("Result: Refused")
		TestRunner.expect(record.value):toBe(nil)
	end)

	TestRunner.it("never carries more than three fields", function()
		local records = {
			TelemetryLogic.taskCompleted("t", 1, 1, "m"),
			TelemetryLogic.mapVoted("m"),
			TelemetryLogic.mapPlayed("m", 3),
			TelemetryLogic.powerUpUsed("p", true, "m"),
			TelemetryLogic.stealShareChoice("Steal", 3, 1, 1),
			TelemetryLogic.finaleOutcome("AllShare", 3, 1),
			TelemetryLogic.streakLoss(3, "FailedToQualify", "m"),
			TelemetryLogic.npcCountInRound(2, 4, "m"),
			TelemetryLogic.purchaseCompleted("p", "GamePass", 99),
			TelemetryLogic.returnedToHub("RoundOver"),
			TelemetryLogic.taskAbandoned("t", 1, "Closed", "m"),
			TelemetryLogic.powerUpCollected("p", "Pickup", "m"),
			TelemetryLogic.roundEnded("m", 1, 0, 1),
			TelemetryLogic.streakWin(1, 0, "m"),
		}
		for _, record in records do
			for key in record.fields do
				TestRunner.expect(type(key) == "number" and key >= 1 and key <= 3):toBe(true)
			end
		end
	end)
end)
