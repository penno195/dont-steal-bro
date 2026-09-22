--!strict
-- Covers Validate.luau (P1-4): the pure half of the config layer.
-- ConfigValidator.luau itself isn't required here - it touches
-- ServerStorage/GetChildren at call time, so it's exercised manually in
-- Studio instead, same split as NetGuard.luau/Net.spec.luau (P1-3).

local TestRunner = require("./TestRunner")
local Validate = require("../src/shared/Config/Validate")

local function validGameConfig(): Validate.GameConfig
	return {
		playerCount = 6,
		qualifierCount = 3,
		tasksPerPlayer = 6,
		qualificationFloorPercent = 0.5,
		streakLossWeight = 2,
		npcSeatStreakCreditThreshold = 3,
		raceDurationSeconds = 300,
		studioTimers = { introSeconds = 5, negotiateSeconds = 45, chooseSeconds = 15, revealDelaySeconds = 1 },
		roundTimers = {
			loadingSeconds = 5,
			introSeconds = 5,
			qualifiedSeconds = 3,
			resultsSeconds = 8,
			cleanupSeconds = 5,
		},
		bountyTiers = {
			{ tier = 1, minStreak = 0, soleStealerVU = 20, loneSharerVU = 10, allShareVU = 5 },
			{ tier = 2, minStreak = 3, soleStealerVU = 24, loneSharerVU = 12, allShareVU = 6 },
		},
		powerUpInventorySlots = 1,
		powerUpFullInventoryPolicy = "Refuse",
		powerUpUseRangeStuds = 24,
		powerUpTargetConeDegrees = 90,
		powerUpRotationTimers = { Common = 20, Uncommon = 35, Rare = 60 },
		movementSampleIntervalSeconds = 0.5,
		movementSpeedTolerance = 1.25,
		movementViolationDecayPerSecond = 0.5,
		movementViolationLogThreshold = 1.0,
		movementViolationFlagThreshold = 3.0,
		movementViolationActThreshold = 6.0,
		decisionStudioDefaultChoice = "Share",
		decisionStudioChatRangeStuds = 30,
		npc = {
			fillGraceSeconds = 10,
			tickHz = 8,
			skillProfiles = {
				{ id = "Casual", weight = 0.3, durationScale = 1.35, moveSpeedScale = 0.9 },
				{ id = "Sweaty", weight = 0.2, durationScale = 0.9, moveSpeedScale = 1.05 },
			},
			fairnessFloorScale = 1.0,
			medianSampleMinimum = 3,
			stationArrivalRadiusStuds = 6,
			nextStationTopK = 2,
			repathAfterStuckSeconds = 1.5,
			maxRepathsPerStation = 5,
		},
		npcBrain = {
			decisionHz = 2,
			utility = {
				baseScore = 0.3,
				deficitWeight = 0.35,
				proximityWeight = 0.5,
				travelWeight = 0.4,
				deficitSaturation = 3,
				travelSaturationStuds = 80,
				useThreshold = 0.6,
			},
			lockInEarliestFraction = 0.25,
			lockInLatestFraction = 0.8,
			negotiationLineCount = 3,
			minSecondsBetweenLines = 6,
			chooseWobbleChance = 0.5,
		},
		leaderboard = {
			storeName = "TestBoard",
			storeScope = "global",
			topCount = 100,
			refreshMinSeconds = 60,
			refreshMaxSeconds = 120,
			staleAfterSeconds = 300,
			nameCacheTtlSeconds = 3600,
			maxWriteAttempts = 3,
			backoffBaseSeconds = 1,
			backoffCapSeconds = 60,
			budget = { perWindow = 60, windowSeconds = 60, softCeiling = 0.7 },
			snapshotStoreName = "TestSnapshots",
			periodGraceSeconds = 3600,
			rewardTopN = 10,
		},
		store = {
			purchaseIdCacheSize = 100,
			receiptSaveRetrySeconds = 10,
			receiptMaxWaitSeconds = 120,
			receiptProfileWaitSeconds = 30,
			passCacheOwnedTtlSeconds = 3600,
			passCacheUnownedTtlSeconds = 60,
			loadoutSlots = 3,
		},
		titleDisplayDuringRound = false,
		npcTitleNoneChance = 0.35,
		npcTitleTopRungsExcluded = 3,
	}
end

local function validPersonality(id: string): Validate.NPCPersonalityDef
	return {
		id = id,
		displayName = "Test Personality",
		stealProbability = 0.5,
		weight = 1,
		lines = {
			promises = { "share bro" },
			pressure = { "say it now" },
			accusations = { "its u" },
			wobbles = { "hmm" },
		},
	}
end

local function validTask(id: string): Validate.TaskDef
	return {
		id = id,
		displayName = "Test Task",
		verb = "Tap",
		expectedDurationSeconds = { min = 6, max = 8 },
		mobileFeasibility = 5,
	}
end

local function validMap(id: string, taskIds: { string }): Validate.MapDef
	return {
		id = id,
		displayName = "Test Map",
		description = "A map.",
		thumbnailAssetId = "rbxassetid://1",
		lightingPreset = "Default",
		musicTrackId = "rbxassetid://2",
		enabledTaskIds = taskIds,
		npcDifficultyModifier = 1.0,
		waveNumber = 1,
		enabled = true,
		taskStationCount = 12,
		powerUpRarityWeightMultipliers = nil,
	}
end

local function validPowerUp(id: string): Validate.PowerUpDef
	return {
		id = id,
		displayName = "Test Power-Up",
		kind = "Buff",
		target = "Self",
		durationSeconds = 6,
		cooldownSeconds = 20,
		rarity = "Common",
		hardControl = false,
		acquisition = { fieldPickup = true, loadoutEligible = true, freelyEarnable = false, robuxPrice = nil },
	}
end

local function validTitle(id: string, minStreak: number): Validate.TitleDef
	return { id = id, displayName = "Test Title", colorHex = "#1c6b67", minStreak = minStreak }
end

TestRunner.describe("Validate.run (happy path)", function()
	TestRunner.it("reports no issues for an internally-consistent registry set", function()
		local issues = Validate.run({
			gameConfig = validGameConfig(),
			maps = { { fileName = "TestMap.luau", def = validMap("test-map", { "pressure-valve" }) } },
			tasks = { { fileName = "PressureValve.luau", def = validTask("pressure-valve") } },
			powerUps = { { fileName = "TestPowerUp.luau", def = validPowerUp("test-powerup") } },
			titles = { { fileName = "TestTitle.luau", def = validTitle("test-title", 0) } },
		})
		TestRunner.expect(#issues):toBe(0)
	end)
end)

TestRunner.describe("Validate.checkTask", function()
	TestRunner.it("rejects an empty id", function()
		local issues = {}
		local task = validTask("")
		Validate.checkTask("X.luau", task, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects min > max in expectedDurationSeconds", function()
		local issues = {}
		local task = validTask("x")
		task.expectedDurationSeconds = { min = 10, max = 5 }
		Validate.checkTask("X.luau", task, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects an out-of-range mobileFeasibility", function()
		local issues = {}
		local task = validTask("x")
		task.mobileFeasibility = 9
		Validate.checkTask("X.luau", task, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)
end)

TestRunner.describe("Validate.checkMap", function()
	TestRunner.it("rejects a taskStationCount below the map-kit-spec.md floor of 12", function()
		local issues = {}
		local map = validMap("m", {})
		map.taskStationCount = 5
		Validate.checkMap("M.luau", map, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects an invalid waveNumber", function()
		local issues = {}
		local map = validMap("m", {})
		map.waveNumber = 7
		Validate.checkMap("M.luau", map, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("accepts an omitted powerUpRarityWeightMultipliers (nil = no override)", function()
		local issues = {}
		local map = validMap("m", { "pressure-valve" }) -- non-empty enabledTaskIds, so only THIS field is under test
		map.powerUpRarityWeightMultipliers = nil
		Validate.checkMap("M.luau", map, issues)
		TestRunner.expect(#issues):toBe(0)
	end)

	TestRunner.it("rejects a non-positive powerUpRarityWeightMultipliers entry", function()
		local issues = {}
		local map = validMap("m", {})
		map.powerUpRarityWeightMultipliers = { Common = 1, Uncommon = 1, Rare = 0 }
		Validate.checkMap("M.luau", map, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)
end)

TestRunner.describe("Validate.checkPowerUp (design-decisions.md Q8)", function()
	TestRunner.it("rejects a Robux price with no free acquisition path", function()
		local issues = {}
		local powerUp = validPowerUp("p")
		powerUp.acquisition = { fieldPickup = false, loadoutEligible = true, freelyEarnable = false, robuxPrice = 99 }
		Validate.checkPowerUp("P.luau", powerUp, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("accepts a Robux price alongside a free field-pickup path", function()
		local issues = {}
		local powerUp = validPowerUp("p")
		powerUp.acquisition = { fieldPickup = true, loadoutEligible = true, freelyEarnable = false, robuxPrice = 99 }
		Validate.checkPowerUp("P.luau", powerUp, issues)
		TestRunner.expect(#issues):toBe(0)
	end)
end)

TestRunner.describe("Validate.checkTitle", function()
	TestRunner.it("rejects a negative minStreak", function()
		local issues = {}
		Validate.checkTitle("T.luau", validTitle("t", -1), issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects a malformed colorHex", function()
		local issues = {}
		local title = validTitle("t", 0)
		title.colorHex = "teal"
		Validate.checkTitle("T.luau", title, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)
end)

TestRunner.describe("Validate.checkGameConfig (P2-7 power-up fields)", function()
	TestRunner.it("rejects a non-positive powerUpInventorySlots", function()
		local issues = {}
		local config = validGameConfig()
		config.powerUpInventorySlots = 0
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects a powerUpFullInventoryPolicy that isn't Swap or Refuse", function()
		local issues = {}
		local config = validGameConfig()
		config.powerUpFullInventoryPolicy = "Discard" :: any
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects a powerUpTargetConeDegrees above 360", function()
		local issues = {}
		local config = validGameConfig()
		config.powerUpTargetConeDegrees = 400
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects a non-positive powerUpRotationTimers entry", function()
		local issues = {}
		local config = validGameConfig()
		config.powerUpRotationTimers = { Common = 20, Uncommon = 35, Rare = -1 }
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)
end)

TestRunner.describe("Validate.checkGameConfig (P2-9 movement-watch fields)", function()
	TestRunner.it("rejects a non-positive movementSampleIntervalSeconds", function()
		local issues = {}
		local config = validGameConfig()
		config.movementSampleIntervalSeconds = 0
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects a non-positive movementSpeedTolerance", function()
		local issues = {}
		local config = validGameConfig()
		config.movementSpeedTolerance = 0
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects a negative movementViolationDecayPerSecond", function()
		local issues = {}
		local config = validGameConfig()
		config.movementViolationDecayPerSecond = -1
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects thresholds not ordered log <= flag <= act", function()
		local issues = {}
		local config = validGameConfig()
		config.movementViolationFlagThreshold = 0.5 -- below the log threshold
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("accepts thresholds with equal log/flag/act values", function()
		local issues = {}
		local config = validGameConfig()
		config.movementViolationLogThreshold = 2
		config.movementViolationFlagThreshold = 2
		config.movementViolationActThreshold = 2
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues):toBe(0)
	end)
end)

TestRunner.describe("Validate.checkGameConfig (P3-2 decisionStudioDefaultChoice)", function()
	TestRunner.it("rejects a value that isn't Steal or Share", function()
		local issues = {}
		local config = validGameConfig()
		config.decisionStudioDefaultChoice = "Pass" :: any
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("accepts Steal as well as the default Share", function()
		local issues = {}
		local config = validGameConfig()
		config.decisionStudioDefaultChoice = "Steal"
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues):toBe(0)
	end)

	TestRunner.it("rejects a non-positive decisionStudioChatRangeStuds", function()
		local issues = {}
		local config = validGameConfig()
		config.decisionStudioChatRangeStuds = 0
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)
end)

TestRunner.describe("Validate.checkGameConfig (P3-5 npc block)", function()
	TestRunner.it("rejects a tick rate outside architecture.md §4's 5-10 Hz band", function()
		-- Both ends: the low end because the bots visibly stutter, the
		-- high end because docs/npc-notes.md's whole cost analysis is
		-- derived from this number staying inside the band.
		for _, badRate in { 1, 4, 11, 60 } do
			local issues = {}
			local config = validGameConfig()
			config.npc.tickHz = badRate
			Validate.checkGameConfig(config, issues)
			TestRunner.expect(#issues > 0):toBeTruthy()
		end
	end)

	TestRunner.it("accepts both ends of the 5-10 Hz band", function()
		for _, rate in { 5, 10 } do
			local issues = {}
			local config = validGameConfig()
			config.npc.tickHz = rate
			Validate.checkGameConfig(config, issues)
			TestRunner.expect(#issues):toBe(0)
		end
	end)

	TestRunner.it("rejects a fairness floor below 1, which would let a bot beat the median human", function()
		local issues = {}
		local config = validGameConfig()
		config.npc.fairnessFloorScale = 0.9
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("accepts a floor above 1 - softer bots are a legitimate tuning choice", function()
		local issues = {}
		local config = validGameConfig()
		config.npc.fairnessFloorScale = 1.25
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues):toBe(0)
	end)

	TestRunner.it("rejects an empty skill profile list", function()
		local issues = {}
		local config = validGameConfig()
		config.npc.skillProfiles = {}
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects two profiles sharing an id", function()
		local issues = {}
		local config = validGameConfig()
		config.npc.skillProfiles = {
			{ id = "Average", weight = 1, durationScale = 1, moveSpeedScale = 1 },
			{ id = "Average", weight = 1, durationScale = 1.2, moveSpeedScale = 1 },
		}
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects a non-positive profile weight", function()
		local issues = {}
		local config = validGameConfig()
		config.npc.skillProfiles = { { id = "Dead", weight = 0, durationScale = 1, moveSpeedScale = 1 } }
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("accepts a profile faster than the fairness floor - it's floored at runtime, not at boot", function()
		-- Deliberate: a durationScale below the floor scale is floored
		-- on its faster draws only, which is what a rubber band is for.
		-- See checkNPCConfig's own note.
		local issues = {}
		local config = validGameConfig()
		config.npc.skillProfiles = { { id = "Sweaty", weight = 1, durationScale = 0.5, moveSpeedScale = 1 } }
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues):toBe(0)
	end)

	TestRunner.it("names a missing npc block instead of erroring on it", function()
		local issues = {}
		local config = validGameConfig();
		(config :: any).npc = nil
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects the remaining knobs at their boundaries", function()
		local cases: { (config: Validate.GameConfig) -> () } = {
			function(config)
				config.npc.fillGraceSeconds = -1
			end,
			function(config)
				config.npc.medianSampleMinimum = 0
			end,
			function(config)
				config.npc.stationArrivalRadiusStuds = 0
			end,
			function(config)
				config.npc.nextStationTopK = 0
			end,
			function(config)
				config.npc.repathAfterStuckSeconds = 0
			end,
			function(config)
				config.npc.maxRepathsPerStation = 0
			end,
		}

		for _, mutate in cases do
			local issues = {}
			local config = validGameConfig()
			mutate(config)
			Validate.checkGameConfig(config, issues)
			TestRunner.expect(#issues > 0):toBeTruthy()
		end
	end)
end)

TestRunner.describe("Validate.checkGameConfig (bounty ordering)", function()
	TestRunner.it("rejects a tier where soleStealer does not exceed loneSharer", function()
		local issues = {}
		local config = validGameConfig()
		config.bountyTiers = { { tier = 1, minStreak = 1, soleStealerVU = 5, loneSharerVU = 10, allShareVU = 2 } }
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects tiers not sorted by ascending minStreak", function()
		local issues = {}
		local config = validGameConfig()
		config.bountyTiers = {
			{ tier = 1, minStreak = 5, soleStealerVU = 20, loneSharerVU = 10, allShareVU = 5 },
			{ tier = 2, minStreak = 1, soleStealerVU = 24, loneSharerVU = 12, allShareVU = 6 },
		}
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it(
		"rejects a tier set where no tier covers streak 0 - a first-ever win would have no bounty tier",
		function()
			local issues = {}
			local config = validGameConfig()
			config.bountyTiers = { { tier = 1, minStreak = 1, soleStealerVU = 20, loneSharerVU = 10, allShareVU = 5 } }
			Validate.checkGameConfig(config, issues)
			TestRunner.expect(#issues > 0):toBeTruthy()
		end
	)

	TestRunner.it("accepts a tier set whose lowest floor is exactly 0", function()
		local issues = {}
		local config = validGameConfig()
		config.bountyTiers = { { tier = 1, minStreak = 0, soleStealerVU = 20, loneSharerVU = 10, allShareVU = 5 } }
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues):toBe(0)
	end)
end)

TestRunner.describe("Validate.run (cross-registry checks)", function()
	TestRunner.it("flags a map that references an unregistered task id", function()
		local issues = Validate.run({
			gameConfig = validGameConfig(),
			maps = { { fileName = "M.luau", def = validMap("m", { "not-a-real-task" }) } },
			tasks = {},
			powerUps = {},
			titles = {},
		})
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("flags two tasks declaring the same id", function()
		local issues = Validate.run({
			gameConfig = validGameConfig(),
			maps = {},
			tasks = {
				{ fileName = "A.luau", def = validTask("dupe") },
				{ fileName = "B.luau", def = validTask("dupe") },
			},
			powerUps = {},
			titles = {},
		})
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("flags a map with fewer stations than GameConfig.tasksPerPlayer", function()
		local config = validGameConfig()
		config.tasksPerPlayer = 20
		local issues = Validate.run({
			gameConfig = config,
			maps = { { fileName = "M.luau", def = validMap("m", {}) } }, -- taskStationCount = 12
			tasks = {},
			powerUps = {},
			titles = {},
		})
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)
end)

TestRunner.describe("Validate.checkGameConfig (P3-6 npcBrain block)", function()
	TestRunner.it("names a missing npcBrain block instead of erroring on it", function()
		local issues = {}
		local config = validGameConfig();
		(config :: any).npcBrain = nil
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects a lock-in fraction at or past the deadline", function()
		-- A bot locking in at fraction 1.0 races the phase timer for
		-- whether its own choice or the configured default counts.
		for _, bad in { 1, 1.2 } do
			local issues = {}
			local config = validGameConfig()
			config.npcBrain.lockInLatestFraction = bad
			Validate.checkGameConfig(config, issues)
			TestRunner.expect(#issues > 0):toBeTruthy()
		end
	end)

	TestRunner.it("rejects an earliest fraction that isn't below the latest", function()
		local issues = {}
		local config = validGameConfig()
		config.npcBrain.lockInEarliestFraction = 0.9
		config.npcBrain.lockInLatestFraction = 0.8
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects a baseScore that already clears useThreshold on its own", function()
		-- At or above the threshold, a bot fires the instant it can
		-- legally do so and every situation weight means nothing.
		local issues = {}
		local config = validGameConfig()
		config.npcBrain.utility.baseScore = 0.6
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects a wobble chance outside 0-1", function()
		local issues = {}
		local config = validGameConfig()
		config.npcBrain.chooseWobbleChance = 1.5
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects the remaining knobs at their boundaries", function()
		local cases: { (config: Validate.GameConfig) -> () } = {
			function(config)
				config.npcBrain.decisionHz = 0
			end,
			function(config)
				config.npcBrain.utility.useThreshold = 0
			end,
			function(config)
				config.npcBrain.utility.deficitSaturation = 0
			end,
			function(config)
				config.npcBrain.utility.travelSaturationStuds = 0
			end,
			function(config)
				config.npcBrain.utility.proximityWeight = -1
			end,
			function(config)
				config.npcBrain.negotiationLineCount = -1
			end,
			function(config)
				config.npcBrain.minSecondsBetweenLines = -1
			end,
		}

		for _, mutate in cases do
			local issues = {}
			local config = validGameConfig()
			mutate(config)
			Validate.checkGameConfig(config, issues)
			TestRunner.expect(#issues > 0):toBeTruthy()
		end
	end)
end)

TestRunner.describe("Validate.checkNPCPersonality (P3-6)", function()
	TestRunner.it("accepts a fully populated personality", function()
		local issues = {}
		Validate.checkNPCPersonality("Greedy.luau", validPersonality("greedy"), issues)
		TestRunner.expect(#issues):toBe(0)
	end)

	TestRunner.it("rejects a steal probability outside 0-1", function()
		local issues = {}
		local def = validPersonality("greedy")
		def.stealProbability = 1.5
		Validate.checkNPCPersonality("Greedy.luau", def, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects an empty line category - a silent stretch, not a smaller pool", function()
		for _, category in { "promises", "pressure", "accusations", "wobbles" } do
			local issues = {}
			local def = validPersonality("greedy");
			(def.lines :: any)[category] = {}
			Validate.checkNPCPersonality("Greedy.luau", def, issues)
			TestRunner.expect(#issues > 0):toBeTruthy()
		end
	end)

	TestRunner.it("rejects an empty line inside a populated category", function()
		local issues = {}
		local def = validPersonality("greedy")
		def.lines.promises = { "share bro", "" }
		Validate.checkNPCPersonality("Greedy.luau", def, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects a non-positive draw weight", function()
		local issues = {}
		local def = validPersonality("greedy")
		def.weight = 0
		Validate.checkNPCPersonality("Greedy.luau", def, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("flags two personalities declaring the same id", function()
		local issues = Validate.run({
			gameConfig = validGameConfig(),
			maps = {},
			tasks = {},
			powerUps = {},
			titles = {},
			npcPersonalities = {
				{ fileName = "Greedy.luau", def = validPersonality("greedy") },
				{ fileName = "AlsoGreedy.luau", def = validPersonality("greedy") },
			},
		})
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("treats an omitted personality registry as none registered, not an error", function()
		-- Every caller and fixture predating P3-6 passes no
		-- npcPersonalities at all.
		local issues = Validate.run({
			gameConfig = validGameConfig(),
			maps = {},
			tasks = {},
			powerUps = {},
			titles = {},
		})
		TestRunner.expect(#issues):toBe(0)
	end)
end)

TestRunner.describe("Validate.checkTitle (P4-2 ladder)", function()
	local function validLadderTitle(id: string, minStreak: number): Validate.TitleDef
		return { id = id, displayName = "Test", colorHex = "#1c6b67", minStreak = minStreak }
	end

	TestRunner.it("accepts a rung with no effect", function()
		local issues = {}
		Validate.checkTitle("T.luau", validLadderTitle("t", 5), issues)
		TestRunner.expect(#issues):toBe(0)
	end)

	TestRunner.it("accepts each of the three effects", function()
		for _, effect in { "Glow", "Pulse", "Rainbow" } do
			local issues = {}
			local def = validLadderTitle("t", 5)
			def.effect = effect :: any
			Validate.checkTitle("T.luau", def, issues)
			TestRunner.expect(#issues):toBe(0)
		end
	end)

	TestRunner.it("rejects an effect that isn't one of the three", function()
		local issues = {}
		local def = validLadderTitle("t", 5)
		def.effect = "Sparkle" :: any
		Validate.checkTitle("T.luau", def, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects an empty displayName", function()
		local issues = {}
		local def = validLadderTitle("t", 5)
		def.displayName = ""
		Validate.checkTitle("T.luau", def, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("rejects two rungs claiming the same threshold", function()
		-- The ladder has to be a total order, or "the highest title
		-- you've unlocked" depends on a filename.
		local issues = Validate.run({
			gameConfig = validGameConfig(),
			maps = {},
			tasks = {},
			powerUps = {},
			titles = {
				{ fileName = "A.luau", def = validLadderTitle("a", 10) },
				{ fileName = "B.luau", def = validLadderTitle("b", 10) },
			},
		})
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("accepts a ladder whose thresholds are all distinct", function()
		local issues = Validate.run({
			gameConfig = validGameConfig(),
			maps = {},
			tasks = {},
			powerUps = {},
			titles = {
				{ fileName = "A.luau", def = validLadderTitle("a", 1) },
				{ fileName = "B.luau", def = validLadderTitle("b", 10) },
			},
		})
		TestRunner.expect(#issues):toBe(0)
	end)

	TestRunner.it("rejects an out-of-range npc title distribution", function()
		for _, mutate in
			{
				function(config: Validate.GameConfig)
					config.npcTitleNoneChance = 1.5
				end,
				function(config: Validate.GameConfig)
					config.npcTitleTopRungsExcluded = -1
				end,
			}
		do
			local issues = {}
			local config = validGameConfig()
			mutate(config)
			Validate.checkGameConfig(config, issues)
			TestRunner.expect(#issues > 0):toBeTruthy()
		end
	end)
end)

-- ===== P4-5's store catalogue ============================================

local function validProduct(key: string): Validate.StoreItemDef
	return {
		key = key,
		kind = "DeveloperProduct",
		assetId = 123456,
		enabled = true,
		displayName = "Test Product",
		description = "A thing you can buy.",
		robuxPrice = 49,
		sortOrder = 1,
		grants = { { kind = "Currency", amount = 500 } },
	}
end

local function runWithStore(store: { { fileName: string, def: Validate.StoreItemDef } }): { Validate.Issue }
	return Validate.run({
		gameConfig = validGameConfig(),
		maps = {},
		tasks = {},
		powerUps = { { fileName = "SprintBoost.luau", def = validPowerUp("sprint-boost") } },
		titles = { { fileName = "GotOne.luau", def = validTitle("got-one", 1) } },
		store = store,
	})
end

TestRunner.describe("Validate.checkStoreItem (P4-5)", function()
	TestRunner.it("accepts a well-formed developer product", function()
		TestRunner.expect(#runWithStore({ { fileName = "T.luau", def = validProduct("t") } })):toBe(0)
	end)

	TestRunner.it("treats an omitted store registry as nothing for sale, not an error", function()
		local issues = Validate.run({
			gameConfig = validGameConfig(),
			maps = {},
			tasks = {},
			powerUps = {},
			titles = {},
		})
		TestRunner.expect(#issues):toBe(0)
	end)

	TestRunner.it("allows a disabled entry with no Roblox asset id yet", function()
		-- Every entry ships this way until somebody creates the product
		-- in the Creator Dashboard.
		local def = validProduct("t")
		def.enabled = false
		def.assetId = 0
		TestRunner.expect(#runWithStore({ { fileName = "T.luau", def = def } })):toBe(0)
	end)

	TestRunner.it("refuses an ENABLED entry with no asset id", function()
		-- Otherwise the prompt opens for asset 0 in front of a player
		-- holding their Robux.
		local def = validProduct("t")
		def.assetId = 0
		TestRunner.expect(#runWithStore({ { fileName = "T.luau", def = def } }) > 0):toBeTruthy()
	end)

	TestRunner.it("refuses a product that grants nothing", function()
		local def = validProduct("t")
		def.grants = {}
		TestRunner.expect(#runWithStore({ { fileName = "T.luau", def = def } }) > 0):toBeTruthy()
	end)

	TestRunner.it("refuses a game pass that grants currency or power-up stock", function()
		-- A pass is permanent and its grants re-apply on every join, so a
		-- consumable grant here is either a one-shot or an infinite tap.
		for _, grant in
			{
				{ kind = "Currency" :: any, amount = 100 },
				{ kind = "PowerUpStock" :: any, powerUpId = "sprint-boost", amount = 5 },
			}
		do
			local def = validProduct("t")
			def.kind = "GamePass"
			def.grants = { grant :: any }
			TestRunner.expect(#runWithStore({ { fileName = "T.luau", def = def } }) > 0):toBeTruthy()
		end
	end)

	TestRunner.it("accepts a game pass that grants a cosmetic", function()
		local def = validProduct("t")
		def.kind = "GamePass"
		def.grants = { { kind = "Cosmetic", cosmeticId = "skin-founder" } }
		TestRunner.expect(#runWithStore({ { fileName = "T.luau", def = def } })):toBe(0)
	end)

	TestRunner.it("refuses a grant missing the field its own kind requires", function()
		for _, grant in
			{
				{ kind = "Currency" :: any }, -- no amount
				{ kind = "PowerUpStock" :: any, amount = 5 }, -- no powerUpId
				{ kind = "Cosmetic" :: any }, -- no cosmeticId
				{ kind = "Title" :: any }, -- no titleId
			}
		do
			local def = validProduct("t")
			def.grants = { grant :: any }
			TestRunner.expect(#runWithStore({ { fileName = "T.luau", def = def } }) > 0):toBeTruthy()
		end
	end)

	TestRunner.it("refuses two entries sharing a key", function()
		local issues = runWithStore({
			{ fileName = "A.luau", def = validProduct("same") },
			{ fileName = "B.luau", def = validProduct("same") },
		})
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("refuses two entries sharing a Roblox asset id", function()
		-- ProcessReceipt dispatches on that number, so one product would
		-- silently grant the other's contents.
		local a = validProduct("a")
		local b = validProduct("b")
		TestRunner.expect(#runWithStore({ { fileName = "A.luau", def = a }, { fileName = "B.luau", def = b } }) > 0)
			:toBeTruthy()
	end)

	TestRunner.it("lets several unfinished entries share asset id 0", function()
		local a = validProduct("a")
		local b = validProduct("b")
		a.enabled, a.assetId = false, 0
		b.enabled, b.assetId = false, 0
		TestRunner.expect(#runWithStore({ { fileName = "A.luau", def = a }, { fileName = "B.luau", def = b } })):toBe(0)
	end)
end)

TestRunner.describe("Validate.run - store cross-registry checks (P4-5)", function()
	TestRunner.it("accepts stock of a registered, loadout-eligible power-up", function()
		local def = validProduct("t")
		def.grants = { { kind = "PowerUpStock", powerUpId = "sprint-boost", amount = 10 } }
		TestRunner.expect(#runWithStore({ { fileName = "T.luau", def = def } })):toBe(0)
	end)

	TestRunner.it("refuses stock of a power-up that does not exist", function()
		local def = validProduct("t")
		def.grants = { { kind = "PowerUpStock", powerUpId = "made-up", amount = 10 } }
		TestRunner.expect(#runWithStore({ { fileName = "T.luau", def = def } }) > 0):toBeTruthy()
	end)

	TestRunner.it("refuses stock of a power-up that can never be equipped", function()
		local powerUp = validPowerUp("sprint-boost")
		powerUp.acquisition.loadoutEligible = false
		local def = validProduct("t")
		def.grants = { { kind = "PowerUpStock", powerUpId = "sprint-boost", amount = 10 } }
		local issues = Validate.run({
			gameConfig = validGameConfig(),
			maps = {},
			tasks = {},
			powerUps = { { fileName = "SprintBoost.luau", def = powerUp } },
			titles = {},
			store = { { fileName = "T.luau", def = def } },
		})
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("enforces design-decisions.md Q8 from the SELLING side too", function()
		-- checkPowerUp catches a power-up that prices itself with no free
		-- path. This catches the same violation smuggled in through a
		-- bundle, where the power-up's own config names no price at all
		-- and so looks innocent.
		local powerUp = validPowerUp("sprint-boost")
		powerUp.acquisition.fieldPickup = false
		powerUp.acquisition.freelyEarnable = false
		local def = validProduct("t")
		def.grants = { { kind = "PowerUpStock", powerUpId = "sprint-boost", amount = 10 } }
		local issues = Validate.run({
			gameConfig = validGameConfig(),
			maps = {},
			tasks = {},
			powerUps = { { fileName = "SprintBoost.luau", def = powerUp } },
			titles = {},
			store = { { fileName = "T.luau", def = def } },
		})
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)

	TestRunner.it("refuses a grant of a title nobody registered", function()
		local def = validProduct("t")
		def.grants = { { kind = "Title", titleId = "not-a-title" } }
		TestRunner.expect(#runWithStore({ { fileName = "T.luau", def = def } }) > 0):toBeTruthy()
	end)
end)

TestRunner.describe("Validate.checkGameConfig - store block (P4-5)", function()
	local function issuesFor(mutate: (Validate.StoreConfig) -> ()): number
		local issues = {}
		local config = validGameConfig()
		mutate(config.store)
		Validate.checkGameConfig(config, issues)
		return #issues
	end

	TestRunner.it("pins the loadout cap at Q8's 3, in both directions", function()
		TestRunner.expect(issuesFor(function(store)
			store.loadoutSlots = 4
		end) > 0):toBeTruthy()
		TestRunner.expect(issuesFor(function(store)
			store.loadoutSlots = 2
		end) > 0):toBeTruthy()
	end)

	TestRunner.it("refuses a replay window small enough to double-grant", function()
		TestRunner.expect(issuesFor(function(store)
			store.purchaseIdCacheSize = 5
		end) > 0):toBeTruthy()
	end)

	TestRunner.it("refuses a receipt handler that gives up before its first retry", function()
		TestRunner.expect(issuesFor(function(store)
			store.receiptMaxWaitSeconds = 5
			store.receiptSaveRetrySeconds = 10
		end) > 0):toBeTruthy()
	end)

	TestRunner.it("refuses an ownership cache that holds a negative answer longer than a positive one", function()
		TestRunner.expect(issuesFor(function(store)
			store.passCacheUnownedTtlSeconds = 7200
		end) > 0):toBeTruthy()
	end)

	TestRunner.it("names a missing store block instead of erroring on it", function()
		local issues = {}
		local config = validGameConfig()
		config.store = nil :: any
		Validate.checkGameConfig(config, issues)
		TestRunner.expect(#issues > 0):toBeTruthy()
	end)
end)
