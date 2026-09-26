--!strict
-- Covers TeleportLogic.luau (P5-2): the retry/requeue verdicts, the
-- TeleportData checks, map resolution, admission and the arrival gate.
-- MatchTeleportService.luau itself needs TeleportService and reserved
-- servers, so it is verified on a published place instead
-- (docs/teleport.md), the same split every other spec uses.

local TestRunner = require("./TestRunner")
local TeleportLogic = require("../src/server/TeleportLogic")

type Manifest = TeleportLogic.Manifest

local RETRY: TeleportLogic.RetryConfig = { maxAttempts = 4, retryBaseSeconds = 1, retryCapSeconds = 8 }

local PSID = "private-server-1"

local function manifest(mapId: string?): Manifest
	return { groupId = PSID, members = { 11, 22, 33 }, npcSlots = 3, mapId = mapId }
end

local function first(n: number): number
	return 1 + 0 * n
end

TestRunner.describe("TeleportLogic.classifyFailure", function()
	TestRunner.it("retries transient failures with doubling, capped backoff", function()
		local delays = {}
		for attempt = 1, 3 do
			local verdict = TeleportLogic.classifyFailure("Flooded", attempt, RETRY)
			TestRunner.expect(verdict.kind):toBe("Retry")
			table.insert(delays, verdict.delaySeconds)
		end
		TestRunner.expect(delays[1]):toBe(1)
		TestRunner.expect(delays[2]):toBe(2)
		TestRunner.expect(delays[3]):toBe(4)
		local capped =
			TeleportLogic.classifyFailure("Failure", 3, { maxAttempts = 10, retryBaseSeconds = 3, retryCapSeconds = 8 })
		TestRunner.expect(capped.delaySeconds):toBe(8)
	end)

	TestRunner.it("gives up on the last attempt and says the player kept their place", function()
		for _, reason in { "Failure", "Flooded", "Timeout", "Error" } do
			local verdict = TeleportLogic.classifyFailure(reason, 4, RETRY)
			TestRunner.expect(verdict.kind):toBe("Requeue")
			TestRunner.expect(string.find(verdict.message, "old place", 1, true) ~= nil):toBeTruthy()
		end
	end)

	TestRunner.it("requeues at once when the reserved server itself won't take them", function()
		for _, reason in { "GameFull", "GameEnded", "GameNotFound", "Unauthorized" } do
			TestRunner.expect(TeleportLogic.classifyFailure(reason, 1, RETRY).kind):toBe("Requeue")
		end
	end)

	TestRunner.it("waits on IsTeleporting instead of stacking a second request", function()
		TestRunner.expect(TeleportLogic.classifyFailure("IsTeleporting", 1, RETRY).kind):toBe("Wait")
	end)

	TestRunner.it("treats an unknown reason as a requeue, never a retry loop", function()
		local verdict = TeleportLogic.classifyFailure("SomeFutureEnumItem", 1, RETRY)
		TestRunner.expect(verdict.kind):toBe("Requeue")
		TestRunner.expect(#verdict.message > 0):toBeTruthy()
	end)

	TestRunner.it("gives every retry and requeue a message", function()
		for _, reason in
			{ "Failure", "Flooded", "Timeout", "Error", "GameFull", "GameEnded", "GameNotFound", "Unauthorized" }
		do
			TestRunner.expect(#TeleportLogic.classifyFailure(reason, 1, RETRY).message > 0):toBeTruthy()
		end
	end)
end)

TestRunner.describe("TeleportLogic.buildHint", function()
	-- P5-5: TeleportData is the only thing that travels from hub to
	-- match. If it only ever holds these four fields, no practice effect,
	-- item or cooldown can ride along into a round.
	TestRunner.it("carries only the version, group, map and NPC seats", function()
		local hint = TeleportLogic.buildHint(PSID, "Lab", 3) :: any
		local allowed = { v = true, groupId = true, mapId = true, npcSlots = true }
		local count = 0
		for key in hint do
			TestRunner.expect(allowed[key]):toBe(true)
			count += 1
		end
		TestRunner.expect(count):toBe(4)
	end)
end)

TestRunner.describe("TeleportLogic.checkHint", function()
	TestRunner.it("accepts an honest hint", function()
		local hint = TeleportLogic.buildHint(PSID, "Lab", 3)
		TestRunner.expect(#TeleportLogic.checkHint(hint, manifest("Lab"), PSID)):toBe(0)
	end)

	TestRunner.it("flags a missing or non-table hint", function()
		TestRunner.expect(TeleportLogic.checkHint(nil, manifest("Lab"), PSID)[1]):toBe("Missing")
		TestRunner.expect(TeleportLogic.checkHint("lol", manifest("Lab"), PSID)[1]):toBe("NotATable")
	end)

	TestRunner.it("flags every field that disagrees with the manifest", function()
		local forged = { v = 1, groupId = "someone-elses", mapId = "Vault", npcSlots = 0 }
		local flags = TeleportLogic.checkHint(forged, manifest("Lab"), PSID)
		TestRunner.expect(table.find(flags, "GroupIdMismatch") ~= nil):toBeTruthy()
		TestRunner.expect(table.find(flags, "MapIdMismatch") ~= nil):toBeTruthy()
		TestRunner.expect(table.find(flags, "NpcSlotsMismatch") ~= nil):toBeTruthy()
	end)

	TestRunner.it("still checks the group id and shape without a manifest", function()
		local flags = TeleportLogic.checkHint({ v = 99, groupId = PSID, npcSlots = 0 / 0 }, nil, PSID)
		TestRunner.expect(table.find(flags, "BadVersion") ~= nil):toBeTruthy()
		TestRunner.expect(table.find(flags, "NpcSlotsMalformed") ~= nil):toBeTruthy()
		TestRunner.expect(table.find(flags, "GroupIdMismatch")):toBe(nil)
	end)
end)

TestRunner.describe("TeleportLogic.resolveMapId", function()
	local ENABLED = { "Lab", "Vault", "Yard" }

	TestRunner.it("uses the manifest's map, ignoring a different hint", function()
		local mapId, source = TeleportLogic.resolveMapId(manifest("Vault"), { mapId = "Yard" }, ENABLED, first)
		TestRunner.expect(mapId):toBe("Vault")
		TestRunner.expect(source):toBe("Manifest")
	end)

	TestRunner.it("never falls back to the hint while a manifest exists", function()
		local mapId, source = TeleportLogic.resolveMapId(manifest("Retired"), { mapId = "Yard" }, ENABLED, first)
		TestRunner.expect(mapId):toBe("Lab")
		TestRunner.expect(source):toBe("Fallback")
	end)

	TestRunner.it("uses an enabled hint only when the manifest is unreadable", function()
		local mapId, source = TeleportLogic.resolveMapId(nil, { mapId = "Yard" }, ENABLED, first)
		TestRunner.expect(mapId):toBe("Yard")
		TestRunner.expect(source):toBe("Hint")
	end)

	TestRunner.it("falls back to a random enabled map for an unknown or forged id", function()
		for _, bad in { "NotAMap", 42, "" } do
			local mapId, source = TeleportLogic.resolveMapId(nil, { mapId = bad }, ENABLED, function(n)
				return n
			end)
			TestRunner.expect(mapId):toBe("Yard")
			TestRunner.expect(source):toBe("Fallback")
		end
	end)

	TestRunner.it("reports None when no map is enabled at all", function()
		local mapId, source = TeleportLogic.resolveMapId(manifest("Lab"), nil, {}, first)
		TestRunner.expect(mapId):toBe(nil)
		TestRunner.expect(source):toBe("None")
	end)
end)

TestRunner.describe("TeleportLogic.admission", function()
	TestRunner.it("admits listed members while the gate is open", function()
		TestRunner.expect(TeleportLogic.admission(22, manifest("Lab"), false)):toBe("Admit")
	end)

	TestRunner.it("turns away anyone the manifest doesn't list", function()
		TestRunner.expect(TeleportLogic.admission(99, manifest("Lab"), false)):toBe("Stray")
	end)

	TestRunner.it("admits on the access code alone when the manifest is unreadable", function()
		TestRunner.expect(TeleportLogic.admission(99, nil, false)):toBe("Admit")
	end)

	TestRunner.it("sends even a listed member home once the round has started", function()
		TestRunner.expect(TeleportLogic.admission(22, manifest("Lab"), true)):toBe("Late")
	end)
end)

TestRunner.describe("TeleportLogic.gateDecision", function()
	local function gate(overrides: { [string]: any }): TeleportLogic.GateDecision
		local input: any = {
			expected = 3,
			present = 0,
			loaded = 0,
			elapsed = 0,
			graceSeconds = 10,
			loadGraceSeconds = 15,
			seatCount = 6,
		}
		for key, value in overrides do
			input[key] = value
		end
		-- `expected = nil` in a table literal is no key at all, so "no
		-- manifest" needs its own flag.
		if overrides.noManifest then
			input.expected = nil
		end
		return TeleportLogic.gateDecision(input)
	end

	TestRunner.it("starts at once when everyone expected is here and loaded", function()
		TestRunner.expect(gate({ present = 3, loaded = 3, elapsed = 1 })):toBe("Start")
	end)

	TestRunner.it("waits while someone expected hasn't arrived", function()
		TestRunner.expect(gate({ present = 2, loaded = 2, elapsed = 5 })):toBe("Wait")
	end)

	TestRunner.it("waits for a profile still loading even when everyone is here", function()
		TestRunner.expect(gate({ present = 3, loaded = 2, elapsed = 5 })):toBe("Wait")
	end)

	TestRunner.it("starts short after the grace window: NPCs take the empty seats", function()
		TestRunner.expect(gate({ present = 2, loaded = 2, elapsed = 10 })):toBe("Start")
	end)

	TestRunner.it("abandons when nobody arrived", function()
		TestRunner.expect(gate({ elapsed = 10 })):toBe("Abandon")
	end)

	TestRunner.it("gives a session-locked profile the extra load window, then starts anyway", function()
		TestRunner.expect(gate({ present = 2, loaded = 1, elapsed = 20 })):toBe("Wait")
		TestRunner.expect(gate({ present = 2, loaded = 1, elapsed = 25 })):toBe("Start")
	end)

	TestRunner.it("without a manifest, only a full server starts early", function()
		TestRunner.expect(gate({ noManifest = true, present = 3, loaded = 3, elapsed = 1 })):toBe("Wait")
		TestRunner.expect(gate({ noManifest = true, present = 6, loaded = 6, elapsed = 1 })):toBe("Start")
	end)
end)

TestRunner.describe("TeleportLogic.returnMessage", function()
	TestRunner.it("maps a known reason to its fixed message", function()
		TestRunner.expect(TeleportLogic.returnMessage({ returnReason = "Late" }) ~= nil):toBeTruthy()
		TestRunner.expect(TeleportLogic.returnMessage({ returnReason = "RoundOver" }) ~= nil):toBeTruthy()
	end)

	TestRunner.it("ignores anything else, so a forged reason can't inject text", function()
		TestRunner.expect(TeleportLogic.returnMessage({ returnReason = "You won 1M Robux" })):toBe(nil)
		TestRunner.expect(TeleportLogic.returnMessage("Late")):toBe(nil)
		TestRunner.expect(TeleportLogic.returnMessage(nil)):toBe(nil)
	end)
end)
