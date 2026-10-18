--!strict
-- Auto-collects every sibling daily-challenge file (payoff-loop step 8),
-- the way Config/Events does. A new challenge is one file here, nothing
-- else to touch (Ground Rule 2). DailyChallengeLogic draws each player's
-- three a day from the enabled ones.
--
-- Win needed?  File               Line
--   no         PlayRounds         Play 3 rounds
--   no         FinishTasks        Finish 15 tasks
--   no         ReachStudio        Reach the Studio twice
--   no         CrossFirst         Cross the line first
--   no         LandHits           Land 5 power-ups on rivals
--   no         FreezePlayers      Freeze 5 players
--   no         BlindPlayers       Blind 3 players
--   yes        WinRound           Win a round
--   yes        ShareAndSurvive    Share and survive
--
-- Validate.run needs at least picksPerDay + rerollsPerDay enabled ones
-- that don't need a win. Every amount is PLACEHOLDER until a playtest.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.DailyChallengeDef> }
