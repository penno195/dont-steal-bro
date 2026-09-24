--!strict
-- The store's pure logic (P4-5): receipt classification, the PurchaseId
-- replay cache, grant application, the loadout cap, and the game-pass
-- ownership cache's freshness rule. StoreService.luau is the thin
-- Roblox-touching wrapper that owns the real MarketplaceService, the
-- real profile and the real clock.
--
-- Self-contained on purpose - no requires of sibling files, no Roblox
-- API calls anywhere - so it stays requirable under Lune for headless
-- tests (tests/StoreLogic.spec.luau), the same shape ProfileLogic,
-- ProgressionLogic and LeaderboardLogic take, and for the same reason
-- (Ground Rule 4).
--
-- ===== WHY THE RECEIPT RULES ARE IN HERE AND NOT IN THE SERVICE ========
--
-- P4-5's own framing: "a receipt bug either robs players or grants free
-- items - both are unrecoverable trust damage." The failure modes that
-- matter are all orderings - a receipt arriving twice, arriving before
-- the profile loaded, arriving after the buyer left, arriving again
-- after a crash that ate the save. None of those are reproducible on
-- demand against a live MarketplaceService, and a bug in any of them is
-- discovered by a player who was charged, not by a test. So every
-- decision is a pure function of explicit inputs here, where all four
-- orderings are three lines of test each.
--
-- What is NOT in here, deliberately: anything that decides WHEN to
-- return PurchaseGranted. That depends on an actual confirmed DataStore
-- write and belongs next to the thing that can observe one - see
-- StoreService.processReceipt. This module says what a receipt means;
-- the service says whether the write landed.

local StoreLogic = {}

-- ===== types ==============================================================

-- Structurally identical to Validate.StoreGrant, duplicated rather than
-- required for the same reason ProfileLogic duplicates BountyTier:
-- requiring Config/Validate means an Instance-path require this module
-- can't resolve under Lune. Luau's structural typing means a real
-- `Validate.StoreGrant` value satisfies these with no cast at the call
-- site, so the duplication costs nothing.
export type GrantKind = "Currency" | "PowerUpStock" | "Cosmetic" | "Title"

export type Grant = {
	kind: GrantKind,
	amount: number?,
	powerUpId: string?,
	cosmeticId: string?,
	titleId: string?,
}

-- The slice of a profile a grant can touch. Passed in and returned as a
-- fresh value rather than mutated, so a caller can log both sides of a
-- purchase - which is most of what makes a support ticket answerable.
export type GrantState = {
	currency: number,
	powerUpStock: { [string]: number },
	ownedCosmetics: { string },
	unlockedTitles: { string },
}

-- ===== receipts ===========================================================

-- What a receipt means, before anything is written.
--
--   "Grant"          - new purchase, apply it.
--   "AlreadyGranted" - this PurchaseId is in the profile's cache, so
--                      the grant already happened AND was already
--                      saved. Confirm it; grant nothing.
--   "Decline"        - not in a position to handle it right now. The
--                      caller returns NotProcessedYet and Roblox
--                      re-offers the receipt later.
--
-- `profileActive` is ProfileStore's own Profile:IsActive() - false once
-- the buyer's session has ended, at which point writing to Profile.Data
-- is not guaranteed to save and so must not be treated as a grant.
--
-- `productKnown` is whether the ProductId maps to an enabled entry in
-- the store catalogue. An unknown product is ALWAYS declined and never
-- confirmed: confirming would consume a real purchase and hand over
-- nothing, which is the "robs players" half of P4-5's framing. Declining
-- means Roblox keeps re-offering it, so shipping the missing config
-- later still pays the player out - the receipt is still waiting.
export type ReceiptDecision = "Grant" | "AlreadyGranted" | "Decline"

function StoreLogic.classifyReceipt(
	purchaseIdCache: { string }?,
	purchaseId: string,
	profileActive: boolean,
	productKnown: boolean
): ReceiptDecision
	-- Order matters. The cache is checked BEFORE `productKnown` so a
	-- product removed from the catalogue after somebody bought it still
	-- confirms, rather than looping forever on a receipt that can never
	-- be satisfied. It is checked before `profileActive` for the same
	-- reason a replay is safe at all: the id being in the cache is
	-- evidence the grant already happened, and no write is needed to say
	-- so.
	if purchaseIdCache ~= nil and table.find(purchaseIdCache, purchaseId) ~= nil then
		return "AlreadyGranted"
	end
	if not profileActive then
		return "Decline"
	end
	if not productKnown then
		return "Decline"
	end
	return "Grant"
end

-- Appends `purchaseId` to a copy of the cache, trimming oldest-first to
-- `maxSize`. Returns a NEW list; never mutates the one passed in.
--
-- Trimming from the front is what bounds the profile's size, and it is
-- also the one real limit in this design: a receipt older than the
-- oldest id still held would be granted a second time if Roblox
-- re-offered it. GameConfig.store.purchaseIdCacheSize is sized so that
-- can't happen in practice (100 purchases between two sessions), and
-- Validate.checkStoreConfig refuses a cache small enough to make it
-- plausible.
function StoreLogic.recordPurchaseId(purchaseIdCache: { string }?, purchaseId: string, maxSize: number): { string }
	local updated: { string } = if purchaseIdCache ~= nil then table.clone(purchaseIdCache) else {}

	if table.find(updated, purchaseId) ~= nil then
		return updated -- already recorded; recording it twice would evict a real id for nothing
	end

	table.insert(updated, purchaseId)

	while #updated > math.max(1, maxSize) do
		table.remove(updated, 1)
	end

	return updated
end

-- Is this purchase visible in a snapshot of what was actually SAVED?
--
-- This is the whole basis for returning PurchaseGranted. `savedCache` is
-- ProfileStore's Profile.LastSavedData.purchaseIdCache - the cache as
-- the DataStore has it, not as this server's memory has it. Until the
-- id appears there, the grant exists only in RAM, and a crash would
-- lose it while Roblox considered the player charged.
--
-- A nil `savedCache` is "not saved yet", never "saved and empty": a
-- profile whose first save hasn't landed has no LastSavedData worth
-- trusting.
function StoreLogic.isPurchaseSaved(savedCache: { string }?, purchaseId: string): boolean
	if savedCache == nil then
		return false
	end
	return table.find(savedCache, purchaseId) ~= nil
end

-- Pulls `purchaseIdCache` out of a whole LastSavedData snapshot, for
-- isPurchaseSaved above. Exists because the caller once passed the whole
-- snapshot straight in (P8-1): a `:: any` cast hid the type mismatch,
-- `table.find` over a dictionary always misses, and so NO receipt was
-- ever seen as saved. Anything that isn't a table is "not saved yet",
-- same as isPurchaseSaved's own nil.
function StoreLogic.savedPurchaseIds(lastSavedData: any): { string }?
	if type(lastSavedData) ~= "table" then
		return nil
	end
	local cache = lastSavedData.purchaseIdCache
	if type(cache) ~= "table" then
		return nil
	end
	return cache
end

-- What to answer Roblox for a receipt classifyReceipt called
-- "AlreadyGranted" (P8-1). The in-memory cache proves the grant was
-- APPLIED, not that it was SAVED: a first attempt that applied the
-- grant but timed out waiting for the save returns NotProcessedYet, and
-- the retry then finds the id in memory. Confirming at that point would
-- tell Roblox the player has their item while it still exists only in
-- RAM. So: confirm if the save has landed; otherwise wait for one if the
-- profile can still save; otherwise decline and let Roblox re-offer.
export type ReplayAnswer = "Confirm" | "WaitForSave" | "Decline"

function StoreLogic.answerReplay(savedCache: { string }?, purchaseId: string, profileActive: boolean): ReplayAnswer
	if StoreLogic.isPurchaseSaved(savedCache, purchaseId) then
		return "Confirm"
	end
	if profileActive then
		return "WaitForSave"
	end
	return "Decline"
end

-- ===== grants =============================================================

-- Applies every grant in `grants` to a copy of `state`, returning the
-- new state and one human-readable line per grant.
--
-- Pure and total: an unrecognised grant kind, a missing amount or a
-- missing id is skipped with a line saying so rather than erroring.
-- That is deliberate, and it is the "never rob a player" rule in code
-- form - a malformed grant in one product must not abort a purchase
-- that also contained three good ones. ConfigValidator is what stops a
-- malformed grant reaching here at all; this is the behaviour if one
-- somehow does.
function StoreLogic.applyGrants(state: GrantState, grants: { Grant }): (GrantState, { string })
	local updated: GrantState = {
		currency = state.currency,
		powerUpStock = table.clone(state.powerUpStock),
		ownedCosmetics = table.clone(state.ownedCosmetics),
		unlockedTitles = table.clone(state.unlockedTitles),
	}
	local lines: { string } = {}

	for _, grant in grants do
		if grant.kind == "Currency" then
			local amount = grant.amount
			if amount == nil or amount <= 0 then
				table.insert(lines, "SKIPPED Currency grant with no positive amount")
				continue
			end
			updated.currency += amount
			table.insert(lines, string.format("currency +%d (now %d)", amount, updated.currency))
		elseif grant.kind == "PowerUpStock" then
			local powerUpId = grant.powerUpId
			local amount = grant.amount
			if powerUpId == nil or amount == nil or amount <= 0 then
				table.insert(lines, "SKIPPED PowerUpStock grant with no powerUpId or no positive amount")
				continue
			end
			local held = updated.powerUpStock[powerUpId] or 0
			updated.powerUpStock[powerUpId] = held + amount
			table.insert(lines, string.format("stock %s +%d (now %d)", powerUpId, amount, held + amount))
		elseif grant.kind == "Cosmetic" then
			local cosmeticId = grant.cosmeticId
			if cosmeticId == nil then
				table.insert(lines, "SKIPPED Cosmetic grant with no cosmeticId")
				continue
			end
			-- A set, not a list, in behaviour: owning something twice is
			-- not a thing. This is what makes a game pass's grants safe
			-- to re-apply on every join, which is how a pass stays
			-- permanent without needing a receipt of its own.
			if table.find(updated.ownedCosmetics, cosmeticId) ~= nil then
				table.insert(lines, string.format("cosmetic %s already owned (no change)", cosmeticId))
			else
				table.insert(updated.ownedCosmetics, cosmeticId)
				table.insert(lines, string.format("cosmetic %s granted", cosmeticId))
			end
		elseif grant.kind == "Title" then
			local titleId = grant.titleId
			if titleId == nil then
				table.insert(lines, "SKIPPED Title grant with no titleId")
				continue
			end
			if table.find(updated.unlockedTitles, titleId) ~= nil then
				table.insert(lines, string.format("title %s already unlocked (no change)", titleId))
			else
				table.insert(updated.unlockedTitles, titleId)
				table.insert(lines, string.format("title %s unlocked", titleId))
			end
		else
			table.insert(lines, string.format("SKIPPED unrecognised grant kind %q", tostring(grant.kind)))
		end
	end

	return updated, lines
end

-- ===== the loadout ========================================================

-- design-decisions.md Q8: "Loadouts are capped at 3 items regardless of
-- spend." Three things have to hold for a slot assignment to be legal,
-- and all three are checked server-side because a client asking is
-- never evidence of anything (Ground Rule 1):
--
--   1. The slot index is within the cap.
--   2. The power-up is loadout-eligible at all.
--   3. The player actually holds enough stock to fill that many slots
--      with it.
--
-- Returns the new loadout, or nil plus a reason. `powerUpId = nil`
-- clears the slot, which is always legal.
--
-- WHY A LOADOUT MAY REPEAT AN ITEM (and why that isn't a cap bypass):
-- three Sprint Boosts is three uses of a Common that also spawns free
-- on every map, drawn from stock the player owns either way. What the
-- cap protects is how much anyone carries into one race, and three is
-- three whether or not they are the same item.
function StoreLogic.setLoadoutSlot(
	loadout: { string },
	slotIndex: number,
	powerUpId: string?,
	stock: { [string]: number },
	loadoutEligible: { [string]: boolean },
	slots: number
): ({ string }?, string?)
	if slotIndex % 1 ~= 0 or slotIndex < 1 or slotIndex > slots then
		return nil, string.format("slot %s is outside 1..%d", tostring(slotIndex), slots)
	end

	local updated: { string } = table.clone(loadout)

	-- Normalise first: a stored loadout longer than the cap (a config
	-- change lowering `slots`, or a profile written under an older one)
	-- is trimmed rather than trusted, so the cap is enforced on read as
	-- well as on write.
	while #updated > slots do
		table.remove(updated)
	end

	if powerUpId == nil then
		if slotIndex <= #updated then
			table.remove(updated, slotIndex)
		end
		return updated, nil
	end

	if not loadoutEligible[powerUpId] then
		return nil, string.format("%q is not loadout-eligible", powerUpId)
	end

	local held = stock[powerUpId] or 0
	if held <= 0 then
		return nil, string.format("no stock of %q", powerUpId)
	end

	-- Holding 2 of an item caps how many slots it can fill at 2: a slot
	-- is a copy that will be spent, so three slots of an item the player
	-- owns two of would spend one they never had.
	local alreadyPlaced = 0
	for index, id in updated do
		if id == powerUpId and index ~= slotIndex then
			alreadyPlaced += 1
		end
	end
	if alreadyPlaced >= held then
		return nil,
			string.format("only %d of %q in stock, and %d already in the loadout", held, powerUpId, alreadyPlaced)
	end

	if slotIndex <= #updated then
		updated[slotIndex] = powerUpId
	else
		-- Assigning slot 3 while holding 1 item appends rather than
		-- leaving a hole: the loadout is a list of what you're taking,
		-- not a sparse array of positions, and a hole would make
		-- `#updated` lie about the count the cap is enforced against.
		table.insert(updated, powerUpId)
	end

	return updated, nil
end

-- What a round should actually consume, given a stored loadout and the
-- stock behind it. Returns the items granted and the stock left after.
--
-- Re-validated against stock rather than trusted, because the loadout
-- was stored at selection time and the stock may have moved since (a
-- previous round spent it, a migration, a refund). An entry with no
-- stock left is dropped rather than granted on credit.
function StoreLogic.consumeLoadout(
	loadout: { string },
	stock: { [string]: number },
	slots: number
): ({ string }, { [string]: number })
	local granted: { string } = {}
	local remaining = table.clone(stock)

	for index, powerUpId in loadout do
		if index > slots then
			break
		end
		local held = remaining[powerUpId] or 0
		if held <= 0 then
			continue
		end
		if held == 1 then
			remaining[powerUpId] = nil -- don't accumulate zero entries in a persisted table
		else
			remaining[powerUpId] = held - 1
		end
		table.insert(granted, powerUpId)
	end

	return granted, remaining
end

-- ===== the game-pass ownership cache ======================================

-- Is a cached ownership answer still worth believing?
--
-- The TTL depends on the ANSWER, not just its age: "owns it" is
-- effectively permanent and cheap to keep, while "doesn't own it"
-- becomes false the instant they buy - and the player who just bought is
-- the one staring at the store screen waiting for it to update. See
-- GameConfig.store's own note.
--
-- A nil `checkedAt` is a cache miss, never a fresh answer.
function StoreLogic.isOwnershipFresh(
	checkedAt: number?,
	owned: boolean,
	now: number,
	ownedTtlSeconds: number,
	unownedTtlSeconds: number
): boolean
	if checkedAt == nil then
		return false
	end
	local ttl = if owned then ownedTtlSeconds else unownedTtlSeconds
	return (now - checkedAt) < ttl
end

-- ===== equip state ========================================================

-- May this player equip `itemId` into `slot`? Ownership is the only
-- question this answers, and it answers it against the profile's own
-- owned list - never against anything the client said.
--
-- `itemId = nil` unequips, which is always allowed: putting something
-- away is not a claim to own anything.
function StoreLogic.canEquipCosmetic(ownedCosmetics: { string }, slot: string, itemId: string?): (boolean, string?)
	if slot == "" then
		return false, "empty slot name"
	end
	if itemId == nil then
		return true, nil
	end
	if table.find(ownedCosmetics, itemId) == nil then
		return false, string.format("%q is not owned", itemId)
	end
	return true, nil
end

-- ===== the support-ticket log line ========================================

-- P4-5: "structured logging of every grant with enough detail to answer
-- a support ticket." The question a ticket actually asks is "I paid for
-- X and didn't get it" - so one line has to carry: who, what they
-- bought, Roblox's own two identifiers for the transaction (the ones a
-- player can quote from their purchase history and the ones Roblox
-- support can match against), and exactly what changed.
--
-- `purchaseId` is logged in full rather than truncated. It is the only
-- thing that distinguishes two identical purchases by the same player,
-- which is precisely the case a duplicate-grant complaint is about.
function StoreLogic.formatGrantAudit(
	playerName: string,
	userId: number,
	productKey: string,
	assetId: number,
	purchaseId: string?,
	changes: { string }
): string
	return string.format(
		"Store: GRANT %s (%d) product=%s assetId=%d purchaseId=%s -> %s",
		playerName,
		userId,
		productKey,
		assetId,
		purchaseId or "n/a",
		if #changes > 0 then table.concat(changes, "; ") else "(nothing changed)"
	)
end

return StoreLogic
