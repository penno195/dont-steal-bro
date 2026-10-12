--!strict
-- Auto-collects every sibling event file (staff-tools.md step 5), the
-- way Config/Seasons does. A new event is one file here plus its view in
-- src/client/EventViews/.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.EventDef> }
