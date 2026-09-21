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
			{ tier = 1, minStreak = 1, soleStealerVU = 20, loneSharerVU = 10, allShareVU = 5 },
			{ tier = 2, minStreak = 3, soleStealerVU = 24, loneSharerVU = 12, allShareVU = 6 },
		},
		powerUpInventorySlots = 1,
		powerUpFullInventoryPolicy = "Refuse",
		powerUpUseRangeStuds = 24,
		powerUpTargetConeDegrees = 90,
		powerUpRotationTimers = { Common = 20, Uncommon = 35, Rare = 60 },
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
