--!strict
-- The pure half of the store screen (P6-6): which tab an item sits in,
-- how rare it reads, what state its button is in, and the purchase flow
-- as a reducer. No Roblox API, no requires - catalogue and registry
-- lookups are passed in - so it runs under Lune (tests/MenuScreens.spec).
--
-- Nothing here decides what anyone owns. Ownership comes only from
-- StoreState, which the server builds from the profile after Roblox has
-- confirmed a purchase. The flow below is a DISPLAY of a purchase in
-- progress, and every state it can reach is safe to be wrong about:
-- the worst case is a screen that says "pending" for a purchase that
-- already landed, which the next StoreState corrects.

local StoreScreenLogic = {}

-- ===== catalogue shape ======================================================

-- Structural copies of Validate.StoreGrant / StoreItemDef's fields this
-- module reads, so a real config value satisfies them without a require.
export type Grant = {
	kind: string,
	amount: number?,
	powerUpId: string?,
	cosmeticId: string?,
	titleId: string?,
}

export type Item = {
	key: string,
	kind: string, -- "GamePass" | "DeveloperProduct"
	enabled: boolean,
	displayName: string,
	robuxPrice: number,
	sortOrder: number,
	grants: { Grant },
}

-- The StoreState payload (StoreService.pushState), as the client gets it.
export type StoreState = {
	currency: number,
	powerUpStock: { [string]: number },
	loadout: { string },
	ownedCosmetics: { string },
	equipped: { [string]: string },
	ownedPasses: { string },
	loadoutSlots: number,
}

export type Category = "Passes" | "Bundles" | "PowerUps" | "Cosmetics" | "Currency"

-- Tab order, left to right. Passes first: a permanent purchase is the
-- one a player most wants to find, and the one least worth burying.
StoreScreenLogic.CATEGORIES = table.freeze({ "Passes", "Bundles", "PowerUps", "Cosmetics", "Currency" } :: { Category })

local KIND_CATEGORY: { [string]: Category } = {
	PowerUpStock = "PowerUps",
	Cosmetic = "Cosmetics",
	Currency = "Currency",
	Title = "Cosmetics",
}

-- Derived from what the item GRANTS rather than a new config field, so
-- adding a product stays one file (Ground Rule 2) and a product can't be
-- filed under a tab that disagrees with its contents. A game pass is
-- always Passes; anything granting two different kinds is a bundle.
function StoreScreenLogic.categoryOf(item: Item): Category
	if item.kind == "GamePass" then
		return "Passes"
	end
	local found: Category? = nil
	for _, grant in item.grants do
		local c = KIND_CATEGORY[grant.kind] or "Bundles"
		if found ~= nil and found ~= c then
			return "Bundles"
		end
		found = c
	end
	return found or "Bundles"
end

-- ===== rarity ===============================================================

export type Rarity = "Common" | "Uncommon" | "Rare"

local RARITY_RANK: { [string]: number } = { Common = 1, Uncommon = 2, Rare = 3 }

-- An item reads as the rarest thing it contains. `rarityOf` maps a
-- grant to the rarity its own registry gives it (a cosmetic's or a
-- power-up's), nil for things with none (currency). nil overall means
-- "no rarity treatment" - currency packs aren't Common, they're just
-- currency, and dressing them as Common would dilute the colour for
-- the items where rarity means something.
function StoreScreenLogic.rarityOf(item: Item, rarityOf: (Grant) -> string?): Rarity?
	local best: string? = nil
	for _, grant in item.grants do
		local r = rarityOf(grant)
		if r ~= nil and RARITY_RANK[r] ~= nil and (best == nil or RARITY_RANK[r] > RARITY_RANK[best]) then
			best = r
		end
	end
	return best :: Rarity?
end

-- ===== per-item state =======================================================

export type ItemState =
	"Unavailable" -- disabled in config (no Roblox id yet): shown, never buyable
	| "Buyable"
	| "Owned" -- a pass already owned: nothing to buy again
	| "Equipped" -- owned, and something it grants is being worn

local function cosmeticIds(item: Item): { string }
	local out = {}
	for _, grant in item.grants do
		if grant.kind == "Cosmetic" and grant.cosmeticId ~= nil then
			table.insert(out, grant.cosmeticId)
		end
	end
	return out
end

local function isEquipped(state: StoreState, cosmeticId: string): boolean
	for _, worn in state.equipped do
		if worn == cosmeticId then
			return true
		end
	end
	return false
end

-- A developer product is never "Owned": it's a consumable, and buying a
-- second currency pack is the point. Only passes can be owned outright.
-- `state` nil means StoreState hasn't arrived - the screen is loading,
-- and no item gets a Buy button it might have to take back.
function StoreScreenLogic.itemState(item: Item, state: StoreState?): ItemState?
	if state == nil then
		return nil
	end
	if not item.enabled then
		return "Unavailable"
	end
	if item.kind ~= "GamePass" or table.find(state.ownedPasses, item.key) == nil then
		return "Buyable"
	end
	for _, id in cosmeticIds(item) do
		if isEquipped(state, id) then
			return "Equipped"
		end
	end
	return "Owned"
end

-- The cosmetics an item grants, each with whether the player owns it
-- and is wearing it - the preview panel's equip toggles.
export type EquipTarget = { cosmeticId: string, owned: boolean, equipped: boolean }

function StoreScreenLogic.equipTargets(item: Item, state: StoreState): { EquipTarget }
	local out = {}
	for _, id in cosmeticIds(item) do
		table.insert(out, {
			cosmeticId = id,
			owned = table.find(state.ownedCosmetics, id) ~= nil,
			equipped = isEquipped(state, id),
		})
	end
	return out
end

-- One tab's items, sorted by config sortOrder then key (so two items
-- with the same order still land in a stable place across refreshes).
function StoreScreenLogic.itemsIn(items: { Item }, category: Category): { Item }
	local out = {}
	for _, item in items do
		if StoreScreenLogic.categoryOf(item) == category then
			table.insert(out, item)
		end
	end
	table.sort(out, function(a, b)
		if a.sortOrder ~= b.sortOrder then
			return a.sortOrder < b.sortOrder
		end
		return a.key < b.key
	end)
	return out
end

-- ===== the purchase flow ====================================================
--
--   Idle -tap-> Requesting -"Prompted"-> Prompted -closed, bought-> Processing
--                  |                        |                        |
--                  |                        +-closed, not bought-> Idle (a cancel says nothing)
--                  +-failure status, or no answer in REQUEST_TIMEOUT-> Failed
--                                                                    +-no grant in GRANT_WAIT-> Delayed
--   Prompted or Processing -StoreState shows it-> Succeeded
--
-- Prompted has no timeout of its own: a player reading the Roblox
-- prompt for a minute is making up their mind, not stuck. The grant
-- clock starts only once Roblox says money changed hands.
--
-- One purchase at a time: a tap while Requesting/Prompted/Processing is
-- ignored, so a double tap can't open two prompts.

export type FlowPhase = "Idle" | "Requesting" | "Prompted" | "Processing" | "Succeeded" | "Failed" | "Delayed"

export type Flow = {
	phase: FlowPhase,
	key: string?,
	since: number, -- when this phase began (os.clock-style seconds)
	message: string?, -- Failed only: text to show verbatim
	baseline: StoreState?, -- the state when the purchase began, to detect it landing
}

export type FlowEvent =
	{ type: "Tap", key: string, state: StoreState? }
	| { type: "Result", key: string, status: string, message: string }
	| { type: "State", state: StoreState }
	| { type: "PromptClosed", key: string, purchased: boolean }
	| { type: "Tick" }
	| { type: "Dismiss" }

-- How long to wait for StoreService's answer to the intent before
-- saying so. The answer is one server round trip; 8s covers a bad
-- mobile connection without leaving a spinner up forever.
StoreScreenLogic.REQUEST_TIMEOUT = 8

-- After the prompt closes with a purchase, how long to wait for the
-- grant to show up in StoreState before telling the player it's still
-- processing. Not a failure: ProcessReceipt can legitimately take a
-- while, and a receipt Roblox holds is paid for regardless.
StoreScreenLogic.GRANT_WAIT = 20

-- The server's own status strings (StoreService.sendPurchaseResult)
-- mapped to what the player reads if the server's message is empty.
local FALLBACK_MESSAGES: { [string]: string } = {
	UnknownProduct = "That item isn't in the store.",
	Unavailable = "That item isn't available right now.",
	AlreadyOwned = "You already own this.",
	PromptFailed = "Couldn't open the purchase window. Please try again.",
}

function StoreScreenLogic.idle(): Flow
	return { phase = "Idle", key = nil, since = 0, message = nil, baseline = nil }
end

-- Did the purchase of `key` land between `before` and `after`? A pass
-- lands when it appears in ownedPasses. A consumable has no ownership
-- flag, so it lands when ANY of the things a product can grant grew.
-- This can misattribute a coincidental change (a title unlock arriving
-- mid-purchase) - acceptable, because it only moves a spinner to "done"
-- a few seconds early, and never touches what is actually owned.
local function landed(key: string, before: StoreState?, after: StoreState): boolean
	if table.find(after.ownedPasses, key) ~= nil then
		return before == nil or table.find(before.ownedPasses, key) == nil
	end
	if before == nil then
		return false
	end
	if after.currency > before.currency or #after.ownedCosmetics > #before.ownedCosmetics then
		return true
	end
	for id, count in after.powerUpStock do
		if count > (before.powerUpStock[id] or 0) then
			return true
		end
	end
	return false
end

function StoreScreenLogic.step(flow: Flow, event: FlowEvent, now: number): Flow
	local e = event :: any
	local busy = flow.phase == "Requesting" or flow.phase == "Prompted" or flow.phase == "Processing"

	if e.type == "Tap" then
		if busy then
			return flow
		end
		return { phase = "Requesting", key = e.key, since = now, message = nil, baseline = e.state }
	elseif e.type == "Dismiss" then
		if busy then
			return flow -- a prompt is open; closing the banner doesn't cancel it
		end
		return StoreScreenLogic.idle()
	elseif e.type == "Result" then
		if flow.phase ~= "Requesting" or e.key ~= flow.key then
			return flow -- a late answer to something we've moved past
		end
		if e.status == "Prompted" then
			return { phase = "Prompted", key = flow.key, since = now, message = nil, baseline = flow.baseline }
		end
		local text = if e.message ~= ""
			then e.message
			else (FALLBACK_MESSAGES[e.status] or "Something went wrong. Please try again.")
		return { phase = "Failed", key = flow.key, since = now, message = text, baseline = nil }
	elseif e.type == "PromptClosed" then
		if flow.phase ~= "Prompted" or e.key ~= flow.key then
			return flow
		end
		if not e.purchased then
			return StoreScreenLogic.idle() -- a cancel isn't an error; say nothing
		end
		return { phase = "Processing", key = flow.key, since = now, message = nil, baseline = flow.baseline }
	elseif e.type == "State" then
		local waiting = flow.phase == "Prompted" or flow.phase == "Processing" or flow.phase == "Delayed"
		if waiting and flow.key ~= nil and landed(flow.key, flow.baseline, e.state) then
			return { phase = "Succeeded", key = flow.key, since = now, message = nil, baseline = nil }
		end
		return flow
	elseif e.type == "Tick" then
		if flow.phase == "Requesting" and now - flow.since >= StoreScreenLogic.REQUEST_TIMEOUT then
			return {
				phase = "Failed",
				key = flow.key,
				since = now,
				message = "The store didn't answer. Check your connection and try again.",
				baseline = nil,
			}
		end
		if flow.phase == "Processing" and now - flow.since >= StoreScreenLogic.GRANT_WAIT then
			-- Delayed, not Failed: money HAS changed hands. Say so, and
			-- that it will arrive, which is true - Roblox re-offers an
			-- unacknowledged receipt, and the grant is idempotent. The
			-- baseline is kept, so a grant that lands later still flips
			-- this to Succeeded.
			return {
				phase = "Delayed",
				key = flow.key,
				since = now,
				message = "Still processing. You were charged, and your item will arrive - you don't need to buy it again.",
				baseline = flow.baseline,
			}
		end
		return flow
	end
	return flow
end

return StoreScreenLogic
