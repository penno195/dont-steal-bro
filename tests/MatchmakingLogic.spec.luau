--!strict
-- Covers MatchmakingLogic.luau (P5-1): the entry state machine's
-- compare-and-set transforms, the exactly-once claim property, group
-- selection with the rematch cooldown, partial groups, and the queue
-- status the UI is sent. MatchmakingService.luau itself touches
-- MemoryStoreService and Players, so it is exercised in Studio instead
-- (docs/matchmaking.md), the same split every other spec uses.

local TestRunner = require("./TestRunner")
local MatchmakingLogic = require("../src/server/MatchmakingLogic")

type Entry = MatchmakingLogic.Entry

local CONFIG: MatchmakingLogic.Config = {
	groupSize = 6,
	partialGroupTimeoutSeconds = 60,
	partialGroupMinPlayers = 1,
	formationTickSeconds = 2,
	rematchCooldownSeconds = 900,
	recentOpponentsCap = 30,
}

local NOW = 1_000_000

local function entry(userId: number, enqueuedAt: number?, jobId: string?): Entry
	return MatchmakingLogic.newEntry(userId, jobId or "jobA", enqueuedAt or (NOW - 10 + userId / 100), 0, {})
end

local function queue(count: number, waitedSeconds: number?): { Entry }
	local out: { Entry } = {}
	for i = 1, count do
		table.insert(out, entry(i, NOW - (waitedSeconds or 10) + i / 100))
	end
	return out
end

-- Simulates MemoryStore's UpdateAsync on one key: the transform runs
-- against the value stored NOW, and a nil return leaves it untouched.
local function update(store: { [number]: Entry }, userId: number, transform: (Entry?) -> Entry?): boolean
	local result = transform(store[userId])
	if result == nil then
		return false
	end
	store[userId] = result
	return true
end

TestRunner.describe("MatchmakingLogic transforms", function()
	TestRunner.it("claims only a Waiting entry, and keeps its place", function()
		local e = entry(1, 500)
		local claimed = MatchmakingLogic.claim(e, "G")
		TestRunner.expect(claimed and claimed.state):toBe("Claimed")
		TestRunner.expect(claimed and claimed.groupId):toBe("G")
		TestRunner.expect(claimed and claimed.enqueuedAt):toBe(500)
		TestRunner.expect(MatchmakingLogic.claim(nil, "G")):toBe(nil)
		TestRunner.expect(MatchmakingLogic.claim(claimed, "H")):toBe(nil)
	end)

	TestRunner.it("two servers claiming the same player: exactly one wins", function()
		-- UpdateAsync serialises the two transforms on one key; whichever
		-- runs second sees the first one's write. Both orders are checked.
		for _, order in { { "G", "H" }, { "H", "G" } } do
			local store: { [number]: Entry } = { [1] = entry(1) }
			local first = update(store, 1, function(c)
				return MatchmakingLogic.claim(c, order[1])
			end)
			local second = update(store, 1, function(c)
				return MatchmakingLogic.claim(c, order[2])
			end)
			TestRunner.expect(first):toBe(true)
			TestRunner.expect(second):toBe(false)
			TestRunner.expect(store[1].groupId):toBe(order[1])
		end
	end)

	TestRunner.it("release only undoes the SAME token, back to Waiting with the same place", function()
		local claimed = MatchmakingLogic.claim(entry(1, 500), "G") :: Entry
		TestRunner.expect(MatchmakingLogic.release(claimed, "H")):toBe(nil)
		local released = MatchmakingLogic.release(claimed, "G")
		TestRunner.expect(released and released.state):toBe("Waiting")
		TestRunner.expect(released and released.groupId):toBe(nil)
		TestRunner.expect(released and released.enqueuedAt):toBe(500)
	end)

	TestRunner.it("depart requires Claimed with the matching token", function()
		local claimed = MatchmakingLogic.claim(entry(1), "G") :: Entry
		TestRunner.expect(MatchmakingLogic.depart(claimed, "H")):toBe(nil)
		TestRunner.expect(MatchmakingLogic.depart(entry(1), "G")):toBe(nil)
		local departed = MatchmakingLogic.depart(claimed, "G")
		TestRunner.expect(departed and departed.state):toBe("Departed")
		-- Departed is final: nothing re-claims or releases it.
		TestRunner.expect(MatchmakingLogic.claim(departed, "H")):toBe(nil)
		TestRunner.expect(MatchmakingLogic.release(departed, "G")):toBe(nil)
	end)

	TestRunner.it("a stalled former cannot steal back a player re-claimed by another group", function()
		-- Server A claims with G and stalls. The owner reverts the stale
		-- claim, server B claims with H. A's late release/depart for G
		-- must bounce off.
		local store: { [number]: Entry } = { [1] = entry(1) }
		update(store, 1, function(c)
			return MatchmakingLogic.claim(c, "G")
		end)
		update(store, 1, function(c)
			return MatchmakingLogic.release(c, "G")
		end)
		update(store, 1, function(c)
			return MatchmakingLogic.claim(c, "H")
		end)
		TestRunner.expect(update(store, 1, function(c)
			return MatchmakingLogic.depart(c, "G")
		end)):toBe(false)
		TestRunner.expect(update(store, 1, function(c)
			return MatchmakingLogic.release(c, "G")
		end)):toBe(false)
		TestRunner.expect(store[1].groupId):toBe("H")
	end)

	TestRunner.it("leave only acts for the owning server, and never on a Departed entry", function()
		local e = entry(1, nil, "jobA")
		TestRunner.expect(MatchmakingLogic.leave(e, "jobB")):toBe(nil)
		local left = MatchmakingLogic.leave(e, "jobA")
		TestRunner.expect(left and left.state):toBe("Left")
		TestRunner.expect(MatchmakingLogic.claim(left, "G")):toBe(nil)

		local departed = MatchmakingLogic.depart(MatchmakingLogic.claim(e, "G"), "G")
		TestRunner.expect(MatchmakingLogic.leave(departed, "jobA")):toBe(nil)
	end)

	TestRunner.it("leaving during a claim makes that group's depart fail", function()
		local store: { [number]: Entry } = { [1] = entry(1) }
		update(store, 1, function(c)
			return MatchmakingLogic.claim(c, "G")
		end)
		update(store, 1, function(c)
			return MatchmakingLogic.leave(c, "jobA")
		end)
		TestRunner.expect(update(store, 1, function(c)
			return MatchmakingLogic.depart(c, "G")
		end)):toBe(false)
	end)

	TestRunner.it("a repeat join from the same server writes nothing", function()
		local original = entry(1, 500, "jobA")
		local fresh = entry(1, 900, "jobA")
		TestRunner.expect(MatchmakingLogic.join(original, fresh)):toBe(nil)
		TestRunner.expect(MatchmakingLogic.join(MatchmakingLogic.claim(original, "G"), fresh)):toBe(nil)
	end)

	TestRunner.it("a join replaces a stale entry from another server or a finished one", function()
		local fresh = entry(1, 900, "jobB")
		TestRunner.expect(MatchmakingLogic.join(nil, fresh)):toBe(fresh)
		TestRunner.expect(MatchmakingLogic.join(entry(1, 500, "jobA"), fresh)):toBe(fresh)
		local left = MatchmakingLogic.leave(entry(1, 500, "jobB"), "jobB")
		TestRunner.expect(MatchmakingLogic.join(left, fresh)):toBe(fresh)
	end)

	TestRunner.it("refresh keeps only the owner's Waiting/Claimed entries alive", function()
		local e = entry(1, nil, "jobA")
		TestRunner.expect(MatchmakingLogic.refresh(e, "jobA")):toBe(e)
		TestRunner.expect(MatchmakingLogic.refresh(e, "jobB")):toBe(nil)
		TestRunner.expect(MatchmakingLogic.refresh(MatchmakingLogic.claim(e, "G"), "jobA") ~= nil):toBe(true)
		TestRunner.expect(MatchmakingLogic.refresh(MatchmakingLogic.leave(e, "jobA"), "jobA")):toBe(nil)
		TestRunner.expect(MatchmakingLogic.refresh(nil, "jobA")):toBe(nil)
	end)
end)

TestRunner.describe("MatchmakingLogic.ownerActionForClaim", function()
	TestRunner.it("departs as soon as the group record exists", function()
		TestRunner.expect(MatchmakingLogic.ownerActionForClaim(true, 0, 45)):toBe("Depart")
		TestRunner.expect(MatchmakingLogic.ownerActionForClaim(true, 999, 45)):toBe("Depart")
	end)

	TestRunner.it("waits, then reverts a claim whose group never committed", function()
		TestRunner.expect(MatchmakingLogic.ownerActionForClaim(false, 44, 45)):toBe("Wait")
		TestRunner.expect(MatchmakingLogic.ownerActionForClaim(false, 45, 45)):toBe("Revert")
	end)
end)

TestRunner.describe("MatchmakingLogic decoding", function()
	TestRunner.it("round-trips a valid entry", function()
		local e = entry(7, 123)
		local decoded = MatchmakingLogic.decodeEntry(e)
		TestRunner.expect(decoded and decoded.userId):toBe(7)
		TestRunner.expect(decoded and decoded.state):toBe("Waiting")
	end)

	TestRunner.it("rejects malformed and foreign-version entries", function()
		TestRunner.expect(MatchmakingLogic.decodeEntry(nil)):toBe(nil)
		TestRunner.expect(MatchmakingLogic.decodeEntry("junk")):toBe(nil)
		local wrongVersion = table.clone(entry(1)) :: any
		wrongVersion.v = 99
		TestRunner.expect(MatchmakingLogic.decodeEntry(wrongVersion)):toBe(nil)
		local badState = table.clone(entry(1)) :: any
		badState.state = "Teleporting"
		TestRunner.expect(MatchmakingLogic.decodeEntry(badState)):toBe(nil)
		local nanTime = table.clone(entry(1)) :: any
		nanTime.enqueuedAt = 0 / 0
		TestRunner.expect(MatchmakingLogic.decodeEntry(nanTime)):toBe(nil)
	end)

	TestRunner.it("rejects a Claimed entry with no token", function()
		local claimed = table.clone(MatchmakingLogic.claim(entry(1), "G") :: Entry) :: any
		claimed.groupId = nil
		TestRunner.expect(MatchmakingLogic.decodeEntry(claimed)):toBe(nil)
	end)

	TestRunner.it("drops malformed avoid records instead of the whole entry", function()
		local raw = table.clone(entry(1)) :: any
		raw.avoid = { { u = 2, t = NOW + 5 }, { u = "x", t = 1 }, "junk" }
		local decoded = MatchmakingLogic.decodeEntry(raw) :: Entry
		TestRunner.expect(#decoded.avoid):toBe(1)
	end)

	TestRunner.it("rejects a group record with a non-numeric member", function()
		local record = MatchmakingLogic.newGroupRecord("G", queue(2), 4, NOW, "jobA")
		TestRunner.expect(MatchmakingLogic.decodeGroup(record) ~= nil):toBe(true)
		local bad = table.clone(record) :: any
		bad.members = { 1, "two" }
		TestRunner.expect(MatchmakingLogic.decodeGroup(bad)):toBe(nil)
	end)
end)

TestRunner.describe("MatchmakingLogic.selectGroups", function()
	TestRunner.it("forms one full group from exactly six, oldest first", function()
		local groups = MatchmakingLogic.selectGroups(queue(6), NOW, CONFIG)
		TestRunner.expect(#groups):toBe(1)
		TestRunner.expect(#groups[1].members):toBe(6)
		TestRunner.expect(groups[1].npcSlots):toBe(0)
		TestRunner.expect(groups[1].partial):toBe(false)
		TestRunner.expect(groups[1].members[1].userId):toBe(1)
	end)

	TestRunner.it("forms two groups from twelve, and holds five of eleven back", function()
		TestRunner.expect(#MatchmakingLogic.selectGroups(queue(12), NOW, CONFIG)):toBe(2)
		TestRunner.expect(#MatchmakingLogic.selectGroups(queue(11), NOW, CONFIG)):toBe(1)
	end)

	TestRunner.it("never puts one player in two groups from the same snapshot", function()
		local seen: { [number]: boolean } = {}
		for _, group in MatchmakingLogic.selectGroups(queue(40, 120), NOW, CONFIG) do
			for _, member in group.members do
				TestRunner.expect(seen[member.userId]):toBe(nil)
				seen[member.userId] = true
			end
		end
	end)

	TestRunner.it("ignores entries that aren't Waiting", function()
		local entries = queue(6)
		entries[3] = MatchmakingLogic.claim(entries[3], "G") :: Entry
		TestRunner.expect(#MatchmakingLogic.selectGroups(entries, NOW, CONFIG)):toBe(0)
	end)

	TestRunner.it("waits under the timer with fewer than six", function()
		TestRunner.expect(#MatchmakingLogic.selectGroups(queue(5, 59), NOW, CONFIG)):toBe(0)
	end)

	TestRunner.it("forms a partial group once the oldest has waited out the timer", function()
		local groups = MatchmakingLogic.selectGroups(queue(4, 61), NOW, CONFIG)
		TestRunner.expect(#groups):toBe(1)
		TestRunner.expect(#groups[1].members):toBe(4)
		TestRunner.expect(groups[1].npcSlots):toBe(2)
		TestRunner.expect(groups[1].partial):toBe(true)
	end)

	TestRunner.it("forms a partial group of one", function()
		local groups = MatchmakingLogic.selectGroups(queue(1, 61), NOW, CONFIG)
		TestRunner.expect(#groups):toBe(1)
		TestRunner.expect(groups[1].npcSlots):toBe(5)
	end)

	TestRunner.it("respects partialGroupMinPlayers", function()
		local strict = table.clone(CONFIG)
		strict.partialGroupMinPlayers = 2
		TestRunner.expect(#MatchmakingLogic.selectGroups(queue(1, 61), NOW, strict)):toBe(0)
	end)

	TestRunner.it("keeps recent opponents apart, even when one side forgot", function()
		local entries = queue(7)
		-- Only player 1 remembers player 2; the symmetric check still bites.
		entries[1].avoid = { { u = 2, t = NOW + 100 } }
		local groups = MatchmakingLogic.selectGroups(entries, NOW, CONFIG)
		TestRunner.expect(#groups):toBe(1)
		local ids: { [number]: boolean } = {}
		for _, member in groups[1].members do
			ids[member.userId] = true
		end
		TestRunner.expect(ids[1] == true and ids[2] == true):toBe(false)
	end)

	TestRunner.it("an expired cooldown no longer separates anyone", function()
		local entries = queue(6)
		entries[1].avoid = { { u = 2, t = NOW - 1 } }
		TestRunner.expect(#MatchmakingLogic.selectGroups(entries, NOW, CONFIG)):toBe(1)
	end)

	TestRunner.it("one incompatible oldest player doesn't block six compatible others", function()
		local entries = queue(7)
		entries[1].avoid = {}
		for other = 2, 7 do
			table.insert(entries[1].avoid, { u = other, t = NOW + 100 })
		end
		local groups = MatchmakingLogic.selectGroups(entries, NOW, CONFIG)
		TestRunner.expect(#groups):toBe(1)
		for _, member in groups[1].members do
			TestRunner.expect(member.userId ~= 1):toBe(true)
		end
	end)

	TestRunner.it("never relaxes the cooldown to fill a partial group", function()
		local entries = queue(2, 61)
		entries[1].avoid = { { u = 2, t = NOW + 100 } }
		local groups = MatchmakingLogic.selectGroups(entries, NOW, CONFIG)
		-- Both have waited out the timer, so both get a group - separately.
		TestRunner.expect(#groups):toBe(2)
		TestRunner.expect(#groups[1].members):toBe(1)
		TestRunner.expect(#groups[2].members):toBe(1)
	end)
end)

TestRunner.describe("MatchmakingLogic.mergeRecent", function()
	TestRunner.it("adds co-members, never self, with the cooldown expiry", function()
		local merged = MatchmakingLogic.mergeRecent({}, 1, { 1, 2, 3 }, NOW, 900, 30)
		TestRunner.expect(#merged):toBe(2)
		for _, record in merged do
			TestRunner.expect(record.u ~= 1):toBe(true)
			TestRunner.expect(record.t):toBe(NOW + 900)
		end
	end)

	TestRunner.it("drops expired records and keeps the later expiry for a repeat", function()
		local existing = { { u = 5, t = NOW - 1 }, { u = 2, t = NOW + 10 } }
		local merged = MatchmakingLogic.mergeRecent(existing, 1, { 2 }, NOW, 900, 30)
		TestRunner.expect(#merged):toBe(1)
		TestRunner.expect(merged[1].u):toBe(2)
		TestRunner.expect(merged[1].t):toBe(NOW + 900)
	end)

	TestRunner.it("caps the list, keeping the longest-lived records", function()
		local existing = {}
		for i = 10, 19 do
			table.insert(existing, { u = i, t = NOW + i })
		end
		local merged = MatchmakingLogic.mergeRecent(existing, 1, { 2, 3 }, NOW, 900, 5)
		TestRunner.expect(#merged):toBe(5)
		TestRunner.expect(merged[1].t):toBe(NOW + 900)
		TestRunner.expect(merged[5].u):toBe(17)
	end)
end)

TestRunner.describe("MatchmakingLogic.queueStatus", function()
	TestRunner.it("reports position and size among Waiting entries only", function()
		local entries = queue(4)
		entries[1] = MatchmakingLogic.claim(entries[1], "G") :: Entry
		local status = MatchmakingLogic.queueStatus(entries, 3, NOW, CONFIG, false)
		TestRunner.expect(status.position):toBe(2)
		TestRunner.expect(status.queueSize):toBe(3)
		TestRunner.expect(status.queueSizeIsLowerBound):toBe(false)
	end)

	TestRunner.it("estimates one tick when a full group is available", function()
		TestRunner.expect(MatchmakingLogic.queueStatus(queue(6), 6, NOW, CONFIG, false).estimatedWaitSeconds):toBe(2)
	end)

	TestRunner.it("estimates the rest of the partial timer otherwise", function()
		local entries = { entry(1, NOW - 20), entry(2, NOW - 15), entry(3, NOW - 5) }
		local status = MatchmakingLogic.queueStatus(entries, 2, NOW, CONFIG, false)
		TestRunner.expect(status.estimatedWaitSeconds):toBe(40)
	end)

	TestRunner.it("never estimates below one tick", function()
		TestRunner.expect(MatchmakingLogic.queueStatus(queue(3, 600), 1, NOW, CONFIG, false).estimatedWaitSeconds)
			:toBe(2)
	end)

	TestRunner.it("reports no position for a player beyond the page", function()
		local status = MatchmakingLogic.queueStatus(queue(3), 99, NOW, CONFIG, true)
		TestRunner.expect(status.position):toBe(nil)
		TestRunner.expect(status.queueSizeIsLowerBound):toBe(true)
	end)
end)

TestRunner.describe("MatchmakingLogic.backoffSeconds", function()
	TestRunner.it("doubles from the base and stops at the cap", function()
		TestRunner.expect(MatchmakingLogic.backoffSeconds(0, 2, 30)):toBe(0)
		TestRunner.expect(MatchmakingLogic.backoffSeconds(1, 2, 30)):toBe(2)
		TestRunner.expect(MatchmakingLogic.backoffSeconds(3, 2, 30)):toBe(8)
		TestRunner.expect(MatchmakingLogic.backoffSeconds(10, 2, 30)):toBe(30)
	end)
end)
