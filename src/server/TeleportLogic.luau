--!strict
-- The pure rules behind the hub-to-match teleport (P5-2). The service
-- (src/server/Services/MatchTeleportService.luau) does the Roblox calls;
-- everything it has to DECIDE lives here so it can be tested headlessly
-- (tests/TeleportLogic.spec.luau). docs/teleport.md walks the whole flow.
--
-- Self-contained on purpose, like ProfileLogic: no requires, so Lune can
-- load it.
--
-- ===== THE ONE RULE =======================================================
--
-- threat-model.md §5: TeleportData is never authoritative. The match
-- server finds its group by its OWN game.PrivateServerId, which keys the
-- group record the hub wrote to MemoryStore (the "manifest"). Members,
-- map and NPC slots all come from there. TeleportData is sent, but the
-- match server only compares it against the manifest and logs any
-- mismatch. The single exception is the map id during a MemoryStore
-- outage, and even then only an enabled map id is accepted - see
-- resolveMapId.

local TeleportLogic = {}

TeleportLogic.HINT_VERSION = 1

-- ===== failures on the hub =================================================

-- Enum.TeleportResult names as TeleportInitFailed reports them, plus two
-- of ours: "Timeout" (the player was still on the hub when the travel
-- watchdog fired) and "Error" (TeleportAsync itself threw).
export type FailureKind = "Retry" | "Requeue" | "Wait"

export type FailureVerdict = {
	kind: FailureKind,
	delaySeconds: number,
	message: string,
}

export type RetryConfig = {
	maxAttempts: number,
	retryBaseSeconds: number,
	retryCapSeconds: number,
}

-- Worth trying again against the SAME reserved server: the server is
-- fine, the trip wasn't.
local RETRYABLE: { [string]: boolean } = {
	Failure = true,
	Flooded = true,
	Timeout = true,
	Error = true,
}

-- What the player reads. Retry messages are shown while we try again;
-- the requeue message is shown once we give up. Every requeue message
-- ends by telling them they kept their place, because they did.
local RETRY_MESSAGES: { [string]: string } = {
	Failure = "The trip to your match hit a snag. Trying again...",
	Flooded = "Lots of players are travelling right now. Trying again...",
	Timeout = "Travel is taking longer than it should. Trying again...",
	Error = "Couldn't start the trip to your match. Trying again...",
}

local GIVE_UP_MESSAGES: { [string]: string } = {
	Failure = "We couldn't get you to your match.",
	Flooded = "Travel is too busy right now.",
	Timeout = "Travel took too long.",
	Error = "We couldn't start the trip to your match.",
	GameFull = "Your match filled up before you got there.",
	GameEnded = "Your match closed before you got there.",
	GameNotFound = "Your match closed before you got there.",
	Unauthorized = "You weren't allowed into that match.",
}

local REQUEUE_SUFFIX = " You're back in the queue at your old place."
local UNKNOWN_GIVE_UP = "Something went wrong on the way to your match."

function TeleportLogic.backoffSeconds(attempt: number, base: number, cap: number): number
	if attempt <= 0 then
		return 0
	end
	return math.min(cap, base * 2 ^ (attempt - 1))
end

-- `attempt` is how many attempts this player has had, including the one
-- that just failed.
function TeleportLogic.classifyFailure(reason: string, attempt: number, config: RetryConfig): FailureVerdict
	-- A teleport for this player is already in flight. The watchdog is
	-- still running, so doing nothing is safe and a second request would
	-- only fail the same way.
	if reason == "IsTeleporting" then
		return { kind = "Wait", delaySeconds = 0, message = "" }
	end
	if RETRYABLE[reason] and attempt < config.maxAttempts then
		return {
			kind = "Retry",
			delaySeconds = TeleportLogic.backoffSeconds(attempt, config.retryBaseSeconds, config.retryCapSeconds),
			message = RETRY_MESSAGES[reason],
		}
	end
	-- GameEnded / GameNotFound / GameFull / Unauthorized mean the reserved
	-- server itself won't take them, so retrying it is pointless. Unknown
	-- reasons (a new enum item) are treated the same way: the safe end
	-- state is back in line, never an endless loop.
	return {
		kind = "Requeue",
		delaySeconds = 0,
		message = (GIVE_UP_MESSAGES[reason] or UNKNOWN_GIVE_UP) .. REQUEUE_SUFFIX,
	}
end

-- ===== TeleportData =========================================================

export type Hint = {
	v: number,
	groupId: string,
	mapId: string?,
	npcSlots: number,
}

function TeleportLogic.buildHint(groupId: string, mapId: string?, npcSlots: number): Hint
	return { v = TeleportLogic.HINT_VERSION, groupId = groupId, mapId = mapId, npcSlots = npcSlots }
end

-- What the match server trusts: the group record the hub committed,
-- read back from MemoryStore under this server's own PrivateServerId.
export type Manifest = {
	groupId: string,
	members: { number },
	npcSlots: number,
	mapId: string?,
}

-- Compares a raw, untrusted TeleportData value against the manifest.
-- Returns one flag per disagreement, for logging only: nothing the
-- match server does depends on the result. An empty list means the
-- hint agrees (or there's no manifest to compare it with, beyond the
-- group id, which must still equal this server's own id).
function TeleportLogic.checkHint(raw: any, manifest: Manifest?, privateServerId: string): { string }
	local flags: { string } = {}
	if raw == nil then
		table.insert(flags, "Missing")
		return flags
	end
	if type(raw) ~= "table" then
		table.insert(flags, "NotATable")
		return flags
	end
	if raw.v ~= TeleportLogic.HINT_VERSION then
		table.insert(flags, "BadVersion")
	end
	if raw.groupId ~= privateServerId then
		table.insert(flags, "GroupIdMismatch")
	end
	if manifest ~= nil then
		if raw.mapId ~= manifest.mapId then
			table.insert(flags, "MapIdMismatch")
		end
		if raw.npcSlots ~= manifest.npcSlots then
			table.insert(flags, "NpcSlotsMismatch")
		end
	elseif raw.npcSlots ~= nil and (type(raw.npcSlots) ~= "number" or raw.npcSlots ~= raw.npcSlots) then
		table.insert(flags, "NpcSlotsMalformed")
	end
	return flags
end

-- ===== map choice on the match server =======================================

export type MapSource = "Manifest" | "Hint" | "Fallback" | "None"

-- The manifest's map wins whenever it is enabled here. The hint is only
-- consulted when the manifest couldn't be read at all (a MemoryStore
-- outage), and only if it names a map this server has enabled: at worst
-- a tampered hint picks one of the maps the group could have been given
-- anyway. Anything else - an unknown id, a disabled map, a hub and match
-- server on different config versions - gets a uniform random enabled
-- map. `roll(n)` returns an integer in 1..n.
function TeleportLogic.resolveMapId(
	manifest: Manifest?,
	hint: any,
	enabledMapIds: { string },
	roll: (n: number) -> number
): (string?, MapSource)
	if manifest ~= nil and manifest.mapId ~= nil and table.find(enabledMapIds, manifest.mapId) then
		return manifest.mapId, "Manifest"
	end
	if manifest == nil and type(hint) == "table" and type(hint.mapId) == "string" then
		if table.find(enabledMapIds, hint.mapId) then
			return hint.mapId, "Hint"
		end
	end
	if #enabledMapIds == 0 then
		return nil, "None"
	end
	return enabledMapIds[roll(#enabledMapIds)], "Fallback"
end

-- ===== who gets in ===========================================================

export type Admission = "Admit" | "Stray" | "Late"

-- "Late": the arrival window has closed and the round is under way.
-- Seats are already settled (NPCs fill the gaps), so a late player is
-- sent back to the hub rather than dropped into a race they can't win.
-- "Stray": the manifest is known and doesn't list them. Only our own
-- servers can send anyone to a reserved server, so this is a bug
-- somewhere, not an attack - but they still don't belong here.
-- Without a manifest (outage), membership can't be checked, and the
-- reserved server's access code is the only gate.
function TeleportLogic.admission(userId: number, manifest: Manifest?, gateClosed: boolean): Admission
	if gateClosed then
		return "Late"
	end
	if manifest ~= nil and table.find(manifest.members, userId) == nil then
		return "Stray"
	end
	return "Admit"
end

-- ===== when the round starts ===================================================

export type GateInput = {
	expected: number?, -- manifest member count; nil if the manifest is unknown
	present: number, -- admitted humans on this server now
	loaded: number, -- of those, how many have a loaded profile
	elapsed: number, -- seconds since the first player arrived
	graceSeconds: number,
	loadGraceSeconds: number,
	seatCount: number,
}

export type GateDecision = "Wait" | "Start" | "Abandon"

-- 1. Everyone expected is here and loaded: start now, no reason to wait.
-- 2. Otherwise wait out the grace window (architecture.md §4's "~10s so
--    slow teleports aren't replaced by bots").
-- 3. Nobody came: abandon. A bots-only round helps no one.
-- 4. Someone is here but their profile is still loading - most likely
--    the hub hasn't released the session lock yet (docs/teleport.md).
--    Give them up to loadGraceSeconds more.
-- 5. Start with whoever is here. NPCService fills the empty seats from
--    the count it sees itself.
function TeleportLogic.gateDecision(input: GateInput): GateDecision
	local target = input.expected or input.seatCount
	if input.present > 0 and input.loaded >= input.present and input.present >= target then
		return "Start"
	end
	if input.elapsed < input.graceSeconds then
		return "Wait"
	end
	if input.present == 0 then
		return "Abandon"
	end
	if input.loaded < input.present and input.elapsed < input.graceSeconds + input.loadGraceSeconds then
		return "Wait"
	end
	return "Start"
end

-- ===== coming back to the hub ==================================================

-- Sent as TeleportData when the match server sends someone home. It is a
-- cosmetic hint - the only thing it can do is choose which of these
-- fixed strings the hub shows - so a forged one is harmless.
local RETURN_MESSAGES: { [string]: string } = {
	Late = "Your match started before you arrived. Press Play to queue again.",
	Stray = "That match wasn't yours. Press Play to queue again.",
	-- Every match ends by sending everyone home (design-decisions.md
	-- Q6: the next round is a fresh queue, never the same server).
	RoundOver = "Round over. Press Play to queue for the next one.",
}

function TeleportLogic.returnMessage(raw: any): string?
	if type(raw) ~= "table" or type(raw.returnReason) ~= "string" then
		return nil
	end
	return RETURN_MESSAGES[raw.returnReason]
end

return TeleportLogic
