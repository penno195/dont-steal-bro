--!strict
-- Auto-collects every sibling store definition file (P4-5), exactly the
-- way Config/PowerUps and Config/Titles do. Adding a product to the
-- store is adding one file next to this one - no service edit, no
-- registration list, nothing here to touch (Ground Rule 2).
--
-- EVERY ENTRY SHIPS `enabled = false` AND `assetId = 0` until somebody
-- creates the matching pass or developer product in the Creator
-- Dashboard and pastes its id in. That isn't a placeholder in the usual
-- sense - it's the safe half of a two-step: the catalogue, its grants
-- and its validation are real and testable now, and the moment a real
-- id exists the entry flips on with a one-line edit. ConfigValidator
-- refuses to boot a server with an enabled entry that still has no id.
--
-- This registry is safe in ReplicatedStorage: it is the SHOP WINDOW,
-- and a shop window is public by definition. What a client can read
-- here is what each product costs and what it says it grants - it has
-- no bearing on what the server actually hands over, which is decided
-- server-side from this same table after Roblox confirms a purchase.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.StoreItemDef> }
