--!strict
-- Publishes who is working at each TaskStation (P7-6), so a client can
-- mark a station a rival is already at. TaskHandlerService reports human
-- attempts and NPCService reports bots in their Working phase. Each
-- racer is at no more than one station, so `enter` moves them.
--
-- The result is written to the station anchor's `Occupants` attribute
-- (format: shared/StationOccupants.luau). Attributes replicate
-- server-to-client only, so a client can't forge one that others see.
-- It's display-only: TaskService and TaskHandlerService never read it,
-- and stations never lock.
--
-- Callers write this AFTER the remote that tells the player about the
-- same change (TaskChallenge, TaskEnded, TaskResult). The client reads
-- its own id out of the attribute, so the order only affects how soon
-- its marker switches, never whether it ends up right.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StationOccupants = require(ReplicatedStorage.Shared.StationOccupants)

local StationOccupancy = {}

local stationOf: { [number]: BasePart } = {}
local occupants: { [BasePart]: { number } } = {}

local function publish(station: BasePart)
	local ids = occupants[station] or {}
	if #ids == 0 then
		occupants[station] = nil
	end
	-- A station destroyed with its map just drops the write.
	if station.Parent ~= nil then
		station:SetAttribute(StationOccupants.ATTRIBUTE, StationOccupants.encode(ids))
	end
end

function StationOccupancy.leave(id: number)
	local station: BasePart? = stationOf[id]
	if station == nil then
		return
	end
	stationOf[id] = nil
	local ids = occupants[station]
	if ids ~= nil then
		local index = table.find(ids, id)
		if index ~= nil then
			table.remove(ids, index)
		end
	end
	publish(station)
end

function StationOccupancy.enter(id: number, station: BasePart)
	local current: BasePart? = stationOf[id]
	if current == station then
		return
	end
	StationOccupancy.leave(id)
	stationOf[id] = station
	local ids = occupants[station]
	if ids == nil then
		ids = {}
		occupants[station] = ids
	end
	table.insert(ids, id)
	publish(station)
end

-- Every station back to empty. Run when a race starts, so nothing from a
-- Studio replay survives into the next one.
function StationOccupancy.clear()
	local stations = occupants
	stationOf = {}
	occupants = {}
	for station in stations do
		publish(station)
	end
end

return StationOccupancy
