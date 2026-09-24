--!strict
-- The wire format of a TaskStation's `Occupants` attribute (P7-6): who
-- has an attempt open there right now, as sorted participant ids joined
-- by commas ("-2,418823"). Humans are their UserId and NPCs their
-- negative participant id, the same ids TaskProgress uses. No attribute
-- (nil) means nobody.
--
-- The server writes it (StationOccupancy.luau) and clients only read it,
-- to draw the "a rival is here" marker. It is display-only: stations
-- are never exclusive, and nothing server-side reads it back.
--
-- Ids, not a count, so a client can tell its own attempt from a rival's
-- without guessing which remote or attribute change landed first.
--
-- Pure: no Roblox API, so tests/StationOccupants.spec.luau runs it
-- under Lune.

local StationOccupants = {}

StationOccupants.ATTRIBUTE = "Occupants"

-- nil for an empty set, so the attribute is removed rather than left as "".
function StationOccupants.encode(ids: { number }): string?
	if #ids == 0 then
		return nil
	end
	local sorted = table.clone(ids)
	table.sort(sorted)
	local parts = table.create(#sorted)
	for i, id in sorted do
		parts[i] = string.format("%d", id)
	end
	return table.concat(parts, ",")
end

-- Anything that isn't a string (a missing attribute, or a map author's
-- stray value of another type) decodes as nobody.
function StationOccupants.decode(value: any): { number }
	local ids: { number } = {}
	if type(value) ~= "string" then
		return ids
	end
	for token in string.gmatch(value, "[^,]+") do
		local id = tonumber(token)
		if id ~= nil then
			table.insert(ids, id)
		end
	end
	return ids
end

-- Whether `selfId` is in the set, and how many others are.
function StationOccupants.split(value: any, selfId: number): (boolean, number)
	local mine = false
	local others = 0
	for _, id in StationOccupants.decode(value) do
		if id == selfId then
			mine = true
		else
			others += 1
		end
	end
	return mine, others
end

return StationOccupants
