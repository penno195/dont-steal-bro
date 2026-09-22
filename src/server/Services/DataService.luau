--!strict
-- Player data service over ProfileStore (MadStudioRoblox/ProfileStore,
-- developed by loleris - the successor to ProfileService; wally.toml's
-- `lm-loleris/profilestore@1.0.3` pin re-verified current against the
-- upstream repo's own wally.toml for this task, Sept 2026). Players
-- teleport constantly between the hub and match places, so session
-- locking and release ordering are the whole game here.
--
-- WHY STREAK/BOUNTY ARE NEVER READ FROM TeleportData:
-- threat-model.md §5 - TeleportData is visible to (and effectively
-- settable by) a compromised client in some flows, so anything read from
-- it and trusted blindly can be forged. This profile, loaded fresh from
-- ProfileStore on every join, is the ONLY source of truth for streak and
-- bounty; TeleportData may only ever carry a cosmetic hint, the same
-- rule architecture.md's NPC-count pattern already follows.
--
-- WHY NO SEPARATE "STUDIO MOCK MODE": Roblox's DataStoreService already
-- auto-mocks itself in Studio unless "Enable Studio Access to API
-- Services" is turned on - reinventing that would just diverge from
-- ProfileStore's own tested code paths. The real footgun this guards
-- against instead: a developer enabling that setting for one unrelated
-- test, then a completely different Studio session accidentally reading
-- or writing PRODUCTION data because the store name collides. Using a
-- separate store name in Studio, decided automatically from RunService,
-- closes that regardless of the API-access setting - "automatic via
-- RunService, not a flag someone forgets" (P1-5's own requirement).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProfileStoreLib = require(ServerScriptService.ServerPackages.ProfileStore)
local Loader = require(ReplicatedStorage.Shared.Loader)
local ProfileLogic = require(ServerScriptService.Server.ProfileLogic)

local STORE_NAME = if RunService:IsStudio() then "PlayerData_Studio" else "PlayerData"

local PlayerStore = ProfileStoreLib.New(STORE_NAME, ProfileLogic.newProfileTemplate())

-- `any`, not the package's own exported `Profile<T>` type: ProfileStore's
-- Wally package is a re-export wrapper (ProfileStore.lua just returns
-- another module's require), and luau-lsp doesn't resolve a generic
-- type name through that indirection ("Unknown type 'ProfileStoreLib.
-- Profile'", confirmed locally). Real safety still comes from the
-- explicit `if profile == nil then return end` flow-narrowing inside
-- loadProfile below, which doesn't depend on this alias at all.
--
-- No service outside this one touches a raw profile table - everything
-- below is private, and DataService only ever exposes narrow typed
-- getters/setters further down.
local profiles: { [Player]: any } = {}
local pendingRoundOutcomeResolvers: { [Player]: () -> () } = {}

ProfileStoreLib.OnError:Connect(function(message: string, storeName: string, profileKey: string)
	warn(string.format("DataService: ProfileStore error on %s/%s: %s", storeName, profileKey, message))
end)

local function loadProfile(player: Player)
	local cancelled = false

	-- ProfileStore.luau's own StartSessionAsync body reads `params.Cancel`
	-- (see its source around line 1400), but this package's exported
	-- `StartSessionAsync` type only declares `{Steal: boolean?}` for
	-- `params` - Cancel is missing from the type even though it's real
	-- and load-bearing at runtime. `:: any` casts past that gap in the
	-- package's own types rather than fighting a type the package itself
	-- doesn't honour.
	local profile = PlayerStore:StartSessionAsync(
		tostring(player.UserId),
		{
			Cancel = function()
				cancelled = player.Parent ~= Players
				return cancelled
			end,
		} :: any
	)

	local outcome = ProfileLogic.classifyLoadOutcome(profile == nil, cancelled)

	if outcome == "CancelledByLeave" then
		return -- player already gone; nothing to log, nothing to kick
	end

	if outcome == "LikelyLockedOrOutage" then
		-- Session-lock diagnostic: StartSessionAsync doesn't say WHY it
		-- returned nil, but ruling out "we cancelled because the player
		-- already left" leaves exactly two real causes: another server
		-- still holds this profile's session lock (most common - a fast
		-- rejoin or a teleport race), or a genuine DataStore outage (see
		-- the ProfileStore.OnError handler above for outage detail).
		-- Either way the player can't safely continue without their real
		-- data, so they're kicked with a message that tells them what to
		-- actually do, not a bare "error."
		warn(
			string.format(
				"DataService: profile load denied for %s (%d) - likely still session-locked by another server, or a DataStore outage (see ProfileStore.OnError above for outage detail)",
				player.Name,
				player.UserId
			)
		)
		player:Kick("Your data is still saving from your last session - please rejoin in a few seconds.")
		return
	end

	-- outcome == "Loaded" here, but the type checker needs its own proof
	-- that `profile` isn't nil, not our classification function's say-so.
	if profile == nil then
		return
	end

	profile:AddUserId(player.UserId)

	-- Structural migration first (renames/restructures across schema
	-- versions), then Reconcile as a safety net for any brand-new
	-- template field a migration step didn't need to touch. Copies
	-- fields into the EXISTING Profile.Data table rather than replacing
	-- the table reference outright, in case ProfileStore holds its own
	-- internal reference to that exact table.
	local migrated = ProfileLogic.migrate(profile.Data :: any)
	local profileData = profile.Data :: any
	for key, value in migrated :: any do
		profileData[key] = value
	end
	profile:Reconcile()
	profileData.lastSeen = os.time()

	profile.OnSessionEnd:Connect(function()
		profiles[player] = nil
		pendingRoundOutcomeResolvers[player] = nil
		player:Kick("Your data session ended - please rejoin.")
	end)

	if player.Parent ~= Players then
		profile:EndSession()
		return
	end

	profiles[player] = profile
end

local function releaseProfile(player: Player)
	local profile = profiles[player]
	local ran = ProfileLogic.release(profile == nil, pendingRoundOutcomeResolvers[player], function()
		if profile ~= nil then
			profile:EndSession()
		end
	end)

	if ran then
		profiles[player] = nil
		pendingRoundOutcomeResolvers[player] = nil
	end
end

-- Registered by whichever service computes a pending round outcome
-- (DecisionService, P3-2) - called BEFORE the profile's session ends on
-- a mid-round leave, per ProfileLogic.applyLeaveSequence's ordering
-- guarantee. Overwrites any previous resolver for this player, since
-- only the most recent pending outcome is ever meaningful.
local function setPendingRoundOutcomeResolver(player: Player, resolver: (() -> ())?)
	if resolver == nil then
		pendingRoundOutcomeResolvers[player] = nil
	else
		pendingRoundOutcomeResolvers[player] = resolver
	end
end

-- ===== Typed getters/setters =============================================
-- The only way anything outside this module touches profile data.
-- Collections are copied out, not handed back by reference, so a caller
-- genuinely cannot mutate this module's state except through these
-- functions.

local function data(player: Player): ProfileLogic.ProfileData?
	local profile = profiles[player]
	if profile == nil then
		return nil
	end
	return profile.Data :: any
end

local function getStreak(player: Player): number
	local d = data(player)
	return if d then d.currentStreak else 0
end

local function getBestStreak(player: Player): number
	local d = data(player)
	return if d then d.bestStreak else 0
end

-- On a win. Bumps bestStreak too if this is a new peak - bestStreak is
local function getPendingBounty(player: Player): ProfileLogic.PendingBounty?
	local d = data(player)
	return if d then d.pendingBounty else nil
end

-- ===== the progression write gate (P4-1) ==================================
--
-- P4-1 requires `ProgressionService.applyRoundResult` to be the ONLY
-- path to a streak change anywhere in the codebase, and asks where the
-- remaining paths are so they can be closed. The honest answer, before
-- this, was "right here": DataService published incrementStreak,
-- resetStreak and setPendingBounty on its service table, so any of the
-- dozen services reachable through Loader.get could have moved a streak
-- without an audit line, a reason code or an idempotency key - and two
-- of them did.
--
-- Rather than rely on nobody doing it again, those three mutators are
-- gone. What replaces them is one atomic state write, handed out ONCE,
-- to the first caller that asks:
--
--   local writeStreakState = DataService.claimProgressionWriter()
--
-- ProgressionService claims it in its own init(). Any second caller -
-- a future service, a well-meaning patch, a copy-pasted line - gets a
-- loud error at boot naming who already holds it, rather than a silent
-- second writer. Loader's topological sort makes "first" deterministic:
-- ProgressionService declares DataService as a dependency, so it runs
-- after DataService's own init and before anything that depends on IT.
--
-- One function, not three, because the whole state moves together:
-- ProgressionLogic.applyResult computes currentStreak, bestStreak and
-- pendingBounty as a single before -> after transformation, and writing
-- them one at a time is what would let a yield land between "streak
-- reset" and "bounty cleared."
export type ProgressionWriter = (player: Player, state: ProfileLogic.ProgressionState) -> ()

local progressionWriterClaimedBy: string? = nil

local function writeProgressionState(player: Player, state: ProfileLogic.ProgressionState)
	local d = data(player)
	if d == nil then
		return
	end
	d.currentStreak = state.currentStreak
	d.bestStreak = state.bestStreak
	d.pendingBounty = state.pendingBounty
end

local function claimProgressionWriter(claimantName: string): ProgressionWriter
	assert(
		progressionWriterClaimedBy == nil,
		string.format(
			"DataService.claimProgressionWriter: already claimed by %q - there is exactly one progression writer in this game, and it is ProgressionService (P4-1). If you need a streak to change, call ProgressionService.applyRoundResult.",
			tostring(progressionWriterClaimedBy)
		)
	)
	progressionWriterClaimedBy = claimantName
	print(string.format("DataService: progression writer claimed by %s", claimantName))
	return writeProgressionState
end

local function getCurrency(player: Player): number
	local d = data(player)
	return if d then d.currency else 0
end

local function addCurrency(player: Player, amount: number)
	local d = data(player)
	if d ~= nil then
		d.currency = math.max(0, d.currency + amount)
	end
end

local function getStats(player: Player): ProfileLogic.Stats
	local d = data(player)
	if d == nil then
		return { roundsPlayed = 0, qualifications = 0, steals = 0, shares = 0, wins = 0, losses = 0 }
	end
	return table.clone(d.stats) -- a copy, not a live reference
end

local function recordRoundStat(
	player: Player,
	statName: "roundsPlayed" | "qualifications" | "steals" | "shares" | "wins" | "losses"
)
	local d = data(player)
	if d ~= nil then
		d.stats[statName] += 1
	end
end

local function getUnlockedTitles(player: Player): { string }
	local d = data(player)
	return if d then table.clone(d.unlockedTitles) else {}
end

-- Never revoked (gdd.md §3) - only ever appends.
local function unlockTitle(player: Player, titleId: string)
	local d = data(player)
	if d ~= nil and table.find(d.unlockedTitles, titleId) == nil then
		table.insert(d.unlockedTitles, titleId)
	end
end

local function getEquippedTitle(player: Player): string?
	local d = data(player)
	return if d then d.equippedTitle else nil
end

-- Refuses to equip a title this profile hasn't unlocked - the one
-- invariant this setter itself enforces, since nothing upstream of it
-- (a UI remote) should be trusted to have checked.
local function setEquippedTitle(player: Player, titleId: string?): boolean
	local d = data(player)
	if d == nil then
		return false
	end
	if titleId ~= nil and table.find(d.unlockedTitles, titleId) == nil then
		return false
	end
	d.equippedTitle = titleId
	return true
end

local DataService: Loader.Service = {
	name = "DataService",
	dependencies = {},
	setPendingRoundOutcomeResolver = setPendingRoundOutcomeResolver,
	getStreak = getStreak,
	getBestStreak = getBestStreak,
	getPendingBounty = getPendingBounty,
	-- P4-1: incrementStreak/resetStreak/setPendingBounty used to live
	-- here. They are deliberately gone - see the write gate above.
	claimProgressionWriter = claimProgressionWriter,
	getCurrency = getCurrency,
	addCurrency = addCurrency,
	getStats = getStats,
	recordRoundStat = recordRoundStat,
	getUnlockedTitles = getUnlockedTitles,
	unlockTitle = unlockTitle,
	getEquippedTitle = getEquippedTitle,
	setEquippedTitle = setEquippedTitle,
}

function DataService:init()
	for _, player in Players:GetPlayers() do
		task.spawn(loadProfile, player)
	end

	Players.PlayerAdded:Connect(loadProfile)
	Players.PlayerRemoving:Connect(releaseProfile)
end

return DataService
