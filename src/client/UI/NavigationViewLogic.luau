--!strict
-- The client's half of Navigation (design-decisions.md Q8, "Navigation"),
-- pure so tests/NavigationViewLogic.spec.luau runs it headlessly:
-- whether the toggle shows at all, what the buy sheet offers, and how a
-- NavigationState payload reads. NavigationController does the drawing.
-- What a switch-on costs is never decided here: the server answers.

local NavigationViewLogic = {}

-- StoreScreenLogic.Item's shape, loose: this module has no requires.
export type Item = {
	key: string,
	kind: string,
	enabled: boolean,
	robuxPrice: number,
	coinPrice: number?,
	sortOrder: number,
	grants: { { kind: string, amount: number? } },
	perk: string?,
}

-- ===== the catalogue ========================================================

local PERK = "UnlimitedNavigation"

-- Sells a round (the Robux product or the coin offer).
function NavigationViewLogic.sellsRound(item: Item): boolean
	for _, grant in item.grants do
		if grant.kind == "NavigationRound" then
			return true
		end
	end
	return false
end

function NavigationViewLogic.sellsPass(item: Item): boolean
	return item.perk == PERK
end

-- The toggle is shown only when Navigation can be had at all: some round
-- or the pass is on sale. While all three are disabled (no product ids
-- or art yet), the compass is just a compass.
function NavigationViewLogic.offered(items: { Item }): boolean
	for _, item in items do
		if item.enabled and (NavigationViewLogic.sellsRound(item) or NavigationViewLogic.sellsPass(item)) then
			return true
		end
	end
	return false
end

-- ===== the buy sheet ========================================================

export type Offer = {
	key: string,
	label: string,
	coins: boolean,
	affordable: boolean,
}

-- What the sheet offers: each enabled round, Robux first, then coins
-- (owner, 2026-10-08: "99 R$ or 100 coins"). A coin round the player
-- can't afford is still listed, greyed out, so the coin path is always
-- visible (Q8). `currency` nil = store state not loaded yet: treated as
-- unaffordable rather than guessed.
function NavigationViewLogic.offers(items: { Item }, currency: number?): { Offer }
	local rounds = {}
	for _, item in items do
		if item.enabled and NavigationViewLogic.sellsRound(item) then
			table.insert(rounds, item)
		end
	end
	table.sort(rounds, function(a, b)
		local aCoins, bCoins = a.kind == "CoinOffer", b.kind == "CoinOffer"
		if aCoins ~= bCoins then
			return bCoins
		end
		if a.sortOrder ~= b.sortOrder then
			return a.sortOrder < b.sortOrder
		end
		return a.key < b.key
	end)

	local out: { Offer } = {}
	for _, item in rounds do
		if item.kind == "CoinOffer" then
			local price = item.coinPrice or 0
			table.insert(out, {
				key = item.key,
				label = string.format("%d coins", price),
				coins = true,
				affordable = currency ~= nil and currency >= price,
			})
		else
			table.insert(out, {
				key = item.key,
				label = string.format("%d R$", item.robuxPrice),
				coins = false,
				affordable = true, -- Roblox's own prompt handles a short balance
			})
		end
	end
	return out
end

-- ===== the server's answer ==================================================

export type Status = "On" | "Off" | "NeedsPurchase" | "Unavailable"

export type State = {
	status: Status,
	on: boolean,
	unlimited: boolean,
	roundsHeld: number,
}

local STATUSES: { [string]: boolean } = { On = true, Off = true, NeedsPurchase = true, Unavailable = true }

-- A NavigationState payload, checked; nil if it's malformed.
function NavigationViewLogic.read(payload: any): State?
	if type(payload) ~= "table" or type(payload.status) ~= "string" or not STATUSES[payload.status] then
		return nil
	end
	return {
		status = payload.status :: Status,
		on = payload.on == true,
		unlimited = payload.unlimited == true,
		roundsHeld = if type(payload.roundsHeld) == "number" then payload.roundsHeld else 0,
	}
end

return NavigationViewLogic
