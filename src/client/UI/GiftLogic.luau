--!strict
-- The staff gift pop-up's rules (staff-tools.md step 3; design-
-- decisions.md "Applied case: staff tools"), kept free of Roblox calls
-- so they're tested headlessly (tests/GiftLogic.spec.luau).
-- MenuController draws what this decides, with ClaimPopup.
--
-- The gifts are already in the profile; the pop-up only says so. Only
-- the Hub sends GiftReceived (owner, 2026-10-12), with every gift the
-- player hasn't seen yet, so one given mid-match or before the game
-- was closed shows on the next Hub visit. The list can arrive again
-- before the client's GiftsSeenIntent lands, so `fresh` drops the ids
-- already shown. A Hub practice round (MenuController's IN_PLAY) still
-- holds the pop-up until it's over.
--
-- Names and items only, never a streak (Q7 condition 1).

local GiftLogic = {}

-- One entry of GiftReceived.gifts, as StaffService sends it (the
-- profile's unseenGifts). `kind` is one of StaffGrantLogic.GIFT_KINDS.
export type Gift = {
	id: string,
	from: string,
	kind: string,
	amount: number?,
	cosmeticId: string?,
}

local KINDS: { [string]: boolean } = {
	Currency = true,
	Cosmetic = true,
	NavigationRound = true,
	UnlimitedNavigation = true,
	StreakSave = true,
}

-- Card icon per kind (Components/Icons names), for when the item has no
-- picture of its own.
local ICON: { [string]: string } = {
	Currency = "coin-gold",
	Cosmetic = "gem",
	NavigationRound = "arrow",
	UnlimitedNavigation = "arrow",
	StreakSave = "shield",
}

-- The store item whose picture stands in for the kind, if any.
local STORE_KEY: { [string]: string } = {
	NavigationRound = "navigation-round",
	UnlimitedNavigation = "navigation-pass",
	StreakSave = "streak-save",
}

-- How many senders the body names before "and N more".
local NAMED = 2

local function readOne(entry: any): Gift?
	if
		type(entry) ~= "table"
		or type(entry.id) ~= "string"
		or type(entry.from) ~= "string"
		or not KINDS[entry.kind]
	then
		return nil
	end
	local amount = entry.amount
	local cosmeticId = entry.cosmeticId
	return {
		id = entry.id,
		from = entry.from,
		kind = entry.kind,
		amount = if type(amount) == "number" then amount else nil,
		cosmeticId = if type(cosmeticId) == "string" then cosmeticId else nil,
	}
end

-- The well-formed gifts of a GiftReceived payload, in order (oldest
-- first). Malformed entries are skipped.
function GiftLogic.read(payload: any): { Gift }
	local gifts: { Gift } = {}
	if type(payload) == "table" and type(payload.gifts) == "table" then
		for _, entry in payload.gifts do
			local gift = readOne(entry)
			if gift ~= nil then
				table.insert(gifts, gift)
			end
		end
	end
	return gifts
end

-- `gifts` minus any whose id is in `seen` (shown or already waiting).
function GiftLogic.fresh(gifts: { Gift }, seen: { [string]: boolean }): { Gift }
	local out: { Gift } = {}
	for _, gift in gifts do
		if not seen[gift.id] then
			table.insert(out, gift)
		end
	end
	return out
end

local function counted(amount: number?, one: string, many: string): string
	local n = amount or 1
	return string.format("%d %s", n, if n == 1 then one else many)
end

-- The card's caption. `cosmeticName` turns a cosmetic id into its
-- display name.
function GiftLogic.text(gift: Gift, cosmeticName: (string) -> string): string
	if gift.kind == "Currency" then
		return counted(gift.amount, "coin", "coins")
	elseif gift.kind == "Cosmetic" then
		return cosmeticName(gift.cosmeticId or "?")
	elseif gift.kind == "NavigationRound" then
		return counted(gift.amount, "Navigation round", "Navigation rounds")
	elseif gift.kind == "UnlimitedNavigation" then
		return "Unlimited Navigation"
	end
	return counted(gift.amount, "Streak Save", "Streak Saves")
end

function GiftLogic.icon(gift: Gift): string
	return ICON[gift.kind] or "gift"
end

-- The store key whose imageAssetId pictures this gift (nil for coins
-- and cosmetics: a cosmetic uses its own preview icon).
function GiftLogic.storeKey(gift: Gift): string?
	return STORE_KEY[gift.kind]
end

-- The pop-up's title and body for a batch of gifts (one, or several
-- that waited out a race).
function GiftLogic.heading(gifts: { Gift }): (string, string)
	local title = if #gifts == 1 then "GIFT RECEIVED!" else string.format("%d GIFTS RECEIVED!", #gifts)
	local names: { string } = {}
	for _, gift in gifts do
		if table.find(names, gift.from) == nil then
			table.insert(names, gift.from)
		end
	end
	local body
	if #names <= NAMED then
		body = "From " .. table.concat(names, " and ")
	else
		body = string.format("From %s and %d more", table.concat(names, ", ", 1, NAMED), #names - NAMED)
	end
	return title, body
end

return GiftLogic
