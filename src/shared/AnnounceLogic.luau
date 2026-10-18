--!strict
-- Staff announcements (staff-tools.md step 6; design-decisions.md
-- "Applied case: staff tools"): the pure rules. AnnounceService is the
-- server side, AnnouncementController draws the banner, and the staff
-- panel's Announce tab builds the request.
--
-- A staff member types a line; it shows as a big banner on every
-- player's screen in every live server (Hub, match and practice). The
-- owner decided (2026-10-18) it shows at once everywhere, mid-race
-- included, and that keeping streaks out of it is staff's job: the
-- panel warns, nothing here scans for streak talk (Q7 condition 1).
--
-- Shared, not server-only, so the panel counts characters with the same
-- rule the server enforces. No requires, so it runs headlessly under
-- Lune.

local AnnounceLogic = {}

-- Characters, not bytes. Two lines of banner text on a phone in
-- landscape at the banner's smallest size.
AnnounceLogic.MAX_CHARS = 120
-- Net.luau's StaffAnnounceIntent byte cap, copied there (Net has no
-- requires): the most MAX_CHARS characters can take in UTF-8.
AnnounceLogic.MAX_BYTES = AnnounceLogic.MAX_CHARS * 4
-- MessagingService refuses a message over 1KB once encoded. This leaves
-- room under it for the JSON keys and quoting.
AnnounceLogic.MESSAGE_BYTE_LIMIT = 900
-- A message older than this when it arrives is dropped: a banner that
-- turns up minutes late (a slow delivery) would read as news.
AnnounceLogic.MAX_AGE_SECONDS = 120
-- How many message ids a server remembers to drop repeats (its own
-- publish comes back to it through the subscription).
AnnounceLogic.SEEN_CAP = 50
-- How many banners a client holds while one is showing.
AnnounceLogic.QUEUE_CAP = 3
-- A display name is at most 20 characters, so 80 bytes of UTF-8.
local NAME_BYTES = 80

-- ===== the text ==============================================================

-- The typed text, tidied: control characters (newlines, tabs) become
-- spaces, runs of spaces become one, and the ends are trimmed. Returns
-- the text, or nil and why, in words for the staff panel.
function AnnounceLogic.clean(text: any): (string?, string?)
	if type(text) ~= "string" then
		return nil, "Type a message"
	end
	if utf8.len(text) == nil then
		return nil, "That text has characters that can't be shown"
	end
	local tidy = string.gsub(text, "%c", " ")
	tidy = string.gsub(tidy, "%s+", " ")
	tidy = string.gsub(tidy, "^ ", "")
	tidy = string.gsub(tidy, " $", "")
	if tidy == "" then
		return nil, "Type a message"
	end
	local length = utf8.len(tidy) :: number
	if length > AnnounceLogic.MAX_CHARS then
		return nil, string.format("Keep it to %d characters (it's %d)", AnnounceLogic.MAX_CHARS, length)
	end
	return tidy, nil
end

-- Characters typed so far, for the panel's counter. Invalid UTF-8 counts
-- in bytes, so the counter still moves.
function AnnounceLogic.length(text: string): number
	return utf8.len(text) or #text
end

-- The panel's counter, "42/120", and whether the text is over the cap.
function AnnounceLogic.counter(text: string): (string, boolean)
	local length = AnnounceLogic.length(text)
	return string.format("%d/%d", length, AnnounceLogic.MAX_CHARS), length > AnnounceLogic.MAX_CHARS
end

-- Whether the text filter left nothing to read: Roblox replaces what it
-- removes with '#', so a message that's all '#' was filtered out.
function AnnounceLogic.isFilteredOut(filtered: string): boolean
	return string.match(filtered, "^[#%s]*$") ~= nil
end

-- ===== per-staff rate limit ==================================================

-- Whether a staff member may announce again, given when they last did
-- (nil = never, in this server). Returns ok, and if not, whole seconds
-- left to wait.
function AnnounceLogic.checkCooldown(lastAt: number?, now: number, cooldownSeconds: number): (boolean, number)
	if lastAt == nil then
		return true, 0
	end
	local left = lastAt + cooldownSeconds - now
	if left <= 0 then
		return true, 0
	end
	return false, math.ceil(left)
end

-- ===== the message between servers ===========================================

export type Message = {
	id: string, -- HttpService GUID, for dropping repeats
	text: string, -- already through the text filter
	from: string, -- the staff member's display name
	sentAt: number, -- os.time() on the sending server
}

-- Bytes the message takes as JSON, counted on the high side: every
-- quote and backslash doubles, and clean() has already removed the
-- control characters that would take six.
function AnnounceLogic.encodedSize(message: Message): number
	local size = 64 -- braces, keys, quotes, commas and the number
	for _, field in { message.id, message.text, message.from } do
		local _, escapes = string.gsub(field, '["\\]', "")
		size += #field + escapes
	end
	return size
end

function AnnounceLogic.fits(message: Message): boolean
	return AnnounceLogic.encodedSize(message) <= AnnounceLogic.MESSAGE_BYTE_LIMIT
end

local function isText(value: any, maxBytes: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maxBytes and utf8.len(value) ~= nil
end

-- A message off MessagingService, or nil if it isn't one. Anything in
-- the game that publishes on the topic could send junk, so every field
-- is checked.
function AnnounceLogic.parse(raw: any): Message?
	if type(raw) ~= "table" then
		return nil
	end
	if not isText(raw.id, 64) or not isText(raw.text, AnnounceLogic.MAX_BYTES) or not isText(raw.from, NAME_BYTES) then
		return nil
	end
	if type(raw.sentAt) ~= "number" or raw.sentAt ~= raw.sentAt then
		return nil
	end
	return { id = raw.id, text = raw.text, from = raw.from, sentAt = raw.sentAt }
end

-- Whether a message is too old to show. A sentAt in the future (clocks a
-- little apart between servers) is fresh.
function AnnounceLogic.isStale(sentAt: number, now: number): boolean
	return now - sentAt > AnnounceLogic.MAX_AGE_SECONDS
end

-- ===== repeats ===============================================================

export type Seen = { order: { string }, set: { [string]: boolean } }

function AnnounceLogic.newSeen(): Seen
	return { order = {}, set = {} }
end

-- Records an id. Returns false if it was already there (a repeat, so
-- don't show it). Keeps the newest SEEN_CAP ids.
function AnnounceLogic.remember(seen: Seen, id: string): boolean
	if seen.set[id] then
		return false
	end
	seen.set[id] = true
	table.insert(seen.order, id)
	while #seen.order > AnnounceLogic.SEEN_CAP do
		local oldest = table.remove(seen.order, 1) :: string
		seen.set[oldest] = nil
	end
	return true
end

-- ===== the banner ============================================================

export type Banner = { text: string, from: string }

-- An Announcement payload as the client gets it, or nil if malformed.
function AnnounceLogic.readBanner(payload: any): Banner?
	if type(payload) ~= "table" then
		return nil
	end
	if not isText(payload.text, AnnounceLogic.MAX_BYTES) or not isText(payload.from, NAME_BYTES) then
		return nil
	end
	return { text = payload.text, from = payload.from }
end

-- Seconds a banner stays up before it fades: long enough to read at a
-- slow pace (about 15 characters a second), never shorter than `min`
-- or longer than `max`.
function AnnounceLogic.holdSeconds(text: string, min: number, max: number): number
	local reading = 1.5 + AnnounceLogic.length(text) / 15
	return math.clamp(reading, min, max)
end

-- Adds a banner to the waiting list. When it's full the oldest waiting
-- one is dropped: the newest is the one staff mean now.
function AnnounceLogic.enqueue(queue: { Banner }, banner: Banner)
	table.insert(queue, banner)
	while #queue > AnnounceLogic.QUEUE_CAP do
		table.remove(queue, 1)
	end
end

-- ===== audit =================================================================

export type AuditEntry = {
	at: number,
	staffUserId: number,
	typed: string, -- what staff typed, before the filter
	shown: string, -- what players saw
	reachedEveryServer: boolean, -- false = the publish failed, this server only
}

-- The audit log with `entry` added, keeping the newest `cap`. Junk in
-- the stored log is dropped rather than kept.
function AnnounceLogic.appendAudit(log: any, entry: AuditEntry, cap: number): { AuditEntry }
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

return AnnounceLogic
