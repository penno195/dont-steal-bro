--!strict
-- Auto-collects every sibling NPC personality file (P3-6). The three in
-- architecture.md §4 - Greedy, Loyal, Chaotic - are here; add a fourth
-- the same way as a task or a power-up: one file, nothing else to touch
-- (Ground Rule 2). NPCBrain picks one per bot by weight and never names
-- a personality in its own code.
--
-- ===== THE RULE FOR WRITING A LINE ======================================
--
-- A line must never state a fact only the server knows. That is a real
-- secrecy constraint, not a style note: these bots sit in the Decision
-- Studio alongside human finalists during Negotiate, and a bot that
-- said "he's locked in already" or "you've got a 4 streak" would be
-- leaking server state into a room whose entire design (see
-- DecisionService.luau's secrecy audit) is built on nobody knowing
-- anything they couldn't observe.
--
-- A line may only ever refer to:
--   * what the bot itself intends or claims to intend (it may lie)
--   * what anyone in the room can see - who is talking, who is silent,
--     how much time is left on the visible clock
--
-- A line may NEVER refer to:
--   * another finalist's choice, locked or not
--   * whether anyone has locked in
--   * any streak, bounty figure, profile stat or steal/share history
--   * anything from the race that isn't visible in the Studio
--
-- No validator can check this - it's a semantic property of English, so
-- it's enforced at review time. Read the rule before adding a line.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.NPCPersonalityDef> }
