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

-- ===== the path line ========================================================
-- Waist-high dots along a smoothed route, with a pulse that runs from
-- the player towards the station and repeats (owner, 2026-10-08).

export type Point = { x: number, y: number, z: number }

local function lerp(a: Point, b: Point, t: number): Point
	return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }
end

local function distance(a: Point, b: Point): number
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Rounds the route's corners (Chaikin corner cutting). Each pass swaps
-- every corner for two points a quarter of the way along its sides, so
-- the curve never overshoots the route the way a spline can, and the
-- two ends stay exactly where they were.
function NavigationViewLogic.smooth(points: { Point }, passes: number): { Point }
	local current = points
	for _ = 1, passes do
		if #current < 3 then
			return current
		end
		local nextPoints = { current[1] }
		for i = 1, #current - 1 do
			local a, b = current[i], current[i + 1]
			if i > 1 then
				table.insert(nextPoints, lerp(a, b, 0.25))
			end
			if i < #current - 1 then
				table.insert(nextPoints, lerp(a, b, 0.75))
			end
		end
		table.insert(nextPoints, current[#current])
		current = nextPoints
	end
	return current
end

-- Evenly spaced dots along a polyline: one every `spacing` studs from
-- the start, at most `maxCount` of them. Each carries how far along the
-- path it is, which the pulse runs on.
function NavigationViewLogic.dots(
	points: { Point },
	spacing: number,
	maxCount: number
): { { point: Point, along: number } }
	local out = {}
	if #points == 0 or spacing <= 0 then
		return out
	end
	table.insert(out, { point = points[1], along = 0 })
	local walked = 0 -- path length before the current segment
	local nextAt = spacing
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local length = distance(a, b)
		while length > 0 and nextAt <= walked + length do
			if #out >= maxCount then
				return out
			end
			table.insert(out, { point = lerp(a, b, (nextAt - walked) / length), along = nextAt })
			nextAt += spacing
		end
		walked += length
	end
	return out
end

-- How lit a dot is, 0..1, `along` studs down the path at time `now`.
-- A peak every `wavelength` studs, moving towards the station at
-- `speed` studs a second, with a short tail behind each peak.
function NavigationViewLogic.pulse(along: number, now: number, speed: number, wavelength: number): number
	local behind = (now * speed - along) % wavelength / wavelength -- 0 at a peak
	return math.max(0, 1 - behind * 3)
end

return NavigationViewLogic
