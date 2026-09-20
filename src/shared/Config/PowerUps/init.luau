--!strict
-- Auto-collects every sibling power-up definition file. Empty for now -
-- docs/powerups.md catalogues all 10, but none has been ported to a real
-- PowerUpDef file yet (that's P2-7's job, alongside the handler that
-- gives each one its actual effect). Add an 11th the same way as a task:
-- one file, nothing else to touch (Ground Rule 2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.PowerUpDef> }
