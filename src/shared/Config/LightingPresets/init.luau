--!strict
-- Auto-collects every sibling lighting preset file (P7-5). A MapDef's
-- `lightingPreset` names one by `id`, and LightingService applies it when
-- that map loads. Lighting a new map means adding one file here and
-- nothing else (Ground Rule 2). docs/lighting-and-streaming.md explains
-- each field and what it costs on mobile.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.LightingPresetDef> }
