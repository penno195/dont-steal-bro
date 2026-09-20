--!strict
-- Auto-collects every sibling title definition file. Empty for now - no
-- title ladder content has been designed yet, only the mechanic (gdd.md
-- §3: titles key off a profile's bestStreak and are never revoked). Add
-- a title the same way as a task: one file, nothing else to touch
-- (Ground Rule 2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.TitleDef> }
