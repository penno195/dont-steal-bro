--!strict
-- The round state machine's pure half (P2-1): the state enum, the
-- transition table as DATA (not branching code, per the task's own
-- requirement), and the exactly-once exit guard. Self-contained on
-- purpose - no requires of sibling files, no Roblox API calls anywhere -
-- so it stays requirable under Lune for headless tests (tests/
-- RoundStates.spec.luau), the same shape as Net.luau (P1-3), Validate.
-- luau (P1-4) and ProfileLogic.luau (P1-5) and for the same reason.
--
-- RoundService.luau (src/server/Services/RoundService.luau) is what
-- actually enforces this table against a real server: Signals, timers,
-- replication, the debug interface. This file only answers "is this
-- transition legal," never touches a clock, and never fires anything.

local RoundStates = {}

export type RoundState =
	"WaitingForPlayers"
	| "Loading"
	| "Intro"
	| "Race"
	| "Qualified"
	| "DecisionStudio"
	| "Results"
	| "Cleanup"

RoundStates.ALL = {
	"WaitingForPlayers",
	"Loading",
	"Intro",
	"Race",
	"Qualified",
	"DecisionStudio",
	"Results",
	"Cleanup",
} :: { RoundState }

-- architecture.md §3's round state machine, verbatim: a strict linear
-- pipeline with no loop-back. A match server runs exactly one round then
-- ends - design-decisions.md Q6 ("progress to the next round" is a fresh
-- requeue, never a same-server continuation) is why `Cleanup` has no
-- legal transitions out of it. Every other state has exactly one legal
-- next state; kept as a list (not a single field) so a future branch
-- (e.g. an abort path) is additive, not a type change.
local TRANSITIONS: { [RoundState]: { RoundState } } = {
	WaitingForPlayers = { "Loading" },
	Loading = { "Intro" },
	Intro = { "Race" },
	Race = { "Qualified" },
	Qualified = { "DecisionStudio" },
	DecisionStudio = { "Results" },
	Results = { "Cleanup" },
	Cleanup = {},
}

-- Pure: is `to` a legal next state from `from`, per the table above?
function RoundStates.isLegalTransition(from: RoundState, to: RoundState): boolean
	return table.find(TRANSITIONS[from], to) ~= nil
end

-- Pure: the legal next states from `from` (0 or 1 entries today, but
-- returned as a list - see the comment on TRANSITIONS above for why).
function RoundStates.legalNextStates(from: RoundState): { RoundState }
	return TRANSITIONS[from]
end

-- Pure: runs `action` exactly once. "A guard that a state's exit always
-- runs exactly once, even when it is triggered by both a timer and a
-- condition in the same frame" (P2-1's own requirement) - `alreadyRan`
-- reflects the caller's own per-state bookkeeping; returns whether this
-- call actually ran `action`. Same shape as ProfileLogic.release's
-- double-release guard (P1-5), because it's the same problem: two
-- triggers for what should be one event.
function RoundStates.runOnce(alreadyRan: boolean, action: () -> ()): boolean
	if alreadyRan then
		return false
	end
	action()
	return true
end

return RoundStates
