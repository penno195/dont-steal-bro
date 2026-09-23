--!strict
-- Monetisation (P4-5): game passes, developer products, receipts,
-- ownership checks, the purchase prompt flow, and equip state.
--
-- The catalogue is config (src/shared/Config/Store/), the rules are pure
-- (src/server/StoreLogic.luau, tested headlessly in
-- tests/StoreLogic.spec.luau), and this file is what talks to the real
-- MarketplaceService and the real profile.
--
-- ===== THE ONLY PART OF THIS FILE THAT REALLY MATTERS ===================
--
-- `processReceipt` below returns PurchaseGranted in exactly two
-- situations, and nowhere else:
--
--   1. This PurchaseId is already in the buyer's SAVED profile, so the
--      grant happened in some earlier session and is durable. Nothing
--      is granted again.
--   2. We applied the grant, wrote the PurchaseId alongside it in the
--      same Profile.Data mutation, and then WATCHED that write land in
--      Profile.LastSavedData.
--
-- Every other path returns NotProcessedYet, which asks Roblox to
-- re-offer the receipt later. That asymmetry is the whole design:
-- returning NotProcessedYet when we actually did grant costs nothing
-- (the replay is recognised and confirmed next time), while returning
-- PurchaseGranted a moment too early costs the player their purchase
-- if the server dies before the save. One of those errors is
-- recoverable and the other is not, so the code only ever makes the
-- recoverable one.
--
-- "The same write" is literal, not a figure of speech: ProfileStore
-- serialises the whole of Profile.Data on each save, so mutating the
-- grant and the PurchaseId cache before calling Save() means the
-- DataStore either holds both or neither. There is no window where a
-- player is charged and un-granted, or granted without a record that
-- would stop a second grant.
--
-- ===== WHY A CLIENT CANNOT REACH ANY OF THIS ============================
--
-- 1. FORGING A PURCHASE. There is no remote that grants anything. The
--    only client-facing purchase remote (StorePurchaseIntent) asks the
--    server to open a Roblox prompt; the grant arrives later through
--    MarketplaceService.ProcessReceipt, which is a server callback
--    Roblox invokes directly and no client can send to.
--
-- 2. AIMING A PROMPT AT AN ARBITRARY ASSET. StorePurchaseIntent carries
--    a catalogue `key`, not an assetId. The key is looked up in this
--    game's own config, and an entry that is disabled or has no real
--    assetId is refused before a prompt is ever opened.
--
-- 3. REPLAYING A RECEIPT. Not reachable in the first place (see 1), and
--    harmless if it somehow were: StoreLogic.classifyReceipt keys off
--    the PurchaseId in the saved profile, not off anything in flight.
--
-- 4. CLAIMING TO OWN A COSMETIC OR A PASS. Equip checks read the
--    profile's own owned list; pass ownership is read from
--    MarketplaceService, cached server-side, and never sent in by a
--    client. The client is told what it owns; it never tells us.
--
-- 5. INFLATING A LOADOUT PAST 3. StoreLoadoutIntent names a slot index,
--    which is validated against GameConfig.store.loadoutSlots (pinned
--    to 3 by design-decisions.md Q8 at boot), and against the stock the
--    profile actually holds.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local StoreCatalogue = require(ReplicatedStorage.Shared.Config.Store)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local StoreLogic = require(ServerScriptService.Server.StoreLogic)

type StoreItemDef = Validate.StoreItemDef

-- ===== the catalogue, indexed =============================================

local byKey: { [string]: StoreItemDef } = {}
local byAssetId: { [number]: StoreItemDef } = {}
local loadoutEligible: { [string]: boolean } = {}

for _, entry in StoreCatalogue do
	local def = entry.def :: StoreItemDef
	byKey[def.key] = def
	-- Only ENABLED entries are reachable by asset id. An entry that is
	-- switched off must not be purchasable and must not be granted, and
	-- keying the receipt lookup on the same table the prompt uses means
	-- those two can never disagree. Id 0 is never indexed: several
	-- unfinished entries legitimately share it.
	if def.enabled and def.assetId > 0 then
		byAssetId[def.assetId] = def
	end
end

for _, entry in PowerUps do
	local def = entry.def :: Validate.PowerUpDef
	loadoutEligible[def.id] = def.acquisition.loadoutEligible
end

-- ===== state ==============================================================

-- The one handle DataService hands out for receipt work. Claimed in
-- init(); see DataService's own "receipt write gate" section.
local receiptHandleFor: ((player: Player) -> any?)? = nil

-- Game pass ownership, per player per pass: the answer and when it was
-- taken. Server-local and rebuilt on join - it's a cache in front of a
-- Roblox web call, not a record of anything.
type OwnershipEntry = { owned: boolean, checkedAt: number }
local ownership: { [Player]: { [number]: OwnershipEntry } } = {}

-- Every grant this server has made, newest last. In memory only: the
-- durable record is the profile itself plus Roblox's own transaction
-- history. This exists so a live server can be asked "what did you hand
-- this person in the last hour" without a DataStore read.
export type GrantRecord = {
	userId: number,
	productKey: string,
	purchaseId: string?,
	changes: { string },
	at: number,
}
local grantLog: { GrantRecord } = {}
local GRANT_LOG_LIMIT = 200

local function now(): number
	return os.clock()
end

-- ===== replication ========================================================

-- A player's own store state, to that player only. Never
-- fireAllClients: this is a private inventory (see Net.luau's own note
-- on StoreState).
local function pushState(player: Player)
	local DataService = Loader.get("DataService") :: any

	local ownedPasses: { string } = {}
	local perPlayer = ownership[player]
	if perPlayer ~= nil then
		for _, entry in StoreCatalogue do
			local def = entry.def :: StoreItemDef
			if def.kind ~= "GamePass" or def.assetId <= 0 then
				continue
			end
			local cached = perPlayer[def.assetId]
			if cached ~= nil and cached.owned then
				table.insert(ownedPasses, def.key)
			end
		end
	end

	Net.fireClient("StoreState", player, {
		currency = DataService.getCurrency(player),
		powerUpStock = DataService.getPowerUpStock(player),
		loadout = DataService.getLoadout(player),
		ownedCosmetics = DataService.getOwnedCosmetics(player),
		equipped = DataService.getEquipped(player),
		ownedPasses = ownedPasses,
		loadoutSlots = GameConfig.store.loadoutSlots,
	})
end

-- P4-5's "clear error path for a failed purchase." `status` is for the
-- UI's logic, `message` is for its text - a store screen that can only
-- say "something went wrong" is what generates the tickets this task
-- exists to make answerable.
local function sendPurchaseResult(player: Player, key: string, status: string, message: string)
	Net.fireClient("StorePurchaseResult", player, {
		key = key,
		status = status,
		message = message,
	})
end

-- ===== grants =============================================================

-- Applies a product's grants to a profile's Data IN PLACE, and (for a
-- developer product) records the PurchaseId in the same mutation.
--
-- In place is required, not preferred: ProfileStore may hold its own
-- reference to the Data table, so replacing the table wholesale can
-- leave the library saving the old one. Same reason DataService's own
-- loadProfile copies migrated fields into the existing table rather
-- than swapping it.
--
-- Returns the human-readable change list, for the audit line.
local function applyProductTo(data: any, def: StoreItemDef, purchaseId: string?): { string }
	local before: StoreLogic.GrantState = {
		currency = data.currency,
		powerUpStock = data.powerUpStock,
		ownedCosmetics = data.ownedCosmetics,
		unlockedTitles = data.unlockedTitles,
	}

	local after, changes = StoreLogic.applyGrants(before, def.grants :: any)

	data.currency = after.currency
	data.powerUpStock = after.powerUpStock
	data.ownedCosmetics = after.ownedCosmetics
	data.unlockedTitles = after.unlockedTitles

	if purchaseId ~= nil then
		-- The line that makes the whole thing safe. Written next to the
		-- grant, before any save, so the DataStore gets both or neither.
		data.purchaseIdCache =
			StoreLogic.recordPurchaseId(data.purchaseIdCache, purchaseId, GameConfig.store.purchaseIdCacheSize)
	end

	return changes
end

local function recordGrant(player: Player, def: StoreItemDef, purchaseId: string?, changes: { string })
	print(StoreLogic.formatGrantAudit(player.Name, player.UserId, def.key, def.assetId, purchaseId, changes))

	table.insert(grantLog, {
		userId = player.UserId,
		productKey = def.key,
		purchaseId = purchaseId,
		changes = changes,
		at = os.time(),
	})
	while #grantLog > GRANT_LOG_LIMIT do
		table.remove(grantLog, 1)
	end
end

-- ===== receipts ===========================================================

-- Waits for a profile to finish loading, for a buyer who purchased
-- during their own join. Gives up when the player leaves or the budget
-- runs out - both of which mean "decline and let Roblox re-offer."
local function waitForHandle(player: Player): any?
	local getHandle = receiptHandleFor
	if getHandle == nil then
		return nil
	end

	local deadline = now() + GameConfig.store.receiptProfileWaitSeconds
	while now() < deadline do
		local handle = getHandle(player)
		if handle ~= nil then
			return handle
		end
		if player.Parent ~= Players then
			return nil
		end
		task.wait(0.25)
	end

	return getHandle(player)
end

-- Yields until the grant is confirmed in Profile.LastSavedData, or
-- until the session ends or the wait budget runs out.
--
-- Yielding inside ProcessReceipt is deliberate and is what the whole
-- guarantee rests on - Roblox waits for the returned decision rather
-- than timing it out, which is the behaviour ProfileStore's own
-- developer-product guidance is built on. If that ever stops being
-- true, the failure mode is a NotProcessedYet and a later re-offer, not
-- a lost grant: the PurchaseId is already in Data by this point.
--
-- The OnAfterSave subscription exists so this doesn't busy-wait a
-- save that ProfileStore performs on its own schedule. It's a
-- Connect-plus-disconnect rather than a :Wait(), because ProfileStore's
-- exported Signal type declares only :Connect - see DataService's
-- ReceiptHandle for that note.
local function waitForSave(handle: any, purchaseId: string): boolean
	local deadline = now() + GameConfig.store.receiptMaxWaitSeconds

	local saved = false
	local disconnect = handle.onAfterSave(function()
		if StoreLogic.isPurchaseSaved(handle.getLastSavedData() :: any, purchaseId) then
			saved = true
		end
	end)

	local function cleanup(): boolean
		disconnect()
		return saved
	end

	if StoreLogic.isPurchaseSaved(handle.getLastSavedData() :: any, purchaseId) then
		return cleanup()
	end

	handle.save()

	while now() < deadline do
		if saved or StoreLogic.isPurchaseSaved(handle.getLastSavedData() :: any, purchaseId) then
			saved = true
			return cleanup()
		end
		if not handle.isActive() then
			-- The session ended. Whether the final save carried the
			-- grant is genuinely unknown from here, so this declines -
			-- and the next session's receipt either finds the
			-- PurchaseId in the cache and confirms immediately, or
			-- doesn't and grants cleanly. Both outcomes are correct;
			-- guessing would not be.
			return cleanup()
		end
		task.wait(GameConfig.store.receiptSaveRetrySeconds)
		if handle.isActive() then
			handle.save()
		end
	end

	return cleanup()
end

-- MarketplaceService.ProcessReceipt. Assigned once, in init().
--
-- `receiptInfo` is Roblox's own table: PlayerId, ProductId, PurchaseId,
-- CurrencySpent, CurrencyType, PlaceIdWherePurchased. It is typed
-- `{[string]: any}` by the engine, so every field is read defensively -
-- this is the one callback in the game whose input shape comes from
-- outside the codebase entirely.
local function processReceipt(receiptInfo: { [string]: any }): Enum.ProductPurchaseDecision
	local granted = Enum.ProductPurchaseDecision.PurchaseGranted
	local notYet = Enum.ProductPurchaseDecision.NotProcessedYet

	local userId = receiptInfo.PlayerId :: number?
	local productId = receiptInfo.ProductId :: number?
	local purchaseId = receiptInfo.PurchaseId

	if userId == nil or productId == nil or purchaseId == nil then
		warn("StoreService: malformed receipt (userId/productId/purchaseId missing) - declining")
		return notYet
	end

	-- PurchaseId is documented as a string, but it is read through an
	-- `any` and it is the key this entire design hangs on - so it is
	-- normalised rather than assumed. tostring on a number id still
	-- yields a stable, comparable key.
	local purchaseKey = tostring(purchaseId)

	local player = Players:GetPlayerByUserId(userId)
	if player == nil then
		-- The buyer is not on this server (they left, or the purchase
		-- completed elsewhere). Nothing to write to; Roblox re-offers
		-- the receipt on their next session.
		return notYet
	end

	local handle = waitForHandle(player)
	if handle == nil then
		warn(
			string.format(
				"StoreService: no profile for %s (%d) after waiting %ds - declining receipt %s so Roblox re-offers it",
				player.Name,
				userId,
				GameConfig.store.receiptProfileWaitSeconds,
				purchaseKey
			)
		)
		return notYet
	end

	local data = handle.getData()
	if data == nil then
		return notYet
	end

	local def = byAssetId[productId]
	local decision = StoreLogic.classifyReceipt(data.purchaseIdCache, purchaseKey, handle.isActive(), def ~= nil)

	if decision == "AlreadyGranted" then
		print(
			string.format(
				"StoreService: receipt %s for %s (%d) already granted in an earlier session - confirming, granting nothing",
				purchaseKey,
				player.Name,
				userId
			)
		)
		return granted
	end

	if decision == "Decline" then
		if def == nil then
			-- Loud, because it is a config bug with a player's money on
			-- the other end of it. Declining keeps the receipt alive:
			-- add the missing Config/Store entry, restart, and the same
			-- receipt pays out.
			warn(
				string.format(
					"StoreService: receipt %s names productId %d, which no ENABLED store entry claims - declining so the purchase is not consumed. Add or enable the config entry and the receipt will be re-offered.",
					purchaseKey,
					productId
				)
			)
		else
			warn(
				string.format(
					"StoreService: profile for %s (%d) is not active - declining receipt %s",
					player.Name,
					userId,
					purchaseKey
				)
			)
		end
		return notYet
	end

	local product = def :: StoreItemDef
	local changes = applyProductTo(data, product, purchaseKey)

	if not waitForSave(handle, purchaseKey) then
		-- The grant is in Data but not confirmed on disk. Declining is
		-- correct: either the save lands later (and the re-offered
		-- receipt finds the PurchaseId and confirms), or it doesn't
		-- (and the re-offered receipt grants cleanly). What must never
		-- happen is confirming a purchase whose grant might evaporate.
		warn(
			string.format(
				"StoreService: grant for receipt %s (%s, %s) is applied but NOT yet confirmed saved - declining; Roblox will re-offer and the PurchaseId cache will resolve it either way",
				purchaseKey,
				player.Name,
				product.key
			)
		)
		return notYet
	end

	recordGrant(player, product, purchaseKey, changes)
	pushState(player)
	return granted
end

-- ===== game passes ========================================================

-- Live ownership, cached. The uncached path is a Roblox web call, so it
-- is wrapped in pcall and a failure returns the last cached answer if
-- there is one - a transient outage should not tell a player they no
-- longer own something they paid for.
--
-- API NOTE: UserOwnsGamePassAsync takes a USER ID, not a Player. Passing
-- a Player is a quiet type error that fails at runtime, and it is the
-- single easiest mistake to make here. Verified against the pinned
-- Roblox global type definitions for this task (see globalTypes.d.luau:
-- `UserOwnsGamePassAsync(self, userId: User | number, gamePassId:
-- number): boolean`).
local function ownsPass(player: Player, gamePassId: number): boolean
	if gamePassId <= 0 then
		return false
	end

	local perPlayer = ownership[player]
	if perPlayer == nil then
		perPlayer = {}
		ownership[player] = perPlayer
	end

	local cached = perPlayer[gamePassId]
	if
		cached ~= nil
		and StoreLogic.isOwnershipFresh(
			cached.checkedAt,
			cached.owned,
			now(),
			GameConfig.store.passCacheOwnedTtlSeconds,
			GameConfig.store.passCacheUnownedTtlSeconds
		)
	then
		return cached.owned
	end

	local ok, owned = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamePassId)
	end)

	if not ok then
		warn(
			string.format(
				"StoreService: UserOwnsGamePassAsync failed for %s (%d) pass %d: %s",
				player.Name,
				player.UserId,
				gamePassId,
				tostring(owned)
			)
		)
		-- Serve the stale answer rather than "no". A player who owns a
		-- pass and is told they don't will contact support; a player
		-- who briefly keeps a cosmetic they own is a non-event.
		return if cached ~= nil then cached.owned else false
	end

	perPlayer[gamePassId] = { owned = owned == true, checkedAt = now() }
	return owned == true
end

-- A pass is permanent, so its grants are re-applied on every join and
-- on every purchase. That is safe by construction rather than by
-- bookkeeping: a pass may only grant Cosmetic or Title
-- (Validate.checkStoreItem refuses anything else), and both of those
-- are set-insertions that do nothing the second time
-- (StoreLogic.applyGrants). There is no receipt and no PurchaseId
-- involved, because there is nothing to consume.
local function syncPasses(player: Player)
	local getHandle = receiptHandleFor
	if getHandle == nil then
		return
	end
	local handle = getHandle(player)
	if handle == nil then
		return
	end
	local data = handle.getData()
	if data == nil then
		return
	end

	local anyChange = false

	for _, entry in StoreCatalogue do
		local def = entry.def :: StoreItemDef
		if def.kind ~= "GamePass" or not def.enabled or def.assetId <= 0 then
			continue
		end
		if not ownsPass(player, def.assetId) then
			continue
		end

		local changes = applyProductTo(data, def, nil)
		local realChange = false
		for _, line in changes do
			if
				string.find(line, "already owned", 1, true) == nil
				and string.find(line, "already unlocked", 1, true) == nil
			then
				realChange = true
				break
			end
		end
		if realChange then
			recordGrant(player, def, nil, changes)
			anyChange = true
		end
	end

	if anyChange then
		handle.save()
	end
end

-- ===== the purchase prompt flow ===========================================

local function handlePurchaseIntent(player: Player, key: string)
	local def = byKey[key]
	if def == nil then
		sendPurchaseResult(player, key, "UnknownProduct", "That item is not in the store.")
		warn(string.format("StoreService: %s asked to buy unknown key %q", player.Name, key))
		return
	end

	-- Both halves matter and neither is redundant: `enabled` is the
	-- design switch, `assetId > 0` is whether the thing exists on
	-- Roblox at all. ConfigValidator refuses the combination
	-- "enabled with no id" at boot, so reaching this branch means the
	-- entry is deliberately off.
	if not def.enabled or def.assetId <= 0 then
		sendPurchaseResult(player, key, "Unavailable", "That item is not available right now.")
		return
	end

	if def.kind == "GamePass" and ownsPass(player, def.assetId) then
		sendPurchaseResult(player, key, "AlreadyOwned", "You already own this.")
		return
	end

	-- Everything past this point is Roblox's. The prompt is opened; the
	-- outcome arrives on PromptGamePassPurchaseFinished (a pass) or
	-- through ProcessReceipt (a developer product). Nothing here
	-- assumes a purchase happened.
	local ok, err = pcall(function()
		if def.kind == "GamePass" then
			MarketplaceService:PromptGamePassPurchase(player, def.assetId)
		else
			MarketplaceService:PromptProductPurchase(player, def.assetId)
		end
	end)

	if not ok then
		sendPurchaseResult(player, key, "PromptFailed", "Could not open the purchase window. Please try again.")
		warn(string.format("StoreService: prompt failed for %s / %s: %s", player.Name, key, tostring(err)))
		return
	end

	sendPurchaseResult(player, key, "Prompted", "")
end

-- ===== equip and loadout ==================================================

local function handleEquipIntent(player: Player, slot: string, itemId: string?)
	local DataService = Loader.get("DataService") :: any

	local owned = DataService.getOwnedCosmetics(player) :: { string }
	local allowed, reason = StoreLogic.canEquipCosmetic(owned, slot, itemId)
	if not allowed then
		warn(
			string.format(
				"StoreService: %s tried to equip %s into %q - %s",
				player.Name,
				tostring(itemId),
				slot,
				tostring(reason)
			)
		)
		return
	end

	-- P4-6: ownership alone isn't enough - this repo's StoreLogic
	-- predates the cosmetics registry and has no idea what a "Trail" is,
	-- so nothing above refuses a real, owned trail aimed at the "skin"
	-- slot. CosmeticService.canEquip is the category-aware gate, checked
	-- here, before anything is written - not just applied defensively at
	-- render time.
	local CosmeticService = Loader.get("CosmeticService") :: any
	local categoryAllowed, categoryReason = CosmeticService.canEquip(slot, itemId)
	if not categoryAllowed then
		warn(
			string.format(
				"StoreService: %s tried to equip %s into %q - %s",
				player.Name,
				tostring(itemId),
				slot,
				tostring(categoryReason)
			)
		)
		return
	end

	-- DataService re-checks ownership against the profile itself. Same
	-- defence-in-depth split TitleService uses: the checks above avoid a
	-- pointless write, this one is the enforcement.
	if not DataService.setEquippedCosmetic(player, slot, itemId) then
		return
	end

	pushState(player)
	CosmeticService.refreshFor(player)
end

local function handleLoadoutIntent(player: Player, slotIndex: number, powerUpId: string?)
	local DataService = Loader.get("DataService") :: any

	local loadout = DataService.getLoadout(player) :: { string }
	local stock = DataService.getPowerUpStock(player) :: { [string]: number }

	local updated, reason =
		StoreLogic.setLoadoutSlot(loadout, slotIndex, powerUpId, stock, loadoutEligible, GameConfig.store.loadoutSlots)

	if updated == nil then
		warn(
			string.format(
				"StoreService: %s tried to set loadout slot %s to %s - %s",
				player.Name,
				tostring(slotIndex),
				tostring(powerUpId),
				tostring(reason)
			)
		)
		return
	end

	-- Stock is unchanged by SELECTING an item - it is spent when a round
	-- actually consumes the loadout (consumeLoadoutFor), not when a
	-- player rearranges a menu. A player who picks an item and then
	-- changes their mind has spent nothing.
	DataService.setLoadoutAndStock(player, updated :: { string }, stock)
	pushState(player)
end

-- Spends the player's stored loadout and hands back what they take into
-- the round. THE ONLY PLACE STOCK IS DECREMENTED.
--
-- NOT WIRED TO ANYTHING YET, DELIBERATELY. See docs/store-receipts.md
-- §"The one seam left open": granting 3 loadout items into
-- PowerUpService's 1-slot field inventory is a design question nobody
-- has answered (powerups.md describes both, and never says how they
-- coexist), and P4-5 is not the task that should answer it. The
-- consumption rule itself is settled and tested here so that wiring it
-- up later is a call site, not a redesign.
local function consumeLoadoutFor(player: Player): { string }
	local DataService = Loader.get("DataService") :: any

	local loadout = DataService.getLoadout(player) :: { string }
	if #loadout == 0 then
		return {}
	end

	local stock = DataService.getPowerUpStock(player) :: { [string]: number }
	local granted, remaining = StoreLogic.consumeLoadout(loadout, stock, GameConfig.store.loadoutSlots)

	-- The loadout is cleared as it is spent: these were consumables, and
	-- leaving the selection in place would re-arm it silently from
	-- whatever stock is left next round.
	DataService.setLoadoutAndStock(player, {}, remaining)

	print(
		string.format(
			"Store: LOADOUT %s (%d) spent [%s]",
			player.Name,
			player.UserId,
			if #granted > 0 then table.concat(granted, ", ") else "nothing"
		)
	)

	pushState(player)
	return granted
end

-- ===== service ============================================================

-- ===== the Studio test seam ===============================================

-- Feeds a synthesised receipt straight into processReceipt, exactly as
-- Roblox would. This is how docs/store-receipts.md's test plan
-- reproduces a replay, a decline and a mid-purchase leave on demand -
-- none of which can be triggered reliably by buying things in Studio,
-- because a real purchase gives you no control over the PurchaseId and
-- no way to ask for the same one twice.
--
-- THERE IS NO REMOTE FOR THIS, deliberately, and there never should be.
-- It grants items. It is a server-side function reachable only from the
-- Studio command bar or a server script - a client has no path to it at
-- all (compare RoundService's DebugForceRoundState, which IS a remote
-- because forcing a round state hands out nothing).
--
-- The Studio guard is belt-and-braces on top of that: even reached from
-- a server script in production, it refuses.
local function debugSimulateReceipt(userId: number, productId: number, purchaseId: string): string
	if not RunService:IsStudio() then
		warn("StoreService.debugSimulateReceipt: refused - Studio only")
		return "Refused"
	end

	local decision = processReceipt({
		PlayerId = userId,
		ProductId = productId,
		PurchaseId = purchaseId,
		CurrencySpent = 0,
		CurrencyType = Enum.CurrencyType.Robux,
		PlaceIdWherePurchased = game.PlaceId,
	})

	local name = if decision == Enum.ProductPurchaseDecision.PurchaseGranted
		then "PurchaseGranted"
		else "NotProcessedYet"
	print(
		string.format(
			"StoreService.debugSimulateReceipt: userId=%d productId=%d purchaseId=%s -> %s",
			userId,
			productId,
			purchaseId,
			name
		)
	)
	return name
end

local StoreService: Loader.Service = {
	name = "StoreService",
	dependencies = { "NetGuard", "ConfigValidator", "DataService", "CosmeticService" },

	ownsPass = ownsPass,
	consumeLoadoutFor = consumeLoadoutFor,

	-- Studio only, and no remote reaches it - see its own comment.
	debugSimulateReceipt = debugSimulateReceipt,
	pushState = pushState,

	-- Read-only, for a support tool or a test - never mutated by a
	-- caller, since this hands back the live list by design (it is a
	-- debugging surface, not game state).
	getGrantLog = function(): { GrantRecord }
		return grantLog
	end,
}

function StoreService:init()
	local NetGuard = Loader.get("NetGuard") :: any
	local DataService = Loader.get("DataService") :: any

	receiptHandleFor = DataService.claimReceiptAccess("StoreService")

	NetGuard.on("StorePurchaseIntent", function(player: Player, payload: any)
		handlePurchaseIntent(player, payload.key)
	end)

	NetGuard.on("StoreEquipIntent", function(player: Player, payload: any)
		handleEquipIntent(player, payload.slot, payload.itemId)
	end)

	NetGuard.on("StoreLoadoutIntent", function(player: Player, payload: any)
		handleLoadoutIntent(player, payload.slotIndex, payload.powerUpId)
	end)

	-- "This can only be done once by one server-side script" (Roblox's
	-- own wording). DataService.claimReceiptAccess above is what makes
	-- that structurally true in this codebase rather than a convention:
	-- a second service trying to build a receipt handler errors at boot
	-- before it ever reaches this line.
	MarketplaceService.ProcessReceipt = processReceipt

	-- A pass bought mid-session. The ownership cache is invalidated
	-- immediately rather than waiting out its TTL, because this is the
	-- exact moment a player is watching the store screen.
	--
	-- API NOTE: this signal hands back a Player. Its developer-product
	-- counterpart, PromptProductPurchaseFinished, hands back a USER ID
	-- instead - the two disagree, which is a well-known trap. It is not
	-- connected here at all: a product purchase is confirmed by
	-- ProcessReceipt, and treating a prompt-finished signal as proof of
	-- purchase is precisely the bug this task exists to avoid.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, gamePassId: number, wasPurchased: boolean)
			local perPlayer = ownership[player]
			if perPlayer ~= nil then
				perPlayer[gamePassId] = nil
			end
			if not wasPurchased then
				return
			end
			task.spawn(function()
				syncPasses(player)
				pushState(player)
			end)
		end
	)

	Players.PlayerRemoving:Connect(function(player: Player)
		ownership[player] = nil
	end)
end

function StoreService:start()
	-- On profile LOAD, not PlayerAdded: pushing on join raced the load
	-- and sent empty defaults, and nothing re-pushed until some unrelated
	-- write happened to (P6-6's store screen found it). onLoaded runs
	-- already-loaded players immediately, so no separate catch-up loop.
	local DataService = Loader.get("DataService") :: any
	DataService.onLoaded(function(player: Player)
		syncPasses(player)
		pushState(player)
	end)
end

return StoreService
