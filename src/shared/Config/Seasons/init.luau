--!strict
-- Auto-collects every sibling season file (rewards-roadmap.md step 5),
-- the way Config/Store and Config/Cosmetics do. A new season is one file
-- here plus its pass in Config/Store/.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.SeasonDef> }
