--!strict
-- Pure half of StudioStageService: where each finalist stands, which
-- lookout each spectator gets, when a spectator has left the upper
-- level, and who may hear whom in chat during the finale. No Roblox API
-- and no requires, so tests/StudioStageLogic.spec.luau covers it
-- headlessly (Ground Rule 4). Positions are plain numbers for the same
-- reason PowerUpLogic's are: Vector3 doesn't exist under Lune.

local StudioStageLogic = {}

-- The world-space height of an oriented box's top face: its centre plus
-- half its extent along world Y. A podium may be a cylinder turned on
-- its side (a Part cylinder's axis is X), so Size.Y alone isn't its
-- height. `rightY`, `upY`, `lookY` are the Y components of the part's
-- RightVector, UpVector and LookVector.
function StudioStageLogic.topY(
	centreY: number,
	sizeX: number,
	sizeY: number,
	sizeZ: number,
	rightY: number,
	upY: number,
	lookY: number
): number
	return centreY + (math.abs(rightY) * sizeX + math.abs(upY) * sizeY + math.abs(lookY) * sizeZ) / 2
end

-- Where a finalist's root goes on a podium, and which way it faces: on
-- top of the podium at `standHeight` (the root's height above the feet),
-- looking at the centre on the level, so the three face each other
-- rather than tilting up or down at the anchor. A podium exactly on the
-- centre gets an arbitrary but valid facing (+Z).
export type Stand = { x: number, y: number, z: number, lookX: number, lookZ: number }

function StudioStageLogic.standOn(
	podiumX: number,
	podiumTopY: number,
	podiumZ: number,
	standHeight: number,
	centreX: number,
	centreZ: number
): Stand
	local dx, dz = centreX - podiumX, centreZ - podiumZ
	local length = math.sqrt(dx * dx + dz * dz)
	local lookX, lookZ = 0, 1
	if length > 1e-6 then
		lookX, lookZ = dx / length, dz / length
	end
	return { x = podiumX, y = podiumTopY + standHeight, z = podiumZ, lookX = lookX, lookZ = lookZ }
end

-- Seat order -> podium. `qualifierIds` is DecisionService's seat order;
-- `slotIndices` are the podiums' SlotIndex attributes. Returns racer id
-- -> slot index, seat n on SlotIndex n. A seat with no podium of its own
-- (the map is short a podium) is left out, and the caller warns.
function StudioStageLogic.podiumFor(qualifierIds: { number }, slotIndices: { number }): { [number]: number }
	local available: { [number]: boolean } = {}
	for _, index in slotIndices do
		available[index] = true
	end
	local out: { [number]: number } = {}
	for seat, id in qualifierIds do
		if available[seat] then
			out[id] = seat
		end
	end
	return out
end

-- Spectators spread over the lookouts in turn, in id order so every
-- server agrees. Returns id -> 1-based lookout index. Sorting on the id
-- keeps it deterministic regardless of the order the caller collected
-- them in.
function StudioStageLogic.lookoutFor(spectatorIds: { number }, lookoutCount: number): { [number]: number }
	assert(lookoutCount > 0, "StudioStageLogic.lookoutFor: no lookouts")
	local sorted = table.clone(spectatorIds)
	table.sort(sorted)
	local out: { [number]: number } = {}
	for position, id in sorted do
		out[id] = (position - 1) % lookoutCount + 1
	end
	return out
end

-- Is a spectator still inside the spectator area? The area is a box
-- (StudioSpectatorArea) around the walkway they watch from, and the
-- point is the root's position in that box's own space
-- (CFrame:PointToObjectSpace), so a rotated box works too. Outside it
-- in any direction - over the fence, down off the end, round a corner -
-- and the service puts them back.
function StudioStageLogic.isInsideArea(
	localX: number,
	localY: number,
	localZ: number,
	sizeX: number,
	sizeY: number,
	sizeZ: number
): boolean
	return math.abs(localX) <= sizeX / 2 and math.abs(localY) <= sizeY / 2 and math.abs(localZ) <= sizeZ / 2
end

-- The general channel during the finale: losers watch only. A finalist
-- neither sends to nor receives from it (their talk is the Negotiate
-- channel, which spectators read), so no eliminated player can coach a
-- finalist and no finalist can use it to side-channel another. Losers
-- still talk among themselves. You always see your own message.
function StudioStageLogic.mayDeliverGeneral(
	senderIsFinalist: boolean,
	recipientIsFinalist: boolean,
	isOwnMessage: boolean
): boolean
	if isOwnMessage then
		return true
	end
	return not senderIsFinalist and not recipientIsFinalist
end

-- The Negotiate channel: only finalists speak, everyone in it reads.
-- Finalist-to-finalist is still range-limited (P3-3); a spectator reads
-- from the upper level, which is out of that range by design.
function StudioStageLogic.mayDeliverNegotiate(
	senderIsFinalist: boolean,
	recipientIsFinalist: boolean,
	isOwnMessage: boolean,
	withinRange: boolean
): boolean
	if not senderIsFinalist then
		return false
	end
	if isOwnMessage or not recipientIsFinalist then
		return true
	end
	return withinRange
end

return table.freeze(StudioStageLogic)
