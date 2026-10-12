--!strict
-- The staff gift pop-up's rules (staff-tools.md step 3; design-
-- decisions.md "Applied case: staff tools"), kept free of Roblox calls
-- so they're tested headlessly (tests/GiftLogic.spec.luau).
-- MenuController draws what this decides, with ClaimPopup.
--
-- The gift is already in the profile when GiftReceived arrives; the
-- pop-up only says so. Mid-race (MenuController's IN_PLAY states) the
-- gifts wait in a queue and show together once the round leaves play,
-- so a pop-up never covers a task or the Decision Studio.
--
-- Names and items only, never a streak (Q7 condition 1).

local GiftLogic = {}

-- GiftReceived, as StaffService sends it. `kind` is one of
-- StaffGrantLogic.GIFT_KINDS.
export type Gift = {
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
	Currency = "coin",
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

-- A well-formed GiftReceived payload, or nil.
function GiftLogic.read(payload: any): Gift?
	if type(payload) ~= "table" or type(payload.from) ~= "string" or not KINDS[payload.kind] then
		return nil
	end
	local amount = payload.amount
	local cosmeticId = payload.cosmeticId
	return {
		from = payload.from,
		kind = payload.kind,
		amount = if type(amount) == "number" then amount else nil,
		cosmeticId = if type(cosmeticId) == "string" then cosmeticId else nil,
	}
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
