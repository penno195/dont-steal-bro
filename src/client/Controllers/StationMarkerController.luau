--!strict
-- The world-space layer of station readability (P7-6,
-- docs/station-readability.md). During a race, every station on YOUR
-- route gets a marker, and no other station gets anything:
--
--   - a shaft of light rising from the floor (a Beam). It clears the
--     walkway clutter, so it reads across a dense room, and it fades out
--     at the top, so it looks like light rather than a pole or a UI pin;
--   - a flat Neon pad on the floor under the station. It marks out the
--     station's floor space and gives the only motion in the marker;
--   - close up only, a glyph for the two states that need words
--     (a rival is on it, or it's done).
--
-- StationMarkerLogic decides the state and what it looks like. This file
-- only builds instances. Everything here is local to this client and
-- display-only: the route comes from TaskAssignmentState, and who's at a
-- station comes from the server-written `Occupants` attribute
-- (shared/StationOccupants.luau).
--
-- Cost per marked station: one Part, two Attachments, one Beam, and a
-- BillboardGui only while Rival or Done. That's at most GameConfig.
-- tasksPerPlayer of each, about 2 transparent draws per station, plus
-- one engine-side tween. There is no per-frame Lua.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Maps = require(ReplicatedStorage.Shared.Config.Maps)
local Net = require(ReplicatedStorage.Shared.Net)
local StationOccupants = require(ReplicatedStorage.Shared.StationOccupants)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)
local Icons = require(script.Parent.Parent.UI.Components.Icons)
local StationMarkerLogic = require(script.Parent.Parent.UI.StationMarkerLogic)
local Tokens = require(script.Parent.Parent.UI.Tokens)

-- A station's footprint in wave1-briefs.md is about a desk wide.
local PAD_DIAMETER = 6
local PAD_THICKNESS = 0.2
-- How far below the anchor to look for the floor. Anchors sit at desk
-- or hand height, so this is generous.
local FLOOR_SEARCH = 20
local BEAM_WIDTH_BASE = 1.4
local BEAM_WIDTH_TOP = 0.3
local GLYPH_STUDS = 2.5
local GLYPH_ABOVE_ANCHOR = 3
local PULSE_SECONDS = 1.1
local PULSE_TRANSPARENCY = 0.8

type Marker = {
	pad: Part,
	beam: Beam,
	style: StationMarkerLogic.Style,
	state: StationMarkerLogic.State,
	glyphAt: Vector3, -- offset above the pad
	glyph: BillboardGui?,
	pulse: Tween?,
}

local selfId = Players.LocalPlayer.UserId

local stationParts: { [string]: BasePart } = {}
-- stationId -> completed, for the stations on your route.
local route: { [string]: boolean } = {}
local racing = false
local markers: { [string]: Marker } = {}
local styles: { [string]: StationMarkerLogic.Style } = {}

-- A map's clone keeps its model's Name, which is its MapDef id
-- (ConfigValidator checks they match). An unknown map, such as Studio's
-- GrayBoxTest, gets the defaults.
local function styleFor(station: BasePart): StationMarkerLogic.Style
	local mapRoot: Instance = station
	while mapRoot.Parent ~= nil and mapRoot.Parent ~= Workspace do
		mapRoot = mapRoot.Parent
	end
	local mapId = mapRoot.Name
	local cached = styles[mapId]
	if cached ~= nil then
		return cached
	end
	local def: Validate.StationMarkerDef? = nil
	for _, entry in Maps do
		if entry.def.id == mapId then
			def = entry.def.stationMarker
			break
		end
	end
	local style = StationMarkerLogic.style(def, Tokens.color.brand)
	styles[mapId] = style
	return style
end

local function floorUnder(station: BasePart): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = { station }
	for _, player in Players:GetPlayers() do
		if player.Character ~= nil then
			table.insert(ignore, player.Character)
		end
	end
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true
	local hit = Workspace:Raycast(station.Position, Vector3.new(0, -FLOOR_SEARCH, 0), params)
	if hit ~= nil then
		return hit.Position
	end
	return station.Position - Vector3.new(0, station.Size.Y / 2, 0)
end

local function toSequence(points: { StationMarkerLogic.Keypoint }): NumberSequence
	local keypoints = table.create(#points)
	for i, point in points do
		keypoints[i] = NumberSequenceKeypoint.new(point.time, point.value)
	end
	return NumberSequence.new(keypoints)
end

local function build(station: BasePart): Marker
	local style = styleFor(station)
	local tint = Color3.fromHex(style.tint)
	local floor = floorUnder(station)

	-- A cylinder's round faces are on its X axis, so turn it onto its side.
	local pad = Instance.new("Part")
	pad.Name = "StationMarker"
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(PAD_THICKNESS, PAD_DIAMETER, PAD_DIAMETER)
	pad.CFrame = CFrame.new(floor + Vector3.new(0, PAD_THICKNESS / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	pad.Anchored = true
	pad.CanCollide = false
	pad.CanTouch = false
	pad.CanQuery = false
	pad.CastShadow = false
	pad.Material = Enum.Material.Neon
	pad.Color = tint
	pad.Transparency = 1

	local base = Instance.new("Attachment")
	base.Parent = pad
	base.WorldPosition = floor
	local top = Instance.new("Attachment")
	top.Parent = pad
	top.WorldPosition = floor + Vector3.new(0, style.beamHeight, 0)

	local beam = Instance.new("Beam")
	beam.Attachment0 = base
	beam.Attachment1 = top
	beam.FaceCamera = true
	beam.Segments = 1
	beam.Width0 = BEAM_WIDTH_BASE
	beam.Width1 = BEAM_WIDTH_TOP
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Color = ColorSequence.new(tint)
	beam.Enabled = false
	beam.Parent = pad

	-- Under the anchor, so it goes when the map is cleaned up.
	pad.Parent = station

	return {
		pad = pad,
		beam = beam,
		style = style,
		state = "Hidden",
		glyphAt = station.Position - floor + Vector3.new(0, GLYPH_ABOVE_ANCHOR, 0),
	}
end

local function setGlyph(marker: Marker, key: string?)
	if marker.glyph ~= nil then
		marker.glyph:Destroy()
		marker.glyph = nil
	end
	if key == nil then
		return
	end
	-- Sized in studs, not pixels, so it shrinks with distance like a
	-- sign in the world. The HUD's arrow is what reads at range.
	local gui = Instance.new("BillboardGui")
	gui.Name = "StationGlyph"
	gui.Size = UDim2.fromScale(GLYPH_STUDS, GLYPH_STUDS)
	gui.StudsOffsetWorldSpace = marker.glyphAt
	gui.MaxDistance = StationMarkerLogic.GLYPH_MAX_DISTANCE
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.ResetOnSpawn = false
	gui.Adornee = marker.pad
	local icon = Icons.view(key, 1, Color3.fromHex(Tokens.color.ink))
	icon.Size = UDim2.fromScale(1, 1)
	if icon:IsA("TextLabel") then
		icon.TextScaled = true
	end
	icon.Parent = gui
	gui.Parent = marker.pad
	marker.glyph = gui
end

local function apply(marker: Marker, state: StationMarkerLogic.State)
	if marker.state == state then
		return
	end
	marker.state = state
	local look = StationMarkerLogic.look(state)
	if look == nil then
		return
	end

	if marker.pulse ~= nil then
		marker.pulse:Cancel()
		marker.pulse = nil
	end
	local pad = marker.pad
	pad.Transparency = if marker.style.pad then look.padTransparency else 1
	if marker.style.pad and look.pulse then
		local pulse = TweenService:Create(
			pad,
			TweenInfo.new(PULSE_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ Transparency = PULSE_TRANSPARENCY }
		)
		pulse:Play()
		marker.pulse = pulse
	end

	local beam = marker.beam
	beam.Enabled = marker.style.beam and look.beam ~= "Off"
	if beam.Enabled then
		beam.Transparency = toSequence(StationMarkerLogic.beamTransparency(look.beam))
	end

	setGlyph(marker, look.glyph)
end

local function remove(stationId: string)
	local marker = markers[stationId]
	if marker == nil then
		return
	end
	markers[stationId] = nil
	if marker.pulse ~= nil then
		marker.pulse:Cancel()
	end
	marker.pad:Destroy()
end

local function refresh(stationId: string)
	local station: BasePart? = stationParts[stationId]
	local completed: boolean? = route[stationId]
	local state: StationMarkerLogic.State = "Hidden"
	if racing and station ~= nil and station.Parent ~= nil and completed ~= nil then
		local mine, others = StationOccupants.split(station:GetAttribute(StationOccupants.ATTRIBUTE), selfId)
		state = StationMarkerLogic.state({
			assigned = true,
			completed = completed,
			mine = mine,
			others = others,
		})
	end

	if state == "Hidden" then
		remove(stationId)
		return
	end
	local marker = markers[stationId]
	if marker == nil then
		marker = build(station :: BasePart)
		markers[stationId] = marker
	end
	apply(marker :: Marker, state)
end

local function refreshAll()
	for stationId in markers do
		if route[stationId] == nil then
			remove(stationId)
		end
	end
	for stationId in route do
		refresh(stationId)
	end
end

local function trackStation(instance: Instance)
	local stationId = instance:GetAttribute("StationId")
	if not instance:IsA("BasePart") or typeof(stationId) ~= "string" then
		return
	end
	stationParts[stationId] = instance
	instance:GetAttributeChangedSignal(StationOccupants.ATTRIBUTE):Connect(function()
		if route[stationId] ~= nil then
			refresh(stationId)
		end
	end)
	if route[stationId] ~= nil then
		refresh(stationId)
	end
end

local function untrackStation(instance: Instance)
	local stationId = instance:GetAttribute("StationId")
	if typeof(stationId) == "string" and stationParts[stationId] == instance then
		stationParts[stationId] = nil
		remove(stationId)
	end
end

local function onRoute(payload: any)
	route = {}
	for _, entry in payload.assignments do
		route[entry.stationId :: string] = entry.completed == true
	end
	refreshAll()
end

local function onRoundState(payload: any)
	local nowRacing = payload.state == "Race"
	if nowRacing == racing then
		return
	end
	racing = nowRacing
	if not racing then
		-- A new race sends a new route.
		route = {}
	end
	refreshAll()
end

local StationMarkerController: Loader.Controller = {
	name = "StationMarkerController",
	dependencies = {},
}

function StationMarkerController:init()
	Net.onClientEvent("RoundState", onRoundState)
	Net.onClientEvent("TaskAssignmentState", onRoute)
end

function StationMarkerController:start()
	for _, instance in CollectionService:GetTagged("TaskStation") do
		trackStation(instance)
	end
	CollectionService:GetInstanceAddedSignal("TaskStation"):Connect(trackStation)
	CollectionService:GetInstanceRemovedSignal("TaskStation"):Connect(untrackStation)
end

return StationMarkerController
