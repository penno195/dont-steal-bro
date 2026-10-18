--!strict
-- Auto-collects every sibling lifetime title (payoff-loop step 9): titles
-- for counts that only ever climb, so a player who never holds a long
-- streak still has a ladder to climb. A new one is one file here, nothing
-- else to touch (Ground Rule 2). Owner, 2026-10-18 (design-decisions.md
-- Q1): they share the one equipped slot with the streak ladder, a player
-- who hasn't picked one still wears their top streak rung, and they are
-- hidden during a round like every title (Q7).
--
--   Wins             Studio visits       Steals that won
--   10   Seen It Before   10   Finalist         1    Sticky Fingers
--   50   Veteran          50   Studio Regular   10   Repeat Offender
--   100  Lifer            150  Knows The Way    50   Wanted
--   250  No Life          400  Has A Keycard    150  Career Criminal
--   500  Furniture        1000 Lives Here       400  Bro Stole
--   1000 Part Of The Map
--
-- Same voice as the streak ladder: flat, never congratulating. Each
-- ladder has its own colour family (gold, blue, red) so the kind reads at
-- a glance. Every name and threshold is PLACEHOLDER until a playtest.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.LifetimeTitleDef> }
