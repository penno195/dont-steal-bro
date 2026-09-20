--!strict
-- Types and pure boot-time validation for the game's data-driven config
-- layer (Ground Rule 2: a map, task, power-up or title is one file in a
-- sibling folder here - never a service edit). Self-contained on
-- purpose, with zero requires of sibling files and no Roblox API calls
-- anywhere - the same shape as src/shared/Net.luau, and for the same
-- reason: this is the one file under Config/ that must stay requirable
-- under Lune for headless tests (tests/Config.spec.luau), and a Roblox
-- Instance-path require (`require(ReplicatedStorage.Shared...)`) can't
-- resolve under Lune. Every other file under Config/ - GameConfig.luau,
-- Tasks/*.luau, the registries, ConfigValidator.luau - is Roblox-only and
-- requires this module the normal way.
--
-- Everything below checks DEVELOPER-authored config content at server
-- boot, not adversarial network input - unlike Net.luau's schema system,
-- these are friendly assertions against a typo in a config file, not a
-- defense against a hostile payload, so plain imperative checks are the
-- right tool here, not Net.luau's exact-shape rejection.

local Validate = {}

-- ===== MapDef: docs/map-kit-spec.md §2 ==================================
-- `taskStationCount` is NOT part of the original map-kit-spec.md type -
-- added here so this validator has a declared number to cross-check
-- against GameConfig.tasksPerPlayer (see checkStationCapacity below).
-- Maps are hand-built in Studio and never synced by Rojo (CLAUDE.md), so
-- this is the map author's own DECLARED count, not something
-- introspected from real geometry - the real TaskStation tag count
-- against the live .rbxl is P7-1's job, a separate Studio validator
-- plugin this module has no access to. Kept in sync with map-kit-
-- spec.md's type block; update both together.
export type MapDef = {
	id: string,
	displayName: string,
	description: string,
	thumbnailAssetId: string,
	lightingPreset: string,
	musicTrackId: string,
	enabledTaskIds: { string },
	npcDifficultyModifier: number, -- 0.5-2.0, 1.0 = baseline
	waveNumber: number, -- 1 | 2 | 3
	enabled: boolean,
	taskStationCount: number, -- see note above
}

-- ===== TaskDef: docs/tasks-catalogue.md =================================
export type TaskVerb = "Tap" | "Hold" | "Drag" | "Sequence" | "Timing" | "Aim"

local TASK_VERBS: { TaskVerb } = { "Tap", "Hold", "Drag", "Sequence", "Timing", "Aim" }

export type TaskDef = {
	id: string,
	displayName: string,
	verb: TaskVerb,
	expectedDurationSeconds: { min: number, max: number }, -- architecture.md's NPC timing sample range
	mobileFeasibility: number, -- 1-5, tasks-catalogue.md's rating
}

-- ===== PowerUpDef: docs/powerups.md ======================================
export type PowerUpKind = "Buff" | "Debuff"
export type PowerUpTarget = "Self" | "Aimed" | "Area" | "Nearest"
export type PowerUpRarity = "Common" | "Uncommon" | "Rare"

local POWERUP_KINDS: { PowerUpKind } = { "Buff", "Debuff" }
local POWERUP_TARGETS: { PowerUpTarget } = { "Self", "Aimed", "Area", "Nearest" }
local POWERUP_RARITIES: { PowerUpRarity } = { "Common", "Uncommon", "Rare" }

-- Two acquisition paths per powerups.md's intro. `robuxPrice` is only
-- ever a convenience purchase, never exclusive - design-decisions.md Q8:
-- "every purchasable item is also earnable for free through normal
-- play." checkPowerUp enforces that rule at boot rather than leaving it
-- to code review, per Q8's own downstream note ("should fail config
-- validation per Ground Rule 2, not just fail review").
export type PowerUpAcquisition = {
	fieldPickup: boolean,
	loadoutEligible: boolean,
	freelyEarnable: boolean, -- earnable via Studio wins / loyalty / event drops
	robuxPrice: number?, -- nil = not purchasable with Robux
}

export type PowerUpDef = {
	id: string,
	displayName: string,
	kind: PowerUpKind,
	target: PowerUpTarget,
	durationSeconds: number,
	cooldownSeconds: number,
	rarity: PowerUpRarity,
	hardControl: boolean, -- Freeze/Push-Trip = true; powerups.md's anti-frustration caps apply only to these
	acquisition: PowerUpAcquisition,
}

-- ===== TitleDef: gdd.md §3, architecture.md's folder skeleton ===========
-- "players unlock permanent Titles based on their highest achieved
-- rank/streak... Titles are never revoked when a streak resets" (gdd.md)
-- - a title's threshold is checked against a profile's bestStreak, never
-- its current streak (src/server/DataMigrations.luau's schema, P1-5).
export type TitleDef = {
	id: string,
	displayName: string,
	colorHex: string, -- "#rrggbb" - a plain string, not Color3, so this file stays Lune-pure; a client controller converts it
	minStreak: number,
}

-- ===== GameConfig: round/player counts, Studio timers, bounty tiers ====
-- Studio phase timers are locked exactly by architecture.md §6's network
-- trace (Intro +5s, Negotiate +45s, Choose +15s, Reveal +1s). Bounty
-- tiers are payoff-table.md §3's table verbatim (VU = the internal
-- balancing currency that doc explains is never shown to a player - see
-- its §1 for why L > M > S > 0 must hold at every tier). Fields with no
-- locked value anywhere in docs/ yet are marked PLACEHOLDER, the same
-- stance perf-budget.md and threat-model.md take on their own
-- unverified figures - not a guess presented as fact.
export type BountyTier = {
	tier: number, -- 1-5, ascending
	minStreak: number, -- payoff-table.md §3's streak-range floor for this tier
	soleStealerVU: number, -- L
	loneSharerVU: number, -- M
	allShareVU: number, -- S
}

export type StudioTimers = {
	introSeconds: number,
	negotiateSeconds: number,
	chooseSeconds: number,
	revealDelaySeconds: number,
}

export type GameConfig = {
	playerCount: number, -- 6, gdd.md
	qualifierCount: number, -- 3, gdd.md
	tasksPerPlayer: number, -- cross-checked against every MapDef.taskStationCount
	qualificationFloorPercent: number, -- design-decisions.md Q2: 0.5
	streakLossWeight: number, -- payoff-table.md §3's c0; Closs(n) = streakLossWeight * n
	npcSeatStreakCreditThreshold: number, -- PLACEHOLDER: threat-model.md §8, playtest-tuned
	raceDurationSeconds: number, -- PLACEHOLDER: no locked value in docs/ yet
	studioTimers: StudioTimers,
	bountyTiers: { BountyTier },
}

-- ===== Issues ============================================================

export type Issue = {
	category: string, -- "Map" | "Task" | "PowerUp" | "Title" | "GameConfig"
	fileName: string,
	field: string,
	message: string,
}

local function issue(issues: { Issue }, category: string, fileName: string, field: string, message: string)
	table.insert(issues, { category = category, fileName = fileName, field = field, message = message })
end

local function isNonEmptyString(value: any): boolean
	return type(value) == "string" and #(value :: string) > 0
end

local function inSet<T>(value: T, set: { T }): boolean
	return table.find(set, value) ~= nil
end

-- ===== per-item checks ===================================================

function Validate.checkMap(fileName: string, def: MapDef, issues: { Issue })
	if not isNonEmptyString(def.id) then
		issue(issues, "Map", fileName, "id", "id must be a non-empty string")
	end
	if not isNonEmptyString(def.displayName) then
		issue(issues, "Map", fileName, "displayName", "displayName must be a non-empty string")
	end
	if not isNonEmptyString(def.thumbnailAssetId) then
		issue(issues, "Map", fileName, "thumbnailAssetId", "thumbnailAssetId must be a non-empty string")
	end
	if #def.enabledTaskIds == 0 then
		issue(issues, "Map", fileName, "enabledTaskIds", "a map must enable at least one task id")
	end
	if def.npcDifficultyModifier < 0.5 or def.npcDifficultyModifier > 2.0 then
		issue(
			issues,
			"Map",
			fileName,
			"npcDifficultyModifier",
			string.format("expected 0.5-2.0, got %s", tostring(def.npcDifficultyModifier))
		)
	end
	if def.waveNumber ~= 1 and def.waveNumber ~= 2 and def.waveNumber ~= 3 then
		issue(
			issues,
			"Map",
			fileName,
			"waveNumber",
			string.format("expected 1, 2 or 3, got %s", tostring(def.waveNumber))
		)
	end
	if def.taskStationCount < 12 or def.taskStationCount > 24 then
		issue(
			issues,
			"Map",
			fileName,
			"taskStationCount",
			string.format("expected 12-24 per map-kit-spec.md §1, got %s", tostring(def.taskStationCount))
		)
	end
end

function Validate.checkTask(fileName: string, def: TaskDef, issues: { Issue })
	if not isNonEmptyString(def.id) then
		issue(issues, "Task", fileName, "id", "id must be a non-empty string")
	end
	if not isNonEmptyString(def.displayName) then
		issue(issues, "Task", fileName, "displayName", "displayName must be a non-empty string")
	end
	if not inSet(def.verb, TASK_VERBS) then
		issue(
			issues,
			"Task",
			fileName,
			"verb",
			string.format("expected one of [%s], got %s", table.concat(TASK_VERBS, ", "), tostring(def.verb))
		)
	end
	local range = def.expectedDurationSeconds
	if range.min <= 0 or range.max <= 0 then
		issue(issues, "Task", fileName, "expectedDurationSeconds", "min and max must both be positive")
	elseif range.min > range.max then
		issue(
			issues,
			"Task",
			fileName,
			"expectedDurationSeconds",
			string.format("min (%s) must be <= max (%s)", tostring(range.min), tostring(range.max))
		)
	end
	if def.mobileFeasibility < 1 or def.mobileFeasibility > 5 then
		issue(
			issues,
			"Task",
			fileName,
			"mobileFeasibility",
			string.format("expected 1-5, got %s", tostring(def.mobileFeasibility))
		)
	end
end

function Validate.checkPowerUp(fileName: string, def: PowerUpDef, issues: { Issue })
	if not isNonEmptyString(def.id) then
		issue(issues, "PowerUp", fileName, "id", "id must be a non-empty string")
	end
	if not inSet(def.kind, POWERUP_KINDS) then
		issue(issues, "PowerUp", fileName, "kind", string.format("expected Buff or Debuff, got %s", tostring(def.kind)))
	end
	if not inSet(def.target, POWERUP_TARGETS) then
		issue(
			issues,
			"PowerUp",
			fileName,
			"target",
			string.format("expected one of [%s], got %s", table.concat(POWERUP_TARGETS, ", "), tostring(def.target))
		)
	end
	if not inSet(def.rarity, POWERUP_RARITIES) then
		issue(
			issues,
			"PowerUp",
			fileName,
			"rarity",
			string.format("expected one of [%s], got %s", table.concat(POWERUP_RARITIES, ", "), tostring(def.rarity))
		)
	end
	if def.durationSeconds <= 0 then
		issue(issues, "PowerUp", fileName, "durationSeconds", "must be positive")
	end
	if def.cooldownSeconds <= 0 then
		issue(issues, "PowerUp", fileName, "cooldownSeconds", "must be positive")
	end

	-- design-decisions.md Q8: a Robux price is only ever a convenience
	-- purchase. A power-up with no free acquisition path fails boot,
	-- rather than shipping a pay-to-win item past review.
	local acquisition = def.acquisition
	if acquisition.robuxPrice ~= nil and acquisition.robuxPrice > 0 then
		local hasFreePath = acquisition.fieldPickup or acquisition.freelyEarnable
		if not hasFreePath then
			issue(
				issues,
				"PowerUp",
				fileName,
				"acquisition",
				"has a robuxPrice but no free acquisition path (fieldPickup or freelyEarnable) - design-decisions.md Q8 forbids Robux-exclusive power-ups"
			)
		end
	end
end

function Validate.checkTitle(fileName: string, def: TitleDef, issues: { Issue })
	if not isNonEmptyString(def.id) then
		issue(issues, "Title", fileName, "id", "id must be a non-empty string")
	end
	if not isNonEmptyString(def.colorHex) or not string.match(def.colorHex, "^#%x%x%x%x%x%x$") then
		issue(
			issues,
			"Title",
			fileName,
			"colorHex",
			string.format('expected "#rrggbb", got %s', tostring(def.colorHex))
		)
	end
	if def.minStreak < 0 or def.minStreak % 1 ~= 0 then
		issue(
			issues,
			"Title",
			fileName,
			"minStreak",
			string.format("expected a non-negative integer, got %s", tostring(def.minStreak))
		)
	end
end

function Validate.checkGameConfig(config: GameConfig, issues: { Issue })
	if config.playerCount <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "playerCount", "must be positive")
	end
	if config.qualifierCount <= 0 or config.qualifierCount > config.playerCount then
		issue(issues, "GameConfig", "GameConfig.luau", "qualifierCount", "must be positive and <= playerCount")
	end
	if config.tasksPerPlayer <= 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "tasksPerPlayer", "must be positive")
	end
	if config.qualificationFloorPercent < 0 or config.qualificationFloorPercent > 1 then
		issue(issues, "GameConfig", "GameConfig.luau", "qualificationFloorPercent", "must be between 0 and 1")
	end

	if #config.bountyTiers == 0 then
		issue(issues, "GameConfig", "GameConfig.luau", "bountyTiers", "must declare at least one tier")
	end

	local previousMinStreak: number? = nil
	for _, tier in config.bountyTiers do
		local label = string.format("bountyTiers[tier=%s]", tostring(tier.tier))

		-- The central invariant the P1-4 task asks for by name: sole-
		-- stealer bounty > lone-sharer bounty > all-share bounty > 0,
		-- checked at every tier (payoff-table.md §1's asymmetric payoff
		-- shape is what keeps Steal and Share both live options).
		if
			not (tier.soleStealerVU > tier.loneSharerVU and tier.loneSharerVU > tier.allShareVU and tier.allShareVU > 0)
		then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				label,
				string.format(
					"bounty ordering broken: expected soleStealer (%s) > loneSharer (%s) > allShare (%s) > 0",
					tostring(tier.soleStealerVU),
					tostring(tier.loneSharerVU),
					tostring(tier.allShareVU)
				)
			)
		end

		if previousMinStreak ~= nil and tier.minStreak <= previousMinStreak then
			issue(
				issues,
				"GameConfig",
				"GameConfig.luau",
				label,
				"bountyTiers must be sorted by strictly ascending minStreak"
			)
		end
		previousMinStreak = tier.minStreak
	end
end

-- ===== cross-registry checks =============================================
-- Duplicate ids and cross-references need the WHOLE set of a category,
-- not one item at a time, so they live here rather than in the per-item
-- checks above.

local function checkDuplicateIds(
	category: string,
	entries: { { fileName: string, def: { id: string } } },
	issues: { Issue }
)
	local seenAt: { [string]: string } = {}
	for _, entry in entries do
		local existingFile = seenAt[entry.def.id]
		if existingFile ~= nil then
			issue(
				issues,
				category,
				entry.fileName,
				"id",
				string.format("duplicate id %q also declared by %s", entry.def.id, existingFile)
			)
		else
			seenAt[entry.def.id] = entry.fileName
		end
	end
end

export type RegistryInput = {
	gameConfig: GameConfig,
	maps: { { fileName: string, def: MapDef } },
	tasks: { { fileName: string, def: TaskDef } },
	powerUps: { { fileName: string, def: PowerUpDef } },
	titles: { { fileName: string, def: TitleDef } },
}

function Validate.run(input: RegistryInput): { Issue }
	local issues: { Issue } = {}

	Validate.checkGameConfig(input.gameConfig, issues)

	for _, entry in input.maps do
		Validate.checkMap(entry.fileName, entry.def, issues)
	end
	for _, entry in input.tasks do
		Validate.checkTask(entry.fileName, entry.def, issues)
	end
	for _, entry in input.powerUps do
		Validate.checkPowerUp(entry.fileName, entry.def, issues)
	end
	for _, entry in input.titles do
		Validate.checkTitle(entry.fileName, entry.def, issues)
	end

	checkDuplicateIds("Map", input.maps :: any, issues)
	checkDuplicateIds("Task", input.tasks :: any, issues)
	checkDuplicateIds("PowerUp", input.powerUps :: any, issues)
	checkDuplicateIds("Title", input.titles :: any, issues)

	local knownTaskIds: { [string]: boolean } = {}
	for _, entry in input.tasks do
		knownTaskIds[entry.def.id] = true
	end

	for _, entry in input.maps do
		for _, taskId in entry.def.enabledTaskIds do
			if not knownTaskIds[taskId] then
				issue(
					issues,
					"Map",
					entry.fileName,
					"enabledTaskIds",
					string.format("references unregistered task id %q", taskId)
				)
			end
		end

		-- The invariant the P1-4 task names explicitly: every map has at
		-- least as many task stations as tasks assigned per player.
		if entry.def.taskStationCount < input.gameConfig.tasksPerPlayer then
			issue(
				issues,
				"Map",
				entry.fileName,
				"taskStationCount",
				string.format(
					"%d stations is fewer than GameConfig.tasksPerPlayer (%d)",
					entry.def.taskStationCount,
					input.gameConfig.tasksPerPlayer
				)
			)
		end
	end

	return issues
end

return Validate
