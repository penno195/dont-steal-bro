--!strict
-- Per-map streaming setup (P7-5). The place-wide Workspace streaming
-- properties can't be set from a script (they are Studio-only), so they
-- live in docs/lighting-and-streaming.md §1 as a checklist. This module
-- does the part a script CAN do: it sets each map clone's per-model
-- ModelStreamingMode before the clone is parented into Workspace.
--
-- The rule is decided by who reads a tag, not by what it is:
--
--   - The SERVER always has the whole map. Streaming only controls what
--     reaches clients. So tags only the server reads (NavNode, KillZone,
--     PlayableBounds, SpawnPoint, the Studio* tags) need nothing. NPCs,
--     bounds checks and spawn placement all run server-side (Ground
--     Rule 1).
--   - CLIENTS read exactly one tag: TaskStation. RaceHUDController tracks
--     every station map-wide for the nearest-objective arrow, and
--     TaskStationController needs the anchor to launch a task. So:
--       * each TaskStation anchor goes into its own tiny Persistent
--         model. That is 16 parts per map, a trivial cost, and the arrow
--         never points at a station the client hasn't received;
--       * the station's dressing model (the machine/desk around the
--         anchor) becomes Atomic, so it loads whole or not at all. A
--         half-rendered station reads as a bug.
--
-- A tagged anchor is a BasePart, and only a Model has a
-- ModelStreamingMode. That is why the anchor is lifted into a wrapper
-- model rather than asking builders to do it (map-kit-spec.md promises
-- builders need no scripting knowledge). The wrapper is parented to the
-- map root, not into the Atomic dressing, so the two modes never nest.
-- The move is safe because every consumer finds stations by tag and
-- attribute, never by path.

local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local MapStreaming = {}

-- Loading lasts GameConfig.roundTimers.loadingSeconds (5s). Leave room
-- for the pivot itself after the stream request gives up.
local STREAM_AROUND_TIMEOUT_SECONDS = 3

local warnedDisabled = false

local function nearestModelBelow(instance: Instance, root: Instance): Model?
	local current = instance.Parent
	while current ~= nil and current ~= root do
		if current:IsA("Model") then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- Call on a freshly cloned map BEFORE parenting it to Workspace, so
-- clients never see it with default streaming modes. It works on an
-- unparented clone because it walks descendants and uses HasTag.
-- GetTagged only sees instances already in the DataModel.
function MapStreaming.prepare(map: Instance)
	if not Workspace.StreamingEnabled and not warnedDisabled then
		warnedDisabled = true
		warn(
			"MapStreaming: Workspace.StreamingEnabled is off - set the place settings in docs/lighting-and-streaming.md §1"
		)
	end

	for _, instance in map:GetDescendants() do
		if not (instance:IsA("BasePart") and CollectionService:HasTag(instance, "TaskStation")) then
			continue
		end

		local dressing = nearestModelBelow(instance, map)
		if dressing ~= nil then
			dressing.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
		end

		local wrapper = Instance.new("Model")
		wrapper.Name = instance.Name .. "_Anchor"
		wrapper.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
		wrapper.Parent = map
		instance.Parent = wrapper
	end
end

-- Asks the engine to stream the area around `position` to `player` before
-- the server moves their character there, for the race spawn and the
-- teleport into the Decision Studio. It yields for up to the timeout.
-- Failure is only logged: under StreamingIntegrityMode
-- PauseOutsideLoadedArea the client pauses until the area arrives anyway,
-- so the worst case is a short loading pause, never a fall through
-- unloaded floor.
function MapStreaming.streamAround(player: Player, position: Vector3)
	local ok, err = pcall(function()
		player:RequestStreamAroundAsync(position, STREAM_AROUND_TIMEOUT_SECONDS)
	end)
	if not ok then
		warn(string.format("MapStreaming: RequestStreamAroundAsync failed for %s: %s", player.Name, tostring(err)))
	end
end

return MapStreaming
