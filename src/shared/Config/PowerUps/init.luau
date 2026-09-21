--!strict
-- Auto-collects every sibling power-up definition file. All 10 of
-- docs/powerups.md's catalogue are ported here as of P2-7 - the actual
-- EFFECT each one applies (speed changes, immobilize, vision, etc) is
-- P2-8's job (Status Effects), not this registry's. Add an 11th the same
-- way as a task: one file, nothing else to touch (Ground Rule 2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.PowerUpDef> }
