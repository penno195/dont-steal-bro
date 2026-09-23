--!strict
-- The sole place every remote in the game is declared (architecture.md
-- §"folder skeleton"). See src/server/Services/NetGuard.luau for how a
-- ServerIntent declaration here actually gets enforced against a fully
-- compromised client (Ground Rule 1) before any real handler sees it.
--
-- WHY THE TOP OF THIS FILE NEVER TOUCHES `game`:
-- schema validation, the rate limiter and the round-state gate are pure
-- logic - no Roblox API calls - so this file can be required directly
-- under Lune and unit-tested headlessly (Ground Rule 4, tests/Net.spec.
-- luau). Only the functions in the "Roblox-touching helpers" section at
-- the bottom read `game`, and only when actually called at runtime.
--
-- ADDING A NEW REMOTE, IN FIVE LINES:
--   MyRemote = {
--       name = "MyRemote",
--       direction = "ServerIntent",
--       schema = Net.struct({ targetUserId = Net.number({ min = 1, integer = true }) }),
--       rateLimit = { capacity = 5, refillPerSecond = 1 },
--       states = { "Race" }, -- or nil to allow it in every round state
--   } :: RemoteDef,
-- Nothing else to touch: NetGuard creates the RemoteEvent, validates,
-- rate-limits and state-gates it automatically because it walks this
-- table - see Ground Rule 2.

local Net = {}

-- ===== Schema: pure runtime payload validation ======================
--
-- Luau has no runtime reflection of a `type` declaration, so there's no
-- way to generate a validator FROM a static type automatically. Instead
-- each schema built below IS the runtime source of truth, and `T` makes
-- a successful validate() call hand back a value actually narrowed to
-- that type (rather than the `any` it started as) - so a caller past
-- NetGuard gets real typing on the payload without a second, hand-
-- written type declaration that could drift out of sync with this one.

export type Schema<T> = {
	-- On success: true, the value narrowed to T, nil.
	-- On failure: false, nil, a human-readable reason. Never throws -
	-- a hostile payload is the expected case here, not an exceptional
	-- one.
	validate: (value: any) -> (boolean, T?, string?),
}

function Net.number(opts: { min: number?, max: number?, integer: boolean? }?): Schema<number>
	local min = if opts then opts.min else nil
	local max = if opts then opts.max else nil
	local integer = if opts then opts.integer else nil

	return {
		validate = function(value: any): (boolean, number?, string?)
			if type(value) ~= "number" then
				return false, nil, string.format("expected a number, got %s", type(value))
			end
			if value ~= value then
				return false, nil, "expected a number, got NaN"
			end
			if integer and value % 1 ~= 0 then
				return false, nil, string.format("expected an integer, got %s", tostring(value))
			end
			if min ~= nil and value < min then
				return false, nil, string.format("expected >= %s, got %s", tostring(min), tostring(value))
			end
			if max ~= nil and value > max then
				return false, nil, string.format("expected <= %s, got %s", tostring(max), tostring(value))
			end
			return true, value, nil
		end,
	}
end

-- Bounded-length free text - `stationId`/task ids and the like, where
-- `stringEnum` (a closed set) doesn't fit but an UNBOUNDED string would
-- let a hostile payload carry an arbitrarily large string through a
-- remote that otherwise looks well-formed (a bandwidth/memory abuse
-- vector, not just a style nit) - `maxLength` defaults to a conservative
-- 64 for exactly that reason, so a new call site has to opt INTO a
-- longer bound rather than silently getting an unbounded one.
function Net.string(opts: { minLength: number?, maxLength: number? }?): Schema<string>
	local minLength = if opts and opts.minLength then opts.minLength else 1
	local maxLength = if opts and opts.maxLength then opts.maxLength else 64

	return {
		validate = function(value: any): (boolean, string?, string?)
			if type(value) ~= "string" then
				return false, nil, string.format("expected a string, got %s", type(value))
			end
			local length = #(value :: string)
			if length < minLength then
				return false, nil, string.format("expected length >= %d, got %d", minLength, length)
			end
			if length > maxLength then
				return false, nil, string.format("expected length <= %d, got %d", maxLength, length)
			end
			return true, value, nil
		end,
	}
end

function Net.boolean(): Schema<boolean>
	return {
		validate = function(value: any): (boolean, boolean?, string?)
			if type(value) ~= "boolean" then
				return false, nil, string.format("expected a boolean, got %s", type(value))
			end
			return true, value, nil
		end,
	}
end

-- Wraps another schema to also accept a MISSING field - a Lua table has
-- no way to store an explicit nil under a key distinct from the key
-- simply being absent, so "the client omitted this field" and "the
-- client sent nil" are the same case here, and this is what lets
-- Net.struct declare a genuinely optional field (P2-7's PowerUpUseIntent:
-- a target hint the client may or may not send) rather than every field
-- being required.
function Net.optional<T>(schema: Schema<T>): Schema<T?>
	return {
		validate = function(value: any): (boolean, T?, string?)
			if value == nil then
				return true, nil, nil
			end
			return schema.validate(value)
		end,
	}
end

function Net.stringEnum(values: { string }): Schema<string>
	return {
		validate = function(value: any): (boolean, string?, string?)
			if type(value) ~= "string" then
				return false, nil, string.format("expected a string, got %s", type(value))
			end
			if table.find(values, value) == nil then
				return false, nil, string.format("expected one of [%s], got %q", table.concat(values, ", "), value)
			end
			return true, value, nil
		end,
	}
end

-- Exact-match struct: every declared field must validate, and any field
-- NOT declared is rejected outright. That second half is deliberate and
-- load-bearing - it's what stops a spoofed extra field from riding along
-- on an otherwise well-formed payload (see tests/Net.spec.luau).
function Net.struct(fields: { [string]: Schema<any> }): Schema<{ [string]: any }>
	return {
		validate = function(value: any): (boolean, { [string]: any }?, string?)
			if type(value) ~= "table" then
				return false, nil, string.format("expected a table, got %s", type(value))
			end

			local payload = value :: { [string]: any }

			for key in payload do
				if type(key) ~= "string" or fields[key :: string] == nil then
					return false, nil, string.format("unexpected field %q", tostring(key))
				end
			end

			for key, fieldSchema in fields do
				local ok, _fieldValue, err = fieldSchema.validate(payload[key])
				if not ok then
					return false, nil, string.format("field %q: %s", key, err or "invalid")
				end
			end

			return true, payload, nil
		end,
	}
end

-- Rough size estimate for structural logging ("payload, size N") - not a
-- serializer, and never used for anything that needs to be exact. Any
-- value shape a schema wouldn't already have rejected (a function, an
-- Instance) just gets counted by its type name and moved past; this
-- exists for an analytics log line, not correctness.
function Net.estimatePayloadSize(value: any): number
	local t = type(value)
	if t == "string" then
		return #(value :: string)
	elseif t == "number" then
		return 8
	elseif t == "boolean" then
		return 1
	elseif t == "nil" then
		return 0
	elseif t == "table" then
		local total = 0
		for key, entry in value :: { [any]: any } do
			total += Net.estimatePayloadSize(key) + Net.estimatePayloadSize(entry)
		end
		return total
	else
		return #t
	end
end

-- ===== Rate limiting: pure token bucket ==============================

export type RateLimit = {
	capacity: number, -- max burst
	refillPerSecond: number, -- steady-state calls/sec
}

export type RateLimiterState = {
	tokens: number,
	lastRefillAt: number,
	capacity: number,
	refillPerSecond: number,
}

function Net.newRateLimiterState(rateLimit: RateLimit, now: number): RateLimiterState
	return {
		tokens = rateLimit.capacity,
		lastRefillAt = now,
		capacity = rateLimit.capacity,
		refillPerSecond = rateLimit.refillPerSecond,
	}
end

-- Pure: takes `now` as an argument instead of reading a clock itself, so
-- it's deterministic and testable without waiting on a real clock (see
-- tests/Net.spec.luau). Mutates and returns the same state table.
function Net.tryConsume(state: RateLimiterState, now: number, cost: number?): boolean
	local elapsed = math.max(0, now - state.lastRefillAt)
	state.tokens = math.min(state.capacity, state.tokens + elapsed * state.refillPerSecond)
	state.lastRefillAt = now

	local actualCost = cost or 1
	if state.tokens >= actualCost then
		state.tokens -= actualCost
		return true
	end

	return false
end

-- ===== Escalation: pure violation tracking ===========================
--
-- The token bucket above IS the "throttle" stage (a rejected call just
-- keeps getting dropped). This tracks a SEPARATE, coarser signal across
-- every kind of rejection (bad shape, wrong state, AND rate limit) so a
-- player who keeps hammering different failure modes to probe the guard
-- still gets flagged, not just one who floods a single remote.

export type ViolationTracker = {
	count: number,
	windowStartedAt: number,
}

function Net.newViolationTracker(now: number): ViolationTracker
	return { count = 0, windowStartedAt = now }
end

-- Pure: records one violation at time `now`. Returns true exactly once
-- per window the count reaches `threshold` - not on every violation
-- after that - so a flag handler wired up downstream fires once per
-- burst instead of once per rejected call.
function Net.recordViolation(tracker: ViolationTracker, now: number, windowSeconds: number, threshold: number): boolean
	if now - tracker.windowStartedAt > windowSeconds then
		tracker.windowStartedAt = now
		tracker.count = 0
	end

	tracker.count += 1
	return tracker.count == threshold
end

-- ===== Remote declarations ===========================================

export type RemoteDirection =
	"ServerIntent" -- client -> server: validated, rate-limited, state-gated
	| "ServerBroadcast" -- server -> client: trusted sender, no guard needed

export type RemoteDef = {
	name: string,
	direction: RemoteDirection,
	schema: Schema<any>?, -- required for ServerIntent; unused for ServerBroadcast
	rateLimit: RateLimit?, -- required for ServerIntent; unused for ServerBroadcast
	states: { string }?, -- nil = valid in every round state
}

-- Pure: does this remote's declared `states` allow `currentState`? A
-- gated remote whose current state is unknown (no RoundService wired up
-- to NetGuard yet, or a state name that's stale) fails CLOSED, not open
-- - an unrecognised state is never treated as "good enough."
function Net.isStateAllowed(def: RemoteDef, currentState: string?): boolean
	if def.states == nil then
		return true
	end
	if currentState == nil then
		return false
	end
	return table.find(def.states :: { string }, currentState) ~= nil
end

-- P2-1's RoundService remotes - the first real ones (ExamplePing, the
-- placeholder that used to live here, is deleted per its own "delete
-- once a real ServerIntent remote exists" comment).
Net.Remotes = {
	-- Server -> client: the round state machine's entire replicated
	-- payload (RoundService.luau, P2-1) - a state name plus an absolute
	-- end time from workspace:GetServerTimeNow(). No schema: the sender
	-- is always the server, trusted by definition for a ServerBroadcast
	-- remote (see RemoteDirection above).
	RoundState = {
		name = "RoundState",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- Client -> server: forces any round transition, bypassing the
	-- normal legality table - RoundService's debug interface (P2-1's own
	-- requirement: "I will need this constantly to test the Decision
	-- Studio"). No `states` gate on purpose: a debug override has to work
	-- from every round state, not just some of them. The real gate is
	-- inside RoundService's own handler, which checks RunService:
	-- IsStudio() or a developer-id allowlist before honouring it -
	-- NetGuard only proves the shape and throttles the call rate.
	DebugForceRoundState = {
		name = "DebugForceRoundState",
		direction = "ServerIntent",
		schema = Net.struct({
			state = Net.stringEnum({
				"WaitingForPlayers",
				"Loading",
				"Intro",
				"Race",
				"Qualified",
				"DecisionStudio",
				"Results",
				"Cleanup",
			}),
		}),
		rateLimit = { capacity = 3, refillPerSecond = 0.2 },
		states = nil,
	} :: RemoteDef,

	-- P2-4's TaskService remotes - both server -> client, both trusted
	-- senders, so ServerBroadcast/no schema, same as RoundState above.

	-- The minimal HUD payload: just enough for a live standings display
	-- (who's on how many tasks) - never a per-station breakdown, and
	-- never on a per-second tick (architecture.md §3) - this fires once
	-- per real completion event instead.
	TaskProgress = {
		name = "TaskProgress",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- The richer results-screen payload: TaskService's full Qualification.
	-- QualificationResult (ranked list, tie-break reasons, qualifiers,
	-- the 4th-place alternate for design-decisions.md Q3) - fired once,
	-- the moment qualification is actually decided (either the first 3
	-- finishers, or the hard round timer per Q2).
	TaskQualificationResult = {
		name = "TaskQualificationResult",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- P3-5: the round's NPC roster - {id, displayName} per bot, broadcast
	-- once they've been spawned. It exists because every id-carrying
	-- payload above (TaskProgress's `playerId`, the qualification
	-- result's ranked ids) can now carry a NEGATIVE id, which no client
	-- can resolve through Players:GetPlayerByUserId - this is how a HUD
	-- puts a name to one. Nothing secret: the bots are standing in the
	-- map in plain sight, and a client already sees their rigs.
	NPCRoster = {
		name = "NPCRoster",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- P3-6: one NPC bubble-chat line, decided server-side and rendered by
	-- NPCBubbleController. It's a broadcast rather than a server-side
	-- call because TextChatService:DisplayBubble is a CLIENT method -
	-- the server can decide a bubble should appear but can't make one.
	--
	-- Carries only {npcId, message}, and the message is always a string
	-- the server picked out of config: a client can neither influence
	-- what a bot says nor learn anything from it that the room can't
	-- already see (see NPCPersonalities/init.luau's line rule).
	NPCChatBubble = {
		name = "NPCChatBubble",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- P2-5's task-interaction remotes - see src/server/TaskHandlers/
	-- Types.luau for the framework these plug into. TaskInteract is the
	-- one remote every task's client view shares to start (or restart) a
	-- challenge; TaskChallenge/TaskResult are ALSO shared, but critically
	-- are fired with Net.fireClient (never fireAllClients) since a
	-- challenge payload is that one player's private secret - see
	-- TaskHandlerService.luau's own header comment for the exploit this
	-- prevents. A per-task submission remote (e.g. KeypadDigitSubmit
	-- below) is the one part of this that ISN'T shared - each task's
	-- input shape is genuinely different, and that's fine: declaring one
	-- more remote here is adding a config-like entry, not a service edit
	-- (Ground Rule 2).

	TaskInteract = {
		name = "TaskInteract",
		direction = "ServerIntent",
		schema = Net.struct({ stationId = Net.string({ maxLength = 64 }) }),
		rateLimit = { capacity = 5, refillPerSecond = 1 },
		states = { "Race" },
	} :: RemoteDef,

	TaskChallenge = {
		name = "TaskChallenge",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	TaskResult = {
		name = "TaskResult",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- CodePlayback's (the P2-5 reference task) own submission remote: one
	-- digit tap per call, against the server's privately-held code - see
	-- src/server/TaskHandlers/CodePlayback.luau. Generous rate limit
	-- (real rapid tapping shouldn't get throttled) but still bounded.
	KeypadDigitSubmit = {
		name = "KeypadDigitSubmit",
		direction = "ServerIntent",
		schema = Net.struct({
			stationId = Net.string({ maxLength = 64 }),
			digit = Net.number({ min = 0, max = 9, integer = true }),
		}),
		rateLimit = { capacity = 10, refillPerSecond = 5 },
		states = { "Race" },
	} :: RemoteDef,

	-- PressureValve's (P2-6's Tap reference task) own submission remote:
	-- one tap per call, no payload beyond which station - the server
	-- privately holds the rolled target count and does its own min-
	-- interval enforcement (src/server/TaskHandlers/PressureValve.luau).
	-- Rate limit set comfortably above the server's own ~70ms min tap
	-- interval (~14/s) so a legitimate fast tapper is never the one
	-- throttled - only an actual flood is.
	TapSubmit = {
		name = "TapSubmit",
		direction = "ServerIntent",
		schema = Net.struct({ stationId = Net.string({ maxLength = 64 }) }),
		rateLimit = { capacity = 20, refillPerSecond = 20 },
		states = { "Race" },
	} :: RemoteDef,

	-- FuseRewire's (P2-6's Drag reference task) own submission remote:
	-- one (fuseId, slotId) drop per call - the server privately holds the
	-- correct mapping (src/server/TaskHandlers/FuseRewire.luau); this
	-- payload alone never reveals it, right or wrong.
	FuseDropSubmit = {
		name = "FuseDropSubmit",
		direction = "ServerIntent",
		schema = Net.struct({
			stationId = Net.string({ maxLength = 64 }),
			fuseId = Net.string({ maxLength = 32 }),
			slotId = Net.string({ maxLength = 32 }),
		}),
		rateLimit = { capacity = 10, refillPerSecond = 3 },
		states = { "Race" },
	} :: RemoteDef,

	-- P2-7's power-up remotes. Note what's deliberately NOT in
	-- PowerUpUseIntent's payload: no powerUpId (the server already knows
	-- what's in the player's own inventory slot) and no effect of any
	-- kind - "a use-intent remote carrying only the target hint, never
	-- the effect" (the task's own requirement, verbatim). See
	-- PowerUpService.luau's own header comment for the full exploit
	-- list this shape closes off.
	PowerUpUseIntent = {
		name = "PowerUpUseIntent",
		direction = "ServerIntent",
		schema = Net.struct({
			slotIndex = Net.optional(Net.number({ min = 1, integer = true })),
			targetPlayerId = Net.optional(Net.number({ min = 1, integer = true })),
		}),
		rateLimit = { capacity = 5, refillPerSecond = 1 },
		states = { "Race" },
	} :: RemoteDef,

	-- Server -> client (targeted, never fireAllClients - see
	-- PowerUpService.luau): a player's own current inventory, for HUD
	-- display.
	PowerUpInventoryChanged = {
		name = "PowerUpInventoryChanged",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- Server -> client (targeted at the USER only): confirms what a use
	-- attempt actually did, including which target smart-targeting
	-- picked - "returns which one it chose so the UI can confirm it"
	-- (the task's own requirement). Cross-player visual feedback for an
	-- applied effect is P2-8's job (Status Effects), not this remote's.
	PowerUpUseResult = {
		name = "PowerUpUseResult",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- P2-8's replication remotes. StatusEffectsChanged is targeted at the
	-- OWNING player only (fireClient - full detail, for HUD icons with
	-- real countdowns); StatusEffectsVisual is broadcast to everyone
	-- (fireAllClients - "a minimal version... for visual feedback," the
	-- task's own requirement) and deliberately carries only categories,
	-- never exact durations/magnitudes, so it can't be used to time a
	-- counter-play more precisely than a player could just by watching.
	StatusEffectsChanged = {
		name = "StatusEffectsChanged",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	StatusEffectsVisual = {
		name = "StatusEffectsVisual",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- P3-2's Decision Studio remotes. See DecisionService.luau's own
	-- header comment for the full secrecy audit - the short version:
	-- DecisionChooseIntent carries a choice INTO the server and nothing
	-- ever carries one back out except DecisionReveal, fired once, after
	-- every choice is already locked and irreversible.

	-- Server -> client (broadcast - every finalist AND every spectator
	-- needs the roster, design-decisions.md Q3's "up to 6 finalists
	-- teleport in together"): fired once when the Studio begins.
	DecisionParticipants = {
		name = "DecisionParticipants",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- P4-2's three title remotes.
	--
	-- TitleUnlocked is targeted at the one player who earned it
	-- (fireClient): it is the unlock MOMENT, and it carries the rung's
	-- own threshold, which is a streak number - broadcasting that would
	-- be the exact Q7 condition 1 leak the whole title-visibility rule
	-- exists to prevent.
	TitleUnlocked = {
		name = "TitleUnlocked",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- Server -> client (broadcast): who is currently WEARING what, for
	-- the nametags. Carries the title id, display text, colour and
	-- effect - never a threshold and never a streak, so the payload
	-- itself can't be mined for the number behind it.
	--
	-- The Q7 suppression is enforced HERE rather than on the client:
	-- while a round is live the server simply doesn't send other
	-- players' titles, so a modified client has nothing to un-hide
	-- (Ground Rule 1). See TitleService.broadcastTitles.
	TitleState = {
		name = "TitleState",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- Client -> server: equip a title, or unequip with a nil id. Rate
	-- limited because it writes to a profile, and validated against the
	-- player's own unlocked list server-side - a client naming a title
	-- it never earned is refused, not trusted.
	-- No `states` restriction: equipping is a menu action, and a player
	-- tidying their profile in the lobby, on the results screen, or
	-- while dead mid-race is all legitimate. What a title does NOT do is
	-- become visible mid-round, and that's enforced on the broadcast
	-- side, not by refusing the equip.
	TitleEquipIntent = {
		name = "TitleEquipIntent",
		direction = "ServerIntent",
		schema = Net.struct({ titleId = Net.optional(Net.string({ minLength = 1, maxLength = 64 })) }),
		rateLimit = { capacity = 5, refillPerSecond = 1 },
		states = nil,
	} :: RemoteDef,

	-- P4-3: the all-time board, broadcast from a server-side cache that
	-- refreshes once per server on a jittered 60-120s interval. Never
	-- fired in response to a client asking - P4-3 forbids reading on
	-- player demand or once per viewer, and there is no request remote
	-- here for a client to call.
	--
	-- `status` is the staleness indicator, and it travels WITH the
	-- entries rather than as its own event: a client that got the board
	-- and missed a separate "this is old" message would present stale
	-- numbers as current, which is worse than showing nothing.
	-- P4-4: one period board (daily or weekly), same contract as
	-- LeaderboardState - broadcast from a server-side cache, never in
	-- response to a client, with the staleness status travelling
	-- alongside the entries. `periodKey` is included so a client can
	-- tell "today's board" from "yesterday's, not yet refreshed."
	PeriodBoardState = {
		name = "PeriodBoardState",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	LeaderboardState = {
		name = "LeaderboardState",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- P4-1: this round didn't move your streak, and here is why.
	-- Targeted at the one player it concerns (fireClient), never
	-- broadcast - design-decisions.md Q7 condition 1 keeps streak off
	-- every in-round surface, and telling the whole server that someone
	-- just failed to gain a streak leaks the same signal by implication.
	--
	-- threat-model.md §8 requires this to exist: an NPC-heavy round
	-- earns no streak credit, and "needs an explicit 'queue too thin for
	-- streak credit right now' message, not silent non-progression."
	-- Carries the seat count and the threshold so a results screen can
	-- say something specific rather than something vague.
	ProgressionStreakSkipped = {
		name = "ProgressionStreakSkipped",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- P3-7: a finalist's seat changed. Two reasons, both broadcast to
	-- everyone in the room because everyone needs to know who they're
	-- actually negotiating with:
	--   "Withdrawn" - they left before the Studio started, and
	--     `replacedById` is the promoted alternate (nil = the seat is
	--     simply gone and the finale runs smaller).
	--   "Forfeited" - they left mid-Studio. Their seat stays and votes
	--     the configured default (design-decisions.md Q4), so
	--     `replacedById` is always nil here.
	--
	-- Carries no choice and no streak - "who is still in the room" is
	-- visible to everyone anyway, and this remote deliberately adds
	-- nothing to it. The secrecy audit at the top of DecisionService
	-- covers this payload too.
	DecisionRosterChange = {
		name = "DecisionRosterChange",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- Server -> client (broadcast): the inner phase machine's own state -
	-- a name plus an absolute deadline, the same shape RoundState uses
	-- and for the same reason (architecture.md §3: clients compute their
	-- own countdowns, no per-second remote).
	DecisionPhaseChanged = {
		name = "DecisionPhaseChanged",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- Server -> client (broadcast): "when someone locks in, broadcast
	-- only that they locked in, never what they chose" (the task's own
	-- requirement, verbatim) - this payload is ONLY ever {playerId}.
	DecisionLockedIn = {
		name = "DecisionLockedIn",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- Client -> server: a qualifier's Steal/Share submission during
	-- Choose. Gated to the "DecisionStudio" ROUND state here (NetGuard's
	-- own coarse gate); DecisionService's own handler checks the FINER
	-- "is it actually the Choose PHASE right now" itself, since NetGuard
	-- has no notion of an inner phase machine.
	DecisionChooseIntent = {
		name = "DecisionChooseIntent",
		direction = "ServerIntent",
		schema = Net.struct({ choice = Net.stringEnum({ "Steal", "Share" }) }),
		rateLimit = { capacity = 3, refillPerSecond = 0.5 },
		states = { "DecisionStudio" },
	} :: RemoteDef,

	-- Server -> client (broadcast): every choice and the computed
	-- outcome, fired exactly once, only after every choice is already
	-- locked (or defaulted) and the profile writes have already
	-- happened - see DecisionService.luau's own resolution-order
	-- comment. `revealAt` is a shared absolute timestamp so all clients
	-- animate the reveal in sync regardless of when each one's copy of
	-- this event actually finished replicating.
	DecisionReveal = {
		name = "DecisionReveal",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- Client -> server: RoundService's DebugForceRoundState's own
	-- pattern, verbatim - no `states` gate (a debug override has to work
	-- from any phase), the real gate is inside DecisionService's own
	-- handler (Studio or a developer-id allowlist).
	DecisionDebugForceOutcome = {
		name = "DecisionDebugForceOutcome",
		direction = "ServerIntent",
		schema = Net.struct({
			branch = Net.stringEnum({ "SoleSteal", "LoneShare", "AllShare", "AllSteal" }),
		}),
		rateLimit = { capacity = 3, refillPerSecond = 0.2 },
		states = nil,
	} :: RemoteDef,

	-- ===== P4-5's store remotes ==========================================
	--
	-- What is deliberately ABSENT from every payload below: a price, an
	-- item's contents, a quantity, and any notion of "grant me this."
	-- A client can ask the server to OPEN a Roblox purchase prompt, and
	-- it can ask to rearrange things it already owns. Everything that
	-- costs money is decided by Roblox and confirmed to the server
	-- through MarketplaceService.ProcessReceipt, which no client can
	-- reach or forge - see StoreService.luau's own threat notes.

	-- Client -> server: "open the Roblox purchase prompt for this
	-- catalogue entry." Carries a `key` (the internal id from
	-- Config/Store), never a Roblox assetId - so a client cannot aim
	-- the prompt at an arbitrary asset, only at something this game
	-- actually sells and has enabled.
	--
	-- No `states` gate: buying is a menu action, and the store is
	-- reachable from the hub, the results screen, and the lobby. What a
	-- purchase must never do is take effect mid-race, and that is
	-- enforced where the loadout is spent (at Race entry), not by
	-- refusing the sale.
	StorePurchaseIntent = {
		name = "StorePurchaseIntent",
		direction = "ServerIntent",
		schema = Net.struct({ key = Net.string({ minLength = 1, maxLength = 64 }) }),
		rateLimit = { capacity = 4, refillPerSecond = 0.5 },
		states = nil,
	} :: RemoteDef,

	-- Client -> server: set one loadout slot, or clear it with a nil
	-- powerUpId. One slot per call rather than the whole list, which
	-- keeps the payload a fixed shape (no array schema needed), makes
	-- the rate limit meaningful per edit, and means a rejected slot
	-- rejects only itself.
	--
	-- The 3-slot cap is NOT expressed as a max on `slotIndex` here.
	-- It's validated server-side against GameConfig.store.loadoutSlots
	-- (StoreLogic.setLoadoutSlot), so the cap lives in one place that
	-- design-decisions.md Q8 pins, rather than being half-stated in a
	-- schema that would silently disagree if the config ever changed.
	StoreLoadoutIntent = {
		name = "StoreLoadoutIntent",
		direction = "ServerIntent",
		schema = Net.struct({
			slotIndex = Net.number({ min = 1, max = 16, integer = true }),
			powerUpId = Net.optional(Net.string({ minLength = 1, maxLength = 64 })),
		}),
		rateLimit = { capacity = 6, refillPerSecond = 1 },
		states = nil,
	} :: RemoteDef,

	-- Client -> server: equip a cosmetic into a slot, or unequip with a
	-- nil itemId. Validated against the player's own owned list
	-- server-side - a client naming a cosmetic it never bought is
	-- refused, not trusted (Ground Rule 1). P4-6 owns what the item
	-- then LOOKS like; this remote only moves the state.
	StoreEquipIntent = {
		name = "StoreEquipIntent",
		direction = "ServerIntent",
		schema = Net.struct({
			slot = Net.string({ minLength = 1, maxLength = 32 }),
			itemId = Net.optional(Net.string({ minLength = 1, maxLength = 64 })),
		}),
		rateLimit = { capacity = 6, refillPerSecond = 1 },
		states = nil,
	} :: RemoteDef,

	-- Server -> client (targeted at the owner only, never
	-- fireAllClients): this player's own store state - currency,
	-- power-up stock, loadout, owned cosmetics, equipped slots, and
	-- which game passes they own. Targeted because it is a private
	-- inventory: what someone else bought is nobody's business, and
	-- broadcasting it would also hand a modified client a free census
	-- of who is worth something.
	StoreState = {
		name = "StoreState",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- Server -> client (targeted): what happened to a purchase attempt.
	-- Carries a machine-readable `status` plus a `message` the UI can
	-- show verbatim, because P4-5 asks for "a clear error path for a
	-- failed purchase" and a store screen that can only say "something
	-- went wrong" generates the support tickets this task exists to
	-- make answerable.
	--
	-- Note what this remote is NOT: it is not how a grant is delivered.
	-- A grant lands in the profile via ProcessReceipt and is replicated
	-- by StoreState above. This is a UI notification, and a client that
	-- never receives it is still paid.
	StorePurchaseResult = {
		name = "StorePurchaseResult",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- P3-3's typing-indicator remotes. No remote exists for "speaking" -
	-- that's read directly off AudioDeviceInput.Active, a replicated
	-- property, with no server relay needed at all (see StudioChat.luau's
	-- own header comment).

	-- Client -> server: "I'm typing, right now, in the Negotiate
	-- channel." No text, no channel name (the server already knows which
	-- channel is live) - just a bare ping the sender's own client-side
	-- throttling already keeps infrequent.
	StudioChatTypingIntent = {
		name = "StudioChatTypingIntent",
		direction = "ServerIntent",
		schema = Net.struct({}),
		rateLimit = { capacity = 3, refillPerSecond = 1 },
		states = { "DecisionStudio" },
	} :: RemoteDef,

	-- Server -> client (targeted at the OTHER finalists only, never
	-- fireAllClients): "this playerId is typing right now." The
	-- receiving client owns its own display expiry (see
	-- StudioChatController.luau) - this fires once per intent, not on a
	-- timer.
	StudioChatTypingStatus = {
		name = "StudioChatTypingStatus",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- P5-1's matchmaking remotes. Both intents are bare: everything a
	-- queue entry holds (streak, enqueue time, who to avoid) comes from
	-- the server's own profile and MemoryStore, never the client. No
	-- `states` gate, because the hub has no round state.
	-- MatchmakingService refuses both outside the hub place instead.
	QueueJoinIntent = {
		name = "QueueJoinIntent",
		direction = "ServerIntent",
		schema = Net.struct({}),
		rateLimit = { capacity = 3, refillPerSecond = 0.5 },
		states = nil,
	} :: RemoteDef,

	QueueLeaveIntent = {
		name = "QueueLeaveIntent",
		direction = "ServerIntent",
		schema = Net.struct({}),
		rateLimit = { capacity = 3, refillPerSecond = 0.5 },
		states = nil,
	} :: RemoteDef,

	-- Server -> client, sent to that player only: their own queue status
	-- (Idle / Joining / Waiting with position, size and an estimated wait /
	-- MatchFound / Travelling (P5-2) / Unavailable, plus a message). Never includes who else
	-- is queued or anyone's streak (design-decisions.md Q7).
	QueueState = {
		name = "QueueState",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,

	-- P5-3's map vote. The client names only a map id. Which group,
	-- which ballot and whose vote it is all come from the server's own
	-- record of the sender (VoteService), so a vote for another group,
	-- another player or an off-ballot map has nothing to attach to. The
	-- bucket allows changing your mind a few times without letting a
	-- client hammer MemoryStore with compare-and-sets.
	MapVoteIntent = {
		name = "MapVoteIntent",
		direction = "ServerIntent",
		schema = Net.struct({ mapId = Net.string({ minLength = 1, maxLength = 64 }) }),
		rateLimit = { capacity = 4, refillPerSecond = 1 },
		states = nil,
	} :: RemoteDef,

	-- Server -> client, sent to one group member at a time: the board
	-- (VoteLogic.BoardState - map ids, counts, voter userIds from their
	-- own group, seconds left, their own vote, and once locked the winner
	-- and whether a tie was broken at random), or `{ closed = true }` to
	-- take the board down. Never the access code, never a streak.
	MapVoteState = {
		name = "MapVoteState",
		direction = "ServerBroadcast",
		schema = nil,
		rateLimit = nil,
		states = nil,
	} :: RemoteDef,
} :: { [string]: RemoteDef }

-- ===== Roblox-touching helpers (never called under Lune tests) ======

local REMOTES_FOLDER_NAME = "Remotes"

local function replicatedStorage(): Instance
	return game:GetService("ReplicatedStorage")
end

-- Server-only. Called once, at boot, from the declaration table above -
-- the folder can never drift from the code because nothing else is
-- allowed to create a remote (threat-model.md §14).
function Net.createRemotes(parent: Instance): Folder
	local existing = parent:FindFirstChild(REMOTES_FOLDER_NAME)
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = REMOTES_FOLDER_NAME

	for name in Net.Remotes do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
	end

	folder.Parent = parent
	return folder
end

function Net.getRemote(name: string): RemoteEvent
	local folder = replicatedStorage():WaitForChild(REMOTES_FOLDER_NAME)
	return folder:WaitForChild(name) :: RemoteEvent
end

-- Thin, typed client helpers - a controller calls these instead of ever
-- touching a RemoteEvent instance directly. `<T>` gives call-site type
-- inference on the payload; Luau has no way to also autocomplete valid
-- remote NAMES from a table's keys, so a typo in `name` is still only
-- caught at runtime (by NetGuard reporting "no handler registered") -
-- if that bites in practice, hand-write a one-line wrapper per remote
-- instead of calling this generic helper directly.
function Net.fireServer<T>(name: string, payload: T)
	Net.getRemote(name):FireServer(payload)
end

function Net.onClientEvent(name: string, callback: (payload: any) -> ()): RBXScriptConnection
	return Net.getRemote(name).OnClientEvent:Connect(callback)
end

-- Server-only broadcast helpers, for ServerBroadcast remotes.
function Net.fireClient<T>(name: string, player: Player, payload: T)
	Net.getRemote(name):FireClient(player, payload)
end

function Net.fireAllClients<T>(name: string, payload: T)
	Net.getRemote(name):FireAllClients(payload)
end

return Net
