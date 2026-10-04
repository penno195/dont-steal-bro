--!strict
-- The root config: round/player counts, Decision Studio timers, and
-- win rewards. See Validate.luau for field provenance - most of these
-- numbers are locked design decisions, not guesses; the ones that aren't
-- are marked PLACEHOLDER, the same stance perf-budget.md and threat-
-- model.md take on their own unverified figures. ConfigValidator
-- (src/server/Services/ConfigValidator.luau) asserts this at boot -
-- edit a number here with confidence that a broken one fails loudly
-- instead of shipping quietly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

local GameConfig: Validate.GameConfig = {
	playerCount = 6, -- gdd.md
	qualifierCount = 3, -- gdd.md
	tasksPerPlayer = 6, -- PLACEHOLDER: no locked value in docs/ yet
	qualificationFloorPercent = 0.5, -- design-decisions.md Q2
	streakLossWeight = 10, -- payoff-table.md §3's c0 in coins (was 2 VU; 1 VU = 5 coins); Closs(n) = 10n
	raceDurationSeconds = 300, -- PLACEHOLDER: no locked value in docs/ yet

	-- architecture.md §6's network trace, verbatim.
	studioTimers = {
		-- The Intro is the loading card's reading time, and ends early
		-- once every finalist taps "Got it" (FinaleRoster.introSeconds).
		introSeconds = 5, -- every finalist is a veteran
		introNewPlayerSeconds = 12, -- PLACEHOLDER: anyone at the table has < newPlayerFinales
		introMinSeconds = 2, -- floor before an early start, so staging lands behind the card
		newPlayerFinales = 3, -- PLACEHOLDER: lifetime steals + shares
		negotiateSeconds = 20, -- cut from 45 after the 2026-09-25 playtest
		chooseSeconds = 15,
		revealDelaySeconds = 1,
	},

	-- RoundService's (P2-1) own state durations. All PLACEHOLDER - no
	-- locked value in docs/ yet, same stance as raceDurationSeconds.
	roundTimers = {
		loadingSeconds = 5,
		introSeconds = 5,
		qualifiedSeconds = 3,
		resultsSeconds = 16, -- must outlast DecisionLogic.revealLength (~11 s) plus reading the result; was 8
		cleanupSeconds = 5,
	},

	-- What a win pays (design-decisions.md Q1, revised 2026-09-30 and
	-- applied 2026-10-02): currency for the outcome tier, scaled by the
	-- winner's title-ladder rung after this win, plus a chance at a random
	-- drop. Replaced the five VU bountyTiers (rewards-roadmap.md 2c).
	-- Every number is PLACEHOLDER until playtest.
	winRewards = {
		-- Rung 0 pays the base; rung 21 (streak 50) pays 3.1x.
		currency = { soleStealer = 100, loneSharer = 50, allShare = 25, perRungBonus = 0.1 },
		drop = {
			-- 10% at rung 0, up to the 50% cap by rung 20.
			baseChance = 0.1,
			perRungChance = 0.02,
			maxChance = 0.5,
			-- At rung 0: 70/25/5. At rung 21: about 48/35/18.
			rarityWeights = {
				Common = { weight = 70, perRungGrowth = 0 },
				Uncommon = { weight = 25, perRungGrowth = 0.05 },
				Rare = { weight = 5, perRungGrowth = 0.2 },
			},
			powerUpAmount = 1,
			duplicateCurrency = { Common = 10, Uncommon = 20, Rare = 50 }, -- 0.4, 0.8 and 2 power-ups
		},
	},

	-- P2-7: PowerUpService's in-round inventory. The pre-game loadout
	-- starts in these slots and field pickups fill whatever is empty
	-- (powerups.md "Inventory and aiming", decided 2026-09-25). Range,
	-- cone and slack are PLACEHOLDER, same stance as raceDurationSeconds.
	powerUpInventorySlots = 3, -- matches store.loadoutSlots, so a full loadout fits
	powerUpFullInventoryPolicy = "Refuse", -- picking up while full is refused (the world pickup stays available) rather than swapping the held item
	powerUpUseRangeStuds = 24, -- max range for an Aimed/Nearest target
	powerUpTargetConeDegrees = 90, -- full width of the lock-on cone an Aimed power-up picks its target from
	-- Extra allowance when the server re-checks the target the client had
	-- locked on to: the client saw that target a round trip ago, so a
	-- lock that was legal on screen can be a few studs or degrees out by
	-- the time it lands. Only ever applied to the client's own locked
	-- target, never to the server's own pick.
	powerUpLockOnSlackStuds = 4,
	powerUpLockOnSlackDegrees = 20,
	-- A thrown item's projectile, explosion, recoil and shunt. PLACEHOLDER
	-- feel numbers: at 90 studs/s a max-range (24) throw lands in ~0.27s.
	powerUpThrow = {
		projectileSpeedStuds = 90,
		maxFlightSeconds = 0.4,
		arcHeightStuds = 2.5,
		explosionRadiusStuds = 4,
		shuntSpeed = 22,
		shuntUpSpeed = 10,
		recoilSpeed = 10,
	},

	-- Base respawn seconds per rarity tier - a MapDef may multiply these
	-- (Validate.PowerUpRarityWeights' own doc comment). Ordered so a
	-- rarer tier respawns more slowly by default, without any map needing
	-- to override anything.
	powerUpRotationTimers = {
		Common = 10,
		Uncommon = 20,
		Rare = 35,
	},

	-- P2-9: MovementWatch's thresholds. All PLACEHOLDER - no real logged
	-- data exists yet to tune against; docs/movement-watch-notes.md
	-- covers how to read the first week of logs before touching these.
	movementSampleIntervalSeconds = 0.5,
	movementSpeedTolerance = 1.25, -- 25% grace above the resolved max
	movementViolationDecayPerSecond = 0.5,
	movementViolationLogThreshold = 1.0,
	movementViolationFlagThreshold = 3.0,
	movementViolationActThreshold = 6.0, -- unused this version - LOG ONLY

	-- P3-2: design-decisions.md Q4, verbatim ("the leaver's substituted
	-- choice for the other two is Share") - locked, not a placeholder.
	decisionStudioDefaultChoice = "Share",

	-- P3-3: PLACEHOLDER - no locked value in docs/ yet. P3-4's podium
	-- layout is expected to fit comfortably inside this.
	decisionStudioChatRangeStuds = 30,

	-- The one Decision Studio set every finale uses, whatever the race
	-- map was (StudioStageService). Cloned from ServerStorage.Maps at
	-- Qualified and moved `offsetStuds` along +X, so it never overlaps
	-- the race map it's loaded next to.
	decisionStudioStage = {
		mapId = "DecisionStudio",
		offsetStuds = 5000,
	},

	-- P3-5: NPC fill. Every knob the bots have, in one block, so tuning
	-- them is a config edit and never a service edit (Ground Rule 2).
	npc = {
		-- architecture.md §4, verbatim ("a ~10s grace window so slow
		-- teleports aren't replaced by bots") - not a placeholder.
		fillGraceSeconds = 10,

		-- architecture.md §4 gives the 5-10 Hz band; 8 is the midpoint
		-- choice within it. docs/npc-notes.md derives the per-server
		-- cost from this exact number - change both together.
		tickHz = 8,

		-- PLACEHOLDER: the three profiles are architecture.md §4's
		-- (Casual/Average/Sweaty), but every number attached to them is
		-- a guess until there is real player telemetry to fit against -
		-- which is the whole point of the doc's "tuned from real player
		-- telemetry" note. The weights deliberately centre on Average.
		skillProfiles = {
			{ id = "Casual", weight = 0.3, durationScale = 1.35, moveSpeedScale = 0.9 },
			{ id = "Average", weight = 0.5, durationScale = 1.1, moveSpeedScale = 1.0 },
			{ id = "Sweaty", weight = 0.2, durationScale = 0.9, moveSpeedScale = 1.05 },
		},

		-- 1.0 = architecture.md §4's rule exactly: never faster than the
		-- median human. Locked by that rule, not a placeholder - raising
		-- it makes bots softer, lowering it below 1.0 fails validation.
		fairnessFloorScale = 1.0,

		-- PLACEHOLDER. 3 completions is enough for a median to stop
		-- swinging on a single outlier, and low enough to switch over
		-- from the catalogue-range fallback partway through a race.
		medianSampleMinimum = 3,

		-- PLACEHOLDER. Roughly a character's own width plus the stud or
		-- two of overshoot a Humanoid:MoveTo finish leaves behind.
		stationArrivalRadiusStuds = 6,

		-- 2 = the smallest value that stops every bot walking an
		-- identical route (see NPCLogic.chooseNextStation).
		nextStationTopK = 2,

		-- PLACEHOLDER, both. The stuck window has to be longer than a
		-- normal Humanoid stutter over a ramp or a doorway, or a bot
		-- repaths constantly for no reason - which is the single
		-- biggest NPC cost on the server (docs/npc-notes.md).
		repathAfterStuckSeconds = 1.5,
		maxRepathsPerStation = 5,

		-- PLACEHOLDER. How many past finales a bot's reputation line
		-- shows, each one rolled from its personality (NPCBrainLogic.
		-- staticHistory). Kept small so a bot reads as a fairly new
		-- player rather than a veteran with a telling record.
		historyFinales = { min = 1, max = 8 },

		-- What a bot wears, so it passes for a real player. Each bot draws
		-- one of each from these lists (NPCLogic.pickAppearance). IDs are
		-- live catalog assets, checked in Studio on 2026-09-29 (hair,
		-- shirts, pants and hats from AvatarEditorService:SearchCatalogAsync,
		-- faces by MarketplaceService:GetProductInfo). A bad ID only costs
		-- that one bot its look - NPCService falls back to the plain rig.
		appearance = {
			hair = {
				63690008, -- Pal Hair (the "bacon")
				63690008, -- listed twice: it's the most common hair in any lobby
				451221329, -- True Blue Hair
				451220849, -- Lavender Updo
				9243992729, -- Short and Sleek - Black
				3814474927, -- Cool Side Shave
				9244021842, -- Side Part - Black
				376524487, -- Blonde Spiked Hair
				376526888, -- Straight Blonde Hair
				7193442167, -- Pony Tail - Black
				9174355709, -- Sideswept Dreads - Black
				3814476174, -- Colorful Braids
				7193448258, -- Wavy Middle Part - Brown
				6993754725, -- Straight Bangs - Black
				9174354743, -- Top Knot - Black
				7193401217, -- Short Fringe - Black
				9244038785, -- Surfer - Red
				7193450455, -- Curly Afro - Black
				1103003368, -- Orange Beanie with Black Hair
			},
			faces = {
				144075659, -- Smile
				144075659, -- listed twice: the default face
				7699174, -- Silly Fun
				20418658, -- Err...
				12145366, -- Freckles
				15432080, -- :3
				7074836, -- Classic Vampire
				7074944, -- Uh Oh
				16101765, -- Tango
			},
			shirts = {
				607785314, -- ROBLOX Jacket
				3670737444, -- Roblox Shirt - Simple Pattern
				144076358, -- Blue and Black Motorcycle Shirt
				398633584, -- Denim Jacket with White Hoodie
				382538059, -- Green Jersey
				398635081, -- Blue Plaid Shirt
				398634295, -- Pastel Starburst Top with Gray Jacket
				4047886060, -- Purple and Teal Top
				4047884939, -- My Favorite Pizza Shirt
				4047884046, -- Guitar Tee with Black Jacket
				144076436, -- Grey Striped Shirt with Denim Jacket
				382537702, -- Teal Shirt
			},
			pants = {
				398633812, -- Black Jeans with White Shoes
				398635338, -- Ripped Skater Pants
				398634487, -- Beautiful You Jeans
				144076760, -- Dark Green Jeans
				382538503, -- Black Jeans with Sneakers
				382537569, -- Black Jeans
				382537950, -- Jean Shorts with White Shoes
				382537806, -- Jean Shorts
			},
			hats = {
				417457461, -- ROBLOX 'R' Baseball Cap
				607702162, -- Roblox Baseball Cap
				2646473721, -- Roblox Visor
				607700713, -- Roblox Logo Visor
				48474313, -- Red Roblox Cap
				4324158403, -- International Fedora - Japan
			},
			hatChance = 0.3, -- PLACEHOLDER: share of bots that also wear a hat
			-- 0-255 RGB, from the BrickColor skin palette (Light orange,
			-- Nougat, Pastel brown, Brown, Reddish brown, Cork, Brick
			-- yellow, Burlap, Bright yellow).
			skinTones = {
				{ 234, 184, 146 },
				{ 204, 142, 105 },
				{ 255, 204, 153 },
				{ 124, 92, 70 },
				{ 105, 64, 40 },
				{ 188, 155, 93 },
				{ 215, 197, 154 },
				{ 199, 172, 120 },
				{ 245, 205, 48 },
			},
		},
	},

	-- P4-3: the all-time leaderboard. EVERY NUMBER IN THIS BLOCK THAT
	-- DESCRIBES A ROBLOX LIMIT MUST BE VERIFIED against current
	-- documentation before launch - see docs/leaderboard-scale.md, which
	-- is where that verification gets recorded. They are config rather
	-- than constants precisely so a corrected limit is an edit here.
	leaderboard = {
		storeName = "AllTimeBestStreak_v1", -- versioned: a schema change means a new store, never a migration of a sorted one
		storeScope = "global",
		topCount = 100, -- P4-3: top 100, and also the GetSortedAsync page size, so one page is the whole board

		-- P4-3: "an interval of 60 to 120 seconds", drawn per cycle
		-- rather than fixed so servers do not synchronise.
		refreshMinSeconds = 60,
		refreshMaxSeconds = 120,
		-- When the board starts being labelled stale to the UI. Longer
		-- than refreshMax on purpose: one skipped cycle is normal and
		-- should not cry wolf.
		staleAfterSeconds = 300,

		nameCacheTtlSeconds = 3600, -- a renamed account corrects itself within the hour
		-- leaderboard-scale.md A5: GetUserInfosByUserIdsAsync is reported to
		-- allow ~250 results/min (undocumented); stay under it per server.
		nameLookupsPerMinute = 200,
		nameFailureRetrySeconds = 120, -- a failed lookup (429, outage) is retried after this
		maxWriteAttempts = 3,
		backoffBaseSeconds = 1,
		backoffCapSeconds = 60,

		-- PLACEHOLDER AND UNVERIFIED. The real per-server DataStore
		-- budget is a formula involving player count, and it is the
		-- single most important thing in this block to check - see
		-- docs/leaderboard-scale.md. The service also consults the
		-- engine's own GetRequestBudgetForRequestType as the hard gate,
		-- so a wrong figure here degrades policy rather than breaking
		-- correctness.
		budget = {
			perWindow = 60,
			windowSeconds = 60,
			softCeiling = 0.7, -- reads yield to writes past this fraction
		},

		-- P4-4. The snapshot store is a REGULAR DataStore and must
		-- outlive every MemoryStore TTL - yesterday's winners are still
		-- worth showing and still owe a reward.
		snapshotStoreName = "PeriodSnapshots_v1",
		-- Extra time a finished period's live entries last, on top of one
		-- full extra period (PeriodKeys.liveExpirySeconds). The extra
		-- period lets a server booting any time in the next period catch
		-- up a rollover no server saw; this margin covers a boot at the
		-- very end of it. 1 hour is generous against a refresh interval
		-- measured in minutes.
		periodGraceSeconds = 3600,
		-- leaderboard-scale.md §9: one server at a time reads each period
		-- board's sorted map (100 units) and publishes it to a hash map;
		-- every other server reads one shard (1 unit).
		periodShare = {
			mapName = "PeriodBoardsPublished_v1",
			shardCount = 4, -- copies of the board, so no one key takes every read
			republishAfterSeconds = 60, -- a copy older than this is replaced on the next read
			lockSeconds = 30, -- how long one server holds the right to republish
			shardTtlSeconds = 900, -- an abandoned copy (old period, dead servers) expires
		},
		-- What a finished period pays (design-decisions.md Q1, applied
		-- 2026-10-02; rewards-roadmap.md step 4). Bands of places in
		-- ascending maxRank: #1, #2-3, #4-10. The last band's maxRank is
		-- how many places get paid. A band may also name a limited
		-- cosmetic via `cosmeticId`; none do yet. The all-time board has
		-- no entry on purpose: it never pays (user decision). Every
		-- amount is PLACEHOLDER until playtest (roadmap step 7).
		payouts = {
			Daily = {
				{ maxRank = 1, currency = 75 }, -- 3 power-ups
				{ maxRank = 3, currency = 50 },
				{ maxRank = 10, currency = 25 },
			},
			Weekly = {
				{ maxRank = 1, currency = 250 }, -- 10 power-ups, under the free track
				{ maxRank = 3, currency = 125 },
				{ maxRank = 10, currency = 50 },
			},
		},
	},

	-- P4-5: the store. Two of these are locked by a design decision and
	-- the rest are judgement calls with real consequences, so they are
	-- config rather than constants.
	store = {
		-- ProfileStore's own devproducts example uses 100. This is the
		-- replay window: a receipt older than the oldest id still held
		-- would be granted twice if Roblox re-offered it. 100 purchases
		-- is far more than any player makes between two sessions.
		purchaseIdCacheSize = 100,

		-- How often a yielding ProcessReceipt re-checks whether the
		-- grant has reached the DataStore. ProfileStore's example polls
		-- every 10s; this matches it. Shorter would burn write budget
		-- re-saving an already-queued profile for no gain.
		receiptSaveRetrySeconds = 10,

		-- PLACEHOLDER. When to stop waiting and return NotProcessedYet.
		-- There is nothing lost by giving up: Roblox re-offers the
		-- receipt, and the PurchaseId cache means the retry cannot
		-- double-grant. Two minutes is long enough to ride out a
		-- DataStore wobble and short enough not to pin a thread open
		-- across a whole round.
		receiptMaxWaitSeconds = 120,

		-- PLACEHOLDER. A receipt can arrive before the buyer's profile
		-- has finished loading (they bought during the join). Waiting
		-- briefly is right; waiting long is not, because declining is
		-- free and safe.
		receiptProfileWaitSeconds = 30,

		-- Game pass ownership cache. "Owns it" is stable for an hour;
		-- "doesn't own it" for a minute, because the player who just
		-- bought it is the one refreshing the store screen. The purchase
		-- prompt's own completion signal invalidates the entry
		-- immediately anyway - this TTL is the fallback for a pass
		-- bought on the website mid-session.
		passCacheOwnedTtlSeconds = 3600,
		passCacheUnownedTtlSeconds = 60,

		-- LOCKED by design-decisions.md Q8: "Loadouts are capped at 3
		-- items regardless of spend." Validate.checkStoreConfig asserts
		-- this is exactly 3 - changing it means amending Q8.
		loadoutSlots = 3,
	},

	-- P5-1: cross-server matchmaking. docs/matchmaking.md explains every
	-- number, and which MemoryStore limits they are designed against.
	-- Validate.checkMatchmakingConfig enforces the orderings between
	-- them, which are what keep the queue moving.
	matchmaking = {
		hubPlaceId = 96878739507497, -- the published Hub (start) place; 0 would run matchmaking in Studio only
		-- Versioned like the leaderboard stores: a schema change means
		-- new names, never an in-place migration of live queue state.
		queueMapName = "MatchQueue_v1",
		groupMapName = "MatchGroups_v1",
		recentMapName = "RecentOpponents_v1",
		metaMapName = "MatchmakingMeta_v1",

		groupSize = 6, -- gdd.md; must equal playerCount
		partialGroupTimeoutSeconds = 30, -- owner's choice 2026-10-04: long enough to fill a group, short enough not to annoy. Live-tunable
		partialGroupMinPlayers = 1, -- P5-1: "with at least 1 player"
		formationTickSeconds = 2, -- PLACEHOLDER: also the UI refresh rate and the claim-discovery latency
		queuePageSize = 200, -- the oldest 200 waiting are the only ones who can form a group this tick

		entryTtlSeconds = 90, -- a dead server's entries are gone within this
		refreshIntervalSeconds = 20,
		claimCommitDeadlineSeconds = 10,
		staleClaimRevertSeconds = 45,
		groupRecordTtlSeconds = 600,
		leaseTtlSeconds = 6, -- 3 ticks: one slow tick doesn't hand formation away
		departedTtlSeconds = 30,

		-- architecture.md §7's collusion mitigation. PLACEHOLDER: 15 min is
		-- roughly two rounds. Never relaxed to fill a group: a quiet
		-- server gets NPC seats instead (MatchmakingLogic.selectGroups).
		rematchCooldownSeconds = 900,
		recentOpponentsCap = 30,

		backoffBaseSeconds = 2,
		backoffCapSeconds = 30,
		unavailableAfterFailures = 3, -- consecutive failed reads before the UI says so

		-- matchmaking.md, partition ceiling: only the lease holder reads the
		-- queue page and publishes a summary into metaMapName; every other
		-- hub server reads one shard (1 unit) instead of the page.
		summaryShardCount = 4,
		summaryStaleSeconds = 10, -- older than this, a server reads the page itself
		summaryTtlSeconds = 60,
	},

	-- P5-2: hub-to-match teleport. docs/teleport.md explains each number.
	-- The arrival grace window is npc.fillGraceSeconds (architecture.md
	-- §4's ~10s), not a second knob here: it's the same window.
	teleport = {
		matchPlaceId = 126392243548802, -- the published Match place; 0 would disable teleporting
		maxAttempts = 4, -- PLACEHOLDER: per player, including the first
		retryBaseSeconds = 1, -- PLACEHOLDER
		retryCapSeconds = 8, -- PLACEHOLDER
		-- PLACEHOLDER: a player still on the hub this long after an attempt,
		-- with no TeleportInitFailed, counts as a failed attempt.
		travelWatchdogSeconds = 20,
		-- PLACEHOLDER: extra wait for a profile still session-locked by the
		-- hub. ProfileStore steals a stuck lock at 40s (SESSION_STEAL), so
		-- this covers the normal release, not a dead hub.
		profileLoadGraceSeconds = 15,
		manifestReadAttempts = 4, -- match server's reads of its own group record
	},

	-- P5-3: the map vote a formed group holds on the hub before it
	-- travels. docs/voting.md explains each number.
	vote = {
		ballotSize = 4, -- P5-3: "3 to 4 ... never all 11"
		voteSeconds = 8, -- short on purpose (6-8s asked for); locks early once every member has voted
		revealSeconds = 3, -- PLACEHOLDER: the winner (or the tie roulette) on screen before travel
		pollSeconds = 1, -- each owner server's read of the group record while voting
		-- PLACEHOLDER: how long past the deadline an owner keeps trying to
		-- lock or read the result before travelling on the former's
		-- provisional map (a MemoryStore outage).
		lockGraceSeconds = 5,
		recentMapName = "RecentMaps_v1",
		recentMapsCap = 3, -- rounds of history per player
		recentMapsTtlSeconds = 21600, -- PLACEHOLDER: 6h; "recent" means this session, roughly
		recentFloorWeight = 0.2, -- PLACEHOLDER: a map everyone just played is drawn 1/5 as often
		recentDecay = 0.5, -- PLACEHOLDER: two rounds ago counts half as much as last round
	},

	-- P5-5: the hub practice area. Same items, same rules as a round,
	-- except these. All PLACEHOLDER, to tune in playtest: the aim is fun
	-- for a few seconds, never annoying for long.
	practice = {
		durationScale = 0.5, -- a 2.5s Freeze lands as 1.25s
		maxEffectSeconds = 2, -- nothing lasts longer than this, whatever the item
		maxActiveEffects = 1, -- one effect per player at a time
		itemSpawnRarities = { "Common", "Uncommon", "Rare" }, -- so every tier shows up to try
		respawnMultipliers = { Common = 0.25, Uncommon = 0.25, Rare = 0.25 }, -- 4x faster than a round
		zoneCheckSeconds = 0.2,
		-- Pickups deal from a shuffled deck: every item turns up once before
		-- any repeats. Attack (red) items go in twice - they're the ones a
		-- player can actually try out here, on the dummies.
		bagCopiesByRole = { Attack = 2, Defence = 1, Utility = 1 },
		-- Dummies fight back: this often, one throws an attack at a player
		-- in its range, so you feel what it does and have a reason to try
		-- Second Wind (cleanse) and Phase Step (can't be touched).
		dummyAttackSeconds = 8,
		-- Attacks with something to see on a player.
		dummyAttackPowerUpIds = { "push-trip", "freeze", "blind", "slow-field" },
		-- Thrown only at a player mid-task at the practice station, and
		-- nothing else is: a push or freeze would just end the attempt.
		dummyTaskAttackPowerUpIds = { "task-scramble" },
		-- The practice station (HubPracticeTask) runs this task, so Task
		-- Insight and Task Scramble have a task to change. A solve is
		-- feedback only: it never reaches TaskService or any stat.
		taskId = "code-playback",
	},

	-- Proximity doors (DoorService / DoorController): any Model tagged
	-- ProximityDoor with a Hinge part. docs/hub-spec.md "Doors".
	doors = {
		openRadius = 10, -- studs on the ground plane; someone this close opens it
		closeRadius = 13, -- and it shuts once nobody is this close (> openRadius: no flapping)
		checkSeconds = 0.15, -- server proximity check; also the worst-case open delay
		swingSeconds = 0.4, -- client tween, open or close
		openAngle = 95, -- degrees; a Model's own OpenAngle attribute overrides it
	},

	-- Studio test mode (StudioTestService). Never runs outside Studio.
	-- Pressing Play loads `mapId` from ServerStorage.Maps and starts a
	-- round once `minHumans` have loaded, NPCs filling the rest. Set
	-- enabled = false to test the hub/queue in Studio instead.
	studioTest = {
		enabled = true,
		mapId = "Laboratory", -- any model name in ServerStorage.Maps, enabled or not
		minHumans = 1,
		startDelaySeconds = 3, -- after minHumans is reached, so a second test client can join
	},

	-- P4-2. LOCKED false by design-decisions.md Q7 condition 1, which
	-- forbids any in-round tell of a player's streak and names
	-- "nameplate" specifically - a title maps to a bestStreak threshold,
	-- so showing one mid-round announces who is worth targeting, and
	-- Q7's safety argument for the harsh streak-reset rule depends on
	-- that not being possible.
	--
	-- The flag exists so the decision is a config flip rather than a
	-- rewrite if it's ever revisited. Setting it true means amending Q7
	-- as well - Q7 itself says the decision "needs revisiting" if
	-- streak-hiding leaks, not that the leak is acceptable.
	titleDisplayDuringRound = false,

	-- P4-2's NPC title distribution. PLACEHOLDER, both: bots wear a
	-- title so a filled lobby doesn't look obviously fake, drawn from
	-- the lower rungs only. The top 6 of the 21 rungs (25 and up) are
	-- excluded, so a bot tops out at Twenty Deep - a bot wearing the
	-- rarest title in the game is MORE obviously fake than a bot
	-- wearing nothing.
	npcTitleNoneChance = 0.35,
	npcTitleTopRungsExcluded = 6,

	-- P4-7: analytics instrumentation. All PLACEHOLDER - no analytics
	-- schema exists yet. The disabled flag is a hard kill switch for when
	-- the telemetry sink breaks or ingests slowly.
	telemetry = {
		enabled = true,
		-- AnalyticsService batches up to this many events before flushing.
		-- PLACEHOLDER: matches a common default, but the actual limit is
		-- platform-specific - verify against current documentation.
		batchSize = 50,
		-- Seconds between forced flushes even if the batch isn't full.
		-- Long enough to batch effectively on a normal server, short
		-- enough that a dead server doesn't keep events for minutes.
		flushIntervalSeconds = 10,
		-- Per-event-name rate limit. 0 = no limit, >0 = max events per
		-- minute. Applied per player. PLACEHOLDER.
		perMinuteLimit = 0,
		-- Roblox only accepts analytics from a published game's server,
		-- so in Studio every event is dropped. true prints each one to
		-- Output instead, to check what would have been sent.
		studioEcho = false,
	},

	-- P3-6: "every probability and timing exposed for tuning without
	-- code changes" (the task's own requirement). The per-personality
	-- steal probabilities are deliberately NOT here - they live on each
	-- src/shared/Config/NPCPersonalities/*.luau file, so adding a
	-- personality stays a one-file change.
	--
	-- All PLACEHOLDER. Every weight below is a starting shape for the
	-- utility curve, not a tuned value - there is no telemetry yet on
	-- when a power-up use actually pays off.
	npcBrain = {
		-- Far slower than npc.tickHz on purpose: a power-up decision
		-- that lands a second late is invisible to everyone, and
		-- re-scoring is the cheapest thing to do less often.
		decisionHz = 2,

		utility = {
			-- Below useThreshold, so holding a usable item is the
			-- default and something about the situation has to push it
			-- over the line. Validation enforces that relationship.
			baseScore = 0.3,
			deficitWeight = 0.35,
			proximityWeight = 0.5,
			travelWeight = 0.4,
			deficitSaturation = 3, -- 3 tasks behind the leader = maximum urgency
			travelSaturationStuds = 80,
			useThreshold = 0.6,
		},

		-- Fractions of the Choose window (15s by default), so retuning
		-- studioTimers can't push a lock-in past the deadline. 0.25-0.8
		-- keeps every bot's commit visibly inside the window, with a
		-- real pause before it and real air after it.
		lockInEarliestFraction = 0.25,
		lockInLatestFraction = 0.8,

		-- 3 lines across a 20s Negotiate is roughly one every 6s -
		-- enough presence to read as a participant. The gap floor is 4s
		-- so all three fit: NPCBrainLogic.lineScheduleSeconds uses 85%
		-- of the window (17s) and stops early when the floor runs out
		-- of room, which at 6s dropped the third line about half the
		-- time.
		negotiationLineCount = 3,
		minSecondsBetweenLines = 4,

		chooseWobbleChance = 0.5,
	},

	-- P8-5: live operations. src/server/LiveConfigLogic.luau owns the
	-- rules; docs/live-ops.md is the operator's guide.
	liveOps = {
		-- false = never read the DataStore; every server runs exactly
		-- what shipped. The switch for "the live config itself is the
		-- incident".
		enabled = true,
		dataStoreName = "LiveConfig_v1",
		envelopeKey = "envelope",
		auditKey = "audit",
		-- Each refresh is one GetAsync per server. 60s keeps a fleet of
		-- servers far inside the per-server read budget, and a kill
		-- switch reaches every server within a minute.
		refreshSeconds = 60,
		auditLogCap = 200,
		-- The developers' Roblox user ids. Empty = nobody can run admin
		-- commands (edit the DataStore by hand instead).
		adminUserIds = { 11654855572 }, -- Corvus2026

		-- What an override may touch. "*" = one path segment, a trailing
		-- "**" = any depth. Roots: game = GameConfig, powerUp = PowerUps
		-- registry by id, effect = StatusEffectDefs by id, map = Maps
		-- registry by id. Every candidate is re-run through Validate, so a
		-- pattern here allows a path, never a bad value.
		--
		-- Deliberately NOT here: player/qualifier counts and anything
		-- else that changes the game's shape; place ids and MemoryStore
		-- names; and matchmaking's queue timings (TTLs, leases, formation
		-- tick). Those are read by every hub at once, and a staged
		-- rollout would run two sets of them against the same queue -
		-- the per-server settings below are the only safe ones.
		tunablePaths = {
			"game.raceDurationSeconds",
			"game.tasksPerPlayer",
			"game.qualificationFloorPercent",
			"game.roundTimers.*",
			"game.studioTimers.*",
			"game.winRewards.**",
			"game.powerUpRotationTimers.*",
			"game.powerUpUseRangeStuds",
			"game.npc.**",
			"game.npcBrain.**",
			"game.matchmaking.partialGroupTimeoutSeconds",
			"game.matchmaking.partialGroupMinPlayers",
			"game.matchmaking.rematchCooldownSeconds",
			"game.telemetry.enabled",
			"powerUp.*.durationSeconds",
			"powerUp.*.cooldownSeconds",
			"effect.*.magnitude",
			"effect.*.durationSeconds",
			"map.*.npcDifficultyModifier",
		},
	},
}

return GameConfig
