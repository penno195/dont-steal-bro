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
