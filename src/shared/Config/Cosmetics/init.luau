--!strict
-- Auto-collects every sibling cosmetic definition file (P4-6), exactly the
-- way Config/Store and Config/Titles do. Adding a skin, trail, emote or
-- podium flair is adding one file next to this one - no service edit, no
-- registration list, nothing here to touch (Ground Rule 2).
--
-- Every cosmetic is granted by a Store product, never sold directly by
-- this registry - see Validate.CosmeticDef's own header comment for why
-- pricing lives on the StoreItemDef that names this item's `id`, not here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.CosmeticDef> }
