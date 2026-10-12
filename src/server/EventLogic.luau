--!strict
-- Themed events (staff-tools.md step 5; design-decisions.md "Applied
-- case: staff tools"): the pure rules. EventService is the Roblox side.
--
-- One event runs at a time, in every Hub server. Staff start one by
-- hand for a set number of minutes, or stop it early (owner,
-- 2026-10-12: manual only, no schedule). The live state is one record
-- in the live-ops DataStore, { version, id, startedAt, endsAt, by }, and every
-- server works out for itself whether it's still on, so an event ends
-- on time even in a server that never hears the stop.
--
-- No requires, so it runs headlessly under Lune.

local EventLogic = {}

-- A day. Long enough for any event, short enough that a forgotten one
-- ends by itself.
EventLogic.MAX_MINUTES = 1440

-- The fields of Validate.EventDef these rules read.
export type EventInfo = {
	id: string,
	enabled: boolean,
	displayName: string,
}

export type State = {
	version: number, -- +1 on every start or stop; the higher one is newer
	id: string,
	startedAt: number, -- os.time()
	endsAt: number, -- os.time(); the event is on while now < endsAt
	by: number, -- the staff user id who started it
}

local function find(events: { EventInfo }, id: any): EventInfo?
	for _, event in events do
		if event.id == id then
			return event
		end
	end
	return nil
end

-- A start request, checked against the shipped events. Returns the
-- event, or nil and why.
function EventLogic.checkStart(eventId: any, minutes: any, events: { EventInfo }): (EventInfo?, string?)
	local event = find(events, eventId)
	if event == nil then
		return nil, "no such event"
	end
	if not event.enabled then
		return nil, event.displayName .. " is switched off in its config"
	end
	if type(minutes) ~= "number" or minutes ~= math.floor(minutes) then
		return nil, "minutes must be a whole number"
	end
	if minutes < 1 or minutes > EventLogic.MAX_MINUTES then
		return nil, string.format("minutes must be 1 to %d", EventLogic.MAX_MINUTES)
	end
	return event, nil
end

-- A start, replacing whatever `current` was (one event at a time).
-- Built inside UpdateAsync, so `current` is the stored record and the
-- versions never collide.
function EventLogic.start(current: State?, eventId: string, minutes: number, staffUserId: number, now: number): State
	return {
		version = (if current ~= nil then current.version else 0) + 1,
		id = eventId,
		startedAt = now,
		endsAt = now + minutes * 60,
		by = staffUserId,
	}
end

-- A stop, written as the same event ending at `now`.
function EventLogic.stop(current: State, staffUserId: number, now: number): State
	return {
		version = current.version + 1,
		id = current.id,
		startedAt = current.startedAt,
		endsAt = math.min(now, current.endsAt),
		by = staffUserId,
	}
end

-- Whatever the DataStore (or a MessagingService message) held, as a
-- State or nil. Anything malformed reads as "no event", never an error.
function EventLogic.parseState(raw: any): State?
	if type(raw) ~= "table" then
		return nil
	end
	if
		type(raw.version) ~= "number"
		or type(raw.id) ~= "string"
		or type(raw.startedAt) ~= "number"
		or type(raw.endsAt) ~= "number"
		or type(raw.by) ~= "number"
	then
		return nil
	end
	return { version = raw.version, id = raw.id, startedAt = raw.startedAt, endsAt = raw.endsAt, by = raw.by }
end

-- The event this server should be showing at `now`, or nil. An event
-- whose config was removed or switched off since it started stops
-- showing at once.
function EventLogic.activeId(state: State?, now: number, events: { EventInfo }): string?
	if state == nil or now >= state.endsAt then
		return nil
	end
	local event = find(events, state.id)
	if event == nil or not event.enabled then
		return nil
	end
	return event.id
end

-- Which of two states is newer: a MessagingService message and a
-- DataStore read can arrive in either order (a read can be a few seconds
-- stale), and the higher version wins.
function EventLogic.newer(a: State?, b: State?): State?
	if a == nil then
		return b
	end
	if b == nil then
		return a
	end
	return if b.version > a.version then b else a
end

-- ===== audit =================================================================

export type AuditEntry = {
	at: number,
	staffUserId: number,
	action: "Start" | "Stop",
	eventId: string?,
	minutes: number?,
	replaced: string?, -- a start that cut short another event: its id
}

function EventLogic.appendAudit(log: any, entry: AuditEntry, cap: number): { AuditEntry }
	local entries: { AuditEntry } = {}
	if type(log) == "table" then
		for _, existing in log do
			if type(existing) == "table" then
				table.insert(entries, existing)
			end
		end
	end
	table.insert(entries, entry)
	while #entries > cap do
		table.remove(entries, 1)
	end
	return entries
end

return EventLogic
