--!strict
-- Pure logic behind the Locker's "something new" dots (Hub menu pass,
-- 2026-10-18). Each tab remembers which of its items the player has
-- already looked at; anything owned but not in that list is new, and
-- dots the tab and the Hub's Locker button. Opening the tab marks
-- everything in it seen.
--
-- What "owned" means per tab:
--   Power   power-up kinds with stock > 0 (one bought in the store or
--           handed out counts as new until the tab's been looked at;
--           running out and getting more again doesn't)
--   Style   owned cosmetics
--   Titles  unlocked titles
--
-- Only ever ids of things the player owns go into a seen list, so it's
-- bounded by the catalogue, and only the server writes it: the client
-- names a tab, never ids (Ground Rule 1).

local LockerSeenLogic = {}

export type Tab = "Power" | "Style" | "Titles"

-- Structurally ProfileLogic.LockerSeen.
export type Seen = { Power: { string }, Style: { string }, Titles: { string } }

export type Unseen = { Power: boolean, Style: boolean, Titles: boolean }

-- The power-up kinds held: ids with stock above 0, sorted so the list
-- (and a profile written from it) doesn't depend on table order.
function LockerSeenLogic.held(stock: { [string]: number }): { string }
	local ids = {}
	for id, count in stock do
		if count > 0 then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

-- What each tab currently counts as owned.
function LockerSeenLogic.owned(stock: { [string]: number }, cosmetics: { string }, titles: { string }): Seen
	return {
		Power = LockerSeenLogic.held(stock),
		Style = table.clone(cosmetics),
		Titles = table.clone(titles),
	}
end

-- Whether any of `owned` is missing from `seen`.
function LockerSeenLogic.anyUnseen(owned: { string }, seen: { string }): boolean
	local known: { [string]: boolean } = {}
	for _, id in seen do
		known[id] = true
	end
	for _, id in owned do
		if not known[id] then
			return true
		end
	end
	return false
end

-- Each tab's dot.
function LockerSeenLogic.unseen(owned: Seen, seen: Seen): Unseen
	return {
		Power = LockerSeenLogic.anyUnseen(owned.Power, seen.Power),
		Style = LockerSeenLogic.anyUnseen(owned.Style, seen.Style),
		Titles = LockerSeenLogic.anyUnseen(owned.Titles, seen.Titles),
	}
end

-- `seen` plus everything in `owned` it lacks, as a fresh list. Ids
-- already seen stay, so a power-up that runs out and comes back isn't
-- new again.
function LockerSeenLogic.markSeen(seen: { string }, owned: { string }): { string }
	local result = table.clone(seen)
	local known: { [string]: boolean } = {}
	for _, id in seen do
		known[id] = true
	end
	for _, id in owned do
		if not known[id] then
			known[id] = true
			table.insert(result, id)
		end
	end
	return result
end

return LockerSeenLogic
