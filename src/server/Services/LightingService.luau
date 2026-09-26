--!strict
-- Applies a map's lighting preset when the map loads, and puts the place's
-- own lighting back on Cleanup (P7-5). Lighting and its children replicate
-- to every client, so setting them on the server is enough and no client
-- code is involved.
--
-- LightingLogic.luau decides what gets written. This file only performs the
-- writes. There is no leaked state between rounds because:
--   - init() snapshots LightingLogic.LIGHTING_PROPERTIES from the place as
--     authored in Studio, once, before any preset has touched it;
--   - apply() writes all of those properties and creates its OWN post
--     effects (tagged by name below);
--   - restore() writes the snapshot back and destroys those effects. It
--     runs on Cleanup, and at the start of apply() in case a caller loads
--     a second map without a Cleanup in between.
--
-- The place's Lighting should ship with no Atmosphere and no post effects
-- (docs/lighting-and-streaming.md §3). An Atmosphere silently overrides
-- FogStart/FogEnd, and a Studio-authored Bloom would stack with a
-- preset's. init() warns about either rather than deleting something a
-- builder put there on purpose.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local LightingPresets = require(ReplicatedStorage.Shared.Config.LightingPresets)
local LightingLogic = require(ServerScriptService.Server.LightingLogic)

local EFFECT_PREFIX = "MapPreset_"

local defaults: { [string]: any } = {}
local ownedEffects: { Instance } = {}
local activePresetId: string? = nil

local function convert(assignment: LightingLogic.Assignment): any
	if assignment.kind == "color" then
		return Color3.fromHex(assignment.value :: string)
	elseif assignment.kind == "enum" then
		return (Enum.LightingStyle :: any)[assignment.value :: string]
	end
	return assignment.value
end

-- Some Lighting properties (LightingStyle, PrioritizeLightingQuality)
-- can refuse a runtime write. A refused property must not abort the
-- whole preset - that error used to kill StudioTestService's round start
-- before anyone was moved onto the map - so warn once and keep going.
local refusedProperties: { [string]: boolean } = {}

local function setProperty(target: Instance, property: string, value: any)
	local ok, message = pcall(function()
		(target :: any)[property] = value
	end)
	if not ok and not refusedProperties[property] then
		refusedProperties[property] = true
		warn(
			string.format(
				"LightingService: can't set %s.%s at runtime (%s) - skipping it",
				target.ClassName,
				property,
				tostring(message)
			)
		)
	end
end

local function write(target: Instance, assignments: { LightingLogic.Assignment })
	for _, assignment in assignments do
		setProperty(target, assignment.property, convert(assignment))
	end
end

local function createEffect(className: string, assignments: { LightingLogic.Assignment })
	local effect = Instance.new(className)
	effect.Name = EFFECT_PREFIX .. className
	write(effect, assignments)
	effect.Parent = Lighting
	table.insert(ownedEffects, effect)
end

local LightingService: Loader.Service = {
	name = "LightingService",
	dependencies = { "ConfigValidator", "RoundService" },
}

function LightingService.restore()
	if activePresetId == nil then
		return
	end
	for property, value in defaults do
		setProperty(Lighting, property, value)
	end
	for _, effect in ownedEffects do
		effect:Destroy()
	end
	table.clear(ownedEffects)
	activePresetId = nil
end

-- Returns false, and leaves the place's default lighting in place, if no
-- preset has this id. Validate.run guarantees every ENABLED map's preset
-- exists, so this only happens for a disabled map in Studio test mode.
function LightingService.apply(presetId: string): boolean
	LightingService.restore()

	local preset = LightingLogic.find(LightingPresets :: any, presetId)
	if preset == nil then
		warn(string.format("LightingService: no lighting preset %q - keeping the place's default lighting", presetId))
		return false
	end

	local plan = LightingLogic.plan(preset)
	write(Lighting, plan.lighting)
	if plan.colorCorrection ~= nil then
		createEffect("ColorCorrectionEffect", plan.colorCorrection)
	end
	if plan.bloom ~= nil then
		createEffect("BloomEffect", plan.bloom)
	end
	activePresetId = presetId
	return true
end

function LightingService.activePreset(): string?
	return activePresetId
end

function LightingService:init()
	for _, property in LightingLogic.LIGHTING_PROPERTIES do
		defaults[property] = (Lighting :: any)[property]
	end

	for _, child in Lighting:GetChildren() do
		if child:IsA("Atmosphere") then
			warn(
				"LightingService: Lighting has an Atmosphere, which overrides every preset's FogStart/FogEnd - remove it"
			)
		elseif child:IsA("PostEffect") then
			warn(
				string.format(
					"LightingService: Lighting.%s is a Studio-authored post effect and will stack with map presets - remove it",
					child.Name
				)
			)
		end
	end
end

function LightingService:start()
	local RoundService = Loader.get("RoundService") :: any
	RoundService.onEnter("Cleanup", function()
		LightingService.restore()
	end)
end

return LightingService
