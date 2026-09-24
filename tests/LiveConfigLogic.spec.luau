--!strict
-- Covers LiveConfigLogic.luau (P8-5): rollout buckets, override paths,
-- fallback resolution, fail-closed kill switches, the admin commands and
-- the audit log. LiveConfig.luau itself needs DataStoreService and chat,
-- so it is verified in Studio instead (docs/live-ops.md), the same split
-- every other spec uses.

local TestRunner = require("./TestRunner")
local LiveConfigLogic = require("../src/server/LiveConfigLogic")

type Roots = LiveConfigLogic.Roots
type Context = LiveConfigLogic.Context

local ACTOR: LiveConfigLogic.Actor = { userId = 42, now = 1000 }

local function defaults(): Roots
	return {
		game = {
			raceDurationSeconds = 300,
			label = "shipped",
			roundTimers = { resultsSeconds = 8, loadingSeconds = 5 },
			bountyTiers = { { soleStealerVU = 20, loneSharerVU = 10, allShareVU = 5 } },
			npc = { tickHz = 8, skillProfiles = { { weight = 0.5 } } },
			playerCount = 6,
		},
		powerUp = { freeze = { durationSeconds = 2.5 } },
	}
end

-- Stands in for Validate: a race must be positive, bounty ordering holds.
local function fakeValidate(roots: Roots): { string }
	local issues = {}
	if roots.game.raceDurationSeconds <= 0 then
		table.insert(issues, "raceDurationSeconds must be positive")
	end
	local tier = roots.game.bountyTiers[1]
	if not (tier.soleStealerVU > tier.loneSharerVU) then
		table.insert(issues, "bounty ordering broken")
	end
	return issues
end

local function context(overrides: { [string]: any }?): Context
	local ctx: Context = {
		defaults = defaults(),
		tunablePaths = {
			"game.raceDurationSeconds",
			"game.label",
			"game.roundTimers.*",
			"game.bountyTiers.*.soleStealerVU",
			"game.npc.**",
			"powerUp.*.durationSeconds",
		},
		catalogue = {
			mapTasks = { Factory = { "fuse", "valve" }, Mall = { "fuse" } },
			taskIds = { "fuse", "valve" },
			powerUpIds = { "freeze" },
		},
		validate = fakeValidate,
	}
	for key, value in overrides or {} do
		(ctx :: any)[key] = value
	end
	return ctx
end

local function layer(version: number, fields: { [string]: any }?): LiveConfigLogic.Layer
	local result: any = { version = version }
	for key, value in fields or {} do
		result[key] = value
	end
	return result
end

local function envelope(active: any?, staged: any?): any
	return { schema = LiveConfigLogic.SCHEMA_VERSION, nextVersion = 10, active = active, staged = staged }
end

TestRunner.describe("LiveConfigLogic.bucketFor", function()
	TestRunner.it("is stable and always 0-99", function()
		for i = 1, 200 do
			local jobId = "job-" .. i
			local bucket = LiveConfigLogic.bucketFor(jobId)
			TestRunner.expect(bucket):toBe(LiveConfigLogic.bucketFor(jobId))
			TestRunner.expect(bucket >= 0 and bucket <= 99 and bucket == math.floor(bucket)):toBeTruthy()
		end
		-- Studio's JobId is empty; it must still land somewhere fixed.
		TestRunner.expect(LiveConfigLogic.bucketFor("")):toBe(LiveConfigLogic.bucketFor(""))
	end)

	TestRunner.it("spreads GUID-like ids across buckets", function()
		local seen = {}
		local distinct = 0
		for i = 1, 500 do
			local bucket = LiveConfigLogic.bucketFor(string.format("%08x-0000-4000-8000-%012d", i * 7919, i))
			if not seen[bucket] then
				seen[bucket] = true
				distinct += 1
			end
		end
		TestRunner.expect(distinct > 80):toBeTruthy()
	end)

	TestRunner.it("only adds servers as the percentage grows", function()
		TestRunner.expect(LiveConfigLogic.inRollout(0, 0)):toBeFalsy()
		TestRunner.expect(LiveConfigLogic.inRollout(9, 10)):toBeTruthy()
		TestRunner.expect(LiveConfigLogic.inRollout(10, 10)):toBeFalsy()
		TestRunner.expect(LiveConfigLogic.inRollout(99, 100)):toBeTruthy()
	end)
end)

TestRunner.describe("LiveConfigLogic paths", function()
	TestRunner.it("matches * as one segment and trailing ** as any depth", function()
		local m = LiveConfigLogic.matchesPattern
		TestRunner.expect(m("game.roundTimers.resultsSeconds", "game.roundTimers.*")):toBeTruthy()
		TestRunner.expect(m("game.roundTimers", "game.roundTimers.*")):toBeFalsy()
		TestRunner.expect(m("game.roundTimers.a.b", "game.roundTimers.*")):toBeFalsy()
		TestRunner.expect(m("game.npc.skillProfiles.1.weight", "game.npc.**")):toBeTruthy()
		TestRunner.expect(m("game.npc", "game.npc.**")):toBeFalsy()
		TestRunner.expect(m("game.raceDurationSeconds", "game.raceDurationSeconds")):toBeTruthy()
		TestRunner.expect(m("game.raceDurationSecondsX", "game.raceDurationSeconds")):toBeFalsy()
	end)

	TestRunner.it("accepts a same-typed leaf on an allowed path, array indices included", function()
		local ctx = context()
		TestRunner.expect(LiveConfigLogic.checkOverride("game.roundTimers.resultsSeconds", 12, ctx)):toBe(nil)
		TestRunner.expect(LiveConfigLogic.checkOverride("game.bountyTiers.1.soleStealerVU", 22, ctx)):toBe(nil)
		TestRunner.expect(LiveConfigLogic.checkOverride("game.npc.skillProfiles.1.weight", 0.4, ctx)):toBe(nil)
		TestRunner.expect(LiveConfigLogic.checkOverride("game.label", "live", ctx)):toBe(nil)
	end)

	TestRunner.it("refuses shape changes, wrong types and non-finite numbers", function()
		local ctx = context()
		local check = LiveConfigLogic.checkOverride
		TestRunner.expect(check("game.playerCount", 8, ctx) ~= nil):toBeTruthy() -- not tunable
		TestRunner.expect(check("game.roundTimers.newTimer", 3, ctx) ~= nil):toBeTruthy() -- doesn't exist
		TestRunner.expect(check("game.bountyTiers.2.soleStealerVU", 3, ctx) ~= nil):toBeTruthy() -- no tier 2
		TestRunner.expect(check("game.npc.skillProfiles", 1, ctx) ~= nil):toBeTruthy() -- a table
		TestRunner.expect(check("game.raceDurationSeconds", "300", ctx) ~= nil):toBeTruthy()
		TestRunner.expect(check("game.raceDurationSeconds", 0 / 0, ctx) ~= nil):toBeTruthy()
		TestRunner.expect(check("game.raceDurationSeconds", math.huge, ctx) ~= nil):toBeTruthy()
		TestRunner.expect(check(nil, 1, ctx) ~= nil):toBeTruthy()
	end)
end)

TestRunner.describe("LiveConfigLogic.resolve", function()
	TestRunner.it("runs shipped defaults when nothing was ever written", function()
		local result = LiveConfigLogic.resolve(nil, 50, context())
		TestRunner.expect(result.source):toBe("Defaults")
		TestRunner.expect(result.version):toBe(0)
		TestRunner.expect(#result.issues):toBe(0)
		TestRunner.expect(result.flags.storeEnabled):toBeTruthy()
	end)

	TestRunner.it("applies a valid active layer without touching the defaults", function()
		local ctx = context()
		local raw = envelope(layer(3, { overrides = { ["game.raceDurationSeconds"] = 240 } }))
		local result = LiveConfigLogic.resolve(raw, 50, ctx)
		TestRunner.expect(result.source):toBe("Active")
		TestRunner.expect(result.version):toBe(3)
		TestRunner.expect(result.roots.game.raceDurationSeconds):toBe(240)
		TestRunner.expect(ctx.defaults.game.raceDurationSeconds):toBe(300)
	end)

	TestRunner.it("rejects a layer whole when any one override is bad", function()
		local raw = envelope(layer(3, {
			overrides = { ["game.raceDurationSeconds"] = 240, ["game.playerCount"] = 8 },
		}))
		local result = LiveConfigLogic.resolve(raw, 50, context())
		TestRunner.expect(result.source):toBe("Defaults")
		TestRunner.expect(result.roots.game.raceDurationSeconds):toBe(300)
		TestRunner.expect(#result.issues):toBe(1)
	end)

	TestRunner.it("rejects a layer the real validator refuses, or that makes it throw", function()
		local raw = envelope(layer(3, { overrides = { ["game.bountyTiers.1.soleStealerVU"] = 1 } }))
		TestRunner.expect(LiveConfigLogic.resolve(raw, 50, context()).source):toBe("Defaults")
		local throwing = context({
			validate = function(_roots: Roots): { string }
				error("boom")
			end,
		})
		local result = LiveConfigLogic.resolve(envelope(layer(1)), 50, throwing)
		TestRunner.expect(result.source):toBe("Defaults")
		TestRunner.expect(string.find(result.issues[1], "threw", 1, true) ~= nil):toBeTruthy()
	end)

	TestRunner.it("runs staged only on servers inside the rollout", function()
		local staged = { percent = 30, layer = layer(5, { overrides = { ["game.raceDurationSeconds"] = 200 } }) }
		local raw = envelope(layer(4), staged)
		local inside = LiveConfigLogic.resolve(raw, 29, context())
		local outside = LiveConfigLogic.resolve(raw, 30, context())
		TestRunner.expect(inside.source):toBe("Staged")
		TestRunner.expect(inside.roots.game.raceDurationSeconds):toBe(200)
		TestRunner.expect(outside.source):toBe("Active")
		TestRunner.expect(outside.roots.game.raceDurationSeconds):toBe(300)
	end)

	TestRunner.it("falls back from a broken staged layer to active", function()
		local staged = { percent = 100, layer = layer(5, { overrides = { ["game.raceDurationSeconds"] = -1 } }) }
		local result = LiveConfigLogic.resolve(envelope(layer(4), staged), 0, context())
		TestRunner.expect(result.source):toBe("Active")
		TestRunner.expect(result.version):toBe(4)
		TestRunner.expect(#result.issues):toBe(1)
	end)

	TestRunner.it("treats malformed documents and other schemas as defaults", function()
		for _, raw in { "garbage", 7, { schema = 99, nextVersion = 1 }, envelope("not a layer") } do
			local result = LiveConfigLogic.resolve(raw, 0, context())
			TestRunner.expect(result.source):toBe("Defaults")
			TestRunner.expect(#result.issues > 0):toBeTruthy()
		end
		local badPercent = envelope(nil, { percent = 150, layer = layer(1) })
		TestRunner.expect(LiveConfigLogic.resolve(badPercent, 0, context()).source):toBe("Defaults")
		local unknownFlag = envelope(layer(1, { flags = { turboMode = true } }))
		TestRunner.expect(LiveConfigLogic.resolve(unknownFlag, 0, context()).source):toBe("Defaults")
	end)
end)

TestRunner.describe("LiveConfigLogic flags", function()
	TestRunner.it("makes read-only mode switch the store and leaderboard writes off", function()
		local flags = LiveConfigLogic.effectiveFlags({ readOnly = true, storeEnabled = true })
		TestRunner.expect(flags.storeEnabled):toBeFalsy()
		TestRunner.expect(flags.leaderboardWritesEnabled):toBeFalsy()
		TestRunner.expect(flags.npcFillEnabled):toBeTruthy()
	end)

	TestRunner.it("keeps a kill switch from a layer that failed validation", function()
		local raw = envelope(layer(4, {
			flags = { storeEnabled = false },
			overrides = { ["game.raceDurationSeconds"] = -5 },
		}))
		local result = LiveConfigLogic.resolve(raw, 0, context())
		TestRunner.expect(result.source):toBe("Defaults")
		TestRunner.expect(result.flags.storeEnabled):toBeFalsy()
		TestRunner.expect(result.flags.npcFillEnabled):toBeTruthy()
	end)

	TestRunner.it("reads a kill switch even from a document that fails the shape check", function()
		local staged = { percent = 100, layer = layer(5) }
		local rejectedActive = layer(4, { flags = { readOnly = true, turboMode = true } })
		-- The shape check rejects the whole document, but readOnly still reads.
		local result = LiveConfigLogic.resolve(envelope(rejectedActive, staged), 0, context())
		TestRunner.expect(result.flags.readOnly):toBeTruthy()
		TestRunner.expect(result.flags.storeEnabled):toBeFalsy()
	end)

	TestRunner.it("only honours the OFF direction from a rejected layer", function()
		local raw = envelope(layer(4, { flags = { storeEnabled = true, readOnly = false }, overrides = 5 }))
		local result = LiveConfigLogic.resolve(raw, 0, context())
		TestRunner.expect(result.flags.storeEnabled):toBeTruthy()
		TestRunner.expect(result.flags.readOnly):toBeFalsy()
	end)

	TestRunner.it("disables content by id and refuses an unplayable result", function()
		local ok = LiveConfigLogic.resolve(
			envelope(layer(1, { flags = { disabledMapIds = { "Mall" }, disabledPowerUpIds = { "freeze" } } })),
			0,
			context()
		)
		TestRunner.expect(ok.source):toBe("Active")
		TestRunner.expect(ok.flags.disabledMaps.Mall):toBeTruthy()
		TestRunner.expect(ok.flags.disabledMaps.Factory):toBe(nil)
		TestRunner.expect(ok.flags.disabledPowerUps.freeze):toBeTruthy()

		local function sourceFor(flags: any): string
			return LiveConfigLogic.resolve(envelope(layer(1, { flags = flags })), 0, context()).source
		end
		TestRunner.expect(sourceFor({ disabledMapIds = { "Factory", "Mall" } })):toBe("Defaults")
		TestRunner.expect(sourceFor({ disabledTaskIds = { "fuse" } })):toBe("Defaults") -- Mall would be empty
		TestRunner.expect(sourceFor({ disabledTaskIds = { "fuse" }, disabledMapIds = { "Mall" } })):toBe("Active")
		TestRunner.expect(sourceFor({ disabledMapIds = { "Atlantis" } })):toBe("Defaults")
	end)
end)

TestRunner.describe("LiveConfigLogic.syncLeaves", function()
	TestRunner.it("writes in place, so a captured sub-table sees the change and the revert", function()
		local live = defaults()
		local captured = live.game.roundTimers
		local ctx = context()
		local tuned = LiveConfigLogic.resolve(
			envelope(layer(1, { overrides = { ["game.roundTimers.resultsSeconds"] = 12 } })),
			0,
			ctx
		)
		TestRunner.expect(LiveConfigLogic.syncLeaves(live, tuned.roots)):toBe(1)
		TestRunner.expect(captured.resultsSeconds):toBe(12)

		local reverted = LiveConfigLogic.resolve(envelope(layer(2)), 0, ctx)
		TestRunner.expect(LiveConfigLogic.syncLeaves(live, reverted.roots)):toBe(1)
		TestRunner.expect(captured.resultsSeconds):toBe(8)
		TestRunner.expect(live.game.roundTimers == captured):toBeTruthy()
	end)
end)

TestRunner.describe("LiveConfigLogic.parseCommand", function()
	TestRunner.it("parses every verb", function()
		local set = LiveConfigLogic.parseCommand("set game.raceDurationSeconds 240")
		TestRunner.expect(set and set.kind):toBe("Set")
		TestRunner.expect(set and set.value):toBe(240)
		local label = LiveConfigLogic.parseCommand("set game.label two words")
		TestRunner.expect(label and label.value):toBe("two words")
		local bool = LiveConfigLogic.parseCommand("set game.telemetry.enabled false")
		TestRunner.expect(bool and bool.value):toBe(false)
		local disable = LiveConfigLogic.parseCommand("DISABLE Map Factory")
		TestRunner.expect(disable and disable.kind):toBe("Disable")
		TestRunner.expect(disable and disable.category):toBe("map")
		TestRunner.expect(disable and disable.id):toBe("Factory")
		local flag = LiveConfigLogic.parseCommand("flag store off")
		TestRunner.expect(flag and flag.on):toBe(false)
		local kill = LiveConfigLogic.parseCommand("kill leaderboard")
		TestRunner.expect(kill and kill.switch):toBe("leaderboard")
		local rollout = LiveConfigLogic.parseCommand("rollout 25")
		TestRunner.expect(rollout and rollout.percent):toBe(25)
		for _, verb in { "status", "promote", "abort", "readonly on", "unset game.label" } do
			TestRunner.expect(LiveConfigLogic.parseCommand(verb) ~= nil):toBeTruthy()
		end
	end)

	TestRunner.it("rejects malformed commands with a message", function()
		for _, text in
			{
				"",
				"set onlypath",
				"flag store maybe",
				"kill everything",
				"rollout 150",
				"rollout 2.5",
				"disable hat x",
				"promote now",
			}
		do
			local command, problem = LiveConfigLogic.parseCommand(text)
			TestRunner.expect(command):toBe(nil)
			TestRunner.expect(type(problem) == "string"):toBeTruthy()
		end
	end)
end)

TestRunner.describe("LiveConfigLogic.applyCommand", function()
	local function run(current: LiveConfigLogic.Envelope, text: string): (LiveConfigLogic.Envelope?, string)
		local command = LiveConfigLogic.parseCommand(text)
		assert(command ~= nil, text)
		return LiveConfigLogic.applyCommand(current, command, ACTOR, context())
	end

	TestRunner.it("stages an edit at 0% on a copy of active, leaving the input alone", function()
		local current = envelope(layer(4, { overrides = { ["game.label"] = "live" } }))
		local after, message = run(current, "set game.raceDurationSeconds 240")
		assert(after ~= nil, message)
		local staged = after.staged :: LiveConfigLogic.Staged
		TestRunner.expect(staged.percent):toBe(0)
		TestRunner.expect(staged.layer.version):toBe(10)
		TestRunner.expect(staged.layer.editedBy):toBe(42)
		TestRunner.expect((staged.layer.overrides :: any)["game.label"]):toBe("live")
		TestRunner.expect((staged.layer.overrides :: any)["game.raceDurationSeconds"]):toBe(240)
		TestRunner.expect(after.nextVersion):toBe(11)
		TestRunner.expect((after.active :: any).version):toBe(4)
		TestRunner.expect(current.staged):toBe(nil)
	end)

	TestRunner.it("refuses an edit that wouldn't validate, before it's ever written", function()
		local after, message = run(envelope(nil), "set game.raceDurationSeconds -1")
		TestRunner.expect(after):toBe(nil)
		TestRunner.expect(string.find(message, "refused", 1, true) ~= nil):toBeTruthy()
		local bad, typeMessage = run(envelope(nil), "set game.raceDurationSeconds fast")
		TestRunner.expect(bad):toBe(nil)
		TestRunner.expect(string.find(typeMessage, "number", 1, true) ~= nil):toBeTruthy()
		local oneMap = run(envelope(nil), "disable map Mall") :: LiveConfigLogic.Envelope
		TestRunner.expect(oneMap ~= nil):toBeTruthy()
		TestRunner.expect((run(oneMap, "disable map Factory"))):toBe(nil)
	end)

	TestRunner.it("walks a change through rollout and promote", function()
		local staged = run(envelope(layer(4)), "set game.raceDurationSeconds 240") :: LiveConfigLogic.Envelope
		TestRunner.expect((run(envelope(layer(4)), "rollout 10"))):toBe(nil)
		local widened = run(staged, "rollout 25") :: LiveConfigLogic.Envelope
		TestRunner.expect((widened.staged :: LiveConfigLogic.Staged).percent):toBe(25)
		local promoted = run(widened, "promote") :: LiveConfigLogic.Envelope
		TestRunner.expect(promoted.staged):toBe(nil)
		TestRunner.expect((promoted.active :: LiveConfigLogic.Layer).version):toBe(10)
		local aborted = run(widened, "abort") :: LiveConfigLogic.Envelope
		TestRunner.expect(aborted.staged):toBe(nil)
		TestRunner.expect((aborted.active :: LiveConfigLogic.Layer).version):toBe(4)
	end)

	TestRunner.it("applies kill switches to active and staged immediately", function()
		local staged = run(envelope(layer(4)), "set game.raceDurationSeconds 240") :: LiveConfigLogic.Envelope
		local killed = run(staged, "kill store") :: LiveConfigLogic.Envelope
		local active = killed.active :: LiveConfigLogic.Layer
		local stagedLayer = (killed.staged :: LiveConfigLogic.Staged).layer
		TestRunner.expect((active.flags :: any).storeEnabled):toBe(false)
		TestRunner.expect((stagedLayer.flags :: any).storeEnabled):toBe(false)
		for _, bucket in { 0, 99 } do
			TestRunner.expect(LiveConfigLogic.resolve(killed, bucket, context()).flags.storeEnabled):toBeFalsy()
		end
		local readOnly = run(envelope(nil), "readonly on") :: LiveConfigLogic.Envelope
		TestRunner.expect(LiveConfigLogic.resolve(readOnly, 50, context()).flags.readOnly):toBeTruthy()
	end)

	TestRunner.it("toggles content lists and cleans up an emptied list", function()
		local disabled = run(envelope(nil), "disable powerup freeze") :: LiveConfigLogic.Envelope
		local layerFlags = (disabled.staged :: LiveConfigLogic.Staged).layer.flags :: any
		TestRunner.expect(layerFlags.disabledPowerUpIds[1]):toBe("freeze")
		local enabled = run(disabled, "enable powerup freeze") :: LiveConfigLogic.Envelope
		TestRunner.expect(((enabled.staged :: LiveConfigLogic.Staged).layer.flags :: any).disabledPowerUpIds):toBe(nil)
	end)

	TestRunner.it("describes status without writing anything", function()
		local after, message = run(envelope(layer(4, { flags = { storeEnabled = false } })), "status")
		TestRunner.expect(after):toBe(nil)
		TestRunner.expect(string.find(message, "off: store", 1, true) ~= nil):toBeTruthy()
	end)
end)

TestRunner.describe("LiveConfigLogic audit and admins", function()
	TestRunner.it("caps the log from the front and survives a corrupt one", function()
		local log = LiveConfigLogic.appendAudit("corrupt", {
			at = 1,
			userId = 42,
			command = "status",
			ok = true,
			message = "",
			version = 0,
		}, 2)
		TestRunner.expect(#log):toBe(1)
		for i = 2, 4 do
			log = LiveConfigLogic.appendAudit(log, {
				at = i,
				userId = 42,
				command = "status",
				ok = true,
				message = "",
				version = 0,
			}, 2)
		end
		TestRunner.expect(#log):toBe(2)
		TestRunner.expect(log[1].at):toBe(3)
		TestRunner.expect(log[2].at):toBe(4)
	end)

	TestRunner.it("gates on the admin list", function()
		TestRunner.expect(LiveConfigLogic.isAdmin(42, { 7, 42 })):toBeTruthy()
		TestRunner.expect(LiveConfigLogic.isAdmin(43, { 7, 42 })):toBeFalsy()
		TestRunner.expect(LiveConfigLogic.isAdmin(42, {})):toBeFalsy()
	end)
end)
