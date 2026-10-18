--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The menu screens (P6-6): locker, store, leaderboards, results and
-- settings.
-- Owns their data (remotes -> Vide sources), the store's purchase flow,
-- the launcher that opens them, and which one is up. The screens never
-- touch a remote.
--
-- ONE MENU AT A TIME. Opening one closes whichever was open.
--
-- THE LAUNCHER: four buttons (locker, store, boards, settings) stacked on the
-- right edge at mid-height, where a right thumb rests in portrait and
-- clear of Roblox's jump button below. Hidden while a round is in play
-- (RaceHUD and the Decision Studio own the screen then), and while a
-- menu is open. Staff (liveOps.adminUserIds) get a fifth, the staff
-- gift panel (staff-tools.md step 4). On the Hub a Bank streak button
-- opens CashOutController's card (payoff-loop step 4), shown once
-- StoreState carries it.
--
-- THE COIN BALANCE: hub only, top-right under Roblox's top bar - where
-- players look for a currency. The "+" says it's a button: it opens the
-- store on the Coins tab. Hidden while a menu is open (the store shows
-- its own balance) and in a match place, where the HUD owns the corners.
-- The account level's badge (payoff-loop step 1c) sits to its left and
-- shows and hides with it, and so do the streak shields held (payoff-
-- loop step 2c), between the two, once there's at least one. Hub only:
-- the player's own screen, never during a live round (Q7 condition 1).
--
-- LEVEL-UP: a round that crossed a level shows the claim pop-up with
-- what the level paid, once the player taps Continue on the results.
--
-- RESULTS opens itself on entering Results - but only once the Decision
-- Studio screen is gone (DecisionStudioController.isActive), because
-- the reveal outlives the Studio phase (docs/decision-studio.md).
--
-- Data freshness, per screen (the P6-6 note; docs/menu-screens.md):
--   store        StoreState live+targeted; catalogue is static config
--   leaderboards cached server-side, broadcast every 60-120s, kept here
--   results      RoundRecap once per round, targeted; tally counted here
--   settings     SettingsController (live, targeted)

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local GroupService = game:GetService("GroupService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local vide = require(ReplicatedStorage.Packages.Vide)

local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local DailyChallenges = require(ReplicatedStorage.Shared.Config.DailyChallenges)
local Events = require(ReplicatedStorage.Shared.Config.Events)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local StoreConfig = require(ReplicatedStorage.Shared.Config.Store)
local Seasons = require(ReplicatedStorage.Shared.Config.Seasons)
local StoreOffers = require(ReplicatedStorage.Shared.StoreOffers)
local Titles = require(ReplicatedStorage.Shared.Config.Titles)
local LifetimeTitles = require(ReplicatedStorage.Shared.Config.LifetimeTitles)
local LockerLogic = require(script.Parent.Parent.UI.LockerLogic)
local BoardLogic = require(script.Parent.Parent.UI.BoardLogic)
local C = require(script.Parent.Parent.UI.Components)
local CashOutViewLogic = require(script.Parent.Parent.UI.CashOutViewLogic)
local RecordViewLogic = require(script.Parent.Parent.UI.RecordViewLogic)
local DailyChallengeViewLogic = require(script.Parent.Parent.UI.DailyChallengeViewLogic)
local DailyChallengesScreen = require(script.Parent.Parent.UI.Screens.DailyChallenges)
local Base = require(script.Parent.Parent.UI.Components.Base)
local ResultsLogic = require(script.Parent.Parent.UI.ResultsLogic)
local StoreScreenLogic = require(script.Parent.Parent.UI.StoreScreenLogic)
local SeasonTrackLogic = require(script.Parent.Parent.UI.SeasonTrackLogic)
local Theme = require(script.Parent.Parent.UI.Theme)
local HubCorner = require(script.Parent.Parent.UI.Screens.HubCorner)
local LeaderboardsScreen = require(script.Parent.Parent.UI.Screens.Leaderboards)
local LockerScreen = require(script.Parent.Parent.UI.Screens.Locker)
local DropNames = require(script.Parent.Parent.UI.DropNames)
local ResultsScreen = require(script.Parent.Parent.UI.Screens.Results)
local SettingsScreen = require(script.Parent.Parent.UI.Screens.Settings)
local StoreScreen = require(script.Parent.Parent.UI.Screens.Store)
local ClaimPopup = require(script.Parent.Parent.UI.Screens.ClaimPopup)
local ItemPreview = require(script.Parent.Parent.UI.Screens.ItemPreview)
local StaffPanelScreen = require(script.Parent.Parent.UI.Screens.StaffPanel)
local GiftLogic = require(script.Parent.Parent.UI.GiftLogic)
local PrizeReveal = require(script.Parent.Parent.UI.Screens.PrizeReveal)
local PrizeRevealLogic = require(script.Parent.Parent.UI.PrizeRevealLogic)
local StaffPanelLogic = require(script.Parent.Parent.UI.StaffPanelLogic)
local DecisionStudioController = require(script.Parent.DecisionStudioController)
local SettingsController = require(script.Parent.SettingsController)
local UIScaleController = require(script.Parent.UIScaleController)

local source = vide.source
local create = vide.create

local selfId = Players.LocalPlayer.UserId

-- Round states with a screen of their own, when the launcher stays away.
local IN_PLAY: { [string]: boolean } = {
	Loading = true,
	Intro = true,
	Race = true,
	Qualified = true,
	DecisionStudio = true,
}

local FLOW_TICK = 0.5
-- How often the store's view of the server clock moves on. Sale windows
-- are to the minute, and the server refuses anything that just ended.
local OFFER_TICK = 30
local STUDIO_POLL = 0.25
-- Title unlocks that land within this long share one toast (a join's
-- backfill, or a round that crossed several rungs).
local UNLOCK_GATHER = 1
-- A staff gift waits this long before it pops, so a few given in quick
-- succession share one pop-up.
local GIFT_BATCH = 0.5
-- Seconds between the Hub being clear and the tutorial reward's spin
-- starting, so the player has landed before the show begins.
local REVEAL_SETTLE = 0.8
-- How long the staff panel waits for StaffGrantResult before saying
-- there was no reply (NetGuard drops a rate-limited intent silently).
local STAFF_REPLY_WAIT = 10

-- ===== static config =========================================================

local items: { StoreScreenLogic.Item } = {}
local byAssetId: { [number]: string } = {}
local imageByKey: { [string]: number } = {} -- store art, for gift cards
for _, entry in StoreConfig do
	table.insert(items, entry.def :: any)
	if entry.def.assetId ~= 0 then
		byAssetId[entry.def.assetId] = entry.def.key
	end
	if entry.def.imageAssetId ~= 0 then
		imageByKey[entry.def.key] = entry.def.imageAssetId
	end
end

-- ===== offers ================================================================
-- What's on sale right now (design-decisions.md Q1, "the featured
-- plinths"), on the server's clock: a player's own clock never decides
-- what shows. StoreService runs the same StoreOffers checks on os.time(),
-- and its answer is the one that counts.

local serverNow = source(Workspace:GetServerTimeNow())
local livePrices = source({} :: { [string]: number })
local priceAsked: { [string]: boolean } = {}

local function isOffered(item: StoreScreenLogic.Item): boolean
	return StoreOffers.isOffered(StoreConfig :: any, item :: any, serverNow())
end

-- What Roblox really charges for a Robux item with a "was" price: the
-- sale tag shows only if that's lower (Q1, "the featured plinths").
-- Asked once per key; config's robuxPrice stands in until it answers.
local function fetchLivePrice(item: StoreScreenLogic.Item)
	local assetId = (item :: any).assetId :: number
	if item.kind == "CoinOffer" or item.wasPrice == nil or assetId == 0 or priceAsked[item.key] then
		return
	end
	priceAsked[item.key] = true
	task.spawn(function()
		local infoType = if item.kind == "GamePass" then Enum.InfoType.GamePass else Enum.InfoType.Product
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfoAsync(assetId, infoType)
		end)
		local price = if ok and type(info) == "table" then (info :: any).PriceInRobux else nil
		if type(price) == "number" then
			local nextPrices = table.clone(livePrices())
			nextPrices[item.key] = price
			livePrices(nextPrices)
		else
			priceAsked[item.key] = false -- try again next time it's shown
		end
	end)
end

local function priceOf(item: StoreScreenLogic.Item): StoreScreenLogic.Price
	if item.kind == "CoinOffer" then
		return { now = item.coinPrice or 0, was = StoreOffers.wasPrice(item :: any, nil) }
	end
	fetchLivePrice(item)
	local live = livePrices()[item.key]
	return { now = live or item.robuxPrice, was = StoreOffers.wasPrice(item :: any, live) }
end

local cosmeticDefs: { [string]: any } = {}
for _, entry in Cosmetics do
	cosmeticDefs[entry.def.id] = entry.def
end
local powerUpDefs: { [string]: any } = {}
local powerUpIds: { string } = {}
for _, entry in PowerUps do
	powerUpDefs[entry.def.id] = entry.def
	table.insert(powerUpIds, entry.def.id)
end

-- The Locker's Style tab groups cosmetics in this order: what you wear
-- first, then what shows in the Studio.
local COSMETIC_CATEGORY_ORDER = {
	"Skin",
	"Hat",
	"BackItem",
	"Trail",
	"Nameplate",
	"StreakFlair",
	"Emote",
	"Projectile",
	"Podium",
	"Reveal",
	"CallingCard",
}
local titleNames: { [string]: string } = {}
local titleColors: { [string]: Color3 } = {}
local titleLadder: { { id: string, minStreak: number } } = {}
for _, entry in Titles do
	titleNames[entry.def.id] = entry.def.displayName
	titleColors[entry.def.id] = Color3.fromHex(entry.def.colorHex)
	table.insert(titleLadder, { id = entry.def.id, minStreak = entry.def.minStreak })
end
-- The lifetime ladders (payoff-loop step 9), listed under the streak
-- ladder in the Locker.
local lifetimeLadder: { LockerLogic.LifetimeDef } = {}
for _, entry in LifetimeTitles do
	titleNames[entry.def.id] = entry.def.displayName
	titleColors[entry.def.id] = Color3.fromHex(entry.def.colorHex)
	table.insert(lifetimeLadder, { id = entry.def.id, stat = entry.def.stat, threshold = entry.def.threshold })
end

local seasonDefs: { [string]: SeasonTrackLogic.SeasonDef } = {}
for _, entry in Seasons do
	seasonDefs[entry.def.id] = entry.def :: any
end

local function rarityOf(grant: StoreScreenLogic.Grant): string?
	if grant.kind == "Cosmetic" and grant.cosmeticId then
		local def = cosmeticDefs[grant.cosmeticId]
		return def and def.rarity
	elseif grant.kind == "PowerUpStock" and grant.powerUpId then
		local def = powerUpDefs[grant.powerUpId]
		return def and def.rarity
	end
	return nil
end

-- A reward's own picture (SeasonTrackLogic.pictureFor); nil shows its
-- icon (SeasonTrackLogic.iconFor).
local function grantImage(grant: SeasonTrackLogic.Grant): number?
	return SeasonTrackLogic.pictureFor(grant, function(id: string): number?
		local def = cosmeticDefs[id]
		return def and def.previewIconAssetId
	end, function(id: string): number?
		local def = powerUpDefs[id]
		return def and def.pictureAssetId
	end)
end

local function cosmeticName(id: string): string
	local def = cosmeticDefs[id]
	return if def then def.displayName else id
end

-- ===== staff panel ===========================================================
-- staff-tools.md step 4. The button shows for liveOps.adminUserIds only;
-- StaffService re-checks the sender on every give.

-- The Locker's Style tab shows every enabled cosmetic, locked where
-- not owned (owner, 2026-10-18), all but the community reward, which has
-- its own tile there. Sorted by LockerLogic.cosmetics.
local cosmeticCatalog: { string } = {}
for id, def in cosmeticDefs do
	if def.enabled and id ~= GameConfig.community.rewardCosmeticId then
		table.insert(cosmeticCatalog, id)
	end
end

local function grantsCosmetic(grant: any, id: string): boolean
	return grant.kind == "Cosmetic" and grant.cosmeticId == id
end

-- A locked cosmetic up close: the player wearing it, what it is, and
-- where to get it right now.
local function previewLockedCosmetic(id: string)
	local def = cosmeticDefs[id]
	if def == nil then
		return
	end
	local store = false
	for _, item in items do
		if not isOffered(item) then
			continue
		end
		for _, grant in (item :: any).grants or {} do
			store = store or grantsCosmetic(grant, id)
		end
	end
	local pass = false
	for _, season in seasonDefs do
		if not (season :: any).enabled then
			continue
		end
		for _, track in { (season :: any).free, (season :: any).premium } do
			for _, tier in track or {} do
				pass = pass or grantsCosmetic(tier.grant, id)
			end
		end
	end
	local how = LockerLogic.howToGet({
		level = def.unlockLevel,
		store = store,
		pass = pass,
		drop = def.winDrop == true,
	})
	ItemPreview.open({
		title = def.displayName,
		-- A level item's description already says which level.
		body = if how and def.unlockLevel == nil then def.description .. "\n" .. how else def.description,
		def = def,
		icon = "gem",
		image = if def.previewIconAssetId ~= 0 then def.previewIconAssetId else nil,
	})
end

local isStaff = StaffPanelLogic.isStaff(selfId, GameConfig.liveOps.adminUserIds)

local staffCosmetics: { StaffPanelLogic.CosmeticEntry } = {}
for id, def in cosmeticDefs do
	table.insert(staffCosmetics, { id = id, name = def.displayName, category = def.category })
end
staffCosmetics = StaffPanelLogic.sortCosmetics(staffCosmetics)

local staffPlayers = source({} :: { StaffPanelLogic.PlayerEntry })
local staffResult = source(nil :: StaffPanelLogic.Result?)
local staffBusy = source(false)
local staffSent = 0 -- which give a reply timeout belongs to

local function refreshStaffPlayers()
	local entries: { StaffPanelLogic.PlayerEntry } = {}
	for _, player in Players:GetPlayers() do
		table.insert(entries, { userId = player.UserId, displayName = player.DisplayName, name = player.Name })
	end
	staffPlayers(StaffPanelLogic.sortPlayers(entries))
end

local function staffGive(payload: { [string]: any })
	staffBusy(true)
	staffSent += 1
	local sent = staffSent
	Net.fireServer("StaffGrantIntent", payload)
	task.delay(STAFF_REPLY_WAIT, function()
		if sent == staffSent and staffBusy() then
			staffBusy(false)
			staffResult({ ok = false, message = "No reply from the server. Wait a moment and try again." })
		end
	end)
end

-- Events (step 5): the panel's second tab. What's on comes from the
-- attributes EventService sets in Hub servers.
local staffEvents: { StaffPanelLogic.EventEntry } = {}
local staffEventNames: { [string]: string } = {}
for _, entry in Events do
	staffEventNames[entry.def.id] = entry.def.displayName
	if entry.def.enabled then
		table.insert(staffEvents, { id = entry.def.id, name = entry.def.displayName })
	end
end
local staffEventResult = source(nil :: StaffPanelLogic.Result?)
local staffEventBusy = source(false)
local staffEventSent = 0
local liveEvent = source(nil :: { id: string, endsAt: number }?)

local function readLiveEvent()
	local id = ReplicatedStorage:GetAttribute("LiveEventId")
	local endsAt = ReplicatedStorage:GetAttribute("LiveEventEndsAt")
	if type(id) == "string" and type(endsAt) == "number" then
		liveEvent({ id = id, endsAt = endsAt })
	else
		liveEvent(nil)
	end
end

local function staffSendEvent(payload: { [string]: any })
	staffEventBusy(true)
	staffEventSent += 1
	local sent = staffEventSent
	Net.fireServer("StaffEventIntent", payload)
	task.delay(STAFF_REPLY_WAIT, function()
		if sent == staffEventSent and staffEventBusy() then
			staffEventBusy(false)
			staffEventResult({ ok = false, message = "No reply from the server. Wait a moment and try again." })
		end
	end)
end

local function grantText(grant: StoreScreenLogic.Grant): string
	if grant.kind == "Currency" then
		return string.format("%d coins", grant.amount or 0)
	elseif grant.kind == "PowerUpStock" and grant.powerUpId then
		local def = powerUpDefs[grant.powerUpId]
		return string.format("%dx %s", grant.amount or 1, if def then def.displayName else grant.powerUpId)
	elseif grant.kind == "Cosmetic" and grant.cosmeticId then
		return cosmeticName(grant.cosmeticId)
	elseif grant.kind == "Title" and grant.titleId then
		return string.format("Title: %s", titleNames[grant.titleId] or grant.titleId)
	end
	return grant.kind
end

-- A season pass tile up close (the Store's `preview`).
local function previewSeasonItem(row: SeasonTrackLogic.Row, premium: boolean)
	local grant = row.grant
	ItemPreview.open({
		title = grantText(grant :: any),
		body = string.format(
			"%s · %s",
			if premium then "Paid pass" else "Free pass",
			if row.wins == 0 then "yours now" else string.format("at %d wins", row.wins)
		),
		def = if grant.kind == "Cosmetic" and grant.cosmeticId then cosmeticDefs[grant.cosmeticId] else nil,
		icon = SeasonTrackLogic.iconFor(grant),
		image = grantImage(grant),
	})
end

-- ===== state =================================================================

local storeState = source(nil :: StoreScreenLogic.StoreState?)
local flow = source(StoreScreenLogic.idle())
local boards = source({} :: { [string]: BoardLogic.Payload })
local recap = source(nil :: ResultsLogic.Recap?)
local tally = source({ placement = nil, fieldSize = 0, tasksCompleted = 0, powerUpsUsed = 0 } :: ResultsLogic.RaceTally)
local roundState = source(nil :: string?)
-- Today's daily challenges (payoff-loop step 8c): DailyChallengeState,
-- when it arrived, and whether a swap is waiting on the server.
local challengeState = source(nil :: DailyChallengeViewLogic.State?)
local challengeReceivedAt = source(0)
local challengeRerolling = source(false)
-- A swap's answer never came: let the buttons work again.
local REROLL_TIMEOUT = 8
local rerollSerial = 0

-- step hands back the same table when nothing changed; only a real
-- change is written, so the twice-a-second Tick doesn't re-run the store
-- screen's derives for nothing.
local function stepFlow(event: StoreScreenLogic.FlowEvent)
	local current = flow()
	local nextFlow = StoreScreenLogic.step(current, event, os.clock())
	if nextFlow ~= current then
		flow(nextFlow)
	end
end

-- ===== the community reward ================================================

-- The Locker's "free for group members" tile (GameConfig.community).
-- Tapping it opens Roblox's own join prompt, then asks the server to
-- check; the server asks Roblox, so nothing here can grant the item.
local communityText = source("Join the Studio Corvus community, then tap here.")
local communityBusy = false

local COMMUNITY_TEXT: { [string]: string } = {
	NotMember = "Not in the group yet. Join it, then tap again.",
	TooSoon = "Checked a moment ago. Tap again in a few seconds.",
	Unavailable = "Couldn't check right now. Try again later.",
	Owned = "Already yours. Find it below.",
}

local function communityOffered(): boolean
	local config = GameConfig.community
	local def = cosmeticDefs[config.rewardCosmeticId]
	local state = storeState()
	return config.groupId > 0
		and def ~= nil
		and def.enabled
		and state ~= nil
		and table.find(state.ownedCosmetics, config.rewardCosmeticId) == nil
end

local function checkCommunity()
	if communityBusy then
		return
	end
	communityBusy = true
	communityText("Opening the join prompt...")
	task.spawn(function()
		local ok, status = pcall(GroupService.PromptJoinAsync, GroupService, GameConfig.community.groupId)
		if ok and status == Enum.GroupMembershipStatus.JoinRequestPending then
			communityText("Join request sent. Tap again once it's accepted.")
			communityBusy = false
		elseif ok and status == Enum.GroupMembershipStatus.None then
			communityText("Join the Studio Corvus community, then tap here.")
			communityBusy = false
		else
			-- Joined, already a member, or the prompt failed (it may have
			-- been joined on the website): either way, let the server look.
			communityText("Checking...")
			Net.fireServer("CommunityRewardCheck", {})
		end
	end)
end

-- "Same as last round", from the Locker or the queue strip. The server
-- picks what goes in, from the profile.
local function repeatLastLoadout()
	Net.fireServer("StoreLoadoutRepeatIntent", {})
end

local function setBoard(tab: string, payload: any)
	if type(payload) ~= "table" or type(payload.entries) ~= "table" then
		return
	end
	local nextBoards = table.clone(boards())
	nextBoards[tab] = {
		entries = payload.entries,
		status = if type(payload.status) == "string" then payload.status else "Fresh",
		periodKey = payload.periodKey,
	}
	boards(nextBoards)
end

-- ===== screens ===============================================================

type Menu = "Store" | "Locker" | "Leaderboards" | "Results" | "Settings" | "Staff"

local openMenu: Menu? = nil
local unmountMenu: (() -> ())? = nil
local syncLauncher: () -> () = function() end
-- The launcher's Locker button, for the hub tutorial's spotlight.
local lockerButtonRef: GuiObject? = nil

-- Same check as QueueController's: the hub place, or in Studio a place
-- with a Hub model when no hub place id is configured.
local function isHubServer(): boolean
	local hubPlaceId = GameConfig.matchmaking.hubPlaceId
	if hubPlaceId == 0 then
		return RunService:IsStudio() and Workspace:FindFirstChild("Hub") ~= nil
	end
	return game.PlaceId == hubPlaceId
end

-- The level-up pop-up (payoff-loop step 1c), shown once per recap when
-- the player leaves the results with Continue. A results screen the
-- next round closes for them skips it; its level card already said so.
local levelUpShownFor: string? = nil

local function showLevelUp()
	local r = recap()
	local level = if r then r.level else nil
	if r == nil or level == nil or ResultsLogic.levelsGained(level) == 0 or levelUpShownFor == r.roundId then
		return
	end
	if IN_PLAY[roundState() or ""] then
		return
	end
	levelUpShownFor = r.roundId
	local shown: { ClaimPopup.Reward } = {}
	if level.levelUpCurrency > 0 then
		local grant = { kind = "Currency", amount = level.levelUpCurrency }
		table.insert(shown, {
			premium = true,
			text = grantText(grant :: any),
			icon = SeasonTrackLogic.iconFor(grant :: any),
			image = nil,
		})
	end
	for _, id in level.cosmetics do
		local grant = { kind = "Cosmetic", cosmeticId = id }
		table.insert(shown, {
			premium = true,
			text = grantText(grant :: any),
			icon = SeasonTrackLogic.iconFor(grant :: any),
			image = grantImage(grant :: any),
		})
	end
	if #shown == 0 then
		return
	end
	ClaimPopup.open(
		shown,
		string.format("LEVEL %d!", level.after.level),
		if ResultsLogic.levelsGained(level) > 1
			then string.format("Up %d levels this round.", ResultsLogic.levelsGained(level))
			else "You levelled up."
	)
	Loader.get("AudioController").play("SeasonClaim")
end

local function closeMenu()
	if unmountMenu ~= nil then
		(unmountMenu :: () -> ())()
		unmountMenu = nil
	end
	openMenu = nil
	syncLauncher()
end

-- The Hub's daily challenges panel (payoff-loop step 8c).
local function openChallenges()
	if challengeState() == nil then
		return
	end
	closeMenu()
	local close: () -> ()
	close = C.Modal.open({
		title = DailyChallengeViewLogic.TITLE,
		actions = {
			{
				label = "Close",
				variant = "secondary",
				onActivate = function()
					close()
				end,
			},
		},
		dismissible = true,
		onDismiss = function()
			close()
		end,
		content = function()
			return DailyChallengesScreen.content({
				state = challengeState,
				receivedAt = challengeReceivedAt,
				rerolling = challengeRerolling,
				onReroll = function(slot: number)
					if challengeRerolling() then
						return
					end
					challengeRerolling(true)
					rerollSerial += 1
					local mine = rerollSerial
					Net.fireServer("DailyChallengeRerollIntent", { slot = slot })
					task.delay(REROLL_TIMEOUT, function()
						if rerollSerial == mine then
							challengeRerolling(false)
						end
					end)
				end,
			})
		end,
	})
end

local function bankCard(): CashOutViewLogic.Card?
	local s = storeState()
	return CashOutViewLogic.parse(if s then s.cashOut else nil)
end

-- Whether the streak can be banked right now: the Record tab's dot.
local function streakBankable(): boolean
	local card = bankCard()
	return card ~= nil and card.available
end

-- Whether a Locker tab ("Power", "Style", "Titles") holds something not
-- yet looked at. The server only sends `lockerUnseen` to the Hub.
local function lockerUnseen(tab: string): boolean
	local s = storeState()
	local unseen = if s then s.lockerUnseen else nil
	return type(unseen) == "table" and unseen[tab] == true
end

-- The Hub launcher's Locker dot: any tab's dot.
local function lockerHasNew(): boolean
	return streakBankable() or lockerUnseen("Power") or lockerUnseen("Style") or lockerUnseen("Titles")
end

local function open(menu: Menu, storeCategory: StoreScreenLogic.Category?, storeKey: string?)
	closeMenu()
	openMenu = menu
	if menu == "Store" then
		unmountMenu = StoreScreen.mount(UIScaleController, {
			items = items,
			initialCategory = storeCategory,
			initialKey = storeKey,
			isOffered = isOffered,
			priceOf = priceOf,
			rarityOf = rarityOf,
			grantText = grantText,
			cosmeticName = cosmeticName,
			cosmeticDef = function(id: string): any?
				return cosmeticDefs[id]
			end,
			state = storeState,
			flow = flow,
			buy = function(key: string)
				local before = flow()
				stepFlow({ type = "Tap", key = key, state = storeState() })
				if flow() ~= before then
					Net.fireServer("StorePurchaseIntent", { key = key })
				end
			end,
			dismiss = function()
				stepFlow({ type = "Dismiss" })
			end,
			equip = function(cosmeticId: string, wear: boolean)
				local def = cosmeticDefs[cosmeticId]
				local slot = def and StoreScreenLogic.slotFor(def.category)
				if slot then
					Net.fireServer("StoreEquipIntent", { slot = slot, itemId = if wear then cosmeticId else nil })
				end
			end,
			close = closeMenu,
			seasonView = function(): SeasonTrackLogic.View?
				local s = storeState()
				local season = if s then s.season else nil
				local def = if season then seasonDefs[season.id] else nil
				if season == nil or def == nil then
					return nil
				end
				return SeasonTrackLogic.view(def, season :: any, grantText :: any, grantImage)
			end,
			preview = previewSeasonItem,
			claim = function(track: ("Free" | "Premium")?, upTo: number?)
				Net.fireServer("SeasonClaimIntent", { track = track, upTo = upTo })
			end,
			passKeyOf = function(seasonId: string): string?
				local def = seasonDefs[seasonId]
				return if def then def.passKey else nil
			end,
		})
	elseif menu == "Locker" then
		unmountMenu = LockerScreen.mount(UIScaleController, {
			state = storeState,
			powerUpIds = powerUpIds,
			powerUpName = function(id: string): string
				local def = powerUpDefs[id]
				return if def then def.displayName else id
			end,
			powerUpRarity = function(id: string): string?
				local def = powerUpDefs[id]
				return def and def.rarity
			end,
			cosmeticName = cosmeticName,
			cosmeticCategory = function(id: string): string?
				local def = cosmeticDefs[id]
				return def and def.category
			end,
			cosmeticRarity = function(id: string): string?
				local def = cosmeticDefs[id]
				return def and def.rarity
			end,
			cosmeticDef = function(id: string): any?
				return cosmeticDefs[id]
			end,
			powerUpPicture = function(id: string): number?
				local def = powerUpDefs[id]
				return def and def.pictureAssetId
			end,
			categoryOrder = COSMETIC_CATEGORY_ORDER,
			cosmeticCatalog = cosmeticCatalog,
			previewLocked = previewLockedCosmetic,
			community = {
				offered = communityOffered,
				name = cosmeticName(GameConfig.community.rewardCosmeticId),
				text = communityText,
				check = checkCommunity,
			},
			setSlot = function(slotIndex: number, powerUpId: string?)
				Net.fireServer("StoreLoadoutIntent", { slotIndex = slotIndex, powerUpId = powerUpId })
			end,
			repeatLast = repeatLastLoadout,
			equip = function(cosmeticId: string, slot: string, wear: boolean)
				Net.fireServer("StoreEquipIntent", { slot = slot, itemId = if wear then cosmeticId else nil })
			end,
			titleLadder = titleLadder,
			lifetimeLadder = lifetimeLadder,
			titleName = function(id: string): string
				return titleNames[id] or id
			end,
			titleColor = function(id: string): Color3
				return titleColors[id] or Theme.color.ink
			end,
			equipTitle = function(titleId: string?)
				Net.fireServer("TitleEquipIntent", { titleId = titleId })
			end,
			close = closeMenu,
			-- The Record tab (payoff-loop step 7's panel; the server sends
			-- the record to the Hub only).
			record = function(): string?
				local s = storeState()
				local record = RecordViewLogic.parse(if s then s.record else nil)
				return if record then RecordViewLogic.body(record) else "Your record shows in the lobby."
			end,
			bank = if isHubServer()
				then {
					available = function(): boolean
						return bankCard() ~= nil
					end,
					ready = streakBankable,
					open = function()
						closeMenu()
						Loader.get("CashOutController").open()
					end,
				}
				else nil,
			seen = if isHubServer()
				then {
					unseen = lockerUnseen,
					mark = function(tab: string)
						Net.fireServer("LockerSeenIntent", { tab = tab })
					end,
				}
				else nil,
		})
	elseif menu == "Leaderboards" then
		unmountMenu =
			LeaderboardsScreen.mount(UIScaleController, { selfId = selfId, boards = boards, close = closeMenu })
	elseif menu == "Results" then
		unmountMenu = ResultsScreen.mount(UIScaleController, {
			recap = recap,
			tally = tally,
			close = function()
				closeMenu()
				showLevelUp()
			end,
			nameOf = DropNames,
			finalistName = DecisionStudioController.nameOf,
		})
	elseif menu == "Staff" then
		staffResult(nil)
		staffEventResult(nil)
		readLiveEvent()
		refreshStaffPlayers()
		unmountMenu = StaffPanelScreen.mount(UIScaleController, {
			players = staffPlayers,
			cosmetics = staffCosmetics,
			cosmeticName = cosmeticName,
			result = staffResult,
			busy = staffBusy,
			give = staffGive,
			close = closeMenu,
			events = staffEvents,
			eventName = function(id: string): string
				return staffEventNames[id] or id
			end,
			live = liveEvent,
			serverNow = function(): number
				return Workspace:GetServerTimeNow()
			end,
			eventResult = staffEventResult,
			eventBusy = staffEventBusy,
			sendEvent = staffSendEvent,
		})
	else
		unmountMenu = SettingsScreen.mount(UIScaleController, {
			settings = SettingsController.settings,
			loaded = SettingsController.loaded,
			change = SettingsController.change,
			reset = SettingsController.reset,
			close = closeMenu,
			-- HubIntroController opens it once the menu has closed.
			showIntro = if isHubServer()
				then function()
					SettingsController.change({ introSeen = false })
					closeMenu()
				end
				else nil,
			-- QueueController requires this controller, so it's fetched
			-- at tap time.
			playTutorial = if isHubServer()
				then function()
					closeMenu()
					Loader.get("QueueController").startTutorial()
				end
				else nil,
		})
	end
	syncLauncher()
end

-- ===== launcher ==============================================================

-- The Hub menu pass (2026-10-18, docs/ui-art-pass/hub-menu.html): one
-- top-right corner. Along the top, the Settings gear, the shields and
-- coins, then a column headed by the level pill (Hub only: its playtime
-- row and daily challenges drop-down, Screens/HubCorner) with three big
-- buttons under it: Locker, Store, Ranks. The bank and "Your record"
-- buttons moved into the Locker's Record tab, the challenges button into
-- the drop-down. On a match server it's the gear and the three buttons.
local BIG = 52 -- the launcher buttons' edge, reference px

-- Daily challenge files by id, for a tapped row's description.
local challengeDefs: { [string]: any } = {}
for _, entry in DailyChallenges do
	challengeDefs[entry.def.id] = entry.def
end

-- A Hub drop-down row's explainer pop-up.
local function explainer(title: string, body: string)
	local close: () -> ()
	close = C.Modal.open({
		title = title,
		body = body,
		bodyLines = 5,
		actions = {
			{
				label = "Got it",
				variant = "primary",
				onActivate = function()
					close()
				end,
			},
		},
		dismissible = true,
		onDismiss = function()
			close()
		end,
	})
end
local BIG_ICON = 44
local COLUMN_W = 3 * BIG + 2 * Theme.spacing.sm

local function mountLauncher()
	-- In the top bar's band (right of Roblox's buttons), so the corner
	-- doesn't start a whole bar's height down (playtest, 2026-10-18).
	local gui = UIScaleController.createScreen("MenuLauncher", { displayOrder = Theme.displayOrder.hud, topbar = true })
	local visible = source(true)
	local coinsVisible = source(false)
	local inHub = isHubServer()
	syncLauncher = function()
		local free = openMenu == nil and not IN_PLAY[roundState() or ""]
		visible(free)
		coinsVisible(free and inHub)
	end

	vide.root(function()
		local function big(icon: string, label: string, order: number, onActivate: () -> ()): TextButton
			return C.IconButton({
				icon = icon,
				label = label,
				caption = label,
				edge = BIG,
				iconSize = BIG_ICON,
				variant = "secondary",
				onActivate = onActivate,
				order = order,
				layoutOrder = order,
			})
		end
		local lockerButton = big("hub-locker", "Locker", 2, function()
			open("Locker")
		end)
		lockerButtonRef = lockerButton
		-- A pink dot while any Locker tab has one: something new to look
		-- at, or a streak that can be banked (not just a bank card: the
		-- Hub always sends one, refusing below the minimum).
		create("Frame")({
			Name = "Dot",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(1, -Theme.spacing.xs, 0, Theme.spacing.xs),
			Size = UDim2.fromOffset(Theme.spacing.md + Theme.spacing.xxs, Theme.spacing.md + Theme.spacing.xxs),
			BackgroundColor3 = Theme.color.brand,
			ZIndex = 6,
			Visible = lockerHasNew,
			Base.corner(Theme.radius.pill),
			create("UIStroke")({ Color = Theme.color.outline, Thickness = 2 }),
			Parent = lockerButton,
		})
		local buttons = create("Frame")({
			Name = "Launcher",
			Size = UDim2.fromOffset(COLUMN_W, BIG + Theme.spacing.sm),
			BackgroundTransparency = 1,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			lockerButton,
			big("hub-shop", "Store", 3, function()
				open("Store")
			end),
			big("hub-trophy", "Ranks", 4, function()
				open("Leaderboards")
			end),
		}) :: Frame

		local column: Frame = if inHub
			then HubCorner.column({
				width = COLUMN_W,
				visible = coinsVisible,
				level = function()
					local s = storeState()
					return if s and s.level then s.level.level else nil
				end,
				fraction = function()
					local s = storeState()
					return if s and s.level then ResultsLogic.levelFraction(s.level) else 0
				end,
				playtime = function()
					local s = storeState()
					return if s and s.season then SeasonTrackLogic.playtimeView(s.season :: any) else nil
				end,
				challenges = challengeState,
				receivedAt = challengeReceivedAt,
				openChallenges = openChallenges,
				explain = function(slot: DailyChallengeViewLogic.Slot)
					local def = challengeDefs[slot.id]
					explainer(slot.label, DailyChallengeViewLogic.explainer(slot, def and def.description))
				end,
				explainPlaytime = function()
					local s = storeState()
					local view = if s and s.season then SeasonTrackLogic.playtimeView(s.season :: any) else nil
					if view then
						explainer(
							"Free Season Pass",
							SeasonTrackLogic.playtimeExplainer(GameConfig.playtimePass.activeHoursPerWeek, view)
						)
					end
				end,
				buttons = buttons,
			})
			else buttons
		column.LayoutOrder = 5

		local coins = C.CurrencyPill({
			amount = function()
				local s = storeState()
				return if s then s.currency else 0
			end,
			onActivate = function()
				open("Store", "Currency")
			end,
			order = 1,
			layoutOrder = 4,
		})
		local shieldCount = vide.derive(function()
			local s = storeState()
			return (if s then ResultsLogic.parseShields(s.streakShields) else nil) or 0
		end)
		local shields = C.CurrencyPill({
			amount = shieldCount,
			icon = "shield",
			layoutOrder = 3,
		})
		vide.effect(function()
			coins.Visible = coinsVisible()
			shields.Visible = coinsVisible() and shieldCount() > 0
		end)
		local gear = C.IconButton({
			icon = "hub-settings",
			label = "Settings",
			iconSize = Theme.spacing.xl + Theme.spacing.xs,
			variant = "secondary",
			onActivate = function()
				open("Settings")
			end,
			order = 0,
			layoutOrder = 2,
		})
		local staff = if isStaff
			then C.IconButton({
				icon = "gift",
				label = "Staff",
				variant = "secondary",
				onActivate = function()
					open("Staff")
				end,
				order = 6,
				layoutOrder = 1,
			})
			else nil

		-- One scaled row, anchored top-right, so everything keeps its
		-- place beside the column at any UI scale.
		local corner = create("Frame")({
			Name = "Corner",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -Theme.spacing.md, 0, Theme.spacing.sm),
			Size = UDim2.fromOffset(0, 0),
			AutomaticSize = Enum.AutomaticSize.XY,
			BackgroundTransparency = 1,
			Visible = visible,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				VerticalAlignment = Enum.VerticalAlignment.Top,
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			staff :: any,
			gear,
			shields,
			coins,
			column,
			Parent = gui,
		}) :: Frame
		UIScaleController.attachScale(corner)
	end)
end

-- ===== round lifecycle =======================================================

local resultsToken = 0

local function onRoundState(state: string)
	roundState(state)
	if state == "Loading" or state == "Intro" then
		recap(nil)
		tally({ placement = nil, fieldSize = 0, tasksCompleted = 0, powerUpsUsed = 0 })
	end
	if IN_PLAY[state] and openMenu ~= nil then
		closeMenu()
	end
	if state == "Results" then
		-- Wait out the Studio's reveal, then show the recap - unless the
		-- round has moved on or the player opened something else first.
		resultsToken += 1
		local token = resultsToken
		task.spawn(function()
			while DecisionStudioController.isActive() do
				task.wait(STUDIO_POLL)
				if token ~= resultsToken or roundState() ~= "Results" then
					return
				end
			end
			if openMenu == nil then
				open("Results")
			end
		end)
	else
		resultsToken += 1
	end
	syncLauncher()
end

-- ===== staff gifts ===========================================================
-- staff-tools.md step 3. Only the Hub sends GiftReceived (GiftLogic);
-- the gifts are already in the profile, this only says so, then tells
-- the server which ones it showed. A Hub practice round holds it.

local heldGifts: { GiftLogic.Gift } = {}
local giftSeen: { [string]: boolean } = {} -- ids shown or waiting
local giftWaiting = false

-- Blocks until no round is in play, the Studio is shut and the loading
-- screen is gone, so a pop-up isn't opened under or over any of them.
local function waitUntilClear()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	while
		IN_PLAY[roundState() or ""]
		or DecisionStudioController.isActive()
		or playerGui:FindFirstChild("LoadingCover") ~= nil
	do
		task.wait(STUDIO_POLL)
	end
end

local function showGifts()
	local gifts = heldGifts
	heldGifts = {}
	if #gifts == 0 then
		return
	end
	Net.fireServer("GiftsSeenIntent", { upToId = gifts[#gifts].id })
	local shown: { ClaimPopup.Reward } = {}
	for _, gift in gifts do
		local key = GiftLogic.storeKey(gift)
		table.insert(shown, {
			premium = true,
			text = GiftLogic.text(gift, cosmeticName),
			icon = GiftLogic.icon(gift),
			image = if gift.kind == "Cosmetic"
				then grantImage({ kind = "Cosmetic", cosmeticId = gift.cosmeticId } :: any)
				elseif key then imageByKey[key]
				else nil,
		})
	end
	local title, body = GiftLogic.heading(gifts)
	ClaimPopup.open(shown, title, body)
	Loader.get("AudioController").play("SeasonClaim")
end

local function holdGifts(gifts: { GiftLogic.Gift })
	local fresh = GiftLogic.fresh(gifts, giftSeen)
	if #fresh == 0 then
		return
	end
	for _, gift in fresh do
		giftSeen[gift.id] = true
		table.insert(heldGifts, gift)
	end
	if giftWaiting then
		return
	end
	giftWaiting = true
	task.spawn(function()
		task.wait(GIFT_BATCH)
		-- Sent as the profile loads, so on joining the Hub it would
		-- otherwise pop up under the loading screen.
		waitUntilClear()
		giftWaiting = false
		showGifts()
	end)
end

-- The "Earned by playtime" pass pop-up (payoff-loop step 5c). Match time
-- counts toward the pass, so it can unlock mid-race: the pop-up waits,
-- like the gifts, for the round and the Studio to be over.
local function showPlaytimePass(def: SeasonTrackLogic.SeasonDef, before: SeasonTrackLogic.SeasonState)
	task.spawn(function()
		waitUntilClear()
		local title, body = SeasonTrackLogic.playtimePassText(def, before)
		ClaimPopup.open({
			{
				premium = true,
				text = def.displayName .. " pass",
				icon = "star",
				image = imageByKey[def.passKey],
			},
		}, title, body)
		Loader.get("AudioController").play("SeasonClaim")
	end)
end

local MenuController: Loader.Controller = {
	name = "MenuController",
	dependencies = { "UIScaleController", "SettingsController", "DecisionStudioController" },

	-- For QueueController's loadout strip, which shows the same
	-- StoreState and opens the Locker.
	storeState = storeState,
	openLocker = function()
		open("Locker")
	end,
	-- For HubIntroController (tutorial v2 seam 3): the launcher's Locker
	-- button, to spotlight while the launcher is showing.
	lockerButton = function(): GuiObject?
		return lockerButtonRef
	end,
	-- For StorePlinthController: a plinth opens the store on its item,
	-- and draws it with the same offers and prices the store uses.
	openStoreOn = function(key: string)
		open("Store", nil, key)
	end,
	featured = function(): { [number]: StoreScreenLogic.Item }
		return StoreOffers.featured(StoreConfig :: any, serverNow()) :: any
	end,
	priceOf = priceOf,
	repeatLastLoadout = repeatLastLoadout,
	-- For BuyBackController: which menu is up (nil = none), and the
	-- round state as this controller last heard it.
	currentMenu = function(): string?
		return openMenu
	end,
	roundState = roundState,
	isHubServer = isHubServer,
}

function MenuController:init()
	Net.onClientEvent("RoundState", function(payload: any)
		if type(payload.state) == "string" then
			onRoundState(payload.state)
		end
	end)

	-- Title unlocks (P4-2, lifetime rungs from payoff-loop step 9), as a
	-- toast. Gathered for a moment so a join's backfill is one toast, and
	-- held through the Studio so a streak rung can't announce a win
	-- before the reveal (LockerLogic.holdsUnlockToast).
	local pendingUnlocks: { LockerLogic.Unlock } = {}
	local unlockFlushing = false
	Net.onClientEvent("TitleUnlocked", function(payload: any)
		if type(payload) ~= "table" or type(payload.title) ~= "table" then
			return
		end
		table.insert(pendingUnlocks, {
			name = tostring(payload.title.displayName),
			minStreak = payload.minStreak,
			lifetime = payload.lifetime,
		})
		if unlockFlushing then
			return
		end
		unlockFlushing = true
		task.spawn(function()
			task.wait(UNLOCK_GATHER)
			while LockerLogic.holdsUnlockToast(roundState(), DecisionStudioController.isActive()) do
				task.wait(STUDIO_POLL)
			end
			local text = LockerLogic.unlockToast(pendingUnlocks)
			pendingUnlocks = {}
			unlockFlushing = false
			if text ~= nil then
				C.Toast.show(text, "success")
			end
		end)
	end)

	-- Store.
	Net.onClientEvent("StoreState", function(payload: any)
		-- A season-pass claim lands as higher paid counts: celebrate what
		-- it paid with the pop-up and its sound.
		local before = storeState()
		local beforeSeason = if before then before.season else nil
		local afterSeason = if type(payload) == "table" then payload.season else nil
		local def = if type(afterSeason) == "table" then seasonDefs[afterSeason.id] else nil
		if def ~= nil then
			local rewards = SeasonTrackLogic.claimedBetween(def, beforeSeason :: any, afterSeason)
			if #rewards > 0 then
				local shown: { ClaimPopup.Reward } = {}
				for _, reward in rewards do
					table.insert(shown, {
						premium = reward.premium,
						text = grantText(reward.grant :: any),
						icon = SeasonTrackLogic.iconFor(reward.grant),
						image = grantImage(reward.grant),
					})
				end
				ClaimPopup.open(shown)
				Loader.get("AudioController").play("SeasonClaim")
			end
			if SeasonTrackLogic.earnedByPlaytime(beforeSeason :: any, afterSeason) then
				showPlaytimePass(def, beforeSeason :: any)
			end
		end
		storeState(payload)
		stepFlow({ type = "State", state = payload })
	end)
	Net.onClientEvent("CommunityRewardResult", function(payload: any)
		communityBusy = false
		local status = if type(payload) == "table" then payload.status else nil
		if status == "Granted" then
			communityText("Join the Studio Corvus community, then tap here.")
			local grant = { kind = "Cosmetic", cosmeticId = GameConfig.community.rewardCosmeticId }
			ClaimPopup.open({
				{
					premium = true,
					text = grantText(grant :: any),
					icon = SeasonTrackLogic.iconFor(grant :: any),
					image = grantImage(grant :: any),
				},
			})
			Loader.get("AudioController").play("SeasonClaim")
		elseif type(status) == "string" and COMMUNITY_TEXT[status] then
			communityText(COMMUNITY_TEXT[status])
		end
	end)
	-- The guided round's once-only reward, revealed back in the Hub
	-- (owner, 2026-10-15): a prize-wheel spin with ticks over the reveal
	-- riser, then a flash, confetti and the claim pop-up with its win
	-- flourish. It waits, like the gift pop-up, for the loading screen
	-- and any other dialog to clear, so the show isn't missed.
	local tutorialRevealing = false
	Net.onClientEvent("TutorialRewarded", function(payload: any)
		local grants = if type(payload) == "table" and type(payload.grants) == "table" then payload.grants else {}
		local shown: { ClaimPopup.Reward } = {}
		for _, grant in grants :: { any } do
			table.insert(shown, {
				premium = true,
				text = grantText(grant),
				icon = SeasonTrackLogic.iconFor(grant),
				image = grantImage(grant),
			})
		end
		if #shown == 0 or tutorialRevealing then
			return
		end
		tutorialRevealing = true
		task.spawn(function()
			local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
			while
				IN_PLAY[roundState() or ""]
				or DecisionStudioController.isActive()
				or playerGui:FindFirstChild("LoadingCover") ~= nil
				or playerGui:FindFirstChild("Modal") ~= nil
			do
				task.wait(STUDIO_POLL)
			end
			task.wait(REVEAL_SETTLE)
			Net.fireServer("TutorialRewardSeenIntent", {})
			local audio = Loader.get("AudioController") :: any
			local reveal = PrizeReveal.open(PrizeRevealLogic.SPIN)
			audio.play("RevealRiser")
			local started = os.clock()
			for _, tick in PrizeRevealLogic.ticks() do
				local wait = tick.at - (os.clock() - started)
				if wait > 0 then
					task.wait(wait)
				end
				audio.playScaled("PrizeTick", tick.volume)
				reveal.tick()
			end
			local rest = PrizeRevealLogic.SPIN - (os.clock() - started)
			if rest > 0 then
				task.wait(rest)
			end
			reveal.reveal()
			ClaimPopup.open(shown, "TUTORIAL DONE!", "First round finished. These are yours.")
			audio.play("SeasonClaim")
			-- The rays stay behind the pop-up until it goes, however it goes
			-- (Nice!, a tap outside, or another dialog replacing it).
			local modal = playerGui:FindFirstChild("Modal")
			if modal then
				modal.Destroying:Connect(reveal.close)
			else
				reveal.close()
			end
			tutorialRevealing = false
		end)
	end)
	Net.onClientEvent("GiftReceived", function(payload: any)
		holdGifts(GiftLogic.read(payload))
	end)
	if isStaff then
		Net.onClientEvent("StaffGrantResult", function(payload: any)
			local result = StaffPanelLogic.readResult(payload)
			if result ~= nil then
				staffBusy(false)
				staffResult(result)
			end
		end)
		Net.onClientEvent("StaffEventResult", function(payload: any)
			local result = StaffPanelLogic.readResult(payload)
			if result ~= nil then
				staffEventBusy(false)
				staffEventResult(result)
			end
		end)
		ReplicatedStorage:GetAttributeChangedSignal("LiveEventId"):Connect(readLiveEvent)
		ReplicatedStorage:GetAttributeChangedSignal("LiveEventEndsAt"):Connect(readLiveEvent)
		-- The panel's player list follows the server while it's open.
		Players.PlayerAdded:Connect(refreshStaffPlayers)
		Players.PlayerRemoving:Connect(function(leaving: Player)
			local entries: { StaffPanelLogic.PlayerEntry } = {}
			for _, entry in staffPlayers() do
				if entry.userId ~= leaving.UserId then
					table.insert(entries, entry)
				end
			end
			staffPlayers(entries)
		end)
	end
	Net.onClientEvent("StorePurchaseResult", function(payload: any)
		if type(payload.key) == "string" and type(payload.status) == "string" then
			stepFlow({
				type = "Result",
				key = payload.key,
				status = payload.status,
				message = if type(payload.message) == "string" then payload.message else "",
			})
		end
	end)
	-- The prompt-closed signals only move the spinner; ownership still
	-- comes from StoreState alone. Note the two disagree on their first
	-- argument (a Player vs a user id) - see StoreService.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			local key = byAssetId[passId]
			if player == Players.LocalPlayer and key then
				stepFlow({ type = "PromptClosed", key = key, purchased = purchased })
			end
		end
	)
	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(userId: number, productId: number, purchased: boolean)
			local key = byAssetId[productId]
			if userId == selfId and key then
				stepFlow({ type = "PromptClosed", key = key, purchased = purchased })
			end
		end
	)

	-- Boards.
	Net.onClientEvent("LeaderboardState", function(payload: any)
		setBoard("AllTime", payload)
	end)
	Net.onClientEvent("PeriodBoardState", function(payload: any)
		if payload.kind == "Daily" or payload.kind == "Weekly" then
			setBoard(payload.kind, payload)
		end
	end)

	-- Results: the recap, and the tally from what this client already saw.
	Net.onClientEvent("RoundRecap", function(payload: any)
		if type(payload) == "table" and type(payload.reason) == "string" then
			payload.level = ResultsLogic.parseLevel(payload.level)
			payload.guess = ResultsLogic.parseGuess(payload.guess)
			payload.streakShields = ResultsLogic.parseShields(payload.streakShields)
			payload.shieldSpent = payload.shieldSpent == true
			payload.challenges = ResultsLogic.parseChallenges(payload.challenges)
			recap(payload)
		end
	end)
	-- Daily challenges (payoff-loop step 8c).
	Net.onClientEvent("DailyChallengeState", function(payload: any)
		local state = DailyChallengeViewLogic.parse(payload)
		if state ~= nil then
			challengeReceivedAt(os.clock())
			challengeState(state)
			challengeRerolling(false)
		end
	end)
	Net.onClientEvent("DailyChallengeRerollResult", function(payload: any)
		challengeRerolling(false)
		if type(payload) == "table" and payload.status == "Refused" then
			C.Toast.show(DailyChallengeViewLogic.refusalText(payload.reason), "warning")
		end
	end)
	Net.onClientEvent("TaskQualificationResult", function(payload: any)
		local ranked = if type(payload) == "table" then payload.ranked else nil
		if type(ranked) ~= "table" then
			return
		end
		local nextTally = table.clone(tally())
		nextTally.fieldSize = #ranked
		for _, entry in ranked do
			if entry.playerId == selfId then
				nextTally.placement = entry.rank
				nextTally.tasksCompleted = entry.tasksCompleted
			end
		end
		tally(nextTally)
	end)
	Net.onClientEvent("PowerUpUseResult", function(payload: any)
		if type(payload) == "table" and payload.success == true then
			local nextTally = table.clone(tally())
			nextTally.powerUpsUsed += 1
			tally(nextTally)
		end
	end)
end

function MenuController:start()
	mountLauncher()
	syncLauncher()

	-- The flow's timeouts (REQUEST_TIMEOUT, GRANT_WAIT). A tick while
	-- idle is a no-op in the reducer, so this doesn't check the phase.
	task.spawn(function()
		while true do
			task.wait(FLOW_TICK)
			stepFlow({ type = "Tick" })
		end
	end)
	task.spawn(function()
		while true do
			task.wait(OFFER_TICK)
			serverNow(Workspace:GetServerTimeNow())
		end
	end)
end

return MenuController
