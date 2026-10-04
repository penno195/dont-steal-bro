--!strict
-- The title system (P4-2): unlock detection, equip/unequip, and the
-- server half of the two places a title is displayed - the nametag
-- above a character and the chat prefix. The ladder is config
-- (src/shared/Config/Titles/), the rules are pure
-- (src/server/TitleLogic.luau, tested headlessly), and this file is
-- what reads real profiles and talks to real clients.
--
-- ===== PERMANENCE IS STRUCTURAL, NOT POLICY =============================
--
-- P4-2: titles "are never removed when a streak resets - that
-- permanence is the whole emotional point, so make it structurally
-- impossible to revoke one." Four separate things make it so, and no
-- single one of them is a rule anybody has to remember:
--
--   * Unlocking reads bestStreak, never currentStreak (TitleLogic.
--     unlockedFor takes only the one argument).
--   * bestStreak is never lowered by anything - P4-1's
--     ProgressionLogic.applyResult only raises it, asserted for every
--     reason code in its own spec.
--   * The stored list is append-only (DataService.unlockTitle ignores
--     a duplicate and has no removal counterpart).
--   * Nothing in this file, TitleLogic or DataService can remove an
--     unlocked title. There is no function to call.
--
-- Unequipping is a different thing entirely and is of course allowed -
-- that puts a title away, it doesn't take it back.
--
-- ===== WHY TITLES VANISH MID-ROUND ======================================
--
-- design-decisions.md Q7 condition 1 forbids any in-round tell of a
-- player's streak and names "nameplate" specifically. A title maps to a
-- bestStreak threshold, so it is exactly such a tell. Titles therefore
-- show in the pre-round lobby and after the result is in, and are
-- suppressed for every state in between - including the Decision
-- Studio, where three finalists reading each other's rungs would learn
-- who needs the win.
--
-- The suppression lives in `broadcastTitles`, which simply does not
-- send other players' titles while a round is live. A modified client
-- has nothing to un-hide, because it was never sent (Ground Rule 1).
-- GameConfig.titleDisplayDuringRound flips it, and flipping it means
-- amending Q7, not just the flag.

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Titles = require(ReplicatedStorage.Shared.Config.Titles)
local Participants = require(ServerScriptService.Server.Participants)
local NPCLogic = require(ServerScriptService.Server.NPCLogic)
local TitleLogic = require(ServerScriptService.Server.TitleLogic)

local ladder: { TitleLogic.TitleDef } = {}
for _, entry in Titles do
	table.insert(ladder, entry.def :: any)
end

-- What each racer is currently WEARING, by participant id - humans from
-- their profile, NPCs from a one-off draw. Rebuilt rather than trusted:
-- it's a replication cache, and the profile is the source of truth.
local wornTitleId: { [number]: string? } = {}

-- bestStreak as this service last saw it, per player. The unlock check
-- is a diff against this rather than a recompute of the whole ladder,
-- so it can fire the notification for exactly the rungs just crossed.
local lastKnownBestStreak: { [Player]: number } = {}

local function currentRoundState(): string
	local RoundService = Loader.get("RoundService") :: any
	return RoundService.getState() :: string
end

local function titlePayload(def: TitleLogic.TitleDef?): { [string]: any }?
	if def == nil then
		return nil
	end
	-- Deliberately no `minStreak`. The threshold IS a streak number, and
	-- Q7 condition 1 keeps streak off every shared surface - a payload
	-- carrying it would leak by inspection what the nametag was
	-- carefully not showing.
	return {
		id = def.id,
		displayName = def.displayName,
		colorHex = def.colorHex,
		effect = def.effect,
	}
end

-- ===== replication =========================================================

-- One broadcast describing who wears what. Called on every change and
-- on every round-state change, because the round state is half of what
-- decides the answer.
--
-- Each entry also names the racer's Nameplate cosmetic - the frame the
-- nametag is drawn in. It rides this broadcast, and so this suppression,
-- on purpose: Q7 condition 1 names "nameplate" as a surface, and a frame
-- showing mid-round is a tag on a racer whether or not the words inside
-- it are. Read from the profile (CosmeticService), so a client can't
-- dress anyone else. `title` may be nil when only the frame is worn.
local function broadcastTitles()
	local visible = TitleLogic.isVisibleInState(currentRoundState(), GameConfig.titleDisplayDuringRound)

	local entries = {}
	if visible then
		local CosmeticService = Loader.get("CosmeticService") :: any
		for _, participant in Participants.all() do
			local def = TitleLogic.findById(ladder, wornTitleId[participant.id])
			local nameplateId = CosmeticService.equippedIdFor(participant.player, "Nameplate") :: string?
			if def ~= nil or nameplateId ~= nil then
				table.insert(
					entries,
					{ racerId = participant.id, title = titlePayload(def), nameplateId = nameplateId }
				)
			end
		end
	end

	-- An empty list mid-round is not a special case the client has to
	-- understand - it just means "nobody has a visible title," which is
	-- exactly true.
	Net.fireAllClients("TitleState", { titles = entries, visible = visible })
end

-- ===== unlocking ===========================================================

-- Persists one rung and tells its owner.
local function grant(player: Player, def: TitleLogic.TitleDef)
	local DataService = Loader.get("DataService") :: any
	DataService.unlockTitle(player, def.id)
	Net.fireClient("TitleUnlocked", player, {
		title = titlePayload(def),
		-- Sent to the OWNER only, and it's their own number, which
		-- they already know - the reason TitleUnlocked is targeted
		-- rather than broadcast.
		minStreak = def.minStreak,
	})
	print(string.format("TitleService: %s unlocked %q at bestStreak %d", player.Name, def.id, def.minStreak))
end

-- Runs on every bestStreak change. Persists each newly crossed rung and
-- tells the player about each one. The baseline comes from `onProfileLoaded`;
-- before that the profile reads as bestStreak 0, which would both hide
-- the title and re-announce every rung later, so it does nothing.
local function refreshUnlocks(player: Player)
	local DataService = Loader.get("DataService") :: any
	local previous = lastKnownBestStreak[player]
	if previous == nil or not DataService.isLoaded(player) then
		return
	end
	local bestStreak = DataService.getBestStreak(player) :: number

	-- A range, not a single rung: bestStreak can cross several at once,
	-- and dropping the extras would leave titles unlocked that nobody
	-- was told about.
	for _, def in TitleLogic.newlyUnlocked(ladder, previous, bestStreak) do
		grant(player, def)
	end

	lastKnownBestStreak[player] = bestStreak
end

-- Join: set the baseline from the loaded profile, granting only rungs it
-- has reached but doesn't hold (see TitleLogic.unownedReached).
local function seedUnlocks(player: Player)
	local DataService = Loader.get("DataService") :: any
	local bestStreak = DataService.getBestStreak(player) :: number
	local owned = DataService.getUnlockedTitles(player) :: { string }
	for _, def in TitleLogic.unownedReached(ladder, owned, bestStreak) do
		grant(player, def)
	end
	lastKnownBestStreak[player] = bestStreak
end

-- What a player should be shown wearing: their own choice if they made
-- one, otherwise the highest rung they've reached. A player who has
-- never opened a menu still gets to show off.
local function resolveWornTitle(player: Player): string?
	local DataService = Loader.get("DataService") :: any

	local equipped = DataService.getEquippedTitle(player) :: string?
	if equipped ~= nil and TitleLogic.findById(ladder, equipped) ~= nil then
		return equipped
	end

	local highest = TitleLogic.highestUnlocked(ladder, DataService.getBestStreak(player) :: number)
	return if highest ~= nil then highest.id else nil
end

local function refreshPlayer(player: Player)
	refreshUnlocks(player)
	wornTitleId[player.UserId] = resolveWornTitle(player)
end

-- ===== equip / unequip =====================================================

local function handleEquipIntent(player: Player, titleId: string?)
	local DataService = Loader.get("DataService") :: any

	local unlocked = DataService.getUnlockedTitles(player) :: { string }
	if not TitleLogic.canEquip(unlocked, titleId) then
		warn(string.format("TitleService: %s tried to equip %q without owning it", player.Name, tostring(titleId)))
		return
	end

	-- DataService re-checks the same rule against the profile itself -
	-- this is defence in depth, not a duplicated decision: the check
	-- above avoids a pointless write, the one below is the enforcement.
	if not DataService.setEquippedTitle(player, titleId) then
		return
	end

	wornTitleId[player.UserId] = resolveWornTitle(player)
	broadcastTitles()
end

-- ===== NPC titles ==========================================================

-- P4-2: "titles must appear for NPCs too, drawn from a plausible fake
-- distribution, so a bot-filled lobby does not look obviously fake."
--
-- Worth stating plainly: with titleDisplayDuringRound false (Q7), no
-- human wears a visible title during a race either, so a title-less bot
-- is currently indistinguishable from a title-less human anyway. This
-- is implemented for the surfaces where titles DO show - the results
-- screen, with bots still in the round - and so the behaviour is
-- already correct the day that flag is ever flipped, rather than being
-- a gap discovered then.
local function assignNPCTitles()
	for _, participant in Participants.npcs() do
		if wornTitleId[participant.id] ~= nil then
			continue
		end
		local rng = NPCLogic.newRng(participant.id * 7717 + 3)
		local def =
			TitleLogic.pickNPCTitle(ladder, rng(), GameConfig.npcTitleNoneChance, GameConfig.npcTitleTopRungsExcluded)
		wornTitleId[participant.id] = if def ~= nil then def.id else nil
	end
end

-- ===== chat prefix =========================================================

-- TextChatService.OnIncomingMessage is a CLIENT-side callback property
-- (it runs on each receiving client to decorate a message before it is
-- displayed), so the prefix itself is applied in
-- NametagController.luau. What this function does is the server half:
-- decide whether a prefix is allowed to exist right now at all, and
-- publish the data it would be built from - which is the same
-- TitleState broadcast the nametags use.
--
-- Doing it this way means there is exactly ONE place the Q7 suppression
-- is enforced, and both display surfaces inherit it. A client that
-- never received a title cannot prefix a message with one.
local function installChatPrefixNotice()
	-- Nothing to install server-side. This function exists so the
	-- absence is deliberate and documented rather than looking like an
	-- oversight next to the nametag half - see NametagController.
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		warn(
			"TitleService: TextChatService is not the active chat version - title chat prefixes will not appear. Set ChatVersion to TextChatService in Studio."
		)
	end
end

-- ===== service =============================================================

local TitleService: Loader.Service = {
	name = "TitleService",
	dependencies = { "NetGuard", "ConfigValidator", "DataService", "RoundService", "ParticipantService" },

	getWornTitleId = function(racerId: number): string?
		return wornTitleId[racerId]
	end,

	-- Called by StoreService after a cosmetic equip, so a new Nameplate
	-- frame shows without waiting for the next round-state change.
	broadcast = broadcastTitles,

	-- Called by ProgressionService after a streak change, so an unlock
	-- notification lands in the same beat as the win that earned it
	-- rather than on the next join.
	refreshFor = refreshPlayer,

	refreshAll = function()
		for _, player in Players:GetPlayers() do
			refreshPlayer(player)
		end
		assignNPCTitles()
		broadcastTitles()
	end,
}

function TitleService:init()
	local NetGuard = Loader.get("NetGuard") :: any
	local RoundService = Loader.get("RoundService") :: any

	installChatPrefixNotice()

	NetGuard.on("TitleEquipIntent", function(player: Player, payload: any)
		handleEquipIntent(player, payload.titleId)
	end)

	-- Not PlayerAdded: the profile loads after it, and until then it
	-- reads as bestStreak 0. Seeding there left the Hub, where the
	-- round state never changes to trigger another refresh, showing
	-- the streak counter with no title under it.
	local DataService = Loader.get("DataService") :: any
	DataService.onLoaded(function(player: Player)
		seedUnlocks(player)
		wornTitleId[player.UserId] = resolveWornTitle(player)
		broadcastTitles()
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastKnownBestStreak[player] = nil
		wornTitleId[player.UserId] = nil
	end)

	-- The round state is half of what decides visibility, so every
	-- transition re-broadcasts. Cheap: one small payload per state
	-- change, not per frame.
	for _, state in
		{ "WaitingForPlayers", "Loading", "Intro", "Race", "Qualified", "DecisionStudio", "Results", "Cleanup" }
	do
		RoundService.onEnter(state, function()
			if state == "Results" then
				-- Post-match is where titles reappear, and it's the
				-- first moment this round's wins have been recorded -
				-- so refresh unlocks before showing anything.
				for _, player in Players:GetPlayers() do
					refreshPlayer(player)
				end
				assignNPCTitles()
			end
			broadcastTitles()
		end)
	end
end

return TitleService
