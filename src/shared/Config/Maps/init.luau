--!strict
-- Auto-collects every sibling map definition file. Empty for now - maps
-- are built by hand in Studio (CLAUDE.md) and this repo doesn't have one
-- yet; add a MapDef file here once P0-5's builder's checklist has been
-- run against a real map. Add an 11th (or 1st) map the same way as a
-- task: one file, nothing else to touch (Ground Rule 2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.MapDef> }
