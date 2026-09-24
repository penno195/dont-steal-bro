--!strict
-- Auto-collects every sibling map definition file (P7-3: all 11, none
-- enabled until built). Maps are built by hand in Studio (CLAUDE.md); ConfigValidator
-- fails boot if an enabled one has no model in ServerStorage.Maps. Add a
-- 12th map the same way as a task: one file, nothing else to touch
-- (Ground Rule 2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.MapDef> }
